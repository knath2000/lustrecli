import dns from "node:dns/promises";
import net from "node:net";
import { ResolverError } from "@lustre/contracts";
import { hostMatches, supportedSourceHosts } from "@lustre/providers";

const forbiddenV4 = [
  ["0.0.0.0", 8], ["10.0.0.0", 8], ["100.64.0.0", 10], ["127.0.0.0", 8],
  ["169.254.0.0", 16], ["172.16.0.0", 12], ["192.0.0.0", 24], ["192.0.2.0", 24],
  ["192.168.0.0", 16], ["198.18.0.0", 15], ["198.51.100.0", 24], ["203.0.113.0", 24],
  ["224.0.0.0", 4], ["240.0.0.0", 4],
] as const;

function ipv4Number(address: string): number {
  return address.split(".").reduce((value, octet) => (value << 8) + Number(octet), 0) >>> 0;
}

export function isPublicAddress(address: string): boolean {
  const family = net.isIP(address);
  if (family === 4) {
    const value = ipv4Number(address);
    return !forbiddenV4.some(([network, bits]) => {
      const mask = (0xffffffff << (32 - bits)) >>> 0;
      return (value & mask) === (ipv4Number(network) & mask);
    });
  }
  if (family !== 6) return false;
  const normalized = address.toLowerCase();
  if (normalized === "::" || normalized === "::1" || normalized.startsWith("fc") || normalized.startsWith("fd") || normalized.startsWith("fe8") || normalized.startsWith("fe9") || normalized.startsWith("fea") || normalized.startsWith("feb")) return false;
  const mapped = normalized.match(/^::ffff:(\d+\.\d+\.\d+\.\d+)$/)?.[1];
  return mapped ? isPublicAddress(mapped) : true;
}

export function parseSupportedURL(value: string): URL {
  const url = parsePublicHTTPSURL(value);
  if (!hostMatches(url.hostname, supportedSourceHosts)) throw new ResolverError("unsupported_provider", "This provider is not supported.", 422);
  return url;
}

export function parsePublicHTTPSURL(value: string): URL {
  let url: URL;
  try { url = new URL(value); } catch { throw new ResolverError("invalid_request", "A valid URL is required.", 400); }
  if (url.protocol !== "https:" || url.username || url.password || url.port) throw new ResolverError("invalid_request", "Only credential-free HTTPS URLs on standard ports are accepted.", 400);
  return url;
}

export async function assertPublicDNS(url: URL): Promise<void> {
  const addresses = await dns.lookup(url.hostname, { all: true, verbatim: true });
  if (!addresses.length || addresses.some(({ address }) => !isPublicAddress(address))) {
    throw new ResolverError("invalid_request", "The URL resolves to a non-public address.", 400);
  }
}

export type SafeRequest = {
  method?: "GET" | "POST";
  headers?: Record<string, string>;
  body?: string;
  maxBytes?: number;
  redirectPolicy?: "supported-source" | "same-host";
};

export type SafeResponse = { body: string; finalURL: URL; status: number; contentType: string };

export async function safeRequest(input: URL, options: SafeRequest = {}): Promise<SafeResponse> {
  let current = input;
  const method = options.method ?? "GET";
  const maxBytes = options.maxBytes ?? 2_000_000;
  for (let redirects = 0; redirects <= 4; redirects += 1) {
    await assertPublicDNS(current);
    const response = await fetch(current, {
      method,
      headers: options.headers,
      body: method === "POST" ? options.body : undefined,
      redirect: "manual",
      signal: AbortSignal.timeout(20_000),
    });
    if ([301, 302, 303, 307, 308].includes(response.status)) {
      const location = response.headers.get("location");
      if (!location || redirects === 4) throw new ResolverError("provider_changed", "Provider returned an invalid redirect.");
      const next = options.redirectPolicy === "same-host"
        ? parsePublicHTTPSURL(new URL(location, current).href)
        : parseSupportedURL(new URL(location, current).href);
      if (options.redirectPolicy === "same-host" && next.hostname !== current.hostname) {
        throw new ResolverError("provider_changed", "Provider returned an unsafe cross-host redirect.");
      }
      current = next;
      continue;
    }
    const reader = response.body?.getReader();
    if (!reader) return { body: "", finalURL: current, status: response.status, contentType: response.headers.get("content-type") ?? "" };
    const chunks: Uint8Array[] = [];
    let length = 0;
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      length += value.byteLength;
      if (length > maxBytes) {
        await reader.cancel();
        throw new ResolverError("provider_changed", "Provider response exceeded the size limit.");
      }
      chunks.push(value);
    }
    return {
      body: new TextDecoder().decode(Buffer.concat(chunks)),
      finalURL: current,
      status: response.status,
      contentType: response.headers.get("content-type") ?? "",
    };
  }
  throw new ResolverError("provider_changed", "Provider returned too many redirects.");
}

export async function safeFetch(input: URL, headers: Record<string, string> = {}, maxBytes = 2_000_000): Promise<SafeResponse> {
  return safeRequest(input, { headers, maxBytes });
}
