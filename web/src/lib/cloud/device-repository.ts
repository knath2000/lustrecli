import "server-only";
import { and, desc, eq, gt, isNull, sql } from "drizzle-orm";
import { randomUUID } from "node:crypto";
import { db } from "@/lib/db/client";
import { lustreDeviceAuditEvents, lustreDeviceCommands, lustreDeviceEnrollments, lustreDeviceJobStatus, lustreDevicePresence, lustreDevices, lustreDeviceSessionChallenges, lustrePairingChallenges } from "@/lib/db/schema";
import { DeviceContractError } from "./device-contract";
import { randomNonce } from "./device-crypto";

const now = () => new Date();
export type EnrollmentInput = { pairingCodeHash: string; publicKey: string; keyThumbprint: string; displayName: string; platform: string; agentVersion: string };

export async function createPairingChallenge(accountID: string, codeHash: string) {
  const expiry = new Date(Date.now() + 5 * 60_000);
  const active = await db.select({ id: lustrePairingChallenges.id }).from(lustrePairingChallenges).where(and(eq(lustrePairingChallenges.accountID, accountID), isNull(lustrePairingChallenges.consumedAt), gt(lustrePairingChallenges.expiresAt, now())));
  if (active.length >= 3) throw new DeviceContractError("rate_limited", "Too many active pairing challenges.");
  return (await db.insert(lustrePairingChallenges).values({ accountID, codeHash, expiresAt: expiry }).returning())[0];
}

export async function beginEnrollment(input: EnrollmentInput) {
  const pairing = (await db.select().from(lustrePairingChallenges).where(eq(lustrePairingChallenges.codeHash, input.pairingCodeHash)).limit(1))[0];
  if (!pairing || pairing.consumedAt || pairing.expiresAt <= now()) throw new DeviceContractError("invalid_pairing_code", "The pairing code is invalid or expired.");
  const expiry = new Date(Date.now() + 60_000);
  return (await db.insert(lustreDeviceEnrollments).values({ pairingChallengeID: pairing.id, publicKey: input.publicKey, keyThumbprint: input.keyThumbprint, displayName: input.displayName, platform: input.platform, agentVersion: input.agentVersion, nonce: randomNonce(), expiresAt: expiry }).returning())[0];
}

export async function enrollmentForCompletion(id: string) {
  const enrollment = (await db.select().from(lustreDeviceEnrollments).where(eq(lustreDeviceEnrollments.id, id)).limit(1))[0];
  if (!enrollment || enrollment.consumedAt || enrollment.expiresAt <= now()) throw new DeviceContractError("challenge_consumed", "The enrollment challenge is unavailable.");
  return enrollment;
}

export async function deviceForThumbprint(keyThumbprint: string) {
  return (await db.select({ revokedAt: lustreDevices.revokedAt }).from(lustreDevices).where(eq(lustreDevices.keyThumbprint, keyThumbprint)).limit(1))[0];
}

export async function completeEnrollment(id: string) {
  const deviceID = randomUUID();
  const eventID = randomUUID();
  const result = await db.execute(sql`
    WITH enrollment AS (
      UPDATE lustre_device_enrollments SET consumed_at = now()
      WHERE id = ${id}::uuid AND consumed_at IS NULL AND expires_at > now()
      RETURNING pairing_challenge_id, public_key, key_thumbprint, display_name, platform, agent_version
    ), pairing AS (
      UPDATE lustre_pairing_challenges SET consumed_at = now()
      WHERE id = (SELECT pairing_challenge_id FROM enrollment) AND consumed_at IS NULL AND expires_at > now()
      RETURNING account_id
    ), device AS (
      INSERT INTO lustre_devices (id, account_id, public_key, key_thumbprint, display_name, platform, agent_version)
      SELECT ${deviceID}::uuid, pairing.account_id, enrollment.public_key, enrollment.key_thumbprint, enrollment.display_name, enrollment.platform, enrollment.agent_version FROM enrollment, pairing
      RETURNING id, account_id, created_at
    ), audit AS (
      INSERT INTO lustre_device_audit_events (id, account_id, device_id, kind, metadata)
      SELECT ${eventID}::uuid, account_id, id, 'enrolled', '{}'::jsonb FROM device
    ) SELECT id, account_id, created_at FROM device
  `);
  const row = (result as unknown as { rows: Array<{ id: string; account_id: string; created_at: string | Date }> }).rows[0];
  if (!row) throw new DeviceContractError("challenge_consumed", "The enrollment challenge was already consumed.");
  return { id: row.id, accountID: row.account_id, createdAt: new Date(row.created_at) };
}

