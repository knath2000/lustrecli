import assert from "node:assert/strict";
import test from "node:test";
import { normalizeWatchlistQueueCommand } from "./watchlist-queue.ts";

const watchlistID = "f8ca8705-69c4-4c73-81fb-7bb1dc5c1853";
const requestID = "88e5c12c-43a1-4b17-ae2a-4231c3644ff8";

test("Watchlist queue commands contain only account-owned lookup inputs", () => {
  assert.deepEqual(
    normalizeWatchlistQueueCommand({ kind: "watchlist_queue", watchlistID, requestID, destination: "local" }),
    { watchlistID, requestID, destination: "local" },
  );
});

test("Watchlist queue commands reject synthetic Feed fields and invalid destinations", () => {
  assert.throws(() => normalizeWatchlistQueueCommand({ kind: "watchlist_queue", watchlistID, requestID, destination: "local", sourcePageURL: "https://example.com/video" }));
  assert.throws(() => normalizeWatchlistQueueCommand({ kind: "watchlist_queue", watchlistID, requestID, destination: "webdav:anything" }));
  assert.throws(() => normalizeWatchlistQueueCommand({ kind: "watchlist_queue", watchlistID: "feed-item", requestID, destination: "local" }));
});
