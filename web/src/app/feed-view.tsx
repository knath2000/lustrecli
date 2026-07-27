"use client";

import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { agentDateMilliseconds } from "@/lib/agent-date";
import {
  feedPreviewDelay,
  feedPreviewFrames,
  feedPreviewMediaKind,
  feedTransferState,
  feedUsesAuthenticatedAssetProxy,
  initialFeedSite,
  type FeedItem,
  type FeedPage,
  type FeedQuery,
  type FeedSite,
} from "@/lib/feed-model";
import type { DestinationProfile } from "./destinations-view";

export type FeedJob = {
  sourcePageURL: string;
  status:
    | "queued"
    | "running"
    | "paused"
    | "completed"
    | "failed"
    | "cancelled"
    | "verificationRequired";
};

type FeedViewProps = {
  destinations: DestinationProfile[];
  jobs: FeedJob[];
  loadSites: () => Promise<FeedSite[]>;
  loadPage: (site: FeedSite["id"], query: FeedQuery) => Promise<FeedPage>;
  queueItem: (item: FeedItem, destination: string, requestID: string) => Promise<void>;
  loadAsset: (url: string, kind: "image" | "video") => Promise<Blob>;
  onQueued: () => Promise<void>;
  mediaEnabled: boolean;
  destinationsEnabled?: boolean;
  queueEnabled: boolean;
};

function compactNumber(value: number) {
  return new Intl.NumberFormat(undefined, {
    notation: "compact",
    maximumFractionDigits: 1,
  }).format(value);
}

