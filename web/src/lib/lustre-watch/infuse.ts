import type { FeedPlaybackResolution } from "@/lib/lustre-watch/contracts";

type PlaybackQuality = FeedPlaybackResolution["qualities"][number];

export function infuseFilename(title: string, mediaKind: PlaybackQuality["mediaKind"]): string {
  const extension = mediaKind === "hls" ? ".m3u8" : ".mp4";
  const normalized = title
    .normalize("NFKC")
    .replace(/[\u0000-\u001f\u007f/\\]+/g, " ")
    .replace(/\s+/g, " ")
    .trim()
    .replace(/\.(?:m3u8|mp4)$/i, "");
  const basename = Array.from(normalized || "Lustre Watch").slice(0, 120).join("").trim();
  return `${basename || "Lustre Watch"}${extension}`;
}

export function infusePlaybackURL(title: string, quality: PlaybackQuality): string {
  const media = new URL(quality.url);
  if (media.protocol !== "https:" || media.username || media.password) throw new Error("Infuse requires a credential-free HTTPS media URL.");
  const deepLink = new URL("infuse://x-callback-url/play");
  deepLink.searchParams.set("url", media.href);
  deepLink.searchParams.set("filename", infuseFilename(title, quality.mediaKind));
  return deepLink.href;
}
