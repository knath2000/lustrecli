import "server-only";
import { and, desc, eq, gt, gte, isNotNull, isNull, sql } from "drizzle-orm";
import { randomUUID } from "node:crypto";
import { db } from "@/lib/db/client";
import { lustreDeviceAuditEvents, lustreDeviceCommands, lustreDeviceEnrollments, lustreDeviceJobStatus, lustreDeviceLibrarySnapshots, lustreDevicePresence, lustreDevices, lustreDeviceSessionChallenges, lustrePairingChallenges, lustreWatchlistItems } from "@/lib/db/schema";
import { DeviceContractError, PRESENCE_FRESHNESS_SECONDS, validLibraryResult, type HeartbeatFrame } from "./device-contract";
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
              'result_too_large', 'invalid_request', 'signed_out', 'signing_in',
              'cancelled', 'expired', 'auth_helper_unavailable',
              'auth_helper_failed', 'auth_timeout', 'invalid_session',
              'auth_storage_unavailable'
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
      WHERE lustre_device_job_status.updated_at <= EXCLUDED.updated_at
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
export async function queueURLCommand(accountID: string, deviceID: string, url: string, title?: string, preferredQualityLabel?: string, destination?: string, requestID?: string) {
  const payload = { url, title, preferredQualityLabel, destination: destination ?? "local", deliveryProtocol: "gateway-v1" };
  if (requestID) {
    const existing = (await db.select().from(lustreDeviceCommands).where(eq(lustreDeviceCommands.id, requestID)).limit(1))[0];
    if (existing) {
      const existingPayload = existing.payload as Record<string, unknown>;
      if (
        existing.accountID !== accountID ||
        existing.deviceID !== deviceID ||
        existing.kind !== "queue_url" ||
        existingPayload.url !== url ||
        existingPayload.title !== title ||
        existingPayload.preferredQualityLabel !== preferredQualityLabel ||
        existingPayload.destination !== payload.destination ||
        existingPayload.deliveryProtocol !== "gateway-v1"
      ) throw new DeviceContractError("conflict", "This request ID was already used with different inputs.");
      return existing;
    }
  }
  return createCommand(accountID, deviceID, "queue_url", payload, requestID);
}
export async function feedQueueCommand(input: { accountID: string; deviceID: string; requestID: string; itemID: string; siteID: string; sourcePageURL: string; title: string; destination: string }) {
  const existing = (await db.select().from(lustreDeviceCommands).where(eq(lustreDeviceCommands.id, input.requestID)).limit(1))[0];
  const payload = { itemID: input.itemID, siteID: input.siteID, url: input.sourcePageURL, title: input.title, destination: input.destination, deliveryProtocol: "gateway-v1" };
  if (existing) {
    const existingPayload = existing.payload as Record<string, unknown>;
    if (existing.accountID !== input.accountID || existing.deviceID !== input.deviceID || existing.kind !== "queue_url" || Object.keys(existingPayload).sort().join(",") !== "deliveryProtocol,destination,itemID,siteID,title,url" || existingPayload.itemID !== input.itemID || existingPayload.siteID !== input.siteID || existingPayload.url !== input.sourcePageURL || existingPayload.title !== input.title || existingPayload.destination !== input.destination || existingPayload.deliveryProtocol !== "gateway-v1") {
      throw new DeviceContractError("conflict", "This request ID was already used with different inputs.");
    }
    return existing;
  }
  const destinationID = /^(webdav|gdrive):/.test(input.destination) ? input.destination.slice(input.destination.indexOf(":") + 1) : null;
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
    ), cloud_feed_provenance AS (
      SELECT cache.account_id AS id
      FROM lustre_feed_cache AS cache, eligible_device
      WHERE cache.account_id = ${input.accountID}::uuid
        AND cache.updated_at >= now() - interval '1 hour'
        AND EXISTS (
          SELECT 1
          FROM jsonb_array_elements(cache.result -> 'items') AS item
          WHERE item ->> 'id' = ${input.itemID}
            AND item ->> 'siteID' = ${input.siteID}
            AND item ->> 'sourcePageURL' = ${input.sourcePageURL}
        )
      ORDER BY cache.updated_at DESC
      LIMIT 1
    ), accepted_feed_provenance AS (
      SELECT id FROM feed_provenance
      UNION ALL
      SELECT id FROM cloud_feed_provenance
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
    FROM eligible_device, accepted_feed_provenance, destination_provenance
    RETURNING *
  `);
  const row = (result as unknown as { rows: Array<{
    id: string;
    account_id: string;
    device_id: string;
    kind: string;
    payload: Record<string, unknown>;
    status: string;
    result: Record<string, unknown> | null;
    created_at: Date | string;
    acknowledged_at: Date | string | null;
  }> }).rows[0];
  if (!row) throw new DeviceContractError("invalid_request", "Fresh Feed and destination provenance are required.");
  return {
    id: row.id,
    accountID: row.account_id,
    deviceID: row.device_id,
    kind: row.kind,
    payload: row.payload,
    status: row.status,
    result: row.result,
    createdAt: row.created_at instanceof Date ? row.created_at : new Date(row.created_at),
    acknowledgedAt: row.acknowledged_at instanceof Date ? row.acknowledged_at : row.acknowledged_at ? new Date(row.acknowledged_at) : null,
  };
}
export async function feedResolveCommand(input: { accountID: string; deviceID: string; itemID: string; siteID: string; sourcePageURL: string }) {
  const payload = { itemID: input.itemID, siteID: input.siteID, url: input.sourcePageURL, deliveryProtocol: "gateway-v1" };
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
    ), cloud_feed_provenance AS (
      SELECT cache.account_id AS id
      FROM lustre_feed_cache AS cache, eligible_device
      WHERE cache.account_id = ${input.accountID}::uuid
        AND cache.updated_at >= now() - interval '1 hour'
        AND EXISTS (
          SELECT 1
          FROM jsonb_array_elements(cache.result -> 'items') AS item
          WHERE item ->> 'id' = ${input.itemID}
            AND item ->> 'siteID' = ${input.siteID}
            AND item ->> 'sourcePageURL' = ${input.sourcePageURL}
        )
      ORDER BY cache.updated_at DESC
      LIMIT 1
    ), accepted_feed_provenance AS (
      SELECT id FROM feed_provenance
      UNION ALL
      SELECT id FROM cloud_feed_provenance
      LIMIT 1
    )
    INSERT INTO lustre_device_commands (account_id, device_id, kind, payload)
    SELECT ${input.accountID}::uuid, ${input.deviceID}::uuid, 'feed_resolve', ${JSON.stringify(payload)}::jsonb
    FROM eligible_device, accepted_feed_provenance
    RETURNING *
  `);
  const row = (result as unknown as { rows: Array<{
    id: string;
    account_id: string;
    device_id: string;
    kind: string;
    payload: Record<string, unknown>;
    status: string;
    result: Record<string, unknown> | null;
    created_at: Date | string;
    acknowledged_at: Date | string | null;
  }> }).rows[0];
  if (!row) throw new DeviceContractError("invalid_request", "Fresh Feed provenance is required.");
  return {
    id: row.id,
    accountID: row.account_id,
    deviceID: row.device_id,
    kind: row.kind,
    payload: row.payload,
    status: row.status,
    result: row.result,
    createdAt: row.created_at instanceof Date ? row.created_at : new Date(row.created_at),
    acknowledgedAt: row.acknowledged_at instanceof Date ? row.acknowledged_at : row.acknowledged_at ? new Date(row.acknowledged_at) : null,
  };
}
export async function watchlistResolveCommand(accountID: string, deviceID: string, watchlistID: string) {
  const result = await db.execute(sql`
    INSERT INTO lustre_device_commands (account_id, device_id, kind, payload)
    SELECT item.account_id, device.id, 'feed_resolve', jsonb_build_object('url', item.source_page_url, 'deliveryProtocol', 'gateway-v1')
    FROM lustre_watchlist_items AS item
    JOIN lustre_devices AS device
      ON device.id = ${deviceID}::uuid
      AND device.account_id = item.account_id
      AND device.revoked_at IS NULL
    WHERE item.id = ${watchlistID}::uuid
      AND item.account_id = ${accountID}::uuid
    RETURNING *
  `);
  const row = (result as unknown as { rows: Array<{
    id: string;
    account_id: string;
    device_id: string;
    kind: string;
    payload: Record<string, unknown>;
    status: string;
    result: Record<string, unknown> | null;
    created_at: Date | string;
    acknowledged_at: Date | string | null;
  }> }).rows[0];
  if (!row) throw new DeviceContractError("invalid_request", "Watchlist item or paired device not found.");
  return {
    id: row.id,
    accountID: row.account_id,
    deviceID: row.device_id,
    kind: row.kind,
    payload: row.payload,
    status: row.status,
    result: row.result,
    createdAt: row.created_at instanceof Date ? row.created_at : new Date(row.created_at),
    acknowledgedAt: row.acknowledged_at instanceof Date ? row.acknowledged_at : row.acknowledged_at ? new Date(row.acknowledged_at) : null,
  };
}
export async function watchlistQueueCommand(accountID: string, deviceID: string, watchlistID: string, requestID: string, destination: "local") {
  const item = (await db.select({
    sourcePageURL: lustreWatchlistItems.sourcePageURL,
    title: lustreWatchlistItems.title,
  }).from(lustreWatchlistItems).where(and(
    eq(lustreWatchlistItems.id, watchlistID),
    eq(lustreWatchlistItems.accountID, accountID),
  )).limit(1))[0];
  if (!item) throw new DeviceContractError("invalid_request", "Watchlist item not found.");
  return queueURLCommand(accountID, deviceID, item.sourcePageURL, item.title, undefined, destination, requestID);
}
export async function watchlistOwnsThumbnail(accountID: string, deviceID: string, thumbnailURL: string) {
  const row = await db.select({ id: lustreWatchlistItems.id })
    .from(lustreWatchlistItems)
    .innerJoin(lustreDevices, and(
      eq(lustreDevices.id, deviceID),
      eq(lustreDevices.accountID, lustreWatchlistItems.accountID),
      isNull(lustreDevices.revokedAt),
    ))
    .where(and(
      eq(lustreWatchlistItems.accountID, accountID),
      eq(lustreWatchlistItems.thumbnailURL, thumbnailURL),
    ))
    .limit(1);
  return !!row[0];
}
export async function jobActionCommand(accountID: string, deviceID: string, jobID: string, action: "pause" | "resume" | "cancel" | "retry") {
  return createCommand(accountID, deviceID, "job_action", { jobID, action, deliveryProtocol: "gateway-v1" });
}
export async function jobsReorderCommand(accountID: string, deviceID: string, jobIDs: string[]) {
  return createCommand(accountID, deviceID, "jobs_reorder", { jobIDs, deliveryProtocol: "gateway-v1" });
}
async function createCommand(accountID: string, deviceID: string, kind: string, payload: Record<string, unknown>, id?: string) {
  const device = (await db.select({ id: lustreDevices.id }).from(lustreDevices).where(and(eq(lustreDevices.id, deviceID), eq(lustreDevices.accountID, accountID), isNull(lustreDevices.revokedAt))).limit(1))[0];
  if (!device) throw new DeviceContractError("device_not_found", "Device not found.");
  return (await db.insert(lustreDeviceCommands).values({ ...(id ? { id } : {}), accountID, deviceID, kind, payload }).returning())[0];
}
export async function feedCommand(accountID: string, deviceID: string, kind: "feed_sites" | "feed_page" | "webdav_add" | "destinations_list" | "gdrive_connect" | "gdrive_folders" | "gdrive_create_folder" | "gdrive_select_folder" | "gdrive_test" | "local_folder_status" | "local_folder_choose" | "local_folder_reset", payload: Record<string, string | undefined>) {
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
  return createCommand(accountID, deviceID, kind, kind === "feed_sites" || kind === "feed_page" || kind === "destinations_list" || kind.startsWith("gdrive_") || kind.startsWith("local_folder_") ? { ...payload, deliveryProtocol: "gateway-v1" } : payload);
}

