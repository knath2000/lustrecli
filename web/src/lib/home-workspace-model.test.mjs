import assert from "node:assert/strict";
import test from "node:test";

import { previewCommandURLLimit, previewURLBatches } from "./home-workspace-model.ts";

test("previewURLBatches accepts an arbitrary queue and preserves input order", () => {
  const urls = Array.from({ length: 42 }, (_, index) => `https://example.com/video/${index + 1}`);
  const batches = previewURLBatches(urls);

  assert.equal(previewCommandURLLimit, 10);
  assert.deepEqual(batches.map((batch) => batch.length), [10, 10, 10, 10, 2]);
  assert.deepEqual(batches.flat(), urls);
});

test("previewURLBatches handles empty and small submissions", () => {
  assert.deepEqual(previewURLBatches([]), []);
  assert.deepEqual(previewURLBatches(["https://example.com/video"]), [["https://example.com/video"]]);
});
