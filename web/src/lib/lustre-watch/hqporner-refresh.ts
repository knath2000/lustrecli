import type { FeedPlaybackResolution } from "@/lib/lustre-watch/contracts";

type Fetcher = typeof fetch;
type PlaybackQuality = FeedPlaybackResolution["qualities"][number];

const validationLimit = 65_536;
const playbackHeaders = {
  Referer: "https://hqporner.com/",
  "User-Agent": "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 Chrome/136 Safari/537.36",
};

export type HQPornerRefreshCode = "embed_unavailable" | "no_sources" | "cors_blocked" | "media_validation_failed";

export class HQPornerRefreshError extends Error {
  constructor(readonly code: HQPornerRefreshCode, message: string) {
    super(message);
    this.name = "HQPornerRefreshError";
  }
}

function myDaddyURL(value: string): URL {
  const url = new URL(value);
  if (
    url.protocol !== "https:"
    || url.username
    || url.password
    || url.port
    || url.hostname !== "mydaddy.cc"
    || !/^\/video\/[A-Za-z0-9_-]{3,128}\/?$/.test(url.pathname)
  ) throw new HQPornerRefreshError("embed_unavailable", "HQPorner returned an unsupported player.");
  return url;
}

function bigCDNURL(value: string, base?: URL): URL {
  const url = new URL(value, base);
  if (
    url.protocol !== "https:"
    || url.username
    || url.password
    || url.port
    || !(url.hostname === "bigcdn.cc" || url.hostname.endsWith(".bigcdn.cc"))
  ) throw new HQPornerRefreshError("no_sources", "HQPorner returned no trusted media sources.");
  return url;
}

function qualityHeight(label: string): number {
  if (/\b4k\b/i.test(label)) return 2_160;
  return Number(label.match(/(\d+)p/i)?.[1] ?? 0);
}

async function boundedBytes(response: Response, limit: number): Promise<Uint8Array> {
  const declared = Number(response.headers.get("content-length") ?? 0);
  if (declared > limit) throw new HQPornerRefreshError("media_validation_failed", "HQPorner media exceeded its validation limit.");
  const reader = response.body?.getReader();
  if (!reader) throw new HQPornerRefreshError("media_validation_failed", "HQPorner returned an empty media response.");
  const chunks: Uint8Array[] = [];
  let length = 0;
  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      if (length + value.byteLength > limit) throw new HQPornerRefreshError("media_validation_failed", "HQPorner media exceeded its validation limit.");
      chunks.push(value);
      length += value.byteLength;
    }
  } finally {
    await reader.cancel().catch(() => {});
  }
  const result = new Uint8Array(length);
  let offset = 0;
  for (const chunk of chunks) {
    result.set(chunk, offset);
    offset += chunk.byteLength;
  }
  return result;
}

async function validateQuality(quality: PlaybackQuality, fetcher: Fetcher, signal?: AbortSignal): Promise<PlaybackQuality> {
  const url = bigCDNURL(quality.url);
  let response: Response;
  try {
    response = await fetcher(url, {
      headers: { Range: "bytes=0-65535" },
      credentials: "omit",
      cache: "no-store",
      mode: "cors",
      redirect: "error",
      referrer: "https://hqporner.com/",
      referrerPolicy: "origin",
      signal: signal ? AbortSignal.any([signal, AbortSignal.timeout(15_000)]) : AbortSignal.timeout(15_000),
    });
  } catch (reason) {
    if (signal?.aborted) throw reason;
    throw new HQPornerRefreshError("cors_blocked", "The browser could not reach HQPorner media. Check privacy or content-blocking settings and retry.");
  }
  if (response.status !== 206) throw new HQPornerRefreshError("media_validation_failed", "HQPorner media did not support range validation.");
  if (!(response.headers.get("content-type") ?? "").toLowerCase().startsWith("video/mp4")) {
    throw new HQPornerRefreshError("media_validation_failed", "HQPorner returned a non-MP4 media response.");
  }
  const rawRange = response.headers.get("content-range");
  const range = rawRange?.match(/^bytes 0-(\d+)\/(\d+)$/i);
  if (rawRange && (!range || Number(range[1]) >= validationLimit || Number(range[1]) >= Number(range[2]))) {
    throw new HQPornerRefreshError("media_validation_failed", "HQPorner returned an invalid media range.");
  }
  const prefix = await boundedBytes(response, validationLimit);
  if (!rawRange && (prefix.length < 8 || prefix.length > validationLimit)) {
    throw new HQPornerRefreshError("media_validation_failed", "HQPorner returned an invalid bounded media response.");
  }
  if (prefix.length < 8 || String.fromCharCode(...prefix.slice(4, 8)) !== "ftyp") {
    throw new HQPornerRefreshError("media_validation_failed", "HQPorner returned an invalid MP4 signature.");
  }
  return quality;
}

