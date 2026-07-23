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

## 2026-07-23 — Provider expansion, Force Start, PornHub, and visible authentication

- Added a per-job **Force Start** action across SQLite state, scheduler, loopback API, CLI, Downloads UI, and tests. It bypasses occupied ordinary capacity only for the selected queued job, never changes the global one-transfer default, and does not create duplicate workers.
- Added the one-page OnlyFan420 feed with durable Playmogo/Dood, LuluStream, and Vidara source links. Lulu packed-player parsing now handles the current escaped p.a.c.k.e.r argument shape. Lulu/Vidara HLS is materialized through an allowlisted `ffmpeg` process before local finalization or staged WebDAV upload.
- Added HQPorner listing support with bounded four-frame previews and durable `/hdporn/...` pages. Resolution accepts only trusted mydaddy embeds, delegates to the shared resolver, and retains the HQPorner page rather than transient embed/CDN URLs.
- Added public PornHub hot-feed parsing and canonical `view_video.php?viewkey=...` sources. Agent-owned, allowlisted `yt-dlp` metadata and materialization use argument arrays, bounded output/runtime, complete audio/video format selectors, private staging, cancellation cleanup, and transfer-time re-resolution.
- Added optional authenticated PornHub Subscriptions, Liked, and Favorites feeds. Sign-in occurs only in a separate visible `lustre-auth-helper` AppKit/WebKit process; Lustre never accepts credentials. Sanitized bounded cookies are stored in Keychain and remain agent-only.
- Hardened session handling with exact/subdomain HTTPS restrictions, RFC domain/path cookie matching, strict redirect policy, Keychain error handling, single-window concurrency, truthful expiry state, explicit logout, and exclusive mode-0600 ephemeral Netscape files for authenticated yt-dlp. No browser-cookie import or `Cookie:` process argument is used.
- Added live Settings sign-in/status/logout controls and status-only authenticated API/CLI contracts. Cookie values, names, domains, and temporary paths are not exposed to Next.js, API responses, jobs, logs, or CLI output.
- Preserved strict Vidara TLS behavior. Its metadata endpoint worked during investigation, but the returned CDN terminated TLS with `curl: (35) Send failure: Broken pipe`; the same item failed in a normal browser, so no insecure bypass or alternate-host guess was added.
- Final acceptance: 98 Swift tests and the Swift release build passed; 28 frontend tests, ESLint, TypeScript, and the Next.js production build passed; `git diff --check` passed. A read-only live PornHub public feed plus yt-dlp metadata probe passed, and the helper's non-login logout lifecycle exited cleanly. No automated or real-account login was performed.