function FeedThumbnail({
  item,
  loadAsset,
}: {
  item: FeedItem;
  loadAsset: FeedViewProps["loadAsset"];
}) {
  const frames = useMemo(
    () => (item.previewURLs.length ? feedPreviewFrames(item) : []),
    [item],
  );
  const usesAssetProxy = feedUsesAuthenticatedAssetProxy(item.siteID);
  const assetCache = useRef(new Map<string, Blob | Promise<Blob>>());
  const [hovered, setHovered] = useState(false);
  const [frameIndex, setFrameIndex] = useState(0);
  const [thumbnail, setThumbnail] = useState<{
    url: string;
    source: string;
  } | null>(null);
  const [preview, setPreview] = useState<{
    url: string;
    source: string;
  } | null>(null);
  const [failedThumbnailURL, setFailedThumbnailURL] = useState<string | null>(
    null,
  );
  const [failedFrames, setFailedFrames] = useState<{
    itemID: string;
    urls: Set<string>;
  }>({ itemID: item.id, urls: new Set() });
  const usableFrames = frames.filter(
    (frame) => failedFrames.itemID !== item.id || !failedFrames.urls.has(frame),
  );
  const frame = hovered
    ? usableFrames[frameIndex % Math.max(usableFrames.length, 1)]
    : undefined;
  const frameKind = frame ? feedPreviewMediaKind(frame) : "image";
  const previewSource =
    frame && hovered
      ? usesAssetProxy
        ? preview?.url === frame
          ? preview.source
          : null
        : frame
      : null;
  const visibleVideo =
    previewSource && frameKind === "video" ? previewSource : null;
  const visiblePreviewImage =
    previewSource && frameKind === "image" ? previewSource : null;
  const proxiedThumbnail =
    thumbnail?.url === item.thumbnailURL ? thumbnail : null;
  const visibleThumbnail =
    failedThumbnailURL === item.thumbnailURL
      ? null
      : usesAssetProxy
        ? (proxiedThumbnail?.source ?? null)
        : (item.thumbnailURL ?? null);
  const visibleImage = visiblePreviewImage ?? visibleThumbnail;

  useEffect(() => {
    let active = true;
    if (!usesAssetProxy || !item.thumbnailURL) return undefined;
    const cached = assetCache.current.get(item.thumbnailURL);
    const request =
      cached instanceof Blob
        ? Promise.resolve(cached)
        : (cached ??
          loadAsset(item.thumbnailURL, "image").then((blob) => {
            assetCache.current.set(item.thumbnailURL!, blob);
            return blob;
          }));
    if (!cached) assetCache.current.set(item.thumbnailURL, request);
    void request
      .then((blob) => {
        if (active)
          setThumbnail({
            url: item.thumbnailURL!,
            source: URL.createObjectURL(blob),
          });
      })
      .catch(() => {
        if (active) setFailedThumbnailURL(item.thumbnailURL!);
      });
    return () => {
      active = false;
    };
  }, [item.thumbnailURL, loadAsset, usesAssetProxy]);

  useEffect(() => {
    let active = true;
    if (!usesAssetProxy || !frame) return undefined;
    const cached = assetCache.current.get(frame);
    const request =
      cached instanceof Blob
        ? Promise.resolve(cached)
        : (cached ??
          loadAsset(frame, frameKind).then((blob) => {
            assetCache.current.set(frame, blob);
            return blob;
          }));
    if (!cached) assetCache.current.set(frame, request);
    void request
      .then((blob) => {
        if (active)
          setPreview({ url: frame, source: URL.createObjectURL(blob) });
      })
      .catch(() => {
        if (active)
          setFailedFrames((current) => ({
            itemID: item.id,
            urls: new Set(current.itemID === item.id ? current.urls : []).add(
              frame,
            ),
          }));
      });
    return () => {
      active = false;
    };
  }, [frame, frameKind, item.id, loadAsset, usesAssetProxy]);

  useEffect(
    () => () => {
      if (thumbnail) URL.revokeObjectURL(thumbnail.source);
    },
    [thumbnail],
  );

  useEffect(
    () => () => {
      if (preview) URL.revokeObjectURL(preview.source);
    },
    [preview],
  );

  useEffect(() => {
    const delay = feedPreviewDelay(hovered, usableFrames.length);
    if (delay === null) return;
    const timer = window.setInterval(
      () => setFrameIndex((current) => (current + 1) % usableFrames.length),
      delay,
    );
    return () => {
      window.clearInterval(timer);
    };
  }, [hovered, usableFrames.length]);

  const stopPreview = () => {
    setHovered(false);
    setFrameIndex(0);
  };

  return (
    <div
      className="feed-preview"
      onMouseEnter={() => setHovered(true)}
      onMouseLeave={stopPreview}
    >
      {visibleVideo ? (
        <video
          src={visibleVideo}
          autoPlay
          muted
          loop
          playsInline
          onError={() =>
            frame &&
            setFailedFrames((current) => ({
              itemID: item.id,
              urls: new Set(current.itemID === item.id ? current.urls : []).add(
                frame,
              ),
            }))
          }
        />
      ) : null}
      {visibleImage ? (
        // eslint-disable-next-line @next/next/no-img-element -- authenticated blob URLs cannot use Next's remote image optimizer.
        <img
          src={visibleImage}
          alt=""
          loading="lazy"
          onError={() =>
            visiblePreviewImage && frame
              ? setFailedFrames((current) => ({
                  itemID: item.id,
                  urls: new Set(
                    current.itemID === item.id ? current.urls : [],
                  ).add(frame),
                }))
              : setFailedThumbnailURL(item.thumbnailURL ?? null)
          }
        />
      ) : null}
      {usableFrames.length > 1 && (
        <div
          className={`feed-preview-progress ${hovered ? "active" : ""}`}
          aria-hidden="true"
        >
          {usableFrames.map((_, index) => (
            <i className={index === frameIndex ? "current" : ""} key={index} />
          ))}
        </div>
      )}
      {hovered && usableFrames.length > 1 && (
        <span className="feed-preview-count">
          Scene {frameIndex + 1}/{usableFrames.length}
        </span>
      )}
    </div>
  );
}

