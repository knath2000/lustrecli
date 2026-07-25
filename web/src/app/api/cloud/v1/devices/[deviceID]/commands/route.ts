import { requireCurrentAccount } from "@/lib/auth/current-account";
import { DeviceContractError } from "@/lib/cloud/device-contract";
import { jobActionCommand, queueURLCommand } from "@/lib/cloud/device-repository";
import { jsonError, requestBody } from "@/lib/cloud/route";

type RouteContext = { params: Promise<{ deviceID: string }> };

function queueURL(body: Record<string, unknown>) {
  if (body.kind !== "queue_url" || typeof body.url !== "string" || body.url.length > 2_048) throw new DeviceContractError("invalid_request", "A supported queue URL is required.");
  const url = new URL(body.url);
  if (!["http:", "https:"].includes(url.protocol) || url.username || url.password) throw new DeviceContractError("invalid_request", "A supported queue URL is required.");
  const preferredQualityLabel = typeof body.preferredQualityLabel === "string" && body.preferredQualityLabel.trim() ? body.preferredQualityLabel.trim().slice(0, 80) : undefined;
  return { url: url.toString(), preferredQualityLabel };
}
function jobAction(body: Record<string, unknown>) {
  if (body.kind !== "job_action" || typeof body.jobID !== "string" || !/^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(body.jobID) || !["pause", "resume", "cancel", "retry"].includes(body.action as string)) throw new DeviceContractError("invalid_request", "A supported job action is required.");
  return { jobID: body.jobID, action: body.action as "pause" | "resume" | "cancel" | "retry" };
}

export async function POST(request: Request, context: RouteContext) {
  try {
    const account = await requireCurrentAccount(); const { deviceID } = await context.params; const body = await requestBody(request);
    const created = body.kind === "queue_url" ? await queueURLCommand(account.id, deviceID, queueURL(body).url, queueURL(body).preferredQualityLabel) : await jobActionCommand(account.id, deviceID, jobAction(body).jobID, jobAction(body).action);
    return Response.json({ command: { id: created.id, status: created.status, createdAt: created.createdAt.toISOString() } }, { status: 201 });
  } catch (error) { return jsonError(error); }
}
