import { spawn } from "node:child_process";
import { feedPlaybackResolutionSchema, ResolverError, type FeedPlaybackResolution } from "@lustre/contracts";

const maxOutputBytes = 2_000_000;

export async function resolveWithYtDlp(sourcePageURL: string, binary = process.env.YT_DLP_PATH || "yt-dlp"): Promise<FeedPlaybackResolution> {
  const args = ["--dump-single-json", "--no-playlist", "--no-download", "--no-warnings", "--socket-timeout", "20", "--", sourcePageURL];
  const child = spawn(binary, args, { stdio: ["ignore", "pipe", "pipe"], env: { PATH: process.env.PATH ?? "" } });
  const output: Buffer[] = [];
  let size = 0;
  let stderr = "";
  const timer = setTimeout(() => child.kill("SIGKILL"), 45_000);
  child.stdout.on("data", (chunk: Buffer) => {
    size += chunk.length;
    if (size > maxOutputBytes) child.kill("SIGKILL");
    else output.push(chunk);
  });
  child.stderr.on("data", (chunk: Buffer) => { stderr = (stderr + chunk.toString()).slice(-4_000); });
  const exitCode = await new Promise<number | null>((resolve, reject) => {
    child.once("error", reject);
    child.once("close", resolve);
  }).finally(() => clearTimeout(timer));
  if (size > maxOutputBytes) throw new ResolverError("provider_changed", "Resolver metadata exceeded the output limit.");
  if (exitCode !== 0) {
    const verification = /captcha|sign in|login|verification|age.?verify/i.test(stderr);
    console.error("[resolver:yt-dlp] extraction failed", { exitCode, verification, stderrBytes: Buffer.byteLength(stderr) });
    throw new ResolverError(verification ? "verification_required" : "provider_unavailable", verification ? "Provider verification is required." : "Provider resolver is unavailable.");
  }
  let metadata: Record<string, unknown>;
  try { metadata = JSON.parse(Buffer.concat(output).toString()) as Record<string, unknown>; }
  catch { throw new ResolverError("provider_changed", "Provider returned malformed metadata."); }
  const formats = Array.isArray(metadata.formats) ? metadata.formats : [];
  const seen = new Set<string>();
  const qualities = formats.flatMap((format): FeedPlaybackResolution["qualities"] => {
    if (!format || typeof format !== "object") return [];
    const row = format as Record<string, unknown>;
    if (typeof row.url !== "string" || seen.has(row.url)) return [];
    let url: URL;
    try { url = new URL(row.url); } catch { return []; }
    if (url.protocol !== "https:" || url.username || url.password) return [];
    seen.add(row.url);
    const label = String(row.format_note || row.resolution || row.format_id || "Auto").slice(0, 80);
    return [{ label, url: row.url, mediaKind: row.protocol === "m3u8_native" || url.pathname.endsWith(".m3u8") ? "hls" : "video", headers: {} }];
  }).slice(0, 12);
  const candidate = {
    sourcePageURL,
    title: typeof metadata.title === "string" ? metadata.title : "Video",
    ...(typeof metadata.thumbnail === "string" && metadata.thumbnail.startsWith("https://") ? { thumbnailURL: metadata.thumbnail } : {}),
    qualities,
  };
  const parsed = feedPlaybackResolutionSchema.safeParse(candidate);
  if (!parsed.success) throw new ResolverError("provider_changed", "Provider returned no safe playable formats.");
  return parsed.data;
}
