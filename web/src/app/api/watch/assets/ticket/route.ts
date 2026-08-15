import crypto from "node:crypto";
import { watchAccountID } from "@/lib/lustre-watch/account";
import { watchDB } from "@/lib/lustre-watch/db";
import { errorResponse } from "@/lib/lustre-watch/resolver";
import { publicHTTPSURL } from "@/lib/lustre-watch/public-url";

export async function POST(request: Request) {
  try {
    const account = await watchAccountID();
    const { url } = await request.json() as { url?: string };
    const assetURL = publicHTTPSURL(url);
    if (!assetURL) return Response.json({ error: { code: "invalid_request", message: "Invalid asset URL." } }, { status: 400 });
    const canonicalURL = assetURL.href;
    const owned = await watchDB()<Array<{ present: boolean }>>`
      SELECT true AS present FROM lustre_watchlist_items WHERE account_id=${account} AND thumbnail_url=${canonicalURL}
      UNION ALL
      SELECT true FROM lustre_feed_cache WHERE account_id=${account} AND expires_at > now() - interval '1 hour'
        AND jsonb_path_exists(
          result,
          '$.items[*] ? (@.thumbnailURL == $url || @.previewURLs[*] == $url)',
          jsonb_build_object('url', to_jsonb(${canonicalURL}::text))
        )
      LIMIT 1
    `;
    if (!owned[0]) return new Response(null, { status: 404 });
    const secret = process.env.ASSET_TICKET_SECRET;
    const origin = process.env.ASSET_WORKER_ORIGIN;
    if (!secret || !origin) throw new Error("Asset service is not configured.");
    const expires = Date.now() + 60_000;
    const signature = crypto.createHmac("sha256", secret).update(`${canonicalURL}\n${expires}`).digest("base64url");
    const ticket = new URL("/assets", origin);
    ticket.search = new URLSearchParams({ url: canonicalURL, expires: String(expires), signature }).toString();
    return Response.json({ url: ticket.href, expiresAt: new Date(expires).toISOString() });
  } catch (reason) { return errorResponse(reason); }
}
