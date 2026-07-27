import assert from "node:assert/strict";
import test from "node:test";
import { createFeedAssetTicketHandler, feedAssetAppearedInResults, issueFeedAssetTicket, normalizeFeedAssetRequest, verifyFeedAssetTicket } from "./feed-asset-ticket.ts";

const deviceID = "f8ca8705-69c4-4c73-81fb-7bb1dc5c1853";
const thumbnailURL = "https://cdn.hqporner.com/thumb.jpg";
const videoURL = "https://cdn.hqporner.com/preview.mp4";
const result = { kind: "feed_page", page: { page: 1, hasMore: false, items: [{ id: "item-1", siteID: "hqporner", title: "Example", sourcePageURL: "https://hqporner.com/hdporn/1", thumbnailURL, previewURLs: [videoURL], uploadedAt: "2026-07-26T10:00:00Z", uploadedAtIsApproximate: false, viewCount: 1, queueCapability: "supported" }] } };

test("feed asset provenance requires an exact listed field and matching kind", () => {
  assert.equal(feedAssetAppearedInResults([result], thumbnailURL, "image"), true);
  assert.equal(feedAssetAppearedInResults([result], thumbnailURL, "video"), false);
  assert.equal(feedAssetAppearedInResults([result], videoURL, "video"), true);
  assert.equal(feedAssetAppearedInResults([result], `${thumbnailURL}?changed=1`, "image"), false);
  assert.equal(feedAssetAppearedInResults([], thumbnailURL, "image"), false);
});

test("feed asset requests require normalized credential-free HTTPS URLs", () => {
  assert.deepEqual(normalizeFeedAssetRequest({ url: thumbnailURL, kind: "image" }), { url: thumbnailURL, kind: "image" });
  assert.throws(() => normalizeFeedAssetRequest({ url: "http://cdn.hqporner.com/thumb.jpg", kind: "image" }));
  assert.throws(() => normalizeFeedAssetRequest({ url: thumbnailURL, kind: "audio" }));
});

test("feed asset tickets are scoped, expire, and reject modification", async () => {
  process.env.LUSTRE_FEED_ASSET_TOKEN_SECRET = "test-feed-asset-secret-with-at-least-thirty-two-bytes";
  const now = new Date("2026-07-26T12:00:00Z");
  const { ticket } = await issueFeedAssetTicket({ deviceID, url: thumbnailURL, kind: "image" }, now);
  const payload = await verifyFeedAssetTicket(ticket, new Date("2026-07-26T12:00:30Z"));
  assert.equal(payload.deviceID, deviceID);
  assert.equal(payload.url, thumbnailURL);
  assert.equal(payload.kind, "image");
  const parts = ticket.split(".");
  const modified = `${parts[0]}.${parts[1].replace(/^./, parts[1][0] === "a" ? "b" : "a")}.${parts[2]}`;
  await assert.rejects(verifyFeedAssetTicket(modified, new Date("2026-07-26T12:00:30Z")));
  await assert.rejects(verifyFeedAssetTicket(ticket, new Date("2026-07-26T12:01:01Z")));
});

test("ticket handler enforces recent provenance and returns no-store", async () => {
  process.env.LUSTRE_FEED_ASSET_ORIGIN = "https://assets.example";
  const calls = [];
  const handler = createFeedAssetTicketHandler({
    currentAccount: async () => ({ id: "account-1" }),
    recentResults: async (accountID, selectedDeviceID, since) => {
      calls.push({ accountID, selectedDeviceID, since });
      return [{ result }];
    },
    issueTicket: async () => ({ ticket: "signed", expiresAt: new Date("2026-07-26T12:01:00Z") }),
    now: () => new Date("2026-07-26T12:00:00Z"),
  });
  const response = await handler(new Request("http://localhost", { method: "POST", body: JSON.stringify({ url: thumbnailURL, kind: "image" }) }), deviceID);
  assert.equal(response.headers.get("cache-control"), "no-store");
  assert.deepEqual(await response.json(), { ticket: "signed", assetURL: "https://assets.example/v1/feed-assets", expiresAt: "2026-07-26T12:01:00.000Z" });
  assert.equal(calls[0].since.toISOString(), "2026-07-26T11:00:00.000Z");
  await assert.rejects(handler(new Request("http://localhost", { method: "POST", body: JSON.stringify({ url: "https://cdn.hqporner.com/unlisted.jpg", kind: "image" }) }), deviceID));
});

test("ticket handler propagates an unowned-device rejection", async () => {
  const handler = createFeedAssetTicketHandler({
    currentAccount: async () => ({ id: "account-1" }),
    recentResults: async () => { throw new Error("unowned-device"); },
  });
  await assert.rejects(
    handler(new Request("http://localhost", { method: "POST", body: JSON.stringify({ url: thumbnailURL, kind: "image" }) }), deviceID),
    /unowned-device/,
  );
});
