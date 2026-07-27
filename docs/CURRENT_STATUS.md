# Current implementation status

Last updated: 2026-07-26

This document records the accepted behavior in the current `main` working tree, including the pieces that are intentionally still incomplete. `ARCHITECTURE.md` remains the component-level design reference; `SESSION_LOG.md` records the delivery chronology.

## Production-ready behavior in this revision

- Feed search is provider-native for PornHub, HQPorner, and AllPornStream. It does not expose unverified sort, date, duration, or view controls.

### Durable local agent

- `lustre-agent` is the persistent per-user worker. It owns SQLite jobs, fresh provider resolution, transfer execution, retries, local filesystem access, WebDAV, Keychain secrets, and the authenticated loopback API.
- The listener remains fixed to `127.0.0.1:63406`; all `/v1` routes require the Keychain-backed bearer token.
- Jobs preserve source page URLs and optional exact quality labels. Signed CDN URLs are resolved again immediately before transfer and are not persisted.
- The default scheduler runs one ordinary transfer at a time. Later jobs remain queued in creation order; Force Start applies only to the explicitly selected queued job.

### Providers and feeds

- Static/direct resolution supports direct media, AllPornStream, Playmogo/Dood, MixDrop, StreamTape, mydaddy.cc, LuluStream/Vidara HLS, HQPorner, OnlyFan420, and PornHub through agent-owned yt-dlp.
- MixDrop remains Foundation-only: original host first, then the known mirror only after transport failure or unusable HTML. The resolver accepts only strict `mxcontent.net` media paths and forwards the resolved page as Referer with the Chrome user agent. The same source has been verified to resolve statically on a compatible VPN route; a home-route TLS failure occurs before HTTP and is reported as an actionable transport failure without weakening TLS.
- Feed sources include AllPornStream, HQPorner, OnlyFan420, PornHub, and—while authenticated—PornHub Subscriptions, Liked, and Favorites.
- OnlyFan420 converts its large upstream listing into stable 50-item logical pages while preserving source order and the existing 65,536-byte Feed acknowledgement ceiling.
- AllPornStream Feed reads use a restricted nonpersistent WebKit helper because the provider presents a browser challenge to plain HTTP clients. `lustre feed verify --site allpornstream` opens the provider locally for user verification and stores only bounded provider-scoped clearance cookies in Keychain; those cookies never leave the Mac.
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

