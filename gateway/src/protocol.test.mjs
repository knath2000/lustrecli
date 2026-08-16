import assert from "node:assert/strict";
import test from "node:test";
import { commandDeliveryCapability, commandDeliveryFrame, commandWakeCapability, destinationsListCapability, feedPageCapability, feedQueueCapability, homeWorkspaceCapability, libraryCapability, negotiatedCommandDelivery, negotiatedCommandWake, negotiatedDestinationsList, negotiatedFeedPage, negotiatedFeedQueue, negotiatedHomeWorkspace, negotiatedLibrary, negotiatedPornHubAuth, pornHubAuthCapability, selectedGatewayCommand, validDestinationsAcknowledgement, validFeedPageAcknowledgement, validHomeWorkspaceAcknowledgement, validLibraryAcknowledgement, validLocalDownloadFolderAcknowledgement, validPersistenceResponse } from "./protocol.ts";

test("capability negotiation is realtime-only and survives attachment serialization", () => {
  assert.equal(negotiatedCommandDelivery({ capabilities: [commandDeliveryCapability] }, true), true);
  assert.equal(negotiatedCommandDelivery({ capabilities: [commandDeliveryCapability] }, false), false);
  assert.equal(negotiatedCommandDelivery({}, true), false);
  assert.equal(negotiatedFeedPage({ capabilities: [commandDeliveryCapability, feedPageCapability] }, true), true);
  assert.equal(negotiatedFeedPage({ capabilities: [feedPageCapability] }, true), false);
  assert.equal(negotiatedDestinationsList({ capabilities: [commandDeliveryCapability, destinationsListCapability] }, true), true);
  assert.equal(negotiatedDestinationsList({ capabilities: [destinationsListCapability] }, true), false);
  assert.equal(negotiatedFeedQueue({ capabilities: [commandDeliveryCapability, feedQueueCapability] }, true), true);
  assert.equal(negotiatedFeedQueue({ capabilities: [feedQueueCapability] }, true), false);
  assert.equal(negotiatedCommandWake({ capabilities: [commandDeliveryCapability, commandWakeCapability] }, true), true);
  assert.equal(negotiatedCommandWake({ capabilities: [commandWakeCapability] }, true), false);
  assert.equal(negotiatedPornHubAuth({ capabilities: [commandDeliveryCapability, pornHubAuthCapability] }, true), true);
  assert.equal(negotiatedPornHubAuth({ capabilities: [pornHubAuthCapability] }, true), false);
  assert.equal(negotiatedHomeWorkspace({ capabilities: [commandDeliveryCapability, homeWorkspaceCapability] }, true), true);
  assert.equal(negotiatedHomeWorkspace({ capabilities: [homeWorkspaceCapability] }, true), false);
  assert.equal(negotiatedLibrary({ capabilities: [commandDeliveryCapability, libraryCapability] }, true), true);
  assert.equal(negotiatedLibrary({ capabilities: [libraryCapability] }, true), false);
  const attachment = JSON.parse(JSON.stringify({ connectionKind: "realtime", commandDeliveryV1: true, feedPageV1: true, destinationsListV1: true, feedQueueV1: true, commandWakeV1: true }));
  assert.equal(attachment.commandDeliveryV1, true);
  assert.equal(attachment.feedPageV1, true);
  assert.equal(attachment.destinationsListV1, true);
  assert.equal(attachment.feedQueueV1, true);
  assert.equal(attachment.commandWakeV1, true);
});

test("library acknowledgements exclude paths and enforce bounded projections", () => {
  const stage = { destination: "Google Drive", state: "succeeded", updatedAt: "2026-08-02T12:00:00Z" };
  const item = { id: "f8ca8705-69c4-4c73-81fb-7bb1dc5c1853", kind: "video", sourcePageURL: "https://pmvhaven.com/video/example", title: "Example", provider: "pmvhaven.com", timestamp: "2026-08-02T12:00:00Z", tags: ["PMV"], collection: "Favorites", favorite: true, duplicateKey: "pmvhaven|example", mediaKind: "video", pipeline: [stage] };
  const ack = { id: item.id, status: "completed", result: { kind: "library_snapshot", library: { revision: 1, page: 1, hasMore: false, items: [item] } } };
  assert.equal(validLibraryAcknowledgement(ack), true);
  assert.equal(validLibraryAcknowledgement({ ...ack, result: { ...ack.result, library: { ...ack.result.library, items: [{ ...item, localPath: "/Users/example/video.mp4" }] } } }), false);
  assert.equal(validLibraryAcknowledgement({ ...ack, result: { ...ack.result, library: { ...ack.result.library, items: [{ ...item, sourcePageURL: "https://127.0.0.1/video" }] } } }), false);
  assert.equal(validLibraryAcknowledgement({ ...ack, result: { ...ack.result, library: { ...ack.result.library, items: Array(101).fill(item) } } }), false);
});

