import assert from "node:assert/strict";
import test from "node:test";
import { ResolverError } from "@lustre/contracts";
import { parseVidaraMaster, resolveVidara, vidaraFilecode } from "../src/vidara";
import type { SafeRequest, SafeResponse } from "../src/safety";

const response = (body: string, url: string, contentType: string, status = 200): SafeResponse => ({
  body,
  finalURL: new URL(url),
  contentType,
  status,
});

test("Vidara accepts watch, embed, and download paths only", () => {
  for (const prefix of ["v", "e", "d"]) {
    assert.equal(vidaraFilecode(new URL(`https://vidara.so/${prefix}/Fr5jKe2grT2tU`)), "Fr5jKe2grT2tU");
  }
  for (const value of [
    "https://vidara.so/watch/code",
    "https://vidara.so/v/",
    "https://vidara.so/v/code/extra",
    `https://vidara.so/v/${"a".repeat(129)}`,
    "https://vidara.so/v/code%2Fextra",
  ]) assert.throws(() => vidaraFilecode(new URL(value)), ResolverError);
});

test("Vidara posts metadata request and returns sorted deduplicated HLS qualities", async () => {
  const requests: Array<{ url: URL; options?: SafeRequest }> = [];
  const request = async (url: URL, options?: SafeRequest) => {
    requests.push({ url, options });
    if (url.pathname === "/api/stream") {
      return response(JSON.stringify({
        streaming_url: "https://media.example/path/master.m3u8?token=signed",
        title: "Fixture",
        thumbnail: "https://images.example/poster.jpg",
      }), url.href, "application/json");
    }
    if (url.pathname.endsWith("/index.m3u8")) {
      return response("#EXTM3U\n#EXT-X-TARGETDURATION:6\nsegment.ts", url.href, "application/vnd.apple.mpegurl");
    }
    if (url.pathname.endsWith("/segment.ts")) {
      return response("media-bytes", url.href, "video/mp2t", 206);
    }
    return response(`#EXTM3U
#EXT-X-STREAM-INF:BANDWIDTH=1,RESOLUTION=1280x720
720/index.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=2,RESOLUTION=1920x1080
/1080/index.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=3,RESOLUTION=1920x1080
/1080/index.m3u8`, url.href, "application/vnd.apple.mpegurl");
  };
  const validated: string[] = [];
  const events: string[] = [];
  const result = await resolveVidara(
    new URL("https://vidara.so/v/Fr5jKe2grT2tU"),
    (event) => events.push(event.type),
    request,
    async (url) => { validated.push(url.href); },
  );
  assert.equal(requests[0]?.url.href, "https://vidara.so/api/stream");
  assert.equal(requests[0]?.options?.method, "POST");
  assert.equal(requests[0]?.options?.headers?.Referer, "https://vidara.so/");
  assert.deepEqual(JSON.parse(requests[0]?.options?.body ?? ""), { filecode: "Fr5jKe2grT2tU", device: "web" });
  assert.equal(requests[1]?.options?.redirectPolicy, "same-host");
  assert.deepEqual(result.qualities.map((quality) => quality.label), ["1080p", "720p"]);
  assert.ok(result.qualities.every((quality) =>
    quality.mediaKind === "hls"
    && quality.provider === "Vidara"
    && quality.resolutionMethod === "native"
    && quality.infuseCompatibility === "verified"
    && quality.headers.Referer === "https://vidara.so/"
    && Boolean(quality.headers["User-Agent"])
  ));
  assert.deepEqual(events, ["provider_started", "metadata", "validating", "provider_completed"]);
  assert.ok(validated.includes("https://media.example/1080/index.m3u8"));
  assert.ok(validated.includes("https://media.example/1080/segment.ts"));
  assert.ok(validated.includes("https://media.example/path/720/index.m3u8"));
  assert.ok(validated.includes("https://media.example/path/720/segment.ts"));
});

test("Vidara returns a validated master when no variants exist", async () => {
  const request = async (url: URL) => {
    if (url.pathname === "/api/stream") return response('{"streaming_url":"https://media.example/master.m3u8"}', url.href, "application/json");
    if (url.pathname.endsWith(".ts")) return response("media-bytes", url.href, "video/mp2t", 206);
    return response("#EXTM3U\n#EXT-X-TARGETDURATION:6\nsegment.ts", url.href, "application/x-mpegURL");
  };
  const result = await resolveVidara(new URL("https://vidara.so/e/code"), undefined, request, async () => {});
  assert.deepEqual(result.qualities.map((quality) => quality.label), ["Master"]);
});

test("Vidara rejects malformed metadata, unsafe streams, invalid playlists, and unsafe variants", async () => {
  const source = new URL("https://vidara.so/d/code");
  await assert.rejects(() => resolveVidara(source, undefined, async (url) =>
    response("not-json", url.href, "application/json"), async () => {}), /malformed metadata/);
  await assert.rejects(() => resolveVidara(source, undefined, async (url) =>
    response('{"streaming_url":"http://media.example/master.m3u8"}', url.href, "application/json"), async () => {}), /unsafe HLS/);
  await assert.rejects(() => resolveVidara(source, undefined, async (url) =>
    url.pathname === "/api/stream"
      ? response('{"streaming_url":"https://media.example/master.m3u8"}', url.href, "application/json")
      : response("<html>challenge</html>", url.href, "text/html"), async () => {}), /invalid HLS/);
  await assert.rejects(() => resolveVidara(source, undefined, async (url) =>
    url.pathname === "/api/stream"
      ? response('{"streaming_url":"https://127.0.0.1/master.m3u8"}', url.href, "application/json")
      : response("#EXTM3U", url.href, "application/x-mpegURL"), async (url) => {
        if (url.hostname === "127.0.0.1") throw new ResolverError("invalid_request", "private");
      }), /private/);
});

test("Vidara bounds parsed variants and ignores unsafe entries", () => {
  const lines = ["#EXTM3U"];
  for (let height = 100; height <= 1500; height += 100) {
    lines.push(`#EXT-X-STREAM-INF:RESOLUTION=1920x${height}`, `${height}.m3u8`);
  }
  lines.push("#EXT-X-STREAM-INF:RESOLUTION=1x1", "http://unsafe.example/one.m3u8");
  const variants = parseVidaraMaster(lines.join("\n"), new URL("https://media.example/master.m3u8"));
  assert.equal(variants.length, 12);
  assert.equal(variants[0]?.height, 1500);
  assert.equal(variants.at(-1)?.height, 400);
});
