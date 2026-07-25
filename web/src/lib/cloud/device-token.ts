import "server-only";
import { SignJWT, jwtVerify } from "jose";
const audience = () => process.env.LUSTRE_CLOUD_ORIGIN ?? "http://localhost:3000";
const key = () => new TextEncoder().encode(process.env.LUSTRE_DEVICE_TOKEN_SECRET ?? "");
export async function issueDeviceToken(deviceID: string, accountID: string) {
  if (!process.env.LUSTRE_DEVICE_TOKEN_SECRET) throw new Error("LUSTRE_DEVICE_TOKEN_SECRET is not configured.");
  return new SignJWT({ accountID, version: 1, use: "realtime" }).setProtectedHeader({ alg: "HS256" }).setSubject(deviceID).setAudience(audience()).setJti(crypto.randomUUID()).setIssuedAt().setExpirationTime("10m").sign(key());
}
export async function verifyDeviceToken(token: string) { const result = await jwtVerify(token, key(), { audience: audience() }); if (result.payload.use !== "realtime" || typeof result.payload.accountID !== "string" || !result.payload.sub) throw new Error("Invalid realtime token."); return result; }
