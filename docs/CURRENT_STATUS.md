# Current implementation status

Last updated: 2026-07-24

This document records the accepted behavior in the current `main` working tree, including the pieces that are intentionally still incomplete. `ARCHITECTURE.md` remains the component-level design reference; `SESSION_LOG.md` records the delivery chronology.

## Production-ready behavior in this revision

### Durable local agent

- `lustre-agent` is the persistent per-user worker. It owns SQLite jobs, fresh provider resolution, transfer execution, retries, local filesystem access, WebDAV, Keychain secrets, and the authenticated loopback API.
- The listener remains fixed to `127.0.0.1:63406`; all `/v1` routes require the Keychain-backed bearer token.
- Jobs preserve source page URLs and optional exact quality labels. Signed CDN URLs are resolved again immediately before transfer and are not persisted.
- The default scheduler runs one ordinary transfer at a time. Later jobs remain queued in creation order; Force Start applies only to the explicitly selected queued job.

### Providers and feeds

- Static/direct resolution supports direct media, AllPornStream, Playmogo/Dood, MixDrop, StreamTape, mydaddy.cc, LuluStream/Vidara HLS, HQPorner, OnlyFan420, and PornHub through agent-owned yt-dlp.
- Feed sources include AllPornStream, HQPorner, OnlyFan420, PornHub, and—while authenticated—PornHub Subscriptions, Liked, and Favorites.
- The regular PornHub source is session-aware: signed-in requests send the agent-only sanitized PornHub cookie header and receive the account homepage; signed-out, signing-in, and expired states use the anonymous homepage. Session-storage failure returns a static error rather than silently downgrading an asserted signed-in request.
- The separate Subscriptions, Liked, and Favorites sources always require a valid session and never fall back to anonymous pages.
- Feed thumbnails and hover videos use `/v1/feed/assets`. The proxy accepts only tightly allowlisted HTTPS provider CDN hosts, fixed non-secret Referer/User-Agent headers, safe redirects, expected image/video media types, and bounded response sizes. PornHub cookies are never forwarded to asset CDNs.
- The web feed renders WebM/MP4 previews as `<video>`, ordinary frames as `<img>`, caches successful object URLs per source URL, remembers failures, and revokes object URLs on teardown.

### PornHub authentication

- Credentials are entered only into a separate visible `lustre-auth-helper` WKWebView. Lustre Cloud, the loopback API, CLI, durable jobs, and logs never receive the username or password.
- The helper uses `WKWebsiteDataStore.nonPersistent()` and is destroyed after success, failure, cancellation, or timeout.
- Main-frame navigation is restricted to trusted HTTPS PornHub hosts. HTTPS subframes may operate only while the current top-level page is trusted HTTPS PornHub, allowing provider-controlled login/captcha internals without allowing foreign content to become the main frame. Popups, downloads, HTTP, and foreign main-frame navigation remain blocked.
- WebKit cookies are bounded at 512 raw entries, filtered to exact trusted PornHub domains, then passed through the strict persisted-cookie sanitizer. Foreign cookies cannot poison or enter the stored candidate set.
- Cookie observation and completed trusted login navigation are coalesced. The current provider flow may stall after `/front/authenticate` because `/user/premium_redirect_cookie?ajax=1` returns an empty body while provider JavaScript expects JSON. The trusted `premium_redirect` cookie is therefore a validation trigger only; it is never authentication proof.
- Successful authentication still requires a sanitized `il` session cookie and explicit `globalThis.isLoggedInUser === 1` on canonical `https://www.pornhub.com/subscriptions` within a bounded validation budget.
- Sessions are stored only as bounded sanitized cookie records in the login Keychain. Host-only cookies remain exact-host. Outbound cookies are limited to matching trusted HTTPS PornHub hosts.
- Authenticated yt-dlp uses a unique exclusive mode-0600 temporary Netscape cookie file. No browser-cookie import, `--cookies-from-browser`, shell command, or raw `Cookie:` process argument is used.
- Cancellation, helper failure, storage failure, and sign-out remain distinct. A cancelled/closed helper cannot save a late session, and partial sessions are removed after cancellation or failure.

### Lustre Cloud

- The Next.js UI is backed by the live loopback agent rather than fabricated telemetry.
- Downloads, Activity, Destinations, Settings, Queue Transfer, Feed, Force Start, and PornHub auth controls call the real API.
- Auth poll/action responses are sequenced so stale polling cannot overwrite a newer sign-in, cancellation, or sign-out result.
- Browser-held bearer tokens remain in the current React session only.

