# Lustre Watch Provider Capture 1.4.0 for Firefox

This Firefox Manifest V3 extension provides browser-assisted AllPornStream feeds and AllPornStream, LuluVDO/LuluStream, and Playmogo/Dood playback capture for `https://lustre-watch.vercel.app`.

## Temporary installation

1. Open `about:debugging#/runtime/this-firefox`.
2. Choose **Load Temporary Add-on**.
3. Select this folder's `manifest.json`.
4. Keep Firefox open and refresh Lustre Watch.

Firefox removes temporary extensions when the browser closes. The packaged `.zip` is intended for testing or future signing through Mozilla Add-ons.

The extension opens temporary provider tabs only after an explicit feed or extraction request. Network observation is filtered to those extension-owned playback tabs. It returns only credential-free HTTPS media URLs plus bounded `Referer`, `Origin`, and `User-Agent` headers; it does not read cookies, storage, or request bodies. Version 1.4.0 recognizes Playmogo's signed extensionless CloudAta media response after validating its trusted host shape, status, and MIME type.
