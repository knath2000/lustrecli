# Plan: parallel range downloads and resume for LustreAgent

Status: draft, awaiting user decisions on the open questions at the end.
Owner: Lustre maintainer
Date: 2026-09-02
Source analysis: this conversation, against `main` at `cdb0536 fix(cloud): accept fractional-second ISO-8601 timestamps in collection store`.

## Problem statement

`Sources/LustreAgent/AgentService.swift` has two structural limits on the download path:

1. **One stream per file.** `downloadToLocalDirectory` (around line 1019-1077) issues a single `URLSession.bytes(for: request)` and reads the response in a sequential `for try await byte` loop, writing 64 KB chunks to a single `*.part` file. Concurrency across jobs is supported via `maximumConcurrentDownloads` (default 1, max 8), but per-job throughput is bound to the bandwidth of one TCP connection per host. Hosts that allow 4-8 parallel connections are being asked to serve one.
2. **No resume.** `recoverDurableJobs` (around line 867-881) flips every `running` job to `queued` on agent startup and `removeJob(id:)` deletes only the SQLite row. The `*.part` file is left on disk and is overwritten from byte 0 on the next attempt. There is no `Range:` request, no partial-state persistence, no `If-Range:` validation, and no cleanup of orphaned partials.

Both issues surface together: a parallel range fan-out without a way to recover from a mid-fan-out failure is brittle, and a resume implementation without a way to express "I have N fragments done" cannot benefit from per-range parallelism. The plan below orders the work so that resume-safe storage is in place before any parallel fan-out is enabled, and rolls the new behavior out behind a feature flag.

## Non-goals

- No change to the queue ordering, the destination routing, the HLS materializer, or the cloud-staging path in this plan. Those are out of scope; analysis for them is in the conversation transcript and can be addressed in a follow-up plan.
- No change to `URLSafetyPolicy`. The existing redirect delegate and the per-host allow list continue to apply; the new code paths (Range request, HEAD, redirect during Range) all flow through the same delegate.
- No change to the LaunchAgent wiring, the runtime install path, or the Keychain flow. The team memory is explicit that LaunchAgent edits are a user-approval gate.
- No change to the loopback server's HTTP contract. The progress events emitted from the new downloader are the same `DownloadProgress` shape that the loopback server already serializes.

## Phase 0: baseline measurements (no agent restart needed)

Goal: a concrete "before" number so the phases below can be evaluated.

1. Measure current download throughput on three known hosts:
   - a direct CDN (one of the `cloudatacdn.com` / `mxcontent.net` cases that already triggers `Range: bytes=0-` via `requiresInitialRange`)
   - an HLS-via-yt-dlp host
   - a WebDAV destination
   For each, run 3 trials at `maximumConcurrentDownloads = 1` and `= 4` and report mean / p95 throughput in MB/s.
2. Measure per-tick cost of the progress path: time from the `onProgress` callback to the `JobStore.update` BLOB write completion, with `activeDownloadTasks.count` = 1, 4, 8.
3. Note that `URLSessionConfiguration.httpMaximumConnectionsPerHost` is left at system default (4-6 on macOS). Any per-job parallelism above that cap on HTTP/1.1 will not help unless we explicitly raise it. Record the current cap as observed.
4. Write the measurements into `docs/SESSION_LOG.md` as a new dated entry under the existing top-insert convention.

Exit criteria: a single SESSION_LOG entry containing the three numbers and the connection-cap observation. The "after" numbers from Phases 2 and 3 will be appended to the same entry.

## Phase 1: resume-safe storage layout

Goal: a per-job partial directory and a persisted `ResumeState` on the `DownloadJob`. No behavior change visible to the user.

1. Replace the `appendingPathExtension("part")` convention with a per-job partial directory keyed by job UUID. Layout: `~/Library/Application Support/LustreStudioAgent/Partials/<job-id>/<base-name>.part` and a sibling `<base-name>.meta.json`.
2. Add `resumeState: ResumeState?` to `DownloadJob` in `Sources/LustreCore/Models.swift`. Suggested shape:

   ```swift
   public struct DownloadResumeState: Codable, Equatable, Sendable {
       public var byteOffset: Int64
       public var etag: String?
       public var lastModified: String?
       public var startedAt: Date
       public var rangesCompleted: [ClosedRange<Int64>]
   }
   ```

   Fields are optional inside the existing JSON BLOB. Existing rows without the field decode to `nil` and behave as today.
3. In `AgentService.removeJob(id:)`, also delete the per-job partial directory.
4. In `AgentService.recoverDurableJobs`, do not delete partials. The next attempt reads the partial directory; if a `ResumeState` exists, the new code in Phase 3 picks it up.
5. Confirm the schema migration is additive only. `JobStore` writes the whole BLOB on every update, so adding a new optional field is forward-compatible. No `ALTER TABLE` is needed.

Exit criteria: `swift build` and the existing `LustreCoreTests` / `ChromeExtensionTests` pass. Manual smoke: queue a 200 MB+ job, let it run for 30 s, kill the agent, restart, and confirm the partial directory is still there. (The job will still re-download from byte 0 at this point; that is expected and is fixed in Phase 3.)

