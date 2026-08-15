import assert from "node:assert/strict";
import test from "node:test";

import { cloudDashboardPollingDelay, cloudDashboardRefreshPaths, cloudDestinationViewNeedsRefresh, cloudDeviceIsOnline, cloudDeviceOfflineMessage, cloudFeedAcceptanceAllowed, cloudFeedCacheFreshness, cloudFeedCapabilities, cloudFeedDestinationsEnabled, cloudFeedEnabled, cloudFeedMediaEnabled, cloudFeedQueueEnabled, cloudFeedRequestKey, cloudGoogleDriveFolderListPath, coalesceCloudFeedRequest } from "./cloud-feed-ui.ts";

test("Cloud dashboard treats only fresh online presence as connected", () => {
  const online = { state: "online", lastSeenAt: "2026-07-28T12:00:00Z", agentVersion: "0.1.0" };
  assert.equal(cloudDeviceIsOnline(online), true);
  assert.equal(cloudDeviceOfflineMessage(online), null);
  for (const state of ["offline", "neverConnected", "revoked"]) {
    const presence = { ...online, state };
    assert.equal(cloudDeviceIsOnline(presence), false);
    assert.match(cloudDeviceOfflineMessage(presence), /Mount MyPassport/);
  }
});

test("Cloud Feed requires the exact server flag value true", () => {
  assert.equal(cloudFeedEnabled("true"), true);
  assert.equal(cloudFeedMediaEnabled("true"), true);
  assert.equal(cloudFeedDestinationsEnabled("true"), true);
  assert.equal(cloudFeedQueueEnabled("true"), true);
  for (const value of [undefined, "", "TRUE", "1", " true", "true "]) assert.equal(cloudFeedEnabled(value), false);
  for (const value of [undefined, "", "TRUE", "1", " true", "true "]) assert.equal(cloudFeedMediaEnabled(value), false);
  for (const value of [undefined, "", "TRUE", "1", " true", "true "]) assert.equal(cloudFeedDestinationsEnabled(value), false);
  for (const value of [undefined, "", "TRUE", "1", " true", "true "]) assert.equal(cloudFeedQueueEnabled(value), false);
});

test("Cloud Feed acceptance requires the exact flag and Clerk subject", () => {
  assert.equal(cloudFeedAcceptanceAllowed("true", "user_allowed", "user_allowed"), true);
  assert.equal(cloudFeedAcceptanceAllowed("TRUE", "user_allowed", "user_allowed"), false);
  assert.equal(cloudFeedAcceptanceAllowed("true", "user_allowed", "user_other"), false);
  assert.equal(cloudFeedAcceptanceAllowed("true", "", "user_allowed"), false);
  assert.equal(cloudFeedAcceptanceAllowed("true", undefined, "user_allowed"), false);
  assert.equal(cloudFeedAcceptanceAllowed("true", "user_allowed", null), false);
});

test("suppressed dashboard refreshes never request destinations", () => {
  assert.deepEqual(cloudDashboardRefreshPaths(true), ["/v1/jobs"]);
  assert.deepEqual(cloudDashboardRefreshPaths(false), ["/v1/jobs", "/v1/destinations"]);
});

test("dashboard polling is fast only while a transfer is active", () => {
  assert.equal(cloudDashboardPollingDelay(1, 2_000), 2_000);
  assert.equal(cloudDashboardPollingDelay(0, 2_000), 30_000);
});

test("destination snapshots load on the Destinations view and enabled Feed", () => {
  assert.equal(cloudDestinationViewNeedsRefresh("Destinations", false), true);
  assert.equal(cloudDestinationViewNeedsRefresh("Feed", true), true);
  assert.equal(cloudDestinationViewNeedsRefresh("Feed", false), false);
  assert.equal(cloudDestinationViewNeedsRefresh("Dashboard", true), false);
});

test("Google Drive folder-list paths do not collide with folder-selection paths", () => {
  assert.equal(cloudGoogleDriveFolderListPath("/v1/destinations/profile-id/google-drive/folders?path=%2F"), true);
  assert.equal(cloudGoogleDriveFolderListPath("/v1/destinations/profile-id/google-drive/folder"), false);
  assert.equal(cloudGoogleDriveFolderListPath("/v1/destinations/profile-id/google-drive/folders"), false);
});

test("Cloud Feed request keys normalize query whitespace and include device and page", () => {
  const first = cloudFeedRequestKey({ deviceID: "device-a", kind: "feed_page", siteID: "hqporner", query: " newest   clips ", page: 2 });
  const identical = cloudFeedRequestKey({ deviceID: "device-a", kind: "feed_page", siteID: "hqporner", query: "newest clips", page: 2 });
  assert.equal(first, identical);
  assert.notEqual(first, cloudFeedRequestKey({ deviceID: "device-b", kind: "feed_page", siteID: "hqporner", query: "newest clips", page: 2 }));
  assert.notEqual(first, cloudFeedRequestKey({ deviceID: "device-a", kind: "feed_page", siteID: "hqporner", query: "newest clips", page: 3 }));
});

test("identical in-flight Feed requests share one promise and clear after settlement", async () => {
  const requests = new Map();
  let calls = 0;
  let resolve;
  const operation = () => {
    calls += 1;
    return new Promise((next) => { resolve = next; });
  };
  const first = coalesceCloudFeedRequest(requests, "same", operation);
  const second = coalesceCloudFeedRequest(requests, "same", operation);
  assert.equal(first, second);
  assert.equal(calls, 1);
  resolve("done");
  assert.equal(await first, "done");
  await Promise.resolve();
  const third = coalesceCloudFeedRequest(requests, "same", async () => "again");
  assert.notEqual(third, first);
  assert.equal(await third, "again");
});

test("Feed cache freshness uses exact five and sixty minute tiers", () => {
  const now = Date.parse("2026-07-27T02:00:00Z");
  assert.equal(cloudFeedCacheFreshness(new Date(now - 5 * 60_000), now), "fresh");
  assert.equal(cloudFeedCacheFreshness(new Date(now - 5 * 60_000 - 1), now), "stale");
  assert.equal(cloudFeedCacheFreshness(new Date(now - 60 * 60_000), now), "stale");
  assert.equal(cloudFeedCacheFreshness(new Date(now - 60 * 60_000 - 1), now), null);
  assert.equal(cloudFeedCacheFreshness(new Date(now + 1), now), null);
});

test("K1 capabilities prevent media loading and every queue interaction", () => {
  assert.deepEqual(cloudFeedCapabilities(false, false, false), { loadMedia: false, chooseDestination: false, selectItems: false, queueItems: false });
  assert.deepEqual(cloudFeedCapabilities(true, true, true), { loadMedia: true, chooseDestination: true, selectItems: true, queueItems: true });
});

test("K4 enables individual and multi-item queueing together", () => {
  assert.deepEqual(cloudFeedCapabilities(true, true, true), { loadMedia: true, chooseDestination: true, selectItems: true, queueItems: true });
});

test("K3 enables destination choice without enabling selection or queueing", () => {
  assert.deepEqual(cloudFeedCapabilities(false, true, false), { loadMedia: false, chooseDestination: true, selectItems: false, queueItems: false });
  const destinationsKey = cloudFeedRequestKey({ deviceID: "device-a", kind: "destinations_list" });
  assert.equal(destinationsKey, cloudFeedRequestKey({ deviceID: "device-a", kind: "destinations_list" }));
});
