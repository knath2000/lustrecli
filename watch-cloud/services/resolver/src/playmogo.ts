import { feedPlaybackResolutionSchema, ResolverError, type FeedPlaybackResolution, type ResolutionProgressEvent } from "@lustre/contracts";
import { providerChromeUserAgent } from "@lustre/providers";
import { assertPublicDNS, parsePublicHTTPSURL, safeRequest, type SafeRequest, type SafeResponse } from "./safety.js";

type ProgressInput = ResolutionProgressEvent extends infer Event ? Event extends { at: string } ? Omit<Event, "at"> : never : never;
type Emit = (event: ProgressInput) => void;
type Request = (url: URL, options?: SafeRequest) => Promise<SafeResponse>;
type ValidateURL = (url: URL) => Promise<void>;

const playmogoSources = ["playmogo.com", "ds2play.com", "doodstream.com", "dood.wf", "vide0.net", "dooodster.com"];

function supportedSource(url: URL): boolean {
  return playmogoSources.some((host) => url.hostname === host || url.hostname.endsWith(`.${host}`));
}

function canonicalURL(sourceURL: URL): URL {
  if (!supportedSource(sourceURL)) throw new ResolverError("invalid_request", "Unsupported Playmogo provider host.", 400);
  const code = sourceURL.pathname.match(/^\/[de]\/([A-Za-z0-9_-]{1,128})\/?$/)?.[1];
  if (!code) throw new ResolverError("invalid_request", "Playmogo URL must contain a valid video code.", 400);
  if (["vide0.net", "dooodster.com"].some((host) => sourceURL.hostname === host || sourceURL.hostname.endsWith(`.${host}`))) {
    return new URL(`https://playmogo.com${sourceURL.pathname}`);
  }
  return sourceURL;
}

function embeddedPlayerURL(html: string, pageURL: URL): URL | undefined {
  const raw = html.replaceAll("\\/", "/").match(/<iframe\b[^>]*\bsrc\s*=\s*["']([^"']+)["']/i)?.[1];
  if (!raw) return undefined;
  try {
    const url = parsePublicHTTPSURL(new URL(raw, pageURL).href);
    return supportedSource(url) && /^\/e\/[A-Za-z0-9_-]{1,128}\/?$/.test(url.pathname) ? url : undefined;
  } catch { return undefined; }
}

function randomSuffix(): string {
  const alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789";
  const bytes = crypto.getRandomValues(new Uint8Array(10));
  return [...bytes].map((value) => alphabet[value % alphabet.length]).join("");
}

function mediaURL(value: string): URL {
  const url = parsePublicHTTPSURL(value);
  if (
    !(url.hostname === "cloudatacdn.com" || url.hostname.endsWith(".cloudatacdn.com"))
    || !url.pathname.includes("~")
    || !url.searchParams.has("token")
    || !url.searchParams.has("expiry")
  ) throw new ResolverError("provider_changed", "Playmogo returned an unsupported media host.");
  return url;
}

async function mediaWorks(url: URL, headers: Record<string, string>, request: Request, validateURL: ValidateURL): Promise<boolean> {
  try {
    await validateURL(url);
    const response = await request(url, { headers: { ...headers, Range: "bytes=0-65535" }, maxBytes: 65_536, redirectPolicy: "same-host" });
    return [200, 206].includes(response.status) && response.body.length > 0 && /video|octet-stream/i.test(response.contentType);
  } catch { return false; }
}

