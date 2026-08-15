import { feedPlaybackResolutionSchema, ResolverError, type FeedPlaybackResolution, type ResolutionProgressEvent } from "@lustre/contracts";
import { providerChromeUserAgent } from "@lustre/providers";
import { assertPublicDNS, parsePublicHTTPSURL, safeRequest, type SafeRequest, type SafeResponse } from "./safety.js";
import { parseHLSVariants, validateHLSCandidates } from "./hls-validation.js";

type ProgressInput = ResolutionProgressEvent extends infer Event ? Event extends { at: string } ? Omit<Event, "at"> : never : never;
type Emit = (event: ProgressInput) => void;
type Request = (url: URL, options?: SafeRequest) => Promise<SafeResponse>;
type ValidateURL = (url: URL) => Promise<void>;

const headers = {
  Referer: "https://vidara.so/",
  "User-Agent": providerChromeUserAgent,
};

export function vidaraFilecode(url: URL): string {
  const match = url.pathname.match(/^\/[ved]\/([A-Za-z0-9_-]{1,128})\/?$/);
  if (!match?.[1]) throw new ResolverError("invalid_request", "Vidara URL must contain a valid video code.", 400);
  return match[1];
}

function optionalPublicURL(value: unknown): string | undefined {
  if (typeof value !== "string") return undefined;
  try { return parsePublicHTTPSURL(value).href; }
  catch { return undefined; }
}

export function parseVidaraMaster(body: string, masterURL: URL): Array<{ height: number; url: URL }> {
  return parseHLSVariants(body, masterURL);
}

function statusError(status: number): never {
  if (status === 403) throw new ResolverError("verification_required", "Vidara verification is required.", 409);
  if (status === 429) throw new ResolverError("rate_limit", "Vidara rate limit reached.", 429);
  throw new ResolverError("provider_unavailable", "Vidara is unavailable.");
}

async function resolveVidaraInternal(
  sourceURL: URL,
  emit?: Emit,
  request: Request = safeRequest,
  validateURL: ValidateURL = assertPublicDNS,
): Promise<FeedPlaybackResolution> {
  const filecode = vidaraFilecode(sourceURL);
  emit?.({ type: "provider_started", provider: "Vidara", message: "Requesting Vidara stream metadata." });
  const api = await request(new URL("https://vidara.so/api/stream"), {
    method: "POST",
    headers: { ...headers, "Content-Type": "application/json" },
    body: JSON.stringify({ filecode, device: "web" }),
    maxBytes: 256_000,
    redirectPolicy: "same-host",
  });
  if (api.status < 200 || api.status > 299) statusError(api.status);
  if (!api.contentType.toLowerCase().includes("application/json")) {
    throw new ResolverError("provider_changed", "Vidara returned unexpected metadata.");
  }
  let metadata: Record<string, unknown>;
  try { metadata = JSON.parse(api.body) as Record<string, unknown>; }
  catch { throw new ResolverError("provider_changed", "Vidara returned malformed metadata."); }
  const title = typeof metadata.title === "string" && metadata.title.trim() ? metadata.title.trim().slice(0, 1000) : `Vidara ${filecode}`;
  let thumbnailURL = optionalPublicURL(metadata.thumbnail);
  if (thumbnailURL) {
    try { await validateURL(new URL(thumbnailURL)); }
    catch { thumbnailURL = undefined; }
  }
  const streamValue = metadata.streaming_url;
  if (typeof streamValue !== "string") throw new ResolverError("provider_changed", "Vidara returned no HLS stream.");
  let masterURL: URL;
  try { masterURL = parsePublicHTTPSURL(streamValue); }
  catch { throw new ResolverError("provider_changed", "Vidara returned an unsafe HLS stream."); }
  await validateURL(masterURL);
  emit?.({ type: "metadata", title, ...(thumbnailURL ? { thumbnailURL } : {}), candidateCount: 1 });
  emit?.({ type: "validating", message: "Validating Vidara’s signed HLS playlist." });
  const playlist = await request(masterURL, {
    headers: {},
    maxBytes: 512_000,
    redirectPolicy: "same-host",
  });
  if (playlist.status < 200 || playlist.status > 299) statusError(playlist.status);
  const selected = await validateHLSCandidates(playlist.body, playlist.finalURL, {}, request, validateURL);
  const qualities = selected.map(({ height, url }) => ({
    label: height > 0 ? `${height}p` : "Master",
    url: url.href,
    mediaKind: "hls" as const,
    headers,
    provider: "Vidara",
    resolutionMethod: "native" as const,
    infuseCompatibility: "verified" as const,
  }));
  const attempt = { provider: "Vidara", status: "resolved" as const };
  emit?.({ type: "provider_completed", attempt, qualities: qualities.slice(0, 4) });
  return feedPlaybackResolutionSchema.parse({
    sourcePageURL: sourceURL.href,
    title,
    ...(thumbnailURL ? { thumbnailURL } : {}),
    providerAttempts: [attempt],
    qualities,
  });
}

export async function resolveVidara(
  sourceURL: URL,
  emit?: Emit,
  request: Request = safeRequest,
  validateURL: ValidateURL = assertPublicDNS,
): Promise<FeedPlaybackResolution> {
  try {
    return await resolveVidaraInternal(sourceURL, emit, request, validateURL);
  } catch (reason) {
    const error = reason instanceof ResolverError ? reason : new ResolverError("provider_unavailable", "Vidara is unavailable.");
    emit?.({
      type: "provider_completed",
      attempt: {
        provider: "Vidara",
        status: error.code === "verification_required" ? "verification_required" : "failed",
        message: error.message.slice(0, 300),
      },
      qualities: [],
    });
    throw error;
  }
}
