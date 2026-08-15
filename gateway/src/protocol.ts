export const commandDeliveryCapability = "command-delivery-v1";
export const feedPageCapability = "feed-page-v1";
export const destinationsListCapability = "destinations-list-v1";
export const feedQueueCapability = "feed-queue-v1";
export const commandWakeCapability = "command-wake-v1";
export const pornHubAuthCapability = "pornhub-auth-v1";
export const homeWorkspaceCapability = "home-workspace-v1";
export const libraryCapability = "library-v1";
export const feedSiteIDs = new Set(["allpornstream", "hqporner", "onlyfan420", "pornhub", "pornhub-subscriptions", "pornhub-liked", "pornhub-favorites"]);
export const maximumFeedPageAcknowledgementBytes = 118_000;
export const maximumDestinationsAcknowledgementBytes = 32_768;
export const maximumDestinations = 64;
export const maximumHomePreviewAcknowledgementBytes = 64_000;
const uuidPattern = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

function record(value: unknown): value is Record<string, unknown> { return !!value && typeof value === "object" && !Array.isArray(value); }
function boundedString(value: unknown, maximum: number) { return typeof value === "string" && value.trim().length > 0 && Array.from(value).length <= maximum; }
function nonNegativeInteger(value: unknown) { return Number.isSafeInteger(value) && (value as number) >= 0; }
function httpsURL(value: unknown, maximum = 4_096) {
  if (typeof value !== "string" || value.length > maximum) return false;
  try { const url = new URL(value); return url.protocol === "https:" && !url.username && !url.password; }
  catch { return false; }
}

function publicHTTPSURL(value: unknown, maximum = 4_096) {
  if (!httpsURL(value, maximum)) return false;
  const host = new URL(value as string).hostname.toLowerCase().replace(/^\[|\]$/g, "");
  if (host === "localhost" || host.endsWith(".localhost") || host === "::1" || host === "0.0.0.0" || host.startsWith("fc") || host.startsWith("fd") || host.startsWith("fe8") || host.startsWith("fe9") || host.startsWith("fea") || host.startsWith("feb")) return false;
  const parts = host.split(".").map(Number);
  if (parts.length === 4 && parts.every((part) => Number.isInteger(part) && part >= 0 && part <= 255)) {
    return !(parts[0] === 10 || parts[0] === 127 || (parts[0] === 169 && parts[1] === 254) || (parts[0] === 172 && parts[1] >= 16 && parts[1] <= 31) || (parts[0] === 192 && parts[1] === 168));
  }
  return true;
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
    if (item.downloadedAt !== undefined && (typeof item.downloadedAt !== "string" || Number.isNaN(Date.parse(item.downloadedAt)))) return false;
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
    if (!record(destination) || typeof destination.id !== "string" || !uuidPattern.test(destination.id) || !boundedString(destination.name, 128) || !normalizedRemotePath(destination.remotePath)) return false;
    if (destination.kind === "google_drive") {
      return Object.keys(destination).every((key) => ["id", "name", "kind", "remoteName", "remotePath"].includes(key)) && boundedString(destination.remoteName, 64) && /^[A-Za-z0-9._-]+$/.test(destination.remoteName as string);
    }
    if ((destination.kind !== undefined && destination.kind !== "webdav") || Object.keys(destination).some((key) => !["id", "name", "kind", "baseURL", "username", "remotePath", "allowInvalidCertificate"].includes(key)) || !boundedString(destination.username, 256) || typeof destination.allowInvalidCertificate !== "boolean") return false;
    if (!httpsURL(destination.baseURL, 2_048)) return false;
    const url = new URL(destination.baseURL as string);
    return !url.search && !url.hash;
  });
}

export function validGoogleDriveFoldersAcknowledgement(value: unknown) {
  if (!record(value) || value.status !== "completed" || !record(value.result) || value.result.kind !== "google_drive_folders" || !Array.isArray(value.result.googleDriveFolders) || value.result.googleDriveFolders.length > 200) return false;
  if (Object.keys(value.result).some((key) => !["kind", "googleDriveFolders"].includes(key))) return false;
  return value.result.googleDriveFolders.every((folder) =>
    record(folder)
    && Object.keys(folder).sort().join(",") === "name,path"
    && boundedString(folder.name, 256)
    && normalizedRemotePath(folder.path)
  );
}

