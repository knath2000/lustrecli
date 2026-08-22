import { watchAccountID } from "@/lib/lustre-watch/account";
import { watchDB } from "@/lib/lustre-watch/db";
import { errorResponse } from "@/lib/lustre-watch/resolver";

export async function PATCH(request: Request, context: { params: Promise<{ id: string }> }) {
  try {
    const account = await watchAccountID();
    const { id } = await context.params;
    const body = await request.json() as Record<string, unknown>;
    if (typeof body.watched !== "boolean" || Object.keys(body).some((key) => key !== "watched")) return Response.json({ error: { code: "invalid_request", message: "Only watched state can be changed." } }, { status: 400 });
    const rows = await watchDB()<Array<{ id: string; sourcePageURL: string; title: string; provider: string; thumbnailURL: string | null; watched: boolean; watchedAt: Date | null; createdAt: Date; updatedAt: Date }>>`UPDATE lustre_watchlist_items SET watched=${body.watched}, watched_at=${body.watched ? new Date() : null}, updated_at=now() WHERE id=${id} AND account_id=${account} AND deleted_at IS NULL RETURNING id, source_page_url AS "sourcePageURL", title, provider, thumbnail_url AS "thumbnailURL", watched, watched_at AS "watchedAt", created_at AS "createdAt", updated_at AS "updatedAt"`;
    if (rows[0]) await watchDB()`INSERT INTO lustre_collection_changes (account_id, entity_type, entity_id, operation, payload) VALUES (${account}, 'watchlist', ${rows[0].id}, 'upsert', ${watchDB().json(rows[0])})`;
    return rows[0] ? new Response(null, { status: 204 }) : new Response(null, { status: 404 });
  } catch (reason) { return errorResponse(reason); }
}

export async function DELETE(_request: Request, context: { params: Promise<{ id: string }> }) {
  try {
    const account = await watchAccountID();
    const { id } = await context.params;
    const rows = await watchDB()<Array<{ id: string; sourcePageURL: string }>>`UPDATE lustre_watchlist_items SET deleted_at=now(), updated_at=now() WHERE id=${id} AND account_id=${account} RETURNING id, source_page_url AS "sourcePageURL"`;
    if (rows[0]) await watchDB()`INSERT INTO lustre_collection_changes (account_id, entity_type, entity_id, operation, payload) VALUES (${account}, 'watchlist', ${rows[0].id}, 'delete', ${watchDB().json({ sourcePageURL: rows[0].sourcePageURL })})`;
    return rows[0] ? new Response(null, { status: 204 }) : new Response(null, { status: 404 });
  } catch (reason) { return errorResponse(reason); }
}
