import assert from "node:assert/strict";
import test from "node:test";
import { resolveLulu } from "../src/lulu";
import { resolvePlaymogo } from "../src/playmogo";
import { decodePackedJavaScript } from "../src/packed-javascript";
import type { SafeRequest, SafeResponse } from "../src/safety";

const response = (body: string, url: string, contentType: string, status = 200): SafeResponse => ({
  body,
  finalURL: new URL(url),
  contentType,
  status,
});

test("packed JavaScript decoder expands Lulu player dictionaries", () => {
  const packed = `eval(function(p,a,c,k,e,d){return p;}('0:"1";',62,2,'file|https://media.example/master.m3u8'.split('|'),0,{}))`;
  assert.deepEqual(decodePackedJavaScript(packed), ['file:"https://media.example/master.m3u8";']);
});

test("LuluVDO resolves packed-player HLS through a bare playlist and segment chain", async () => {
  const requests: Array<{ url: URL; options?: SafeRequest }> = [];
  const request = async (url: URL, options?: SafeRequest) => {
    requests.push({ url, options });
    if (url.hostname === "luluvid.com") return response("<title>Lulu fixture</title>", url.href, "text/html");
    if (url.hostname === "luluvdo.com") return response('file:"https:\\/\\/media.example\\/master.m3u8?token=fresh"', url.href, "text/html");
    if (url.pathname === "/master.m3u8") return response("#EXTM3U\n#EXT-X-STREAM-INF:RESOLUTION=1920x1080\n1080/index.m3u8", url.href, "application/vnd.apple.mpegurl");
    if (url.pathname === "/1080/index.m3u8") return response("#EXTM3U\n#EXT-X-TARGETDURATION:6\nfirst.ts", url.href, "application/vnd.apple.mpegurl");
    return response("media", url.href, "video/mp2t", 206);
  };
  const result = await resolveLulu(new URL("https://luluvdo.com/d/l2q10ab4wzs9"), undefined, request, async () => {});
  assert.equal(result.title, "Lulu fixture");
  assert.deepEqual(result.qualities.map(({ label, infuseCompatibility }) => [label, infuseCompatibility]), [["1080p", "verified"]]);
  assert.ok(requests.some(({ url, options }) => url.pathname.endsWith(".ts") && options?.headers?.Range === "bytes=0-65535"));
});

test("LuluVDO marks qualities header-required when bare validation fails", async () => {
  const request = async (url: URL, options?: SafeRequest) => {
    if (url.hostname === "luluvid.com") return response("<title>Lulu fixture</title>", url.href, "text/html");
    if (url.hostname === "luluvdo.com") return response('file:"https://media.example/master.m3u8"', url.href, "text/html");
    if (!options?.headers?.Referer) return response("forbidden", url.href, "text/plain", 403);
    if (url.pathname === "/master.m3u8") return response("#EXTM3U\n#EXT-X-TARGETDURATION:6\nfirst.ts", url.href, "application/vnd.apple.mpegurl");
    return response("media", url.href, "video/mp2t", 206);
  };
  const result = await resolveLulu(new URL("https://luluvid.com/d/code"), undefined, request, async () => {});
  assert.equal(result.qualities[0]?.infuseCompatibility, "header_required");
});

test("Playmogo normalizes download links, mints CloudAta URLs, and checks bare compatibility", async () => {
  const requests: Array<{ url: URL; options?: SafeRequest }> = [];
  const request = async (url: URL, options?: SafeRequest) => {
    requests.push({ url, options });
    if (url.hostname === "playmogo.com" && url.pathname === "/d/vo8oq3dzixt2") {
      return response('<iframe src="/e/vo8oq3dzixt2"></iframe>', url.href, "text/html");
    }
    if (url.hostname === "playmogo.com" && url.pathname === "/e/vo8oq3dzixt2") {
      return response(`<title>Playmogo fixture</title><script>
        $.get('/pass_md5/secret');
        const suffix = "?token=fixture&expiry=" + Date.now();
      </script>`, url.href, "text/html");
    }
    if (url.pathname === "/pass_md5/secret") return response("https://video.cloudatacdn.com/dl/video~", url.href, "text/plain");
    return response("media", url.href, "video/mp4", 206);
  };
  const result = await resolvePlaymogo(new URL("https://playmogo.com/d/vo8oq3dzixt2"), undefined, request, async () => {});
  assert.equal(requests[0]?.url.href, "https://playmogo.com/d/vo8oq3dzixt2");
  assert.equal(requests[1]?.url.href, "https://playmogo.com/e/vo8oq3dzixt2");
  assert.equal(requests[2]?.options?.headers?.["X-Requested-With"], "XMLHttpRequest");
  assert.match(result.qualities[0]?.url ?? "", /^https:\/\/video\.cloudatacdn\.com\/dl\/video~[A-Za-z0-9]{10}\?token=fixture&expiry=\d+$/);
  assert.equal(result.qualities[0]?.infuseCompatibility, "verified");
});

test("Playmogo rejects token endpoints and media hosts outside its trusted flow", async () => {
  await assert.rejects(() => resolvePlaymogo(
    new URL("https://playmogo.com/e/code"),
    undefined,
    async (url) => response(`<script>$.get('https://evil.example/pass_md5/x'); const x="?token=a&expiry="+Date.now()</script>`, url.href, "text/html"),
    async () => {},
  ), /unsafe token endpoint/);

  await assert.rejects(() => resolvePlaymogo(
    new URL("https://playmogo.com/e/code"),
    undefined,
    async (url) => url.pathname.includes("pass_md5")
      ? response("https://evil.example/dl/video~", url.href, "text/plain")
      : response(`<script>$.get('/pass_md5/x'); const x="?token=a&expiry="+Date.now()</script>`, url.href, "text/html"),
    async () => {},
  ), /unsupported media host/);
});
