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

## Transfer-progress work: deliberately incomplete

The existing transfer API still shows only legacy progress for paths that emit `DownloadProgress`. For staged PornHub yt-dlp materialization and completion-only WebDAV upload, full live telemetry is **not integrated yet**.

Implemented foundations:

- Backward-compatible `TransferPhase` and optional per-phase durable fields.
- Phase-aware validated `DownloadProgress` fields for bytes, total, estimated-total flag, speed, and ETA.
- Staged jobs persist materializing and uploading transitions; upload starts with zero bytes and the exact local file size.
- `LUSTRE_PROGRESS:v1` is a strict versioned tab protocol with exactly ten fields: status, downloaded bytes, exact total, estimated total, speed, ETA, fragment index/count, and a bounded component class.
- `YtDlpProgressParser` accepts only enumerated status/component grammar, fixed safe messages, bounded finite numbers, coherent fragments, strict UTF-8/control characters, and exact version/field count.
- `BoundedLineDecoder` handles LF, CR, and CRLF incrementally with bounded partial-line storage and deterministic failure after overflow.
- `YtDlpProgressEventBuffer` is a pure bounded typed-event coalescer preserving the first sample, latest same-category sample, FIFO transitions, and final state; pathological transition overflow fails statically rather than growing without bound.
- `YtDlpProgressEventMailbox` currently provides initial actor-based open/closed/failed/cancelled behavior and one suspended waiter.
- `StreamingProcessRunner` is a standalone readiness-driven experiment. Independent stdout/stderr `FileHandle.readabilityHandler`s are installed before launch, a causal fixture proves a progress callback can occur before child exit, recognized progress is excluded from bounded diagnostics, and retention caps do not intentionally stop pipe drainage.

Not yet accepted or integrated:

- The mailbox still needs cancellation-safe waiter removal and deterministic multi-consumer/race coverage.
- The standalone runner still needs bounded typed-event mailbox integration, cancellation/timeout/reaping tests, slow-callback backpressure proof, partial/CR/EOF tests, and exact cap coverage.
- `PornHubYtDlp.run()` still uses the existing EOF-oriented implementation and does not use `StreamingProcessRunner` or `--progress-template`.
- Live `URLSessionTaskDelegate.didSendBodyData` WebDAV upload progress is not implemented.
- Lustre Cloud does not yet render phase-specific estimated totals, speed, or ETA.
- PornHub materialized output still uses the generic `Lustre-PornHub.mp4` name; resolved-title filename sanitization remains future work.

Do not describe this revision as providing live staged yt-dlp/WebDAV percentage. The current scaffolding is intentionally isolated until its lifecycle guarantees and integration tests are complete.

## Verification commands

Accepted verification snapshot for this revision:

- `swift test`: 132 tests passed, 0 failed.
- `swift build -c release`: passed.
- `web/npm test`: 34 tests passed, 0 failed.
- `web/npm run lint`: passed.
- `web/npm run build`: passed.
- `git diff --check`: passed.

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
5. After progress integration is finished, a staged PornHub → WebDAV job must show live materialization and upload phases before completion.
