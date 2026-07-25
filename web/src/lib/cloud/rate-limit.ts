import "server-only";
import { db } from "@/lib/db/client";
import { sql } from "drizzle-orm";
import { DeviceContractError } from "./device-contract";

export async function enforceRateLimit(bucket: string, limit: number, windowSeconds: number) {
  const result = await db.execute(sql`
    INSERT INTO lustre_rate_limits (bucket, count, resets_at)
    VALUES (${bucket}, 1, now() + (${windowSeconds} || ' seconds')::interval)
    ON CONFLICT (bucket) DO UPDATE SET
      count = CASE WHEN lustre_rate_limits.resets_at <= now() THEN 1 ELSE lustre_rate_limits.count + 1 END,
      resets_at = CASE WHEN lustre_rate_limits.resets_at <= now() THEN now() + (${windowSeconds} || ' seconds')::interval ELSE lustre_rate_limits.resets_at END
    RETURNING count
  `);
  const row = (result as unknown as { rows: Array<{ count: number }> }).rows[0];
  if (!row || row.count > limit) throw new DeviceContractError("rate_limited", "Too many requests. Try again later.");
}