test("home workspace acknowledgements are bounded and credential-free", () => {
  const status = { id: "a", status: "completed", result: { kind: "home_status", homeReadiness: { ytDlp: true, ffmpeg: true, browserBridge: false } } };
  assert.equal(validHomeWorkspaceAcknowledgement(status), true);
  const item = { sourcePageURL: "https://pmvhaven.com/video/example", state: "resolved", title: "Example", thumbnailURL: "https://cdn.example.com/thumb.jpg", provider: "PMVHaven", qualities: [{ label: "2160p", mediaKind: "direct" }], errorCode: null };
  const preview = { id: "a", status: "completed", result: { kind: "extract_preview", homePreview: [item] } };
  assert.equal(validHomeWorkspaceAcknowledgement(preview), true);
  assert.equal(validHomeWorkspaceAcknowledgement({ ...preview, result: { ...preview.result, homePreview: [{ ...item, cookies: "secret" }] } }), false);
  assert.equal(validHomeWorkspaceAcknowledgement({ ...preview, result: { ...preview.result, homePreview: [{ ...item, sourcePageURL: "https://127.0.0.1/video" }] } }), false);
  assert.equal(validHomeWorkspaceAcknowledgement({ ...preview, result: { ...preview.result, homePreview: [{ ...item, qualities: Array(21).fill(item.qualities[0]) }] } }), false);
  assert.equal(validHomeWorkspaceAcknowledgement({ ...preview, result: { ...preview.result, homePreview: [{ ...item, title: "x".repeat(65_000) }] } }), false);
});

test("destination acknowledgements enforce safe fields and the 32768-byte boundary", () => {
  const destination = { id: "f8ca8705-69c4-4c73-81fb-7bb1dc5c1853", name: "Seedbox", baseURL: "https://dav.example.com", username: "user", remotePath: "/downloads", allowInvalidCertificate: false };
  const acknowledgement = { id: destination.id, status: "completed", result: { kind: "destinations_list", destinations: [destination] } };
  assert.equal(validDestinationsAcknowledgement(acknowledgement), true);
  assert.equal(validDestinationsAcknowledgement({ ...acknowledgement, result: { ...acknowledgement.result, destinations: Array(65).fill(destination) } }), false);
  for (const invalid of [
    { ...destination, baseURL: "https://user:secret@dav.example.com" },
    { ...destination, baseURL: "http://dav.example.com" },
    { ...destination, remotePath: "/safe/../secret" },
    { ...destination, remotePath: "/safe//path" },
    { ...destination, allowInvalidCertificate: "false" },
  ]) assert.equal(validDestinationsAcknowledgement({ ...acknowledgement, result: { ...acknowledgement.result, destinations: [invalid] } }), false);
  assert.equal(validDestinationsAcknowledgement({ ...acknowledgement, result: { ...acknowledgement.result, destinations: [{ ...destination, name: "x".repeat(33_000) }] } }), false);
  const drive = { id: destination.id, name: "Google Drive", kind: "google_drive", remoteName: "gdrive", remotePath: "/Lustre Uploads" };
  assert.equal(validDestinationsAcknowledgement({ ...acknowledgement, result: { ...acknowledgement.result, destinations: [drive] } }), true);
  assert.equal(validDestinationsAcknowledgement({ ...acknowledgement, result: { ...acknowledgement.result, destinations: [{ ...drive, token: "secret" }] } }), false);
});

test("local download folder acknowledgements never expose filesystem paths", () => {
  const acknowledgement = { id: "f8ca8705-69c4-4c73-81fb-7bb1dc5c1853", status: "completed", result: { kind: "local_download_folder", localDownloadFolder: { mode: "custom", folderName: "Videos" } } };
  assert.equal(validLocalDownloadFolderAcknowledgement(acknowledgement), true);
  assert.equal(validLocalDownloadFolderAcknowledgement({ ...acknowledgement, result: { ...acknowledgement.result, localDownloadFolder: { ...acknowledgement.result.localDownloadFolder, path: "/Volumes/Private" } } }), false);
  const selected = { version: 1, type: "gateway-command-selected", sequence: 1, correlationID: "folder", command: { id: acknowledgement.id, kind: "local_folder_choose", payload: { deliveryProtocol: "gateway-v1" } } };
  assert.equal(selectedGatewayCommand(selected, 1, "folder", false, true)?.kind, "local_folder_choose");
  assert.equal(selectedGatewayCommand(selected, 1, "folder", false, false), undefined);
});

