export const DEVICE_PROTOCOL_VERSION = 1;
export const PAIRING_CODE_LENGTH = 20;
export const MAX_PUBLIC_KEY_BYTES = 512;
export const MAX_SIGNATURE_BYTES = 160;
export const HEARTBEAT_INTERVAL_SECONDS = 30;
export const PRESENCE_FRESHNESS_SECONDS = 75;
export const MAX_HEARTBEAT_FRAME_BYTES = 131_072;
export const MAX_FEED_PAGE_ACK_BYTES = 118_000;
export const MAX_DESTINATIONS_ACK_BYTES = 32_768;
export const MAX_DESTINATIONS = 64;
export const FEED_SITE_IDS = ["allpornstream", "hqporner", "onlyfan420", "pornhub", "pornhub-subscriptions", "pornhub-liked", "pornhub-favorites"] as const;

export type DeviceErrorCode =
  | "unauthenticated" | "email_unverified" | "invalid_request" | "invalid_pairing_code"
  | "challenge_expired" | "challenge_consumed" | "device_revoked" | "device_not_found"
  | "invalid_signature" | "unsupported_protocol" | "rate_limited" | "already_enrolled" | "conflict"
  | "agent_offline" | "internal_error";

export class DeviceContractError extends Error {
  readonly code: DeviceErrorCode;
  constructor(code: DeviceErrorCode, message: string) { super(message); this.code = code; }
}

export function normalizePairingCode(value: string): string {
  const normalized = value.replace(/[\s-]/g, "").toUpperCase();
  if (!new RegExp(`^[0123456789ABCDEFGHJKMNPQRSTVWXYZ]{${PAIRING_CODE_LENGTH}}$`).test(normalized)) {
    throw new DeviceContractError("invalid_pairing_code", "The pairing code is invalid.");
  }
  return normalized;
}

export function validateDisplayName(value: unknown): string {
  if (typeof value !== "string") throw new DeviceContractError("invalid_request", "displayName is required.");
  const name = value.trim();
  if ([...name].length < 1 || [...name].length > 80) throw new DeviceContractError("invalid_request", "displayName must be 1–80 characters.");
  return name;
}

export function decodeBase64(value: unknown, maxBytes: number, field: string): Uint8Array {
  if (typeof value !== "string" || value.length === 0 || value.length > Math.ceil(maxBytes / 3) * 4 + 4 || !/^[A-Za-z0-9+/]+={0,2}$/.test(value)) {
    throw new DeviceContractError("invalid_request", `${field} is invalid.`);
  }
  const bytes = Uint8Array.from(Buffer.from(value, "base64"));
  if (bytes.length === 0 || bytes.length > maxBytes || Buffer.from(bytes).toString("base64") !== value) {
    throw new DeviceContractError("invalid_request", `${field} is invalid.`);
  }
  return bytes;
}

export function requireProtocolVersion(value: unknown): number {
  if (value !== DEVICE_PROTOCOL_VERSION) throw new DeviceContractError("unsupported_protocol", "Unsupported device protocol version.");
  return DEVICE_PROTOCOL_VERSION;
}

export function isoDate(value: Date): string { return value.toISOString(); }

export function deviceError(error: unknown): { error: { code: DeviceErrorCode; message: string } } {
  if (error instanceof DeviceContractError) return { error: { code: error.code, message: error.message } };
  return { error: { code: "internal_error", message: "Unable to process the device request." } };
}

const UUID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const JOB_STATUSES = new Set(["queued", "running", "paused", "completed", "failed", "cancelled", "verificationRequired"]);
const JOB_PHASES = new Set(["resolving", "downloading", "materializing", "postProcessing", "uploading", "verifying"]);
const MAX_JOB_STRING_CHARACTERS = 512;
const MAX_SOURCE_URL_CHARACTERS = 4_096;
const ACKNOWLEDGEMENT_CODES = new Set(["provider_verification_required", "provider_http_error", "provider_unreachable", "provider_changed", "authentication_required", "browser_extension_required", "result_too_large", "invalid_request", "signed_out", "signing_in", "cancelled", "expired", "auth_helper_unavailable", "auth_helper_failed", "auth_timeout", "invalid_session", "auth_storage_unavailable"]);
const PORNHUB_AUTH_STATES = new Set(["signedOut", "signingIn", "signedIn", "expired"]);

