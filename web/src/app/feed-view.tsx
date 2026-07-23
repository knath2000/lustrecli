"use client";

import { useCallback, useEffect, useMemo, useState } from "react";
import { agentDateMilliseconds } from "@/lib/agent-date";
import { feedPreviewDelay, feedPreviewFrames, feedTransferState, queueFeedItems, toggleFeedSelection, type FeedItem, type FeedPage, type FeedSite } from "@/lib/feed-model";
import type { DestinationProfile } from "./destinations-view";

export type FeedJob = { sourcePageURL: string; status: "queued" | "running" | "paused" | "completed" | "failed" | "cancelled" | "verificationRequired" };

type FeedViewProps = {
  destinations: DestinationProfile[];
  jobs: FeedJob[];
  loadSites: () => Promise<FeedSite[]>;
  loadPage: (site: FeedSite["id"], page: number) => Promise<FeedPage>;
  queueItem: (item: FeedItem, destination: string) => Promise<void>;
  onQueued: () => Promise<void>;
};

function compactNumber(value: number) {
  return new Intl.NumberFormat(undefined, { notation: "compact", maximumFractionDigits: 1 }).format(value);
}

function FeedThumbnail({ item }: { item: FeedItem }) {
  const frames = useMemo(() => feedPreviewFrames(item), [item]);
  const [hovered, setHovered] = useState(false);
  const [frameIndex, setFrameIndex] = useState(0);

  useEffect(() => {
    const delay = feedPreviewDelay(hovered, frames.length);
    if (delay === null) return;
    const previews = frames.slice(1).map((source) => {
      const image = new Image();
      image.src = source;
      return image;
    });
    const timer = window.setInterval(() => setFrameIndex((current) => (current + 1) % frames.length), delay);
    return () => { window.clearInterval(timer); void previews; };
  }, [frames, hovered]);

  const stopPreview = () => {
    setHovered(false);
    setFrameIndex(0);
  };

  return <div className="feed-preview" onMouseEnter={() => setHovered(true)} onMouseLeave={stopPreview}>
    {/* Provider thumbnails are dynamic remote URLs and cannot use a fixed Next image allowlist. */}
    {/* eslint-disable-next-line @next/next/no-img-element */}
    {frames[frameIndex] ? <img src={frames[frameIndex]} alt="" loading="lazy" /> : null}
    {frames.length > 1 && <div className={`feed-preview-progress ${hovered ? "active" : ""}`} aria-hidden="true">
      {frames.map((_, index) => <i className={index === frameIndex ? "current" : ""} key={index} />)}
    </div>}
    {hovered && frames.length > 1 && <span className="feed-preview-count">Scene {frameIndex + 1}/{frames.length}</span>}
  </div>;
}

export function FeedView({ destinations, jobs, loadSites, loadPage, queueItem, onQueued }: FeedViewProps) {
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
  const selectedSite = sites.find((site) => site.id === siteID);

  const fetchPage = useCallback(async (nextPage: number, replace = false) => {
    setLoading(true);
    setError(null);
    try {
      const result = await loadPage(siteID, nextPage);
      setItems((current) => replace ? result.items : [...current, ...result.items.filter((item) => !current.some((existing) => existing.id === item.id))]);
      setPage(result.page);
      setHasMore(result.hasMore);
      if (replace) setSelection(new Set());
    } catch (reason) {
      setError(reason instanceof Error ? reason.message : "Unable to load this feed page.");
    } finally {
      setLoading(false);
    }
  }, [loadPage, siteID]);

  useEffect(() => {
    let active = true;
    void loadSites().then(async (nextSites) => {
      if (!active) return;
      const initialSite = nextSites[0];
      if (!initialSite) throw new Error("The agent did not report any feed sources.");
      const result = await loadPage(initialSite.id, 1);
      if (!active) return;
      setSites(nextSites);
      setSiteID(initialSite.id);
      setItems(result.items);
      setPage(result.page);
      setHasMore(result.hasMore);
      setLoading(false);
    }).catch((reason) => {
      if (!active) return;
      setError(reason instanceof Error ? reason.message : "Unable to load the feed.");
      setLoading(false);
    });
    return () => { active = false; };
  }, [loadPage, loadSites]);

  const selectSite = async (nextSite: FeedSite["id"]) => {
    setSiteID(nextSite);
    setLoading(true);
    setError(null);
    try {
      const result = await loadPage(nextSite, 1);
      setItems(result.items);
      setPage(result.page);
      setHasMore(result.hasMore);
      setSelection(new Set());
    } catch (reason) {
      setError(reason instanceof Error ? reason.message : "Unable to load the feed.");
    } finally {
      setLoading(false);
    }
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
      <label><span>Source</span><select value={siteID} disabled={!sites.length} onChange={(event) => void selectSite(event.target.value as FeedSite["id"])}>{sites.map((site) => <option key={site.id} value={site.id}>{site.displayName}</option>)}</select></label>
      <label><span>Destination</span><select value={destination} onChange={(event) => setDestination(event.target.value)}><option value="local">Local Downloads</option>{destinations.map((item) => <option key={item.id} value={`webdav:${item.id}`}>{item.name} · WebDAV</option>)}</select></label>
      <button className="secondary-button" disabled={loading} onClick={() => void fetchPage(1, true)}>{loading && page <= 1 ? "Refreshing…" : "Refresh feed"}</button>
      <p>{items.length} discovered</p>
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
            <FeedThumbnail item={item} />
            <span className={`feed-transfer-state state-${state}`}>{state === "available" ? "Ready" : state.replace(/([A-Z])/g, " $1")}</span>
            <button className="feed-select" aria-label={`${selected ? "Deselect" : "Select"} ${item.title}`} aria-pressed={selected} onClick={() => setSelection((current) => toggleFeedSelection(current, item.id))}>{selected ? "✓" : "+"}</button>
          </div>
          <div className="feed-card-copy"><p>{item.studio ?? selectedSite?.displayName ?? "Video"}</p><h3>{item.title}</h3><dl><div><dt>Published</dt><dd>{new Date(agentDateMilliseconds(item.uploadedAt)).toLocaleDateString([], { month: "short", day: "numeric", year: "numeric" })}</dd></div><div><dt>Views</dt><dd>{compactNumber(item.viewCount)}</dd></div></dl></div>
          <footer><a href={item.sourcePageURL} target="_blank" rel="noreferrer">View source ↗</a><button disabled={queueing || state === "queued" || state === "running"} onClick={() => void queueItems([item])}>{state === "queued" || state === "running" ? "In queue" : "Queue"}</button></footer>
        </article>;
      })}
    </section>

    {!items.length && !loading && !error && <section className="feed-empty glass-panel"><span>◫</span><h3>No feed items found</h3><p>The source returned no structured video entries for this page.</p></section>}
    {hasMore && items.length > 0 && <div className="feed-load-more"><button className="secondary-button" disabled={loading} onClick={() => void fetchPage(page + 1)}>{loading ? "Loading…" : "Load more"}</button></div>}
  </div>;
}
