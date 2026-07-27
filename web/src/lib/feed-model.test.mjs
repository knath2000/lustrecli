import assert from "node:assert/strict";
import test from "node:test";

import { feedPreviewDelay, feedPreviewFrames, feedPreviewMediaKind, feedTransferState, feedUsesAuthenticatedAssetProxy, initialFeedSite, queueFeedItems, toggleFeedSelection } from "./feed-model.ts";

const alpha = { id: "alpha", sourcePageURL: "https://allpornstream.com/post/alpha" };
const beta = { id: "beta", sourcePageURL: "https://allpornstream.com/post/beta" };

test("initialFeedSite prefers the stable HQPorner metadata source", () => {
  const sites = [
    { id: "allpornstream", displayName: "AllPornStream", homeURL: "https://allpornstream.com", supportsSearch: true },
    { id: "hqporner", displayName: "HQPorner", homeURL: "https://hqporner.com", supportsSearch: true },
  ];
  assert.equal(initialFeedSite(sites)?.id, "hqporner");
  assert.equal(initialFeedSite(sites.slice(0, 1))?.id, "allpornstream");
  assert.equal(initialFeedSite([]), undefined);
});

test("toggleFeedSelection adds and removes stable item ids", () => {
  assert.deepEqual([...toggleFeedSelection(new Set(), alpha.id)], ["alpha"]);
  assert.deepEqual([...toggleFeedSelection(new Set(["alpha", "beta"]), alpha.id)], ["beta"]);
});

test("feedPreviewFrames prefers unique scene thumbnails and falls back to the card thumbnail", () => {
  assert.deepEqual(
    feedPreviewFrames({ thumbnailURL: "thumb.jpg", previewURLs: ["scene-1.jpg", "scene-2.jpg", "scene-1.jpg", "scene-3.jpg", "scene-4.jpg", "scene-5.jpg", ""] }),
    ["scene-1.jpg", "scene-2.jpg", "scene-3.jpg", "scene-4.jpg"],
  );
  assert.deepEqual(feedPreviewFrames({ thumbnailURL: "thumb.jpg", previewURLs: [] }), ["thumb.jpg"]);
  assert.deepEqual(feedPreviewFrames({ previewURLs: [] }), []);
});

test("feedPreviewDelay rotates multi-frame previews whenever the user is hovering", () => {
  assert.equal(feedPreviewDelay(false, 4), null);
  assert.equal(feedPreviewDelay(true, 1), null);
  assert.equal(feedPreviewDelay(true, 4), 800);
});

test("feedPreviewMediaKind keeps video previews out of image elements", () => {
  assert.equal(feedPreviewMediaKind("https://di.phncdn.com/preview.webm?token=one"), "video");
  assert.equal(feedPreviewMediaKind("https://img.hqporner.com/scene-1.jpg"), "image");
});

test("feedUsesAuthenticatedAssetProxy keeps non-PornHub feeds in the browser", () => {
  assert.equal(feedUsesAuthenticatedAssetProxy("pornhub"), true);
  assert.equal(feedUsesAuthenticatedAssetProxy("pornhub-liked"), true);
  assert.equal(feedUsesAuthenticatedAssetProxy("hqporner"), true);
  assert.equal(feedUsesAuthenticatedAssetProxy("allpornstream"), false);
  assert.equal(feedUsesAuthenticatedAssetProxy("onlyfan420"), false);
});

test("feedTransferState prefers active jobs over completed history", () => {
  const jobs = [
    { sourcePageURL: alpha.sourcePageURL, status: "completed" },
    { sourcePageURL: `${alpha.sourcePageURL}#details`, status: "running" },
  ];
  assert.equal(feedTransferState(alpha.sourcePageURL, jobs), "running");
  assert.equal(feedTransferState(beta.sourcePageURL, jobs), "available");
});

test("queueFeedItems bounds concurrent queue requests and reports each failure", async () => {
  let active = 0;
  let maximumActive = 0;
  const results = await queueFeedItems(
    Array.from({ length: 7 }, (_, index) => ({ id: String(index), sourcePageURL: `https://allpornstream.com/post/${index}` })),
    async (item) => {
      active += 1;
      maximumActive = Math.max(maximumActive, active);
      await new Promise((resolve) => setTimeout(resolve, 5));
      active -= 1;
      if (item.id === "4") throw new Error("rejected");
    },
    3,
  );

  assert.equal(maximumActive, 3);
  assert.deepEqual(results.filter((result) => !result.ok).map((result) => result.id), ["4"]);
  assert.equal(results.length, 7);
});
