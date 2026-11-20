# Handoff: parallel range downloads and resume

This file is the entry point for the next session that picks up the work
designed in `parallel-ranges-and-resume.md`. It exists because the original
session ended under a system-level instruction that forbade code edits; the
design is complete and the implementation belongs in a fresh session.

## Read these first, in order

1. `docs/PLANS/parallel-ranges-and-resume.md` — the full plan, with the
   five locked decisions under the `## Decisions` heading
2. `docs/CURRENT_STATUS.md` — current accepted behavior of `main`; the
   runtime is 18, Keychain is backed by `127.0.0.1:63406`, no active jobs
3. `docs/SESSION_LOG.md` — chronological history; the top entry is the
   2026-08-29 fractional-second ISO-8601 fix and the Runtime 18 deployment
4. The plan file's `## Implementation contract` section — the verification
   gate, the LaunchAgent approval gate, and the no-runtime-bump rule
5. Team memory entries (read with the memory MCP server if not already in
   context):
   - `user-collaboration-style` — explicit approval for LaunchAgent edits
     and Keychain material
   - `lustre-agent-runtime-layout` — the per-runtime install path under
     `~/Library/Application Support/LustreStudioAgent/Runtime/N/`
   - `lustre-xcode-toolchain` — use `/Volumes/WD/Applications/Xcode.app`
     (Swift 6.2.4), not the system CommandLineTools
   - `lustre-cloud-iso8601-decoder` — `JSONDecoder.cloud` strategy must
     be mirrored in any new code that touches the cloud wire format

## Start here: Phase 0

The first deliverable is Phase 0: a standalone `lustre bench <url>`
subcommand in `Sources/lustre/main.swift`, gated behind
`lustre config download.benchEnabled = true`. It produces a JSONL
stream of throughput, latency, and per-tick write cost.

This is the only phase that does not require a verification subagent
before being marked complete; it is the measurement harness the rest
of the phases use. Once it lands, run it against the three target
hosts (a direct CDN that hits `requiresInitialRange`, an
HLS-via-yt-dlp host, a WebDAV destination) and write the numbers into
`docs/SESSION_LOG.md` as a new dated top-insert entry.

## Then, in this order

- Phase 1: resume-safe storage layout (`DownloadJob.resumeState`,
  per-job partial directory under `~/Library/Application Support/LustreStudioAgent/Partials/<job-id>/`)
- Phase 2: parallel range download (8 streams per job, `httpMaximumConnectionsPerHost=8`)
- Phase 3: resume on restart (HEAD-then-Range, `If-Range` validation, 72 h TTL)
- Phase 4: observability (per-range worker log entries, `lustre status --job <id>`)
- Phase 5: verification (subagent_type=verification, per the standing contract)

## What you do not need to redo

- The deep analysis of `downloadToLocalDirectory`, the URL safety
  policy, the queue model, the HLS materialization, and the
  loopback-server contract is already in the plan file
- The five open questions in the original draft are now locked
  decisions under the `## Decisions` heading of the plan
- The non-goals are explicit: no change to queue ordering, destination
  routing, HLS materializer, cloud-staging path, or `URLSafetyPolicy`
  in this plan

## What you must not do

- No LaunchAgent edits without explicit user approval
- No runtime version bump (Runtime 18 is the live install; a Runtime
  19 deployment is a separate plan the user must approve)
- No Keychain code path changes without explicit user approval
- No silent re-litigation of the five locked decisions

## Verification contract

Phases 1-4 each require a subagent_type=verification pass before being
reported complete. The verifier receives: the original user request,
the list of files changed, the approach taken, and the path to this
plan file. On PASS, spot-check 2-3 commands from the verifier's report
by re-running them. On FAIL or PARTIAL, fix and resume the verifier.
