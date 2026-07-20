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

The first run stores a local API token in the login Keychain and records the active loopback port under Application Support. `lustre token` prints the token for entering in the web panel.

Direct media URLs plus static Dood/Playmogo, MixDrop, and StreamTape resolution are available. Static resolution emits the request headers needed for the resolved media URL. Downloads, transfers, and a verification bridge remain separate next steps; jobs retain the original source page URL so those stages can re-resolve instead of persisting expired CDN URLs.

## API

All `/v1` endpoints require `Authorization: Bearer <token>`.

- `GET /health`
- `GET /v1/jobs`
- `POST /v1/extract` with `{"url":"https://..."}`
- `POST /v1/jobs` with `{"sourcePageURL":"https://...","preferredQualityLabel":"1080p","destination":"local"}`
- `POST /v1/jobs/:id/action` with `{"action":"pause|resume|cancel|retry"}`

## LaunchAgent

Build a release binary, create the per-user definition, then load it:

```sh
swift build -c release
.build/release/lustre-agent install "$(pwd)/.build/release/lustre-agent"
launchctl bootstrap "gui/$(id -u)" "$HOME/Library/LaunchAgents/com.pmvdl.lustre-agent.plist"
```

Do not run it as a root daemon: Keychain and eventual WebKit session access are user-session resources.
