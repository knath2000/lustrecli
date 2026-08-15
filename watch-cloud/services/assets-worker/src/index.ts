import { assetReferer, safeAssetURL, validTicket } from "./ticket";

const allowedTypes = new Set(["image/jpeg", "image/png", "image/webp", "image/gif"]);
const maximumBytes = 5_000_000;

function corsHeaders(origin: string): HeadersInit {
  return {
    "Access-Control-Allow-Origin": origin,
    "Access-Control-Allow-Methods": "GET, OPTIONS",
    "Access-Control-Allow-Headers": "Content-Type",
    "Access-Control-Max-Age": "86400",
    "Vary": "Origin",
  };
}

async function fetchAsset(initialURL: URL): Promise<Response> {
  let current = initialURL;
  for (let redirects = 0; redirects <= 3; redirects += 1) {
    const response = await fetch(current, {
      redirect: "manual",
      headers: {
        Accept: "image/avif,image/webp,image/apng,image/*,*/*;q=0.8",
        Referer: assetReferer(current),
        "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 Chrome/140 Safari/537.36",
      },
      signal: AbortSignal.timeout(10_000),
    });
    if ([301, 302, 303, 307, 308].includes(response.status)) {
      const location = response.headers.get("Location");
      if (!location || redirects === 3) return new Response("Unsafe asset redirect.", { status: 502 });
      const next = safeAssetURL(new URL(location, current).href);
      if (!next) return new Response("Unsafe asset redirect.", { status: 502 });
      current = next;
      continue;
    }
    if (!response.ok || !response.body) return new Response("Asset unavailable.", { status: 502 });
    const type = response.headers.get("Content-Type")?.split(";")[0]?.toLowerCase() ?? "";
    const length = Number(response.headers.get("Content-Length") ?? "0");
    if (!allowedTypes.has(type)) return new Response("Unsupported asset type.", { status: 415 });
    if (Number.isFinite(length) && length > maximumBytes) return new Response("Asset exceeds size limit.", { status: 413 });
    let received = 0;
    const limiter = new TransformStream<Uint8Array, Uint8Array>({
      transform(chunk, controller) {
        received += chunk.byteLength;
        if (received > maximumBytes) return controller.error(new Error("Asset exceeds size limit."));
        controller.enqueue(chunk);
      },
    });
    return new Response(response.body.pipeThrough(limiter), {
      headers: { "Content-Type": type, "Cache-Control": "private, max-age=300", "X-Content-Type-Options": "nosniff" },
    });
  }
  return new Response("Asset unavailable.", { status: 502 });
}

export default {
  async fetch(request, env): Promise<Response> {
    const origin = request.headers.get("Origin");
    if (origin !== env.WEB_ORIGIN) return new Response("Forbidden.", { status: 403 });
    if (request.method === "OPTIONS") return new Response(null, { status: 204, headers: corsHeaders(env.WEB_ORIGIN) });
    if (request.method !== "GET") return new Response("Method not allowed.", { status: 405 });
    const input = new URL(request.url);
    if (input.pathname !== "/assets") return new Response("Not found.", { status: 404 });
    const url = input.searchParams.get("url");
    const expires = input.searchParams.get("expires");
    const signature = input.searchParams.get("signature");
    if (!url || !expires || !signature || !await validTicket(url, expires, signature, env.ASSET_TICKET_SECRET)) return new Response("Invalid or expired ticket.", { status: 401 });
    const assetURL = safeAssetURL(url);
    if (!assetURL) return new Response("Unsafe asset URL.", { status: 400 });
    const response = await fetchAsset(assetURL);
    const headers = new Headers(response.headers);
    for (const [name, value] of Object.entries(corsHeaders(env.WEB_ORIGIN))) headers.set(name, value);
    return new Response(response.body, { status: response.status, headers });
  },
} satisfies ExportedHandler<Env>;