export function validLocalDownloadFolderAcknowledgement(value: unknown) {
  if (!record(value) || value.status !== "completed" || !record(value.result) || value.result.kind !== "local_download_folder" || !record(value.result.localDownloadFolder)) return false;
  if (Object.keys(value.result).sort().join(",") !== "kind,localDownloadFolder") return false;
  const folder = value.result.localDownloadFolder;
  return Object.keys(folder).sort().join(",") === "folderName,mode"
    && ["default", "custom"].includes(folder.mode as string)
    && boundedString(folder.folderName, 128);
}

export function validHomeWorkspaceAcknowledgement(value: unknown) {
  if (!record(value) || value.status !== "completed" || !record(value.result)) return false;
  if (new TextEncoder().encode(JSON.stringify(value)).byteLength > maximumHomePreviewAcknowledgementBytes) return false;
  if (value.result.kind === "home_status") {
    return Object.keys(value.result).sort().join(",") === "homeReadiness,kind"
      && record(value.result.homeReadiness)
      && Object.keys(value.result.homeReadiness).sort().join(",") === "browserBridge,ffmpeg,ytDlp"
      && Object.values(value.result.homeReadiness).every((item) => typeof item === "boolean");
  }
  if (value.result.kind !== "extract_preview" || !Array.isArray(value.result.homePreview) || !(value.result.homePreview.length >= 1 && value.result.homePreview.length <= 10) || Object.keys(value.result).sort().join(",") !== "homePreview,kind") return false;
  return value.result.homePreview.every((item) => {
    if (!record(item) || Object.keys(item).some((key) => !["sourcePageURL", "state", "title", "thumbnailURL", "provider", "qualities", "errorCode"].includes(key)) || !publicHTTPSURL(item.sourcePageURL, 2_048) || !["resolved", "verificationRequired", "unsupported", "failed"].includes(item.state as string) || !Array.isArray(item.qualities) || item.qualities.length > 20) return false;
    if (item.title !== undefined && item.title !== null && !boundedString(item.title, 512)) return false;
    if (item.thumbnailURL !== undefined && item.thumbnailURL !== null && !publicHTTPSURL(item.thumbnailURL, 2_048)) return false;
    if (item.provider !== undefined && item.provider !== null && !boundedString(item.provider, 64)) return false;
    if (item.errorCode !== undefined && item.errorCode !== null && !["provider_verification_required", "provider_unreachable", "provider_changed"].includes(item.errorCode as string)) return false;
    return item.qualities.every((quality) => record(quality)
      && Object.keys(quality).sort().join(",") === "label,mediaKind"
      && boundedString(quality.label, 80)
      && ["direct", "hls", "yt-dlp"].includes(quality.mediaKind as string));
  });
}

export function validFeedResolveAcknowledgement(value: unknown) {
  if (!record(value) || value.status !== "completed" || !record(value.result) || value.result.kind !== "feed_resolve" || !record(value.result.playback)) return false;
  if (new TextEncoder().encode(JSON.stringify(value)).byteLength > maximumHomePreviewAcknowledgementBytes || Object.keys(value.result).sort().join(",") !== "kind,playback") return false;
  const playback = value.result.playback;
  if (Object.keys(playback).some((key) => !["sourcePageURL", "title", "provider", "qualities"].includes(key)) || !publicHTTPSURL(playback.sourcePageURL, 2_048) || !boundedString(playback.provider, 64) || !Array.isArray(playback.qualities) || playback.qualities.length < 1 || playback.qualities.length > 12) return false;
  if (playback.title !== undefined && playback.title !== null && !boundedString(playback.title, 512)) return false;
  return playback.qualities.every((quality) => {
    if (!record(quality) || Object.keys(quality).sort().join(",") !== "headers,label,mediaKind,url" || !boundedString(quality.label, 80) || !publicHTTPSURL(quality.url) || !["direct", "hls", "yt-dlp"].includes(quality.mediaKind as string) || !record(quality.headers)) return false;
    return Object.entries(quality.headers).every(([key, value]) => ["referer", "origin", "user-agent"].includes(key.toLowerCase()) && key.length <= 32 && typeof value === "string" && value.length <= 2_048);
  });
}

