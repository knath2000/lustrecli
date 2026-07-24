# Lustre Agent Architecture

## Current scope

Lustre Agent is a macOS 14+ local control plane for the LustreStudio download pipeline. It is intentionally a separate Swift Package, not a conversion of the SwiftUI app. The Agent owns durable job records; the browser panel and `lustre` CLI use the same loopback API.

`LustreCore` is Foundation-first. It has no SwiftUI, AppKit, WebKit, or main-actor dependency.

## Components

| Component | Responsibility |
| --- | --- |
| `LustreCore` | Public URL validation, AllPornStream metadata parsing, static provider resolution, resolved-media provenance and headers, SQLite job persistence, and the API client. |
| `LustreAgent` | Agent service, local download and yt-dlp execution, authenticated `127.0.0.1` HTTP server, and bundled web panel. |
| `lustre-agent` | Long-running per-user executable; creates the Keychain token, binds the fixed loopback endpoint `127.0.0.1:63406`, and can generate a LaunchAgent plist. |
| `lustre-auth-helper` | Short-lived visible AppKit/WebKit PornHub sign-in process with a nonpersistent website store and strict HTTPS provider navigation. |
| `lustre` | Thin CLI client for extraction, queue mutation, status, and job actions. |
| `web` | Next.js/React/TypeScript development UI for the future hosted product; currently uses a server-side loopback bridge to exercise the real local agent API. |

### Runtime roles and packaging direction

The persistent-worker boundary is essential even though the executable packaging may change. Downloads, retries, durable scheduling, browser control, remote commands, filesystem access, and WebDAV uploads must continue after a short-lived command exits. Today `lustre-agent` provides that lifetime while `lustre` is an optional thin API client for scripting, diagnostics, token retrieval, queue mutation, and job control.

The capabilities can be shipped in one executable without collapsing those runtime roles: a future `lustre daemon` mode could host `LustreAgent` under `launchd`, while ordinary `lustre` invocations remain short-lived clients. This would remove a separately named binary and manual agent management, not the persistent local worker architecture. A foreground-only CLI would intentionally give up durable queues, browser/remote control, retry scheduling, reboot recovery, and transfers that survive terminal closure.

## Resolution contract

`StaticProviderResolver` returns a `ProviderResolution` containing the original source page, provider, trace, media qualities, request headers, and resolution method. Resolved CDN URLs are response data only: queued jobs persist the original page URL and preferred quality label so future worker, retry, and resume paths can resolve fresh media URLs.

Supported resolution paths:

- Direct media URLs: MP4, HLS, WebM, and MOV.
- PornHub public video pages: accept only canonical HTTPS `pornhub.com`/`www.pornhub.com/view_video.php?viewkey=...` URLs, run an allowlisted yt-dlp binary inside `LustreAgent`, return complete audio-and-video formats only, and expose durable source URLs plus exact safe format IDs rather than signed CDN URLs. Browser-cookie import and invisible authentication are deliberately unsupported.
- AllPornStream posts: parse Next.js Flight or structured post metadata, pair provider links with embeds, retain stable provider diagnostics, resolve at most three providers concurrently, and preserve the original post URL as the durable source.
- Dood/Playmogo: trusted AllPornStream Dood aliases canonicalize to Playmogo, follow the static `pass_md5` path, construct the signed CloudAta URL, and retain `Referer`, Chrome user-agent, `Accept`, and language headers.
- MixDrop: extracts static `MDCore.wurl`, source-file, or `data-src` media configuration, falls back to the current `miiiixdrop.net` mirror only when the initial page has no usable media, and accepts only MP4 or signed `mxcontent.net/d/...` media paths.
- StreamTape: extracts static source/get-video configuration, including literal hidden `get_video` links, follows the provider redirect to `tapecontent.net`, and preserves referer and user-agent headers.
- mydaddy.cc: routes otherwise-unknown AllPornStream candidates only when their exact public host is `mydaddy.cc` or a subdomain, fetches embeds with the required `https://hqporner.com/` referer, accepts normal and backslash-escaped `<source>` attributes, deduplicates and sorts MP4 qualities, and forwards the referer and Chrome user-agent to the CDN request. A missing or incorrect referer produces the provider's misleading `This domain has been blocked` response.

