import * as cheerio from "cheerio";
import type { FeedPage } from "@lustre/contracts";

const baseURL = "https://allpornstream.com";

function httpsURL(value: unknown, base = baseURL): string | undefined {
  if (typeof value !== "string") return undefined;
  try {
    const url = new URL(value, base);
    return url.protocol === "https:" && !url.username && !url.password ? url.href : undefined;
  } catch {
    return undefined;
  }
}

function visit(value: unknown, callback: (record: Record<string, unknown>) => void): void {
  if (!value || typeof value !== "object") return;
  if (!Array.isArray(value)) callback(value as Record<string, unknown>);
  for (const child of Object.values(value)) {
    if (Array.isArray(child)) child.forEach((item) => visit(item, callback));
    else visit(child, callback);
  }
}

export function parseAllPornStreamFeed(html: string, page: number): FeedPage {
  const $ = cheerio.load(html);
  const items: FeedPage["items"] = [];
  const seen = new Set<string>();
  $("script[type='application/ld+json']").each((_, script) => {
    let root: unknown;
    try { root = JSON.parse($(script).text()); } catch { return; }
    visit(root, (record) => {
      if (record["@type"] !== "VideoObject") return;
      const sourcePageURL = httpsURL(record.url);
      const path = sourcePageURL ? new URL(sourcePageURL).pathname : "";
      const id = path.match(/^\/post\/([0-9a-f-]{36})\//i)?.[1];
      const title = typeof record.name === "string" ? record.name.replace(/\s+/g, " ").trim() : "";
      if (!sourcePageURL || !id || !title || seen.has(sourcePageURL)) return;
      const rawThumbnails = Array.isArray(record.thumbnailUrl) ? record.thumbnailUrl : [record.thumbnailUrl];
      const card = $(`[data-href="${path}"],[data-slug="${path}"]`).first();
      let dataImages: unknown[] = [];
      try { dataImages = JSON.parse(card.attr("data-images") ?? "[]") as unknown[]; } catch {}
      const images = [...dataImages, ...rawThumbnails].flatMap((value) => {
        const direct = httpsURL(value);
        if (!direct) return [];
        const proxy = new URL("/api/images", baseURL);
        proxy.searchParams.set("src", direct);
        proxy.searchParams.set("width", "384");
        proxy.searchParams.set("quality", "60");
        return [proxy.href];
      });
      const uniqueImages = [...new Set(images)].slice(0, 5);
      const interaction = Array.isArray(record.interactionStatistic) ? record.interactionStatistic[0] : record.interactionStatistic;
      const viewCount = interaction && typeof interaction === "object" ? Number((interaction as Record<string, unknown>).userInteractionCount) : 0;
      const uploadedAt = typeof record.uploadDate === "string" && !Number.isNaN(Date.parse(record.uploadDate)) ? new Date(record.uploadDate).toISOString() : new Date(0).toISOString();
      const studio = title.match(/^\[([^\]]+)\]/)?.[1]?.trim();
      seen.add(sourcePageURL);
      items.push({
        id: `allpornstream-${id}`,
        siteID: "allpornstream",
        title,
        sourcePageURL,
        ...(uniqueImages[0] ? { thumbnailURL: uniqueImages[0] } : {}),
        previewURLs: uniqueImages.slice(1, 5),
        uploadedAt,
        uploadedAtIsApproximate: false,
        viewCount: Number.isSafeInteger(viewCount) && viewCount >= 0 ? viewCount : 0,
        ...(studio ? { studio } : {}),
      });
    });
  });
  if (!items.length && /just a moment|verify you are human|checking your browser|cf-chl/i.test(html)) throw new Error("verification_required");
  return { items: items.slice(0, 50), page, hasMore: items.length >= 50 || $("a[rel='next']").length > 0 };
}

export type AllPornStreamCandidate = {
  provider: string;
  sourceURL: string;
};

export type AllPornStreamMetadata = {
  title?: string;
  thumbnailURL?: string;
  candidates: AllPornStreamCandidate[];
};

export function parseAllPornStreamPost(html: string, sourcePageURL: string): AllPornStreamMetadata {
  const normalized = html.replaceAll("\\/", "/").replaceAll('\\"', '"');
  const $ = cheerio.load(normalized);
  const title = $("meta[property='og:title']").attr("content")?.trim() || $("title").text().trim() || undefined;
  const thumbnailURL = httpsURL($("meta[property='og:image']").attr("content"), sourcePageURL);
  const candidates: AllPornStreamCandidate[] = [];
  const seen = new Set<string>();
  const candidateKey = (provider: string, sourceURL: string) => `${provider}:${new URL(sourceURL).pathname.split("/").filter(Boolean).at(-1) ?? sourceURL}`;
  const objectPattern = /\{[^{}]{0,4000}?"embed_url"\s*:\s*"([^"]+)"[^{}]{0,4000}?"hosting_provider"\s*:\s*"([^"]+)"[^{}]*\}|\{[^{}]{0,4000}?"hosting_provider"\s*:\s*"([^"]+)"[^{}]{0,4000}?"embed_url"\s*:\s*"([^"]+)"[^{}]*\}/gi;
  for (const match of normalized.matchAll(objectPattern)) {
    const rawURL = match[1] ?? match[4];
    const provider = (match[2] ?? match[3])?.trim().toUpperCase();
    const sourceURL = httpsURL(rawURL, sourcePageURL);
    if (!provider || !sourceURL) continue;
    const key = candidateKey(provider, sourceURL);
    if (seen.has(key)) continue;
    seen.add(key);
    candidates.push({ provider, sourceURL });
  }
  const pairPattern = /\[\s*"([^"]{1,80})"\s*,\s*"(https:[^"]+)"\s*\]/gi;
  for (const match of normalized.matchAll(pairPattern)) {
    const provider = match[1]?.trim().toUpperCase();
    const sourceURL = httpsURL(match[2], sourcePageURL);
    if (!provider || !sourceURL) continue;
    const key = candidateKey(provider, sourceURL);
    if (seen.has(key)) continue;
    seen.add(key);
    candidates.push({ provider, sourceURL });
  }
  return { ...(title ? { title } : {}), ...(thumbnailURL ? { thumbnailURL } : {}), candidates: candidates.slice(0, 12) };
}
