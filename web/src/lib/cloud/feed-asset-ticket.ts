import { SignJWT, jwtVerify } from "jose";
import { DeviceContractError, validFeedPageResult, validHomeWorkspaceResult, validLibraryResult } from "./device-contract.ts";

export const FEED_ASSET_TICKET_ISSUER = "lustre-cloud";
export const FEED_ASSET_TICKET_AUDIENCE = "lustre-feed-assets";
export const FEED_ASSET_TICKET_SECONDS = 60;
export type FeedAssetKind = "image" | "video";

type TicketInput = {
  deviceID: string;
  url: string;
  kind: FeedAssetKind;
};

function secret() {
  const value = process.env.LUSTRE_FEED_ASSET_TOKEN_SECRET;
  if (!value) throw new Error("LUSTRE_FEED_ASSET_TOKEN_SECRET is not configured.");
  return new TextEncoder().encode(value);
}

function record(value: unknown): value is Record<string, unknown> {
  return !!value && typeof value === "object" && !Array.isArray(value);
}

export function normalizeFeedAssetRequest(value: unknown): { url: string; kind: FeedAssetKind } {
  if (!record(value) || (value.kind !== "image" && value.kind !== "video") || typeof value.url !== "string" || value.url.length > 4_096) {
    throw new DeviceContractError("invalid_request", "A supported feed asset is required.");
  }
  let url: URL;
  try { url = new URL(value.url); } catch { throw new DeviceContractError("invalid_request", "A supported feed asset is required."); }
  if (url.protocol !== "https:" || url.username || url.password) throw new DeviceContractError("invalid_request", "A supported feed asset is required.");
  return { url: value.url, kind: value.kind };
}

export function feedAssetAppearedInResults(results: unknown[], url: string, kind: FeedAssetKind): boolean {
  for (const candidate of results) {
    if (validLibraryResult(candidate) && kind === "image") {
      const snapshot = candidate.library as { items: Array<{ thumbnailURL?: string | null }> };
      if (snapshot.items.some((item) => item.thumbnailURL === url)) return true;
    }
    if (validHomeWorkspaceResult(candidate) && candidate.kind === "extract_preview" && kind === "image") {
      const items = candidate.homePreview as Array<{ thumbnailURL?: string | null }>;
      if (items.some((item) => item.thumbnailURL === url)) return true;
    }
    if (!validFeedPageResult(candidate)) continue;
    const page = candidate.page as { items: Array<{ thumbnailURL?: string | null; previewURLs: string[] }> };
    for (const item of page.items) {
      if (kind === "image" && item.thumbnailURL === url) return true;
      if (item.previewURLs.some((previewURL) => previewURL === url && (/\.(?:webm|mp4|mov)(?:$|[?#])/i.test(previewURL) ? "video" : "image") === kind)) return true;
    }
  }
  return false;
}

export async function issueFeedAssetTicket(input: TicketInput, now = new Date()) {
  const expiresAt = new Date(now.getTime() + FEED_ASSET_TICKET_SECONDS * 1_000);
  const ticket = await new SignJWT({ version: 1, deviceID: input.deviceID, url: input.url, kind: input.kind })
    .setProtectedHeader({ alg: "HS256", typ: "JWT" })
    .setIssuer(FEED_ASSET_TICKET_ISSUER)
    .setAudience(FEED_ASSET_TICKET_AUDIENCE)
    .setJti(crypto.randomUUID())
    .setIssuedAt(Math.floor(now.getTime() / 1_000))
    .setExpirationTime(Math.floor(expiresAt.getTime() / 1_000))
    .sign(secret());
  return { ticket, expiresAt };
}

export async function verifyFeedAssetTicket(ticket: string, now?: Date) {
  const verified = await jwtVerify(ticket, secret(), {
    algorithms: ["HS256"],
    issuer: FEED_ASSET_TICKET_ISSUER,
    audience: FEED_ASSET_TICKET_AUDIENCE,
    ...(now ? { currentDate: now } : {}),
  });
  return verified.payload;
}

export function createFeedAssetTicketHandler(dependencies: {
  currentAccount: () => Promise<{ id: string }>;
  recentResults: (accountID: string, deviceID: string, since: Date) => Promise<Array<{ result: unknown }>>;
  storedImage?: (accountID: string, deviceID: string, url: string) => Promise<boolean>;
  issueTicket?: typeof issueFeedAssetTicket;
  now?: () => Date;
}) {
  return async (request: Request, deviceID: string) => {
    const now = dependencies.now?.() ?? new Date();
    const account = await dependencies.currentAccount();
    const declaredLength = Number(request.headers.get("Content-Length") ?? "0");
    if (Number.isFinite(declaredLength) && declaredLength > 8_192) throw new DeviceContractError("invalid_request", "Request body is too large.");
    const encoded = await request.text();
    if (new TextEncoder().encode(encoded).byteLength > 8_192) throw new DeviceContractError("invalid_request", "Request body is too large.");
    let parsed: unknown;
    try { parsed = JSON.parse(encoded); } catch { throw new DeviceContractError("invalid_request", "Request body must be valid JSON."); }
    const body = normalizeFeedAssetRequest(parsed);
    const rows = await dependencies.recentResults(account.id, deviceID, new Date(now.getTime() - 60 * 60_000));
    const recent = feedAssetAppearedInResults(rows.map((row) => row.result), body.url, body.kind);
    const stored = !recent && body.kind === "image" && dependencies.storedImage
      ? await dependencies.storedImage(account.id, deviceID, body.url)
      : false;
    if (!recent && !stored) {
      throw new DeviceContractError("invalid_request", "The feed asset is unavailable.");
    }
    const { ticket, expiresAt } = await (dependencies.issueTicket ?? issueFeedAssetTicket)({ deviceID, ...body }, now);
    const origin = process.env.LUSTRE_FEED_ASSET_ORIGIN;
    if (!origin) throw new Error("LUSTRE_FEED_ASSET_ORIGIN is not configured.");
    return Response.json(
      { ticket, assetURL: `${origin.replace(/\/+$/, "")}/v1/feed-assets`, expiresAt: expiresAt.toISOString() },
      { headers: { "Cache-Control": "no-store" } },
    );
  };
}
