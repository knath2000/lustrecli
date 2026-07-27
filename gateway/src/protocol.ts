export const commandDeliveryCapability = "command-delivery-v1";
export const feedPageCapability = "feed-page-v1";
export const feedSiteIDs = new Set(["allpornstream", "hqporner", "onlyfan420", "pornhub", "pornhub-subscriptions", "pornhub-liked", "pornhub-favorites"]);
export const maximumFeedPageAcknowledgementBytes = 65_536;

function record(value: unknown): value is Record<string, unknown> { return !!value && typeof value === "object" && !Array.isArray(value); }
function boundedString(value: unknown, maximum: number) { return typeof value === "string" && value.trim().length > 0 && Array.from(value).length <= maximum; }
function nonNegativeInteger(value: unknown) { return Number.isSafeInteger(value) && (value as number) >= 0; }
function httpsURL(value: unknown, maximum = 4_096) {
  if (typeof value !== "string" || value.length > maximum) return false;
  try { const url = new URL(value); return url.protocol === "https:" && !url.username && !url.password; }
  catch { return false; }
}

export function validFeedPageAcknowledgement(value: unknown) {
  if (!record(value) || value.status !== "completed" || !record(value.result) || value.result.kind !== "feed_page" || !record(value.result.page)) return false;
  if (new TextEncoder().encode(JSON.stringify(value)).byteLength > maximumFeedPageAcknowledgementBytes) return false;
  const page = value.result.page;
  if (!Number.isSafeInteger(page.page) || (page.page as number) < 1 || typeof page.hasMore !== "boolean" || !Array.isArray(page.items) || page.items.length > 50) return false;
  return page.items.every((item) => {
    if (!record(item) || !boundedString(item.id, 512) || typeof item.siteID !== "string" || !feedSiteIDs.has(item.siteID) || !boundedString(item.title, 1_024) || !httpsURL(item.sourcePageURL) || typeof item.uploadedAt !== "string" || Number.isNaN(Date.parse(item.uploadedAt)) || typeof item.uploadedAtIsApproximate !== "boolean" || !nonNegativeInteger(item.viewCount) || item.queueCapability !== "supported") return false;
    if (item.thumbnailURL !== undefined && item.thumbnailURL !== null && !httpsURL(item.thumbnailURL)) return false;
    if (!Array.isArray(item.previewURLs) || item.previewURLs.length > 4 || !item.previewURLs.every((url) => httpsURL(url))) return false;
    return item.studio === undefined || item.studio === null || (typeof item.studio === "string" && Array.from(item.studio).length <= 512);
  });
}

export function negotiatedCommandDelivery(frame: Record<string, unknown>, realtime: boolean) {
  return realtime && Array.isArray(frame.capabilities) && frame.capabilities.includes(commandDeliveryCapability);
}

export function negotiatedFeedPage(frame: Record<string, unknown>, realtime: boolean) {
  return negotiatedCommandDelivery(frame, realtime) && (frame.capabilities as unknown[]).includes(feedPageCapability);
}

export type GatewayCommand =
  | { id: string; kind: "feed_sites"; payload: Record<string, never> }
  | { id: string; kind: "feed_page"; payload: { siteID: string; page: number; query?: string } };

export function commandDeliveryFrame(input: {
  sequence: number;
  correlationID: string;
  acknowledgedCommandAckIDs: string[];
  command: GatewayCommand | null;
}) {
  return {
    version: 1,
    type: "command-delivery",
    sequence: input.sequence,
    correlationID: input.correlationID,
    acknowledgedCommandAckIDs: input.acknowledgedCommandAckIDs,
    command: input.command,
  };
}

export function validPersistenceResponse(value: unknown, sequence: number, correlationID: string): value is Record<string, unknown> & { acknowledgedCommandAckIDs: string[] } {
  return !!value && typeof value === "object" && !Array.isArray(value) &&
    (value as Record<string, unknown>).version === 1 &&
    (value as Record<string, unknown>).type === "gateway-heartbeat-persisted" &&
    (value as Record<string, unknown>).sequence === sequence &&
    (value as Record<string, unknown>).correlationID === correlationID &&
    Array.isArray((value as Record<string, unknown>).acknowledgedCommandAckIDs) &&
    ((value as Record<string, unknown>).acknowledgedCommandAckIDs as unknown[]).every((id) => typeof id === "string");
}

function normalizedQuery(value: unknown) {
  if (value === undefined) return undefined;
  if (typeof value !== "string" || /[\u0000-\u001f\u007f-\u009f]/.test(value)) return null;
  const query = value.trim().split(/\s+/).join(" ");
  return query.length <= 120 ? query || undefined : null;
}

export function selectedGatewayCommand(value: unknown, sequence: number, correlationID: string, allowFeedPage: boolean): GatewayCommand | null | undefined {
  if (!value || typeof value !== "object" || Array.isArray(value)) return undefined;
  const record = value as Record<string, unknown>;
  if (record.version !== 1 || record.type !== "gateway-command-selected" || record.sequence !== sequence || record.correlationID !== correlationID) return undefined;
  if (record.command === null) return null;
  if (!record.command || typeof record.command !== "object" || Array.isArray(record.command)) return undefined;
  const command = record.command as Record<string, unknown>;
  if (typeof command.id !== "string" || !command.payload || typeof command.payload !== "object" || Array.isArray(command.payload)) return undefined;
  const payload = command.payload as Record<string, unknown>;
  if (command.kind === "feed_sites" && Object.keys(payload).length === 0) return { id: command.id, kind: "feed_sites", payload: {} };
  if (command.kind !== "feed_page" || !allowFeedPage || typeof payload.siteID !== "string" || !feedSiteIDs.has(payload.siteID) || !Number.isSafeInteger(payload.page) || (payload.page as number) < 1) return undefined;
  const query = normalizedQuery(payload.query);
  if (query === null || Object.keys(payload).some((key) => !["siteID", "page", "query"].includes(key))) return undefined;
  return { id: command.id, kind: "feed_page", payload: { siteID: payload.siteID, page: payload.page as number, ...(query ? { query } : {}) } };
}
