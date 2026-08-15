import crypto from "node:crypto";
import { feedPageSchema, feedSiteIDSchema, type FeedPage } from "@/lib/lustre-watch/contracts";
import { parseAllPornStreamFeed, providerChromeUserAgent } from "@/lib/lustre-watch/providers";
import { watchAccountID } from "@/lib/lustre-watch/account";
import { watchDB } from "@/lib/lustre-watch/db";
import { errorResponse, resolverRequest } from "@/lib/lustre-watch/resolver";

export async function GET(request: Request) {
  try {
    const account = await watchAccountID();
    const input = new URL(request.url).searchParams;
    const site = feedSiteIDSchema.safeParse(input.get("site"));
    const page = Number(input.get("page") || "1");
    const q = input.get("q")?.trim().replace(/\s+/g, " ");
    if (!site.success || !Number.isSafeInteger(page) || page < 1 || (q?.length ?? 0) > 120) return Response.json({ error: { code: "invalid_request", message: "Invalid feed query." } }, { status: 400 });
    const queryHash = crypto.createHash("sha256").update(q?.toLocaleLowerCase() ?? "").digest("hex");
    const cached = await watchDB()<Array<{ result: FeedPage }>>`
      SELECT result FROM lustre_feed_cache
      WHERE account_id = ${account} AND provider = ${site.data} AND normalized_query_hash = ${queryHash}
        AND page = ${page} AND expires_at > now()
      LIMIT 1
    `;
    if (cached[0]) return Response.json(feedPageSchema.parse(cached[0].result), { headers: { "X-Lustre-Cache": "hit" } });
    const params = new URLSearchParams({ site: site.data, page: String(page) });
    if (q) params.set("q", q);
    let result: FeedPage;
    if (site.data === "allpornstream") {
      const providerParams = new URLSearchParams();
      if (q) providerParams.set("s", q);
      if (page > 1) providerParams.set("page", String(page));
      const providerURL = `https://allpornstream.com/${providerParams.size ? `?${providerParams}` : ""}`;
      const response = await fetch(providerURL, {
        headers: { "User-Agent": providerChromeUserAgent, Referer: "https://allpornstream.com/" },
        cache: "no-store",
        signal: AbortSignal.timeout(20_000),
      });
      if (!response.ok) {
        console.warn("allpornstream_feed_upstream", {
          status: response.status,
          mitigated: response.headers.get("cf-mitigated"),
          host: new URL(response.url).hostname,
        });
        return Response.json({ error: { code: response.status === 403 || response.headers.get("cf-mitigated") === "challenge" ? "verification_required" : "provider_unavailable", message: "AllPornStream requires browser assistance from this network." } }, { status: 502 });
      }
      result = feedPageSchema.parse(parseAllPornStreamFeed(await response.text(), page));
    } else {
      result = feedPageSchema.parse(await resolverRequest<FeedPage>(`/internal/feed?${params}`));
    }
    await watchDB()`
      INSERT INTO lustre_feed_cache (account_id, provider, normalized_query_hash, page, result, expires_at)
      VALUES (${account}, ${site.data}, ${queryHash}, ${page}, ${watchDB().json(result)}, now() + interval '5 minutes')
      ON CONFLICT (account_id, provider, normalized_query_hash, page)
      DO UPDATE SET result = EXCLUDED.result, expires_at = EXCLUDED.expires_at, updated_at = now()
    `;
    return Response.json(result, { headers: { "X-Lustre-Cache": "miss" } });
  } catch (reason) { return errorResponse(reason); }
}