export async function pornHubAuthCommand(accountID: string, deviceID: string, kind: "pornhub_auth_status" | "pornhub_auth_login" | "pornhub_auth_cancel" | "pornhub_auth_logout") {
  const cutoff = new Date(Date.now() - PRESENCE_FRESHNESS_SECONDS * 1_000);
  const online = (await db.select({ deviceID: lustreDevicePresence.deviceID }).from(lustreDevicePresence).innerJoin(
    lustreDevices,
    and(
      eq(lustreDevices.id, lustreDevicePresence.deviceID),
      eq(lustreDevices.accountID, accountID),
      isNull(lustreDevices.revokedAt),
    ),
  ).where(and(
    eq(lustreDevicePresence.deviceID, deviceID),
    gte(lustreDevicePresence.lastHeartbeatAt, cutoff),
  )).limit(1))[0];
  if (!online) throw new DeviceContractError("agent_offline", "Paired Mac is offline. Mount MyPassport and start Lustre Agent, then retry.");
  if (kind === "pornhub_auth_status") {
    const pending = (await db.select().from(lustreDeviceCommands).where(and(
      eq(lustreDeviceCommands.accountID, accountID),
      eq(lustreDeviceCommands.deviceID, deviceID),
      eq(lustreDeviceCommands.kind, kind),
      sql`${lustreDeviceCommands.status} in ('pending', 'running')`,
    )).orderBy(lustreDeviceCommands.createdAt).limit(1))[0];
    if (pending) return pending;
  }
  return createCommand(accountID, deviceID, kind, { deliveryProtocol: "gateway-v1" });
}

