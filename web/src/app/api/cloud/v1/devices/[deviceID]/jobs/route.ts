import { requireCurrentAccount } from "@/lib/auth/current-account";
import { PRESENCE_FRESHNESS_SECONDS } from "@/lib/cloud/device-contract";
import { jobDashboardForOwnedDevice, jobStatusForOwnedDevice } from "@/lib/cloud/device-repository";
import { jsonError } from "@/lib/cloud/route";

type RouteContext = { params: Promise<{ deviceID: string }> };

function serializedJob(job: Awaited<ReturnType<typeof jobStatusForOwnedDevice>>[number]) {
  return { id: job.jobID, sourcePageURL: job.sourcePageURL, displayName: job.displayName, preferredQualityLabel: job.preferredQualityLabel, status: job.status, progress: job.progress === null ? null : job.progress / 10_000, downloadedBytes: job.downloadedBytes, totalBytes: job.totalBytes, phase: job.phase, attempts: job.attempts, queuePriority: job.queuePriority, updatedAt: job.updatedAt.toISOString() };
}

function serializedPresence(presence: { revokedAt: Date | null; lastHeartbeatAt: Date | null; agentVersion: string | null }) {
  const age = presence.lastHeartbeatAt ? Date.now() - presence.lastHeartbeatAt.getTime() : null;
  const state = presence.revokedAt ? "revoked" : !presence.lastHeartbeatAt ? "neverConnected" : age! <= PRESENCE_FRESHNESS_SECONDS * 1000 ? "online" : "offline";
  return { state, lastSeenAt: presence.lastHeartbeatAt?.toISOString() ?? null, agentVersion: presence.agentVersion ?? null };
}

export async function GET(request: Request, context: RouteContext) {
  try {
    const account = await requireCurrentAccount();
    const { deviceID } = await context.params;
    const query = new URL(request.url).searchParams;
    if (query.get("scope") === "dashboard") {
      const snapshot = await jobDashboardForOwnedDevice(account.id, deviceID);
      return Response.json({
        jobs: snapshot.jobs.map(serializedJob),
        counts: snapshot.counts,
        presence: serializedPresence(snapshot.presence),
      }, { headers: { "Cache-Control": "private, no-store" } });
    }
    const status = query.get("status") ?? undefined;
    const limit = Number(query.get("limit") ?? "100");
    const offset = Number(query.get("offset") ?? "0");
    const jobs = await jobStatusForOwnedDevice(account.id, deviceID, {
      status,
      limit: Number.isFinite(limit) ? limit : 100,
      offset: Number.isFinite(offset) ? offset : 0,
    });
    return Response.json({ jobs: jobs.map(serializedJob), page: { limit: Math.min(Math.max(limit, 1), 100), offset: Math.max(offset, 0), hasMore: jobs.length === Math.min(Math.max(limit, 1), 100) } }, { headers: { "Cache-Control": "private, no-store" } });
  } catch (error) { return jsonError(error); }
}
