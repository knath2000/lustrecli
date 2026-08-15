import assert from "node:assert/strict";
import test from "node:test";
import type { FeedPlaybackResolution, ResolutionProgressEvent } from "./contracts.ts";
import { resolveClientBoundSources } from "./client-bound-resolution";
import { displayProgressEvent } from "./client-bound-progress";
import { HQPornerRefreshError, refreshHQPornerSources } from "./hqporner-refresh";

const sourcePageURL = "https://hqporner.com/hdporn/127429-your_new_girlfriend_is_for_both_4K.html";
const clientResolverURL = "https://mydaddy.cc/video/cd980543a2972616da/";
const mediaURLs = [
  "https://s86.bigcdn.cc/pubs/fresh/2160.mp4",
  "https://s86.bigcdn.cc/pubs/fresh/1080.mp4",
  "https://s86.bigcdn.cc/pubs/fresh/720.mp4",
  "https://s86.bigcdn.cc/pubs/fresh/360.mp4",
];

function resolution(): FeedPlaybackResolution {
  return {
    sourcePageURL,
    title: "Your New Girlfriend Is For Both 4K",
    clientResolverURL,
    qualities: mediaURLs.map((url, index) => ({ label: `Modal ${index}`, url: url.replace("/fresh/", "/server/"), mediaKind: "video", headers: {} })),
  };
}

function mp4Response(overrides: { status?: number; type?: string; range?: string; bytes?: Uint8Array } = {}) {
  const bytes = overrides.bytes ?? new Uint8Array([0, 0, 0, 24, 102, 116, 121, 112, 105, 115, 111, 109]);
  return new Response(bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength) as ArrayBuffer, {
    status: overrides.status ?? 206,
    headers: {
      "Content-Type": overrides.type ?? "video/mp4",
      "Content-Range": overrides.range ?? "bytes 0-11/3847850470",
      "Content-Length": String(bytes.byteLength),
    },
  });
}

function providerFetcher(mediaResponse = mp4Response()): typeof fetch {
  return (async (input: string | URL | Request, init?: RequestInit) => {
    const url = input instanceof Request ? input.url : input.toString();
    assert.equal(init?.credentials, "omit");
    assert.equal(init?.mode, "cors");
    if (url === clientResolverURL) {
      return new Response(`<video>${mediaURLs.map((mediaURL, index) => `<source src="${mediaURL}" title="${[2160, 1080, 720, 360][index]}p">`).join("")}</video>`);
    }
    if (mediaURLs.includes(url)) {
      assert.equal(new Headers(init?.headers).get("range"), "bytes=0-65535");
      return mediaResponse.clone();
    }
    throw new Error(`Unexpected URL: ${url}`);
  }) as typeof fetch;
}

test("server completion becomes device validation instead of ready sources", () => {
  const event: ResolutionProgressEvent = { type: "completed", at: "2026-08-13T12:00:00.000Z", resolution: resolution() };
  const displayed = displayProgressEvent(event);
  assert.equal(displayed.type, "validating");
  assert.match(displayed.type === "validating" ? displayed.message : "", /Refreshing 4 HQPorner candidates on this device/);
});

test("browser-local refresh replaces all Modal URLs with validated device sources", async () => {
  const refreshed = await resolveClientBoundSources(resolution(), providerFetcher());
  assert.deepEqual(refreshed.qualities.map(({ url }) => url), mediaURLs);
  assert.ok(refreshed.qualities.every((quality) => quality.infuseCompatibility === "verified" && quality.provider === "HQPorner"));
});

test("accepts a valid bounded 206 when Content-Range is not exposed by CORS", async () => {
  const response = mp4Response();
  response.headers.delete("Content-Range");
  const refreshed = await resolveClientBoundSources(resolution(), providerFetcher(response));
  assert.equal(refreshed.qualities.length, 4);
});

test("streaming and compatibility paths use identical browser-local qualities", async () => {
  const streamed = await resolveClientBoundSources(resolution(), providerFetcher());
  const compatibility = await resolveClientBoundSources(resolution(), providerFetcher());
  assert.deepEqual(streamed, compatibility);
});

for (const [name, response] of [
  ["non-206 responses", mp4Response({ status: 200 })],
  ["incorrect content types", mp4Response({ type: "text/html" })],
  ["invalid content ranges", mp4Response({ range: "bytes 10-20/100" })],
  ["malformed MP4 bytes", mp4Response({ bytes: new Uint8Array([0, 0, 0, 8, 98, 97, 100, 33]) })],
] as const) {
  test(`rejects ${name}`, async () => {
    await assert.rejects(refreshHQPornerSources(clientResolverURL, providerFetcher(response)), HQPornerRefreshError);
  });
}

test("classifies unsafe players, missing sources, embed failures, and CORS failures", async () => {
  await assert.rejects(refreshHQPornerSources("https://mydaddy.cc.attacker.example/video/code/", providerFetcher()), (reason) =>
    reason instanceof HQPornerRefreshError && reason.code === "embed_unavailable");
  await assert.rejects(refreshHQPornerSources(clientResolverURL, (async () => new Response("<video></video>")) as typeof fetch), (reason) =>
    reason instanceof HQPornerRefreshError && reason.code === "no_sources");
  await assert.rejects(refreshHQPornerSources(clientResolverURL, (async () => new Response("unavailable", { status: 503 })) as typeof fetch), (reason) =>
    reason instanceof HQPornerRefreshError && reason.code === "embed_unavailable");
  await assert.rejects(refreshHQPornerSources(clientResolverURL, (async () => { throw new TypeError("Failed to fetch"); }) as typeof fetch), (reason) =>
    reason instanceof HQPornerRefreshError && reason.code === "cors_blocked");
});

test("cancellation propagates and repeated refreshes start from the embed", async () => {
  const controller = new AbortController();
  controller.abort();
  await assert.rejects(refreshHQPornerSources(clientResolverURL, (async () => { throw controller.signal.reason; }) as typeof fetch, controller.signal), /aborted/i);
  const first = await resolveClientBoundSources(resolution(), providerFetcher());
  const second = await resolveClientBoundSources(resolution(), providerFetcher());
  assert.deepEqual(first.qualities.map(({ url }) => url), mediaURLs);
  assert.deepEqual(second.qualities.map(({ url }) => url), mediaURLs);
});
