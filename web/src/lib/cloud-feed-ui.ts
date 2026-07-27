export type CloudFeedCommandKind = "feed_sites" | "feed_page" | "destinations_list";

export function cloudFeedEnabled(value: string | undefined): boolean {
  return value === "true";
}

export function cloudFeedMediaEnabled(value: string | undefined): boolean {
  return value === "true";
}

export function cloudFeedDestinationsEnabled(value: string | undefined): boolean {
  return value === "true";
}

export function cloudFeedQueueEnabled(value: string | undefined): boolean {
  return value === "true";
}

export function cloudFeedAcceptanceAllowed(
  enabled: string | undefined,
  expectedSubject: string | undefined,
  userID: string | null | undefined,
): boolean {
  return enabled === "true" && typeof expectedSubject === "string" && expectedSubject.length > 0 && userID === expectedSubject;
}

export function cloudDashboardRefreshPaths(suppressDestinationPolling: boolean): Array<"/v1/jobs" | "/v1/destinations"> {
  return suppressDestinationPolling ? ["/v1/jobs"] : ["/v1/jobs", "/v1/destinations"];
}

export function normalizeCloudFeedQuery(value: string | undefined): string {
  return value?.trim().replace(/\s+/g, " ") ?? "";
}

export function cloudFeedRequestKey(input: {
  deviceID: string;
  kind: CloudFeedCommandKind;
  siteID?: string;
  query?: string;
  page?: number;
}): string {
  return JSON.stringify([input.deviceID, input.kind, input.siteID ?? "", normalizeCloudFeedQuery(input.query), input.page ?? 0]);
}

export function coalesceCloudFeedRequest<T>(
  requests: Map<string, Promise<unknown>>,
  key: string,
  operation: () => Promise<T>,
): Promise<T> {
  const existing = requests.get(key);
  if (existing) return existing as Promise<T>;
  const promise = operation();
  requests.set(key, promise);
  void promise.finally(() => {
    if (requests.get(key) === promise) requests.delete(key);
  }).catch(() => undefined);
  return promise;
}

export function cloudFeedCapabilities(mediaEnabled: boolean, destinationsEnabled: boolean, queueEnabled: boolean) {
  return { loadMedia: mediaEnabled, chooseDestination: destinationsEnabled, selectItems: false, queueItems: queueEnabled };
}