export function FeedView({
  destinations,
  jobs,
  loadSites,
  loadPage,
  queueItem,
  loadAsset,
  onQueued,
  mediaEnabled,
  destinationsEnabled = false,
  queueEnabled,
}: FeedViewProps) {
  const [sites, setSites] = useState<FeedSite[]>([]);
  const [siteID, setSiteID] = useState<FeedSite["id"]>("");
  const [items, setItems] = useState<FeedItem[]>([]);
  const [page, setPage] = useState(0);
  const [hasMore, setHasMore] = useState(true);
  const [selection, setSelection] = useState<Set<string>>(new Set());
  const [destination, setDestination] = useState("local");
  const [loading, setLoading] = useState(true);
  const [pendingItems, setPendingItems] = useState<Set<string>>(new Set());
  const requestIDs = useRef(new Map<string, string>());
  const [error, setError] = useState<string | null>(null);
  const [notice, setNotice] = useState<string | null>(null);
  const [searchInput, setSearchInput] = useState("");
  const [activeQuery, setActiveQuery] = useState("");
  const [retryNonce, setRetryNonce] = useState(0);
  const requestSequence = useRef(0);
  const selectedSite = sites.find((site) => site.id === siteID);

  const fetchPage = useCallback(
    async (nextPage: number, replace = false, query = activeQuery) => {
      const sequence = ++requestSequence.current;
      setLoading(true);
      setError(null);
      try {
        const result = await loadPage(siteID, {
          text: query || undefined,
          page: nextPage,
        });
        if (sequence !== requestSequence.current) return;
        setItems((current) =>
          replace
            ? result.items
            : [
                ...current,
                ...result.items.filter(
                  (item) =>
                    !current.some((existing) => existing.id === item.id),
                ),
              ],
        );
        setPage(result.page);
        setHasMore(result.hasMore);
        if (replace) setSelection(new Set());
      } catch (reason) {
        if (sequence === requestSequence.current)
          setError(
            reason instanceof Error
              ? reason.message
              : "Unable to load this feed page.",
          );
      } finally {
        if (sequence === requestSequence.current) setLoading(false);
      }
    },
    [activeQuery, loadPage, siteID],
  );

  useEffect(() => {
    let active = true;
    const sequence = ++requestSequence.current;
    void loadSites()
      .then(async (nextSites) => {
        if (!active || sequence !== requestSequence.current) return;
        const initialSite = initialFeedSite(nextSites);
        if (!initialSite)
          throw new Error("The agent did not report any feed sources.");
        setSites(nextSites);
        setSiteID(initialSite.id);
        const result = await loadPage(initialSite.id, { page: 1 });
        if (!active || sequence !== requestSequence.current) return;
        setItems(result.items);
        setPage(result.page);
        setHasMore(result.hasMore);
        setLoading(false);
      })
      .catch((reason) => {
        if (!active || sequence !== requestSequence.current) return;
        setError(
          reason instanceof Error ? reason.message : "Unable to load the feed.",
        );
        setLoading(false);
      });
    return () => {
      active = false;
    };
  }, [loadPage, loadSites, retryNonce]);

  const selectSite = async (nextSite: FeedSite["id"]) => {
    const sequence = ++requestSequence.current;
    setSiteID(nextSite);
    setSearchInput("");
    setActiveQuery("");
    setLoading(true);
    setError(null);
    try {
      const result = await loadPage(nextSite, { page: 1 });
      if (sequence !== requestSequence.current) return;
      setItems(result.items);
      setPage(result.page);
      setHasMore(result.hasMore);
      setSelection(new Set());
      setSearchInput("");
      setActiveQuery("");
    } catch (reason) {
      if (sequence === requestSequence.current)
        setError(
          reason instanceof Error ? reason.message : "Unable to load the feed.",
        );
    } finally {
      if (sequence === requestSequence.current) setLoading(false);
    }
  };

  const submitSearch = async (event: React.FormEvent) => {
    event.preventDefault();
    const query = searchInput.trim().replace(/\s+/g, " ");
    setActiveQuery(query);
    setItems([]);
    setPage(0);
    setHasMore(false);
    setSelection(new Set());
    await fetchPage(1, true, query);
  };

  const clearSearch = async () => {
    setSearchInput("");
    setActiveQuery("");
    setItems([]);
    setPage(0);
    setHasMore(false);
    setSelection(new Set());
    await fetchPage(1, true, "");
  };

  const queueItems = async (targets: FeedItem[]) => {
    if (!queueEnabled || targets.length !== 1) return;
    const item = targets[0];
    const requestID = requestIDs.current.get(item.id) ?? crypto.randomUUID();
    requestIDs.current.set(item.id, requestID);
    setPendingItems((current) => new Set(current).add(item.id));
    setError(null);
    setNotice(null);
    try {
      await queueItem(item, destination, requestID);
      await onQueued();
      setNotice(
        `Transfer queued to ${destination === "local" ? "Local Downloads" : "the selected WebDAV destination"}.`,
      );
      requestIDs.current.delete(item.id);
    } catch (reason) {
      setError(reason instanceof Error ? reason.message : "The transfer could not be queued.");
    }
    setSelection(new Set());
    setPendingItems((current) => {
      const next = new Set(current);
      next.delete(item.id);
      return next;
    });
  };

  return (
    <div className="feed-page">
      <header className="feed-header">
        <div>
          <p className="eyebrow">Agent-backed discovery</p>
          <h2>Feed</h2>
          <p>
            Browse supported source pages and queue durable transfers without
            exposing provider media URLs.
          </p>
        </div>
        <a
          className="feed-source-link"
          href={selectedSite?.homeURL ?? "#"}
          target="_blank"
          rel="noreferrer"
        >
          Open source ↗
        </a>
      </header>

      <p className="feed-gate-notice" role="note">
        {mediaEnabled
          ? "Protected media preview; destination and queueing remain gated."
          : "Browsing preview; media and queueing remain gated."}
      </p>

      <section className="feed-toolbar glass-panel" aria-label="Feed controls">
        <div className="feed-toolbar-main">
          <label className="feed-source-control">
            <span>Source</span>
            <select
              value={siteID}
              disabled={!sites.length || loading}
              onChange={(event) =>
                void selectSite(event.target.value as FeedSite["id"])
              }
            >
              {sites.map((site) => (
                <option key={site.id} value={site.id}>
                  {site.displayName}
                </option>
              ))}
            </select>
          </label>
          {selectedSite?.supportsSearch ? (
            <form
              className="feed-search"
              onSubmit={(event) => void submitSearch(event)}
            >
              <label className="feed-search-field">
                <span>Search</span>
                <input
                  value={searchInput}
                  disabled={loading}
                  onChange={(event) => setSearchInput(event.target.value)}
                  maxLength={120}
                  placeholder={`Search ${selectedSite.displayName}`}
                />
              </label>
              <button className="feed-search-submit" disabled={loading}>
                {loading ? "Searching…" : "Search"}
              </button>
            </form>
          ) : (
            <div />
          )}
          <label className="feed-destination-control">
            <span>Destination</span>
            <select
              value={destination}
              disabled={!destinationsEnabled || loading}
              onChange={(event) => setDestination(event.target.value)}
            >
              <option value="local">Local Downloads</option>
              {destinations.map((item) => (
                <option key={item.id} value={`webdav:${item.id}`}>
                  {item.name} · WebDAV
                </option>
              ))}
            </select>
          </label>
          <button
            className="secondary-button feed-refresh"
            aria-label={activeQuery ? "Refresh results" : "Refresh feed"}
            disabled={loading}
            onClick={() => void fetchPage(1, true)}
          >
            ↻
          </button>
        </div>
        <div className="feed-toolbar-meta">
          <p>
            {items.length} result{items.length === 1 ? "" : "s"}
            {activeQuery ? ` for “${activeQuery}”` : ""}
          </p>
          {activeQuery && (
            <button
              disabled={loading}
              onClick={() => void clearSearch()}
              aria-label="Clear search"
            >
              Clear search ×
            </button>
          )}
        </div>
      </section>

      {error && (
        <div className="inline-error feed-message" role="alert">
          <span>{error}</span>
          <button
            className="secondary-button"
            disabled={loading}
            onClick={() =>
              sites.length && siteID
                ? void fetchPage(Math.max(page, 1), items.length === 0)
                : setRetryNonce((current) => current + 1)
            }
          >
            Retry
          </button>
        </div>
      )}
      {notice && (
        <p className="feed-notice" role="status">
          {notice}
        </p>
      )}

      <section
        className="feed-grid"
        aria-label={`${selectedSite?.displayName ?? "Video"} feed`}
      >
        {items.map((item) => {
          const state = feedTransferState(item.sourcePageURL, jobs);
          const selected = selection.has(item.id);
          return (
            <article
              className={`feed-card glass-panel ${selected ? "selected" : ""}`}
              key={item.id}
            >
              <div className="feed-thumb">
                {mediaEnabled ? (
                  <FeedThumbnail item={item} loadAsset={loadAsset} />
                ) : (
                  <div
                    className="feed-media-placeholder"
                    aria-label={`Media preview unavailable for ${item.title}`}
                  >
                    <span>{selectedSite?.displayName ?? item.siteID}</span>
                    <strong>Metadata preview</strong>
                  </div>
                )}
                <span className={`feed-transfer-state state-${state}`}>
                  {state === "available"
                    ? "Ready"
                    : state.replace(/([A-Z])/g, " $1")}
                </span>
              </div>
              <div className="feed-card-copy">
                <p>{item.studio ?? selectedSite?.displayName ?? "Video"}</p>
                <h3>{item.title}</h3>
                <dl>
                  <div>
                    <dt>Published</dt>
                    <dd>
                      {new Date(
                        agentDateMilliseconds(item.uploadedAt),
                      ).toLocaleDateString([], {
                        month: "short",
                        day: "numeric",
                        year: "numeric",
                      })}
                    </dd>
                  </div>
                  <div>
                    <dt>Views</dt>
                    <dd>{compactNumber(item.viewCount)}</dd>
                  </div>
                </dl>
              </div>
              <footer>
                <a href={item.sourcePageURL} target="_blank" rel="noreferrer">
                  View source ↗
                </a>
                <button
                  disabled={
                    !queueEnabled ||
                    pendingItems.has(item.id) ||
                    state === "queued" ||
                    state === "running"
                  }
                  onClick={() => void queueItems([item])}
                >
                  {!queueEnabled
                    ? "Queue gated"
                    : pendingItems.has(item.id)
                    ? "Queueing…"
                    : state === "queued" || state === "running"
                    ? "In queue"
                    : "Queue"}
                </button>
              </footer>
            </article>
          );
        })}
      </section>

      {loading && !items.length && (
        <section className="feed-empty glass-panel" aria-busy="true">
          <span>◫</span>
          <h3>{sites.length ? "Loading feed page" : "Loading feed sources"}</h3>
          <p>Waiting for the paired Mac to return structured metadata.</p>
        </section>
      )}
      {loading && items.length > 0 && (
        <p className="feed-progress" role="status">
          {page > 0 ? "Loading metadata…" : "Refreshing metadata…"}
        </p>
      )}
      {!items.length && !loading && !error && (
        <section className="feed-empty glass-panel">
          <span>◫</span>
          <h3>{activeQuery ? "No search results" : "No feed items found"}</h3>
          <p>
            {activeQuery
              ? `No structured results matched “${activeQuery}”.`
              : "The source returned no structured video entries for this page."}
          </p>
        </section>
      )}
      {hasMore && items.length > 0 && (
        <div className="feed-load-more">
          <button
            className="secondary-button"
            disabled={loading}
            onClick={() => void fetchPage(page + 1)}
          >
            {loading ? "Loading…" : "Load more"}
          </button>
        </div>
      )}
    </div>
  );
}
