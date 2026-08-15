import * as cheerio from "cheerio";
import type { FeedItem, FeedPage, FeedSite, FeedSiteID, FeedPlaybackResolution } from "@lustre/contracts";
export { parseAllPornStreamFeed, parseAllPornStreamPost } from "./allpornstream";
export type { AllPornStreamCandidate, AllPornStreamMetadata } from "./allpornstream";

export const providerChromeUserAgent = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 Chrome/136 Safari/537.36";

export const feedSites: FeedSite[] = [
  { id: "allpornstream", displayName: "AllPornStream", homeURL: "https://allpornstream.com", supportsSearch: true },
  { id: "hqporner", displayName: "HQPorner", homeURL: "https://hqporner.com", supportsSearch: true },
  { id: "onlyfan420", displayName: "OnlyFan420", homeURL: "https://rentry.co/OnlyFan420", supportsSearch: false },
  { id: "pornhub", displayName: "PornHub", homeURL: "https://www.pornhub.com", supportsSearch: true },
];

export const supportedSourceHosts = [
  "allpornstream.com", "streamtape.com", "doodstream.com", "hgcloud.to", "voe.sx", "byselapuix.com", "filemoon.to",
  "hqporner.com", "mydaddy.cc", "rentry.co", "pornhub.com",
  "luluvid.com", "luluvdo.com", "lulustream.com", "vidara.so",
  "playmogo.com", "ds2play.com", "doodstream.com", "dood.wf", "vide0.net", "dooodster.com",
] as const;

export function hostMatches(host: string, allowed: readonly string[]): boolean {
  const normalized = host.toLowerCase().replace(/\.$/, "");
  return allowed.some((candidate) => normalized === candidate || normalized.endsWith(`.${candidate}`));
}

export function providerForURL(value: string): FeedSiteID | "generic" | null {
  const url = new URL(value);
  if (hostMatches(url.hostname, ["allpornstream.com"])) return "allpornstream";
  if (hostMatches(url.hostname, ["hqporner.com", "mydaddy.cc"])) return "hqporner";
  if (hostMatches(url.hostname, ["pornhub.com"])) return "pornhub";
  if (hostMatches(url.hostname, ["rentry.co", "luluvid.com", "luluvdo.com", "lulustream.com", "vidara.so", "playmogo.com", "ds2play.com", "doodstream.com", "dood.wf", "vide0.net", "dooodster.com"])) return "onlyfan420";
  return hostMatches(url.hostname, supportedSourceHosts) ? "generic" : null;
}

function absoluteURL(value: string | undefined, base: string): string | undefined {
  if (!value) return undefined;
  try {
    const url = new URL(value, base);
    return url.protocol === "https:" && !url.username && !url.password ? url.href : undefined;
  } catch {
    return undefined;
  }
}