## Transfer-progress implementation

`DownloadJob` persists optional active-phase telemetry while retaining the compatibility aliases `progress`, `downloadedBytes`, and `totalBytes`. The durable fields are `transferPhase`, `phaseProgress`, `phaseBytes`, `phaseTotalBytes`, `phaseTotalIsEstimated`, `phaseBytesPerSecond`, and `phaseETASeconds`.

- `YtDlpProgressEventChannel` is the sole bounded async typed-event primitive. It has open, finished, and cancelled terminal states; one identity-protected suspended consumer; direct handoff; buffer-backed FIFO/coalescing; graceful drain; abortive cancellation; and static errors only. The former duplicate mailbox source and tests are removed.
- `StreamingProcessRunner` uses fixed 16 KiB independent Darwin read loops rather than raw `AsyncStream<Data>` buffering. Stderr is incrementally decoded and parsed into the bounded channel; one separate consumer invokes callbacks serially. Success waits for child exit, both EOFs, final decoder processing, channel drain, and callback completion. Timeout, caller cancellation, decoder/channel failure, and launch failure use static errors and lifecycle cleanup/reaping.
- `PornHubYtDlp` now delegates process execution to that runner. Its materialization command adds `--newline`, `--progress`, and one strict stderr `--progress-template` for `LUSTRE_PROGRESS:v1`'s ten tab-separated fields. The component is the fixed safe `media` class. Parsed samples flow through the existing `DownloadProgress` callback; valid protocol records are excluded from diagnostics.
- Cookie-file handling remains private: each authenticated invocation receives an exclusive mode-0600 Netscape file, and its path/value never enter API output, durable jobs, logs, or diagnostics. Fake local executables cover command construction and lifecycle behavior; no real yt-dlp transfer was run.
- `AgentService` initializes local and staged yt-dlp work as `.materializing`, persists phase-aware samples without suppressing phase/total/counter-reset transitions, rejects stale materializing/post-processing callbacks after `.uploading`, and clears stale speed/ETA on phase completion or upload entry. Repeated comparable samples retain the bounded 512 KiB/0.5 second durability cadence.
- WebDAV file and direct-stream PUT paths emit `.uploading` telemetry from `URLSessionTaskDelegate.didSendBodyData`. A lock-protected coalescing reporter retains at most one latest sample and has at most one delivery task; it flushes a final exact sample only after an accepted 2xx response and stops/joins on cancellation or failure. Direct streamed PUTs use URLSession telemetry rather than competing source-read counters. TLS, redirect, authentication, and response-validation policy are unchanged.
- The Lustre Cloud frontend has one shared job contract and one phase-aware display model. Dashboard cards, the Downloads ledger, and the inspector show phase labels, determinate or indeterminate progress, exact/estimated/unknown totals, bytes, supplied speed, and supplied ETA without aggregate phase weighting or invented values. Static/terminal jobs do not animate; reduced-motion users receive a stable indeterminate segment.

Known follow-up risk: focused runner and fake-yt-dlp suites passed, but an aggregate `swift test`/strict-concurrency run intermittently hung in an existing `StreamingProcessRunner.waitForExit()` fixture when run after the wider suite. No runner redesign was made during the WebDAV pass; resolve that lifecycle-test flake before treating a new all-suite count as an acceptance snapshot.

## Verification commands

Latest recorded verification:

- Focused `StreamingProcessRunnerTests`: 8 passed.
- Focused `PornHubYtDlpTests`: 12 passed.
- `swift build -c release`: passed.
- Frontend: 33 tests passed; ESLint passed; Next.js production build and TypeScript passed.
- `git diff --check`: passed.
- A full strict-concurrency Swift run advanced through the broader suite but reproduced the documented aggregate runner-fixture hang and was terminated after its 10-minute bound; the orphaned XCTest process was explicitly cleaned up before focused verification.

Run before release:

```sh
swift test
swift build -c release
git diff --check

cd web
npm test
npm run lint
npm run build
```

Real-account/manual checks that cannot be replaced by fixtures:

1. Visible PornHub sign-in closes only after semantic validation.
2. Regular PornHub feed changes between authenticated homepage and anonymous homepage after sign-in/sign-out.
3. Subscriptions, Liked, and Favorites remain authenticated-only.
4. A PornHub yt-dlp transfer resolves and completes without exposing cookies.
5. A staged PornHub → WebDAV job must be manually confirmed to show live materialization and upload phases before completion.