## Phase 2: parallel range download

Goal: per-job multi-stream download, behind a feature flag that defaults to OFF for one release.

1. Refactor `downloadToLocalDirectory` into four named functions. The existing `URLSafetyPolicy` guard and the `AgentDownloadRedirectDelegate` are reused as-is.
   - `probeSizeAndAcceptRanges(url:headers:) -> (total: Int64, acceptsRanges: Bool, etag: String?, lastModified: String?)` — issue a `HEAD` and parse the response. The same probe is reused by the resume path in Phase 3.
   - `planRanges(total:cap:etag:) -> [RangePlan]` — split the file into N equal-size ranges. `cap` is a per-job setting (default 4, max 8).
   - `downloadRange(url:range:etag:...) -> URL` — own `URLSession` with `httpMaximumConnectionsPerHost = 8`, `AgentDownloadRedirectDelegate`, `For-Range` redirect validation. Writes to `<base>.part.<i>`.
   - `concat(parts:into:onProgress:)` — single-pass concatenation, sorted by range start, with no intermediate copy. Reports progress as bytes summed across ranges.
2. Defaults: fall back to the existing single-stream path when any of the following are true:
   - `Content-Length` is missing or unreliable (no `Content-Length` header, or `Transfer-Encoding: chunked`)
   - `Accept-Ranges: bytes` is absent
   - total size < 8 MB (parallel overhead not worth it)
   - The feature flag is OFF (default for one release)
3. Per-fragment `URLSession` configuration: `httpMaximumConnectionsPerHost = 8`, ephemeral, custom redirect delegate. Each per-fragment session is invalidated at the end of its fragment.
4. Per-fragment buffer size: 1 MB (up from 64 KB) to amortize `FileHandle.write` syscalls. The total in-flight memory per job is bounded by `cap × 1 MB` = 8 MB at the default cap, well under the macOS per-process soft limit.
5. The `onProgress` callback in the parent task sums the per-fragment bytes. The existing dedupe logic in `updateProgress(_:for:taskID:)` (around line 821-865) continues to gate writes.
6. The 416 path: if any range returns 416 mid-fan-out, the parent task aborts, deletes the per-job partial directory, and the next attempt re-runs the single-stream path.

Risks:

- File descriptor count: with 8 jobs × 8 ranges × 2 sockets = 128 FDs, under the macOS default `ulimit -n` of 256 but worth a `lustre status --fds` endpoint in a follow-up.
- HTTP/1.1 head-of-line blocking: the per-fragment `URLSession` will not get the first byte until the previous one has handed off the connection. This is acceptable; we are not trying to be a BBR-style CDN.
- Server `If-Range` mismatch: if the file changes between probe and fetch, the server returns 200 with the new full content. The current code overwrites the partial; the same is true here. The `ResumeState.etag` captured in Phase 1 will be the source of truth for "same file" across the resume attempt in Phase 3.

Exit criteria: feature flag `lustre config download.parallelRanges` defaults to OFF. With the flag ON, a smoke test downloads a known 1 GB file in roughly the time the throughput number from Phase 0 suggests is the parallel ceiling. The SESSION_LOG entry from Phase 0 gains a new "after" line with the parallel number.

## Phase 3: resume on restart

Goal: pick up a partial file on a fresh attempt.

1. On `downloadToLocalDirectory` entry, look up `job.resumeState`. If non-nil and the partial directory exists:
   - Issue `HEAD` first (not `Range`).
   - If `ETag` and `Last-Modified` both match the saved values, issue `Range: bytes=<byteOffset>-` on a single stream and append to the existing partial.
   - If either mismatches, restart from byte 0 (delete the partial directory and behave as a fresh job).
2. On `processQueuedJob` exit (success, failure, or cancellation), persist the new `resumeState` to the job row. On success the offset is the total file size and the partial is renamed to its final name; the `resumeState` is set to `nil` so the next attempt is a fresh job.
3. `removeJob(id:)` deletes the per-job partial directory.
4. `recoverDurableJobs()` no longer flips `running` to `queued` blindly. Instead:
   - If the partial directory exists and the `ResumeState` is recent (within the configurable resume TTL, default 72 h), keep the job at `running` and re-arm the progress callback. The next download attempt re-enters the resume path.
   - If the partial is missing or the metadata is older than the TTL, flip to `queued` as today.
5. URL rotation: providers that rotate `quality.url` per request will cause the HEAD-then-Resume path to return 416 or 200 with mismatched content. The retry falls back to a fresh download. The old partial is removed at that point.

Risks:

- Resume TTL defaults are a tradeoff between "trust the partial" and "the provider rotated URLs". 72 h is a starting point; the open question below asks for confirmation.
- The 416 path emits a single "resuming" event in the job log. Users who see the event in the loopback server should not mistake it for a retry loop.

Exit criteria: kill the agent mid-download at 60%, restart the agent, see the job resume from 60%, and complete in roughly the time the Phase 0 throughput number suggests is the remaining 40%.