export async function homeWorkspaceCommand(accountID: string, deviceID: string, kind: "home_status" | "extract_preview", urls?: string[]) {
  if (kind === "home_status") {
    const pending = (await db.select().from(lustreDeviceCommands).where(and(
      eq(lustreDeviceCommands.accountID, accountID),
      eq(lustreDeviceCommands.deviceID, deviceID),
      eq(lustreDeviceCommands.kind, kind),
      sql`${lustreDeviceCommands.status} in ('pending', 'running')`,
    )).orderBy(lustreDeviceCommands.createdAt).limit(1))[0];
    if (pending) return pending;
  }
  return createCommand(accountID, deviceID, kind, { ...(urls ? { urls } : {}), deliveryProtocol: "gateway-v1" });
}

export async function libraryCommand(accountID: string, deviceID: string, kind: "library_list" | "library_update" | "library_remove" | "library_verify", payload: Record<string, unknown>) {
  if (kind === "library_list") {
    const pending = (await db.select().from(lustreDeviceCommands).where(and(
      eq(lustreDeviceCommands.accountID, accountID),
      eq(lustreDeviceCommands.deviceID, deviceID),
      eq(lustreDeviceCommands.kind, kind),
      sql`${lustreDeviceCommands.status} in ('pending', 'running')`,
      sql`${lustreDeviceCommands.payload} ->> 'page' = ${String(payload.page ?? 1)}`,
    )).orderBy(lustreDeviceCommands.createdAt).limit(1))[0];
    if (pending) return pending;
  }
  return createCommand(accountID, deviceID, kind, { ...payload, deliveryProtocol: "gateway-v1" });
}

