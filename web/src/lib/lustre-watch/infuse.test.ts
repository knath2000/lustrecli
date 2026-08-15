import assert from "node:assert/strict";
import test from "node:test";
import { infuseFilename, infusePlaybackURL } from "./infuse.ts";

test("Infuse deep links encode media URLs and Unicode exactly once", () => {
  const mediaURL = "https://media.example/video file.mp4?token=a+b&name=café";
  const result = new URL(infusePlaybackURL("Café & Friends", {
    label: "1080p",
    url: mediaURL,
    mediaKind: "video",
    headers: { Referer: "https://example.com/" },
  }));
  assert.equal(result.protocol, "infuse:");
  assert.equal(result.hostname, "x-callback-url");
  assert.equal(result.pathname, "/play");
  assert.equal(result.searchParams.get("url"), new URL(mediaURL).href);
  assert.equal(result.searchParams.get("filename"), "Café & Friends.mp4");
  assert.equal(result.searchParams.has("Referer"), false);
});

test("Infuse filenames remove separators and control characters", () => {
  assert.equal(infuseFilename("  Folder/Scene\\Name\u0000\n  ", "video"), "Folder Scene Name.mp4");
  assert.equal(infuseFilename("Playlist.mp4", "hls"), "Playlist.m3u8");
  assert.equal(infuseFilename("", "video"), "Lustre Watch.mp4");
});

test("Infuse filenames are bounded without splitting Unicode", () => {
  const filename = infuseFilename("🎬".repeat(140), "video");
  assert.equal(Array.from(filename.replace(/\.mp4$/, "")).length, 120);
  assert.equal(filename.endsWith(".mp4"), true);
});

test("Infuse rejects non-HTTPS and credential-bearing media URLs", () => {
  const quality = { label: "Auto", mediaKind: "video" as const, headers: {} };
  assert.throws(() => infusePlaybackURL("Title", { ...quality, url: "http://example.com/video.mp4" }));
  assert.throws(() => infusePlaybackURL("Title", { ...quality, url: "https://user:pass@example.com/video.mp4" }));
});