- Slice 1 is implemented and deployed: Clerk authenticates browser users; Lustre-owned accounts, devices, pairing challenges, enrollment/session challenges, audits, and revocation live in Neon through Drizzle migrations. Device signatures use one permanent macOS Keychain P-256 key and deterministic, domain-separated envelopes. Local `lustre cloud disconnect` only removes local enrollment metadata.
- The durable transport is a dedicated Cloudflare Worker plus Durable Object gateway. The enrolled agent obtains a fresh signed session, opens the outbound WebSocket, receives `gateway_hello_ack`, and then sends bounded sequenced heartbeats. The Durable Object accepts the socket before parsing application data, restores per-socket attachment metadata after hibernation, rejects malformed or stale messages with stable `4400` close reasons, and sends a local heartbeat acknowledgement before any Vercel request.
- Heartbeats are capped at 131,072 bytes and require strict UTF-8, a valid JSON envelope, a monotonic per-connection sequence, and the complete versioned heartbeat schema. Feed result acknowledgements are separately capped at 65,536 bytes. Rejected messages are neither acknowledged nor serialized.
- The gateway relays accepted heartbeats asynchronously to authenticated Vercel control-plane routes with a bounded timeout. Relay failure does not disconnect the agent or delay the local acknowledgement. Vercel persists truthful presence, all 29 durable job projections, and command receipts in Neon at wire timestamp precision.
- Outbound command selection is intentionally allowlisted to `feed_sites`, gated `feed_page`, and separately negotiated/gated `destinations_list` plus `queue_url`. Durable receipt replay survives hibernation and transient command-row or relay failures. Feed queue delivery requires negotiated `feed-queue-v1`; download mutation and every other command type remain disabled until they receive equivalent end-to-end acceptance.
- Feed command creation is cached-first and coalesces identical pending/running requests. Exact device/site/query/page results are classified fresh through five minutes and stale through 60 minutes. Cached metadata may render immediately, but queue controls remain disabled until the live refresh succeeds.
- Realtime agents negotiate `command-wake-v1`. After Neon commits a command, Vercel sends a bounded timestamped HMAC notification containing only device and command IDs to the gateway. The device Durable Object wakes its negotiated hibernating sockets with a payload-free `command-available` frame; the agent's single receive pump triggers the normal heartbeat immediately, with the existing 30-second heartbeat retained as fallback.
- Failed commands persist only an optional fixed safe failure code. Provider verification, HTTP, reachability, provider-change, authentication, size, and invalid-request failures map to actionable dashboard text; older agents remain compatible as `unknown`.
- The production Cloud dashboard at `https://lustrecli.vercel.app` is Clerk-gated, reads paired-agent state through authenticated Vercel HTTP, and never calls `127.0.0.1:63406` or sees the loopback token, provider cookies, Keychain secrets, raw WebDAV credentials, or transient media URLs.
- Cloud Downloads and Activity show agent-projected original source-page URLs. Presence is truthful (`online`, `offline`, `neverConnected`, or `revoked`) and does not overstate storage, latency, or transfer availability.
- Cloud Feed metadata browsing is implemented behind the exact `LUSTRE_CLOUD_FEED_ENABLED=true` flag. Requests are coalesced by canonical source/query/page keys, stale results cannot replace newer ones, pagination and normalized search preserve existing cards, and destination/selection/queue controls remain gated. Public Production currently has no Feed navigation or rendering.
- The temporary `/feed-acceptance` canary requires an exact Clerk subject plus an explicit kill switch. It is disabled in the final production deployment and returns `404`, including for the previously allowlisted account.
- Protected Feed media uses short-lived, device-bound Vercel tickets and the separate `lustre-feed-assets` Cloudflare Worker. Tickets bind the exact URL and media kind; the Worker enforces HTTPS provider-host allowlists, exact production CORS, safe redirects, expected content types, 6 MiB image and 16 MiB video limits, a 20-second upstream timeout, no credential forwarding, and `no-store` responses. The browser makes no direct protected-provider request.
- K2 production acceptance rendered 50 protected HQPorner thumbnails, advanced a four-scene hover preview, and rendered 42 protected PornHub thumbnails. Blocking the asset Worker preserved metadata, agent connectivity, 29 unchanged jobs, and zero active transfers.
- K4 adds individual-card Feed queueing with one browser-generated request UUID retained across retry, exact account/device Feed-result provenance, recent destination provenance, canonical payload enforcement, and caller-supplied job IDs. Crash-window replay validates the immutable job/source/destination tuple and returns the existing job rather than creating a second transfer.
- K4 production acceptance forced acknowledgement persistence failure after one HQPorner queue command to Seedbox3. Neon temporarily showed the command running without an acknowledgement while SQLite contained exactly one matching job. Restoring persistence completed the same command and projected the same job ID; there was exactly one `queue_url` command, one durable job, and no duplicate transfer. The transfer completed before cancellation, its exact 1,112,455,608-byte remote file was verified and deleted, and Seedbox3 subsequently returned `404` for that path.
- Current production artifacts are Vercel deployment `dpl_14Hfc1R6jxpRkSSRszLYwK9qaKv9`, gateway version `7a405308-4aa3-4fb5-ae42-9b2d5e99f215` at `lustre-gateway.knath2000.workers.dev`, and asset Worker version `b9df82c1-f26c-42e2-841d-88229016ff19` at `lustre-feed-assets.knath2000.workers.dev`. Feed, destinations, queueing, media, and command wake are enabled in Production. The user subsequently completed manual Production testing and reported the near-instant Feed/provider-recovery rollout working successfully.

- The Next.js UI is backed by the live loopback agent rather than fabricated telemetry.
- Downloads, Activity, Destinations, Settings, Queue Transfer, Feed, Force Start, and PornHub auth controls call the real API.
- Auth poll/action responses are sequenced so stale polling cannot overwrite a newer sign-in, cancellation, or sign-out result.
- Browser-held bearer tokens remain in the current React session only.
- AllPornStream, HQPorner, and PornHub expose agent-owned provider-native search. Search text is normalized and bounded, provider URLs are constructed from fixed trusted origins, pagination preserves the active query, and the Next.js proxy preserves the complete query string. AllPornStream uses its current `s` parameter, HQPorner uses `q`, and PornHub uses `/video/search?search=...`.
- The Feed toolbar keeps source, search, destination, and refresh controls in a deliberate primary grid with a separate result/query metadata row. Search is a horizontal compound control; clearing an active query reloads the ordinary feed; desktop, medium, and mobile layouts use explicit grid areas.

### PornHub output naming

- Agent-owned yt-dlp still writes to a private fixed working template, then Lustre moves the single validated output through the shared `FilenamePolicy`.
- Final PornHub filenames use the sanitized metadata title plus the validated PornHub viewkey-derived stable suffix and the actual materialized extension. This replaces the collision-prone generic `Lustre-PornHub.mp4` name while preserving deterministic output discovery and path safety.
- Staged WebDAV upload preserves that materialized filename. Existing remote-file collision behavior remains ordinary WebDAV `PUT` semantics; Lustre does not perform a remote existence check or conditional rename.

## Transfer-progress implementation

`DownloadJob` persists optional active-phase telemetry while retaining the compatibility aliases `progress`, `downloadedBytes`, and `totalBytes`. The durable fields are `transferPhase`, `phaseProgress`, `phaseBytes`, `phaseTotalBytes`, `phaseTotalIsEstimated`, `phaseBytesPerSecond`, and `phaseETASeconds`.

