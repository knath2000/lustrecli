const encoder = new TextEncoder();

function decodeBase64URL(value: string): Uint8Array | null {
  if (!/^[A-Za-z0-9_-]{43}$/.test(value)) return null;
  try {
    const normalized = value.replaceAll("-", "+").replaceAll("_", "/") + "=";
    return Uint8Array.from(atob(normalized), (character) => character.charCodeAt(0));
  } catch {
    return null;
  }
}

export async function validTicket(url: string, expires: string, signature: string, secret: string, now = Date.now()): Promise<boolean> {
  const expiry = Number(expires);
  if (!Number.isSafeInteger(expiry) || expiry < now || expiry > now + 90_000 || secret.length < 32) return false;
  const bytes = decodeBase64URL(signature);
  if (!bytes) return false;
  const key = await crypto.subtle.importKey("raw", encoder.encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["verify"]);
  return crypto.subtle.verify("HMAC", key, new Uint8Array(bytes), encoder.encode(`${url}\n${expires}`));
}

export function safeAssetURL(value: string): URL | null {
  let url: URL;
  try { url = new URL(value); } catch { return null; }
  if (url.protocol !== "https:" || url.username || url.password || url.port) return null;
  const host = url.hostname.toLowerCase().replace(/\.$/, "");
  if (host === "localhost" || host.endsWith(".localhost") || host.endsWith(".local") || host.endsWith(".internal")) return null;
  const octets = host.split(".").map(Number);
  if (octets.length === 4 && octets.every((octet) => Number.isInteger(octet) && octet >= 0 && octet <= 255)) {
    if (octets[0] === 0 || octets[0] === 10 || octets[0] === 127 || octets[0]! >= 224 || (octets[0] === 169 && octets[1] === 254) || (octets[0] === 172 && octets[1]! >= 16 && octets[1]! <= 31) || (octets[0] === 192 && octets[1] === 168)) return null;
  }
  if (host.includes(":")) return null;
  return url;
}

export function assetReferer(url: URL): string {
  const host = url.hostname.toLowerCase();
  return host === "phncdn.com" || host.endsWith(".phncdn.com") ? "https://www.pornhub.com/" : `${url.origin}/`;
}