function record(value: unknown): value is Record<string, unknown> { return !!value && typeof value === "object" && !Array.isArray(value); }
function uuid(value: unknown): value is string { return typeof value === "string" && UUID_PATTERN.test(value); }
function boundedString(value: unknown, maximum: number): value is string { return typeof value === "string" && value.trim().length > 0 && [...value].length <= maximum; }
function nonNegativeInteger(value: unknown): value is number { return Number.isSafeInteger(value) && (value as number) >= 0; }
function httpsURL(value: unknown, maximum = 4_096): value is string {
  if (typeof value !== "string" || value.length > maximum) return false;
  try { const url = new URL(value); return url.protocol === "https:" && !url.username && !url.password; }
  catch { return false; }
}

function publicHTTPSURL(value: unknown, maximum = 4_096): value is string {
  if (!httpsURL(value, maximum)) return false;
  const host = new URL(value).hostname.toLowerCase().replace(/^\[|\]$/g, "");
  if (host === "localhost" || host.endsWith(".localhost") || host === "::1" || host === "0.0.0.0" || host.startsWith("fc") || host.startsWith("fd") || /^fe[89ab]/.test(host)) return false;
  const parts = host.split(".").map(Number);
  return parts.length !== 4 || !parts.every((part) => Number.isInteger(part) && part >= 0 && part <= 255)
    || !(parts[0] === 10 || parts[0] === 127 || (parts[0] === 169 && parts[1] === 254) || (parts[0] === 172 && parts[1] >= 16 && parts[1] <= 31) || (parts[0] === 192 && parts[1] === 168));
}

export function normalizeFeedPageCommand(value: unknown) {
  if (!record(value) || typeof value.siteID !== "string" || !FEED_SITE_IDS.includes(value.siteID as (typeof FEED_SITE_IDS)[number]) || !Number.isSafeInteger(value.page) || (value.page as number) < 1) throw new DeviceContractError("invalid_request", "A supported feed page is required.");
  if (value.query !== undefined && typeof value.query !== "string") throw new DeviceContractError("invalid_request", "A supported feed query is required.");
  if (typeof value.query === "string" && value.query.match(/[\u0000-\u001f\u007f-\u009f]/)) throw new DeviceContractError("invalid_request", "A supported feed query is required.");
  const query = typeof value.query === "string" ? value.query.trim().split(/\s+/).join(" ") : undefined;
  if ([...(query ?? "")].length > 120) throw new DeviceContractError("invalid_request", "A supported feed query is required.");
  return { siteID: value.siteID as (typeof FEED_SITE_IDS)[number], page: value.page as number, ...(query ? { query } : {}) };
}

export function validFeedPageResult(value: unknown): value is Record<string, unknown> {
  if (!record(value) || value.kind !== "feed_page" || !record(value.page)) return false;
  const page = value.page;
  if (!Number.isSafeInteger(page.page) || (page.page as number) < 1 || typeof page.hasMore !== "boolean" || !Array.isArray(page.items) || page.items.length > 50) return false;
  for (const item of page.items) {
    if (!record(item) || !boundedString(item.id, 512) || typeof item.siteID !== "string" || !FEED_SITE_IDS.includes(item.siteID as (typeof FEED_SITE_IDS)[number]) || !boundedString(item.title, 1_024) || !httpsURL(item.sourcePageURL) || typeof item.uploadedAt !== "string" || Number.isNaN(Date.parse(item.uploadedAt)) || typeof item.uploadedAtIsApproximate !== "boolean" || !nonNegativeInteger(item.viewCount) || item.queueCapability !== "supported") return false;
    if (item.downloadedAt !== undefined && (typeof item.downloadedAt !== "string" || Number.isNaN(Date.parse(item.downloadedAt)))) return false;
    if (item.thumbnailURL !== undefined && item.thumbnailURL !== null && !httpsURL(item.thumbnailURL)) return false;
    if (!Array.isArray(item.previewURLs) || item.previewURLs.length > 4 || !item.previewURLs.every((url) => httpsURL(url))) return false;
    if (item.studio !== undefined && item.studio !== null && (typeof item.studio !== "string" || [...item.studio].length > 512)) return false;
  }
  return true;
}

