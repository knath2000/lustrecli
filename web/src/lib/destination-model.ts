type DestinationJob = { destination: string };

export function destinationUsageCounts(jobs: DestinationJob[]): Record<string, number> {
  const counts: Record<string, number> = { local: 0 };
  for (const job of jobs) {
    const match = /^webdav:(.+)$/i.exec(job.destination);
    const key = match ? match[1].toLowerCase() : "local";
    counts[key] = (counts[key] ?? 0) + 1;
  }
  return counts;
}

export function safeDestinationHost(baseURL: string): string {
  try {
    const url = new URL(baseURL);
    return url.protocol === "https:" && url.host ? url.host : "Invalid endpoint";
  } catch {
    return "Invalid endpoint";
  }
}

export function destinationSecurityLabel(allowInvalidCertificate: boolean): string {
  return allowInvalidCertificate ? "Certificate exception enabled" : "Strict TLS validation";
}
