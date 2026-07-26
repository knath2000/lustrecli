export const DEVICE_PROTOCOL_VERSION = 1;
export const PAIRING_CODE_LENGTH = 20;
export const MAX_PUBLIC_KEY_BYTES = 512;
export const MAX_SIGNATURE_BYTES = 160;
export const HEARTBEAT_INTERVAL_SECONDS = 30;
export const PRESENCE_FRESHNESS_SECONDS = 75;
export const MAX_HEARTBEAT_FRAME_BYTES = 131_072;

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

export type RemoteCommandAck = { id: string; status: "completed" | "failed"; jobID?: string; result?: Record<string, unknown> };
export type RemoteJobStatus = { id: string; sourcePageURL?: string; displayName?: string; preferredQualityLabel?: string; status: string; progress?: number; downloadedBytes?: number; totalBytes?: number; phase?: string; attempts: number };
export type HeartbeatFrame = { version: 1; type: "heartbeat"; sequence: number; sentAt: string; agentVersion: string; commandAcks: RemoteCommandAck[]; jobs: RemoteJobStatus[] };
export function parseHeartbeatFrame(value: unknown): HeartbeatFrame {
  if (!value || typeof value !== "object" || Array.isArray(value)) throw new DeviceContractError("invalid_request", "Invalid heartbeat.");
  const frame = value as Record<string, unknown>;
  if (frame.version !== DEVICE_PROTOCOL_VERSION || frame.type !== "heartbeat" || !Number.isSafeInteger(frame.sequence) || (frame.sequence as number) < 1 || typeof frame.sentAt !== "string" || Number.isNaN(Date.parse(frame.sentAt)) || typeof frame.agentVersion !== "string" || frame.agentVersion.length < 1 || frame.agentVersion.length > 80) throw new DeviceContractError("invalid_request", "Invalid heartbeat.");
  const commandAcks = frame.commandAcks ?? []; const jobs = frame.jobs ?? [];
  if (!Array.isArray(commandAcks) || commandAcks.length > 8 || !Array.isArray(jobs) || jobs.length > 50) throw new DeviceContractError("invalid_request", "Invalid heartbeat.");
  for (const ack of commandAcks) if (!ack || typeof ack !== "object" || typeof (ack as Record<string, unknown>).id !== "string" || !["completed", "failed"].includes((ack as Record<string, unknown>).status as string)) throw new DeviceContractError("invalid_request", "Invalid heartbeat.");
  for (const job of jobs) if (!job || typeof job !== "object" || typeof (job as Record<string, unknown>).id !== "string" || typeof (job as Record<string, unknown>).status !== "string" || !Number.isSafeInteger((job as Record<string, unknown>).attempts)) throw new DeviceContractError("invalid_request", "Invalid heartbeat.");
  return { ...(frame as Omit<HeartbeatFrame, "commandAcks" | "jobs">), commandAcks: commandAcks as RemoteCommandAck[], jobs: jobs as RemoteJobStatus[] };
}