Every eligible AllPornStream candidate is attempted with bounded concurrency. Failures are isolated per candidate, diagnostics remain in source order, successful qualities survive other-provider failures, and the aggregate fails only when no static candidate succeeds.

The resolver rejects private/local source URLs. A Cloudflare response is returned as `verificationRequired`; it never silently retries or pretends static resolution succeeded.

## Download execution

Creating a job durably acknowledges it as `queued` immediately. The scheduler starts at most one transfer by default and leaves later local or WebDAV jobs queued in creation order until capacity is available. A finishing, failing, paused, or cancelled worker releases its slot and starts the next durable job. The worker changes its job from `queued` to `running`, re-resolves the original source page immediately before transfer, selects the exact preferred label (or first available quality), and sends the resolver's headers with the media request. When the provider supplies a content length, URLSession byte callbacks persist a `0...1` progress fraction for the web panel's two-second polling loop.

- Completed files are saved under `~/Downloads/Lustre`.
- CloudAta and MixDrop requests add `Range: bytes=0-` unless the resolver already supplied a range.
- Downloads accept only video, audio, or `application/octet-stream` response types, reject non-2xx responses and undersized payloads, and never finalize typical error documents as media.
- URLSession writes to a temporary location; Lustre moves it to a `.part` file and atomically renames that to the final sanitized filename after validation.
- Pause/cancel cancels the active transfer. Resume/retry queues a fresh resolution, never an expired CDN URL.
- Force Start applies only to an explicitly selected queued job. It may run beside occupied ordinary capacity without changing the scheduler's global one-transfer default or starting unrelated queued jobs.
- A `webdav:<profile-id>` destination re-resolves the source exactly like a local job, retrieves the profile password from Keychain, and uploads to the configured remote folder. Jobs and SQLite store only the profile identifier, never the password.
- Known-length compatible media streams through the local agent directly to a WebDAV `PUT` without retaining a complete local media file. Unknown-length and range-sensitive sources use safe temporary local staging, followed by upload and cleanup.
- WebDAV directory creation uses `MKCOL`; connection testing verifies authentication, directory creation, a temporary write, and deletion before a job is queued.
- Interactive browser verification remains separate from Foundation-only Core/Agent code.
- PornHub yt-dlp qualities are materialized into a unique local directory with a fixed restricted output template. Local results move atomically from the private working directory; WebDAV results upload through the staged-file path and always clean staging. No shell command, arbitrary executable, raw `Cookie:` argument, or user-controlled yt-dlp argument is used.

## Local security and state

- The API listener is bound to `127.0.0.1` only.
- All `/v1` routes require a bearer token stored in the login Keychain under `com.pmvdl.lustre-agent`.
- Agent data is stored in `~/Library/Application Support/LustreStudioAgent/`: `jobs.sqlite3` is durable job state, `endpoint.json` records the fixed port `63406`, and `remote-destinations.json` holds non-secret WebDAV profile settings. WebDAV passwords and the API token are stored in the login Keychain. Resolved signed media URLs are never persisted.
- WebDAV TLS validation uses macOS defaults. A user may explicitly enable an invalid-certificate exception for one saved profile; the exception is limited to that profile's configured host. Redirected and unrelated hosts retain default validation.
- The intended production host is a per-user LaunchAgent, never a root daemon, because Keychain and a future user-session verification bridge require the signed-in user context.

## API

Feed discovery accepts a typed `FeedQuery` with site, optional text, and page. The agent constructs provider-native search URLs only from fixed trusted origins and parameters: PornHub `/video/search?search=`, HQPorner `?q=` with `p=` pagination, and AllPornStream `?s=` with `page=` pagination. The API never accepts an arbitrary provider URL.

