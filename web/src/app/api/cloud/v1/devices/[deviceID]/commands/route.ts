import { requireCurrentAccount } from "@/lib/auth/current-account";
import { DeviceContractError, normalizeFeedPageCommand } from "@/lib/cloud/device-contract";
import { notifyCommandWake } from "@/lib/cloud/command-wake";
import { cachedFeedResult, feedCommand, feedQueueCommand, jobActionCommand, queueURLCommand } from "@/lib/cloud/device-repository";
import { jsonError, requestBody } from "@/lib/cloud/route";

type RouteContext = { params: Promise<{ deviceID: string }> };

function queueURL(body: Record<string, unknown>) {
  if (body.kind !== "queue_url" || typeof body.url !== "string" || body.url.length > 2_048) throw new DeviceContractError("invalid_request", "A supported queue URL is required.");
  const url = new URL(body.url);
  if (!["http:", "https:"].includes(url.protocol) || url.username || url.password) throw new DeviceContractError("invalid_request", "A supported queue URL is required.");
  const preferredQualityLabel = typeof body.preferredQualityLabel === "string" && body.preferredQualityLabel.trim() ? body.preferredQualityLabel.trim().slice(0, 80) : undefined;
  const destination = typeof body.destination === "string" && body.destination === "local" ? "local" : typeof body.destination === "string" && /^webdav:[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(body.destination) ? body.destination : undefined;
  if (body.destination !== undefined && !destination) throw new DeviceContractError("invalid_request", "A supported destination is required.");
  return { url: url.toString(), preferredQualityLabel, destination };
}
function jobAction(body: Record<string, unknown>) {
  if (body.kind !== "job_action" || typeof body.jobID !== "string" || !/^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(body.jobID) || !["pause", "resume", "cancel", "retry"].includes(body.action as string)) throw new DeviceContractError("invalid_request", "A supported job action is required.");
  return { jobID: body.jobID, action: body.action as "pause" | "resume" | "cancel" | "retry" };
}
function feedPage(body: Record<string, unknown>) {
  if (body.kind !== "feed_page") throw new DeviceContractError("invalid_request", "A supported feed page is required.");
  return normalizeFeedPageCommand(body);
}
const uuidPattern = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
function feedQueue(body: Record<string, unknown>) {
  if (Object.keys(body).sort().join(",") !== "destination,itemID,kind,requestID,siteID,sourcePageURL" || body.kind !== "feed_queue" || typeof body.requestID !== "string" || !uuidPattern.test(body.requestID) || typeof body.itemID !== "string" || !body.itemID || body.itemID.length > 512 || typeof body.siteID !== "string" || typeof body.sourcePageURL !== "string" || body.sourcePageURL.length > 2_048 || typeof body.destination !== "string" || !/^local$|^webdav:[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(body.destination)) {
    throw new DeviceContractError("invalid_request", "A supported Feed queue request is required.");
  }
  const url = new URL(body.sourcePageURL);
  if (url.protocol !== "https:" || url.username || url.password || url.hash) throw new DeviceContractError("invalid_request", "A supported Feed source URL is required.");
  return { requestID: body.requestID, itemID: body.itemID, siteID: body.siteID, sourcePageURL: url.toString(), destination: body.destination };
}

export async function POST(request: Request, context: RouteContext) {
  try {
    const account = await requireCurrentAccount(); const { deviceID } = await context.params; const body = await requestBody(request);
    const queue = body.kind === "queue_url" ? queueURL(body) : null;
    const feedQueueInput = body.kind === "feed_queue" ? feedQueue(body) : null;
    const page = body.kind === "feed_page" ? feedPage(body) : null;
    const feedPayload = body.kind === "feed_sites" ? {} : page ? { siteID: page.siteID, page: String(page.page), query: page.query } : null;
    const cache = body.kind === "feed_sites"
      ? await cachedFeedResult(account.id, deviceID, "feed_sites", {})
      : page
        ? await cachedFeedResult(account.id, deviceID, "feed_page", feedPayload!)
        : null;
    const created = feedQueueInput ? await feedQueueCommand({ accountID: account.id, deviceID, ...feedQueueInput }) : queue ? await queueURLCommand(account.id, deviceID, queue.url, queue.preferredQualityLabel, queue.destination) : body.kind === "job_action" ? await jobActionCommand(account.id, deviceID, jobAction(body).jobID, jobAction(body).action) : body.kind === "feed_sites" ? await feedCommand(account.id, deviceID, "feed_sites", {}) : page ? await feedCommand(account.id, deviceID, "feed_page", feedPayload!) : body.kind === "destinations_list" ? await feedCommand(account.id, deviceID, "destinations_list", {}) : body.kind === "webdav_add" && ["name", "baseURL", "username", "remotePath"].every((field) => typeof body[field] === "string") ? await feedCommand(account.id, deviceID, "webdav_add", { name: body.name as string, baseURL: body.baseURL as string, username: body.username as string, remotePath: body.remotePath as string, allowInvalidCertificate: body.allowInvalidCertificate === true ? "true" : "false" }) : (() => { throw new DeviceContractError("invalid_request", "Unsupported Cloud command."); })();
    await notifyCommandWake(deviceID, created.id);
    return Response.json({
      command: { id: created.id, status: created.status, createdAt: created.createdAt.toISOString() },
      cache: cache ? { ...cache, acknowledgedAt: cache.acknowledgedAt.toISOString() } : null,
    }, { status: 201 });
  } catch (error) { return jsonError(error); }
}
