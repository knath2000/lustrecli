import { requireCurrentAccount } from "@/lib/auth/current-account";
import { jobStatusForOwnedDevice } from "@/lib/cloud/device-repository";
import { jsonError } from "@/lib/cloud/route";

type RouteContext = { params: Promise<{ deviceID: string }> };

export async function GET(_request: Request, context: RouteContext) {
  try {
    const account = await requireCurrentAccount(); const { deviceID } = await context.params; const jobs = await jobStatusForOwnedDevice(account.id, deviceID);
    return Response.json({ jobs: jobs.map((job) => ({ id: job.jobID, sourcePageURL: job.sourcePageURL, displayName: job.displayName, preferredQualityLabel: job.preferredQualityLabel, status: job.status, progress: job.progress === null ? null : job.progress / 10_000, downloadedBytes: job.downloadedBytes, totalBytes: job.totalBytes, phase: job.phase, attempts: job.attempts, updatedAt: job.updatedAt.toISOString() })) }, { headers: { "Cache-Control": "no-store" } });
  } catch (error) { return jsonError(error); }
}
