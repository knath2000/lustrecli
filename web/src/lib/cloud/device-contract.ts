export const DEVICE_PROTOCOL_VERSION = 1;
export const PAIRING_CODE_LENGTH = 20;
export const MAX_PUBLIC_KEY_BYTES = 512;
export const MAX_SIGNATURE_BYTES = 160;
export const HEARTBEAT_INTERVAL_SECONDS = 30;
export const PRESENCE_FRESHNESS_SECONDS = 75;
export const MAX_HEARTBEAT_FRAME_BYTES = 131_072;
export const MAX_FEED_PAGE_ACK_BYTES = 65_536;
export const FEED_SITE_IDS = ["allpornstream", "hqporner", "onlyfan420", "pornhub", "pornhub-subscriptions", "pornhub-liked", "pornhub-favorites"] as const;

export type DeviceErrorCode =
  | "unauthenticated" | "email_unverified" | "invalid_request" | "invalid_pairing_code"
  | "challenge_expired" | "challenge_consumed" | "device_revoked" | "device_not_found"
  | "invalid_signature" | "unsupported_protocol" | "rate_limited" | "already_enrolled" | "internal_error";

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

function record(value: unknown): value is Record<string, unknown> { return !!value && typeof value === "object" && !Array.isArray(value); }
function uuid(value: unknown): value is string { return typeof value === "string" && UUID_PATTERN.test(value); }
function boundedString(value: unknown, maximum: number): value is string { return typeof value === "string" && value.trim().length > 0 && [...value].length <= maximum; }
function nonNegativeInteger(value: unknown): value is number { return Number.isSafeInteger(value) && (value as number) >= 0; }
function httpsURL(value: unknown, maximum = 4_096): value is string {
  if (typeof value !== "string" || value.length > maximum) return false;
  try { const url = new URL(value); return url.protocol === "https:" && !url.username && !url.password; }
  catch { return false; }
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
    if (item.thumbnailURL !== undefined && item.thumbnailURL !== null && !httpsURL(item.thumbnailURL)) return false;
    if (!Array.isArray(item.previewURLs) || item.previewURLs.length > 4 || !item.previewURLs.every((url) => httpsURL(url))) return false;
    if (item.studio !== undefined && item.studio !== null && (typeof item.studio !== "string" || [...item.studio].length > 512)) return false;
  }
  return true;
}

export type RemoteCommandAck = { id: string; status: "completed" | "failed"; jobID?: string; result?: Record<string, unknown> };
export type RemoteJobStatus = { id: string; sourcePageURL?: string; displayName?: string; preferredQualityLabel?: string; status: "queued" | "running" | "paused" | "completed" | "failed" | "cancelled" | "verificationRequired"; progress?: number; downloadedBytes?: number; totalBytes?: number; phase?: "resolving" | "downloading" | "materializing" | "postProcessing" | "uploading" | "verifying"; attempts: number; updatedAt?: string };
export type HeartbeatFrame = { version: 1; type: "heartbeat"; sequence: number; sentAt: string; agentVersion: string; correlationID: string; commandAcks: RemoteCommandAck[]; jobs: RemoteJobStatus[] };
export function parseHeartbeatFrame(value: unknown): HeartbeatFrame {
  if (!record(value)) throw new DeviceContractError("invalid_request", "Invalid heartbeat.");
  const frame = value;
  if (frame.version !== DEVICE_PROTOCOL_VERSION || frame.type !== "heartbeat" || !Number.isSafeInteger(frame.sequence) || (frame.sequence as number) < 1 || typeof frame.sentAt !== "string" || Number.isNaN(Date.parse(frame.sentAt)) || !boundedString(frame.agentVersion, 80) || !boundedString(frame.correlationID, 64)) throw new DeviceContractError("invalid_request", "Invalid heartbeat.");
  const commandAcks = frame.commandAcks; const jobs = frame.jobs;
  if (!Array.isArray(commandAcks) || commandAcks.length > 8 || !Array.isArray(jobs) || jobs.length > 50) throw new DeviceContractError("invalid_request", "Invalid heartbeat.");
  for (const ack of commandAcks) {
    if (!record(ack) || !uuid(ack.id) || !["completed", "failed"].includes(ack.status as string) || (ack.jobID !== undefined && !uuid(ack.jobID)) || (ack.result !== undefined && !record(ack.result))) throw new DeviceContractError("invalid_request", "Invalid heartbeat.");
    if (ack.status === "completed" && record(ack.result) && ack.result.kind === "feed_page" && (!validFeedPageResult(ack.result) || new TextEncoder().encode(JSON.stringify(ack)).byteLength > MAX_FEED_PAGE_ACK_BYTES)) throw new DeviceContractError("invalid_request", "Invalid heartbeat.");
  }
  for (const job of jobs) {
    if (!record(job) || !uuid(job.id) || typeof job.status !== "string" || !JOB_STATUSES.has(job.status) || !nonNegativeInteger(job.attempts)) throw new DeviceContractError("invalid_request", "Invalid heartbeat.");
    if (job.progress !== undefined && (typeof job.progress !== "number" || !Number.isFinite(job.progress) || job.progress < 0 || job.progress > 1)) throw new DeviceContractError("invalid_request", "Invalid heartbeat.");
    if (job.downloadedBytes !== undefined && !nonNegativeInteger(job.downloadedBytes)) throw new DeviceContractError("invalid_request", "Invalid heartbeat.");
    if (job.totalBytes !== undefined && !nonNegativeInteger(job.totalBytes)) throw new DeviceContractError("invalid_request", "Invalid heartbeat.");
    if (job.phase !== undefined && (typeof job.phase !== "string" || !JOB_PHASES.has(job.phase))) throw new DeviceContractError("invalid_request", "Invalid heartbeat.");
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
