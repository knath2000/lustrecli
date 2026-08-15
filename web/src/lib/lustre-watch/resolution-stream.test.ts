import assert from "node:assert/strict";
import test from "node:test";
import { readResolutionStream } from "./resolution-stream.ts";

const at = "2026-08-13T12:00:00.000Z";

test("reads NDJSON events across arbitrary chunks", async () => {
  const payload = [
    JSON.stringify({ type: "started", at, provider: "HQPorner", message: "Starting." }),
    JSON.stringify({ type: "validating", at, message: "Validating." }),
  ].join("\n") + "\n";
  const bytes = new TextEncoder().encode(payload);
  const response = new Response(new ReadableStream({
    start(controller) {
      controller.enqueue(bytes.slice(0, 17));
      controller.enqueue(bytes.slice(17, 63));
      controller.enqueue(bytes.slice(63));
      controller.close();
    },
  }));
  const events: string[] = [];
  assert.equal(await readResolutionStream(response, (event) => events.push(event.type)), 2);
  assert.deepEqual(events, ["started", "validating"]);
});

test("rejects malformed or unbounded progress events", async () => {
  const response = new Response(`${JSON.stringify({ type: "provider_started", at, provider: "x".repeat(81), message: "Starting." })}\n`);
  await assert.rejects(() => readResolutionStream(response, () => {}));
});
