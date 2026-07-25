import { requireCurrentAccount } from "@/lib/auth/current-account";
import { DeviceContractError } from "@/lib/cloud/device-contract";
import { queueURLCommand } from "@/lib/cloud/device-repository";
import { jsonError, requestBody } from "@/lib/cloud/route";

type RouteContext = { params: Promise<{ deviceID: string }> };

function queueURL(body: Record<string, unknown>) {
  if (body.kind !== "queue_url" || typeof body.url !== "string" || body.url.length > 2_048) throw new DeviceContractError("invalid_request", "A supported queue URL is required.");
  const url = new URL(body.url);
  if (!["http:", "https:"].includes(url.protocol) || url.username || url.password) throw new DeviceContractError("invalid_request", "A supported queue URL is required.");
  const preferredQualityLabel = typeof body.preferredQualityLabel === "string" && body.preferredQualityLabel.trim() ? body.preferredQualityLabel.trim().slice(0, 80) : undefined;
  return { url: url.toString(), preferredQualityLabel };
}

export async function POST(request: Request, context: RouteContext) {
  try {
    const account = await requireCurrentAccount(); const { deviceID } = await context.params; const command = queueURL(await requestBody(request));
    const created = await queueURLCommand(account.id, deviceID, command.url, command.preferredQualityLabel);
    return Response.json({ command: { id: created.id, status: created.status, createdAt: created.createdAt.toISOString() } }, { status: 201 });
  } catch (error) { return jsonError(error); }
}
