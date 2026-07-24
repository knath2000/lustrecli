"use client";

import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { agentDateMilliseconds } from "@/lib/agent-date";
import { feedPreviewDelay, feedPreviewFrames, feedPreviewMediaKind, feedTransferState, feedUsesAuthenticatedAssetProxy, queueFeedItems, toggleFeedSelection, type FeedItem, type FeedPage, type FeedQuery, type FeedSite } from "@/lib/feed-model";
import type { DestinationProfile } from "./destinations-view";

export type FeedJob = { sourcePageURL: string; status: "queued" | "running" | "paused" | "completed" | "failed" | "cancelled" | "verificationRequired" };

type FeedViewProps = {
  destinations: DestinationProfile[];
  jobs: FeedJob[];
  loadSites: () => Promise<FeedSite[]>;
  loadPage: (site: FeedSite["id"], query: FeedQuery) => Promise<FeedPage>;
  queueItem: (item: FeedItem, destination: string) => Promise<void>;
  loadAsset: (url: string, kind: "image" | "video") => Promise<Blob>;
  onQueued: () => Promise<void>;
};

function compactNumber(value: number) {
  return new Intl.NumberFormat(undefined, { notation: "compact", maximumFractionDigits: 1 }).format(value);
}

function FeedThumbnail({ item, loadAsset }: { item: FeedItem; loadAsset: FeedViewProps["loadAsset"] }) {
  const frames = useMemo(() => item.previewURLs.length ? feedPreviewFrames(item) : [], [item]);
  const usesAssetProxy = feedUsesAuthenticatedAssetProxy(item.siteID);
  const assetCache = useRef(new Map<string, Blob | Promise<Blob>>());
  const [hovered, setHovered] = useState(false);
  const [frameIndex, setFrameIndex] = useState(0);
  const [thumbnail, setThumbnail] = useState<{ url: string; source: string } | null>(null);
  const [preview, setPreview] = useState<{ url: string; source: string } | null>(null);
  const [failedThumbnailURL, setFailedThumbnailURL] = useState<string | null>(null);
  const [failedFrames, setFailedFrames] = useState<{ itemID: string; urls: Set<string> }>({ itemID: item.id, urls: new Set() });
  const usableFrames = frames.filter((frame) => failedFrames.itemID !== item.id || !failedFrames.urls.has(frame));
  const frame = hovered ? usableFrames[frameIndex % Math.max(usableFrames.length, 1)] : undefined;
  const frameKind = frame ? feedPreviewMediaKind(frame) : "image";
  const previewSource = frame && hovered ? (usesAssetProxy ? preview?.url === frame ? preview.source : null : frame) : null;
  const visibleVideo = previewSource && frameKind === "video" ? previewSource : null;
  const visiblePreviewImage = previewSource && frameKind === "image" ? previewSource : null;
  const proxiedThumbnail = thumbnail?.url === item.thumbnailURL ? thumbnail : null;
  const visibleThumbnail = failedThumbnailURL === item.thumbnailURL ? null : usesAssetProxy ? proxiedThumbnail?.source ?? null : item.thumbnailURL ?? null;
  const visibleImage = visiblePreviewImage ?? visibleThumbnail;

  useEffect(() => {
    let active = true;
    if (!usesAssetProxy || !item.thumbnailURL) return undefined;
    const cached = assetCache.current.get(item.thumbnailURL);
    const request = cached instanceof Blob ? Promise.resolve(cached) : cached ?? loadAsset(item.thumbnailURL, "image").then((blob) => {
      assetCache.current.set(item.thumbnailURL!, blob);
      return blob;
    });
    if (!cached) assetCache.current.set(item.thumbnailURL, request);
    void request.then((blob) => {
      if (active) setThumbnail({ url: item.thumbnailURL!, source: URL.createObjectURL(blob) });
    }).catch(() => {
      if (active) setFailedThumbnailURL(item.thumbnailURL!);
    });
    return () => { active = false; };
  }, [item.thumbnailURL, loadAsset, usesAssetProxy]);

  useEffect(() => {
    let active = true;
    if (!usesAssetProxy || !frame) return undefined;
    const cached = assetCache.current.get(frame);
    const request = cached instanceof Blob ? Promise.resolve(cached) : cached ?? loadAsset(frame, frameKind).then((blob) => {
      assetCache.current.set(frame, blob);
      return blob;
    });
    if (!cached) assetCache.current.set(frame, request);
    void request.then((blob) => {
      if (active) setPreview({ url: frame, source: URL.createObjectURL(blob) });
    }).catch(() => {
      if (active) setFailedFrames((current) => ({ itemID: item.id, urls: new Set(current.itemID === item.id ? current.urls : []).add(frame) }));
    });
    return () => { active = false; };
  }, [frame, frameKind, item.id, loadAsset, usesAssetProxy]);

  useEffect(() => () => {
    if (thumbnail) URL.revokeObjectURL(thumbnail.source);
  }, [thumbnail]);

  useEffect(() => () => {
    if (preview) URL.revokeObjectURL(preview.source);
  }, [preview]);

  useEffect(() => {
    const delay = feedPreviewDelay(hovered, usableFrames.length);
    if (delay === null) return;
    const timer = window.setInterval(() => setFrameIndex((current) => (current + 1) % usableFrames.length), delay);
    return () => { window.clearInterval(timer); };
  }, [hovered, usableFrames.length]);

  const stopPreview = () => {
    setHovered(false);
    setFrameIndex(0);
  };

  return <div className="feed-preview" onMouseEnter={() => setHovered(true)} onMouseLeave={stopPreview}>
    {visibleVideo ? <video src={visibleVideo} autoPlay muted loop playsInline onError={() => frame && setFailedFrames((current) => ({ itemID: item.id, urls: new Set(current.itemID === item.id ? current.urls : []).add(frame) }))} /> : null}
    {/* eslint-disable-next-line @next/next/no-img-element -- authenticated blob URLs cannot use Next's remote image optimizer. */}
    {visibleImage ? <img src={visibleImage} alt="" loading="lazy" onError={() => visiblePreviewImage && frame ? setFailedFrames((current) => ({ itemID: item.id, urls: new Set(current.itemID === item.id ? current.urls : []).add(frame) })) : setFailedThumbnailURL(item.thumbnailURL ?? null)} /> : null}
    {usableFrames.length > 1 && <div className={`feed-preview-progress ${hovered ? "active" : ""}`} aria-hidden="true">
      {usableFrames.map((_, index) => <i className={index === frameIndex ? "current" : ""} key={index} />)}
    </div>}
    {hovered && usableFrames.length > 1 && <span className="feed-preview-count">Scene {frameIndex + 1}/{usableFrames.length}</span>}
  </div>;
}

