# Lustre Agent Architecture

## Current scope

Lustre Agent is a macOS 14+ local control plane for the LustreStudio download pipeline. It is intentionally a separate Swift Package, not a conversion of the SwiftUI app. The Agent owns durable job records; the browser panel and `lustre` CLI use the same loopback API.

`LustreCore` is Foundation-first. It has no SwiftUI, AppKit, WebKit, or main-actor dependency.

## Components

| Component | Responsibility |
| --- | --- |
| `LustreCore` | Public URL validation, AllPornStream metadata parsing, static provider resolution, resolved-media provenance and headers, SQLite job persistence, and the API client. |
| `LustreAgent` | Agent service, local download execution, authenticated `127.0.0.1` HTTP server, and bundled web panel. |
| `lustre-agent` | Long-running per-user executable; creates the Keychain token, binds the fixed loopback endpoint `127.0.0.1:63406`, and can generate a LaunchAgent plist. |
| `lustre` | Thin CLI client for extraction, queue mutation, status, and job actions. |
| `web` | Next.js/React/TypeScript development UI for the future hosted product; currently uses a server-side loopback bridge to exercise the real local agent API. |

### Runtime roles and packaging direction

The persistent-worker boundary is essential even though the executable packaging may change. Downloads, retries, durable scheduling, browser control, remote commands, filesystem access, and WebDAV uploads must continue after a short-lived command exits. Today `lustre-agent` provides that lifetime while `lustre` is an optional thin API client for scripting, diagnostics, token retrieval, queue mutation, and job control.

The capabilities can be shipped in one executable without collapsing those runtime roles: a future `lustre daemon` mode could host `LustreAgent` under `launchd`, while ordinary `lustre` invocations remain short-lived clients. This would remove a separately named binary and manual agent management, not the persistent local worker architecture. A foreground-only CLI would intentionally give up durable queues, browser/remote control, retry scheduling, reboot recovery, and transfers that survive terminal closure.

## Resolution contract

`StaticProviderResolver` returns a `ProviderResolution` containing the original source page, provider, trace, media qualities, request headers, and resolution method. Resolved CDN URLs are response data only: queued jobs persist the original page URL and preferred quality label so future worker, retry, and resume paths can resolve fresh media URLs.

Supported resolution paths:

- Direct media URLs: MP4, HLS, WebM, and MOV.
- AllPornStream posts: parse Next.js Flight or structured post metadata, pair provider links with embeds, retain stable provider diagnostics, resolve at most three providers concurrently, and preserve the original post URL as the durable source.
- Dood/Playmogo: trusted AllPornStream Dood aliases canonicalize to Playmogo, follow the static `pass_md5` path, construct the signed CloudAta URL, and retain `Referer`, Chrome user-agent, `Accept`, and language headers.
- MixDrop: extracts static `MDCore.wurl`, source-file, or `data-src` media configuration, falls back to the current `miiiixdrop.net` mirror only when the initial page has no usable media, and accepts only MP4 or signed `mxcontent.net/d/...` media paths.
- StreamTape: extracts static source/get-video configuration, including literal hidden `get_video` links, follows the provider redirect to `tapecontent.net`, and preserves referer and user-agent headers.

The resolver rejects private/local source URLs. A Cloudflare response is returned as `verificationRequired`; it never silently retries or pretends static resolution succeeded.

## Download execution

Creating a `destination: "local"` job durably acknowledges it as `queued` immediately, then starts an in-process download task. The worker changes it from `queued` to `running`, re-resolves the original source page immediately before transfer, selects the exact preferred label (or first available quality), and sends the resolver's headers with the media request. When the provider supplies a content length, URLSession byte callbacks persist a `0...1` progress fraction for the web panel's two-second polling loop.

