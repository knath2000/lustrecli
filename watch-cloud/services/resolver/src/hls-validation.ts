import { ResolverError } from "@lustre/contracts";
import { assertPublicDNS, parsePublicHTTPSURL, safeRequest, type SafeRequest, type SafeResponse } from "./safety.js";

type Request = (url: URL, options?: SafeRequest) => Promise<SafeResponse>;
type ValidateURL = (url: URL) => Promise<void>;

export type HLSCandidate = { height: number; url: URL };

export function parseHLSVariants(body: string, playlistURL: URL): HLSCandidate[] {
  if (!body.trimStart().startsWith("#EXTM3U")) throw new ResolverError("provider_changed", "Provider returned an invalid HLS playlist.");
  const lines = body.split(/\r?\n/).map((line) => line.trim());
  const variants: HLSCandidate[] = [];
  const seen = new Set<string>();
  for (let index = 0; index < lines.length; index += 1) {
    const line = lines[index] ?? "";
    if (!line.startsWith("#EXT-X-STREAM-INF")) continue;
    const raw = lines[index + 1];
    if (!raw || raw.startsWith("#")) continue;
    let url: URL;
    try { url = parsePublicHTTPSURL(new URL(raw, playlistURL).href); } catch { continue; }
    if (seen.has(url.href)) continue;
    seen.add(url.href);
    variants.push({ height: Number(line.match(/RESOLUTION=\d+x(\d+)/i)?.[1] ?? 0), url });
  }
  return variants.sort((left, right) => right.height - left.height).slice(0, 12);
}

function firstMediaURL(body: string, playlistURL: URL): URL {
  if (!body.trimStart().startsWith("#EXTM3U")) throw new ResolverError("provider_changed", "Provider returned an invalid HLS media playlist.");
  const map = body.match(/#EXT-X-MAP:[^\n]*\bURI=["']([^"']+)["']/i)?.[1];
  const line = body.split(/\r?\n/).map((value) => value.trim()).find((value) => value && !value.startsWith("#"));
  const raw = map ?? line;
  if (!raw) throw new ResolverError("provider_changed", "Provider returned an empty HLS media playlist.");
  return parsePublicHTTPSURL(new URL(raw, playlistURL).href);
}

async function validateMediaPlaylist(
  playlistURL: URL,
  headers: Record<string, string>,
  request: Request,
  validateURL: ValidateURL,
): Promise<void> {
  await validateURL(playlistURL);
  const playlist = await request(playlistURL, { headers, maxBytes: 512_000, redirectPolicy: "same-host" });
  if (playlist.status < 200 || playlist.status > 299) throw new ResolverError("provider_unavailable", "Provider HLS quality is unavailable.");
  const mediaURL = firstMediaURL(playlist.body, playlist.finalURL);
  await validateURL(mediaURL);
  const media = await request(mediaURL, {
    headers: { ...headers, Range: "bytes=0-65535" },
    maxBytes: 65_536,
    redirectPolicy: "same-host",
  });
  if (
    ![200, 206].includes(media.status)
    || !media.body.length
    || (media.contentType && !/(?:video|audio|octet-stream|mp2t|mpegurl|mp4)/i.test(media.contentType))
  ) throw new ResolverError("provider_changed", "Provider returned an invalid HLS media segment.");
}

export async function validateHLSCandidates(
  masterBody: string,
  masterURL: URL,
  headers: Record<string, string>,
  request: Request = safeRequest,
  validateURL: ValidateURL = assertPublicDNS,
): Promise<HLSCandidate[]> {
  const variants = parseHLSVariants(masterBody, masterURL);
  const selected = variants.length ? variants : [{ height: 0, url: masterURL }];
  const valid: HLSCandidate[] = [];
  for (let offset = 0; offset < selected.length; offset += 3) {
    const settled = await Promise.allSettled(selected.slice(offset, offset + 3).map(async (candidate) => {
      await validateMediaPlaylist(candidate.url, headers, request, validateURL);
      return candidate;
    }));
    valid.push(...settled.flatMap((result) => result.status === "fulfilled" ? [result.value] : []));
  }
  if (!valid.length) throw new ResolverError("provider_unavailable", "Provider returned no validated HLS qualities.");
  return valid;
}
