import crypto from "node:crypto";
import { feedPageSchema } from "@/lib/lustre-watch/contracts";
import { watchAccountID } from "@/lib/lustre-watch/account";
import { watchDB } from "@/lib/lustre-watch/db";
import { errorResponse } from "@/lib/lustre-watch/resolver";

export async function POST(request: Request) {
  try {
    const account = await watchAccountID();
    const body = await request.json() as { page?: unknown; q?: unknown; result?: unknown };
    const page = Number(body.page);
    const q = typeof body.q === "string" ? body.q.trim().replace(/\s+/g, " ") : "";
    if (!Number.isSafeInteger(page) || page < 1 || q.length > 120) {
      return Response.json({ error: { code: "invalid_request", message: "Invalid captured feed query." } }, { status: 400 });
    }
    const result = feedPageSchema.parse(body.result);
    if (result.page !== page || result.items.some((item) => {
      const source = new URL(item.sourcePageURL);
      const images = [item.thumbnailURL, ...item.previewURLs].filter(Boolean) as string[];
      return item.siteID !== "allpornstream"
        || !["allpornstream.com", "www.allpornstream.com"].includes(source.hostname)
        || !source.pathname.startsWith("/post/")
        || images.some((value) => {
          const image = new URL(value);
          return !["allpornstream.com", "www.allpornstream.com"].includes(image.hostname) || image.pathname !== "/api/images";
        });
    })) {
      return Response.json({ error: { code: "invalid_request", message: "Captured feed was rejected." } }, { status: 400 });
    }
    const queryHash = crypto.createHash("sha256").update(q.toLocaleLowerCase()).digest("hex");
    await watchDB()`
      INSERT INTO lustre_feed_cache (account_id, provider, normalized_query_hash, page, result, expires_at)
      VALUES (${account}, 'allpornstream', ${queryHash}, ${page}, ${watchDB().json(result)}, now() + interval '5 minutes')
      ON CONFLICT (account_id, provider, normalized_query_hash, page)
      DO UPDATE SET result = EXCLUDED.result, expires_at = EXCLUDED.expires_at, updated_at = now()
    `;
    return Response.json(result);
  } catch (reason) { return errorResponse(reason); }
}