export async function refreshHQPornerSources(clientResolverURL: string, fetcher: Fetcher = fetch, signal?: AbortSignal): Promise<PlaybackQuality[]> {
  const resolver = myDaddyURL(clientResolverURL);
  let response: Response;
  try {
    response = await fetcher(resolver, {
      credentials: "omit",
      cache: "no-store",
      mode: "cors",
      redirect: "error",
      referrer: "https://hqporner.com/",
      referrerPolicy: "origin",
      signal: signal ? AbortSignal.any([signal, AbortSignal.timeout(15_000)]) : AbortSignal.timeout(15_000),
    });
  } catch (reason) {
    if (signal?.aborted) throw reason;
    throw new HQPornerRefreshError("cors_blocked", "The browser could not refresh the HQPorner player. Check privacy or content-blocking settings and retry.");
  }
  if (!response.ok) throw new HQPornerRefreshError("embed_unavailable", "The HQPorner player is temporarily unavailable.");
  let html: string;
  try {
    html = new TextDecoder().decode(await boundedBytes(response, 500_000)).replaceAll("\\/", "/");
  } catch (reason) {
    if (reason instanceof HQPornerRefreshError) throw new HQPornerRefreshError("embed_unavailable", "The HQPorner player returned an invalid response.");
    throw reason;
  }
  const tags = html.match(/<source\b[^>]*>/gi) ?? [];
  const seen = new Set<string>();
  const candidates = tags.flatMap((tag): PlaybackQuality[] => {
    const src = tag.match(/\bsrc\s*=\s*\\?["']([^"'\\]+)\\?["']/i)?.[1];
    if (!src) return [];
    let url: URL;
    try { url = bigCDNURL(src, resolver); } catch { return []; }
    if (seen.has(url.href)) return [];
    seen.add(url.href);
    const label = (tag.match(/\b(?:title|label|res)\s*=\s*\\?["']([^"'\\]+)\\?["']/i)?.[1] || "Auto").slice(0, 80);
    return [{
      label,
      url: url.href,
      mediaKind: "video",
      headers: playbackHeaders,
      provider: "HQPorner",
      resolutionMethod: "native",
      infuseCompatibility: "verified",
    }];
  }).sort((left, right) => qualityHeight(right.label) - qualityHeight(left.label)).slice(0, 12);
  if (!candidates.length) throw new HQPornerRefreshError("no_sources", "HQPorner returned no trusted media sources.");
  const qualities: PlaybackQuality[] = [];
  for (let index = 0; index < candidates.length; index += 3) {
    const batch = await Promise.allSettled(candidates.slice(index, index + 3).map((quality) => validateQuality(quality, fetcher, signal)));
    qualities.push(...batch.flatMap((result) => result.status === "fulfilled" ? [result.value] : []));
  }
  if (!qualities.length) throw new HQPornerRefreshError("media_validation_failed", "HQPorner returned no playable MP4 sources. Refresh and try again.");
  return qualities;
}
