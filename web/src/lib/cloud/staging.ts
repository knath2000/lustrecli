import "server-only";
import { DeleteObjectCommand, GetObjectCommand, S3Client } from "@aws-sdk/client-s3";
import { getSignedUrl } from "@aws-sdk/s3-request-presigner";
import { and, eq, sql } from "drizzle-orm";
import { SignJWT, jwtVerify } from "jose";
import { db } from "@/lib/db/client";
import { lustreCloudStages } from "@/lib/db/schema";

const maximumBytes = 10 * 1024 * 1024 * 1024;
const retentionHours = 72;
const reservation = maximumBytes * retentionHours;
const monthlyReservationLimit = 8 * 1024 * 1024 * 1024 * 30 * 24;
const terminalStates = new Set(["ready", "delivered", "failed", "cancelled", "expired"]);

type StagingClaims = {
  sourcePageURL: string;
  mediaURL: string;
  headers: Record<string, string>;
  title: string;
  label: string;
};

function tokenKey() {
  const value = process.env.LUSTRE_STAGING_TOKEN_SECRET;
  if (!value) throw new Error("LUSTRE_STAGING_TOKEN_SECRET is not configured.");
  return new TextEncoder().encode(value);
}

function safeFilename(title: string) {
  const stem = title.normalize("NFKC").replace(/[\u0000-\u001f\u007f/\\:*?"<>|]/g, " ").replace(/\s+/g, " ").trim().slice(0, 180) || "Lustre Video";
  return `${stem}.mp4`;
}

export async function issueStagingToken(deviceID: string, claims: StagingClaims) {
  return new SignJWT({ ...claims, use: "cloud-staging", version: 1 })
    .setProtectedHeader({ alg: "HS256" })
    .setSubject(deviceID)
    .setAudience("lustre-cloud-staging")
    .setJti(crypto.randomUUID())
    .setIssuedAt()
    .setExpirationTime("10m")
    .sign(tokenKey());
}

export async function verifyStagingToken(token: string, deviceID: string): Promise<StagingClaims> {
  const result = await jwtVerify(token, tokenKey(), { audience: "lustre-cloud-staging", subject: deviceID });
  const value = result.payload;
  if (value.use !== "cloud-staging" || value.version !== 1 || typeof value.sourcePageURL !== "string" || typeof value.mediaURL !== "string" || typeof value.title !== "string" || typeof value.label !== "string" || !value.headers || typeof value.headers !== "object" || Array.isArray(value.headers)) throw new Error("invalid_staging_token");
  const headers = Object.fromEntries(Object.entries(value.headers).filter(([key, item]) => ["Referer", "Origin", "User-Agent"].includes(key) && typeof item === "string")) as Record<string, string>;
  return { sourcePageURL: value.sourcePageURL, mediaURL: value.mediaURL, title: value.title.slice(0, 1000), label: value.label.slice(0, 80), headers };
}

async function modalRequest<T>(path: string, init?: RequestInit): Promise<T> {
  const origin = process.env.STAGING_ORIGIN;
  const key = process.env.MODAL_PROXY_KEY;
  const secret = process.env.MODAL_PROXY_SECRET;
  if (!origin || !key || !secret) throw new Error("staging_unavailable");
  const response = await fetch(new URL(path, origin), {
    ...init,
    headers: { ...init?.headers, "Modal-Key": key, "Modal-Secret": secret },
    cache: "no-store",
    signal: AbortSignal.timeout(15_000),
  });
  const body = await response.json().catch(() => ({}));
  if (!response.ok) throw new Error(typeof body?.error === "string" ? body.error : "staging_unavailable");
  return body as T;
}

export async function createStage(accountID: string, deviceID: string, claims: StagingClaims) {
  const id = crypto.randomUUID();
  const objectKey = `staging/${deviceID}/${id}.mp4`;
  const filename = safeFilename(claims.title);
  const expiresAt = new Date(Date.now() + retentionHours * 60 * 60 * 1000);
  const inserted = await db.execute(sql`
    WITH device_lock AS (
      SELECT pg_advisory_xact_lock(hashtext(${deviceID}))
    ),
    eligible AS (
      SELECT 1
      FROM device_lock
      WHERE ${process.env.LUSTRE_CLOUD_STAGING_ENABLED === "true"}
        AND (SELECT count(*) FROM lustre_cloud_stages WHERE device_id = ${deviceID}::uuid AND status IN ('pending', 'staging', 'ready')) < 2
        AND (SELECT coalesce(sum(reserved_byte_hours), 0) FROM lustre_cloud_stages WHERE created_at >= date_trunc('month', now())) + ${reservation} <= ${monthlyReservationLimit}
    )
    INSERT INTO lustre_cloud_stages
      (id, account_id, device_id, object_key, filename, status, reserved_byte_hours, expires_at)
    SELECT ${id}::uuid, ${accountID}::uuid, ${deviceID}::uuid, ${objectKey}, ${filename}, 'pending', ${reservation}, ${expiresAt}
    FROM eligible
    RETURNING id
  `);
  if (!(inserted as unknown as { rows: unknown[] }).rows.length) throw new Error("staging_disabled_or_quota");
  try {
    const submitted = await modalRequest<{ callID: string }>("/submit", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ stageID: id, mediaURL: claims.mediaURL, headers: claims.headers, objectKey, filename, maximumBytes }),
    });
    await db.update(lustreCloudStages).set({ modalCallID: submitted.callID, status: "staging", updatedAt: new Date() }).where(eq(lustreCloudStages.id, id));
  } catch (error) {
    await db.update(lustreCloudStages).set({ status: "failed", failureCode: "submit_failed", reservedByteHours: 0, updatedAt: new Date() }).where(eq(lustreCloudStages.id, id));
    throw error;
  }
  return stageForDevice(id, deviceID);
}

