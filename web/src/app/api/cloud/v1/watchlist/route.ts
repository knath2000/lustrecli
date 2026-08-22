import { and, desc, eq, isNull } from "drizzle-orm";
import { requireCurrentAccount } from "@/lib/auth/current-account";
import { DeviceContractError } from "@/lib/cloud/device-contract";
import { jsonError, requestBody } from "@/lib/cloud/route";
import { db } from "@/lib/db/client";
import { lustreWatchlistItems } from "@/lib/db/schema";
import { recordCollectionChange } from "@/lib/cloud/collections";

const uuidPattern = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

function publicHTTPSURL(value: unknown) {
  if (typeof value !== "string" || value.length > 2_048) return null;
  const url = new URL(value);
  const host = url.hostname.toLowerCase().replace(/^\[|\]$/g, "");
  const parts = host.split(".").map(Number);
  const privateIPv4 = parts.length === 4 && parts.every((part) => Number.isInteger(part) && part >= 0 && part <= 255) && (parts[0] === 10 || parts[0] === 127 || (parts[0] === 169 && parts[1] === 254) || (parts[0] === 172 && parts[1] >= 16 && parts[1] <= 31) || (parts[0] === 192 && parts[1] === 168));
  if (url.protocol !== "https:" || url.username || url.password || url.hash || host === "localhost" || host.endsWith(".localhost") || host === "::1" || host.startsWith("fc") || host.startsWith("fd") || /^fe[89ab]/.test(host) || privateIPv4) return null;
  return url.toString();
}

function responseItem(item: typeof lustreWatchlistItems.$inferSelect) {
  return {
    id: item.id,
    sourcePageURL: item.sourcePageURL,
    title: item.title,
    provider: item.provider,
    thumbnailURL: item.thumbnailURL,
    watched: item.watched,
    watchedAt: item.watchedAt?.toISOString() ?? null,
    createdAt: item.createdAt.toISOString(),
    updatedAt: item.updatedAt.toISOString(),
  };
}

export async function GET() {
  try {
    const account = await requireCurrentAccount();
    const items = await db.select().from(lustreWatchlistItems).where(and(eq(lustreWatchlistItems.accountID, account.id), isNull(lustreWatchlistItems.deletedAt))).orderBy(desc(lustreWatchlistItems.updatedAt)).limit(500);
    return Response.json({ items: items.map(responseItem) }, { headers: { "Cache-Control": "private, no-store" } });
  } catch (error) {
    return jsonError(error);
  }
}

export async function POST(request: Request) {
  try {
    const account = await requireCurrentAccount();
    const body = await requestBody(request);
    const sourcePageURL = publicHTTPSURL(body.sourcePageURL);
    if (!sourcePageURL || typeof body.title !== "string" || !body.title.trim() || [...body.title].length > 1_024 || typeof body.provider !== "string" || !body.provider.trim() || [...body.provider].length > 64) throw new DeviceContractError("invalid_request", "Valid Watchlist video metadata is required.");
    const thumbnailURL = body.thumbnailURL === null || body.thumbnailURL === undefined ? null : publicHTTPSURL(body.thumbnailURL);
    if (body.thumbnailURL && !thumbnailURL) throw new DeviceContractError("invalid_request", "A valid Watchlist thumbnail is required.");
    const [item] = await db.insert(lustreWatchlistItems).values({
      accountID: account.id,
      sourcePageURL,
      title: body.title.trim(),
      provider: body.provider.trim(),
      thumbnailURL,
    }).onConflictDoUpdate({
      target: [lustreWatchlistItems.accountID, lustreWatchlistItems.sourcePageURL],
      set: { title: body.title.trim(), provider: body.provider.trim(), thumbnailURL, deletedAt: null, updatedAt: new Date() },
    }).returning();
    await recordCollectionChange(account.id, "watchlist", item.id, "upsert", responseItem(item));
    return Response.json({ item: responseItem(item) }, { status: 201 });
  } catch (error) {
    return jsonError(error);
  }
}

export async function PATCH(request: Request) {
  try {
    const account = await requireCurrentAccount();
    const body = await requestBody(request);
    if (typeof body.id !== "string" || !uuidPattern.test(body.id) || typeof body.watched !== "boolean") throw new DeviceContractError("invalid_request", "A valid Watchlist update is required.");
    const [item] = await db.update(lustreWatchlistItems).set({ watched: body.watched, watchedAt: body.watched ? new Date() : null, updatedAt: new Date() }).where(and(eq(lustreWatchlistItems.id, body.id), eq(lustreWatchlistItems.accountID, account.id))).returning();
    if (!item) throw new DeviceContractError("invalid_request", "Watchlist item not found.");
    await recordCollectionChange(account.id, "watchlist", item.id, "upsert", responseItem(item));
    return Response.json({ item: responseItem(item) });
  } catch (error) {
    return jsonError(error);
  }
}

export async function DELETE(request: Request) {
  try {
    const account = await requireCurrentAccount();
    const body = await requestBody(request);
    if (typeof body.id !== "string" || !uuidPattern.test(body.id)) throw new DeviceContractError("invalid_request", "A valid Watchlist item is required.");
    const [item] = await db.update(lustreWatchlistItems).set({ deletedAt: new Date(), updatedAt: new Date() }).where(and(eq(lustreWatchlistItems.id, body.id), eq(lustreWatchlistItems.accountID, account.id))).returning();
    if (item) await recordCollectionChange(account.id, "watchlist", item.id, "delete", { sourcePageURL: item.sourcePageURL });
    return new Response(null, { status: 204 });
  } catch (error) {
    return jsonError(error);
  }
}
