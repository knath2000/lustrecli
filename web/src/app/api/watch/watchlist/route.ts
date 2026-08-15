import { watchAccountID } from "@/lib/lustre-watch/account";
import { watchDB } from "@/lib/lustre-watch/db";
import { errorResponse } from "@/lib/lustre-watch/resolver";
import { publicHTTPSURL } from "@/lib/lustre-watch/public-url";

const select = `id, source_page_url AS "sourcePageURL", title, provider, thumbnail_url AS "thumbnailURL", watched, watched_at AS "watchedAt", created_at AS "createdAt", updated_at AS "updatedAt"`;

export async function GET() {
  try {
    const account = await watchAccountID();
    return Response.json(await watchDB().unsafe(`SELECT ${select} FROM lustre_watchlist_items WHERE account_id = $1 ORDER BY updated_at DESC`, [account]));
  } catch (reason) { return errorResponse(reason); }
}

export async function POST(request: Request) {
  try {
    const account = await watchAccountID();
    const body = await request.json() as Record<string, unknown>;
    if (typeof body.sourcePageURL !== "string" || typeof body.title !== "string" || typeof body.provider !== "string") return Response.json({ error: { code: "invalid_request", message: "Invalid Watchlist item." } }, { status: 400 });
    const url = publicHTTPSURL(body.sourcePageURL);
    const thumbnail = body.thumbnailURL === undefined || body.thumbnailURL === null ? null : publicHTTPSURL(body.thumbnailURL);
    if (!url || (body.thumbnailURL && !thumbnail)) return Response.json({ error: { code: "invalid_request", message: "Only public HTTPS URLs are accepted." } }, { status: 400 });
    const rows = await watchDB().unsafe(`INSERT INTO lustre_watchlist_items (account_id, source_page_url, title, provider, thumbnail_url) VALUES ($1,$2,$3,$4,$5) ON CONFLICT (account_id, source_page_url) DO UPDATE SET title=EXCLUDED.title, provider=EXCLUDED.provider, thumbnail_url=COALESCE(EXCLUDED.thumbnail_url,lustre_watchlist_items.thumbnail_url), updated_at=now() RETURNING ${select}`, [account, url.href, body.title.slice(0, 1000), body.provider.slice(0, 80), thumbnail?.href ?? null]);
    return Response.json(rows[0], { status: 201 });
  } catch (reason) { return errorResponse(reason); }
}