- `YtDlpProgressEventChannel` is the sole bounded async typed-event primitive. It has open, finished, and cancelled terminal states; one identity-protected suspended consumer; direct handoff; buffer-backed FIFO/coalescing; graceful drain; abortive cancellation; and static errors only. The former duplicate mailbox source and tests are removed.
- `StreamingProcessRunner` uses fixed 16 KiB independent Darwin read loops rather than raw `AsyncStream<Data>` buffering. Stderr is incrementally decoded and parsed into the bounded channel; one separate consumer invokes callbacks serially. Success waits for child exit, both EOFs, final decoder processing, channel drain, and callback completion. Timeout, caller cancellation, decoder/channel failure, and launch failure use static errors and lifecycle cleanup/reaping.
- `PornHubYtDlp` now delegates process execution to that runner. Its materialization command adds `--newline`, `--progress`, and one strict stderr `--progress-template` for `LUSTRE_PROGRESS:v1`'s ten tab-separated fields. The component is the fixed safe `media` class. Parsed samples flow through the existing `DownloadProgress` callback; valid protocol records are excluded from diagnostics.
- Cookie-file handling remains private: each authenticated invocation receives an exclusive mode-0600 Netscape file, and its path/value never enter API output, durable jobs, logs, or diagnostics. Fake local executables cover command construction and lifecycle behavior. A real staged PornHub transfer subsequently confirmed materialization telemetry, title/viewkey output naming, and live WebDAV upload telemetry without exposing session data.
- `AgentService` initializes local and staged yt-dlp work as `.materializing`, persists phase-aware samples without suppressing phase/total/counter-reset transitions, rejects stale materializing/post-processing callbacks after `.uploading`, and clears stale speed/ETA on phase completion or upload entry. Repeated comparable samples retain the bounded 512 KiB/0.5 second durability cadence.
- WebDAV file and direct-stream PUT paths emit `.uploading` telemetry from `URLSessionTaskDelegate.didSendBodyData`. A lock-protected coalescing reporter retains at most one latest sample and has at most one delivery task; it flushes a final exact sample only after an accepted 2xx response and stops/joins on cancellation or failure. Direct streamed PUTs use URLSession telemetry rather than competing source-read counters. TLS, redirect, authentication, and response-validation policy are unchanged.
- The Lustre Cloud frontend has one shared job contract and one phase-aware display model. Dashboard cards, the Downloads ledger, and the inspector show phase labels, determinate or indeterminate progress, exact/estimated/unknown totals, bytes, supplied speed, and supplied ETA without aggregate phase weighting or invented values. Static/terminal jobs do not animate; reduced-motion users receive a stable indeterminate segment.

Known follow-up risk: an earlier aggregate strict-concurrency run intermittently hung in a `StreamingProcessRunner.waitForExit()` fixture. The current full suite completed cleanly, including all runner lifecycle tests, but the prior intermittent result remains worth monitoring rather than declaring impossible from one clean aggregate run.

## Verification commands

Latest recorded verification:

- The last Cloud command-delivery acceptance passed 183 Swift tests. K1 later encountered an intermittent process-fixture aggregate flake; all 8 affected tests passed on immediate rerun. K2 did not change or restart the agent.
- Frontend: 72 tests passed; TypeScript and the Next.js production build passed.
- K4 focused Swift acceptance passed 6 caller-ID and Cloud remote-control tests; an isolated Swift release build passed. The pre-existing aggregate SwiftPM build lock was left untouched.
- Gateway: 5 tests and static/type checks passed before deployment of version `06da3333-b17e-4d78-98a2-6cce2801c251`.
- Near-instant Feed validation passed 10 focused Swift tests, 73 web tests and the Next.js production build, plus 5 gateway tests and static/type checks. Production migration `0006_lustre_feed_command_cache` applied successfully; the restarted agent negotiated `command-wake-v1` after zero active transfers were confirmed.
- Asset Worker: 5 tests, typecheck, Wrangler dry run, production deployment, and unauthenticated `401` probe passed.
- Gateway tests, static checks, and Wrangler dry run passed before the K1/K1.1 canaries; the gateway was unchanged in K2.
- K2 browser acceptance verified 50 HQPorner and 42 PornHub protected thumbnails, a four-scene hover preview, zero direct protected-provider requests, and graceful metadata-only degradation when the asset Worker was blocked.
- The unrelated pre-existing lint errors in `cloud-dashboard-view.tsx` and `cloud-home-view.tsx` remain unchanged; do not record the repository-wide lint command as green until those are repaired.
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
4. Repeat real-account PornHub transfer checks after material provider/yt-dlp changes; the current revision has been observed resolving and materializing without exposing cookies.
5. Repeat staged PornHub → WebDAV telemetry checks after transport changes; the current revision has been observed reporting both live materialization and upload phases.
