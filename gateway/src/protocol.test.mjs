import assert from "node:assert/strict";
import test from "node:test";
import { commandDeliveryCapability, commandDeliveryFrame, feedPageCapability, negotiatedCommandDelivery, negotiatedFeedPage, selectedGatewayCommand, validFeedPageAcknowledgement, validPersistenceResponse } from "./protocol.ts";

test("capability negotiation is realtime-only and survives attachment serialization", () => {
  assert.equal(negotiatedCommandDelivery({ capabilities: [commandDeliveryCapability] }, true), true);
  assert.equal(negotiatedCommandDelivery({ capabilities: [commandDeliveryCapability] }, false), false);
  assert.equal(negotiatedCommandDelivery({}, true), false);
  assert.equal(negotiatedFeedPage({ capabilities: [commandDeliveryCapability, feedPageCapability] }, true), true);
  assert.equal(negotiatedFeedPage({ capabilities: [feedPageCapability] }, true), false);
  const attachment = JSON.parse(JSON.stringify({ connectionKind: "realtime", commandDeliveryV1: true, feedPageV1: true }));
  assert.equal(attachment.commandDeliveryV1, true);
  assert.equal(attachment.feedPageV1, true);
});

test("feed_page acknowledgements enforce schema and the 65536-byte boundary", () => {
  const item = { id: "item", siteID: "hqporner", title: "Example", sourcePageURL: "https://example.com/video", thumbnailURL: null, previewURLs: [], uploadedAt: "2026-07-26T10:00:00Z", uploadedAtIsApproximate: false, viewCount: 0, studio: null, queueCapability: "supported" };
  const ack = { id: "a", status: "completed", result: { kind: "feed_page", page: { items: [item], page: 1, hasMore: false } } };
  assert.equal(validFeedPageAcknowledgement(ack), true);
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
});
