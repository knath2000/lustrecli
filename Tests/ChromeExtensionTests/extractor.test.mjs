import assert from "node:assert/strict";
import fs from "node:fs";
import test from "node:test";
import vm from "node:vm";

const source = fs.readFileSync(new URL("../../Sources/LustreAgent/Resources/ChromeExtension/extractor.js", import.meta.url), "utf8");
const context = vm.createContext({ URL, TextEncoder });
vm.runInContext(source, context);
const extract = context.LustreAllPornStreamExtractor.extract;
const extractPost = context.LustreAllPornStreamExtractor.extractPost;

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

test("extracts only bounded AllPornStream post provider metadata", () => {
  const result = extractPost({
    title: "Post",
    bodyText: "Ready",
    origin: "https://allpornstream.com",
    metadataScripts: [
      "self.__next_f.push([1, 'unrelated'])",
      `self.__next_f.push([1, ${JSON.stringify('{"video_urls":[{"hosting_provider":"MIXDROP","iframe":"https://mixdrop.co/e/example"}]}')}])`,
      "x".repeat(40_000)
    ]
  });
  assert.equal(result.metadataSources.length, 1);
  assert.match(result.metadataSources[0], /hosting_provider/);
  assert.equal(extractPost({ title: "Just a moment", bodyText: "", origin: "https://allpornstream.com", metadataScripts: [] }), null);
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

test("manifest limits browser access to capture and local Pornhub authentication", () => {
  const manifest = JSON.parse(fs.readFileSync(new URL("../../Sources/LustreAgent/Resources/ChromeExtension/manifest.json", import.meta.url), "utf8"));
  assert.deepEqual(manifest.permissions.sort(), ["cookies", "nativeMessaging", "storage", "tabs"]);
  assert.deepEqual(manifest.host_permissions.sort(), ["https://allpornstream.com/*", "https://pornhub.com/*", "https://www.allpornstream.com/*", "https://www.pornhub.com/*"]);
  for (const forbidden of ["history", "proxy", "webRequest"]) assert.equal(manifest.permissions.includes(forbidden), false);
});

test("Firefox manifest keeps narrow permissions and a stable local native-messaging ID", () => {
  const manifest = JSON.parse(fs.readFileSync(new URL("../../Sources/LustreAgent/Resources/FirefoxManifest.json", import.meta.url), "utf8"));
  assert.deepEqual(manifest.permissions.sort(), ["cookies", "nativeMessaging", "storage", "tabs"]);
  assert.deepEqual(manifest.host_permissions.sort(), ["https://allpornstream.com/*", "https://pornhub.com/*", "https://www.allpornstream.com/*", "https://www.pornhub.com/*"]);
  assert.deepEqual(manifest.background.scripts, ["service.js"]);
  assert.equal(manifest.browser_specific_settings.gecko.id, "lustre-allpornstream@pmvdl.local");
  assert.deepEqual(manifest.browser_specific_settings.gecko.data_collection_permissions.required, ["websiteContent"]);
  assert.equal("key" in manifest, false);
  for (const forbidden of ["history", "proxy", "webRequest"]) assert.equal(manifest.permissions.includes(forbidden), false);
});

test("Pornhub authentication forwards browser cookies locally without credential fields", () => {
  const service = fs.readFileSync(new URL("../../Sources/LustreAgent/Resources/ChromeExtension/service.js", import.meta.url), "utf8");
  const auth = fs.readFileSync(new URL("../../Sources/LustreAgent/Resources/ChromeExtension/pornhub-auth.js", import.meta.url), "utf8");
  assert.match(auth, /pornhub_auth_probe_v1/);
  assert.match(service, /extensionAPI\.cookies\.getAll\(\{ domain: "pornhub\.com" \}\)/);
  assert.match(service, /cookie\.name === "il"/);
  assert.match(service, /type: "pornhub_auth_v1"/);
  assert.match(service, /type: "pornhub_auth_closed_v1"/);
  assert.doesNotMatch(auth, /isLoggedInUser|users\/logout/);
  for (const forbidden of ["localStorage", "document.cookie", "password", "username"]) {
    assert.equal(auth.includes(forbidden), false);
    assert.equal(service.includes(forbidden), false);
  }
});

test("shared extension scripts select Firefox or Chrome APIs without browser-specific payloads", () => {
  const service = fs.readFileSync(new URL("../../Sources/LustreAgent/Resources/ChromeExtension/service.js", import.meta.url), "utf8");
  const capture = fs.readFileSync(new URL("../../Sources/LustreAgent/Resources/ChromeExtension/capture.js", import.meta.url), "utf8");
  assert.match(service, /globalThis\.browser \?\? globalThis\.chrome/);
  assert.match(capture, /globalThis\.browser \?\? globalThis\.chrome/);
  assert.doesNotMatch(service, /allowed_extensions|allowed_origins/);
});

test("capture reads authoritative embedded card images before mounted media fallbacks", () => {
  const capture = fs.readFileSync(new URL("../../Sources/LustreAgent/Resources/ChromeExtension/capture.js", import.meta.url), "utf8");
  assert.match(capture, /card\.getAttribute\("data-images"\)/);
  assert.match(capture, /\.snap-center img/);
  assert.doesNotMatch(capture, /button\[data-nav-control="next"\]/);
  assert.doesNotMatch(capture, /card\.querySelectorAll\("img, source"\)/);
});