`GET /health` is unauthenticated. All other API endpoints require `Authorization: Bearer <token>`.

| Method | Route | Purpose |
| --- | --- | --- |
| `GET` | `/v1/jobs` | List durable jobs. |
| `GET` | `/v1/auth/pornhub` | Return status-only PornHub session state. |
| `POST` | `/v1/auth/pornhub/login` | Open and await the visible provider-owned sign-in flow. |
| `DELETE` | `/v1/auth/pornhub` | Remove PornHub session state from Keychain. |
| `GET` | `/v1/feed/sites` | List normalized feed sources supported by the agent. |
| `GET` | `/v1/feed/items?site=<site>&page=N` | Fetch a normalized page from AllPornStream, HQPorner, OnlyFan420, public PornHub, or an available authenticated PornHub section. |
| `POST` | `/v1/extract` | Resolve a URL without queueing it. |
| `POST` | `/v1/jobs` | Create a durable job from its original page URL. |
| `POST` | `/v1/folders/select` | Show a native macOS folder picker and return a validated absolute local destination. |
| `POST` | `/v1/jobs/:id/action` | Pause, resume, cancel, retry, or Force Start a job. |
| `GET` | `/v1/destinations` | List saved non-secret WebDAV profiles. |
| `POST` | `/v1/destinations/webdav` | Save a WebDAV profile and its Keychain password. |
| `POST` | `/v1/destinations/:id/test` | Validate WebDAV reachability, authentication, remote write, and cleanup. |
| `DELETE` | `/v1/destinations/:id` | Delete a WebDAV profile and its Keychain password. |

## Web panel

PornHub feed cards retain canonical viewkeys, source ordering, bounded previews, parsed counts, and exact or clock-derived approximate dates. Feed redirects accept HTTPS PornHub hosts only and challenge/login pages return an explicit error. The regular PornHub source is session-aware: it sends a sanitized agent-only session to the account homepage when signed in and uses the anonymous homepage in signed-out, signing-in, or expired states. Authenticated Subscriptions, Liked, and Favorites remain separate, require a usable session, and are exposed only where the page is truthfully represented as video cards.

HQPorner feed cards retain canonical source-page URLs and truthful approximate listing dates. Static extraction validates the HTTPS HQPorner page and redirect host, selects only trusted mydaddy iframe candidates, and delegates source parsing to the shared mydaddy resolver. Resolved embed and CDN URLs remain transient and are never stored in durable jobs.

The root loopback page is an authenticated Monitor/Operate surface at `http://127.0.0.1:63406`. It holds the token in the browser tab only, queues URLs with an optional exact quality label, opens the macOS folder chooser through the authenticated local API, manages named WebDAV destinations, can test their reachability/writeability, polls job state and live percentage every two seconds, exposes only valid state actions (pause/cancel, resume, or retry), and displays each durable job's bounded worker/event log. The UI escapes all server-provided text before rendering it.

## Lustre Cloud web application

`web/` is the first implementation slice of the MyJDownloader-style product direction. It is a Next.js 16 App Router application with React, TypeScript, Tailwind CSS, and a liquid-glass design system derived from the Google Stitch workspace. The current device workspace, Downloads ledger and inspector, Destinations manager, Activity timeline, Settings surface, and Queue Transfer sheet are real operational surfaces rather than static mockups:

