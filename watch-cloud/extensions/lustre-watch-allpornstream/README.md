# Lustre Watch Provider Capture 1.4.0

1. Open `chrome://extensions`.
2. Enable **Developer mode**.
3. Choose **Load unpacked** and select this folder.
4. Keep the extension enabled while using `https://lustre-watch.vercel.app`.

The extension activates only when Lustre Watch requests browser assistance. For a challenged feed, it opens AllPornStream, extracts bounded JSON-LD card metadata, returns it to the signed-in page, and closes the tab. For playback, it opens a temporary AllPornStream, LuluVDO/LuluStream, or Playmogo/Dood provider tab, attaches Chrome network capture only to that tab, returns the first credential-free HTTPS media response with bounded playback headers, then detaches and closes the tab. Version 1.4.0 recognizes Playmogo's signed extensionless CloudAta media response after validating its trusted host shape, status, and MIME type.

It does not send cookies, page storage, request bodies, or browsing history to Lustre Watch.
