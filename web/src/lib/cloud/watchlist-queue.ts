import { DeviceContractError } from "./device-contract.ts";

const uuidPattern = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

export function normalizeWatchlistQueueCommand(body: Record<string, unknown>) {
  if (
    Object.keys(body).sort().join(",") !== "destination,kind,requestID,watchlistID"
    || body.kind !== "watchlist_queue"
    || typeof body.watchlistID !== "string"
    || !uuidPattern.test(body.watchlistID)
    || typeof body.requestID !== "string"
    || !uuidPattern.test(body.requestID)
    || body.destination !== "local"
  ) {
    throw new DeviceContractError("invalid_request", "A valid Watchlist queue request is required.");
  }
  return {
    watchlistID: body.watchlistID,
    requestID: body.requestID,
    destination: "local" as const,
  };
}
