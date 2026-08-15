import { watchAccountID } from "@/lib/lustre-watch/account";
import { watchDB } from "@/lib/lustre-watch/db";
import { errorResponse } from "@/lib/lustre-watch/resolver";

export async function PATCH(request: Request, context: { params: Promise<{ id: string }> }) {
  try {
    const account = await watchAccountID();
    const { id } = await context.params;
    const body = await request.json() as Record<string, unknown>;
    if (typeof body.watched !== "boolean" || Object.keys(body).some((key) => key !== "watched")) return Response.json({ error: { code: "invalid_request", message: "Only watched state can be changed." } }, { status: 400 });
    const rows = await watchDB()<Array<{ id: string }>>`UPDATE lustre_watchlist_items SET watched=${body.watched}, watched_at=${body.watched ? new Date() : null}, updated_at=now() WHERE id=${id} AND account_id=${account} RETURNING id`;
    return rows[0] ? new Response(null, { status: 204 }) : new Response(null, { status: 404 });
  } catch (reason) { return errorResponse(reason); }
}

export async function DELETE(_request: Request, context: { params: Promise<{ id: string }> }) {
  try {
    const account = await watchAccountID();
    const { id } = await context.params;
    const rows = await watchDB()<Array<{ id: string }>>`DELETE FROM lustre_watchlist_items WHERE id=${id} AND account_id=${account} RETURNING id`;
    return rows[0] ? new Response(null, { status: 204 }) : new Response(null, { status: 404 });
  } catch (reason) { return errorResponse(reason); }
}