export function validLibraryAcknowledgement(value: unknown) {
  if (!record(value) || value.status !== "completed" || !record(value.result) || value.result.kind !== "library_snapshot" || !record(value.result.library)) return false;
  if (Object.keys(value.result).sort().join(",") !== "kind,library" || new TextEncoder().encode(JSON.stringify(value)).byteLength > 118_000) return false;
  const snapshot = value.result.library;
  if (Object.keys(snapshot).some((key) => !["revision", "page", "hasMore", "items", "verification"].includes(key)) || !nonNegativeInteger(snapshot.revision) || !Number.isSafeInteger(snapshot.page) || (snapshot.page as number) < 1 || typeof snapshot.hasMore !== "boolean" || !Array.isArray(snapshot.items) || snapshot.items.length > 100) return false;
  const validStage = (stage: unknown) => record(stage) && Object.keys(stage).sort().join(",") === "destination,state,updatedAt" && boundedString(stage.destination, 64) && ["succeeded", "running", "queued", "paused", "failed", "cancelled", "verificationRequired", "confirmed"].includes(stage.state as string) && typeof stage.updatedAt === "string" && !Number.isNaN(Date.parse(stage.updatedAt));
  if (snapshot.verification !== undefined && snapshot.verification !== null) {
    if (!record(snapshot.verification) || Object.keys(snapshot.verification).sort().join(",") !== "itemID,message,states" || !boundedString(snapshot.verification.itemID, 36) || !uuidPattern.test(snapshot.verification.itemID as string) || !boundedString(snapshot.verification.message, 512) || !Array.isArray(snapshot.verification.states) || snapshot.verification.states.length > 16 || !snapshot.verification.states.every(validStage)) return false;
  }
  return snapshot.items.every((item) => {
    if (!record(item) || Object.keys(item).some((key) => !["id", "kind", "sourcePageURL", "title", "provider", "thumbnailURL", "timestamp", "tags", "collection", "favorite", "duplicateKey", "mediaKind", "pipeline"].includes(key))) return false;
    if (!boundedString(item.id, 36) || !uuidPattern.test(item.id as string) || !["video", "link", "upload", "favorite"].includes(item.kind as string) || !publicHTTPSURL(item.sourcePageURL, 2_048) || !boundedString(item.title, 512) || !boundedString(item.provider, 64) || typeof item.timestamp !== "string" || Number.isNaN(Date.parse(item.timestamp)) || typeof item.favorite !== "boolean" || !boundedString(item.duplicateKey, 1_024) || !["video", "audio", "web"].includes(item.mediaKind as string)) return false;
    if (item.thumbnailURL !== undefined && item.thumbnailURL !== null && !publicHTTPSURL(item.thumbnailURL, 2_048)) return false;
    if (item.collection !== undefined && item.collection !== null && (typeof item.collection !== "string" || Array.from(item.collection).length > 80)) return false;
    if (!Array.isArray(item.tags) || item.tags.length > 20 || !item.tags.every((tag) => boundedString(tag, 48)) || !Array.isArray(item.pipeline) || item.pipeline.length > 16) return false;
    return item.pipeline.every(validStage);
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

export function negotiatedCommandWake(frame: Record<string, unknown>, realtime: boolean) {
  return negotiatedCommandDelivery(frame, realtime) && (frame.capabilities as unknown[]).includes(commandWakeCapability);
}

export function negotiatedPornHubAuth(frame: Record<string, unknown>, realtime: boolean) {
  return negotiatedCommandDelivery(frame, realtime) && (frame.capabilities as unknown[]).includes(pornHubAuthCapability);
}

export function negotiatedHomeWorkspace(frame: Record<string, unknown>, realtime: boolean) {
  return negotiatedCommandDelivery(frame, realtime) && (frame.capabilities as unknown[]).includes(homeWorkspaceCapability);
}

export function negotiatedLibrary(frame: Record<string, unknown>, realtime: boolean) {
  return negotiatedCommandDelivery(frame, realtime) && (frame.capabilities as unknown[]).includes(libraryCapability);
}

export type GatewayCommand =
  | { id: string; kind: "feed_sites"; payload: Record<string, never> }
  | { id: string; kind: "feed_page"; payload: { siteID: string; page: number; query?: string } }
  | { id: string; kind: "destinations_list"; payload: Record<string, never> }
  | { id: string; kind: "gdrive_connect"; payload: { deliveryProtocol: "gateway-v1" } }
  | { id: string; kind: "gdrive_folders" | "gdrive_create_folder" | "gdrive_select_folder"; payload: { profileID: string; path: string; deliveryProtocol: "gateway-v1" } }
  | { id: string; kind: "gdrive_test"; payload: { profileID: string; deliveryProtocol: "gateway-v1" } }
  | { id: string; kind: "local_folder_status" | "local_folder_choose" | "local_folder_reset"; payload: { deliveryProtocol: "gateway-v1" } }
  | { id: string; kind: "queue_url"; payload: { url: string; destination: string; preferredQualityLabel?: string; deliveryProtocol: "gateway-v1" } }
  | { id: string; kind: "job_action"; payload: { jobID: string; action: "pause" | "resume" | "cancel" | "retry"; deliveryProtocol: "gateway-v1" } }
  | { id: string; kind: "pornhub_auth_status" | "pornhub_auth_login" | "pornhub_auth_cancel" | "pornhub_auth_logout"; payload: { deliveryProtocol: "gateway-v1" } }
  | { id: string; kind: "home_status"; payload: { deliveryProtocol: "gateway-v1" } }
  | { id: string; kind: "extract_preview"; payload: { urls: string[]; deliveryProtocol: "gateway-v1" } }
  | { id: string; kind: "feed_resolve"; payload: { url: string; deliveryProtocol: "gateway-v1" } }
  | { id: string; kind: "library_list"; payload: { page: number; deliveryProtocol: "gateway-v1" } }
  | { id: string; kind: "library_update"; payload: { itemID: string; tags: string[]; collection?: string; favorite?: boolean; deliveryProtocol: "gateway-v1" } }
  | { id: string; kind: "library_remove" | "library_verify"; payload: { itemID: string; deliveryProtocol: "gateway-v1" } };

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

export function selectedGatewayCommand(value: unknown, sequence: number, correlationID: string, allowFeedPage: boolean, allowDestinationsList = false, allowFeedQueue = false, allowPornHubAuth = false, allowHomeWorkspace = false, allowLibrary = false): GatewayCommand | null | undefined {
  if (!value || typeof value !== "object" || Array.isArray(value)) return undefined;
  const record = value as Record<string, unknown>;
  if (record.version !== 1 || record.type !== "gateway-command-selected" || record.sequence !== sequence || record.correlationID !== correlationID) return undefined;
  if (record.command === null) return null;
  if (!record.command || typeof record.command !== "object" || Array.isArray(record.command)) return undefined;
  const command = record.command as Record<string, unknown>;
  if (typeof command.id !== "string" || !command.payload || typeof command.payload !== "object" || Array.isArray(command.payload)) return undefined;
  const payload = command.payload as Record<string, unknown>;
  if (command.kind === "library_list") {
    return allowLibrary && uuidPattern.test(command.id) && Object.keys(payload).sort().join(",") === "deliveryProtocol,page" && payload.deliveryProtocol === "gateway-v1" && Number.isSafeInteger(payload.page) && (payload.page as number) >= 1 && (payload.page as number) <= 100
      ? { id: command.id, kind: "library_list", payload: { page: payload.page as number, deliveryProtocol: "gateway-v1" } }
      : undefined;
  }
  if (command.kind === "library_remove" || command.kind === "library_verify") {
    return allowLibrary && uuidPattern.test(command.id) && Object.keys(payload).sort().join(",") === "deliveryProtocol,itemID" && payload.deliveryProtocol === "gateway-v1" && typeof payload.itemID === "string" && uuidPattern.test(payload.itemID)
      ? { id: command.id, kind: command.kind, payload: { itemID: payload.itemID, deliveryProtocol: "gateway-v1" } }
      : undefined;
  }
  if (command.kind === "library_update") {
    if (!allowLibrary || !uuidPattern.test(command.id) || payload.deliveryProtocol !== "gateway-v1" || typeof payload.itemID !== "string" || !uuidPattern.test(payload.itemID) || !Array.isArray(payload.tags) || payload.tags.length > 20 || !payload.tags.every((tag) => boundedString(tag, 48)) || (payload.collection !== undefined && (typeof payload.collection !== "string" || Array.from(payload.collection).length > 80)) || (payload.favorite !== undefined && typeof payload.favorite !== "boolean") || Object.keys(payload).some((key) => !["itemID", "tags", "collection", "favorite", "deliveryProtocol"].includes(key))) return undefined;
    return { id: command.id, kind: "library_update", payload: { itemID: payload.itemID, tags: payload.tags as string[], ...(typeof payload.collection === "string" ? { collection: payload.collection } : {}), ...(typeof payload.favorite === "boolean" ? { favorite: payload.favorite } : {}), deliveryProtocol: "gateway-v1" } };
  }
  if (command.kind === "home_status") {
    return allowHomeWorkspace && uuidPattern.test(command.id) && Object.keys(payload).join(",") === "deliveryProtocol" && payload.deliveryProtocol === "gateway-v1"
      ? { id: command.id, kind: "home_status", payload: { deliveryProtocol: "gateway-v1" } }
      : undefined;
  }
  if (command.kind === "extract_preview") {
    if (!allowHomeWorkspace || !uuidPattern.test(command.id) || Object.keys(payload).sort().join(",") !== "deliveryProtocol,urls" || payload.deliveryProtocol !== "gateway-v1" || !Array.isArray(payload.urls) || payload.urls.length < 1 || payload.urls.length > 10 || !payload.urls.every((url) => publicHTTPSURL(url, 2_048))) return undefined;
    return { id: command.id, kind: "extract_preview", payload: { urls: payload.urls.map((url) => new URL(url as string).toString()), deliveryProtocol: "gateway-v1" } };
  }
  if (command.kind === "feed_resolve") {
    return allowHomeWorkspace && uuidPattern.test(command.id) && Object.keys(payload).sort().join(",") === "deliveryProtocol,url" && payload.deliveryProtocol === "gateway-v1" && publicHTTPSURL(payload.url, 2_048)
      ? { id: command.id, kind: "feed_resolve", payload: { url: new URL(payload.url as string).toString(), deliveryProtocol: "gateway-v1" } }
      : undefined;
  }
  if (command.kind === "feed_sites" && Object.keys(payload).length === 0) return { id: command.id, kind: "feed_sites", payload: {} };
  if (command.kind === "destinations_list") return allowDestinationsList && uuidPattern.test(command.id) && Object.keys(payload).length === 0 ? { id: command.id, kind: "destinations_list", payload: {} } : undefined;
  if (command.kind === "local_folder_status" || command.kind === "local_folder_choose" || command.kind === "local_folder_reset") {
    return allowDestinationsList && uuidPattern.test(command.id) && Object.keys(payload).join(",") === "deliveryProtocol" && payload.deliveryProtocol === "gateway-v1"
      ? { id: command.id, kind: command.kind, payload: { deliveryProtocol: "gateway-v1" } }
      : undefined;
  }
  if (command.kind === "gdrive_connect") {
    return allowDestinationsList && uuidPattern.test(command.id) && Object.keys(payload).join(",") === "deliveryProtocol" && payload.deliveryProtocol === "gateway-v1" ? { id: command.id, kind: "gdrive_connect", payload: { deliveryProtocol: "gateway-v1" } } : undefined;
  }
  if (command.kind === "gdrive_test") {
    return allowDestinationsList && uuidPattern.test(command.id) && Object.keys(payload).sort().join(",") === "deliveryProtocol,profileID" && payload.deliveryProtocol === "gateway-v1" && typeof payload.profileID === "string" && uuidPattern.test(payload.profileID) ? { id: command.id, kind: "gdrive_test", payload: { profileID: payload.profileID, deliveryProtocol: "gateway-v1" } } : undefined;
  }
  if (command.kind === "gdrive_folders" || command.kind === "gdrive_create_folder" || command.kind === "gdrive_select_folder") {
    if (!allowDestinationsList || !uuidPattern.test(command.id) || Object.keys(payload).sort().join(",") !== "deliveryProtocol,path,profileID" || payload.deliveryProtocol !== "gateway-v1" || typeof payload.profileID !== "string" || !uuidPattern.test(payload.profileID) || typeof payload.path !== "string" || payload.path.length > 1_024 || !payload.path.startsWith("/") || payload.path.split("/").some((part) => part === "." || part === "..")) return undefined;
    return { id: command.id, kind: command.kind, payload: { profileID: payload.profileID, path: payload.path, deliveryProtocol: "gateway-v1" } };
  }
  if (command.kind === "queue_url") {
    const keys = Object.keys(payload).sort().join(",");
    if (!allowFeedQueue || !uuidPattern.test(command.id) || !["deliveryProtocol,destination,url", "deliveryProtocol,destination,preferredQualityLabel,url"].includes(keys) || payload.deliveryProtocol !== "gateway-v1") return undefined;
    if (!httpsURL(payload.url, 2_048) || typeof payload.destination !== "string" || !/^local$|^(webdav|gdrive):[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(payload.destination)) return undefined;
    const preferredQualityLabel = payload.preferredQualityLabel;
    if (preferredQualityLabel !== undefined && (typeof preferredQualityLabel !== "string" || !boundedString(preferredQualityLabel, 80))) return undefined;
    const normalized = { id: command.id, kind: "queue_url" as const, payload: { url: new URL(payload.url as string).toString(), destination: payload.destination, ...(preferredQualityLabel ? { preferredQualityLabel } : {}), deliveryProtocol: "gateway-v1" as const } };
    return new TextEncoder().encode(JSON.stringify(normalized)).byteLength <= 4_096 ? normalized : undefined;
  }
  if (command.kind === "job_action") {
    if (!uuidPattern.test(command.id) || Object.keys(payload).sort().join(",") !== "action,deliveryProtocol,jobID" || payload.deliveryProtocol !== "gateway-v1" || typeof payload.jobID !== "string" || !uuidPattern.test(payload.jobID) || typeof payload.action !== "string" || !["pause", "resume", "cancel", "retry"].includes(payload.action)) return undefined;
    return { id: command.id, kind: "job_action", payload: { jobID: payload.jobID, action: payload.action as "pause" | "resume" | "cancel" | "retry", deliveryProtocol: "gateway-v1" } };
  }
  if (["pornhub_auth_status", "pornhub_auth_login", "pornhub_auth_cancel", "pornhub_auth_logout"].includes(command.kind as string)) {
    if (!allowPornHubAuth || !uuidPattern.test(command.id) || Object.keys(payload).join(",") !== "deliveryProtocol" || payload.deliveryProtocol !== "gateway-v1") return undefined;
    return { id: command.id, kind: command.kind as "pornhub_auth_status" | "pornhub_auth_login" | "pornhub_auth_cancel" | "pornhub_auth_logout", payload: { deliveryProtocol: "gateway-v1" } };
  }
  if (command.kind !== "feed_page" || !allowFeedPage || typeof payload.siteID !== "string" || !feedSiteIDs.has(payload.siteID) || !Number.isSafeInteger(payload.page) || (payload.page as number) < 1) return undefined;
  const query = normalizedQuery(payload.query);
  if (query === null || Object.keys(payload).some((key) => !["siteID", "page", "query"].includes(key))) return undefined;
  return { id: command.id, kind: "feed_page", payload: { siteID: payload.siteID, page: payload.page as number, ...(query ? { query } : {}) } };
}
