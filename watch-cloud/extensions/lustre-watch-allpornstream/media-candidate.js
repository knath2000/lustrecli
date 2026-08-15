(function () {
  const HLS_MIME_TYPES = new Set([
    "application/vnd.apple.mpegurl",
    "application/x-mpegurl",
    "audio/mpegurl",
    "audio/x-mpegurl",
  ]);

  function classifyMediaResponse(value, mimeValue, status) {
    if (status !== 200 && status !== 206) return null;

    let parsed;
    try {
      parsed = new URL(value);
    } catch {
      return null;
    }

    if (
      parsed.protocol !== "https:" ||
      parsed.username ||
      parsed.password ||
      (parsed.port && parsed.port !== "443")
    ) return null;

    const hostname = parsed.hostname.toLowerCase();
    const path = parsed.pathname.toLowerCase();
    const isCloudAta =
      (hostname === "cloudatacdn.com" || hostname.endsWith(".cloudatacdn.com")) &&
      path.includes("~") &&
      parsed.searchParams.has("token") &&
      parsed.searchParams.has("expiry");
    const hasKnownURLShape =
      path.endsWith(".mp4") ||
      path.endsWith(".m3u8") ||
      path.includes("get_video") ||
      path.includes("manifest") ||
      isCloudAta;

    if (!hasKnownURLShape) return null;

    const mimeType = String(mimeValue || "")
      .split(";", 1)[0]
      .trim()
      .toLowerCase();
    const isVideo = mimeType.startsWith("video/");
    const isHLS = HLS_MIME_TYPES.has(mimeType);
    const isCloudAtaOctetStream =
      isCloudAta && mimeType === "application/octet-stream";

    if (!isVideo && !isHLS && !isCloudAtaOctetStream) return null;

    return {
      url: parsed.toString(),
      mediaKind: isHLS || path.endsWith(".m3u8") ? "hls" : "video",
      cloudAta: isCloudAta,
    };
  }

  globalThis.LustreMediaCapture = Object.freeze({
    classifyMediaResponse,
  });
})();