function normalizedRemotePath(value: unknown): value is string {
  if (typeof value !== "string" || value.length > 1_024 || !value.startsWith("/")) return false;
  const components = value.split("/").filter(Boolean);
  return !components.some((component) => component === "." || component === "..") && (components.length ? `/${components.join("/")}` : "/") === value;
}

export function validDestinationsResult(value: unknown): value is Record<string, unknown> {
  if (!record(value) || value.kind !== "destinations_list" || !Array.isArray(value.destinations) || value.destinations.length > MAX_DESTINATIONS || Object.keys(value).some((key) => !["kind", "destinations"].includes(key))) return false;
  return value.destinations.every((destination) => {
    if (!record(destination) || !uuid(destination.id) || !boundedString(destination.name, 128) || !normalizedRemotePath(destination.remotePath)) return false;
    if (destination.kind === "google_drive") {
      return Object.keys(destination).every((key) => ["id", "name", "kind", "remoteName", "remotePath"].includes(key))
        && boundedString(destination.remoteName, 64)
        && /^[A-Za-z0-9._-]+$/.test(destination.remoteName as string);
    }
    if ((destination.kind !== undefined && destination.kind !== "webdav") || Object.keys(destination).some((key) => !["id", "name", "kind", "baseURL", "username", "remotePath", "allowInvalidCertificate"].includes(key))) return false;
    if (!httpsURL(destination.baseURL, 2_048) || !boundedString(destination.username, 256) || typeof destination.allowInvalidCertificate !== "boolean") return false;
    const url = new URL(destination.baseURL as string);
    return !url.search && !url.hash;
  });
}

function validGoogleDriveFoldersResult(value: unknown): value is Record<string, unknown> {
  if (!record(value) || value.kind !== "google_drive_folders" || !Array.isArray(value.googleDriveFolders) || value.googleDriveFolders.length > 200 || Object.keys(value).some((key) => !["kind", "googleDriveFolders"].includes(key))) return false;
  return value.googleDriveFolders.every((folder) => record(folder) && Object.keys(folder).sort().join(",") === "name,path" && boundedString(folder.name, 256) && normalizedRemotePath(folder.path));
}

export function validLocalDownloadFolderResult(value: unknown): value is Record<string, unknown> {
  if (!record(value) || value.kind !== "local_download_folder" || !record(value.localDownloadFolder) || Object.keys(value).sort().join(",") !== "kind,localDownloadFolder") return false;
  const folder = value.localDownloadFolder;
  return Object.keys(folder).sort().join(",") === "folderName,mode"
    && ["default", "custom"].includes(folder.mode as string)
    && boundedString(folder.folderName, 128);
}

function validPornHubAuthResult(value: unknown): value is Record<string, unknown> {
  if (!record(value) || value.kind !== "pornhub_auth" || !record(value.pornHubAuth) || Object.keys(value).some((key) => !["kind", "pornHubAuth"].includes(key))) return false;
  const status = value.pornHubAuth;
  return Object.keys(status).every((key) => ["state", "lastValidatedAt", "code"].includes(key))
    && typeof status.state === "string" && PORNHUB_AUTH_STATES.has(status.state)
    && (status.lastValidatedAt === undefined || (typeof status.lastValidatedAt === "string" && !Number.isNaN(Date.parse(status.lastValidatedAt))))
    && (status.code === undefined || (typeof status.code === "string" && ACKNOWLEDGEMENT_CODES.has(status.code)));
}

