import Fastify from "fastify";
import { feedPageSchema, feedPlaybackResolutionSchema, feedSiteIDSchema, resolutionProgressEventSchema, resolveRequestSchema, ResolverError, type FeedPlaybackResolution, type ResolutionProgressEvent } from "@lustre/contracts";
import { feedSites, parseAllPornStreamFeed, parseHQPorner, parseMydaddy, parseOnlyFan420, parsePornHub, providerChromeUserAgent, providerForURL } from "@lustre/providers";
import { parseSupportedURL, safeFetch } from "./safety.js";
import { resolveWithYtDlp } from "./ytdlp.js";
import { resolveAllPornStream } from "./allpornstream.js";
import { resolveVidara } from "./vidara.js";
import { resolveLulu } from "./lulu.js";
import { resolvePlaymogo } from "./playmogo.js";

const app = Fastify({
  logger: { redact: ["req.headers", "res.headers", "request.body", "response.body"] },
  bodyLimit: 16_384,
});
type ProgressInput = ResolutionProgressEvent extends infer Event ? Event extends { at: string } ? Omit<Event, "at"> : never : never;
type Emit = (event: ProgressInput) => void;

app.get("/healthz", async () => ({ ok: true }));
app.get("/internal/feed/sites", async () => feedSites);
app.get("/internal/feed", async (request) => {
  const query = request.query as Record<string, string>;
  const site = feedSiteIDSchema.safeParse(query.site);
  const page = Number(query.page || "1");
  const search = query.q?.trim().replace(/\s+/g, " ");
  if (!site.success || !Number.isSafeInteger(page) || page < 1 || (search?.length ?? 0) > 120) throw new ResolverError("invalid_request", "Invalid feed query.", 400);
  let url: URL;
  if (site.data === "allpornstream") {
    const params = new URLSearchParams();
    if (search) params.set("s", search);
    if (page > 1) params.set("page", String(page));
    url = new URL(`/${params.size ? `?${params}` : ""}`, "https://allpornstream.com");
  } else if (site.data === "hqporner") {
    url = search ? new URL(`/?q=${encodeURIComponent(search)}${page > 1 ? `&p=${page}` : ""}`, "https://hqporner.com") : new URL(page === 1 ? "/" : `/hdporn/${page}`, "https://hqporner.com");
  } else if (site.data === "onlyfan420") {
    url = new URL("https://rentry.co/OnlyFan420");
  } else {
    url = search ? new URL(`/video/search?search=${encodeURIComponent(search)}&page=${page}`, "https://www.pornhub.com") : new URL(`/?page=${page}`, "https://www.pornhub.com");
  }
  const response = await safeFetch(url, { "User-Agent": providerChromeUserAgent, Referer: `${url.origin}/` });
  if (response.status === 403) throw new ResolverError("verification_required", "Provider verification is required.");
  if (response.status === 429) throw new ResolverError("rate_limit", "Provider rate limit reached.", 429);
  if (response.status < 200 || response.status > 299) throw new ResolverError("provider_unavailable", "Provider is unavailable.");
  let result;
  try {
    result = site.data === "allpornstream" ? parseAllPornStreamFeed(response.body, page) : site.data === "hqporner" ? parseHQPorner(response.body, page) : site.data === "onlyfan420" ? parseOnlyFan420(response.body, page) : parsePornHub(response.body, page);
  } catch (reason) {
    if (reason instanceof Error && reason.message === "verification_required") throw new ResolverError("verification_required", "Provider verification is required.");
    throw reason;
  }
  return feedPageSchema.parse(result);
});

