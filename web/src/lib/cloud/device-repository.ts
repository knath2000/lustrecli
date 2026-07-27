import "server-only";
import { and, desc, eq, gt, gte, isNotNull, isNull, sql } from "drizzle-orm";
import { randomUUID } from "node:crypto";
import { db } from "@/lib/db/client";
import { lustreDeviceAuditEvents, lustreDeviceCommands, lustreDeviceEnrollments, lustreDeviceJobStatus, lustreDevicePresence, lustreDevices, lustreDeviceSessionChallenges, lustrePairingChallenges } from "@/lib/db/schema";
import { DeviceContractError, type HeartbeatFrame } from "./device-contract";
import { randomNonce } from "./device-crypto";
import { cloudFeedCacheFreshness } from "../cloud-feed-ui";

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
export async function persistGatewayHeartbeat(input: { deviceID: string; connectionID: string; connectedAt: Date; frame: HeartbeatFrame }) {
  const acknowledgements = JSON.stringify(input.frame.commandAcks);
  const jobs = JSON.stringify(input.frame.jobs);
  const result = await db.execute(sql`
    WITH eligible_device AS (
      SELECT device.id
      FROM lustre_devices AS device
      INNER JOIN lustre_accounts AS account ON account.id = device.account_id
      WHERE device.id = ${input.deviceID}::uuid
        AND device.revoked_at IS NULL
        AND account.disabled_at IS NULL
    ), accepted_presence AS (
      INSERT INTO lustre_device_presence (
        device_id, connection_id, connected_at, last_heartbeat_at,
        agent_version, heartbeat_sequence, updated_at
      )
      SELECT id, ${input.connectionID}::uuid, ${input.connectedAt}, now(),
        ${input.frame.agentVersion}, ${input.frame.sequence}, now()
      FROM eligible_device
      ON CONFLICT (device_id) DO UPDATE SET
        connection_id = EXCLUDED.connection_id,
        connected_at = EXCLUDED.connected_at,
        last_heartbeat_at = EXCLUDED.last_heartbeat_at,
        agent_version = EXCLUDED.agent_version,
        heartbeat_sequence = EXCLUDED.heartbeat_sequence,
        updated_at = EXCLUDED.updated_at
      WHERE (
        lustre_device_presence.connection_id = EXCLUDED.connection_id
        AND lustre_device_presence.heartbeat_sequence < EXCLUDED.heartbeat_sequence
      ) OR (
        lustre_device_presence.connection_id <> EXCLUDED.connection_id
        AND lustre_device_presence.connected_at < EXCLUDED.connected_at
      )
      RETURNING device_id
    ), acknowledgement_input AS (
      SELECT *
      FROM jsonb_to_recordset(${acknowledgements}::jsonb)
        AS acknowledgement(id uuid, status text, "jobID" uuid, result jsonb, code text)
    ), persisted_acknowledgements AS (
      UPDATE lustre_device_commands AS command SET
        status = acknowledgement.status,
        result = CASE
          WHEN acknowledgement.status = 'failed' THEN jsonb_build_object(
            'code',
            CASE WHEN acknowledgement.code IN (
              'provider_verification_required', 'provider_http_error',
              'provider_unreachable', 'provider_changed',
              'authentication_required', 'browser_extension_required',
              'result_too_large', 'invalid_request'
            ) THEN acknowledgement.code ELSE 'unknown' END
          )
          ELSE COALESCE(
            acknowledgement.result,
            CASE WHEN acknowledgement."jobID" IS NULL THEN '{}'::jsonb ELSE jsonb_build_object('jobID', acknowledgement."jobID") END
          )
        END,
        acknowledged_at = now()
      FROM acknowledgement_input AS acknowledgement, accepted_presence
      WHERE command.id = acknowledgement.id
        AND command.device_id = accepted_presence.device_id
        AND command.status IN ('pending', 'running')
      RETURNING command.id
    ), confirmed_acknowledgements AS (
      SELECT id FROM persisted_acknowledgements
      UNION
      SELECT command.id
      FROM lustre_device_commands AS command
      INNER JOIN acknowledgement_input AS acknowledgement
        ON acknowledgement.id = command.id
        AND acknowledgement.status = command.status
      INNER JOIN accepted_presence ON accepted_presence.device_id = command.device_id
    ), job_input AS (
      SELECT *
      FROM jsonb_to_recordset(${jobs}::jsonb)
        AS job(
          id uuid, "sourcePageURL" text, "displayName" text,
          "preferredQualityLabel" text, status text, progress double precision,
          "downloadedBytes" bigint, "totalBytes" bigint, phase text,
          attempts integer, "updatedAt" timestamptz
        )
    ), persisted_jobs AS (
      INSERT INTO lustre_device_job_status (
        device_id, job_id, source_page_url, display_name,
        preferred_quality_label, status, progress, downloaded_bytes,
        total_bytes, phase, attempts, updated_at
      )
      SELECT accepted_presence.device_id, job.id, job."sourcePageURL",
        COALESCE(job."displayName", 'Download'), job."preferredQualityLabel",
        job.status,
        CASE WHEN job.progress IS NULL THEN NULL ELSE round(job.progress * 10000)::integer END,
        job."downloadedBytes", job."totalBytes", job.phase, job.attempts,
        COALESCE(job."updatedAt", now())
      FROM job_input AS job, accepted_presence
      ON CONFLICT (device_id, job_id) DO UPDATE SET
        source_page_url = EXCLUDED.source_page_url,
        display_name = EXCLUDED.display_name,
        preferred_quality_label = EXCLUDED.preferred_quality_label,
        status = EXCLUDED.status,
        progress = EXCLUDED.progress,
        downloaded_bytes = EXCLUDED.downloaded_bytes,
        total_bytes = EXCLUDED.total_bytes,
        phase = EXCLUDED.phase,
        attempts = EXCLUDED.attempts,
        updated_at = EXCLUDED.updated_at
      WHERE lustre_device_job_status.updated_at < EXCLUDED.updated_at
      RETURNING job_id
    )
    SELECT accepted_presence.device_id,
      COALESCE(
        (SELECT array_agg(id::text ORDER BY id::text) FROM confirmed_acknowledgements),
        ARRAY[]::text[]
      ) AS acknowledged_command_ack_ids
    FROM accepted_presence
  `);
  const row = (result as unknown as { rows: Array<{ acknowledged_command_ack_ids: string[] }> }).rows[0];
  if (!row) throw new DeviceContractError("device_revoked", "Heartbeat rejected.");
  return row.acknowledged_command_ack_ids;
}
export async function presenceForOwnedDevice(accountID: string, deviceID: string) {
  const row = (await db.select({ revokedAt: lustreDevices.revokedAt, lastHeartbeatAt: lustreDevicePresence.lastHeartbeatAt, agentVersion: lustreDevicePresence.agentVersion }).from(lustreDevices).leftJoin(lustreDevicePresence, eq(lustreDevicePresence.deviceID, lustreDevices.id)).where(and(eq(lustreDevices.accountID, accountID), eq(lustreDevices.id, deviceID))).limit(1))[0];
  if (!row) throw new DeviceContractError("device_not_found", "Device not found.");
  return row;
}
export async function queueURLCommand(accountID: string, deviceID: string, url: string, preferredQualityLabel?: string, destination?: string) {
  return createCommand(accountID, deviceID, "queue_url", { url, preferredQualityLabel, destination });
}
export async function feedQueueCommand(input: { accountID: string; deviceID: string; requestID: string; itemID: string; siteID: string; sourcePageURL: string; destination: string }) {
  const existing = (await db.select().from(lustreDeviceCommands).where(eq(lustreDeviceCommands.id, input.requestID)).limit(1))[0];
  const payload = { itemID: input.itemID, siteID: input.siteID, url: input.sourcePageURL, destination: input.destination, deliveryProtocol: "gateway-v1" };
  if (existing) {
    const existingPayload = existing.payload as Record<string, unknown>;
    if (existing.accountID !== input.accountID || existing.deviceID !== input.deviceID || existing.kind !== "queue_url" || Object.keys(existingPayload).sort().join(",") !== "deliveryProtocol,destination,itemID,siteID,url" || existingPayload.itemID !== input.itemID || existingPayload.siteID !== input.siteID || existingPayload.url !== input.sourcePageURL || existingPayload.destination !== input.destination || existingPayload.deliveryProtocol !== "gateway-v1") {
      throw new DeviceContractError("conflict", "This request ID was already used with different inputs.");
    }
    return existing;
  }
  const destinationID = input.destination.startsWith("webdav:") ? input.destination.slice(7) : null;
  const result = await db.execute(sql`
    WITH eligible_device AS (
      SELECT id FROM lustre_devices
      WHERE id = ${input.deviceID}::uuid
        AND account_id = ${input.accountID}::uuid
        AND revoked_at IS NULL
    ), feed_provenance AS (
      SELECT command.id
      FROM lustre_device_commands AS command, eligible_device
      WHERE command.account_id = ${input.accountID}::uuid
        AND command.device_id = eligible_device.id
        AND command.kind = 'feed_page'
        AND command.status = 'completed'
        AND command.acknowledged_at >= now() - interval '1 hour'
        AND EXISTS (
          SELECT 1
          FROM jsonb_array_elements(command.result -> 'page' -> 'items') AS item
          WHERE item ->> 'id' = ${input.itemID}
            AND item ->> 'siteID' = ${input.siteID}
            AND item ->> 'sourcePageURL' = ${input.sourcePageURL}
            AND item ->> 'queueCapability' = 'supported'
        )
      ORDER BY command.acknowledged_at DESC
      LIMIT 1
    ), newest_destination AS (
      SELECT command.result
      FROM lustre_device_commands AS command, eligible_device
      WHERE command.account_id = ${input.accountID}::uuid
        AND command.device_id = eligible_device.id
        AND command.kind = 'destinations_list'
        AND command.status = 'completed'
        AND command.acknowledged_at >= now() - interval '15 minutes'
      ORDER BY command.acknowledged_at DESC
      LIMIT 1
    ), destination_provenance AS (
      SELECT true AS allowed
      WHERE ${input.destination} = 'local'
      UNION ALL
      SELECT true
      FROM newest_destination
      WHERE ${destinationID}::text IS NOT NULL
        AND EXISTS (
          SELECT 1
          FROM jsonb_array_elements(newest_destination.result -> 'destinations') AS destination
          WHERE destination ->> 'id' = ${destinationID}
        )
      ORDER BY allowed
      LIMIT 1
    )
    INSERT INTO lustre_device_commands (id, account_id, device_id, kind, payload)
    SELECT ${input.requestID}::uuid, ${input.accountID}::uuid, ${input.deviceID}::uuid, 'queue_url', ${JSON.stringify(payload)}::jsonb
    FROM eligible_device, feed_provenance, destination_provenance
    RETURNING *
  `);
  const row = (result as unknown as { rows: typeof lustreDeviceCommands.$inferSelect[] }).rows[0];
  if (!row) throw new DeviceContractError("invalid_request", "Fresh Feed and destination provenance are required.");
  return row;
}
export async function jobActionCommand(accountID: string, deviceID: string, jobID: string, action: "pause" | "resume" | "cancel" | "retry") {
  return createCommand(accountID, deviceID, "job_action", { jobID, action });
}
async function createCommand(accountID: string, deviceID: string, kind: string, payload: Record<string, string | undefined>) {
  const device = (await db.select({ id: lustreDevices.id }).from(lustreDevices).where(and(eq(lustreDevices.id, deviceID), eq(lustreDevices.accountID, accountID), isNull(lustreDevices.revokedAt))).limit(1))[0];
  if (!device) throw new DeviceContractError("device_not_found", "Device not found.");
  return (await db.insert(lustreDeviceCommands).values({ accountID, deviceID, kind, payload }).returning())[0];
}
export async function feedCommand(accountID: string, deviceID: string, kind: "feed_sites" | "feed_page" | "webdav_add" | "destinations_list", payload: Record<string, string | undefined>) {
  if (kind === "feed_sites" || kind === "feed_page" || kind === "destinations_list") {
    const pending = (await db.select().from(lustreDeviceCommands).where(and(
      eq(lustreDeviceCommands.accountID, accountID),
      eq(lustreDeviceCommands.deviceID, deviceID),
      eq(lustreDeviceCommands.kind, kind),
      sql`${lustreDeviceCommands.status} in ('pending', 'running')`,
      sql`${lustreDeviceCommands.payload} ->> 'deliveryProtocol' = 'gateway-v1'`,
      kind === "feed_page"
        ? sql`${lustreDeviceCommands.payload} ->> 'siteID' = ${payload.siteID}
            AND ${lustreDeviceCommands.payload} ->> 'page' = ${payload.page}
            AND COALESCE(${lustreDeviceCommands.payload} ->> 'query', '') = ${payload.query ?? ""}`
        : sql`true`,
    )).orderBy(lustreDeviceCommands.createdAt).limit(1))[0];
    if (pending) return pending;
  }
  return createCommand(accountID, deviceID, kind, kind === "feed_sites" || kind === "feed_page" || kind === "destinations_list" ? { ...payload, deliveryProtocol: "gateway-v1" } : payload);
}

