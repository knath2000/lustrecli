import { requireCurrentAccount } from "@/lib/auth/current-account";
import { DeviceContractError, normalizeFeedPageCommand } from "@/lib/cloud/device-contract";
import { notifyCommandWake } from "@/lib/cloud/command-wake";
import { cachedFeedResult, feedCommand, feedQueueCommand, feedResolveCommand, homeWorkspaceCommand, jobActionCommand, libraryCommand, pornHubAuthCommand, queueURLCommand, watchlistQueueCommand, watchlistResolveCommand } from "@/lib/cloud/device-repository";
import { jsonError, requestBody } from "@/lib/cloud/route";
import { normalizeWatchlistQueueCommand } from "@/lib/cloud/watchlist-queue";

type RouteContext = { params: Promise<{ deviceID: string }> };

function queueURL(body: Record<string, unknown>) {
  if (body.kind !== "queue_url" || typeof body.url !== "string" || body.url.length > 2_048) throw new DeviceContractError("invalid_request", "A supported queue URL is required.");
  const url = new URL(body.url);
  if (!["http:", "https:"].includes(url.protocol) || url.username || url.password) throw new DeviceContractError("invalid_request", "A supported queue URL is required.");
  const preferredQualityLabel = typeof body.preferredQualityLabel === "string" && body.preferredQualityLabel.trim() ? body.preferredQualityLabel.trim().slice(0, 80) : undefined;
  const title = typeof body.title === "string" && body.title.trim() ? body.title.trim().slice(0, 512) : undefined;
  if (body.title !== undefined && !title) throw new DeviceContractError("invalid_request", "A supported source title is required.");
  const destination = typeof body.destination === "string" && body.destination === "local" ? "local" : typeof body.destination === "string" && /^(webdav|gdrive):[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(body.destination) ? body.destination : undefined;
  if (body.destination !== undefined && !destination) throw new DeviceContractError("invalid_request", "A supported destination is required.");
  const requestID = typeof body.requestID === "string" && uuidPattern.test(body.requestID) ? body.requestID : undefined;
  if (body.requestID !== undefined && !requestID) throw new DeviceContractError("invalid_request", "A valid queue request ID is required.");
  return { url: url.toString(), title, preferredQualityLabel, destination, requestID };
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
function publicHost(hostname: string) {
  const host = hostname.toLowerCase().replace(/^\[|\]$/g, "");
  if (host === "localhost" || host.endsWith(".localhost") || host === "::1" || host === "0.0.0.0" || host.startsWith("fc") || host.startsWith("fd") || /^fe[89ab]/.test(host)) return false;
  const parts = host.split(".").map(Number);
  return parts.length !== 4 || !parts.every((part) => Number.isInteger(part) && part >= 0 && part <= 255)
    || !(parts[0] === 10 || parts[0] === 127 || (parts[0] === 169 && parts[1] === 254) || (parts[0] === 172 && parts[1] >= 16 && parts[1] <= 31) || (parts[0] === 192 && parts[1] === 168));
}
function feedQueue(body: Record<string, unknown>) {
  if (Object.keys(body).sort().join(",") !== "destination,itemID,kind,requestID,siteID,sourcePageURL,title" || body.kind !== "feed_queue" || typeof body.requestID !== "string" || !uuidPattern.test(body.requestID) || typeof body.itemID !== "string" || !body.itemID || body.itemID.length > 512 || typeof body.siteID !== "string" || typeof body.title !== "string" || !body.title.trim() || body.title.length > 512 || typeof body.sourcePageURL !== "string" || body.sourcePageURL.length > 2_048 || typeof body.destination !== "string" || !/^local$|^(webdav|gdrive):[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(body.destination)) {
    throw new DeviceContractError("invalid_request", "A supported Feed queue request is required.");
  }
  const url = new URL(body.sourcePageURL);
  if (url.protocol !== "https:" || url.username || url.password || url.hash) throw new DeviceContractError("invalid_request", "A supported Feed source URL is required.");
  return { requestID: body.requestID, itemID: body.itemID, siteID: body.siteID, sourcePageURL: url.toString(), title: body.title.trim(), destination: body.destination };
}
function feedResolve(body: Record<string, unknown>) {
  if (Object.keys(body).sort().join(",") !== "itemID,kind,siteID,sourcePageURL" || body.kind !== "feed_resolve" || typeof body.itemID !== "string" || !body.itemID || body.itemID.length > 512 || typeof body.siteID !== "string" || typeof body.sourcePageURL !== "string" || body.sourcePageURL.length > 2_048) {
    throw new DeviceContractError("invalid_request", "A supported Feed extraction request is required.");
  }
  const url = new URL(body.sourcePageURL);
  if (url.protocol !== "https:" || url.username || url.password || url.hash || !publicHost(url.hostname)) throw new DeviceContractError("invalid_request", "A supported Feed source URL is required.");
  return { itemID: body.itemID, siteID: body.siteID, sourcePageURL: url.toString() };
}

export async function POST(request: Request, context: RouteContext) {
  try {
    const account = await requireCurrentAccount(); const { deviceID } = await context.params; const body = await requestBody(request);
    const queue = body.kind === "queue_url" ? queueURL(body) : null;
    const feedQueueInput = body.kind === "feed_queue" ? feedQueue(body) : null;
    const feedResolveInput = body.kind === "feed_resolve" ? feedResolve(body) : null;
    const watchlistID = body.kind === "watchlist_resolve" && Object.keys(body).sort().join(",") === "kind,watchlistID" && typeof body.watchlistID === "string" && uuidPattern.test(body.watchlistID) ? body.watchlistID : null;
    if (body.kind === "watchlist_resolve" && !watchlistID) throw new DeviceContractError("invalid_request", "A valid Watchlist item is required.");
    const watchlistQueueInput = body.kind === "watchlist_queue" ? normalizeWatchlistQueueCommand(body) : null;
    const page = body.kind === "feed_page" ? feedPage(body) : null;
    const feedPayload = body.kind === "feed_sites" ? {} : page ? { siteID: page.siteID, page: String(page.page), query: page.query } : null;
    const cache = body.kind === "feed_sites"
      ? await cachedFeedResult(account.id, deviceID, "feed_sites", {})
      : page
        ? await cachedFeedResult(account.id, deviceID, "feed_page", feedPayload!)
        : null;
    const authKinds = ["pornhub_auth_status", "pornhub_auth_login", "pornhub_auth_cancel", "pornhub_auth_logout"] as const;
    const gdriveKinds = ["gdrive_connect", "gdrive_folders", "gdrive_create_folder", "gdrive_select_folder", "gdrive_test"] as const;
    const gdriveKind = gdriveKinds.includes(body.kind as typeof gdriveKinds[number]) ? body.kind as typeof gdriveKinds[number] : null;
    const localFolderKinds = ["local_folder_status", "local_folder_choose", "local_folder_reset"] as const;
    const localFolderKind = localFolderKinds.includes(body.kind as typeof localFolderKinds[number]) ? body.kind as typeof localFolderKinds[number] : null;
    const homeKind = body.kind === "home_status" || body.kind === "extract_preview" ? body.kind : null;
    const libraryKinds = ["library_list", "library_update", "library_remove", "library_verify"] as const;
    const libraryKind = libraryKinds.includes(body.kind as typeof libraryKinds[number]) ? body.kind as typeof libraryKinds[number] : null;
    let libraryPayload: Record<string, unknown> | null = null;
    if (libraryKind === "library_list") {
      if (body.page !== undefined && (!Number.isSafeInteger(body.page) || (body.page as number) < 1 || (body.page as number) > 100)) throw new DeviceContractError("invalid_request", "A valid Library page is required.");
      libraryPayload = { page: body.page ?? 1 };
    } else if (libraryKind) {
      if (typeof body.itemID !== "string" || !uuidPattern.test(body.itemID)) throw new DeviceContractError("invalid_request", "A valid Library item is required.");
      if (libraryKind === "library_update") {
        if (!Array.isArray(body.tags) || body.tags.length > 20 || !body.tags.every((tag) => typeof tag === "string" && tag.trim() && [...tag].length <= 48) || (body.collection !== undefined && (typeof body.collection !== "string" || [...body.collection].length > 80)) || (body.favorite !== undefined && typeof body.favorite !== "boolean")) throw new DeviceContractError("invalid_request", "Valid Library organization is required.");
        libraryPayload = { itemID: body.itemID, tags: body.tags, ...(typeof body.collection === "string" ? { collection: body.collection } : {}), ...(typeof body.favorite === "boolean" ? { favorite: body.favorite } : {}) };
      } else {
        libraryPayload = { itemID: body.itemID };
      }
    }
    let previewURLs: string[] | undefined;
    if (homeKind === "extract_preview") {
      if (!Array.isArray(body.urls) || body.urls.length < 1 || body.urls.length > 10) throw new DeviceContractError("invalid_request", "Provide between 1 and 10 supported HTTPS URLs.");
      previewURLs = body.urls.map((value) => {
        if (typeof value !== "string" || value.length > 2_048) throw new DeviceContractError("invalid_request", "A supported extraction URL is required.");
        const url = new URL(value);
        const host = url.hostname.toLowerCase();
        if (url.protocol !== "https:" || url.username || url.password || !publicHost(host)) throw new DeviceContractError("invalid_request", "A supported extraction URL is required.");
        return url.toString();
      });
    }
    if (gdriveKind && gdriveKind !== "gdrive_connect" && (typeof body.profileID !== "string" || !uuidPattern.test(body.profileID))) throw new DeviceContractError("invalid_request", "A valid Google Drive profile is required.");
    if (gdriveKind && (gdriveKind === "gdrive_folders" || gdriveKind === "gdrive_create_folder" || gdriveKind === "gdrive_select_folder") && (typeof body.path !== "string" || body.path.length > 1_024 || !body.path.startsWith("/") || body.path.split("/").some((part) => part === "." || part === ".."))) throw new DeviceContractError("invalid_request", "A valid Google Drive folder is required.");
    const created = feedQueueInput ? await feedQueueCommand({ accountID: account.id, deviceID, ...feedQueueInput }) : feedResolveInput ? await feedResolveCommand({ accountID: account.id, deviceID, ...feedResolveInput }) : watchlistQueueInput ? await watchlistQueueCommand(account.id, deviceID, watchlistQueueInput.watchlistID, watchlistQueueInput.requestID, watchlistQueueInput.destination) : watchlistID ? await watchlistResolveCommand(account.id, deviceID, watchlistID) : queue ? await queueURLCommand(account.id, deviceID, queue.url, queue.title, queue.preferredQualityLabel, queue.destination, queue.requestID) : body.kind === "job_action" ? await jobActionCommand(account.id, deviceID, jobAction(body).jobID, jobAction(body).action) : libraryKind && libraryPayload ? await libraryCommand(account.id, deviceID, libraryKind, libraryPayload) : homeKind ? await homeWorkspaceCommand(account.id, deviceID, homeKind, previewURLs) : body.kind === "feed_sites" ? await feedCommand(account.id, deviceID, "feed_sites", {}) : page ? await feedCommand(account.id, deviceID, "feed_page", feedPayload!) : body.kind === "destinations_list" ? await feedCommand(account.id, deviceID, "destinations_list", {}) : localFolderKind ? await feedCommand(account.id, deviceID, localFolderKind, {}) : gdriveKind ? await feedCommand(account.id, deviceID, gdriveKind, { profileID: body.profileID as string | undefined, path: body.path as string | undefined }) : authKinds.includes(body.kind as typeof authKinds[number]) ? await pornHubAuthCommand(account.id, deviceID, body.kind as typeof authKinds[number]) : body.kind === "webdav_add" && ["name", "baseURL", "username", "remotePath"].every((field) => typeof body[field] === "string") ? await feedCommand(account.id, deviceID, "webdav_add", { name: body.name as string, baseURL: body.baseURL as string, username: body.username as string, remotePath: body.remotePath as string, allowInvalidCertificate: body.allowInvalidCertificate === true ? "true" : "false" }) : (() => { throw new DeviceContractError("invalid_request", "Unsupported Cloud command."); })();
    await notifyCommandWake(deviceID, created.id);
    return Response.json({
      command: { id: created.id, status: created.status, createdAt: created.createdAt instanceof Date ? created.createdAt.toISOString() : new Date(created.createdAt).toISOString() },
      cache: cache ? { ...cache, acknowledgedAt: cache.acknowledgedAt.toISOString() } : null,
    }, { status: 201 });
  } catch (error) { return jsonError(error); }
}
