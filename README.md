# Lustre Agent

A local macOS download agent for LustreStudio-compatible extraction and transfer work.

It runs as a per-user process, binds only to `127.0.0.1`, stores job state in SQLite, and exposes the same authenticated API to a bundled web panel and the `lustre` CLI.

See [the architecture](docs/ARCHITECTURE.md) for module boundaries and [the current implementation status](docs/CURRENT_STATUS.md) for accepted behavior, verification, and explicitly incomplete work.

## Development

```sh
swift run lustre-agent
swift run lustre token
swift run lustre extract https://example.com/video.mp4
swift run lustre queue https://example.com/watch-page
swift run lustre status
```

The first run stores a local API token in the login Keychain. `lustre token` prints the token for entering in the web panel. Open `http://127.0.0.1:63406`, enter that token, then queue URLs, choose a macOS folder with the native picker, and monitor job state, live download percentage, and timestamped worker/error events. The token remains only in the current browser tab. The loopback port is fixed at `63406` across agent restarts.

## Lustre Cloud web UI (development)

The Next.js redesign lives in `web/`. It currently runs as a local development bridge to the existing authenticated agent API; it is not the future hosted remote-control service yet. Its live operational surfaces cover the device workspace, durable Downloads ledger and Transfer Inspector, WebDAV Destinations management, a searchable Activity timeline derived from worker logs, session-scoped Settings, the Queue Transfer sheet, and an agent-backed AllPornStream Feed with pagination, selection, destination handoff, and hover scene previews.

```sh
swift run lustre-agent
cd web
npm install
npm run dev
```

Open `http://localhost:3000`, run `swift run lustre token` in a separate terminal, and paste that token into the connection screen. The browser keeps it in memory only. The local Next.js route handler proxies only authenticated `/v1/*` calls to the fixed loopback agent at `127.0.0.1:63406`, so every operational surface reflects live agent state. Queueing a transfer through the sheet creates a real durable job; destination creation, connection testing, deletion, and job actions call the real agent API.

## Runtime roles

`lustre-agent` is the persistent local worker. It owns provider resolution, downloads, retries, SQLite state, filesystem access, WebDAV transfers, Keychain secrets, progress, and the authenticated loopback API. The web UI and `lustre` CLI are clients of that service; neither owns transfer execution.

`lustre` is intentionally a thin optional administrative client for scripting, diagnostics, token retrieval, queue operations, and job control. A future packaging simplification may ship one `lustre` binary with a persistent `lustre daemon` mode managed by `launchd`, but durable background execution must remain a persistent local process even if the separate `lustre-agent` executable name is removed.

Direct media URLs plus static Dood/Playmogo, MixDrop, StreamTape, mydaddy.cc, LuluStream, and Vidara resolution are available. mydaddy embeds are fetched with their required HQPorner request context, support normal or escaped `<source>` attributes, deduplicate qualities, and preserve media headers. AllPornStream resolves supported candidates concurrently, retains per-provider failures, and keeps successful qualities when another provider fails.

PornHub and HQPorner are available through the generic feed API and web Feed selector. PornHub keeps canonical `view_video.php?viewkey=...` sources and does not expose an iframe or import browser cookies. The regular PornHub source uses the authenticated account homepage while signed in and the anonymous homepage otherwise; Subscriptions, Liked, and Favorites remain separate authenticated-only sources. Feed thumbnails and hover previews are fetched through the authenticated loopback agent, which only accepts HTTPS provider CDN hosts, sends fixed provider Referer/User-Agent headers without cookies, rejects unsafe redirects and unexpected media types, and enforces small image/video response limits. PornHub extraction and transfer require `yt-dlp` at `/opt/homebrew/bin/yt-dlp`, `/usr/local/bin/yt-dlp`, or `/opt/local/bin/yt-dlp`; the Agent persists only the source page and exact format label/ID, then re-runs yt-dlp at transfer time.

HQPorner listing pages expose durable `/hdporn/...` source URLs, scene previews capped at four, zero views unless the site supplies a count, and explicitly approximate listing dates. Resolution accepts only canonical HTTPS HQPorner video pages and trusted mydaddy embeds, then delegates media parsing to the existing mydaddy resolver while retaining the HQPorner page as the durable job source.

OnlyFan420 is exposed as a one-page feed backed by `https://rentry.co/OnlyFan420`. Page 1 includes supported LuluStream, Vidara, Playmogo, and Dood provider links; later pages return an empty terminal page. Feed inclusion indicates that the provider has a resolver, not that every upstream CDN is operational, so individual items can still fail safely during resolution or transfer.

LuluStream and Vidara resolve HLS playlists. The agent re-resolves the durable provider page immediately before transfer and materializes HLS as MP4 before local finalization or WebDAV upload. This requires `ffmpeg` at `/opt/homebrew/bin/ffmpeg`, `/usr/local/bin/ffmpeg`, `/opt/local/bin/ffmpeg`, or `/usr/bin/ffmpeg`.

Queue acknowledgement is immediate. The durable scheduler runs one transfer at a time by default; additional local or WebDAV jobs remain queued in creation order until the active transfer exits. Each worker re-resolves the original source page immediately before downloading, preserves the resolved media headers, writes through a `.part` file, and saves completed local files under `~/Downloads/Lustre`. Select an exact quality label with `--quality`, for example `DOODSTREAM · Video`; omit it to use the first resolved quality. Jobs retain the original source page URL rather than persisting expired CDN URLs. Interactive browser verification remains a separate next step.

