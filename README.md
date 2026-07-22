# Lustre Agent

A local macOS download agent for LustreStudio-compatible extraction and transfer work.

It runs as a per-user process, binds only to `127.0.0.1`, stores job state in SQLite, and exposes the same authenticated API to a bundled web panel and the `lustre` CLI.

See [the architecture and current implementation status](docs/ARCHITECTURE.md) for module boundaries, provider behavior, and the next delivery seams.

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

The Next.js redesign lives in `web/`. It currently runs as a local development bridge to the existing authenticated agent API; it is not the future hosted remote-control service yet.

```sh
swift run lustre-agent
cd web
npm install
npm run dev
```

Open `http://localhost:3000`, run `swift run lustre token` in a separate terminal, and paste that token into the connection screen. The browser keeps it in memory only. The local Next.js route handler proxies only authenticated `/v1/*` calls to the fixed loopback agent at `127.0.0.1:63406`, so the redesigned workspace reflects live jobs, progress, durable worker logs, saved WebDAV destination names, and supported job actions. Queueing a transfer through the sheet creates a real agent job.

Direct media URLs plus static Dood/Playmogo, MixDrop, and StreamTape resolution are available. Queue acknowledgement is immediate; queued local jobs re-resolve their original source page in the background immediately before downloading, preserve the resolved media headers, write through a `.part` file, and save completed files under `~/Downloads/Lustre`. Select an exact quality label with `--quality`, for example `DOODSTREAM · Video`; omit it to use the first resolved quality. Jobs retain the original source page URL rather than persisting expired CDN URLs. Interactive browser verification remains a separate next step.

## Remote WebDAV destinations

The web panel can save named WebDAV destinations. Enter a profile name, HTTPS WebDAV base URL, username, password, and remote folder, then select it in the queue form. Passwords stay in the login Keychain; durable jobs reference only `webdav:<profile-id>` and never contain credentials.

Use **Test connection** before queueing a remote job. Lustre authenticates, creates the configured remote directory when needed, writes a uniquely named temporary file, then deletes it. A passing test confirms reachability, authentication, and write permission.

TLS validation is strict by default. If a private/self-signed certificate or an intentional IP-address endpoint cannot be corrected to use the certificate's DNS name, the profile form has an explicit **Trust an invalid certificate for this exact server** option. Enable it only for a server you control: it is scoped to that saved profile's exact host; other hosts retain normal system certificate validation.

## API

All `/v1` endpoints require `Authorization: Bearer <token>`.

- `GET /health`
- `GET /v1/jobs`
- `POST /v1/extract` with `{"url":"https://..."}`
- `POST /v1/jobs` with `{"sourcePageURL":"https://...","preferredQualityLabel":"1080p","destination":"local"}`
- `POST /v1/folders/select` opens the local macOS folder picker and returns `{"path":"/absolute/path"}`
- `POST /v1/jobs/:id/action` with `{"action":"pause|resume|cancel|retry"}`
- `GET /v1/destinations` lists saved non-secret WebDAV profiles
- `POST /v1/destinations/webdav` saves a WebDAV profile and its Keychain password
- `POST /v1/destinations/:id/test` checks WebDAV reachability, authentication, remote-directory creation, temporary write, and cleanup
- `DELETE /v1/destinations/:id` removes a saved profile and its Keychain password

## LaunchAgent

Build a release binary, create the per-user definition, then load it:

```sh
swift build -c release
.build/release/lustre-agent install "$(pwd)/.build/release/lustre-agent"
launchctl bootstrap "gui/$(id -u)" "$HOME/Library/LaunchAgents/com.pmvdl.lustre-agent.plist"
```

Do not run it as a root daemon: Keychain and eventual WebKit session access are user-session resources.