- The browser keeps the local agent token in React memory only; it is discarded on disconnect or tab reload.
- A server-side catch-all route forwards authenticated `/v1/*` calls only to `127.0.0.1:63406`. Path validation prevents traversal or proxying arbitrary hosts.
- Session-configurable polling displays durable jobs, byte progress, status messages, supported state actions, saved non-secret WebDAV profiles, and bounded worker logs from the Swift agent.
- The Downloads surface filters and searches the complete live job collection client-side, resolves destination profile names, and exposes a selected job's source, quality, progress, timestamps, valid actions, and complete bounded worker event log.
- The Destinations surface shows the built-in local target and saved WebDAV profiles, derives real per-target job usage, creates profiles through the authenticated agent, runs the agent's write-and-cleanup connection test, and removes profiles after explicit confirmation. Password fields are never retained after submission or returned by the agent.
- The Activity surface derives a searchable, categorized, severity-aware timeline from the bounded durable logs already attached to agent jobs. It does not fabricate device-wide events that the current API cannot provide.
- Settings controls the current browser tab's real polling cadence, manual refresh, and disconnect behavior. Unsupported agent settings are explicitly identified rather than represented by non-functional controls.
- Queue Transfer submits real `CreateJobRequest` values and can target local storage or an existing `webdav:<profile-id>` destination. WebDAV passwords remain in the agent's Keychain.
- Feed fetches normalized multi-provider cards through the agent, preserves query parameters through the authenticated Next.js proxy, supports pagination, individual or bounded batch queueing, destination selection, and job-derived transfer status. Provider thumbnails and hover images/videos use the bounded `/v1/feed/assets` proxy; object URLs are cached per source, failed sources are remembered, and object URLs are revoked on teardown.
- Swift's default `JSONEncoder` emits `Date` as Foundation reference-date seconds. The web boundary normalizes those numeric values while also accepting ISO-8601 strings, so sorting and time display remain compatible with a future API encoding change.

This bridge is deliberately development-only. The hosted service must not attempt to call a visitor's loopback address. Production remote control will keep the Swift agent authoritative for downloads, paths, SQLite state, and Keychain secrets while the agent establishes an outbound authenticated realtime connection to the cloud control plane. Browser account identity and paired-device identity remain separate trust domains.

## PornHub visible authentication

The helper keeps credentials inside a provider-owned visible nonpersistent WKWebView. Only trusted HTTPS PornHub pages may occupy the main frame; provider-controlled HTTPS subframes may operate while that trusted top-level page is active, but foreign frames cannot become the main frame and popups/downloads remain blocked. Raw WebKit cookies are bounded, filtered to exact trusted PornHub domains, and then strictly sanitized.

Current provider behavior can complete credential submission but stall its own UI because the `premium_redirect_cookie` request returns an empty body while provider JavaScript expects JSON. Lustre treats the resulting trusted `premium_redirect` cookie only as a signal to start bounded validation. It is never proof. Proof remains a sanitized `il` cookie plus explicit `isLoggedInUser === 1` on canonical `https://www.pornhub.com/subscriptions`. Cookie and navigation signals coalesce; exhaustion produces a fixed helper failure instead of an indefinitely stuck `signingIn` state.

Cancellation, helper failure, storage failure, logout, and late helper completion are isolated. Only a still-current successful helper may save a session, and cancellation/failure removes partial state. Frontend auth polls and mutations are sequence-ordered so stale polling cannot overwrite a newer action.

## Transfer-progress pipeline

`DownloadJob` has backward-compatible optional phase fields and `TransferPhase` supports resolving, downloading, materializing, post-processing, uploading, and verifying. The active-phase compatibility aliases remain `progress`, `downloadedBytes`, and `totalBytes`.

The strict internal yt-dlp progress protocol is `LUSTRE_PROGRESS:v1` with exactly ten tab-separated fields. `YtDlpProgressParser` produces only typed samples and fixed messages; `BoundedLineDecoder` handles CR/LF/CRLF incrementally; and `YtDlpProgressEventBuffer` bounds/coalesces typed samples.

`YtDlpProgressEventChannel` is the canonical bounded asynchronous layer: one waiter at a time, UUID waiter identity, direct handoff, buffer-backed delivery, cancellation-safe waiter removal, graceful finish, and abortive channel cancellation. `StreamingProcessRunner` owns fixed-size independent pipe readers, incremental stderr decoding, one bounded channel per process, and one serial callback consumer. It finishes the channel only after stderr EOF/final decode and joins work before normal completion.

