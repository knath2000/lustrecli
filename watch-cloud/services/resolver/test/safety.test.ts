import assert from "node:assert/strict";
import test from "node:test";
import { isPublicAddress, parseSupportedURL } from "../src/safety";

test("blocks private, loopback, link-local, metadata, and documentation IPs", () => {
  for (const address of ["127.0.0.1", "10.0.0.1", "169.254.169.254", "172.16.0.1", "192.168.1.1", "192.0.2.1", "::1", "fd00::1", "fe80::1"]) {
    assert.equal(isPublicAddress(address), false, address);
  }
  assert.equal(isPublicAddress("8.8.8.8"), true);
  assert.equal(isPublicAddress("2606:4700:4700::1111"), true);
});

test("source URLs require credential-free HTTPS and supported hosts", () => {
  assert.equal(parseSupportedURL("https://hqporner.com/hdporn/1").hostname, "hqporner.com");
  assert.throws(() => parseSupportedURL("http://hqporner.com/hdporn/1"));
  assert.throws(() => parseSupportedURL("https://user:pass@hqporner.com/hdporn/1"));
  assert.throws(() => parseSupportedURL("https://hqporner.com.evil.example/hdporn/1"));
});