## Remote WebDAV destinations

The web panel can save named WebDAV destinations. Enter a profile name, HTTPS WebDAV base URL, username, password, and remote folder, then select it in the queue form. Passwords stay in the login Keychain; durable jobs reference only `webdav:<profile-id>` and never contain credentials.

Use **Test connection** before queueing a remote job. Lustre authenticates, creates the configured remote directory when needed, writes a uniquely named temporary file, then deletes it. A passing test confirms reachability, authentication, and write permission.

TLS validation is strict by default. If a private/self-signed certificate or an intentional IP-address endpoint cannot be corrected to use the certificate's DNS name, the profile form has an explicit **Trust an invalid certificate for this exact server** option. Enable it only for a server you control: it is scoped to that saved profile's exact host; other hosts retain normal system certificate validation.

## Transfer progress status

Direct Foundation transfers report live bytes and percentage when the provider supplies a usable length. Phase-aware durable fields, a strict `LUSTRE_PROGRESS:v1` parser, bounded CR/LF line decoding, a typed event coalescer/mailbox, and a standalone readiness-driven process-runner experiment now exist for yt-dlp work. They are intentionally **not integrated** into `PornHubYtDlp.run()` yet: cancellation-safe mailbox delivery, runner lifecycle/backpressure coverage, WebDAV `didSendBodyData`, and phase-aware frontend rendering remain incomplete. Staged PornHub/WebDAV jobs must not be described as having live percentage until those seams are finished. See [CURRENT_STATUS.md](docs/CURRENT_STATUS.md).

## API

All `/v1` endpoints require `Authorization: Bearer <token>`.

- `GET /health`
- `GET /v1/jobs`
- `GET /v1/auth/pornhub`
- `POST /v1/auth/pornhub/login`
- `DELETE /v1/auth/pornhub/login` cancels a visible sign-in in progress
- `DELETE /v1/auth/pornhub`
- `GET /v1/feed/sites`
- `GET /v1/feed/items?site=allpornstream|hqporner|onlyfan420|pornhub|pornhub-subscriptions|pornhub-liked|pornhub-favorites&page=1`
- `GET /v1/feed/assets?url=https%3A%2F%2F...&kind=image|video` fetches a tightly allowlisted provider thumbnail or preview through the authenticated agent
- `POST /v1/extract` with `{"url":"https://..."}`
- `POST /v1/jobs` with `{"sourcePageURL":"https://...","preferredQualityLabel":"1080p","destination":"local"}`
- `POST /v1/folders/select` opens the local macOS folder picker and returns `{"path":"/absolute/path"}`
- `POST /v1/jobs/:id/action` with `{"action":"pause|resume|cancel|retry|forceStart"}`
- `GET /v1/destinations` lists saved non-secret WebDAV profiles
- `POST /v1/destinations/webdav` saves a WebDAV profile and its Keychain password
- `POST /v1/destinations/:id/test` checks WebDAV reachability, authentication, remote-directory creation, temporary write, and cleanup
- `DELETE /v1/destinations/:id` removes a saved profile and its Keychain password

The CLI mirrors feed discovery with `lustre feed sites` and `lustre feed list --site pornhub --page 1`.

## LaunchAgent

Build a release binary, create the per-user definition, then load it:

```sh
swift build -c release
.build/release/lustre-agent install "$(pwd)/.build/release/lustre-agent"
launchctl bootstrap "gui/$(id -u)" "$HOME/Library/LaunchAgents/com.pmvdl.lustre-agent.plist"
```

Do not run it as a root daemon: Keychain and eventual WebKit session access are user-session resources.
## PornHub sign-in boundary

PornHub sign-in is optional and is always performed in a separate visible macOS window owned by `lustre-auth-helper`. Lustre never receives, renders, or submits a username or password. Cookie-store changes trigger validation after AJAX login; the helper persists a session only when the trusted subscriptions page explicitly reports an authenticated user and a sanitized session cookie is present. Missing or ambiguous provider state fails closed, and an anonymous successful response is not accepted as proof. The loopback API, CLI, Next.js panel, job records, and logs never return cookie values.

Use `lustre auth status`, `lustre auth login`, and `lustre auth logout`, or the Settings control. `login` opens the visible window and returns `signingIn`; status reports completion, timeout, cancellation, or a session-expiry signal without provider telemetry. The Settings control can cancel an in-progress login. `login` requires the built `lustre-auth-helper` executable beside `lustre-agent`; existing running agents must be restarted manually after review to activate it. Logout removes the Keychain state. The helper uses a process-local nonpersistent WebKit store, so Lustre has no persistent WebKit browser state to remove.

The regular PornHub feed is session-aware: it requests the account homepage with the private agent session when signed in and the anonymous homepage while signed out, signing in, or expired. Authenticated feed sources separately expose Subscriptions, Liked, and Favorites; playlists are deliberately not advertised because their directory shape is not a truthful video-card feed. Auth cookies are sent only to matching HTTPS `pornhub.com` hosts. yt-dlp receives a unique mode-0600 temporary Netscape cookie file immediately before a PornHub invocation; its path is removed on completion, failure, or cancellation. Lustre never uses `--cookies-from-browser` or a `Cookie:` process argument.