export async function cachedFeedResult(accountID: string, deviceID: string, kind: "feed_sites" | "feed_page", payload: Record<string, string | undefined>) {
  const rows = await db.select({
    result: lustreDeviceCommands.result,
    acknowledgedAt: lustreDeviceCommands.acknowledgedAt,
  }).from(lustreDeviceCommands).where(and(
    eq(lustreDeviceCommands.accountID, accountID),
    eq(lustreDeviceCommands.deviceID, deviceID),
    eq(lustreDeviceCommands.kind, kind),
    eq(lustreDeviceCommands.status, "completed"),
    isNotNull(lustreDeviceCommands.result),
    isNotNull(lustreDeviceCommands.acknowledgedAt),
    gte(lustreDeviceCommands.acknowledgedAt, new Date(Date.now() - 60 * 60_000)),
    kind === "feed_page"
      ? sql`${lustreDeviceCommands.payload} ->> 'siteID' = ${payload.siteID}
          AND ${lustreDeviceCommands.payload} ->> 'page' = ${payload.page}
          AND COALESCE(${lustreDeviceCommands.payload} ->> 'query', '') = ${payload.query ?? ""}`
      : sql`true`,
  )).orderBy(desc(lustreDeviceCommands.acknowledgedAt)).limit(1);
  const cached = rows[0];
  if (!cached?.acknowledgedAt || !cached.result) return null;
  const freshness = cloudFeedCacheFreshness(cached.acknowledgedAt);
  if (!freshness) return null;
  return {
    result: cached.result,
    acknowledgedAt: cached.acknowledgedAt,
    freshness,
  };
}
export async function nextGatewayCommand(input: { deviceID: string; connectionID: string; sequence: number; allowFeedPage: boolean; allowDestinationsList: boolean; allowFeedQueue: boolean }) {
  const result = await db.execute(sql`
    WITH current_presence AS (
      SELECT device_id
      FROM lustre_device_presence
      WHERE device_id = ${input.deviceID}::uuid
        AND connection_id = ${input.connectionID}::uuid
        AND heartbeat_sequence = ${input.sequence}
    ), candidate AS (
      SELECT command.id
      FROM lustre_device_commands AS command
      INNER JOIN current_presence ON current_presence.device_id = command.device_id
      WHERE (
          command.kind = 'feed_sites'
          OR (${input.allowFeedPage} AND command.kind = 'feed_page')
          OR (${input.allowDestinationsList} AND command.kind = 'destinations_list')
          OR (${input.allowFeedQueue} AND command.kind = 'queue_url')
        )
        AND command.status IN ('pending', 'running')
        AND command.payload ->> 'deliveryProtocol' = 'gateway-v1'
      ORDER BY command.created_at
      LIMIT 1
      FOR UPDATE OF command SKIP LOCKED
    )
    UPDATE lustre_device_commands AS command
    SET status = 'running'
    FROM candidate
    WHERE command.id = candidate.id
    RETURNING command.id, command.kind, command.payload
  `);
  const row = (result as unknown as { rows: Array<{ id: string; kind: "feed_sites" | "feed_page" | "destinations_list" | "queue_url"; payload: Record<string, string> }> }).rows[0];
  if (!row) return null;
  if (row.kind === "feed_sites") return { id: row.id, kind: "feed_sites" as const, payload: {} };
  if (row.kind === "destinations_list") return { id: row.id, kind: "destinations_list" as const, payload: {} };
  if (row.kind === "queue_url") return { id: row.id, kind: "queue_url" as const, payload: { url: row.payload.url, destination: row.payload.destination, deliveryProtocol: "gateway-v1" as const } };
  return { id: row.id, kind: "feed_page" as const, payload: { siteID: row.payload.siteID, page: Number(row.payload.page), ...(row.payload.query ? { query: row.payload.query } : {}) } };
}
export async function nextPendingCommand(deviceID: string) {
  return (await db.select().from(lustreDeviceCommands).where(and(eq(lustreDeviceCommands.deviceID, deviceID), sql`${lustreDeviceCommands.status} in ('pending', 'running')`)).orderBy(lustreDeviceCommands.createdAt).limit(1))[0] ?? null;
}
export async function acknowledgeCommands(deviceID: string, acknowledgements: Array<{ id: string; status: "completed" | "failed"; jobID?: string; result?: Record<string, unknown> }>) {
  for (const acknowledgement of acknowledgements) await db.update(lustreDeviceCommands).set({ status: acknowledgement.status, result: acknowledgement.result ?? (acknowledgement.jobID ? { jobID: acknowledgement.jobID } : {}), acknowledgedAt: now() }).where(and(eq(lustreDeviceCommands.id, acknowledgement.id), eq(lustreDeviceCommands.deviceID, deviceID), sql`${lustreDeviceCommands.status} in ('pending', 'running')`));
}
export async function commandForOwnedDevice(accountID: string, deviceID: string, commandID: string) { const row = (await db.select().from(lustreDeviceCommands).where(and(eq(lustreDeviceCommands.accountID, accountID), eq(lustreDeviceCommands.deviceID, deviceID), eq(lustreDeviceCommands.id, commandID))).limit(1))[0]; if (!row) throw new DeviceContractError("device_not_found", "Command not found."); return row; }
export async function recentCompletedFeedPageResults(accountID: string, deviceID: string, since: Date) {
  const device = (await db.select({ id: lustreDevices.id }).from(lustreDevices).where(and(eq(lustreDevices.id, deviceID), eq(lustreDevices.accountID, accountID), isNull(lustreDevices.revokedAt))).limit(1))[0];
  if (!device) throw new DeviceContractError("device_not_found", "Device not found.");
  return db.select({ result: lustreDeviceCommands.result }).from(lustreDeviceCommands).where(and(
    eq(lustreDeviceCommands.accountID, accountID),
    eq(lustreDeviceCommands.deviceID, deviceID),
    eq(lustreDeviceCommands.kind, "feed_page"),
    eq(lustreDeviceCommands.status, "completed"),
    isNotNull(lustreDeviceCommands.result),
    isNotNull(lustreDeviceCommands.acknowledgedAt),
    gte(lustreDeviceCommands.acknowledgedAt, since),
  )).orderBy(desc(lustreDeviceCommands.acknowledgedAt));
}
export async function syncJobStatus(deviceID: string, jobs: Array<{ id: string; sourcePageURL?: string; displayName?: string; preferredQualityLabel?: string; status: string; progress?: number; downloadedBytes?: number; totalBytes?: number; phase?: string; attempts: number; updatedAt?: string }>) {
  for (const job of jobs) {
    const updatedAt = job.updatedAt ? new Date(job.updatedAt) : now();
    await db.insert(lustreDeviceJobStatus).values({ deviceID, jobID: job.id, sourcePageURL: job.sourcePageURL ?? null, displayName: job.displayName ?? "Download", preferredQualityLabel: job.preferredQualityLabel ?? null, status: job.status, progress: job.progress === undefined ? null : Math.round(job.progress * 10_000), downloadedBytes: job.downloadedBytes ?? null, totalBytes: job.totalBytes ?? null, phase: job.phase ?? null, attempts: job.attempts, updatedAt }).onConflictDoUpdate({ target: [lustreDeviceJobStatus.deviceID, lustreDeviceJobStatus.jobID], set: { sourcePageURL: job.sourcePageURL ?? null, displayName: job.displayName ?? "Download", preferredQualityLabel: job.preferredQualityLabel ?? null, status: job.status, progress: job.progress === undefined ? null : Math.round(job.progress * 10_000), downloadedBytes: job.downloadedBytes ?? null, totalBytes: job.totalBytes ?? null, phase: job.phase ?? null, attempts: job.attempts, updatedAt } });
  }
}
export async function jobStatusForOwnedDevice(accountID: string, deviceID: string) {
  const device = (await db.select({ id: lustreDevices.id }).from(lustreDevices).where(and(eq(lustreDevices.id, deviceID), eq(lustreDevices.accountID, accountID))).limit(1))[0]; if (!device) throw new DeviceContractError("device_not_found", "Device not found.");
  return db.select().from(lustreDeviceJobStatus).where(eq(lustreDeviceJobStatus.deviceID, deviceID)).orderBy(desc(lustreDeviceJobStatus.updatedAt));
}
