export const commandDeliveryCapability = "command-delivery-v1";
export const feedPageCapability = "feed-page-v1";
export const destinationsListCapability = "destinations-list-v1";
export const feedQueueCapability = "feed-queue-v1";
export const feedSiteIDs = new Set(["allpornstream", "hqporner", "onlyfan420", "pornhub", "pornhub-subscriptions", "pornhub-liked", "pornhub-favorites"]);
export const maximumFeedPageAcknowledgementBytes = 65_536;
export const maximumDestinationsAcknowledgementBytes = 32_768;
export const maximumDestinations = 64;
const uuidPattern = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

function record(value: unknown): value is Record<string, unknown> { return !!value && typeof value === "object" && !Array.isArray(value); }
function boundedString(value: unknown, maximum: number) { return typeof value === "string" && value.trim().length > 0 && Array.from(value).length <= maximum; }
function nonNegativeInteger(value: unknown) { return Number.isSafeInteger(value) && (value as number) >= 0; }
function httpsURL(value: unknown, maximum = 4_096) {
  if (typeof value !== "string" || value.length > maximum) return false;
  try { const url = new URL(value); return url.protocol === "https:" && !url.username && !url.password; }
  catch { return false; }
}

function normalizedRemotePath(value: unknown) {
  if (typeof value !== "string" || value.length > 1_024 || !value.startsWith("/")) return false;
  const components = value.split("/").filter(Boolean);
  return !components.some((component) => component === "." || component === "..") && (components.length ? `/${components.join("/")}` : "/") === value;
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

export function validDestinationsAcknowledgement(value: unknown) {
  if (!record(value) || value.status !== "completed" || !record(value.result) || value.result.kind !== "destinations_list" || !Array.isArray(value.result.destinations)) return false;
  if (Object.keys(value.result).some((key) => !["kind", "destinations"].includes(key))) return false;
  if (new TextEncoder().encode(JSON.stringify(value)).byteLength > maximumDestinationsAcknowledgementBytes || value.result.destinations.length > maximumDestinations) return false;
  return value.result.destinations.every((destination) => {
    if (record(destination) && Object.keys(destination).some((key) => !["id", "name", "baseURL", "username", "remotePath", "allowInvalidCertificate"].includes(key))) return false;
    if (!record(destination) || typeof destination.id !== "string" || !uuidPattern.test(destination.id) || !boundedString(destination.name, 128) || !boundedString(destination.username, 256) || !normalizedRemotePath(destination.remotePath) || typeof destination.allowInvalidCertificate !== "boolean") return false;
    if (!httpsURL(destination.baseURL, 2_048)) return false;
    const url = new URL(destination.baseURL as string);
    return !url.search && !url.hash;
  });
}

export function negotiatedCommandDelivery(frame: Record<string, unknown>, realtime: boolean) {
  return realtime && Array.isArray(frame.capabilities) && frame.capabilities.includes(commandDeliveryCapability);
}

export function negotiatedFeedPage(frame: Record<string, unknown>, realtime: boolean) {
  return negotiatedCommandDelivery(frame, realtime) && (frame.capabilities as unknown[]).includes(feedPageCapability);
}

export function negotiatedDestinationsList(frame: Record<string, unknown>, realtime: boolean) {
  return negotiatedCommandDelivery(frame, realtime) && (frame.capabilities as unknown[]).includes(destinationsListCapability);
}

export function negotiatedFeedQueue(frame: Record<string, unknown>, realtime: boolean) {
  return negotiatedCommandDelivery(frame, realtime) && (frame.capabilities as unknown[]).includes(feedQueueCapability);
}

export type GatewayCommand =
  | { id: string; kind: "feed_sites"; payload: Record<string, never> }
  | { id: string; kind: "feed_page"; payload: { siteID: string; page: number; query?: string } }
  | { id: string; kind: "destinations_list"; payload: Record<string, never> }
  | { id: string; kind: "queue_url"; payload: { url: string; destination: string; deliveryProtocol: "gateway-v1" } };

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

export function selectedGatewayCommand(value: unknown, sequence: number, correlationID: string, allowFeedPage: boolean, allowDestinationsList = false, allowFeedQueue = false): GatewayCommand | null | undefined {
  if (!value || typeof value !== "object" || Array.isArray(value)) return undefined;
  const record = value as Record<string, unknown>;
  if (record.version !== 1 || record.type !== "gateway-command-selected" || record.sequence !== sequence || record.correlationID !== correlationID) return undefined;
  if (record.command === null) return null;
  if (!record.command || typeof record.command !== "object" || Array.isArray(record.command)) return undefined;
  const command = record.command as Record<string, unknown>;
  if (typeof command.id !== "string" || !command.payload || typeof command.payload !== "object" || Array.isArray(command.payload)) return undefined;
  const payload = command.payload as Record<string, unknown>;
  if (command.kind === "feed_sites" && Object.keys(payload).length === 0) return { id: command.id, kind: "feed_sites", payload: {} };
  if (command.kind === "destinations_list") return allowDestinationsList && uuidPattern.test(command.id) && Object.keys(payload).length === 0 ? { id: command.id, kind: "destinations_list", payload: {} } : undefined;
  if (command.kind === "queue_url") {
    if (!allowFeedQueue || !uuidPattern.test(command.id) || Object.keys(payload).sort().join(",") !== "deliveryProtocol,destination,url" || payload.deliveryProtocol !== "gateway-v1") return undefined;
    if (!httpsURL(payload.url, 2_048) || typeof payload.destination !== "string" || !/^local$|^webdav:[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(payload.destination)) return undefined;
    const normalized = { id: command.id, kind: "queue_url" as const, payload: { url: new URL(payload.url as string).toString(), destination: payload.destination, deliveryProtocol: "gateway-v1" as const } };
    return new TextEncoder().encode(JSON.stringify(normalized)).byteLength <= 4_096 ? normalized : undefined;
  }
  if (command.kind !== "feed_page" || !allowFeedPage || typeof payload.siteID !== "string" || !feedSiteIDs.has(payload.siteID) || !Number.isSafeInteger(payload.page) || (payload.page as number) < 1) return undefined;
  const query = normalizedQuery(payload.query);
  if (query === null || Object.keys(payload).some((key) => !["siteID", "page", "query"].includes(key))) return undefined;
  return { id: command.id, kind: "feed_page", payload: { siteID: payload.siteID, page: payload.page as number, ...(query ? { query } : {}) } };
}
