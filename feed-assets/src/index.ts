const ISSUER = "lustre-cloud";
const AUDIENCE = "lustre-feed-assets";
const MAX_REQUEST_BYTES = 12_288;
const MAX_REDIRECTS = 5;
const TIMEOUT_MS = 20_000;
const IMAGE_MAX_BYTES = 6 * 1_024 * 1_024;
const VIDEO_MAX_BYTES = 16 * 1_024 * 1_024;
const USER_AGENT = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/125.0.0.0";
const ALLOWED_HOSTS = ["phncdn.com", "hqporner.com", "fastporndelivery.com"];
const ALLPORNSTREAM_HOSTS = new Set(["allpornstream.com", "www.allpornstream.com"]);

type AssetKind = "image" | "video";
type TicketClaims = {
  version: 1;
  iss: string;
  aud: string;
  deviceID: string;
  url: string;
  kind: AssetKind;
  exp: number;
  iat: number;
  jti: string;
};

function corsHeaders(origin: string) {
  return {
    "Access-Control-Allow-Origin": origin,
    "Access-Control-Allow-Methods": "POST, OPTIONS",
    "Access-Control-Allow-Headers": "Content-Type",
    "Access-Control-Max-Age": "600",
    "Vary": "Origin",
  };
}

function jsonResponse(status: number, code: string, origin?: string) {
  return Response.json(
    { error: { code } },
    {
      status,
      headers: {
        "Cache-Control": "private, no-store",
        "X-Content-Type-Options": "nosniff",
        ...(origin ? corsHeaders(origin) : {}),
      },
    },
  );
}

function base64URLBytes(value: string): Uint8Array {
  if (!/^[A-Za-z0-9_-]+$/.test(value)) throw new Error("invalid-ticket");
  const padded = value.replace(/-/g, "+").replace(/_/g, "/") + "=".repeat((4 - value.length % 4) % 4);
  const binary = atob(padded);
  return Uint8Array.from(binary, (character) => character.charCodeAt(0));
}

function record(value: unknown): value is Record<string, unknown> {
  return !!value && typeof value === "object" && !Array.isArray(value);
}

function allowedURL(value: unknown): URL {
  if (typeof value !== "string" || value.length > 4_096) throw new Error("invalid-url");
  const url = new URL(value);
  const host = url.hostname.toLowerCase();
  const allPornStreamImage = ALLPORNSTREAM_HOSTS.has(host) && url.pathname === "/api/images";
  if (url.protocol !== "https:" || url.username || url.password || (!allPornStreamImage && !ALLOWED_HOSTS.some((allowed) => host === allowed || host.endsWith(`.${allowed}`)))) {
    throw new Error("invalid-url");
  }
  return url;
}

async function verifyTicket(ticket: unknown, secret: string, nowSeconds: number): Promise<TicketClaims> {
  if (typeof ticket !== "string" || ticket.length === 0 || ticket.length > 8_192) throw new Error("invalid-ticket");
  const parts = ticket.split(".");
  if (parts.length !== 3) throw new Error("invalid-ticket");
  const header = JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(base64URLBytes(parts[0]))) as unknown;
  if (!record(header) || header.alg !== "HS256" || header.typ !== "JWT") throw new Error("invalid-ticket");
  const key = await crypto.subtle.importKey("raw", new TextEncoder().encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["verify"]);
  const signature = new Uint8Array(base64URLBytes(parts[2])).buffer;
  const valid = await crypto.subtle.verify("HMAC", key, signature, new TextEncoder().encode(`${parts[0]}.${parts[1]}`));
  if (!valid) throw new Error("invalid-ticket");
  const payload = JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(base64URLBytes(parts[1]))) as unknown;
  if (!record(payload) || payload.version !== 1 || payload.iss !== ISSUER || payload.aud !== AUDIENCE ||
      typeof payload.deviceID !== "string" || !/^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(payload.deviceID) ||
      (payload.kind !== "image" && payload.kind !== "video") || !Number.isSafeInteger(payload.exp) || !Number.isSafeInteger(payload.iat) ||
      typeof payload.jti !== "string" || !/^[0-9a-f-]{36}$/i.test(payload.jti) || payload.exp as number <= nowSeconds ||
      payload.iat as number > nowSeconds + 5 || payload.exp as number - (payload.iat as number) > 60) throw new Error("invalid-ticket");
  allowedURL(payload.url);
  return payload as TicketClaims;
}

async function boundedJSON(request: Request): Promise<unknown> {
  const declared = Number(request.headers.get("Content-Length") ?? "0");
  if (Number.isFinite(declared) && declared > MAX_REQUEST_BYTES) throw new Error("invalid-request");
  if (!request.body) throw new Error("invalid-request");
  const reader = request.body.getReader();
  const chunks: Uint8Array[] = [];
  let length = 0;
  while (true) {
    const { done, value } = await reader.read();
    if (done) break;
    length += value.byteLength;
    if (length > MAX_REQUEST_BYTES) {
      await reader.cancel();
      throw new Error("invalid-request");
    }
    chunks.push(value);
  }
  const bytes = new Uint8Array(length);
  let offset = 0;
  for (const chunk of chunks) {
    bytes.set(chunk, offset);
    offset += chunk.byteLength;
  }
  return JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(bytes));
}

