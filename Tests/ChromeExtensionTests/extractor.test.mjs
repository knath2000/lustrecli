import assert from "node:assert/strict";
import fs from "node:fs";
import test from "node:test";
import vm from "node:vm";

const source = fs.readFileSync(new URL("../../Sources/LustreAgent/Resources/ChromeExtension/extractor.js", import.meta.url), "utf8");
const context = vm.createContext({ URL });
vm.runInContext(source, context);
const extract = context.LustreAllPornStreamExtractor.extract;

function snapshot(itemListElement, overrides = {}) {
  return {
    title: "AllPornStream",
    bodyText: "Feed",
    origin: "https://allpornstream.com",
    scripts: [JSON.stringify({ "@type": "ItemList", itemListElement })],
    previews: {},
    ...overrides
  };
}

const video = (id) => ({
  "@type": "VideoObject",
  name: `Video ${id}`,
  url: `/post/${id}`,
  thumbnailUrl: `https://cdn.example/${id}.jpg`,
  uploadDate: "2026-07-26T00:00:00.000Z",
  interactionStatistic: { userInteractionCount: "12" }
});

test("extracts bounded normalized cards and four previews", () => {
  const item = { ...video("one"), name: ` Video\n\u001f\u200Bone ${"x".repeat(600)}` };
  const result = extract(snapshot([item], { previews: { "/post/one": ["https://cdn.example/1.jpg", "https://cdn.example/2.jpg", "https://cdn.example/3.jpg", "https://cdn.example/4.jpg", "https://cdn.example/5.jpg"] } }));
  assert.equal(result.cards.length, 1);
  assert.equal(result.cards[0].title.startsWith("Video one"), true);
  assert.equal(Array.from(result.cards[0].title).length, 512);
  assert.equal(result.cards[0].sourcePageURL, "https://allpornstream.com/post/one");
  assert.equal(result.cards[0].previewURLs.length, 3);
  assert.match(result.cards[0].thumbnailURL, /^https:\/\/allpornstream\.com\/api\/images\?/);
});

test("canonicalizes responsive variants and retains distinct mounted frames", () => {
  const first = "/api/images?src=https%3A%2F%2Fcdn.example%2Fscene-1.jpg&width=48&quality=60";
  const sameFirst = "/api/images?src=https%3A%2F%2Fcdn.example%2Fscene-1.jpg&width=1920&quality=60";
  const second = "/api/images?src=https%3A%2F%2Fcdn.example%2Fscene-2.jpg&width=1920&quality=60";
  const result = extract(snapshot([video("one")], { previews: { "/post/one": [first, sameFirst, second] } }));
  assert.equal(result.cards[0].previewURLs.length, 1);
  assert.notEqual(result.cards[0].thumbnailURL, result.cards[0].previewURLs[0]);
  assert.match(result.cards[0].thumbnailURL, /width=384/);
  assert.match(result.cards[0].previewURLs[0], /scene-2/);
});

test("returns no capture for challenged, malformed, or empty pages", () => {
  assert.equal(extract(snapshot([video("one")], { title: "Just a moment..." })), null);
  assert.equal(extract({ ...snapshot([]), scripts: ["{"] }), null);
  assert.equal(extract(snapshot([])), null);
  assert.equal(extract(snapshot([{ ...video("one"), name: "\u0000\u0085" }])), null);
});

test("caps oversized pages at fifty and reports more", () => {
  const result = extract(snapshot(Array.from({ length: 75 }, (_, index) => video(index))));
  assert.equal(result.cards.length, 50);
  assert.equal(result.hasMore, true);
});

test("preserves searched and paginated page metadata outside extracted cards", () => {
  const result = extract(snapshot([video("search")], { origin: "https://allpornstream.com" }));
  assert.equal(result.cards[0].sourcePageURL, "https://allpornstream.com/post/search");
});

test("manifest has only narrow permissions and exact AllPornStream hosts", () => {
  const manifest = JSON.parse(fs.readFileSync(new URL("../../Sources/LustreAgent/Resources/ChromeExtension/manifest.json", import.meta.url), "utf8"));
  assert.deepEqual(manifest.permissions.sort(), ["nativeMessaging", "storage", "tabs"]);
  assert.deepEqual(manifest.host_permissions.sort(), ["https://allpornstream.com/*", "https://www.allpornstream.com/*"]);
  for (const forbidden of ["cookies", "history", "proxy", "webRequest"]) assert.equal(manifest.permissions.includes(forbidden), false);
});

test("capture reads authoritative embedded card images before mounted media fallbacks", () => {
  const capture = fs.readFileSync(new URL("../../Sources/LustreAgent/Resources/ChromeExtension/capture.js", import.meta.url), "utf8");
  assert.match(capture, /card\.getAttribute\("data-images"\)/);
  assert.match(capture, /\.snap-center img/);
  assert.doesNotMatch(capture, /button\[data-nav-control="next"\]/);
  assert.doesNotMatch(capture, /card\.querySelectorAll\("img, source"\)/);
});
