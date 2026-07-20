# Lustre Agent Architecture

## Current scope

Lustre Agent is a macOS 14+ local control plane for the LustreStudio download pipeline. It is intentionally a separate Swift Package, not a conversion of the SwiftUI app. The Agent owns durable job records; the browser panel and `lustre` CLI use the same loopback API.

`LustreCore` is Foundation-first. It has no SwiftUI, AppKit, WebKit, or main-actor dependency.

## Components

| Component | Responsibility |
| --- | --- |
| `LustreCore` | Public URL validation, static provider resolution, resolved-media provenance and headers, SQLite job persistence, and the API client. |
| `LustreAgent` | Agent service, authenticated `127.0.0.1` HTTP server, and bundled web panel. |
| `lustre-agent` | Long-running per-user executable; creates the Keychain token, writes the active endpoint, and can generate a LaunchAgent plist. |
| `lustre` | Thin CLI client for extraction, queue mutation, status, and job actions. |

## Resolution contract

`StaticProviderResolver` returns a `ProviderResolution` containing the original source page, provider, trace, media qualities, request headers, and resolution method. Resolved CDN URLs are response data only: queued jobs persist the original page URL and preferred quality label so future worker, retry, and resume paths can resolve fresh media URLs.

Supported static paths:

- Direct media URLs: MP4, HLS, WebM, and MOV.
- Dood/Playmogo: follows the static `pass_md5` path, constructs the CloudAta URL, and retains `Referer`, Chrome user-agent, `Accept`, and language headers.
- MixDrop: extracts static `MDCore.wurl`, source-file, or `data-src` media configuration and retains its media headers.
- StreamTape: extracts static source/get-video configuration and preserves referer and user-agent headers.

The resolver rejects private/local source URLs. A Cloudflare response is returned as `verificationRequired`; it never silently retries or pretends static resolution succeeded.

## Local security and state

- The API listener is bound to `127.0.0.1` only.
- All `/v1` routes require a bearer token stored in the login Keychain under `com.pmvdl.lustre-agent`.
- Agent data is stored in `~/Library/Application Support/LustreStudioAgent/`: `jobs.sqlite3` is durable job state and `endpoint.json` carries only the active loopback port.
- The intended production host is a per-user LaunchAgent, never a root daemon, because Keychain and a future user-session verification bridge require the signed-in user context.

## API

`GET /health` is unauthenticated. All other API endpoints require `Authorization: Bearer <token>`.

| Method | Route | Purpose |
| --- | --- | --- |
| `GET` | `/v1/jobs` | List durable jobs. |
| `POST` | `/v1/extract` | Resolve a URL without queueing it. |
| `POST` | `/v1/jobs` | Create a durable job from its original page URL. |
| `POST` | `/v1/jobs/:id/action` | Pause, resume, cancel, or retry a job. |

## Deliberate next seams

1. Add provider-metadata parsing for AllPornStream and route trusted `hosting_provider` records into the static resolver.
2. Port Vidara's API/HLS resolver.
3. Add the scheduler, download workers, validation, and destination transfers behind the existing durable job model.
4. Isolate WebKit in a visible verification bridge for actual interactive challenges; it must not enter `LustreCore`.

## Validation

`swift test` currently verifies SQLite persistence, Agent-to-Core resolution wiring, Playmogo URL/header construction, MixDrop resolution, StreamTape resolution, and Cloudflare challenge classification. `swift build -c release` validates the production executables.
