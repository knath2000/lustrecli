"use client";

import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { agentDateMilliseconds } from "@/lib/agent-date";
import {
  feedPreviewDelay,
  feedPreviewFrames,
  feedPreviewMediaKind,
  feedSelectionKey,
  feedTransferState,
  feedUsesAuthenticatedAssetProxy,
  initialFeedSite,
  queueFeedItems,
  toggleFeedItemSelection,
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

export type FeedPlaybackResolution = {
  kind: "feed_resolve";
  playback: {
    sourcePageURL: string;
    title?: string;
    provider: string;
    qualities: Array<{
      label: string;
      url: string;
      mediaKind: "direct" | "hls" | "yt-dlp";
      headers: Record<string, string>;
    }>;
  };
};

type FeedViewProps = {
  destinations: DestinationProfile[];
  jobs: FeedJob[];
  loadSites: () => Promise<FeedRefresh<FeedSite[]>>;
  loadPage: (site: FeedSite["id"], query: FeedQuery) => Promise<FeedRefresh<FeedPage>>;
  queueItem: (item: FeedItem, destination: string, requestID: string) => Promise<void>;
  resolveItem?: (item: FeedItem) => Promise<FeedPlaybackResolution>;
  saveItem?: (item: FeedItem) => Promise<void>;
  loadAsset: (url: string, kind: "image" | "video") => Promise<Blob>;
  onQueued: () => Promise<void>;
  mediaEnabled: boolean;
  destinationsEnabled?: boolean;
  queueEnabled: boolean;
};

export type FeedRefresh<T> = {
  cache: { result: T; acknowledgedAt: string; freshness: "fresh" | "stale" } | null;
  live: Promise<T>;
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
          }).catch((error) => {
            assetCache.current.delete(item.thumbnailURL!);
            throw error;
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
  }, [item.thumbnailURL, item.uploadedAt, loadAsset, usesAssetProxy]);

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
          }).catch((error) => {
            assetCache.current.delete(frame);
            throw error;
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
  resolveItem,
  saveItem,
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
  const [selection, setSelection] = useState<Map<string, FeedItem>>(new Map());
  const [destination, setDestination] = useState("local");
  const [loading, setLoading] = useState(true);
  const [pendingItems, setPendingItems] = useState<Set<string>>(new Set());
  const requestIDs = useRef(new Map<string, string>());
  const [error, setError] = useState<string | null>(null);
  const [notice, setNotice] = useState<string | null>(null);
  const [resolvingItem, setResolvingItem] = useState<string | null>(null);
  const [playback, setPlayback] = useState<FeedPlaybackResolution["playback"] | null>(null);
  const [copiedURL, setCopiedURL] = useState<string | null>(null);
  const [savedItems, setSavedItems] = useState<Set<string>>(new Set());
  const [searchInput, setSearchInput] = useState("");
  const [activeQuery, setActiveQuery] = useState("");
  const [retryNonce, setRetryNonce] = useState(0);
  const [liveReady, setLiveReady] = useState(false);
  const requestSequence = useRef(0);
  const selectedSite = sites.find((site) => site.id === siteID);

  const fetchPage = useCallback(
    async (nextPage: number, query = activeQuery) => {
      const sequence = ++requestSequence.current;
      setLoading(true);
      setLiveReady(false);
      setError(null);
      try {
        const refresh = await loadPage(siteID, {
          text: query || undefined,
          page: nextPage,
        });
        if (refresh.cache && sequence === requestSequence.current) {
          const cached = refresh.cache.result;
          setItems(cached.items);
          setPage(cached.page);
          setHasMore(cached.hasMore);
          setLoading(false);
        }
        const result = await refresh.live;
        if (sequence !== requestSequence.current) return;
        setItems(result.items);
        setPage(result.page);
        setHasMore(result.hasMore);
        setLiveReady(true);
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
    const sitesRequest = loadSites();
    const pageRequest = loadPage("hqporner", { page: 1 });
    void Promise.all([sitesRequest, pageRequest])
      .then(async ([sitesRefresh, pageRefresh]) => {
        if (!active || sequence !== requestSequence.current) return;
        const cachedSites = sitesRefresh.cache?.result;
        const cachedPage = pageRefresh.cache?.result;
        if (cachedSites?.length && cachedPage) {
          setSites(cachedSites);
          setSiteID("hqporner");
          setItems(cachedPage.items);
          setPage(cachedPage.page);
          setHasMore(cachedPage.hasMore);
          setLoading(false);
        }
        const [nextSites, livePage] = await Promise.all([sitesRefresh.live, pageRefresh.live]);
        if (!active || sequence !== requestSequence.current) return;
        const initialSite = initialFeedSite(nextSites);
        if (!initialSite)
          throw new Error("The agent did not report any feed sources.");
        setSites(nextSites);
        setSiteID(initialSite.id);
        setItems(livePage.items);
        setPage(livePage.page);
        setHasMore(livePage.hasMore);
        setLiveReady(true);
        setLoading(false);
      })
      .catch((reason) => {
        if (!active || sequence !== requestSequence.current) return;
        setError(
          reason instanceof Error ? reason.message : "Unable to refresh the HQPorner feed.",
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
    setLiveReady(false);
    setError(null);
    try {
      const refresh = await loadPage(nextSite, { page: 1 });
      if (refresh.cache && sequence === requestSequence.current) {
        setItems(refresh.cache.result.items);
        setPage(refresh.cache.result.page);
        setHasMore(refresh.cache.result.hasMore);
        setLoading(false);
      }
      const result = await refresh.live;
      if (sequence !== requestSequence.current) return;
      setItems(result.items);
      setPage(result.page);
      setHasMore(result.hasMore);
      setSearchInput("");
      setActiveQuery("");
      setLiveReady(true);
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
    await fetchPage(1, query);
  };

  const clearSearch = async () => {
    setSearchInput("");
    setActiveQuery("");
    setItems([]);
    setPage(0);
    setHasMore(false);
    await fetchPage(1, "");
  };

  const queueItems = async (targets: FeedItem[]) => {
    if (!queueEnabled || !liveReady || targets.length === 0) return;
    const targetKeys = targets.map(feedSelectionKey);
    setPendingItems((current) => new Set([...current, ...targetKeys]));
    setError(null);
    setNotice(null);
    const results = await queueFeedItems(targets, async (item) => {
      const key = feedSelectionKey(item);
      const requestID = requestIDs.current.get(key) ?? crypto.randomUUID();
      requestIDs.current.set(key, requestID);
      await queueItem(item, destination, requestID);
      requestIDs.current.delete(key);
    });
    const successfulKeys = new Set(
      results.flatMap((result, index) =>
        result.ok ? [targetKeys[index]] : [],
      ),
    );
    const successfulCount = successfulKeys.size;
    let refreshError: string | null = null;
    if (successfulCount) {
      try {
        await onQueued();
      } catch (reason) {
        refreshError =
          reason instanceof Error
            ? reason.message
            : "Queued transfers could not be refreshed.";
      }
      setNotice(
        `${successfulCount} transfer${successfulCount === 1 ? "" : "s"} queued to ${destination === "local" ? "Local Downloads" : "the selected WebDAV destination"}.`,
      );
    }
    const failures = results.filter((result) => !result.ok);
    if (failures.length) {
      setError(
        failures.length === 1
          ? failures[0].error ?? "One transfer could not be queued."
          : `${failures.length} transfers could not be queued. The failed selections remain selected for retry.`,
      );
    } else if (refreshError) {
      setError(refreshError);
    }
    setSelection((current) => {
      const next = new Map(current);
      successfulKeys.forEach((key) => next.delete(key));
      return next;
    });
    setPendingItems((current) => {
      const next = new Set(current);
      targetKeys.forEach((key) => next.delete(key));
      return next;
    });
  };

  const extractLink = async (item: FeedItem) => {
    if (!resolveItem) return;
    const key = feedSelectionKey(item);
    setResolvingItem(key);
    setPlayback(null);
    setError(null);
    try {
      const result = await resolveItem(item);
      setPlayback(result.playback);
    } catch (reason) {
      setError(reason instanceof Error ? reason.message : "Unable to extract a playable link.");
    } finally {
      setResolvingItem(null);
    }
  };

  const copyText = async (value: string, marker: string) => {
    await navigator.clipboard.writeText(value);
    setCopiedURL(marker);
    window.setTimeout(() => setCopiedURL((current) => current === marker ? null : current), 1_500);
  };

  const saveForLater = async (item: FeedItem) => {
    if (!saveItem) return;
    const key = feedSelectionKey(item);
    setResolvingItem(key);
    setError(null);
    try {
      await saveItem(item);
      setSavedItems((current) => new Set(current).add(key));
      setNotice("Saved to Experimental Watchlist.");
    } catch (reason) {
      setError(reason instanceof Error ? reason.message : "Unable to save this video.");
    } finally {
      setResolvingItem(null);
    }
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
        {destinationsEnabled && queueEnabled && liveReady
          ? `${mediaEnabled ? "Protected media preview" : "Browsing preview"}, destination selection, and multi-select queueing are enabled.`
          : destinationsEnabled
            ? `${mediaEnabled ? "Protected media preview" : "Browsing preview"} and destination selection are enabled; queueing remains gated.`
            : mediaEnabled
              ? "Protected media preview; destination and queueing remain gated."
              : "Browsing preview; media, destination, and queueing remain gated."}
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
                <option key={item.id} value={`${item.kind === "google_drive" ? "gdrive" : "webdav"}:${item.id}`}>
                  {item.name} · {item.kind === "google_drive" ? "Google Drive" : "WebDAV"}
                </option>
              ))}
            </select>
          </label>
          <button
            className="secondary-button feed-refresh"
            aria-label={activeQuery ? "Refresh results" : "Refresh feed"}
            disabled={loading}
            onClick={() => void fetchPage(Math.max(page, 1))}
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
                ? void fetchPage(Math.max(page, 1))
                : setRetryNonce((current) => current + 1)
            }
          >
            Retry
          </button>
        </div>
      )}
      {!liveReady && siteID === "allpornstream" && !error && (
        <p className="feed-notice" role="status">
          Complete verification in the selected browser on the paired Mac. Cached cards remain visible while Lustre waits.
        </p>
      )}
      {notice && (
        <p className="feed-notice" role="status">
          {notice}
        </p>
      )}

      {selection.size > 0 && (
        <section className="feed-selection-bar" aria-label="Selected feed items">
          <div>
            <i aria-hidden="true">✓</i>
            <p>
              <strong>{selection.size} selected</strong>
              <span>Across feed pages</span>
            </p>
          </div>
          <button onClick={() => setSelection(new Map())}>Clear</button>
          <button
            className="queue-button"
            disabled={!queueEnabled || !liveReady || pendingItems.size > 0}
            onClick={() => void queueItems([...selection.values()])}
          >
            {pendingItems.size > 0 ? "Queueing…" : "Queue selected"}
          </button>
        </section>
      )}

      <section
        className="feed-grid"
        aria-label={`${selectedSite?.displayName ?? "Video"} feed`}
      >
        {items.map((item) => {
          const state = feedTransferState(item.sourcePageURL, jobs);
          const downloaded = item.downloadedAt !== undefined || state === "completed";
          const itemKey = feedSelectionKey(item);
          const selected = selection.has(itemKey);
          return (
            <article
              className={`feed-card glass-panel ${selected ? "selected" : ""} ${downloaded ? "downloaded" : ""}`}
              key={item.id}
            >
              <div className="feed-thumb">
                {mediaEnabled ? (
                  <FeedThumbnail
                    key={`${item.id}-${item.uploadedAt}`}
                    item={item}
                    loadAsset={loadAsset}
                  />
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
                  {downloaded && state === "available"
                    ? "Downloaded"
                    : state === "available"
                    ? "Ready"
                    : state.replace(/([A-Z])/g, " $1")}
                </span>
                {downloaded && (
                  <span
                    className="feed-downloaded-check"
                    aria-label="Previously downloaded"
                    title={item.downloadedAt
                      ? `Downloaded ${new Date(agentDateMilliseconds(item.downloadedAt)).toLocaleString()}`
                      : "Previously downloaded"}
                  >
                    ✓
                  </span>
                )}
                <button
                  className="feed-select"
                  type="button"
                  aria-label={`${selected ? "Deselect" : "Select"} ${item.title}`}
                  aria-pressed={selected}
                  disabled={!queueEnabled || pendingItems.has(itemKey)}
                  onClick={() =>
                    setSelection((current) =>
                      toggleFeedItemSelection(current, item),
                    )
                  }
                >
                  {selected ? "✓" : "+"}
                </button>
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
                  disabled={!resolveItem || !liveReady || resolvingItem === itemKey}
                  onClick={() => void extractLink(item)}
                >
                  {resolvingItem === itemKey ? "Extracting…" : "Extract link"}
                </button>
                <button disabled={!saveItem || savedItems.has(itemKey) || resolvingItem === itemKey} onClick={() => void saveForLater(item)}>
                  {savedItems.has(itemKey) ? "Saved" : "Save"}
                </button>
                <button
                  disabled={
                    !queueEnabled ||
                    !liveReady ||
                    pendingItems.has(itemKey) ||
                    state === "queued" ||
                    state === "running"
                  }
                  onClick={() => void queueItems([item])}
                >
                  {!queueEnabled || !liveReady
                    ? "Queue gated"
                    : pendingItems.has(itemKey)
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

      {playback && (
        <div className="feed-playback-backdrop" role="presentation" onMouseDown={() => setPlayback(null)}>
          <section className="feed-playback-panel glass-panel" role="dialog" aria-modal="true" aria-label="Playable video links" onMouseDown={(event) => event.stopPropagation()}>
            <header>
              <div>
                <p>{playback.provider}</p>
                <h3>{playback.title ?? "Playable video links"}</h3>
              </div>
              <button type="button" aria-label="Close playable links" onClick={() => setPlayback(null)}>×</button>
            </header>
            <p className="feed-playback-note">Provider links are temporary. Re-extract if one expires. VLC or Infuse may require the listed request headers.</p>
            <div className="feed-playback-options">
              {playback.qualities.map((quality, index) => {
                const marker = `${index}:${quality.url}`;
                const headerText = Object.entries(quality.headers).map(([key, value]) => `${key}: ${value}`).join("\n");
                return (
                  <article key={marker}>
                    <div>
                      <strong>{quality.label}</strong>
                      <span>{quality.mediaKind === "hls" ? "HLS stream" : "Direct media"}</span>
                    </div>
                    <button type="button" onClick={() => void copyText(quality.url, marker)}>
                      {copiedURL === marker ? "Copied" : "Copy URL"}
                    </button>
                    {headerText && (
                      <button type="button" onClick={() => void copyText(headerText, `${marker}:headers`)}>
                        {copiedURL === `${marker}:headers` ? "Copied" : "Copy headers"}
                      </button>
                    )}
                  </article>
                );
              })}
            </div>
          </section>
        </div>
      )}

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
      {items.length > 0 && (
        <nav className="feed-pagination" aria-label="Feed pagination">
          <button
            className="secondary-button"
            disabled={loading || page <= 1}
            onClick={() => void fetchPage(page - 1)}
          >
            ← Previous
          </button>
          <span>
            Page <strong>{page}</strong>
          </span>
          <button
            className="secondary-button"
            disabled={loading || !hasMore}
            onClick={() => void fetchPage(page + 1)}
          >
            Next →
          </button>
        </nav>
      )}
    </div>
  );
}
