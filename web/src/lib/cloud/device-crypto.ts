import { createHash, createHmac, randomBytes, timingSafeEqual, verify } from "node:crypto";
import { DEVICE_PROTOCOL_VERSION } from "./device-contract";

const p256SPKIPrefix = Buffer.from("3059301306072a8648ce3d020106082a8648ce3d030107034200", "hex");
const crockford = "0123456789ABCDEFGHJKMNPQRSTVWXYZ";

function field(value: Uint8Array | string): Buffer {
  const bytes = typeof value === "string" ? Buffer.from(value, "utf8") : Buffer.from(value);
  const length = Buffer.allocUnsafe(4); length.writeUInt32BE(bytes.length);
  return Buffer.concat([length, bytes]);
}

export function canonicalEnvelope(input: { purpose: "enrollment" | "session"; audience: string; subjectID: string; nonce: string; thumbprint: string; expiresAt: string }): Buffer {
  const nonce = Buffer.from(input.nonce, "base64");
  return Buffer.concat([
    field("LUSTRE-CLOUD-DEVICE-V1"), field(String(DEVICE_PROTOCOL_VERSION)), field(input.purpose),
    field(input.audience), field(input.subjectID), field(nonce), field(input.thumbprint), field(input.expiresAt),
  ]);
}

export function publicKeyThumbprint(publicKey: Uint8Array): string { return createHash("sha256").update(publicKey).digest("base64url"); }
export function p256SPKI(point: Uint8Array): Buffer {
  if (point.length !== 65 || point[0] !== 4) throw new Error("Invalid P-256 public key.");
  return Buffer.concat([p256SPKIPrefix, point]);
}
export function verifyP256Signature(publicKeyPoint: Uint8Array, envelope: Uint8Array, signature: Uint8Array): boolean {
  return verify("sha256", envelope, { key: p256SPKI(publicKeyPoint), format: "der", type: "spki", dsaEncoding: "der" }, signature);
}
export function pairingCode(): string {
  const bits = randomBytes(20);
  const code = Array.from(bits, (byte) => crockford[byte & 31]).join("");
  return code.match(/.{1,5}/g)!.join("-");
}
export function secretHash(value: string): string {
  const pepper = process.env.LUSTRE_PAIRING_PEPPER;
  if (!pepper) throw new Error("LUSTRE_PAIRING_PEPPER is not configured.");
  return createHmac("sha256", pepper).update(value).digest("base64url");
}
export function hashesEqual(left: string, right: string): boolean {
  const leftBytes = Buffer.from(left); const rightBytes = Buffer.from(right);
  return leftBytes.length === rightBytes.length && timingSafeEqual(leftBytes, rightBytes);
}
export function randomNonce(): string { return randomBytes(32).toString("base64"); }
