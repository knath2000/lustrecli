# Session Log

## 2026-07-20 — Agent bootstrap, aggregate resolution, and local downloads

- Created the macOS Swift Package with `LustreCore`, `LustreAgent`, `lustre-agent`, and `lustre` products.
- Added a loopback-authenticated HTTP API, Keychain-backed token, SQLite job persistence, local web panel, and LaunchAgent plist generator.
- Ported Foundation-only direct, Dood/Playmogo, MixDrop, and StreamTape resolution into `StaticProviderResolver`.
- Added AllPornStream Next.js/structured metadata parsing, embed pairing, provider diagnostics, three-provider concurrency limiting, and 15-second per-provider timeouts.
- Added Playmogo/Dood `pass_md5` signed CloudAta construction; MixDrop fallback to the current mirror and signed-media validation; and StreamTape hidden `get_video`/redirect handling.
- Preserved original page URLs in queue payloads and response-level media provenance/headers for fresh re-resolution rather than persisting expired CDN URLs.
- Added local job execution: queued jobs re-resolve the source, preserve quality headers, validate media responses, atomically finalize output under `~/Downloads/Lustre`, and update durable job state.
- Kept interactive verification outside the core: Cloudflare is reported as `verificationRequired`.
- Validated with `swift test` (24 passing tests at that point), `swift build -c release`, and a live AllPornStream job that reached `running` while downloading the resolved `DOODSTREAM · Video` quality.