export async function listDevices(accountID: string) { return db.select({ id: lustreDevices.id, displayName: lustreDevices.displayName, platform: lustreDevices.platform, agentVersion: lustreDevices.agentVersion, createdAt: lustreDevices.createdAt, lastAuthenticatedAt: lustreDevices.lastAuthenticatedAt, revokedAt: lustreDevices.revokedAt }).from(lustreDevices).where(eq(lustreDevices.accountID, accountID)).orderBy(desc(lustreDevices.createdAt)); }
export async function renameDevice(accountID: string, id: string, displayName: string) {
  const rows = await db.update(lustreDevices).set({ displayName }).where(and(eq(lustreDevices.id, id), eq(lustreDevices.accountID, accountID))).returning();
  const device = rows[0]; if (!device) throw new DeviceContractError("device_not_found", "Device not found.");
  await db.insert(lustreDeviceAuditEvents).values({ accountID, deviceID: id, kind: "renamed", metadata: { displayName } }); return device;
}
export async function revokeDevice(accountID: string, id: string) {
  const rows = await db.update(lustreDevices).set({ revokedAt: now() }).where(and(eq(lustreDevices.id, id), eq(lustreDevices.accountID, accountID), isNull(lustreDevices.revokedAt))).returning();
  if (!rows[0]) { const existing = await db.select({ id: lustreDevices.id }).from(lustreDevices).where(and(eq(lustreDevices.id, id), eq(lustreDevices.accountID, accountID))).limit(1); if (!existing[0]) throw new DeviceContractError("device_not_found", "Device not found."); return; }
  await db.update(lustreDeviceSessionChallenges).set({ consumedAt: now() }).where(and(eq(lustreDeviceSessionChallenges.deviceID, id), isNull(lustreDeviceSessionChallenges.consumedAt)));
  await db.insert(lustreDeviceAuditEvents).values({ accountID, deviceID: id, kind: "revoked", metadata: {} });
}
export async function createSessionChallenge(deviceID: string) {
  const device = (await db.select().from(lustreDevices).where(eq(lustreDevices.id, deviceID)).limit(1))[0];
  if (!device) throw new DeviceContractError("device_not_found", "Device not found.");
  if (device.revokedAt) throw new DeviceContractError("device_revoked", "This device has been revoked.");
  return { device, challenge: (await db.insert(lustreDeviceSessionChallenges).values({ deviceID, nonce: randomNonce(), expiresAt: new Date(Date.now() + 60_000) }).returning())[0] };
}
export async function sessionForCompletion(deviceID: string, challengeID: string) {
  const challenge = (await db.select().from(lustreDeviceSessionChallenges).where(and(eq(lustreDeviceSessionChallenges.id, challengeID), eq(lustreDeviceSessionChallenges.deviceID, deviceID))).limit(1))[0];
  const device = (await db.select().from(lustreDevices).where(eq(lustreDevices.id, deviceID)).limit(1))[0];
  if (!challenge || challenge.consumedAt || challenge.expiresAt <= now()) throw new DeviceContractError("challenge_consumed", "The session challenge is unavailable.");
  if (!device) throw new DeviceContractError("device_not_found", "Device not found.");
  if (device.revokedAt) throw new DeviceContractError("device_revoked", "This device has been revoked.");
  return { challenge, device };
}
export async function consumeSessionChallenge(deviceID: string, challengeID: string) {
  const rows = await db.update(lustreDeviceSessionChallenges).set({ consumedAt: now() }).where(and(eq(lustreDeviceSessionChallenges.id, challengeID), eq(lustreDeviceSessionChallenges.deviceID, deviceID), isNull(lustreDeviceSessionChallenges.consumedAt), gt(lustreDeviceSessionChallenges.expiresAt, now()))).returning();
  if (!rows[0]) throw new DeviceContractError("challenge_consumed", "The session challenge was already consumed.");
  const devices = await db.update(lustreDevices).set({ lastAuthenticatedAt: now() }).where(and(eq(lustreDevices.id, deviceID), isNull(lustreDevices.revokedAt))).returning();
  if (!devices[0]) throw new DeviceContractError("device_revoked", "This device has been revoked."); return devices[0];
}
export async function establishPresence(deviceID: string, connectionID: string, agentVersion: string) {
  const result = await db.execute(sql`
    INSERT INTO lustre_device_presence (device_id, connection_id, connected_at, last_heartbeat_at, agent_version, heartbeat_sequence, updated_at)
    SELECT ${deviceID}::uuid, ${connectionID}::uuid, now(), NULL, ${agentVersion}, 0, now()
    FROM lustre_devices WHERE id = ${deviceID}::uuid AND revoked_at IS NULL
    ON CONFLICT (device_id) DO UPDATE SET connection_id = EXCLUDED.connection_id, connected_at = now(), last_heartbeat_at = NULL, agent_version = EXCLUDED.agent_version, heartbeat_sequence = 0, updated_at = now()
    RETURNING device_id
  `);
  if (!(result as unknown as { rows: unknown[] }).rows[0]) throw new DeviceContractError("device_revoked", "This device has been revoked.");
}
export async function acceptHeartbeat(deviceID: string, connectionID: string, sequence: number, agentVersion: string) {
  const result = await db.execute(sql`
    UPDATE lustre_device_presence AS presence SET last_heartbeat_at = now(), updated_at = now(), heartbeat_sequence = ${sequence}, agent_version = ${agentVersion}
    FROM lustre_devices AS device
    WHERE presence.device_id = ${deviceID}::uuid AND presence.connection_id = ${connectionID}::uuid AND presence.heartbeat_sequence < ${sequence} AND device.id = presence.device_id AND device.revoked_at IS NULL
    RETURNING presence.last_heartbeat_at
  `);
  if (!(result as unknown as { rows: unknown[] }).rows[0]) throw new DeviceContractError("device_revoked", "Heartbeat rejected.");
}
export async function presenceForOwnedDevice(accountID: string, deviceID: string) {
  const row = (await db.select({ revokedAt: lustreDevices.revokedAt, lastHeartbeatAt: lustreDevicePresence.lastHeartbeatAt, agentVersion: lustreDevicePresence.agentVersion }).from(lustreDevices).leftJoin(lustreDevicePresence, eq(lustreDevicePresence.deviceID, lustreDevices.id)).where(and(eq(lustreDevices.accountID, accountID), eq(lustreDevices.id, deviceID))).limit(1))[0];
  if (!row) throw new DeviceContractError("device_not_found", "Device not found.");
  return row;
}
export async function queueURLCommand(accountID: string, deviceID: string, url: string, preferredQualityLabel?: string) {
  return createCommand(accountID, deviceID, "queue_url", { url, preferredQualityLabel });
}
export async function jobActionCommand(accountID: string, deviceID: string, jobID: string, action: "pause" | "resume" | "cancel" | "retry") {
  return createCommand(accountID, deviceID, "job_action", { jobID, action });
}
async function createCommand(accountID: string, deviceID: string, kind: string, payload: Record<string, string | undefined>) {
  const device = (await db.select({ id: lustreDevices.id }).from(lustreDevices).where(and(eq(lustreDevices.id, deviceID), eq(lustreDevices.accountID, accountID), isNull(lustreDevices.revokedAt))).limit(1))[0];
  if (!device) throw new DeviceContractError("device_not_found", "Device not found.");
  return (await db.insert(lustreDeviceCommands).values({ accountID, deviceID, kind, payload }).returning())[0];
}
export async function feedCommand(accountID: string, deviceID: string, kind: "feed_sites" | "feed_page" | "webdav_add", payload: Record<string, string | undefined>) { return createCommand(accountID, deviceID, kind, payload); }
export async function nextPendingCommand(deviceID: string) { return (await db.select().from(lustreDeviceCommands).where(and(eq(lustreDeviceCommands.deviceID, deviceID), eq(lustreDeviceCommands.status, "pending"))).orderBy(lustreDeviceCommands.createdAt).limit(1))[0] ?? null; }
export async function acknowledgeCommands(deviceID: string, acknowledgements: Array<{ id: string; status: "completed" | "failed"; jobID?: string; result?: Record<string, unknown> }>) {
  for (const acknowledgement of acknowledgements) await db.update(lustreDeviceCommands).set({ status: acknowledgement.status, result: acknowledgement.result ?? (acknowledgement.jobID ? { jobID: acknowledgement.jobID } : {}), acknowledgedAt: now() }).where(and(eq(lustreDeviceCommands.id, acknowledgement.id), eq(lustreDeviceCommands.deviceID, deviceID), eq(lustreDeviceCommands.status, "pending")));
}
export async function commandForOwnedDevice(accountID: string, deviceID: string, commandID: string) { const row = (await db.select().from(lustreDeviceCommands).where(and(eq(lustreDeviceCommands.accountID, accountID), eq(lustreDeviceCommands.deviceID, deviceID), eq(lustreDeviceCommands.id, commandID))).limit(1))[0]; if (!row) throw new DeviceContractError("device_not_found", "Command not found."); return row; }
export async function syncJobStatus(deviceID: string, jobs: Array<{ id: string; displayName?: string; preferredQualityLabel?: string; status: string; progress?: number; downloadedBytes?: number; totalBytes?: number; phase?: string; attempts: number }>) {
  for (const job of jobs) await db.insert(lustreDeviceJobStatus).values({ deviceID, jobID: job.id, displayName: job.displayName ?? "Download", preferredQualityLabel: job.preferredQualityLabel ?? null, status: job.status, progress: job.progress === undefined ? null : Math.round(job.progress * 10_000), downloadedBytes: job.downloadedBytes ?? null, totalBytes: job.totalBytes ?? null, phase: job.phase ?? null, attempts: job.attempts, updatedAt: now() }).onConflictDoUpdate({ target: [lustreDeviceJobStatus.deviceID, lustreDeviceJobStatus.jobID], set: { displayName: job.displayName ?? "Download", preferredQualityLabel: job.preferredQualityLabel ?? null, status: job.status, progress: job.progress === undefined ? null : Math.round(job.progress * 10_000), downloadedBytes: job.downloadedBytes ?? null, totalBytes: job.totalBytes ?? null, phase: job.phase ?? null, attempts: job.attempts, updatedAt: now() } });
}
export async function jobStatusForOwnedDevice(accountID: string, deviceID: string) {
  const device = (await db.select({ id: lustreDevices.id }).from(lustreDevices).where(and(eq(lustreDevices.id, deviceID), eq(lustreDevices.accountID, accountID))).limit(1))[0]; if (!device) throw new DeviceContractError("device_not_found", "Device not found.");
  return db.select().from(lustreDeviceJobStatus).where(eq(lustreDeviceJobStatus.deviceID, deviceID)).orderBy(desc(lustreDeviceJobStatus.updatedAt));
}
