import { verifyDeviceToken } from "@/lib/cloud/device-token";
import { DeviceContractError } from "@/lib/cloud/device-contract";
import { synchronizeCollections, type CollectionMutation } from "@/lib/cloud/collections";
import { jsonError, requestBody } from "@/lib/cloud/route";

const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const kinds = new Set(["watchlist_upsert", "watchlist_delete", "library_upsert", "library_organize", "library_delete"]);

function publicHTTPSURL(value: unknown) {
  if (typeof value !== "string" || value.length > 2_048) return null;
  try {
    const url = new URL(value);
    const host = url.hostname.toLowerCase().replace(/^\[|\]$/g, "");
    const parts = host.split(".").map(Number);
    const privateIPv4 = parts.length === 4 && parts.every((part) => Number.isInteger(part) && part >= 0 && part <= 255) && (parts[0] === 10 || parts[0] === 127 || (parts[0] === 169 && parts[1] === 254) || (parts[0] === 172 && parts[1] >= 16 && parts[1] <= 31) || (parts[0] === 192 && parts[1] === 168));
    if (url.protocol !== "https:" || url.username || url.password || url.hash || !host || host === "localhost" || host.endsWith(".localhost") || host === "::1" || host.startsWith("fc") || host.startsWith("fd") || /^fe[89ab]/.test(host) || privateIPv4) return null;
    return url.toString();
  } catch {
    return null;
  }
}

function mutations(value: unknown): CollectionMutation[] {
  if (!Array.isArray(value) || value.length > 100) throw new DeviceContractError("invalid_request", "A bounded collection mutation batch is required.");
  return value.map((entry) => {
    if (!entry || typeof entry !== "object") throw new DeviceContractError("invalid_request", "Invalid collection mutation.");
    const item = entry as Record<string, unknown>;
    const sourcePageURL = publicHTTPSURL(item.sourcePageURL);
    if (typeof item.id !== "string" || !uuid.test(item.id) || typeof item.kind !== "string" || !kinds.has(item.kind) || !sourcePageURL || !item.payload || typeof item.payload !== "object" || Array.isArray(item.payload)) throw new DeviceContractError("invalid_request", "Invalid collection mutation.");
    const payload = item.payload as Record<string, unknown>;
    if (item.kind === "watchlist_upsert" && (typeof payload.title !== "string" || !payload.title.trim() || [...payload.title].length > 1_024 || typeof payload.provider !== "string" || !payload.provider.trim() || [...payload.provider].length > 64 || typeof payload.watched !== "boolean")) throw new DeviceContractError("invalid_request", "Invalid Watchlist metadata.");
    if (item.kind === "library_upsert" && (typeof payload.jobID !== "string" || !uuid.test(payload.jobID) || typeof payload.title !== "string" || !payload.title.trim() || [...payload.title].length > 1_024 || typeof payload.provider !== "string" || !payload.provider.trim() || [...payload.provider].length > 64 || !["video", "audio"].includes(payload.mediaKind as string) || typeof payload.completedAt !== "string" || Number.isNaN(Date.parse(payload.completedAt)))) throw new DeviceContractError("invalid_request", "Invalid Library metadata.");
    if (item.kind === "library_organize" && (!Array.isArray(payload.tags) || payload.tags.length > 20 || !payload.tags.every((tag) => typeof tag === "string" && tag.trim() && [...tag].length <= 48) || (payload.collection !== null && payload.collection !== undefined && (typeof payload.collection !== "string" || [...payload.collection].length > 80)) || typeof payload.favorite !== "boolean")) throw new DeviceContractError("invalid_request", "Invalid Library organization.");
    for (const key of ["thumbnailURL", "displayFilename"]) {
      if (payload[key] !== undefined && payload[key] !== null && typeof payload[key] !== "string") throw new DeviceContractError("invalid_request", "Invalid collection metadata.");
    }
    if (typeof payload.displayFilename === "string" && [...payload.displayFilename].length > 512) throw new DeviceContractError("invalid_request", "Invalid Library filename.");
    if (payload.thumbnailURL && !publicHTTPSURL(payload.thumbnailURL)) throw new DeviceContractError("invalid_request", "Invalid collection thumbnail.");
    if (payload.byteCount !== undefined && payload.byteCount !== null && (!Number.isSafeInteger(payload.byteCount) || (payload.byteCount as number) < 0)) throw new DeviceContractError("invalid_request", "Invalid Library byte count.");
    return { id: item.id, kind: item.kind as CollectionMutation["kind"], sourcePageURL, payload };
  });
}

export async function POST(request: Request) {
  try {
    const authorization = request.headers.get("authorization");
    if (!authorization?.startsWith("Bearer ")) throw new Error("unauthorized");
    const verified = await verifyDeviceToken(authorization.slice(7));
    const body = await requestBody(request, 1_048_576);
    if (!Number.isSafeInteger(body.cursor) || (body.cursor as number) < 0) throw new DeviceContractError("invalid_request", "A valid collection cursor is required.");
    return Response.json(await synchronizeCollections(
      verified.payload.accountID as string,
      verified.payload.sub!,
      body.cursor as number,
      mutations(body.mutations),
    ), { headers: { "Cache-Control": "private, no-store" } });
  } catch (error) {
    return jsonError(error);
  }
}