test("feed_page acknowledgements enforce schema and the 118000-byte boundary", () => {
  const item = { id: "item", siteID: "hqporner", title: "Example", sourcePageURL: "https://example.com/video", thumbnailURL: null, previewURLs: [], uploadedAt: "2026-07-26T10:00:00Z", uploadedAtIsApproximate: false, viewCount: 0, studio: null, queueCapability: "supported" };
  const ack = { id: "a", status: "completed", result: { kind: "feed_page", page: { items: [item], page: 1, hasMore: false } } };
  assert.equal(validFeedPageAcknowledgement(ack), true);
  assert.equal(validFeedPageAcknowledgement({ ...ack, result: { ...ack.result, page: { ...ack.result.page, items: [{ ...item, downloadedAt: "2026-07-26T11:00:00Z" }] } } }), true);
  assert.equal(validFeedPageAcknowledgement({ ...ack, result: { ...ack.result, page: { ...ack.result.page, items: [{ ...item, downloadedAt: "not-a-date" }] } } }), false);
  assert.equal(validFeedPageAcknowledgement({ ...ack, result: { ...ack.result, page: { ...ack.result.page, items: Array(51).fill(item) } } }), false);
  assert.equal(validFeedPageAcknowledgement({ ...ack, result: { ...ack.result, page: { ...ack.result.page, items: [{ ...item, title: "x".repeat(70_000) }] } } }), false);
  assert.equal(validFeedPageAcknowledgement({ ...ack, result: { ...ack.result, page: { ...ack.result.page, items: [{ ...item, sourcePageURL: "http://example.com/video" }] } } }), false);
});

test("delivery frame is ordered after local acceptance by construction and supports null", () => {
  const frames = [
    { version: 1, type: "heartbeat-accepted", sequence: 4 },
    commandDeliveryFrame({ sequence: 4, correlationID: "j1", acknowledgedCommandAckIDs: [], command: null }),
  ];
  assert.deepEqual(frames.map((frame) => frame.type), ["heartbeat-accepted", "command-delivery"]);
  assert.equal(frames[1].command, null);
});

