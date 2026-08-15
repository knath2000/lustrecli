import { feedPlaybackResolutionSchema, ResolverError, type FeedPlaybackResolution, type ResolutionProgressEvent } from "@lustre/contracts";
import { providerChromeUserAgent } from "@lustre/providers";
import { validateHLSCandidates } from "./hls-validation.js";
import { decodePackedJavaScript } from "./packed-javascript.js";
import { assertPublicDNS, parsePublicHTTPSURL, safeRequest, type SafeRequest, type SafeResponse } from "./safety.js";

type ProgressInput = ResolutionProgressEvent extends infer Event ? Event extends { at: string } ? Omit<Event, "at"> : never : never;
type Emit = (event: ProgressInput) => void;
type Request = (url: URL, options?: SafeRequest) => Promise<SafeResponse>;
type ValidateURL = (url: URL) => Promise<void>;

const luluHosts = ["luluvid.com", "luluvdo.com", "lulustream.com"];

function luluCode(url: URL): string {
  if (!luluHosts.some((host) => url.hostname === host || url.hostname.endsWith(`.${host}`))) throw new ResolverError("invalid_request", "Unsupported Lulu provider host.", 400);
  const parts = url.pathname.split("/").filter(Boolean);
  const code = parts.length >= 2 && ["d", "e", "w"].includes(parts.at(-2) ?? "") ? parts.at(-1) : parts.at(-1)?.split(".")[0];
  if (!code || !/^[A-Za-z0-9_-]{1,128}$/.test(code)) throw new ResolverError("invalid_request", "Lulu URL must contain a valid video code.", 400);
  return code;
}

function firstM3U8(html: string): string | undefined {
  const sources = [html, ...decodePackedJavaScript(html)];
  for (const source of sources) {
    const value = source.replaceAll("\\/", "/").match(/["'](https:\/\/[^"'\\\s]+\.m3u8[^"'\\\s]*)["']/i)?.[1];
    if (value) return value;
  }
  return undefined;
}

function title(html: string): string {
  return (html.match(/<title[^>]*>(.*?)<\/title>/is)?.[1] ?? "LuluVDO video").replace(/<[^>]+>/g, "").replace(/\s+/g, " ").trim().slice(0, 1000);
}

function thumbnail(html: string): string | undefined {
  const raw = html.match(/<meta[^>]+(?:property=["']og:image["'][^>]+content|content)=["']([^"']+)["']/i)?.[1];
  if (!raw) return undefined;
  try { return parsePublicHTTPSURL(raw).href; } catch { return undefined; }
}

async function resolveLuluInternal(sourceURL: URL, emit?: Emit, request: Request = safeRequest, validateURL: ValidateURL = assertPublicDNS): Promise<FeedPlaybackResolution> {
  const code = luluCode(sourceURL);
  const wrapperURL = new URL(`https://luluvid.com/d/${code}`);
  const embedURL = new URL(`https://luluvdo.com/e/${code}`);
  const pageHeaders = { "User-Agent": providerChromeUserAgent, Referer: "https://luluvid.com/" };
  emit?.({ type: "provider_started", provider: "LuluVDO", message: "Inspecting the LuluVDO packed player." });
  const embed = await request(embedURL, { headers: pageHeaders, maxBytes: 1_000_000 });
  if (embed.status === 403) throw new ResolverError("verification_required", "LuluVDO browser verification is required.", 409);
  if (embed.status < 200 || embed.status > 299) throw new ResolverError("provider_unavailable", "LuluVDO player is unavailable.");
  if (!luluHosts.some((host) => embed.finalURL.hostname === host || embed.finalURL.hostname.endsWith(`.${host}`))) {
    throw new ResolverError("provider_changed", "LuluVDO redirected to an unsupported player.");
  }
  let wrapper = embed;
  try {
    const candidate = await request(wrapperURL, { headers: pageHeaders, maxBytes: 1_000_000 });
    if (
      candidate.status >= 200
      && candidate.status <= 299
      && luluHosts.some((host) => candidate.finalURL.hostname === host || candidate.finalURL.hostname.endsWith(`.${host}`))
    ) wrapper = candidate;
  } catch {}
  const rawMaster = firstM3U8(embed.body);
  if (!rawMaster) throw new ResolverError("provider_changed", "LuluVDO returned no HLS source.");
  const masterURL = parsePublicHTTPSURL(new URL(rawMaster, embed.finalURL).href);
  await validateURL(masterURL);
  const mediaHeaders = { "User-Agent": providerChromeUserAgent, Referer: embedURL.href };
  emit?.({ type: "metadata", title: title(wrapper.body), ...(thumbnail(wrapper.body) ? { thumbnailURL: thumbnail(wrapper.body) } : {}), candidateCount: 1 });
  emit?.({ type: "validating", message: "Validating LuluVDO HLS playlists and media segments." });
  const master = await request(masterURL, { headers: mediaHeaders, maxBytes: 512_000, redirectPolicy: "same-host" });
  if (master.status < 200 || master.status > 299) throw new ResolverError("provider_unavailable", "LuluVDO HLS source is unavailable.");
  const nativeCandidates = await validateHLSCandidates(master.body, master.finalURL, mediaHeaders, request, validateURL);
  let bareCandidates: typeof nativeCandidates = [];
  try {
    const bareMaster = await request(masterURL, { headers: {}, maxBytes: 512_000, redirectPolicy: "same-host" });
    if (bareMaster.status >= 200 && bareMaster.status <= 299) bareCandidates = await validateHLSCandidates(bareMaster.body, bareMaster.finalURL, {}, request, validateURL);
  } catch {}
  const bareURLs = new Set(bareCandidates.map(({ url }) => url.href));
  const qualities = nativeCandidates.map(({ height, url }) => ({
    label: height > 0 ? `${height}p` : "Master",
    url: url.href,
    mediaKind: "hls" as const,
    headers: mediaHeaders,
    provider: "LuluVDO",
    resolutionMethod: "native" as const,
    infuseCompatibility: bareURLs.has(url.href) ? "verified" as const : "header_required" as const,
  }));
  const attempt = { provider: "LuluVDO", status: "resolved" as const };
  emit?.({ type: "provider_completed", attempt, qualities: qualities.slice(0, 4) });
  const poster = thumbnail(wrapper.body);
  return feedPlaybackResolutionSchema.parse({
    sourcePageURL: sourceURL.href,
    title: title(wrapper.body),
    ...(poster ? { thumbnailURL: poster } : {}),
    providerAttempts: [attempt],
    qualities,
  });
}

export async function resolveLulu(sourceURL: URL, emit?: Emit, request: Request = safeRequest, validateURL: ValidateURL = assertPublicDNS): Promise<FeedPlaybackResolution> {
  try { return await resolveLuluInternal(sourceURL, emit, request, validateURL); }
  catch (reason) {
    const error = reason instanceof ResolverError ? reason : new ResolverError("provider_unavailable", "LuluVDO is unavailable.");
    emit?.({ type: "provider_completed", attempt: { provider: "LuluVDO", status: error.code === "verification_required" ? "verification_required" : "failed", message: error.message.slice(0, 300) }, qualities: [] });
    throw error;
  }
}