export async function stageForDevice(id: string, deviceID: string) {
  const [stage] = await db.select().from(lustreCloudStages).where(and(eq(lustreCloudStages.id, id), eq(lustreCloudStages.deviceID, deviceID))).limit(1);
  if (!stage) throw new Error("stage_not_found");
  if (stage.expiresAt <= new Date() && !terminalStates.has(stage.status)) {
    await cleanupRemoteStage(stage);
    await db.update(lustreCloudStages).set({ status: "expired", failureCode: "expired", reservedByteHours: 0, updatedAt: new Date() }).where(eq(lustreCloudStages.id, id));
    return { ...stage, status: "expired", failureCode: "expired" };
  }
  if (stage.modalCallID && stage.status === "staging") {
    try {
      const result = await modalRequest<{ status: string; progressBytes?: number; totalBytes?: number; sha256?: string; failureCode?: string }>(`/result/${encodeURIComponent(stage.modalCallID)}?stageID=${encodeURIComponent(stage.id)}`);
      const status = ["staging", "ready", "failed", "cancelled"].includes(result.status) ? result.status : "failed";
      const reservedByteHours = status === "failed" || status === "cancelled" ? 0 : status === "ready" && result.totalBytes ? result.totalBytes * retentionHours : stage.reservedByteHours;
      await db.update(lustreCloudStages).set({ status, progressBytes: result.progressBytes ?? stage.progressBytes, totalBytes: result.totalBytes ?? stage.totalBytes, sha256: result.sha256 ?? stage.sha256, failureCode: result.failureCode ?? null, reservedByteHours, updatedAt: new Date() }).where(eq(lustreCloudStages.id, id));
      return { ...stage, status, progressBytes: result.progressBytes ?? stage.progressBytes, totalBytes: result.totalBytes ?? stage.totalBytes, sha256: result.sha256 ?? stage.sha256, failureCode: result.failureCode ?? null };
    } catch {
      await cleanupRemoteStage(stage);
      await db.update(lustreCloudStages).set({ status: "failed", failureCode: "poll_failed", reservedByteHours: 0, updatedAt: new Date() }).where(eq(lustreCloudStages.id, id));
      return { ...stage, status: "failed", failureCode: "poll_failed" };
    }
  }
  return stage;
}

function r2() {
  const accountID = process.env.R2_ACCOUNT_ID;
  const accessKeyId = process.env.R2_ACCESS_KEY_ID;
  const secretAccessKey = process.env.R2_SECRET_ACCESS_KEY;
  if (!accountID || !accessKeyId || !secretAccessKey) throw new Error("r2_unavailable");
  return new S3Client({ region: "auto", endpoint: `https://${accountID}.r2.cloudflarestorage.com`, credentials: { accessKeyId, secretAccessKey } });
}

function bucket() {
  if (!process.env.R2_STAGING_BUCKET) throw new Error("r2_unavailable");
  return process.env.R2_STAGING_BUCKET;
}

async function cleanupRemoteStage(stage: typeof lustreCloudStages.$inferSelect) {
  if (stage.modalCallID) await modalRequest(`/cancel/${encodeURIComponent(stage.modalCallID)}`, { method: "POST" }).catch(() => undefined);
  await r2().send(new DeleteObjectCommand({ Bucket: bucket(), Key: stage.objectKey })).catch(() => undefined);
}

export async function stageTicket(id: string, deviceID: string) {
  const stage = await stageForDevice(id, deviceID);
  if (stage.status !== "ready" || !stage.totalBytes || !stage.sha256) throw new Error("stage_not_ready");
  const downloadURL = await getSignedUrl(r2(), new GetObjectCommand({ Bucket: bucket(), Key: stage.objectKey, ResponseContentDisposition: `attachment; filename="${stage.filename.replaceAll('"', "")}"` }), { expiresIn: 15 * 60 });
  return { stageID: stage.id, status: stage.status, filename: stage.filename, totalBytes: stage.totalBytes, sha256: stage.sha256, expiresAt: new Date(Date.now() + 15 * 60 * 1000).toISOString(), downloadURL };
}

export async function finishStage(id: string, deviceID: string) {
  const stage = await stageForDevice(id, deviceID);
  if (stage.status === "delivered") return stage;
  if (stage.status !== "ready") throw new Error("stage_not_ready");
  await r2().send(new DeleteObjectCommand({ Bucket: bucket(), Key: stage.objectKey }));
  const retainedHours = Math.max(1, Math.ceil((Date.now() - stage.createdAt.getTime()) / 3_600_000));
  await db.update(lustreCloudStages).set({ status: "delivered", deliveredAt: new Date(), reservedByteHours: (stage.totalBytes ?? 0) * retainedHours, updatedAt: new Date() }).where(eq(lustreCloudStages.id, id));
  return { ...stage, status: "delivered" };
}

export async function cancelStage(id: string, deviceID: string) {
  const stage = await stageForDevice(id, deviceID);
  await cleanupRemoteStage(stage);
  await db.update(lustreCloudStages).set({ status: "cancelled", failureCode: "cancelled", reservedByteHours: 0, updatedAt: new Date() }).where(eq(lustreCloudStages.id, id));
}

export function serializeStage(stage: Awaited<ReturnType<typeof stageForDevice>>) {
  return { stageID: stage.id, status: stage.status, progressBytes: stage.progressBytes, totalBytes: stage.totalBytes, expiresAt: stage.expiresAt.toISOString(), failureCode: stage.failureCode };
}
