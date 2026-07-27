import assert from "node:assert/strict";
import { createHmac } from "node:crypto";
import test from "node:test";
import { createHandler } from "./index.ts";

const secret = "test-feed-asset-secret-with-at-least-thirty-two-bytes";
const origin = "https://lustrecli.vercel.app";
const deviceID = "f8ca8705-69c4-4c73-81fb-7bb1dc5c1853";
const now = Date.parse("2026-07-26T12:00:00Z");
const env = { ALLOWED_ORIGIN: origin, LUSTRE_FEED_ASSET_TOKEN_SECRET: secret };

function encode(value) {
  return Buffer.from(JSON.stringify(value)).toString("base64url");
}

function ticket(overrides = {}) {
  const header = encode({ alg: "HS256", typ: "JWT" });
  const payload = encode({ version: 1, iss: "lustre-cloud", aud: "lustre-feed-assets", deviceID, url: "https://cdn.hqporner.com/thumb.jpg", kind: "image", iat: now / 1000, exp: now / 1000 + 60, jti: "f8ca8705-69c4-4c73-81fb-7bb1dc5c1853", ...overrides });
  const signature = createHmac("sha256", secret).update(`${header}.${payload}`).digest("base64url");
  return `${header}.${payload}.${signature}`;
}

function request(value = ticket(), method = "POST", requestOrigin = origin) {
  return new Request("https://assets.example/v1/feed-assets", {
    method,
    headers: { "Content-Type": "application/json", "Origin": requestOrigin, ...(method === "OPTIONS" ? { "Access-Control-Request-Method": "POST" } : {}) },
    ...(method === "POST" ? { body: JSON.stringify({ ticket: value }) } : {}),
  });
}

test("asset worker streams the exact image limit with fresh provider headers", async () => {
  const maximum = 6 * 1024 * 1024;
  let upstreamRequest;
  const handler = createHandler(async (next) => {
    upstreamRequest = next;
    return new Response(new Uint8Array(maximum), { headers: { "Content-Type": "image/jpeg", "Content-Length": String(maximum), "Set-Cookie": "unsafe=1" } });
  }, () => now);
  const response = await handler(request(), env);
  assert.equal(response.status, 200);
  assert.equal((await response.arrayBuffer()).byteLength, maximum);
  assert.equal(response.headers.get("set-cookie"), null);
  assert.equal(response.headers.get("cache-control"), "private, no-store");
  assert.equal(upstreamRequest.headers.get("cookie"), null);
  assert.equal(upstreamRequest.headers.get("authorization"), null);
  assert.equal(upstreamRequest.headers.get("origin"), null);
  assert.equal(upstreamRequest.headers.get("referer"), "https://hqporner.com/");
});

test("asset worker rejects declared and streamed over-limit bodies", async () => {
  const maximum = 6 * 1024 * 1024;
  let pulled = false;
  const declared = createHandler(async () => new Response(new ReadableStream({ pull() { pulled = true; } }), { headers: { "Content-Type": "image/jpeg", "Content-Length": String(maximum + 1) } }), () => now);
  assert.equal((await declared(request(), env)).status, 413);
  assert.equal(typeof pulled, "boolean");

  const streamed = createHandler(async () => new Response(new Uint8Array(maximum + 1), { headers: { "Content-Type": "image/jpeg" } }), () => now);
  const response = await streamed(request(), env);
  assert.equal(response.status, 200);
  await assert.rejects(response.arrayBuffer());
});

test("asset worker accepts the exact video limit and rejects a declared byte over it", async () => {
  const maximum = 16 * 1024 * 1024;
  const validHandler = createHandler(async () => new Response(new Uint8Array(maximum), { headers: { "Content-Type": "video/mp4", "Content-Length": String(maximum) } }), () => now);
  const valid = await validHandler(request(ticket({ kind: "video", url: "https://cdn.hqporner.com/preview.mp4" })), env);
  assert.equal(valid.status, 200);
  assert.equal((await valid.arrayBuffer()).byteLength, maximum);

  const oversizedHandler = createHandler(async () => new Response("not-read", { headers: { "Content-Type": "video/mp4", "Content-Length": String(maximum + 1) } }), () => now);
  assert.equal((await oversizedHandler(request(ticket({ kind: "video", url: "https://cdn.hqporner.com/preview.mp4" })), env)).status, 413);
});

test("asset worker proxies only the exact AllPornStream image endpoint with its provider referer", async () => {
  let upstreamRequest;
  const handler = createHandler(async (next) => {
    upstreamRequest = next;
    return new Response(new Uint8Array([1, 2, 3]), { headers: { "Content-Type": "image/webp" } });
  }, () => now);

  const imageURL = "https://allpornstream.com/api/images?src=https%3A%2F%2Fcdn.example%2Fthumb.jpg";
  const response = await handler(request(ticket({ url: imageURL })), env);

  assert.equal(response.status, 200);
  assert.equal(upstreamRequest.headers.get("referer"), "https://allpornstream.com/");
  assert.equal((await response.arrayBuffer()).byteLength, 3);
  assert.equal((await handler(request(ticket({ url: "https://allpornstream.com/post/not-an-asset" })), env)).status, 502);
  assert.equal((await handler(request(ticket({ url: "https://images.allpornstream.com/api/images" })), env)).status, 502);
});

test("asset worker validates tickets, origin, redirects, and kind", async () => {
  const handler = createHandler(async () => new Response("ok", { headers: { "Content-Type": "image/jpeg" } }), () => now);
  assert.equal((await handler(request(`${ticket().slice(0, -1)}x`), env)).status, 401);
  assert.equal((await handler(request(ticket({ exp: now / 1000 - 1 })), env)).status, 401);
  assert.equal((await handler(request(ticket({ url: "https://example.com/no.jpg" })), env)).status, 502);
  assert.equal((await handler(request(ticket(), "POST", "https://evil.example"), env)).status, 403);
  assert.equal((await handler(request(ticket({ kind: "video" })), env)).status, 502);
});

test("asset worker serves exact-origin CORS preflight", async () => {
  const handler = createHandler(async () => new Response(), () => now);
  const response = await handler(request(ticket(), "OPTIONS"), env);
  assert.equal(response.status, 204);
  assert.equal(response.headers.get("access-control-allow-origin"), origin);
});
