import assert from "node:assert/strict";
import crypto from "node:crypto";
import test from "node:test";
import { assetReferer, safeAssetURL, validTicket } from "../src/ticket";

test("asset tickets are exact, scoped, and expire", async () => {
  const secret = "test-secret-with-at-least-thirty-two-bytes";
  const url = "https://cdn.example/thumb.jpg";
  const expires = String(Date.now() + 60_000);
  const signature = crypto.createHmac("sha256", secret).update(`${url}\n${expires}`).digest("base64url");
  assert.equal(await validTicket(url, expires, signature, secret), true);
  assert.equal(await validTicket(`${url}?changed=1`, expires, signature, secret), false);
  assert.equal(await validTicket(url, String(Date.now() - 1), signature, secret), false);
});

test("asset URL validation rejects credentials and local destinations", () => {
  assert.equal(safeAssetURL("https://cdn.example/thumb.jpg")?.hostname, "cdn.example");
  for (const value of ["http://cdn.example/a.jpg", "https://user:pass@cdn.example/a.jpg", "https://127.0.0.1/a.jpg", "https://169.254.169.254/latest", "https://service.internal/a.jpg", "https://[::1]/a.jpg"]) {
    assert.equal(safeAssetURL(value), null, value);
  }
});

test("asset referers preserve provider hotlink requirements", () => {
  assert.equal(assetReferer(new URL("https://pix-cdn77.phncdn.com/thumb.jpg")), "https://www.pornhub.com/");
  assert.equal(assetReferer(new URL("https://images.example/thumb.jpg")), "https://images.example/");
});