test("relay responses are strictly validated", () => {
  assert.equal(validPersistenceResponse({ version: 1, type: "gateway-heartbeat-persisted", sequence: 7, correlationID: "j1", acknowledgedCommandAckIDs: ["a"] }, 7, "j1"), true);
  assert.equal(validPersistenceResponse({ version: 1, type: "gateway-heartbeat-persisted", sequence: 8, correlationID: "j1", acknowledgedCommandAckIDs: [] }, 7, "j1"), false);
  assert.deepEqual(selectedGatewayCommand({ version: 1, type: "gateway-command-selected", sequence: 7, correlationID: "j1", command: { id: "a", kind: "feed_sites", payload: {} } }, 7, "j1", false), { id: "a", kind: "feed_sites", payload: {} });
  assert.equal(selectedGatewayCommand({ version: 1, type: "gateway-command-selected", sequence: 7, correlationID: "j1", command: null }, 7, "j1", true), null);
  const page = { version: 1, type: "gateway-command-selected", sequence: 7, correlationID: "j1", command: { id: "a", kind: "feed_page", payload: { siteID: "hqporner", page: 1 } } };
  assert.equal(selectedGatewayCommand(page, 7, "j1", false), undefined);
  assert.deepEqual(selectedGatewayCommand(page, 7, "j1", true), page.command);
  for (const payload of [{ siteID: "unknown", page: 1 }, { siteID: "hqporner", page: 0 }, { siteID: "hqporner", page: 1, query: "\u0000" }]) {
    assert.equal(selectedGatewayCommand({ ...page, command: { ...page.command, payload } }, 7, "j1", true), undefined);
  }
  const destinations = { version: 1, type: "gateway-command-selected", sequence: 7, correlationID: "j1", command: { id: "f8ca8705-69c4-4c73-81fb-7bb1dc5c1853", kind: "destinations_list", payload: {} } };
  assert.equal(selectedGatewayCommand(destinations, 7, "j1", true, false), undefined);
  assert.deepEqual(selectedGatewayCommand(destinations, 7, "j1", true, true), destinations.command);
  assert.equal(selectedGatewayCommand({ ...destinations, command: { ...destinations.command, payload: { unexpected: true } } }, 7, "j1", true, true), undefined);
  const queue = { version: 1, type: "gateway-command-selected", sequence: 7, correlationID: "j1", command: { id: "f8ca8705-69c4-4c73-81fb-7bb1dc5c1853", kind: "queue_url", payload: { url: "https://hqporner.com/hdporn/example.html", destination: "local", deliveryProtocol: "gateway-v1" } } };
  assert.equal(selectedGatewayCommand(queue, 7, "j1", true, true, false), undefined);
  assert.deepEqual(selectedGatewayCommand(queue, 7, "j1", true, true, true), queue.command);
  const qualityQueue = { ...queue, command: { ...queue.command, payload: { ...queue.command.payload, preferredQualityLabel: "1080p" } } };
  assert.deepEqual(selectedGatewayCommand(qualityQueue, 7, "j1", true, true, true), qualityQueue.command);
  const titledQueue = { ...queue, command: { ...queue.command, payload: { ...queue.command.payload, title: "Original video title" } } };
  assert.deepEqual(selectedGatewayCommand(titledQueue, 7, "j1", true, true, true), titledQueue.command);
  for (const payload of [
    { ...queue.command.payload, url: "https://user:secret@hqporner.com/example" },
    { ...queue.command.payload, url: "http://hqporner.com/example" },
    { ...queue.command.payload, destination: "Seedbox3" },
    { ...queue.command.payload, preferredQualityLabel: "x".repeat(81) },
    { ...queue.command.payload, title: "x".repeat(513) },
  ]) assert.equal(selectedGatewayCommand({ ...queue, command: { ...queue.command, payload } }, 7, "j1", true, true, true), undefined);
  const action = { version: 1, type: "gateway-command-selected", sequence: 7, correlationID: "j1", command: { id: "f8ca8705-69c4-4c73-81fb-7bb1dc5c1853", kind: "job_action", payload: { jobID: "88e5c12c-43a1-4b17-ae2a-4231c3644ff8", action: "retry", deliveryProtocol: "gateway-v1" } } };
  assert.deepEqual(selectedGatewayCommand(action, 7, "j1", true, true, true), action.command);
  for (const payload of [
    { ...action.command.payload, action: "delete" },
    { ...action.command.payload, jobID: "invalid" },
    { ...action.command.payload, unexpected: true },
  ]) assert.equal(selectedGatewayCommand({ ...action, command: { ...action.command, payload } }, 7, "j1", true, true, true), undefined);
  for (const kind of ["pornhub_auth_status", "pornhub_auth_login", "pornhub_auth_cancel", "pornhub_auth_logout"]) {
    const auth = { ...action, command: { id: action.command.id, kind, payload: { deliveryProtocol: "gateway-v1" } } };
    assert.equal(selectedGatewayCommand(auth, 7, "j1", true, true, true, false), undefined);
    assert.deepEqual(selectedGatewayCommand(auth, 7, "j1", true, true, true, true), auth.command);
    assert.equal(selectedGatewayCommand({ ...auth, command: { ...auth.command, payload: { deliveryProtocol: "gateway-v1", cookie: "secret" } } }, 7, "j1", true, true, true, true), undefined);
  }
  const home = { version: 1, type: "gateway-command-selected", sequence: 7, correlationID: "j1", command: { id: action.command.id, kind: "extract_preview", payload: { urls: ["https://pmvhaven.com/video/example"], deliveryProtocol: "gateway-v1" } } };
  assert.equal(selectedGatewayCommand(home, 7, "j1", true, true, true, true, false), undefined);
  assert.deepEqual(selectedGatewayCommand(home, 7, "j1", true, true, true, true, true), home.command);
  for (const urls of [[], Array(11).fill("https://example.com/video"), ["https://192.168.1.2/video"], ["https://pmvhaven.com@evil.example/video"]]) {
    assert.equal(selectedGatewayCommand({ ...home, command: { ...home.command, payload: { ...home.command.payload, urls } } }, 7, "j1", true, true, true, true, true), undefined);
  }
  const library = { version: 1, type: "gateway-command-selected", sequence: 7, correlationID: "j1", command: { id: action.command.id, kind: "library_list", payload: { page: 1, deliveryProtocol: "gateway-v1" } } };
  assert.equal(selectedGatewayCommand(library, 7, "j1", true, true, true, true, true, false), undefined);
  assert.deepEqual(selectedGatewayCommand(library, 7, "j1", true, true, true, true, true, true), library.command);
});
