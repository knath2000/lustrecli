import assert from "node:assert/strict";
import test from "node:test";
import { parseAllPornStreamFeed, parseAllPornStreamPost, parseHQPorner, parseMydaddy, parseOnlyFan420, parsePornHub, providerForURL } from "../src/index";

test("AllPornStream feed parses JSON-LD cards and bounded previews", () => {
  const video = { "@type": "VideoObject", name: "[Studio] Scene", url: "/post/966ad9af-7efc-49cb-b8c9-9eb2f4abe2d3/scene", thumbnailUrl: ["https://img.example/thumb.jpg"], uploadDate: "2026-08-10T12:00:00Z", interactionStatistic: { userInteractionCount: 42 } };
  const html = `<script type="application/ld+json">${JSON.stringify({ "@type": "ItemList", itemListElement: [video] })}</script><article data-href="${video.url}" data-images='["https://img.example/a.jpg","https://img.example/b.jpg"]'></article>`;
  const page = parseAllPornStreamFeed(html, 1);
  assert.equal(page.items[0]?.siteID, "allpornstream");
  assert.equal(page.items[0]?.studio, "Studio");
  assert.equal(page.items[0]?.viewCount, 42);
  assert.equal(page.items[0]?.previewURLs.length, 2);
});

test("AllPornStream post pairs and deduplicates provider records", () => {
  const html = `<title>Scene</title><script>self.__next_f.push([1,"{\\"embed_url\\":\\"https://streamtape.com/e/abc\\",\\"hosting_provider\\":\\"STREAMTAPE\\"} {\\"video_urls\\":{\\"link\\":[[\\"STREAMTAPE\\",\\"https://streamtape.com/e/abc\\"],[\\"VOE\\",\\"https://voe.sx/e/xyz\\"]]}}"])</script>`;
  const metadata = parseAllPornStreamPost(html, "https://allpornstream.com/post/966ad9af-7efc-49cb-b8c9-9eb2f4abe2d3/scene");
  assert.deepEqual(metadata.candidates.map(({ provider }) => provider), ["STREAMTAPE", "VOE"]);
});

test("HQPorner parser keeps canonical page and bounded previews", () => {
  const page = parseHQPorner(`<article><a href="/hdporn/123-scene" title="Example"><img src="https://img.hqporner.com/a.jpg"></a></article>`, 1, new Date("2026-01-01T00:00:00Z"));
  assert.equal(page.items.length, 1);
  assert.equal(page.items[0]?.sourcePageURL, "https://hqporner.com/hdporn/123-scene");
  assert.equal(page.items[0]?.uploadedAtIsApproximate, true);
});

test("OnlyFan420 parser rejects unsupported links and paginates", () => {
  const html = `<a class="external" href="https://doodstream.com/e/abc">Scene<img src="https://rentry.co/thumb.jpg"></a><a class="external" href="https://evil.example/x">Nope<img src="https://evil.example/a.jpg"></a>`;
  assert.equal(parseOnlyFan420(html, 1).items.length, 1);
  assert.equal(parseOnlyFan420(html, 2).items.length, 0);
});

test("mydaddy parser returns safe sources with referer", () => {
  const result = parseMydaddy(`<title>Scene</title><video><source src="https://cdn.mydaddy.cc/a.mp4" label="1080p"></video>`, "https://hqporner.com/hdporn/123-scene");
  assert.equal(result?.qualities[0]?.label, "1080p");
  assert.equal(result?.qualities[0]?.headers.Referer, "https://hqporner.com/");
  assert.match(result?.qualities[0]?.headers["User-Agent"] ?? "", /Chrome/);
});

test("mydaddy parser extracts escaped inline sources and sorts highest first", () => {
  const result = parseMydaddy(`<script>$("#jw").html("<video><source src=\\"//s39.bigcdn.cc/pubs/id/360.mp4\\" title=\\"360p\\" /><source src=\\"//s39.bigcdn.cc/pubs/id/1080.mp4\\" title=\\"1080p Full HD\\" /><source src=\\"//s39.bigcdn.cc/pubs/id/1080.mp4\\" title=\\"duplicate\\" /></video>")</script>`, "https://hqporner.com/hdporn/123-scene");
  assert.deepEqual(result?.qualities.map((quality) => quality.label), ["1080p Full HD", "360p"]);
  assert.deepEqual(result?.qualities.map((quality) => quality.url), [
    "https://s39.bigcdn.cc/pubs/id/1080.mp4",
    "https://s39.bigcdn.cc/pubs/id/360.mp4",
  ]);
});

test("mydaddy parser rejects unsafe and empty sources", () => {
  const result = parseMydaddy(`<source src="http://cdn.example/video.mp4"><source src="https://user:pass@cdn.example/video.mp4">`, "https://hqporner.com/hdporn/123-scene");
  assert.equal(result, null);
});

test("provider dispatch requires exact host suffixes", () => {
  assert.equal(providerForURL("https://allpornstream.com/post/966ad9af-7efc-49cb-b8c9-9eb2f4abe2d3/scene"), "allpornstream");
  assert.equal(providerForURL("https://www.pornhub.com/view_video.php?viewkey=abc"), "pornhub");
  assert.equal(providerForURL("https://pornhub.com.evil.example/video"), null);
});

test("PornHub parser retains canonical public sources", () => {
  const page = parsePornHub(`<li class="pcVideoListItem" data-video-vkey="abc_123"><a href="/view_video.php?viewkey=abc_123" title="Fixture"></a><img data-src="https://ci.phncdn.com/thumb.jpg"><span class="views"><var>1.2K</var></span></li>`, 1);
  assert.equal(page.items[0]?.sourcePageURL, "https://www.pornhub.com/view_video.php?viewkey=abc_123");
  assert.equal(page.items[0]?.viewCount, 1200);
});