export async function cachedLibrarySnapshot(accountID: string, deviceID: string) {
  const device = (await db.select({ id: lustreDevices.id }).from(lustreDevices).where(and(eq(lustreDevices.id, deviceID), eq(lustreDevices.accountID, accountID), isNull(lustreDevices.revokedAt))).limit(1))[0];
  if (!device) throw new DeviceContractError("device_not_found", "Device not found.");
  return (await db.select().from(lustreDeviceLibrarySnapshots).where(and(eq(lustreDeviceLibrarySnapshots.accountID, accountID), eq(lustreDeviceLibrarySnapshots.deviceID, deviceID))).limit(1))[0] ?? null;
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
export async function nextGatewayCommand(input: { deviceID: string; connectionID: string; sequence: number; allowFeedPage: boolean; allowDestinationsList: boolean; allowFeedQueue: boolean; allowPornHubAuth: boolean; allowHomeWorkspace: boolean; allowLibrary: boolean }) {
  const result = await db.execute(sql`
    WITH expired_auth AS (
      UPDATE lustre_device_commands
      SET status = 'failed',
          result = jsonb_build_object('code', 'command_expired'),
          acknowledged_at = now()
      WHERE device_id = ${input.deviceID}::uuid
        AND kind IN ('pornhub_auth_status', 'pornhub_auth_login', 'pornhub_auth_cancel', 'pornhub_auth_logout')
        AND status IN ('pending', 'running')
        AND created_at < now() - interval '90 seconds'
      RETURNING id
    ), current_presence AS (
      SELECT device_id
      FROM lustre_device_presence
      WHERE device_id = ${input.deviceID}::uuid
        AND connection_id = ${input.connectionID}::uuid
        AND heartbeat_sequence = ${input.sequence}
    ), candidate AS (
      SELECT command.id
      FROM lustre_device_commands AS command
      INNER JOIN current_presence ON current_presence.device_id = command.device_id
      LEFT JOIN expired_auth ON expired_auth.id = command.id
      WHERE (
          command.kind = 'feed_sites'
          OR (${input.allowFeedPage} AND command.kind = 'feed_page')
          OR (${input.allowDestinationsList} AND command.kind IN ('destinations_list', 'gdrive_connect', 'gdrive_folders', 'gdrive_create_folder', 'gdrive_select_folder', 'gdrive_test', 'local_folder_status', 'local_folder_choose', 'local_folder_reset'))
          OR (${input.allowFeedQueue} AND command.kind = 'queue_url')
          OR (${input.allowPornHubAuth} AND command.kind IN ('pornhub_auth_status', 'pornhub_auth_login', 'pornhub_auth_cancel', 'pornhub_auth_logout'))
          OR (${input.allowHomeWorkspace} AND command.kind IN ('home_status', 'extract_preview', 'feed_resolve'))
          OR (${input.allowLibrary} AND command.kind IN ('library_list', 'library_update', 'library_remove', 'library_verify'))
          OR command.kind IN ('job_action', 'jobs_reorder')
        )
        AND command.status IN ('pending', 'running')
        AND expired_auth.id IS NULL
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
  const row = (result as unknown as { rows: Array<{ id: string; kind: "feed_sites" | "feed_page" | "destinations_list" | "gdrive_connect" | "gdrive_folders" | "gdrive_create_folder" | "gdrive_select_folder" | "gdrive_test" | "local_folder_status" | "local_folder_choose" | "local_folder_reset" | "queue_url" | "job_action" | "jobs_reorder" | "pornhub_auth_status" | "pornhub_auth_login" | "pornhub_auth_cancel" | "pornhub_auth_logout" | "home_status" | "extract_preview" | "feed_resolve" | "library_list" | "library_update" | "library_remove" | "library_verify"; payload: Record<string, unknown> }> }).rows[0];
  if (!row) return null;
  if (row.kind === "feed_sites") return { id: row.id, kind: "feed_sites" as const, payload: {} };
  if (row.kind === "destinations_list") return { id: row.id, kind: "destinations_list" as const, payload: {} };
  if (row.kind === "local_folder_status" || row.kind === "local_folder_choose" || row.kind === "local_folder_reset") return { id: row.id, kind: row.kind, payload: { deliveryProtocol: "gateway-v1" as const } };
  if (row.kind === "gdrive_connect") return { id: row.id, kind: "gdrive_connect" as const, payload: { deliveryProtocol: "gateway-v1" as const } };
  if (row.kind === "gdrive_test") return { id: row.id, kind: "gdrive_test" as const, payload: { profileID: row.payload.profileID as string, deliveryProtocol: "gateway-v1" as const } };
  if (row.kind === "gdrive_folders" || row.kind === "gdrive_create_folder" || row.kind === "gdrive_select_folder") return { id: row.id, kind: row.kind, payload: { profileID: row.payload.profileID as string, path: row.payload.path as string, deliveryProtocol: "gateway-v1" as const } };
  if (row.kind === "queue_url") return { id: row.id, kind: "queue_url" as const, payload: { url: row.payload.url as string, ...(typeof row.payload.title === "string" ? { title: row.payload.title } : {}), destination: row.payload.destination as string, ...(typeof row.payload.preferredQualityLabel === "string" ? { preferredQualityLabel: row.payload.preferredQualityLabel } : {}), deliveryProtocol: "gateway-v1" as const } };
  if (row.kind === "job_action") return { id: row.id, kind: "job_action" as const, payload: { jobID: row.payload.jobID as string, action: row.payload.action as "pause" | "resume" | "cancel" | "retry", deliveryProtocol: "gateway-v1" as const } };
  if (row.kind === "jobs_reorder") return { id: row.id, kind: "jobs_reorder" as const, payload: { jobIDs: row.payload.jobIDs as string[], deliveryProtocol: "gateway-v1" as const } };
  if (row.kind === "pornhub_auth_status" || row.kind === "pornhub_auth_login" || row.kind === "pornhub_auth_cancel" || row.kind === "pornhub_auth_logout") {
    return { id: row.id, kind: row.kind, payload: { deliveryProtocol: "gateway-v1" as const } };
  }
  if (row.kind === "home_status") return { id: row.id, kind: "home_status" as const, payload: { deliveryProtocol: "gateway-v1" as const } };
  if (row.kind === "extract_preview") return { id: row.id, kind: "extract_preview" as const, payload: { urls: row.payload.urls as unknown as string[], deliveryProtocol: "gateway-v1" as const } };
  if (row.kind === "feed_resolve") return { id: row.id, kind: "feed_resolve" as const, payload: { url: row.payload.url as string, deliveryProtocol: "gateway-v1" as const } };
  if (row.kind === "library_list") return { id: row.id, kind: "library_list" as const, payload: { page: Number(row.payload.page), deliveryProtocol: "gateway-v1" as const } };
  if (row.kind === "library_remove" || row.kind === "library_verify") return { id: row.id, kind: row.kind, payload: { itemID: row.payload.itemID as string, deliveryProtocol: "gateway-v1" as const } };
  if (row.kind === "library_update") return { id: row.id, kind: "library_update" as const, payload: { itemID: row.payload.itemID as string, tags: row.payload.tags as string[], ...(typeof row.payload.collection === "string" ? { collection: row.payload.collection } : {}), ...(typeof row.payload.favorite === "boolean" ? { favorite: row.payload.favorite } : {}), deliveryProtocol: "gateway-v1" as const } };
  return { id: row.id, kind: "feed_page" as const, payload: { siteID: row.payload.siteID as string, page: Number(row.payload.page), ...(typeof row.payload.query === "string" ? { query: row.payload.query } : {}) } };
}
export async function nextPendingCommand(deviceID: string) {
  return (await db.select().from(lustreDeviceCommands).where(and(eq(lustreDeviceCommands.deviceID, deviceID), sql`${lustreDeviceCommands.status} in ('pending', 'running')`)).orderBy(lustreDeviceCommands.createdAt).limit(1))[0] ?? null;
}
export async function acknowledgeCommands(deviceID: string, acknowledgements: Array<{ id: string; status: "completed" | "failed"; jobID?: string; result?: Record<string, unknown> }>) {
  for (const acknowledgement of acknowledgements) {
    const command = (await db.select({ accountID: lustreDeviceCommands.accountID }).from(lustreDeviceCommands).where(and(eq(lustreDeviceCommands.id, acknowledgement.id), eq(lustreDeviceCommands.deviceID, deviceID))).limit(1))[0];
    await db.update(lustreDeviceCommands).set({ status: acknowledgement.status, result: acknowledgement.result ?? (acknowledgement.jobID ? { jobID: acknowledgement.jobID } : {}), acknowledgedAt: now() }).where(and(eq(lustreDeviceCommands.id, acknowledgement.id), eq(lustreDeviceCommands.deviceID, deviceID), sql`${lustreDeviceCommands.status} in ('pending', 'running')`));
    if (command && acknowledgement.status === "completed" && acknowledgement.result && validLibraryResult(acknowledgement.result)) {
      const library = acknowledgement.result.library as { revision: number; page: number; items: unknown[] };
      if (library.page === 1) {
        await db.insert(lustreDeviceLibrarySnapshots).values({ deviceID, accountID: command.accountID, revision: library.revision, items: library.items, syncedAt: now() }).onConflictDoUpdate({
          target: lustreDeviceLibrarySnapshots.deviceID,
          set: { accountID: command.accountID, revision: library.revision, items: library.items, syncedAt: now() },
          setWhere: sql`${lustreDeviceLibrarySnapshots.revision} <= ${library.revision}`,
        });
      }
    }
  }
}
export async function commandForOwnedDevice(accountID: string, deviceID: string, commandID: string) {
  await db.update(lustreDeviceCommands).set({
    status: "failed",
    result: { code: "command_expired" },
    acknowledgedAt: now(),
  }).where(and(
    eq(lustreDeviceCommands.accountID, accountID),
    eq(lustreDeviceCommands.deviceID, deviceID),
    eq(lustreDeviceCommands.id, commandID),
    sql`${lustreDeviceCommands.kind} in ('pornhub_auth_status', 'pornhub_auth_login', 'pornhub_auth_cancel', 'pornhub_auth_logout')`,
    sql`${lustreDeviceCommands.status} in ('pending', 'running')`,
    sql`${lustreDeviceCommands.createdAt} < now() - interval '90 seconds'`,
  ));
  const row = (await db.select().from(lustreDeviceCommands).where(and(eq(lustreDeviceCommands.accountID, accountID), eq(lustreDeviceCommands.deviceID, deviceID), eq(lustreDeviceCommands.id, commandID))).limit(1))[0];
  if (!row) throw new DeviceContractError("device_not_found", "Command not found.");
  return row;
}
export async function recentCompletedFeedPageResults(accountID: string, deviceID: string, since: Date) {
  const device = (await db.select({ id: lustreDevices.id }).from(lustreDevices).where(and(eq(lustreDevices.id, deviceID), eq(lustreDevices.accountID, accountID), isNull(lustreDevices.revokedAt))).limit(1))[0];
  if (!device) throw new DeviceContractError("device_not_found", "Device not found.");
  const results = await db.select({ result: lustreDeviceCommands.result }).from(lustreDeviceCommands).where(and(
    eq(lustreDeviceCommands.accountID, accountID),
    eq(lustreDeviceCommands.deviceID, deviceID),
    sql`${lustreDeviceCommands.kind} in ('feed_page', 'extract_preview', 'library_list', 'library_update', 'library_verify')`,
    eq(lustreDeviceCommands.status, "completed"),
    isNotNull(lustreDeviceCommands.result),
    isNotNull(lustreDeviceCommands.acknowledgedAt),
    gte(lustreDeviceCommands.acknowledgedAt, since),
  )).orderBy(desc(lustreDeviceCommands.acknowledgedAt));
  const snapshot = (await db.select().from(lustreDeviceLibrarySnapshots).where(and(eq(lustreDeviceLibrarySnapshots.accountID, accountID), eq(lustreDeviceLibrarySnapshots.deviceID, deviceID))).limit(1))[0];
  return snapshot ? [...results, { result: { kind: "library_snapshot", library: { revision: snapshot.revision, page: 1, hasMore: false, items: snapshot.items } } }] : results;
}
export async function syncJobStatus(deviceID: string, jobs: Array<{ id: string; sourcePageURL?: string; displayName?: string; preferredQualityLabel?: string; status: string; progress?: number; downloadedBytes?: number; totalBytes?: number; phase?: string; attempts: number; queuePriority?: number; updatedAt?: string }>) {
  for (const job of jobs) {
    const updatedAt = job.updatedAt ? new Date(job.updatedAt) : now();
    await db.insert(lustreDeviceJobStatus).values({ deviceID, jobID: job.id, sourcePageURL: job.sourcePageURL ?? null, displayName: job.displayName ?? "Download", preferredQualityLabel: job.preferredQualityLabel ?? null, status: job.status, progress: job.progress === undefined ? null : Math.round(job.progress * 10_000), downloadedBytes: job.downloadedBytes ?? null, totalBytes: job.totalBytes ?? null, phase: job.phase ?? null, attempts: job.attempts, queuePriority: job.queuePriority ?? null, updatedAt }).onConflictDoUpdate({ target: [lustreDeviceJobStatus.deviceID, lustreDeviceJobStatus.jobID], set: { sourcePageURL: job.sourcePageURL ?? null, displayName: job.displayName ?? "Download", preferredQualityLabel: job.preferredQualityLabel ?? null, status: job.status, progress: job.progress === undefined ? null : Math.round(job.progress * 10_000), downloadedBytes: job.downloadedBytes ?? null, totalBytes: job.totalBytes ?? null, phase: job.phase ?? null, attempts: job.attempts, queuePriority: job.queuePriority ?? null, updatedAt } });
  }
}
export async function jobStatusForOwnedDevice(
  accountID: string,
  deviceID: string,
  options: { status?: string; limit?: number; offset?: number } = {},
) {
  const device = (await db.select({ id: lustreDevices.id }).from(lustreDevices).where(and(eq(lustreDevices.id, deviceID), eq(lustreDevices.accountID, accountID))).limit(1))[0]; if (!device) throw new DeviceContractError("device_not_found", "Device not found.");
  const statusFilter = options.status === "active"
    ? sql`${lustreDeviceJobStatus.status} IN ('queued', 'running', 'paused')`
    : options.status === "failed"
      ? sql`${lustreDeviceJobStatus.status} IN ('failed', 'verificationRequired')`
      : options.status && options.status !== "all"
        ? eq(lustreDeviceJobStatus.status, options.status)
        : undefined;
  return db.select().from(lustreDeviceJobStatus)
    .where(and(eq(lustreDeviceJobStatus.deviceID, deviceID), statusFilter))
    .orderBy(desc(lustreDeviceJobStatus.updatedAt))
    .limit(Math.min(Math.max(options.limit ?? 100, 1), 100))
    .offset(Math.max(options.offset ?? 0, 0));
}

export async function jobDashboardForOwnedDevice(accountID: string, deviceID: string) {
  const device = (await db.select({ id: lustreDevices.id }).from(lustreDevices).where(and(eq(lustreDevices.id, deviceID), eq(lustreDevices.accountID, accountID))).limit(1))[0];
  if (!device) throw new DeviceContractError("device_not_found", "Device not found.");
  const [jobs, countResult, presence] = await Promise.all([
    db.select().from(lustreDeviceJobStatus)
      .where(and(
        eq(lustreDeviceJobStatus.deviceID, deviceID),
        sql`${lustreDeviceJobStatus.status} IN ('queued', 'running', 'paused')`,
      ))
      .orderBy(desc(lustreDeviceJobStatus.updatedAt))
      .limit(25),
    db.execute(sql`
      SELECT
        count(*) FILTER (WHERE status IN ('running', 'paused'))::integer AS active,
        count(*) FILTER (WHERE status = 'queued')::integer AS queued,
        count(*) FILTER (WHERE status IN ('failed', 'verificationRequired'))::integer AS failed,
        count(*) FILTER (WHERE status = 'completed')::integer AS completed
      FROM lustre_device_job_status
      WHERE device_id = ${deviceID}::uuid
    `),
    db.select({
      revokedAt: lustreDevices.revokedAt,
      lastHeartbeatAt: lustreDevicePresence.lastHeartbeatAt,
      agentVersion: lustreDevicePresence.agentVersion,
    }).from(lustreDevices)
      .leftJoin(lustreDevicePresence, eq(lustreDevicePresence.deviceID, lustreDevices.id))
      .where(eq(lustreDevices.id, deviceID))
      .limit(1),
  ]);
  const countRow = (countResult as unknown as { rows: Array<{ active: number; queued: number; failed: number; completed: number }> }).rows[0];
  return {
    jobs,
    counts: {
      active: Number(countRow?.active ?? 0),
      queued: Number(countRow?.queued ?? 0),
      failed: Number(countRow?.failed ?? 0),
      completed: Number(countRow?.completed ?? 0),
    },
    presence: presence[0]!,
  };
}