async function resolvePlaymogoInternal(sourceURL: URL, emit?: Emit, request: Request = safeRequest, validateURL: ValidateURL = assertPublicDNS): Promise<FeedPlaybackResolution> {
  let pageURL = canonicalURL(sourceURL);
  const pageHeaders = {
    "User-Agent": providerChromeUserAgent,
    Accept: "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
    "Accept-Language": "en-US,en;q=0.9",
  };
  emit?.({ type: "provider_started", provider: "Playmogo", message: "Requesting a fresh Playmogo media token." });
  let page = await request(pageURL, { headers: pageHeaders, maxBytes: 1_000_000 });
  if (page.status === 403) throw new ResolverError("verification_required", "Playmogo browser verification is required.", 409);
  if (page.status < 200 || page.status > 299) throw new ResolverError("provider_unavailable", "Playmogo player is unavailable.");
  if (page.finalURL.pathname.startsWith("/d/")) {
    const embedURL = embeddedPlayerURL(page.body, page.finalURL);
    if (!embedURL) throw new ResolverError("provider_changed", "Playmogo download page returned no trusted player.");
    pageURL = embedURL;
    page = await request(embedURL, { headers: { ...pageHeaders, Referer: page.finalURL.href }, maxBytes: 1_000_000 });
    if (page.status === 403) throw new ResolverError("verification_required", "Playmogo browser verification is required.", 409);
    if (page.status < 200 || page.status > 299) throw new ResolverError("provider_unavailable", "Playmogo player is unavailable.");
  }
  const normalized = page.body.replaceAll("\\/", "/");
  const passPath = normalized.match(/(?:\.get\(\s*|url\s*:\s*|fetch\(\s*)["']([^"']*\/pass_md5\/[^"']+)["']/i)?.[1]
    ?? normalized.match(/["']([^"']*\/pass_md5\/[^"']+)["']/i)?.[1];
  const tokenPrefix = normalized.match(/["']([^"']*\?token=[^"']+&expiry=)["']\s*\+\s*(?:Date\s*\.\s*now\s*\(\s*\)|\(new\s+Date\s*\(\s*\)\)\.getTime\s*\(\s*\))/i)?.[1]
    ?? normalized.match(/["']([^"']*\?token=[^"']+&expiry=)["']/i)?.[1];
  if (!passPath || !tokenPrefix) throw new ResolverError("provider_changed", "Playmogo token metadata changed.");
  const passURL = parsePublicHTTPSURL(new URL(passPath, page.finalURL).href);
  if (passURL.hostname !== page.finalURL.hostname) throw new ResolverError("provider_changed", "Playmogo returned an unsafe token endpoint.");
  const passHeaders = {
    "User-Agent": providerChromeUserAgent,
    Referer: page.finalURL.href,
    "X-Requested-With": "XMLHttpRequest",
    Accept: "*/*",
  };
  const pass = await request(passURL, { headers: passHeaders, maxBytes: 32_000, redirectPolicy: "same-host" });
  if (pass.status < 200 || pass.status > 299) throw new ResolverError("provider_unavailable", "Playmogo token endpoint is unavailable.");
  const url = mediaURL(`${pass.body.trim()}${randomSuffix()}${tokenPrefix}${Date.now()}`);
  const requiredHeaders = { Referer: page.finalURL.href, "User-Agent": providerChromeUserAgent };
  emit?.({ type: "metadata", title: (normalized.match(/<title[^>]*>(.*?)<\/title>/is)?.[1] ?? "Playmogo video").replace(/<[^>]+>/g, "").trim().slice(0, 1000), candidateCount: 1 });
  emit?.({ type: "validating", message: "Validating Playmogo’s fresh signed MP4 URL." });
  if (!await mediaWorks(url, requiredHeaders, request, validateURL)) throw new ResolverError("provider_unavailable", "Playmogo returned no validated MP4 source.");
  const bare = await mediaWorks(url, {}, request, validateURL);
  const quality = {
    label: "Video",
    url: url.href,
    mediaKind: "video" as const,
    headers: requiredHeaders,
    provider: "Playmogo",
    resolutionMethod: "native" as const,
    infuseCompatibility: bare ? "verified" as const : "header_required" as const,
  };
  const attempt = { provider: "Playmogo", status: "resolved" as const };
  emit?.({ type: "provider_completed", attempt, qualities: [quality] });
  return feedPlaybackResolutionSchema.parse({
    sourcePageURL: sourceURL.href,
    title: (normalized.match(/<title[^>]*>(.*?)<\/title>/is)?.[1] ?? "Playmogo video").replace(/<[^>]+>/g, "").trim().slice(0, 1000),
    providerAttempts: [attempt],
    qualities: [quality],
  });
}

export async function resolvePlaymogo(sourceURL: URL, emit?: Emit, request: Request = safeRequest, validateURL: ValidateURL = assertPublicDNS): Promise<FeedPlaybackResolution> {
  try { return await resolvePlaymogoInternal(sourceURL, emit, request, validateURL); }
  catch (reason) {
    const error = reason instanceof ResolverError ? reason : new ResolverError("provider_unavailable", "Playmogo is unavailable.");
    emit?.({ type: "provider_completed", attempt: { provider: "Playmogo", status: error.code === "verification_required" ? "verification_required" : "failed", message: error.message.slice(0, 300) }, qualities: [] });
    throw error;
  }
}