function providerHeaders(url: URL, kind: AssetKind) {
  const phncdn = url.hostname === "phncdn.com" || url.hostname.endsWith(".phncdn.com");
  const allPornStream = ALLPORNSTREAM_HOSTS.has(url.hostname);
  return new Headers({
    "User-Agent": USER_AGENT,
    "Referer": phncdn ? "https://www.pornhub.com/" : allPornStream ? "https://allpornstream.com/" : "https://hqporner.com/",
    "Accept": kind === "image" ? "image/avif,image/webp,image/apng,image/svg+xml,image/*,*/*;q=0.8" : "video/webm,video/mp4,video/*;q=0.9,*/*;q=0.8",
    "Accept-Language": "en-US,en;q=0.9",
  });
}

async function fetchAsset(fetcher: typeof fetch, initialURL: URL, kind: AssetKind, signal: AbortSignal) {
  let url = initialURL;
  for (let redirects = 0; ; redirects += 1) {
    const response = await fetcher(new Request(url, { method: "GET", headers: providerHeaders(url, kind), redirect: "manual", signal }));
    if ([301, 302, 303, 307, 308].includes(response.status)) {
      if (redirects >= MAX_REDIRECTS) throw new Error("redirect-limit");
      const location = response.headers.get("Location");
      if (!location) throw new Error("invalid-response");
      url = allowedURL(new URL(location, url).toString());
      continue;
    }
    return { response, url };
  }
}

export function createHandler(fetcher: typeof fetch = fetch, now: () => number = Date.now) {
  return async (request: Request, env: Env): Promise<Response> => {
    const requestURL = new URL(request.url);
    const requestOrigin = request.headers.get("Origin");
    const originAllowed = requestOrigin === env.ALLOWED_ORIGIN;
    if (requestURL.pathname !== "/v1/feed-assets") return jsonResponse(404, "not-found");
    if (request.method === "OPTIONS") {
      if (!originAllowed || request.headers.get("Access-Control-Request-Method") !== "POST") return jsonResponse(403, "origin-denied");
      return new Response(null, { status: 204, headers: corsHeaders(env.ALLOWED_ORIGIN) });
    }
    if (request.method !== "POST") return jsonResponse(405, "method-not-allowed", originAllowed ? env.ALLOWED_ORIGIN : undefined);
    if (!originAllowed) return jsonResponse(403, "origin-denied");

    let hostname = "unknown";
    let kind: AssetKind = "image";
    let bytes = 0;
    try {
      const body = await boundedJSON(request);
      if (!record(body)) throw new Error("invalid-request");
      const claims = await verifyTicket(body.ticket, env.LUSTRE_FEED_ASSET_TOKEN_SECRET, Math.floor(now() / 1_000));
      kind = claims.kind;
      const sourceURL = allowedURL(claims.url);
      hostname = sourceURL.hostname;
      const controller = new AbortController();
      const timeout = setTimeout(() => controller.abort(), TIMEOUT_MS);
      let response: Response;
      let finalURL: URL;
      try {
        ({ response, url: finalURL } = await fetchAsset(fetcher, sourceURL, kind, controller.signal));
      } finally {
        clearTimeout(timeout);
      }
      hostname = finalURL.hostname;
      if (response.status < 200 || response.status > 299 || !response.body) throw new Error("invalid-response");
      const contentType = response.headers.get("Content-Type")?.split(";", 1)[0].trim().toLowerCase() ?? "";
      if (!(kind === "image" ? contentType.startsWith("image/") : contentType.startsWith("video/"))) throw new Error("invalid-content-type");
      const maximum = kind === "image" ? IMAGE_MAX_BYTES : VIDEO_MAX_BYTES;
      const declaredLength = response.headers.get("Content-Length");
      if (declaredLength !== null) {
        const parsedLength = Number(declaredLength);
        if (!Number.isSafeInteger(parsedLength) || parsedLength < 0 || parsedLength > maximum) throw new Error("response-too-large");
      }
      const limiter = new TransformStream<Uint8Array, Uint8Array>({
        transform(chunk, controller) {
          bytes += chunk.byteLength;
          if (bytes > maximum) {
            console.log(JSON.stringify({ outcome: "response-too-large", hostname, kind, byteCount: bytes }));
            controller.error(new Error("response-too-large"));
            return;
          }
          controller.enqueue(chunk);
        },
        flush() {
          console.log(JSON.stringify({ outcome: "success", hostname, kind, byteCount: bytes }));
        },
      });
      const headers = new Headers({
        "Content-Type": contentType,
        "Cache-Control": "private, no-store",
        "X-Content-Type-Options": "nosniff",
        ...corsHeaders(env.ALLOWED_ORIGIN),
      });
      return new Response(response.body.pipeThrough(limiter), { status: 200, headers });
    } catch (error) {
      const outcome = error instanceof Error ? error.message : "asset-failed";
      console.log(JSON.stringify({ outcome, hostname, kind, byteCount: bytes }));
      return jsonResponse(outcome === "invalid-ticket" ? 401 : outcome === "response-too-large" ? 413 : 502, outcome, env.ALLOWED_ORIGIN);
    }
  };
}

const handler = createHandler();

export default {
  fetch(request, env) {
    return handler(request, env);
  },
} satisfies ExportedHandler<Env>;
