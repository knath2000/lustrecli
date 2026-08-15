import { feedPlaybackResolutionSchema, type FeedPlaybackResolution, type ResolutionProgressEvent } from "@lustre/contracts";
import { parseAllPornStreamPost, providerChromeUserAgent, type AllPornStreamCandidate } from "@lustre/providers";
import { parseSupportedURL, safeFetch } from "./safety.js";
import { resolvePlaymogo } from "./playmogo.js";

const headersFor = (url: string) => ({
  Referer: url,
  "User-Agent": providerChromeUserAgent,
  Accept: "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
  "Accept-Language": "en-US,en;q=0.9",
});

type Quality = FeedPlaybackResolution["qualities"][number];
type Attempt = NonNullable<FeedPlaybackResolution["providerAttempts"]>[number];
type ProgressInput = ResolutionProgressEvent extends infer Event ? Event extends { at: string } ? Omit<Event, "at"> : never : never;
type Emit = (event: ProgressInput) => void;

function mediaURLs(html: string, base: string): string[] {
  const normalized = html.replaceAll("\\/", "/").replaceAll("\\u0026", "&");
  const matches = normalized.match(/https?:\/\/[^"'\\\s<>]+?\.(?:m3u8|mp4)(?:\?[^"'\\\s<>]*)?|\/\/[^"'\\\s<>]+?\.(?:m3u8|mp4)(?:\?[^"'\\\s<>]*)?/gi) ?? [];
  return [...new Set(matches.flatMap((raw) => {
    try {
      const url = new URL(raw, base);
      return url.protocol === "https:" && !url.username && !url.password ? [url.href] : [];
    } catch { return []; }
  }))];
}

function quality(provider: string, url: string, referer: string, label = "Auto"): Quality {
  return {
    label: `${provider} · ${label}`.slice(0, 80),
    url,
    mediaKind: new URL(url).pathname.endsWith(".m3u8") ? "hls" : "video",
    headers: { Referer: referer, "User-Agent": providerChromeUserAgent },
    provider,
    resolutionMethod: "native",
  };
}

function streamTapeURL(html: string, sourceURL: string): string | undefined {
  const path = html.match(/id=["']robotlink["'][^>]*>\s*(\/\/[^<]+|\/streamtape\.com\/get_video[^<]+)</i)?.[1]
    ?? html.match(/id=["']ideoolink["'][^>]*>\s*(\/\/[^<]+|\/streamtape\.com\/get_video[^<]+)</i)?.[1];
  if (!path) return undefined;
  try {
    const url = new URL(path.replace(/^\/streamtape\.com\//, "/"), sourceURL);
    return url.protocol === "https:" ? url.href : undefined;
  } catch { return undefined; }
}

async function resolveCandidate(candidate: AllPornStreamCandidate, emit?: Emit): Promise<{ attempt: Attempt; qualities: Quality[] }> {
  const provider = candidate.provider;
  emit?.({ type: "provider_started", provider, message: `Checking ${provider} for playable sources.` });
  const supported = /^(STREAMTAPE|DOODSTREAM|PLAYMOGO|VIDE0(?:\.NET)?|HGCLOUD\.TO|VOE|BYSE)$/i.test(provider);
  if (!supported) {
    const result = { attempt: { provider, status: "unsupported" as const, message: "No native resolver is installed for this provider." }, qualities: [] };
    emit?.({ type: "provider_completed", ...result });
    return result;
  }
  try {
    const source = parseSupportedURL(candidate.sourceURL);
    if (/^(DOODSTREAM|PLAYMOGO|VIDE0(?:\.NET)?)$/i.test(provider)) {
      const resolution = await resolvePlaymogo(source);
      const qualities = resolution.qualities.map((item) => ({
        ...item,
        label: `${provider} · ${item.label}`.slice(0, 80),
      }));
      const result = { attempt: { provider, status: "resolved" as const }, qualities };
      emit?.({ type: "provider_completed", ...result });
      return result;
    }
    const response = await safeFetch(source, headersFor("https://allpornstream.com/"));
    if (response.status === 403 || /cf-chl|just a moment|verify you are human|checking your browser/i.test(response.body)) {
      const result = { attempt: { provider, status: "verification_required" as const, message: "Browser verification is required." }, qualities: [] };
      emit?.({ type: "provider_completed", ...result });
      return result;
    }
    const direct = provider === "STREAMTAPE" ? streamTapeURL(response.body, source.href) : undefined;
    if (provider === "STREAMTAPE" && direct) {
      const result = { attempt: { provider, status: "verification_required" as const, message: "StreamTape media tokens must be minted on the playback device." }, qualities: [] };
      emit?.({ type: "provider_completed", ...result });
      return result;
    }
    const urls = direct ? [direct] : mediaURLs(response.body, response.finalURL.href);
    if (urls.length) {
      const result = {
        attempt: { provider, status: "resolved" },
        qualities: urls.slice(0, 4).map((url, index) => quality(provider, url, response.finalURL.href, urls.length === 1 ? "Auto" : `Source ${index + 1}`)),
      } satisfies { attempt: Attempt; qualities: Quality[] };
      emit?.({ type: "provider_completed", ...result });
      return result;
    }
    const result = { attempt: { provider, status: "verification_required" as const, message: "This provider requires browser execution." }, qualities: [] };
    emit?.({ type: "provider_completed", ...result });
    return result;
  } catch (reason) {
    const message = reason instanceof Error && /timeout/i.test(reason.message) ? "Native resolution timed out." : "Native resolution failed.";
    const result = { attempt: { provider, status: "verification_required" as const, message }, qualities: [] };
    emit?.({ type: "provider_completed", ...result });
    return result;
  }
}

export async function resolveAllPornStream(sourceURL: URL, emit?: Emit): Promise<FeedPlaybackResolution> {
  const outer = await safeFetch(sourceURL, headersFor("https://allpornstream.com/"));
  const metadata = parseAllPornStreamPost(outer.body, outer.finalURL.href);
  const candidates = metadata.candidates.slice(0, 12);
  emit?.({ type: "metadata", title: metadata.title ?? "AllPornStream video", ...(metadata.thumbnailURL ? { thumbnailURL: metadata.thumbnailURL } : {}), candidateCount: candidates.length });
  const results: Array<{ attempt: Attempt; qualities: Quality[] }> = [];
  for (let offset = 0; offset < candidates.length; offset += 3) {
    results.push(...await Promise.all(candidates.slice(offset, offset + 3).map((candidate) =>
      Promise.race([
        resolveCandidate(candidate, emit),
        new Promise<{ attempt: Attempt; qualities: Quality[] }>((resolve) => setTimeout(() => resolve({
          attempt: { provider: candidate.provider, status: "verification_required", message: "Native resolution timed out." },
          qualities: [],
        }), 15_000)),
      ])
    )));
  }
  const qualities = results.flatMap((result) => result.qualities).slice(0, 12);
  emit?.({ type: "validating", message: `Validating ${qualities.length} resolved source${qualities.length === 1 ? "" : "s"}.` });
  if (!qualities.length) {
    const error = new Error("Browser assistance is required for the available AllPornStream providers.");
    Object.assign(error, { code: "verification_required", status: 409, providerAttempts: results.map((result) => result.attempt) });
    throw error;
  }
  return feedPlaybackResolutionSchema.parse({
    sourcePageURL: sourceURL.href,
    title: metadata.title ?? "AllPornStream video",
    ...(metadata.thumbnailURL ? { thumbnailURL: metadata.thumbnailURL } : {}),
    providerAttempts: results.map((result) => result.attempt),
    qualities,
  });
}