`PornHubYtDlp` uses `StreamingProcessRunner` and emits the strict progress template to stderr. The agent persists phase-aware materialization samples through its existing callback path. WebDAV file and direct streamed uploads report URLSession `didSendBodyData` telemetry through a bounded coalescing reporter; final upload completion is published only after successful HTTP validation. The web client consumes only durable job telemetry and never fabricates cross-phase percentages, totals, speed, or ETA.

PornHub materialization keeps yt-dlp's subprocess output template fixed inside a private working directory. After validating that exactly one media file was produced, the agent applies the shared `FilenamePolicy`: provider title metadata is sanitized and bounded, the canonical PornHub viewkey supplies a stable collision-resistant suffix, and the real output extension is preserved. Staged WebDAV upload uses that resulting basename unchanged.

Feed search is an agent-owned extension of the structured feed contract rather than a browser-side provider request. `FeedQuery` normalizes and bounds plain-text input; each provider adapter constructs only its fixed HTTPS search URL and preserves pagination. The loopback API and Next.js proxy forward `site`, `q`, and `page`, while the React Feed view sequences requests and renders only agent-normalized items. Provider-specific query names are implementation details of `FeedService`, not arbitrary frontend-controlled URL components.

## Deliberate next seams

1. Resolve the intermittent aggregate runner-fixture hang, then renew full-suite/release acceptance counts.
2. Add hosted account authentication, device enrollment, revocation, and an outbound agent realtime channel without exposing the loopback API.
4. Add device enrollment/selection and server-backed pagination as job histories grow.
5. Make the current single-transfer scheduler limit configurable and add per-destination limits.
6. Add resumable `.part` transfers and bounded automatic re-resolution for expired media responses.

## Validation

`swift test` verifies SQLite persistence, Force Start isolation, serialized scheduling, multi-provider feeds, provider pairing and diagnostics, HLS handling, mydaddy parsing, yt-dlp format/process safety, authenticated cookie sanitization/routing, helper lifecycle, private cookie-file cleanup, WebDAV staging, cancellation, transfer-time re-resolution, feed asset proxy boundaries, auth sequencing, and the progress parser/decoder/buffer/channel/runner pipeline. `web/` tests plus lint and production build validate the proxy, feed identities/previews, auth sequencing, Force Start, live operational views, TypeScript, and the production bundle. Exact accepted counts are recorded in `CURRENT_STATUS.md` and `SESSION_LOG.md` after each release verification.
## PornHub authentication and authenticated feeds

`LustreCore` contains only the public `PornHubAuthStatus` model and feed contract. `LustreAgent` owns the private cookie store, helper process launch, redirect-safe request handling, and yt-dlp cookie-file lifecycle. `lustre-auth-helper` is a dedicated AppKit/WebKit executable with its own visible NSApplication event loop. It restricts the main frame to HTTPS PornHub, allows HTTPS subframes only under a trusted PornHub top level, rejects popups/downloads, and emits one fixed status token. It persists Codable cookie records directly to the fixed `com.pmvdl.lustre-agent` Keychain service/account only after bounded canonical-page semantic validation.

The agent derives the helper from its canonical sibling directory and never accepts a configured executable path or user-controlled helper arguments. It caps helper output/time, terminates timed-out/cancelled helpers, and does not relay stdout/stderr to any API. Auth routes remain protected by the existing loopback bearer token: `GET /v1/auth/pornhub`, `POST /v1/auth/pornhub/login`, and `DELETE /v1/auth/pornhub`.

Cookies never leave the agent except in a private HTTPS request to an exact PornHub host or in a per-invocation 0600 Netscape file passed by pathname to yt-dlp. Redirects carrying a session are denied outside trusted HTTPS PornHub hosts. Durable jobs retain only canonical PornHub page URLs and quality labels, so transfer-time resolution never persists a signed media URL or cookie-file path.

The helper's `WKWebsiteDataStore` is nonpersistent and process-local. Signing out removes the Keychain record; any helper-store cleanup only applies to the short-lived helper process and cannot claim to delete persistent WebKit data.