export function FeedView({ destinations, jobs, loadSites, loadPage, queueItem, loadAsset, onQueued }: FeedViewProps) {
  const [sites, setSites] = useState<FeedSite[]>([]);
  const [siteID, setSiteID] = useState<FeedSite["id"]>("");
  const [items, setItems] = useState<FeedItem[]>([]);
  const [page, setPage] = useState(0);
  const [hasMore, setHasMore] = useState(true);
  const [selection, setSelection] = useState<Set<string>>(new Set());
  const [destination, setDestination] = useState("local");
  const [loading, setLoading] = useState(true);
  const [queueing, setQueueing] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [notice, setNotice] = useState<string | null>(null);
  const [searchInput, setSearchInput] = useState("");
  const [activeQuery, setActiveQuery] = useState("");
  const requestSequence = useRef(0);
  const selectedSite = sites.find((site) => site.id === siteID);

  const fetchPage = useCallback(async (nextPage: number, replace = false, query = activeQuery) => {
    const sequence = ++requestSequence.current;
    setLoading(true);
    setError(null);
    try {
      const result = await loadPage(siteID, { text: query || undefined, page: nextPage });
      if (sequence !== requestSequence.current) return;
      setItems((current) => replace ? result.items : [...current, ...result.items.filter((item) => !current.some((existing) => existing.id === item.id))]);
      setPage(result.page);
      setHasMore(result.hasMore);
      if (replace) setSelection(new Set());
    } catch (reason) {
      if (sequence === requestSequence.current) setError(reason instanceof Error ? reason.message : "Unable to load this feed page.");
    } finally {
      if (sequence === requestSequence.current) setLoading(false);
    }
  }, [activeQuery, loadPage, siteID]);

  useEffect(() => {
    let active = true;
    const sequence = ++requestSequence.current;
    void loadSites().then(async (nextSites) => {
      if (!active || sequence !== requestSequence.current) return;
      const initialSite = nextSites[0];
      if (!initialSite) throw new Error("The agent did not report any feed sources.");
      const result = await loadPage(initialSite.id, { page: 1 });
      if (!active || sequence !== requestSequence.current) return;
      setSites(nextSites);
      setSiteID(initialSite.id);
      setItems(result.items);
      setPage(result.page);
      setHasMore(result.hasMore);
      setLoading(false);
    }).catch((reason) => {
      if (!active || sequence !== requestSequence.current) return;
      setError(reason instanceof Error ? reason.message : "Unable to load the feed.");
      setLoading(false);
    });
    return () => { active = false; };
  }, [loadPage, loadSites]);

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
      if (sequence === requestSequence.current) setError(reason instanceof Error ? reason.message : "Unable to load the feed.");
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

  const selectedItems = useMemo(() => items.filter((item) => selection.has(item.id)), [items, selection]);

  const queueItems = async (targets: FeedItem[]) => {
    if (!targets.length) return;
    setQueueing(true);
    setError(null);
    setNotice(null);
    const results = await queueFeedItems(targets, (item) => queueItem(item, destination), 3);
    const failed = results.filter((result) => !result.ok);
    await onQueued();
    if (failed.length) setError(`${failed.length} of ${results.length} transfers could not be queued. ${failed[0].error ?? ""}`.trim());
    else setNotice(`${results.length} transfer${results.length === 1 ? "" : "s"} queued to ${destination === "local" ? "Local Downloads" : "the selected WebDAV destination"}.`);
    setSelection(new Set());
    setQueueing(false);
  };

  return <div className="feed-page">
    <header className="feed-header">
      <div><p className="eyebrow">Agent-backed discovery</p><h2>Feed</h2><p>Browse supported source pages and queue durable transfers without exposing provider media URLs.</p></div>
      <a className="feed-source-link" href={selectedSite?.homeURL ?? "#"} target="_blank" rel="noreferrer">Open source ↗</a>
    </header>

    <section className="feed-toolbar glass-panel" aria-label="Feed controls">
      <div className="feed-toolbar-main">
        <label className="feed-source-control"><span>Source</span><select value={siteID} disabled={!sites.length} onChange={(event) => void selectSite(event.target.value as FeedSite["id"])}>{sites.map((site) => <option key={site.id} value={site.id}>{site.displayName}</option>)}</select></label>
        {selectedSite?.supportsSearch ? <form className="feed-search" onSubmit={(event) => void submitSearch(event)}><label className="feed-search-field"><span>Search</span><input value={searchInput} onChange={(event) => setSearchInput(event.target.value)} maxLength={120} placeholder={`Search ${selectedSite.displayName}`} /></label><button className="feed-search-submit" disabled={loading}>{loading ? "Searching…" : "Search"}</button></form> : <div />}
        <label className="feed-destination-control"><span>Destination</span><select value={destination} onChange={(event) => setDestination(event.target.value)}><option value="local">Local Downloads</option>{destinations.map((item) => <option key={item.id} value={`webdav:${item.id}`}>{item.name} · WebDAV</option>)}</select></label>
        <button className="secondary-button feed-refresh" aria-label={activeQuery ? "Refresh results" : "Refresh feed"} disabled={loading} onClick={() => void fetchPage(1, true)}>↻</button>
      </div>
      <div className="feed-toolbar-meta"><p>{items.length} result{items.length === 1 ? "" : "s"}{activeQuery ? ` for “${activeQuery}”` : ""}</p>{activeQuery && <button onClick={() => void clearSearch()} aria-label="Clear search">Clear search ×</button>}</div>
    </section>

    {error && <p className="inline-error feed-message" role="alert">{error}</p>}
    {notice && <p className="feed-notice" role="status">{notice}</p>}

    {selection.size > 0 && <section className="feed-selection-bar" aria-label="Selected feed items">
      <strong>{selection.size} selected</strong><span>Queue requests run three at a time.</span><button onClick={() => setSelection(new Set())}>Clear</button><button className="queue-button" disabled={queueing} onClick={() => void queueItems(selectedItems)}>{queueing ? "Queueing…" : "Queue selected"}</button>
    </section>}

    <section className="feed-grid" aria-label={`${selectedSite?.displayName ?? "Video"} feed`}>
      {items.map((item) => {
        const state = feedTransferState(item.sourcePageURL, jobs);
        const selected = selection.has(item.id);
        return <article className={`feed-card glass-panel ${selected ? "selected" : ""}`} key={item.id}>
          <div className="feed-thumb">
            <FeedThumbnail item={item} loadAsset={loadAsset} />
            <span className={`feed-transfer-state state-${state}`}>{state === "available" ? "Ready" : state.replace(/([A-Z])/g, " $1")}</span>
            <button className="feed-select" aria-label={`${selected ? "Deselect" : "Select"} ${item.title}`} aria-pressed={selected} onClick={() => setSelection((current) => toggleFeedSelection(current, item.id))}>{selected ? "✓" : "+"}</button>
          </div>
          <div className="feed-card-copy"><p>{item.studio ?? selectedSite?.displayName ?? "Video"}</p><h3>{item.title}</h3><dl><div><dt>Published</dt><dd>{new Date(agentDateMilliseconds(item.uploadedAt)).toLocaleDateString([], { month: "short", day: "numeric", year: "numeric" })}</dd></div><div><dt>Views</dt><dd>{compactNumber(item.viewCount)}</dd></div></dl></div>
          <footer><a href={item.sourcePageURL} target="_blank" rel="noreferrer">View source ↗</a><button disabled={queueing || state === "queued" || state === "running"} onClick={() => void queueItems([item])}>{state === "queued" || state === "running" ? "In queue" : "Queue"}</button></footer>
        </article>;
      })}
    </section>

    {!items.length && !loading && !error && <section className="feed-empty glass-panel"><span>◫</span><h3>{activeQuery ? "No search results" : "No feed items found"}</h3><p>{activeQuery ? `No structured results matched “${activeQuery}”.` : "The source returned no structured video entries for this page."}</p></section>}
    {hasMore && items.length > 0 && <div className="feed-load-more"><button className="secondary-button" disabled={loading} onClick={() => void fetchPage(page + 1)}>{loading ? "Loading…" : "Load more"}</button></div>}
  </div>;
}
