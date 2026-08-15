import assert from "node:assert/strict";
import test from "node:test";
import { publicHTTPSURL } from "./public-url.ts";

test("accepts credential-free public HTTPS URLs", () => {
  assert.equal(publicHTTPSURL("https://cdn.example.com/video.jpg")?.href, "https://cdn.example.com/video.jpg");
});

test("rejects local, private, credential-bearing, and non-HTTPS URLs", () => {
  for (const value of [
    "http://cdn.example.com/video.jpg",
    "https://user:pass@cdn.example.com/video.jpg",
    "https://localhost/video.jpg",
    "https://127.0.0.1/video.jpg",
    "https://10.0.0.2/video.jpg",
    "https://192.168.1.2/video.jpg",
    "https://[::1]/video.jpg",
  ]) {
    assert.equal(publicHTTPSURL(value), null);
  }
});
