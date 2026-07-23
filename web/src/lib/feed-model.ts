export type FeedSite = {
  id: "allpornstream";
  displayName: string;
  homeURL: string;
  supportsSearch: boolean;
};

export type FeedItem = {
  id: string;
  siteID: FeedSite["id"];
  title: string;
  sourcePageURL: string;
  thumbnailURL?: string;
  previewURLs: string[];
  uploadedAt: string | number;
  uploadedAtIsApproximate: boolean;
  viewCount: number;
  studio?: string;
  queueCapability: "supported";
};

export type FeedPage = { items: FeedItem[]; page: number; hasMore: boolean };
export type FeedTransferState = "available" | "queued" | "running" | "paused" | "completed" | "failed" | "cancelled" | "verificationRequired";

type FeedItemIdentity = Pick<FeedItem, "id" | "sourcePageURL">;
type FeedJob = { sourcePageURL: string; status: Exclude<FeedTransferState, "available"> };

const transferPriority: FeedJob["status"][] = ["running", "queued", "paused", "verificationRequired", "failed", "completed", "cancelled"];

function normalizedSourceURL(value: string): string {
  try {
    const url = new URL(value);
    url.hash = "";
    return url.href;
  } catch {
    return value.trim();
  }
}

export function feedPreviewFrames(item: Pick<FeedItem, "thumbnailURL" | "previewURLs">): string[] {
  const previews = [...new Set(item.previewURLs.map((url) => url.trim()).filter(Boolean))].slice(0, 4);
  if (previews.length) return previews;
  const thumbnail = item.thumbnailURL?.trim();
  return thumbnail ? [thumbnail] : [];
}

export function feedPreviewDelay(hovered: boolean, frameCount: number): number | null {
  return hovered && frameCount > 1 ? 800 : null;
}

export function toggleFeedSelection(selection: Set<string>, id: string): Set<string> {
  const next = new Set(selection);
  if (next.has(id)) next.delete(id);
  else next.add(id);
  return next;
}

export function feedTransferState(sourcePageURL: string, jobs: FeedJob[]): FeedTransferState {
  const source = normalizedSourceURL(sourcePageURL);
  const statuses = new Set(jobs.filter((job) => normalizedSourceURL(job.sourcePageURL) === source).map((job) => job.status));
  return transferPriority.find((status) => statuses.has(status)) ?? "available";
}

export async function queueFeedItems<T extends FeedItemIdentity>(
  items: T[],
  queue: (item: T) => Promise<void>,
  concurrency = 3,
): Promise<Array<{ id: string; ok: boolean; error?: string }>> {
  const results: Array<{ id: string; ok: boolean; error?: string } | undefined> = Array(items.length);
  let nextIndex = 0;
  const workerCount = Math.min(Math.max(1, Math.floor(concurrency)), items.length);

  await Promise.all(Array.from({ length: workerCount }, async () => {
    while (nextIndex < items.length) {
      const index = nextIndex;
      nextIndex += 1;
      const item = items[index];
      try {
        await queue(item);
        results[index] = { id: item.id, ok: true };
      } catch (reason) {
        results[index] = { id: item.id, ok: false, error: reason instanceof Error ? reason.message : "Queue request failed." };
      }
    }
  }));

  return results.filter((result): result is { id: string; ok: boolean; error?: string } => result !== undefined);
}