async function resolveSource(sourcePageURL: string, emit?: Emit): Promise<FeedPlaybackResolution> {
  const url = parseSupportedURL(sourcePageURL);
  const isVidara = url.hostname === "vidara.so" || url.hostname.endsWith(".vidara.so");
  const isLulu = ["luluvid.com", "luluvdo.com", "lulustream.com"].some((host) => url.hostname === host || url.hostname.endsWith(`.${host}`));
  const isPlaymogo = ["playmogo.com", "ds2play.com", "doodstream.com", "dood.wf", "vide0.net", "dooodster.com"].some((host) => url.hostname === host || url.hostname.endsWith(`.${host}`));
  const provider = isVidara ? "Vidara" : isLulu ? "LuluVDO" : isPlaymogo ? "Playmogo" : providerForURL(url.href);
  emit?.({ type: "started", provider: provider ?? "Unknown", message: `Preparing ${provider ?? "provider"} extraction.` });
  if (isVidara) return resolveVidara(url, emit);
  if (isLulu) return resolveLulu(url, emit);
  if (isPlaymogo) return resolvePlaymogo(url, emit);
  if (provider === "allpornstream") return resolveAllPornStream(url, emit);
  if (provider === "hqporner") {
    emit?.({ type: "provider_started", provider: "HQPorner", message: "Inspecting the HQPorner player." });
    const headers = { "User-Agent": providerChromeUserAgent, Referer: "https://hqporner.com/" };
    const outer = await safeFetch(url, headers);
    const normalized = outer.body.replaceAll("\\/", "/").replaceAll('\\"', '"');
    const iframes = [...normalized.matchAll(/<iframe\b[^>]*\bsrc\s*=\s*["']([^"']+)["'][^>]*>/gi)]
      .map((match) => match[1])
      .filter((value): value is string => Boolean(value));
    for (const iframe of [...new Set(iframes)]) {
      const candidate = new URL(iframe, outer.finalURL);
      if (candidate.protocol !== "https:" || !(candidate.hostname === "mydaddy.cc" || candidate.hostname.endsWith(".mydaddy.cc"))) continue;
      const embedURL = parseSupportedURL(candidate.href);
      const embed = await safeFetch(embedURL, headers);
      const parsed = parseMydaddy(embed.body, outer.finalURL.href);
      if (parsed) {
        const result = feedPlaybackResolutionSchema.parse({ ...parsed, clientResolverURL: embedURL.href });
        emit?.({ type: "metadata", title: result.title, ...(result.thumbnailURL ? { thumbnailURL: result.thumbnailURL } : {}) });
        emit?.({ type: "provider_completed", attempt: { provider: "HQPorner", status: "resolved" }, qualities: result.qualities.slice(0, 4) });
        emit?.({ type: "validating", message: "Validating HQPorner playback sources." });
        return result;
      }
    }
  }
  const providerName = provider ?? "yt-dlp";
  emit?.({ type: "provider_started", provider: providerName, message: `Resolving ${providerName} playback metadata.` });
  const result = await resolveWithYtDlp(url.href);
  emit?.({ type: "metadata", title: result.title, ...(result.thumbnailURL ? { thumbnailURL: result.thumbnailURL } : {}) });
  emit?.({ type: "provider_completed", attempt: { provider: providerName, status: "resolved" }, qualities: result.qualities.slice(0, 4) });
  emit?.({ type: "validating", message: `Validating ${result.qualities.length} playback source${result.qualities.length === 1 ? "" : "s"}.` });
  return result;
}

app.post("/internal/resolve", async (request) => {
  const body = resolveRequestSchema.safeParse(request.body);
  if (!body.success) throw new ResolverError("invalid_request", "A supported source URL is required.", 400);
  return resolveSource(body.data.sourcePageURL);
});

app.post("/internal/resolve/stream", async (request, reply) => {
  const body = resolveRequestSchema.safeParse(request.body);
  if (!body.success) throw new ResolverError("invalid_request", "A supported source URL is required.", 400);
  reply.hijack();
  reply.raw.writeHead(200, {
    "Content-Type": "application/x-ndjson; charset=utf-8",
    "Cache-Control": "no-store, no-transform",
    "X-Content-Type-Options": "nosniff",
  });
  let open = true;
  request.raw.once("aborted", () => { open = false; });
  reply.raw.once("close", () => {
    if (!reply.raw.writableEnded) open = false;
  });
  const emit: Emit = (input) => {
    if (!open || reply.raw.destroyed) return;
    const event = resolutionProgressEventSchema.parse({ ...input, at: new Date().toISOString() });
    reply.raw.write(`${JSON.stringify(event)}\n`);
  };
  try {
    const resolution = await resolveSource(body.data.sourcePageURL, emit);
    emit({ type: "completed", resolution });
  } catch (reason) {
    if (reason && typeof reason === "object" && "code" in reason && reason.code === "verification_required") {
      const details = reason as unknown as Error & { providerAttempts?: FeedPlaybackResolution["providerAttempts"] };
      emit({ type: "browser_required", message: details.message, providerAttempts: details.providerAttempts ?? [] });
    } else {
      const error = reason instanceof ResolverError ? reason : new ResolverError("provider_unavailable", "Resolver unavailable.");
      emit({ type: "failed", code: error.code, message: error.message });
    }
  } finally {
    if (!reply.raw.destroyed) reply.raw.end();
  }
});

app.setErrorHandler((error, _request, reply) => {
  if (error instanceof ResolverError) return reply.status(error.status).send({ error: { code: error.code, message: error.message } });
  if (error && typeof error === "object" && "code" in error && error.code === "verification_required") {
    const details = error as unknown as Error & { status?: number; providerAttempts?: unknown };
    return reply.status(details.status ?? 409).send({ error: { code: "verification_required", message: details.message }, ...(details.providerAttempts ? { providerAttempts: details.providerAttempts } : {}) });
  }
  if (error instanceof DOMException && error.name === "TimeoutError") return reply.status(504).send({ error: { code: "timeout", message: "Provider request timed out." } });
  app.log.error(error);
  return reply.status(500).send({ error: { code: "provider_unavailable", message: "Resolver unavailable." } });
});

if (process.env.NODE_ENV !== "test") await app.listen({ host: "0.0.0.0", port: Number(process.env.PORT || 8080) });
export { app };