## Phase 4: observability

Goal: make both improvements visible and diagnosable.

1. Per-job `JobLogEntry` events for the new paths:
   - "Detected partial: N bytes, resuming from offset N"
   - "Planned K parallel ranges of ~M MB each"
   - "Server did not return Accept-Ranges; falling back to single-stream"
   - "If-Range mismatch; restarting from byte 0"
2. Per-tick `DownloadProgress.bytesPerSecond` is the sum across all ranges. The existing ETA math in `DownloadProgress.init` continues to bound it; the dedupe logic is unchanged.
3. Add `lustre status --job <id>` that prints a per-range worker list, e.g.:

   ```
   job 9c1a-...  phase=downloading  total=1.2 GB
   range 0/7 [0–150M)        @ 4.2 MB/s  done
   range 1/7 [150–300M)      @ 3.8 MB/s  done
   range 2/7 [300–450M)      @ 4.1 MB/s  in-progress  72%
   range 3/7 [450–600M)      @ 3.9 MB/s  in-progress  41%
   range 4/7 [600–750M)      queued
   range 5/7 [750–900M)      queued
   range 6/7 [900–1050M)     queued
   range 7/7 [1050–1200M)    queued
   ```

4. A SESSION_LOG entry after one full cycle that the user can hand to the verifier.

Exit criteria: a SESSION_LOG entry containing the per-job log events and the per-range worker output for at least one job.

## Phase 5: verification

Per the standing verification contract, the work is non-trivial (multiple files, behavior change, schema-adjacent additions) and must be independently verified before reporting completion.

Spawn the verification subagent with subagent_type=verification, passing:

- the original user request (parallel range download and resume)
- the list of files changed (filled in at implementation time)
- the approach taken (this plan)
- the path to this plan file

The verifier runs:
1. `swift build` with the external Xcode toolchain at `/Volumes/WD/Applications/Xcode.app` (per team memory `lustre-xcode-toolchain`)
2. `swift test` running `LustreCoreTests` and `ChromeExtensionTests`
3. A smoke test of parallel range download against a known provider
4. A smoke test of resume by killing the agent at 60% and confirming the partial is preserved
5. A `URLSafetyPolicy` confirmation that every new code path (Range request, HEAD, redirect during Range) still blocks `localhost` and `*.local`

On PASS, spot-check 2-3 commands from the report by re-running them. On FAIL or PARTIAL, fix and resume the verifier.

## Decisions (locked 2026-09-02)

1. Per-job parallelism cap: **8 streams per job, host-agnostic**. The `requiresInitialRange` gate already restricts `Range:` to hosts whose CDN supports it, so a host-specific cap adds complexity without a real win.
2. Resume TTL: **72 hours, configurable** via `lustre config download.resumeTTLHours`. Stored on the `DownloadResumeState` row as `startedAt`; the age check uses wall-clock `Date()` at the start of the next attempt.
3. Feature flag mechanism: **`agent_config.json`** under `~/Library/Application Support/LustreStudioAgent/`. Read on every `downloadToLocalDirectory` entry, not cached. User-editable without touching the SQLite row.
4. Phase 0 measurement: a **standalone `lustre bench <url>`** subcommand in `Sources/lustre/main.swift`, gated behind `lustre config download.benchEnabled = true` so it doesn't ship by default. Prints throughput, latency, and per-tick write cost to a JSONL stream. Run before any Phase 1 code lands.
5. Phase order: **1 before 2**. Resume-safe storage must exist before parallel ranges fan out, so a 416 mid-fan-out has a known recovery path.

## Implementation contract

The plan is locked at the design level. The implementation belongs in a follow-up session where the standing code-writing instruction is not in effect. When the implementation session starts, the contract is:

- All five decisions in the "Decisions" section above are the source of truth. No silent re-litigation.
- Phase 0 (`lustre bench`) lands first and is the only Phase that lands without a code-review gate; the next session that wants to write code picks up Phase 0 as its first deliverable.
- Phases 1-4 each require a verification subagent (subagent_type=verification) before being reported complete. The original user request, the list of files changed, the approach taken, and this plan file's path are the inputs to the verifier.
- Phase 5 is the cross-phase verification pass: build, test, smoke, and `URLSafetyPolicy` re-check.
- LaunchAgent edits, runtime install path changes, and Keychain flows are user-approval gates per team memory `user-collaboration-style`. The implementation session must surface these and wait for explicit approval before acting.
- No runtime bump in this plan. `docs/CURRENT_STATUS.md` reports Runtime 18 as the live install; a Runtime 19 deployment is a separate plan that the user must approve.

## What this plan does not do

- It does not modify the LaunchAgent or the runtime install path. Team memory is explicit that this is a user-approval gate.
- It does not bump the runtime version. `docs/CURRENT_STATUS.md` reports Runtime 18 as the live install; a deployment to Runtime 19 belongs in a separate conversation where the user approves the launch.
- It does not write or augment any Swift code in this conversation. The standing instruction is analysis only; the implementation phases above are plans, not patches.
