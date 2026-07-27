import "server-only";
import { createHmac } from "node:crypto";

export async function notifyCommandWake(deviceID: string, commandID: string) {
  if (process.env.LUSTRE_COMMAND_WAKE_ENABLED !== "true") return;
  const origin = process.env.LUSTRE_GATEWAY_ORIGIN;
  const secret = process.env.LUSTRE_GATEWAY_CONTROL_SECRET;
  if (!origin || !secret) return;
  const body = JSON.stringify({ version: 1, deviceID, commandID });
  const timestamp = String(Date.now());
  const signature = createHmac("sha256", secret).update(`${timestamp}.${body}`).digest("hex");
  const signal = AbortSignal.timeout(2_000);
  try {
    await fetch(new URL("/control/command-wake", origin), {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "X-Lustre-Control-Timestamp": timestamp,
        "X-Lustre-Control-Signature": signature,
      },
      body,
      cache: "no-store",
      signal,
    });
  } catch {}
}