export function parseHQPorner(html: string, page: number, now = new Date()): FeedPage {
  const $ = cheerio.load(html);
  const items: FeedItem[] = [];
  const seen = new Set<string>();
  $("a[href*='/hdporn/']").each((_, anchor) => {
    const sourcePageURL = absoluteURL($(anchor).attr("href"), "https://hqporner.com");
    if (!sourcePageURL || seen.has(sourcePageURL)) return;
    const id = new URL(sourcePageURL).pathname.match(/^\/hdporn\/(\d+)/)?.[1];
    if (!id) return;
    const card = $(anchor).closest("article, li, .item, .video, .box").length ? $(anchor).closest("article, li, .item, .video, .box") : $(anchor);
    const title = ($(anchor).attr("title") || card.find("img").attr("alt") || $(anchor).text()).replace(/\s+/g, " ").trim();
    if (!title) return;
    const thumbnailURL = absoluteURL(card.find("img").first().attr("data-src") || card.find("img").first().attr("src"), "https://hqporner.com");
    const previewURLs = [...new Set(card.html()?.match(/https?:\\?\/\\?\/[^"'() ]+/g)?.map((url) => url.replaceAll("\\/", "/")).filter((url) => /\.(?:jpe?g|webp|png)(?:\?|$)/i.test(url)) ?? [])].slice(0, 4);
    seen.add(sourcePageURL);
    items.push({ id: `hqporner-${id}`, siteID: "hqporner", title, sourcePageURL, ...(thumbnailURL ? { thumbnailURL } : {}), previewURLs, uploadedAt: now.toISOString(), uploadedAtIsApproximate: true, viewCount: 0 });
  });
  return { items: items.slice(0, 50), page, hasMore: items.length > 0 };
}

const onlyFanHosts = ["luluvid.com", "luluvdo.com", "lulustream.com", "vidara.so", "playmogo.com", "ds2play.com", "doodstream.com", "dood.wf", "vide0.net", "dooodster.com"];

export function parseOnlyFan420(html: string, page: number): FeedPage {
  const $ = cheerio.load(html);
  const all: FeedItem[] = [];
  const seen = new Set<string>();
  $("a.external[href]").each((_, anchor) => {
    const sourcePageURL = absoluteURL($(anchor).attr("href"), "https://rentry.co/OnlyFan420");
    if (!sourcePageURL || !hostMatches(new URL(sourcePageURL).hostname, onlyFanHosts) || seen.has(sourcePageURL)) return;
    const title = $(anchor).clone().find("img").remove().end().text().replace(/\s+/g, " ").trim() || $(anchor).find("img").attr("alt")?.trim();
    if (!title) return;
    const thumbnailURL = absoluteURL($(anchor).find("img").attr("src"), "https://rentry.co/OnlyFan420");
    seen.add(sourcePageURL);
    all.push({ id: `${new URL(sourcePageURL).hostname}:${new URL(sourcePageURL).pathname}`, siteID: "onlyfan420", title, sourcePageURL, ...(thumbnailURL ? { thumbnailURL } : {}), previewURLs: [], uploadedAt: new Date(0).toISOString(), uploadedAtIsApproximate: true, viewCount: 0 });
  });
  const start = (page - 1) * 50;
  return { items: all.slice(start, start + 50), page, hasMore: start + 50 < all.length };
}

export function parsePornHub(html: string, page: number, now = new Date()): FeedPage {
  const $ = cheerio.load(html);
  const items: FeedItem[] = [];
  const seen = new Set<string>();
  $("li.pcVideoListItem").each((_, card) => {
    const element = $(card);
    if (/\b(?:advert|sponsor|premiumLocked)\b/i.test(element.attr("class") ?? "")) return;
    const key = element.attr("data-video-vkey");
    if (!key || !/^[A-Za-z0-9_-]{3,128}$/.test(key) || seen.has(key)) return;
    const anchor = element.find("a[href*='view_video.php']").first();
    const title = (anchor.attr("title") || element.find("a[title]").first().attr("title") || "").replace(/\s+/g, " ").trim();
    if (!title) return;
    const image = element.find("img").first();
    const thumbnailURL = absoluteURL(element.attr("data-image") || image.attr("data-image") || image.attr("data-mediumthumb") || image.attr("data-src") || image.attr("src"), "https://www.pornhub.com");
    const previewURL = absoluteURL(element.attr("data-mediabook") || image.attr("data-mediabook"), "https://www.pornhub.com");
    const rawViews = element.find(".views var").first().text().toLowerCase().replace(/views|,/g, "").trim();
    const multiplier = rawViews.endsWith("m") ? 1_000_000 : rawViews.endsWith("k") ? 1_000 : 1;
    const viewCount = Math.max(0, Math.floor((Number.parseFloat(multiplier === 1 ? rawViews : rawViews.slice(0, -1)) || 0) * multiplier));
    seen.add(key);
    items.push({
      id: `pornhub:${key}`,
      siteID: "pornhub",
      title,
      sourcePageURL: `https://www.pornhub.com/view_video.php?viewkey=${key}`,
      ...(thumbnailURL ? { thumbnailURL } : {}),
      previewURLs: previewURL ? [previewURL] : [],
      uploadedAt: now.toISOString(),
      uploadedAtIsApproximate: true,
      viewCount,
    });
  });
  if (!items.length && /cf-chl|just a moment|captcha|verify you are human|age verification|login to continue/i.test(html)) throw new Error("verification_required");
  const hasMore = $("a.page_next, a.next, a[rel='next']").length > 0;
  return { items: items.slice(0, 50), page, hasMore };
}

export function parseMydaddy(html: string, sourcePageURL: string): FeedPlaybackResolution | null {
  const normalized = html.replaceAll("\\/", "/");
  const $ = cheerio.load(normalized);
  const sourceTags = [
    ...$("source[src]").toArray().map((node) => $.html(node)),
    ...(normalized.match(/<source\b[^>]*>/gi) ?? []),
  ];
  const seen = new Set<string>();
  const qualities = sourceTags.flatMap((tag): FeedPlaybackResolution["qualities"] => {
    const src = tag.match(/\bsrc\s*=\s*\\?["']([^"'\\]+)\\?["']/i)?.[1];
    const url = absoluteURL(src, sourcePageURL);
    if (!url || seen.has(url)) return [];
    const label = tag.match(/\b(?:title|label|res)\s*=\s*\\?["']([^"'\\]+)\\?["']/i)?.[1] || "Auto";
    seen.add(url);
    return [{
      label: label.slice(0, 80),
      url,
      mediaKind: url.includes(".m3u8") ? "hls" as const : "video" as const,
      headers: { Referer: "https://hqporner.com/", "User-Agent": providerChromeUserAgent },
    }];
  }).sort((left, right) => {
    const resolution = (label: string) => Number(label.match(/(\d+)p/i)?.[1] ?? 0);
    return resolution(right.label) - resolution(left.label);
  }).slice(0, 12);
  if (!qualities.length) return null;
  return { sourcePageURL, title: $("title").text().replace(/\s+/g, " ").trim() || "HQPorner video", qualities };
}