export function validHomeWorkspaceResult(value: unknown): value is Record<string, unknown> {
  if (!record(value) || !["home_status", "extract_preview"].includes(value.kind as string)) return false;
  if (new TextEncoder().encode(JSON.stringify(value)).byteLength > 64_000) return false;
  if (value.kind === "home_status") {
    return Object.keys(value).sort().join(",") === "homeReadiness,kind"
      && record(value.homeReadiness)
      && Object.keys(value.homeReadiness).sort().join(",") === "browserBridge,ffmpeg,ytDlp"
      && Object.values(value.homeReadiness).every((item) => typeof item === "boolean");
  }
  if (!Array.isArray(value.homePreview) || value.homePreview.length < 1 || value.homePreview.length > 10 || Object.keys(value).sort().join(",") !== "homePreview,kind") return false;
  return value.homePreview.every((item) => {
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

export function validFeedResolveResult(value: unknown): value is Record<string, unknown> {
  if (!record(value) || value.kind !== "feed_resolve" || !record(value.playback) || Object.keys(value).sort().join(",") !== "kind,playback") return false;
  if (new TextEncoder().encode(JSON.stringify(value)).byteLength > 64_000) return false;
  const playback = value.playback;
  if (Object.keys(playback).some((key) => !["sourcePageURL", "title", "provider", "qualities"].includes(key)) || !publicHTTPSURL(playback.sourcePageURL, 2_048) || !boundedString(playback.provider, 64) || !Array.isArray(playback.qualities) || playback.qualities.length < 1 || playback.qualities.length > 12) return false;
  if (playback.title !== undefined && playback.title !== null && !boundedString(playback.title, 512)) return false;
  return playback.qualities.every((quality) => {
    if (!record(quality) || Object.keys(quality).sort().join(",") !== "headers,label,mediaKind,url" || !boundedString(quality.label, 80) || !publicHTTPSURL(quality.url) || !["direct", "hls", "yt-dlp"].includes(quality.mediaKind as string) || !record(quality.headers)) return false;
    return Object.entries(quality.headers).every(([key, headerValue]) => ["referer", "origin", "user-agent"].includes(key.toLowerCase()) && key.length <= 32 && typeof headerValue === "string" && headerValue.length <= 2_048);
  });
}

export function validLibraryResult(value: unknown): value is Record<string, unknown> {
  if (!record(value) || value.kind !== "library_snapshot" || !record(value.library) || Object.keys(value).sort().join(",") !== "kind,library" || new TextEncoder().encode(JSON.stringify(value)).byteLength > 118_000) return false;
  const snapshot = value.library;
  if (Object.keys(snapshot).some((key) => !["revision", "page", "hasMore", "items", "verification"].includes(key)) || !nonNegativeInteger(snapshot.revision) || !Number.isSafeInteger(snapshot.page) || (snapshot.page as number) < 1 || typeof snapshot.hasMore !== "boolean" || !Array.isArray(snapshot.items) || snapshot.items.length > 100) return false;
  const validStage = (stage: unknown) => record(stage) && Object.keys(stage).sort().join(",") === "destination,state,updatedAt" && boundedString(stage.destination, 64) && ["succeeded", "running", "queued", "paused", "failed", "cancelled", "verificationRequired", "confirmed"].includes(stage.state as string) && typeof stage.updatedAt === "string" && !Number.isNaN(Date.parse(stage.updatedAt));
  if (snapshot.verification !== undefined && snapshot.verification !== null && (!record(snapshot.verification) || Object.keys(snapshot.verification).sort().join(",") !== "itemID,message,states" || !uuid(snapshot.verification.itemID) || !boundedString(snapshot.verification.message, 512) || !Array.isArray(snapshot.verification.states) || snapshot.verification.states.length > 16 || !snapshot.verification.states.every(validStage))) return false;
  return snapshot.items.every((item) => {
    if (!record(item) || Object.keys(item).some((key) => !["id", "kind", "sourcePageURL", "title", "provider", "thumbnailURL", "timestamp", "tags", "collection", "favorite", "duplicateKey", "mediaKind", "pipeline"].includes(key))) return false;
    if (!uuid(item.id) || !["video", "link", "upload", "favorite"].includes(item.kind as string) || !publicHTTPSURL(item.sourcePageURL, 2_048) || !boundedString(item.title, 512) || !boundedString(item.provider, 64) || typeof item.timestamp !== "string" || Number.isNaN(Date.parse(item.timestamp)) || typeof item.favorite !== "boolean" || !boundedString(item.duplicateKey, 1_024) || !["video", "audio", "web"].includes(item.mediaKind as string)) return false;
    if (item.thumbnailURL !== undefined && item.thumbnailURL !== null && !publicHTTPSURL(item.thumbnailURL, 2_048)) return false;
    if (item.collection !== undefined && item.collection !== null && (typeof item.collection !== "string" || Array.from(item.collection).length > 80)) return false;
    if (!Array.isArray(item.tags) || item.tags.length > 20 || !item.tags.every((tag) => boundedString(tag, 48)) || !Array.isArray(item.pipeline) || item.pipeline.length > 16) return false;
    return item.pipeline.every(validStage);
  });
}

export type RemoteCommandAck = { id: string; status: "completed" | "failed"; jobID?: string; result?: Record<string, unknown>; code?: string };
export type RemoteJobStatus = { id: string; sourcePageURL?: string; displayName?: string; preferredQualityLabel?: string; status: "queued" | "running" | "paused" | "completed" | "failed" | "cancelled" | "verificationRequired"; progress?: number; downloadedBytes?: number; totalBytes?: number; phase?: "resolving" | "downloading" | "materializing" | "postProcessing" | "uploading" | "verifying"; attempts: number; queuePriority?: number; updatedAt?: string };
export type HeartbeatFrame = { version: 1; type: "heartbeat"; sequence: number; sentAt: string; agentVersion: string; correlationID: string; commandAcks: RemoteCommandAck[]; jobs: RemoteJobStatus[] };
export function parseHeartbeatFrame(value: unknown): HeartbeatFrame {
  if (!record(value)) throw new DeviceContractError("invalid_request", "Invalid heartbeat.");
  const frame = value;
  if (frame.version !== DEVICE_PROTOCOL_VERSION || frame.type !== "heartbeat" || !Number.isSafeInteger(frame.sequence) || (frame.sequence as number) < 1 || typeof frame.sentAt !== "string" || Number.isNaN(Date.parse(frame.sentAt)) || !boundedString(frame.agentVersion, 80) || !boundedString(frame.correlationID, 64)) throw new DeviceContractError("invalid_request", "Invalid heartbeat.");
  const commandAcks = frame.commandAcks; const jobs = frame.jobs;
  if (!Array.isArray(commandAcks) || commandAcks.length > 8 || !Array.isArray(jobs) || jobs.length > 50) throw new DeviceContractError("invalid_request", "Invalid heartbeat.");
  for (const ack of commandAcks) {
    if (!record(ack) || !uuid(ack.id) || !["completed", "failed"].includes(ack.status as string) || (ack.jobID !== undefined && !uuid(ack.jobID)) || (ack.result !== undefined && !record(ack.result)) || (ack.code !== undefined && (typeof ack.code !== "string" || !ACKNOWLEDGEMENT_CODES.has(ack.code)))) throw new DeviceContractError("invalid_request", "Invalid heartbeat.");
    if (ack.status === "failed" && ack.result !== undefined) throw new DeviceContractError("invalid_request", "Invalid heartbeat.");
    if (ack.status === "completed" && record(ack.result) && ack.result.kind === "feed_page" && (!validFeedPageResult(ack.result) || new TextEncoder().encode(JSON.stringify(ack)).byteLength > MAX_FEED_PAGE_ACK_BYTES)) throw new DeviceContractError("invalid_request", "Invalid heartbeat.");
    if (ack.status === "completed" && record(ack.result) && ack.result.kind === "destinations_list" && (!validDestinationsResult(ack.result) || new TextEncoder().encode(JSON.stringify(ack)).byteLength > MAX_DESTINATIONS_ACK_BYTES)) throw new DeviceContractError("invalid_request", "Invalid heartbeat.");
    if (ack.status === "completed" && record(ack.result) && ack.result.kind === "google_drive_folders" && !validGoogleDriveFoldersResult(ack.result)) throw new DeviceContractError("invalid_request", "Invalid heartbeat.");
    if (ack.status === "completed" && record(ack.result) && ack.result.kind === "local_download_folder" && !validLocalDownloadFolderResult(ack.result)) throw new DeviceContractError("invalid_request", "Invalid heartbeat.");
    if (ack.status === "completed" && record(ack.result) && ack.result.kind === "pornhub_auth" && !validPornHubAuthResult(ack.result)) throw new DeviceContractError("invalid_request", "Invalid heartbeat.");
    if (ack.status === "completed" && record(ack.result) && ["home_status", "extract_preview"].includes(ack.result.kind as string) && !validHomeWorkspaceResult(ack.result)) throw new DeviceContractError("invalid_request", "Invalid heartbeat.");
    if (ack.status === "completed" && record(ack.result) && ack.result.kind === "feed_resolve" && !validFeedResolveResult(ack.result)) throw new DeviceContractError("invalid_request", "Invalid heartbeat.");
    if (ack.status === "completed" && record(ack.result) && ack.result.kind === "library_snapshot" && !validLibraryResult(ack.result)) throw new DeviceContractError("invalid_request", "Invalid heartbeat.");
  }
  for (const job of jobs) {
    if (!record(job) || !uuid(job.id) || typeof job.status !== "string" || !JOB_STATUSES.has(job.status) || !nonNegativeInteger(job.attempts)) throw new DeviceContractError("invalid_request", "Invalid heartbeat.");
    if (job.progress !== undefined && (typeof job.progress !== "number" || !Number.isFinite(job.progress) || job.progress < 0 || job.progress > 1)) throw new DeviceContractError("invalid_request", "Invalid heartbeat.");
    if (job.downloadedBytes !== undefined && !nonNegativeInteger(job.downloadedBytes)) throw new DeviceContractError("invalid_request", "Invalid heartbeat.");
    if (job.totalBytes !== undefined && !nonNegativeInteger(job.totalBytes)) throw new DeviceContractError("invalid_request", "Invalid heartbeat.");
    if (job.phase !== undefined && (typeof job.phase !== "string" || !JOB_PHASES.has(job.phase))) throw new DeviceContractError("invalid_request", "Invalid heartbeat.");
    if (job.queuePriority !== undefined && !nonNegativeInteger(job.queuePriority)) throw new DeviceContractError("invalid_request", "Invalid heartbeat.");
    if (job.displayName !== undefined && !boundedString(job.displayName, MAX_JOB_STRING_CHARACTERS)) throw new DeviceContractError("invalid_request", "Invalid heartbeat.");
    if (job.preferredQualityLabel !== undefined && !boundedString(job.preferredQualityLabel, MAX_JOB_STRING_CHARACTERS)) throw new DeviceContractError("invalid_request", "Invalid heartbeat.");
    if (job.sourcePageURL !== undefined) {
      if (!boundedString(job.sourcePageURL, MAX_SOURCE_URL_CHARACTERS)) throw new DeviceContractError("invalid_request", "Invalid heartbeat.");
      try { if (!["http:", "https:"].includes(new URL(job.sourcePageURL).protocol)) throw new Error(); }
      catch { throw new DeviceContractError("invalid_request", "Invalid heartbeat."); }
    }
    const updatedAt = job.updatedAt;
    if (updatedAt !== undefined && (typeof updatedAt !== "string" || Number.isNaN(Date.parse(updatedAt)))) throw new DeviceContractError("invalid_request", "Invalid heartbeat.");
  }
  return { ...(frame as Omit<HeartbeatFrame, "commandAcks" | "jobs">), commandAcks: commandAcks as RemoteCommandAck[], jobs: jobs as RemoteJobStatus[] };
}
