import assert from "node:assert/strict";
import test from "node:test";
import { copyText } from "./clipboard";

test("copies the exact source URL and supports repeated copies", async () => {
  const copied: string[] = [];
  const clipboard = {
    async writeText(value: string) {
      copied.push(value);
    },
  };
  const sourcePageURL = "https://vidara.so/v/Fr5jKe2grT2tU?ref=watchlist";

  await copyText(sourcePageURL, clipboard);
  await copyText(sourcePageURL, clipboard);

  assert.deepEqual(copied, [sourcePageURL, sourcePageURL]);
});

test("surfaces clipboard rejection", async () => {
  const failure = new Error("Clipboard access denied");
  const clipboard = {
    async writeText() {
      throw failure;
    },
  };

  await assert.rejects(copyText("https://example.com/source", clipboard), failure);
});
