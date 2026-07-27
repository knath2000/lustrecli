import assert from "node:assert/strict";
import test from "node:test";
import { normalizeFeedPageCommand, normalizePairingCode, parseHeartbeatFrame, validDestinationsResult, validFeedPageResult, validateDisplayName } from "./device-contract.ts";

test("pairing codes normalize grouped Crockford Base32", () => {
  assert.equal(normalizePairingCode("abcde-fghjk-mnpqr-stvwz"), "ABCDEFGHJKMNPQRSTVWZ");
  assert.throws(() => normalizePairingCode("0000-0000"));
});
test("display names are trimmed and bounded", () => {
  assert.equal(validateDisplayName("  Kalyan's Mac  "), "Kalyan's Mac");
  assert.throws(() => validateDisplayName(""));
  assert.throws(() => validateDisplayName("x".repeat(81)));
});

test("heartbeat preserves an agent-reported job update timestamp", () => {
  const frame = parseHeartbeatFrame({ version: 1, type: "heartbeat", sequence: 1, sentAt: "2026-07-25T10:00:00Z", agentVersion: "0.1.0", correlationID: "heartbeat-1", commandAcks: [], jobs: [{ id: "f8ca8705-69c4-4c73-81fb-7bb1dc5c1853", status: "completed", attempts: 1, updatedAt: "2026-07-24T18:04:03Z" }] });
  assert.equal(frame.jobs[0].updatedAt, "2026-07-24T18:04:03Z");
  assert.throws(() => parseHeartbeatFrame({ ...frame, jobs: [{ ...frame.jobs[0], updatedAt: "not-a-date" }] }));
});

test("heartbeat validates acknowledgements and complete job projections", () => {
  const frame = { version: 1, type: "heartbeat", sequence: 1, sentAt: "2026-07-25T10:00:00Z", agentVersion: "0.1.0", correlationID: "heartbeat-1", commandAcks: [{ id: "f8ca8705-69c4-4c73-81fb-7bb1dc5c1853", status: "completed", result: {} }], jobs: [{ id: "88e5c12c-43a1-4b17-ae2a-4231c3644ff8", sourcePageURL: "https://example.com/video", displayName: "Video", preferredQualityLabel: "1080p", status: "running", progress: 0.5, downloadedBytes: 10, totalBytes: 20, phase: "downloading", attempts: 0, updatedAt: "2026-07-25T10:00:00Z" }] };
  assert.equal(parseHeartbeatFrame({ ...frame, futureField: true }).jobs[0].phase, "downloading");
  assert.equal(parseHeartbeatFrame({ ...frame, commandAcks: [{ id: frame.commandAcks[0].id, status: "failed", code: "provider_verification_required" }] }).commandAcks[0].code, "provider_verification_required");
  for (const invalid of [
    { ...frame, correlationID: "" },
    { ...frame, commandAcks: [{ ...frame.commandAcks[0], id: "not-a-uuid" }] },
    { ...frame, commandAcks: [{ id: frame.commandAcks[0].id, status: "failed", code: "raw provider message" }] },
    { ...frame, commandAcks: [{ id: frame.commandAcks[0].id, status: "failed", code: "provider_changed", result: { raw: "forbidden" } }] },
    { ...frame, jobs: [{ ...frame.jobs[0], status: "unknown" }] },
    { ...frame, jobs: [{ ...frame.jobs[0], progress: 2 }] },
    { ...frame, jobs: [{ ...frame.jobs[0], downloadedBytes: -1 }] },
    { ...frame, jobs: [{ ...frame.jobs[0], attempts: -1 }] },
  ]) assert.throws(() => parseHeartbeatFrame(invalid));
});

test("feed_page commands normalize only known bounded requests", () => {
  assert.deepEqual(normalizeFeedPageCommand({ siteID: "hqporner", page: 1, query: "  newest   clips " }), { siteID: "hqporner", page: 1, query: "newest clips" });
  for (const value of [{ siteID: "unknown", page: 1 }, { siteID: "hqporner", page: 0 }, { siteID: "hqporner", page: 1.5 }, { siteID: "hqporner", page: 1, query: "\u0000" }, { siteID: "hqporner", page: 1, query: "x".repeat(121) }]) assert.throws(() => normalizeFeedPageCommand(value));
});

test("feed_page results enforce the canonical bounded schema", () => {
  const result = { kind: "feed_page", page: { page: 1, hasMore: true, items: [{ id: "item-1", siteID: "hqporner", title: "Example", sourcePageURL: "https://example.com/video", thumbnailURL: "https://example.com/thumb.jpg", previewURLs: ["https://example.com/preview.jpg"], uploadedAt: "2026-07-26T10:00:00Z", uploadedAtIsApproximate: false, viewCount: 10, studio: null, queueCapability: "supported" }] } };
  assert.equal(validFeedPageResult(result), true);
  assert.equal(validFeedPageResult({ ...result, page: { ...result.page, items: Array(51).fill(result.page.items[0]) } }), false);
  assert.equal(validFeedPageResult({ ...result, page: { ...result.page, items: [{ ...result.page.items[0], previewURLs: Array(5).fill("https://example.com/p.jpg") }] } }), false);
  assert.throws(() => parseHeartbeatFrame({ version: 1, type: "heartbeat", sequence: 1, sentAt: "2026-07-26T10:00:00Z", agentVersion: "0.1.0", correlationID: "j2", commandAcks: [{ id: "f8ca8705-69c4-4c73-81fb-7bb1dc5c1853", status: "completed", result: { ...result, page: { ...result.page, page: 0 } } }], jobs: [] }));
});

test("destination results contain only bounded credential-free fields", () => {
  const destination = { id: "f8ca8705-69c4-4c73-81fb-7bb1dc5c1853", name: "Seedbox", baseURL: "https://dav.example.com", username: "user", remotePath: "/downloads", allowInvalidCertificate: false };
  assert.equal(validDestinationsResult({ kind: "destinations_list", destinations: [destination] }), true);
  assert.equal(validDestinationsResult({ kind: "destinations_list", destinations: [{ ...destination, password: "secret" }] }), false);
  assert.equal(validDestinationsResult({ kind: "destinations_list", destinations: [{ ...destination, baseURL: "https://user:secret@dav.example.com" }] }), false);
  assert.equal(validDestinationsResult({ kind: "destinations_list", destinations: [{ ...destination, remotePath: "/safe/../secret" }] }), false);
  assert.equal(validDestinationsResult({ kind: "destinations_list", destinations: Array(65).fill(destination) }), false);
});
