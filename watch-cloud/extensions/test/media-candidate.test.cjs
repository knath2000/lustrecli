const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const test = require("node:test");

require("../shared/media-candidate.js");

const { classifyMediaResponse } = globalThis.LustreMediaCapture;

test("Chrome and Firefox package the exact shared classifier", () => {
  const source = fs.readFileSync(
    path.join(__dirname, "../shared/media-candidate.js"),
    "utf8",
  );
  for (const relativePath of [
    "../lustre-watch-allpornstream/media-candidate.js",
    "../lustre-watch-allpornstream-firefox/media-candidate.js",
  ]) {
    assert.equal(
      fs.readFileSync(path.join(__dirname, relativePath), "utf8"),
      source,
    );
  }
});

test("accepts extensionless signed CloudAta video responses", () => {
  const result = classifyMediaResponse(
    "https://x319o.cloudatacdn.com/base/video~abcdefghij?token=fixture&expiry=1786682156000",
    "video/mp4",
    206,
  );
  assert.deepEqual(result, {
    url: "https://x319o.cloudatacdn.com/base/video~abcdefghij?token=fixture&expiry=1786682156000",
    mediaKind: "video",
    cloudAta: true,
  });
  assert.equal(classifyMediaResponse(
    "https://x319o.cloudatacdn.com/base/video~abcdefghij?token=fixture&expiry=1786682156000",
    "application/octet-stream",
    200,
  )?.cloudAta, true);
});

test("preserves MP4, HLS, get_video, and manifest capture", () => {
  assert.equal(classifyMediaResponse("https://media.example/video.mp4?token=x", "video/mp4", 206)?.mediaKind, "video");
  assert.equal(classifyMediaResponse("https://media.example/master.m3u8?token=x", "application/vnd.apple.mpegurl", 200)?.mediaKind, "hls");
  assert.equal(classifyMediaResponse("https://streamtape.com/get_video?id=x", "video/mp4", 200)?.mediaKind, "video");
  assert.equal(classifyMediaResponse("https://media.example/manifest?id=x", "application/x-mpegURL", 200)?.mediaKind, "hls");
});

test("rejects unsafe or untrusted extensionless responses", () => {
  for (const [url, mime, status] of [
    ["https://cloudatacdn.com.attacker.example/video~x?token=a&expiry=1", "video/mp4", 206],
    ["https://cloudatacdn.com/video~x?expiry=1", "video/mp4", 206],
    ["https://cloudatacdn.com/video~x?token=a", "video/mp4", 206],
    ["http://cloudatacdn.com/video~x?token=a&expiry=1", "video/mp4", 206],
    ["https://user:pass@cloudatacdn.com/video~x?token=a&expiry=1", "video/mp4", 206],
    ["https://media.example/extensionless", "video/mp4", 206],
    ["https://media.example/video.mp4", "text/html", 200],
    ["https://media.example/video.mp4", "video/mp4", 403],
    ["https://media.example/video.mp4", "application/octet-stream", 206],
  ]) assert.equal(classifyMediaResponse(url, mime, status), null);
});