- Completed files are saved under `~/Downloads/Lustre`.
- CloudAta and MixDrop requests add `Range: bytes=0-` unless the resolver already supplied a range.
- Downloads accept only video, audio, or `application/octet-stream` response types, reject non-2xx responses and undersized payloads, and never finalize typical error documents as media.
- URLSession writes to a temporary location; Lustre moves it to a `.part` file and atomically renames that to the final sanitized filename after validation.
- Pause/cancel cancels the active transfer. Resume/retry queues a fresh resolution, never an expired CDN URL.
- A `webdav:<profile-id>` destination re-resolves the source exactly like a local job, retrieves the profile password from Keychain, and uploads to the configured remote folder. Jobs and SQLite store only the profile identifier, never the password.
- Known-length compatible media streams through the local agent directly to a WebDAV `PUT` without retaining a complete local media file. Unknown-length and range-sensitive sources use safe temporary local staging, followed by upload and cleanup.
- WebDAV directory creation uses `MKCOL`; connection testing verifies authentication, directory creation, a temporary write, and deletion before a job is queued.
- Interactive browser verification remains separate from Foundation-only Core/Agent code.

## Local security and state

- The API listener is bound to `127.0.0.1` only.
- All `/v1` routes require a bearer token stored in the login Keychain under `com.pmvdl.lustre-agent`.
- Agent data is stored in `~/Library/Application Support/LustreStudioAgent/`: `jobs.sqlite3` is durable job state, `endpoint.json` records the fixed port `63406`, and `remote-destinations.json` holds non-secret WebDAV profile settings. WebDAV passwords and the API token are stored in the login Keychain. Resolved signed media URLs are never persisted.
- WebDAV TLS validation uses macOS defaults. A user may explicitly enable an invalid-certificate exception for one saved profile; the exception is limited to that profile's configured host. Redirected and unrelated hosts retain default validation.
- The intended production host is a per-user LaunchAgent, never a root daemon, because Keychain and a future user-session verification bridge require the signed-in user context.

## API

`GET /health` is unauthenticated. All other API endpoints require `Authorization: Bearer <token>`.

| Method | Route | Purpose |
| --- | --- | --- |
| `GET` | `/v1/jobs` | List durable jobs. |
| `POST` | `/v1/extract` | Resolve a URL without queueing it. |
| `POST` | `/v1/jobs` | Create a durable job from its original page URL. |
| `POST` | `/v1/folders/select` | Show a native macOS folder picker and return a validated absolute local destination. |
| `POST` | `/v1/jobs/:id/action` | Pause, resume, cancel, or retry a job. |
| `GET` | `/v1/destinations` | List saved non-secret WebDAV profiles. |
| `POST` | `/v1/destinations/webdav` | Save a WebDAV profile and its Keychain password. |
| `POST` | `/v1/destinations/:id/test` | Validate WebDAV reachability, authentication, remote write, and cleanup. |
| `DELETE` | `/v1/destinations/:id` | Delete a WebDAV profile and its Keychain password. |

## Web panel

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
- Swift's default `JSONEncoder` emits `Date` as Foundation reference-date seconds. The web boundary normalizes those numeric values while also accepting ISO-8601 strings, so sorting and time display remain compatible with a future API encoding change.

This bridge is deliberately development-only. The hosted service must not attempt to call a visitor's loopback address. Production remote control will keep the Swift agent authoritative for downloads, paths, SQLite state, and Keychain secrets while the agent establishes an outbound authenticated realtime connection to the cloud control plane. Browser account identity and paired-device identity remain separate trust domains.

## Deliberate next seams

1. Add hosted account authentication, device enrollment, revocation, and an outbound agent realtime channel without exposing the loopback API.
2. Add device enrollment/selection and server-backed pagination as job histories grow.
3. Add a configurable bounded transfer scheduler with global and per-destination concurrency limits.
4. Port Vidara's API/HLS resolver.
5. Add resumable `.part` transfers and bounded automatic re-resolution for expired media responses.
6. Isolate WebKit in a visible verification bridge for actual interactive challenges; it must not enter `LustreCore`.

## Validation

`swift test` verifies SQLite persistence, AllPornStream metadata pairing/concurrency/diagnostics, Agent-to-Core resolution wiring, Playmogo URL/header construction, MixDrop mirror/media validation, StreamTape redirect handling, Cloudflare challenge classification, and queued-job re-resolution/header handoff. `swift build -c release` validates the production executables. In `web/`, `npm test`, `npm run lint`, and `npm run build` validate agent-date compatibility, loopback proxy restrictions, Downloads filtering, destination presentation, Activity derivation/filtering, session polling settings, frontend quality, and the production Next.js bundle.
