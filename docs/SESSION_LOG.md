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

## 2026-07-22 — Feed workspace, serialized transfers, and mydaddy resolution

- Added an agent-backed AllPornStream feed contract, authenticated `/v1/feed/sites` and `/v1/feed/items` routes, matching CLI commands, defensive JSON-LD thumbnail decoding, and live pagination.
- Added the Lustre Cloud Feed workspace with normalized cards, selection, destination-aware individual/batch queueing, durable job status, and hover scene rotation. Preview URLs are deduplicated and capped at four frames to prevent malformed upstream metadata from causing excessive fetches.
- Fixed the Next.js agent proxy to preserve validated query strings, which is required for site-scoped feed pagination.
- Changed the durable worker scheduler to run one transfer at a time by default. Additional local or seedbox jobs remain queued in creation order and start when the active worker releases its slot.
- Added static mydaddy.cc resolution for otherwise-unknown AllPornStream candidates whose actual host is trusted. The provider requires `Referer: https://hqporner.com/`; without it, a working embed misleadingly returns `This domain has been blocked`.
- Added support for normal and backslash-escaped mydaddy `<source>` tags, protocol-relative HTTPS media URLs, duplicate removal, descending resolution order, and required CDN request headers.
- Preserved multi-provider partial success: candidates resolve concurrently with independent failures, original-order diagnostics, and successful qualities retained when an alternate provider fails.
- Live-verified the previously failing post at 1080p, 720p, and 360p. A ranged CDN request returned `206 Partial Content` with `Content-Type: video/mp4`.
- Final validation at this point: 47 Swift tests passed, Swift release build passed, 26 frontend tests passed, frontend lint/build passed, and `git diff --check` passed.
