"use client";
/* eslint-disable react-hooks/set-state-in-effect */

import { AnimatePresence, LayoutGroup, motion, useReducedMotion } from "motion/react";
import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { feedPreviewDelay, feedPreviewFrames } from "@/lib/feed-model";
import type { FeedItem, FeedPage, FeedPlaybackResolution, FeedSite, ResolutionProgressEvent, WatchlistItem } from "@/lib/lustre-watch/contracts";
import { copyText } from "@/lib/lustre-watch/clipboard";
import { resolveClientBoundSources } from "@/lib/lustre-watch/client-bound-resolution";
import { displayProgressEvent } from "@/lib/lustre-watch/client-bound-progress";
import { HQPornerRefreshError } from "@/lib/lustre-watch/hqporner-refresh";
import { infusePlaybackURL } from "@/lib/lustre-watch/infuse";
import { readResolutionStream } from "@/lib/lustre-watch/resolution-stream";
import { ToastStack, type Toast } from "./toast-stack";

type Tab = "feed" | "watchlist";
type BatchResolution = { item: FeedItem; state: "extracting" | "resolved" | "failed"; resolution?: FeedPlaybackResolution; error?: string };
class RequestError extends Error {
  constructor(message: string, readonly code?: string) { super(message); }
}
async function json<T>(url: string, init?: RequestInit): Promise<T> {
  const response = await fetch(url, init);
  const body = await response.json().catch(() => ({}));
  if (!response.ok) throw new RequestError(body?.error?.message ?? "Request failed.", body?.error?.code);
  return body as T;
}

function supportsBrowserAssistance(sourcePageURL: string): boolean {
  const host = new URL(sourcePageURL).hostname;
  return ["allpornstream.com", "luluvid.com", "luluvdo.com", "lulustream.com", "playmogo.com", "ds2play.com", "doodstream.com", "dood.wf", "vide0.net", "dooodster.com"]
    .some((allowed) => host === allowed || host.endsWith(`.${allowed}`));
}

function feedWithExtension(page: number, q: string): Promise<FeedPage> {
  return new Promise((resolve, reject) => {
    const requestID = crypto.randomUUID();
    let requested = false;
    const cleanup = () => {
      window.clearTimeout(availabilityTimer);
      window.clearTimeout(timer);
      window.removeEventListener("message", receive);
    };
    const availabilityTimer = window.setTimeout(() => {
      if (requested) return;
      cleanup();
      reject(new Error("AllPornStream blocked cloud access. Load or update the Lustre Watch Provider Capture extension, then retry."));
    }, 1_000);
    const timer = window.setTimeout(() => {
      cleanup();
      reject(new Error("AllPornStream browser assistance timed out."));
    }, 30_000);
    function receive(event: MessageEvent) {
      const message = event.data;
      if (event.origin !== window.location.origin || message?.source !== "lustre-watch-extension" || message?.requestID !== requestID) return;
      if (message.type === "ready" && !requested) {
        requested = true;
        window.clearTimeout(availabilityTimer);
        window.postMessage({ source: "lustre-watch-app", type: "capture_allpornstream_feed", requestID, page, q }, window.location.origin);
        return;
      }
      cleanup();
      if (message.type !== "feed_captured" || !message.result) return reject(new Error(message.message ?? "Browser assistance did not return a feed."));
      resolve(message.result as FeedPage);
    }
    window.addEventListener("message", receive);
    window.postMessage({ source: "lustre-watch-app", type: "ping", requestID }, window.location.origin);
  });
}

function AssetImage({ url }: { url: string }) {
  const [ticketURL, setTicketURL] = useState("");
  const [direct, setDirect] = useState(false);
  const [failed, setFailed] = useState(false);
  useEffect(() => {
    let active = true;
    setTicketURL("");
    setDirect(false);
    setFailed(false);
    void json<{ url: string }>("/api/watch/assets/ticket", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ url }) })
      .then((ticket) => { if (active) setTicketURL(ticket.url); })
      .catch(() => { if (active) setDirect(true); });
    return () => { active = false; };
  }, [url]);
  if (failed) return <span>No preview</span>;
  if (!ticketURL && !direct) return <span>No preview</span>;
  return <img src={direct ? url : ticketURL} alt="" loading="lazy" crossOrigin={direct ? undefined : "anonymous"} referrerPolicy="no-referrer" onError={() => direct ? setFailed(true) : setDirect(true)} />;
}

function FeedArtwork({ item }: { item: FeedItem }) {
  const frames = useMemo(
    () => item.siteID === "allpornstream" ? feedPreviewFrames(item) : item.thumbnailURL ? [item.thumbnailURL] : [],
    [item],
  );
  const [hovered, setHovered] = useState(false);
  const [frameIndex, setFrameIndex] = useState(0);

  useEffect(() => {
    const delay = feedPreviewDelay(hovered, frames.length);
    if (delay === null) return;
    const timer = window.setInterval(() => setFrameIndex((current) => (current + 1) % frames.length), delay);
    return () => window.clearInterval(timer);
  }, [frames.length, hovered]);

  const stop = () => {
    setHovered(false);
    setFrameIndex(0);
  };

  return <div className="thumb rotating-thumb" onMouseEnter={() => setHovered(true)} onMouseLeave={stop}>
    {frames.length ? frames.map((url, index) => (
      <span className={`thumb-frame ${index === frameIndex ? "active" : ""}`} key={url}><AssetImage url={url} /></span>
    )) : <span className="no-preview">No preview</span>}
    {hovered && frames.length > 1 && <span className="thumb-progress" aria-hidden="true">{frames.map((url, index) => <i className={index === frameIndex ? "active" : ""} key={url} />)}</span>}
  </div>;
}

function formatViews(value: number): string {
  return new Intl.NumberFormat("en", { notation: "compact", maximumFractionDigits: 1 }).format(value);
}

function formatDate(value: string): string {
  const date = new Date(value);
  return date.getTime() > 0 ? new Intl.DateTimeFormat("en", { month: "short", day: "numeric", year: "numeric" }).format(date) : "Date unavailable";
}

export function WatchApp({
  activeTab,
  canQueue = false,
  canAgentResolve = false,
  onQueue,
  onQueueWatchlist,
  onAgentResolveFeed,
  onAgentResolveWatchlist,
}: {
  activeTab: Tab;
  canQueue?: boolean;
  canAgentResolve?: boolean;
  onQueue?: (item: FeedItem) => Promise<void>;
  onQueueWatchlist?: (item: WatchlistItem) => Promise<void>;
  onAgentResolveFeed?: (item: FeedItem) => Promise<FeedPlaybackResolution>;
  onAgentResolveWatchlist?: (item: WatchlistItem) => Promise<FeedPlaybackResolution>;
}) {
  const reducedMotion = useReducedMotion();
  const tab = activeTab;
  const [sites, setSites] = useState<FeedSite[]>([]);
  const [site, setSite] = useState("hqporner");
  const [query, setQuery] = useState("");
  const [page, setPage] = useState<FeedPage>({ items: [], page: 1, hasMore: false });
  const [watchlist, setWatchlist] = useState<WatchlistItem[]>([]);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");
  const [resolution, setResolution] = useState<FeedPlaybackResolution>();
  const [activeSource, setActiveSource] = useState<{ sourcePageURL: string; title: string; thumbnailURL?: string }>();
  const [progress, setProgress] = useState<ResolutionProgressEvent[]>([]);
  const [partialQualities, setPartialQualities] = useState<FeedPlaybackResolution["qualities"]>([]);
  const [partialAttempts, setPartialAttempts] = useState<NonNullable<FeedPlaybackResolution["providerAttempts"]>>([]);
  const [resolving, setResolving] = useState(false);
  const [toasts, setToasts] = useState<Toast[]>([]);
  const [copied, setCopied] = useState("");
  const [savedSource, setSavedSource] = useState("");
  const [queueingSource, setQueueingSource] = useState("");
  const [selection, setSelection] = useState<Set<string>>(new Set());
  const [watchSelection, setWatchSelection] = useState<Set<string>>(new Set());
  const [watchQuery, setWatchQuery] = useState("");
  const [watchStatus, setWatchStatus] = useState<"all" | "unwatched" | "watched">("all");
  const [watchProvider, setWatchProvider] = useState("all");
  const [watchSort, setWatchSort] = useState<"newest" | "oldest" | "title" | "provider">("newest");
  const [watchGroup, setWatchGroup] = useState<"none" | "provider" | "status">("none");
  const [batchAction, setBatchAction] = useState<"download" | "extract" | "watchlist" | "">("");
  const [batchResolutions, setBatchResolutions] = useState<BatchResolution[]>([]);
  const [showBatchResults, setShowBatchResults] = useState(false);
  const abortRef = useRef<AbortController | undefined>(undefined);
  const agentResolveRef = useRef<(() => Promise<FeedPlaybackResolution>) | undefined>(undefined);
  const triggerRef = useRef<HTMLElement | null>(null);
  const modalRef = useRef<HTMLElement | null>(null);

  const dismissToast = useCallback((id: string) => setToasts((current) => current.filter((toast) => toast.id !== id)), []);
  const notify = useCallback((toast: Omit<Toast, "id">) => {
    const id = crypto.randomUUID();
    setToasts((current) => [...current.slice(-3), { ...toast, id }]);
    return id;
  }, []);

  const loadWatchlist = useCallback(async () => setWatchlist(await json<WatchlistItem[]>("/api/watch/watchlist")), []);
  const loadFeed = useCallback(async (nextPage = 1) => {
    setBusy(true); setError("");
    try {
      const params = new URLSearchParams({ site, page: String(nextPage) });
      if (query.trim()) params.set("q", query.trim());
      setPage(await json<FeedPage>(`/api/watch/feed?${params}`));
      setSelection(new Set());
    } catch (reason) {
      if (site === "allpornstream" && reason instanceof RequestError && ["verification_required", "provider_unavailable"].includes(reason.code ?? "")) {
        try {
          const captured = await feedWithExtension(nextPage, query.trim());
          setPage(await json<FeedPage>("/api/watch/feed/capture", {
            method: "POST",
            headers: { "Content-Type": "application/json" },
            body: JSON.stringify({ page: nextPage, q: query.trim(), result: captured }),
          }));
        } catch (extensionError) {
          setError(extensionError instanceof Error ? extensionError.message : "AllPornStream browser assistance is unavailable.");
        }
      } else setError(reason instanceof Error ? reason.message : "Feed unavailable.");
    }
    finally { setBusy(false); }
  }, [query, site]);

  useEffect(() => {
    void Promise.all([json<FeedSite[]>("/api/watch/feed/sites").then((value) => setSites(value)), loadWatchlist()]);
  }, [loadWatchlist]);
  useEffect(() => { void loadFeed(1); }, [site]);

  async function save(item: FeedItem) {
    try {
      await json("/api/watch/watchlist", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ sourcePageURL: item.sourcePageURL, title: item.title, provider: item.siteID, thumbnailURL: item.thumbnailURL }) });
      setSavedSource(item.sourcePageURL);
      window.setTimeout(() => setSavedSource((current) => current === item.sourcePageURL ? "" : current), 1_400);
      await loadWatchlist();
      notify({ kind: "success", title: "Saved to your void", message: item.title });
    } catch (reason) {
      notify({ kind: "error", title: "Could not save scene", message: reason instanceof Error ? reason.message : "Watchlist is unavailable." });
    }
  }

  async function queue(item: FeedItem) {
    if (!onQueue) return;
    setQueueingSource(item.sourcePageURL);
    try {
      await onQueue(item);
      notify({ kind: "success", title: "Added to download queue", message: item.title });
    } catch (reason) {
      notify({ kind: "error", title: "Could not queue download", message: reason instanceof Error ? reason.message : "The paired Mac is unavailable." });
    } finally {
      setQueueingSource((current) => current === item.sourcePageURL ? "" : current);
    }
  }

  async function queueWatchlist(item: WatchlistItem) {
    if (!onQueueWatchlist) return;
    setQueueingSource(item.sourcePageURL);
    try {
      await onQueueWatchlist(item);
      notify({ kind: "success", title: "Added to download queue", message: item.title });
    } catch (reason) {
      notify({ kind: "error", title: "Could not queue download", message: reason instanceof Error ? reason.message : "The paired Mac is unavailable." });
    } finally {
      setQueueingSource((current) => current === item.sourcePageURL ? "" : current);
    }
  }

  const itemKey = (item: FeedItem) => `${item.siteID}:${item.id}`;
  const selectedItems = page.items.filter((item) => selection.has(itemKey(item)));
  const selectedWatchItems = watchlist.filter((item) => watchSelection.has(item.id));

  function watchlistFeedItem(item: WatchlistItem): FeedItem {
    const provider = item.provider.toLowerCase();
    const host = new URL(item.sourcePageURL).hostname.toLowerCase();
    const siteID = provider.includes("allpornstream") || host.includes("allpornstream")
      ? "allpornstream"
      : provider.includes("onlyfan420") || host.includes("onlyfan420")
        ? "onlyfan420"
        : provider.includes("pornhub") || host.includes("pornhub")
          ? "pornhub"
          : "hqporner";
    return {
      id: item.id,
      siteID,
      title: item.title,
      sourcePageURL: item.sourcePageURL,
      ...(item.thumbnailURL ? { thumbnailURL: item.thumbnailURL } : {}),
      previewURLs: [],
      uploadedAt: item.createdAt,
      uploadedAtIsApproximate: true,
      viewCount: 0,
      studio: item.provider,
    };
  }

  function toggleSelection(item: FeedItem) {
    const key = itemKey(item);
    setSelection((current) => {
      const next = new Set(current);
      if (next.has(key)) next.delete(key); else next.add(key);
      return next;
    });
  }

  async function inBatches<T>(items: FeedItem[], operation: (item: FeedItem) => Promise<T>) {
    const results: Array<PromiseSettledResult<T>> = [];
    for (let start = 0; start < items.length; start += 3) {
      results.push(...await Promise.allSettled(items.slice(start, start + 3).map(operation)));
    }
    return results;
  }

  async function downloadSelected() {
    if (!onQueue || !selectedItems.length) return;
    setBatchAction("download");
    const targets = [...selectedItems];
    const results = await inBatches(targets, onQueue);
    const failures = results.filter((result) => result.status === "rejected").length;
    setSelection(new Set(targets.filter((_, index) => results[index]?.status === "rejected").map(itemKey)));
    notify({ kind: failures ? "warning" : "success", title: `${targets.length - failures} added to downloads`, message: failures ? `${failures} item${failures === 1 ? "" : "s"} remain selected for retry.` : "The paired Mac will process them in queue order." });
    setBatchAction("");
  }

  async function watchlistSelected() {
    if (!selectedItems.length) return;
    setBatchAction("watchlist");
    const targets = [...selectedItems];
    const results = await inBatches(targets, (item) => json("/api/watch/watchlist", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ sourcePageURL: item.sourcePageURL, title: item.title, provider: item.siteID, thumbnailURL: item.thumbnailURL }) }));
    const failures = results.filter((result) => result.status === "rejected").length;
    setSelection(new Set(targets.filter((_, index) => results[index]?.status === "rejected").map(itemKey)));
    await loadWatchlist();
    notify({ kind: failures ? "warning" : "success", title: `${targets.length - failures} added to Watchlist`, message: failures ? `${failures} item${failures === 1 ? "" : "s"} remain selected for retry.` : "Your selected scenes are saved." });
    setBatchAction("");
  }

  async function extractSelected() {
    if (!onAgentResolveFeed || !canAgentResolve || !selectedItems.length) return;
    const targets = [...selectedItems];
    setBatchAction("extract");
    setBatchResolutions(targets.map((item) => ({ item, state: "extracting" })));
    setShowBatchResults(true);
    await inBatches(targets, async (item) => {
      try {
        const resolution = await onAgentResolveFeed(item);
        setBatchResolutions((current) => current.map((entry) => itemKey(entry.item) === itemKey(item) ? { item, state: "resolved", resolution } : entry));
        return resolution;
      } catch (reason) {
        setBatchResolutions((current) => current.map((entry) => itemKey(entry.item) === itemKey(item) ? { item, state: "failed", error: reason instanceof Error ? reason.message : "Extraction failed." } : entry));
        throw reason;
      }
    });
    setBatchAction("");
  }

  async function downloadWatchlistSelected() {
    if (!onQueueWatchlist || !selectedWatchItems.length) return;
    setBatchAction("download");
    const targets = [...selectedWatchItems];
    const results: Array<PromiseSettledResult<void>> = [];
    for (let start = 0; start < targets.length; start += 3) {
      results.push(...await Promise.allSettled(targets.slice(start, start + 3).map(onQueueWatchlist)));
    }
    const failures = results.filter((result) => result.status === "rejected").length;
    setWatchSelection(new Set(targets.filter((_, index) => results[index]?.status === "rejected").map((item) => item.id)));
    notify({ kind: failures ? "warning" : "success", title: `${targets.length - failures} added to downloads`, message: failures ? `${failures} item${failures === 1 ? "" : "s"} remain selected for retry.` : "The paired Mac will process them in queue order." });
    setBatchAction("");
  }

  async function extractWatchlistSelected() {
    if (!onAgentResolveWatchlist || !canAgentResolve || !selectedWatchItems.length) return;
    const targets = [...selectedWatchItems];
    const feedItems = new Map(targets.map((item) => [item.id, watchlistFeedItem(item)]));
    setBatchAction("extract");
    setBatchResolutions(targets.map((item) => ({ item: feedItems.get(item.id)!, state: "extracting" })));
    setShowBatchResults(true);
    for (let start = 0; start < targets.length; start += 3) {
      await Promise.allSettled(targets.slice(start, start + 3).map(async (item) => {
        const batchItem = feedItems.get(item.id)!;
        try {
          const resolved = await onAgentResolveWatchlist(item);
          setBatchResolutions((current) => current.map((entry) => entry.item.id === item.id ? { item: batchItem, state: "resolved", resolution: resolved } : entry));
          return resolved;
        } catch (reason) {
          setBatchResolutions((current) => current.map((entry) => entry.item.id === item.id ? { item: batchItem, state: "failed", error: reason instanceof Error ? reason.message : "Extraction failed." } : entry));
          throw reason;
        }
      }));
    }
    setBatchAction("");
  }

  async function resolve(sourcePageURL: string, title = "Resolving scene", thumbnailURL?: string, agentResolve?: () => Promise<FeedPlaybackResolution>) {
    if (agentResolve) agentResolveRef.current = agentResolve;
    abortRef.current?.abort();
    const controller = new AbortController();
    abortRef.current = controller;
    triggerRef.current = document.activeElement as HTMLElement | null;
    setActiveSource({ sourcePageURL, title, ...(thumbnailURL ? { thumbnailURL } : {}) });
    setProgress([]); setPartialQualities([]); setPartialAttempts([]);
    setResolving(true); setBusy(true); setError(""); setResolution(undefined);
    let eventCount = 0;
    let completed: FeedPlaybackResolution | undefined;
    let lastEvent: ResolutionProgressEvent | undefined;
    const handleEvent = (event: ResolutionProgressEvent) => {
      eventCount += 1;
      lastEvent = event;
      if (event.type === "completed" && event.resolution.clientResolverURL) {
        completed = event.resolution;
        setProgress((current) => [...current.slice(-23), displayProgressEvent(event)]);
        return;
      }
      setProgress((current) => [...current.slice(-23), event]);
      if (event.type === "metadata") setActiveSource((current) => current ? { ...current, title: event.title, ...(event.thumbnailURL ? { thumbnailURL: event.thumbnailURL } : {}) } : current);
      if (event.type === "provider_completed") {
        setPartialAttempts((current) => [...current.filter((attempt) => attempt.provider !== event.attempt.provider), event.attempt].slice(-12));
        if (event.attempt.provider !== "HQPorner" && event.qualities.length) setPartialQualities((current) => [...new Map([...current, ...event.qualities].map((quality) => [quality.url, quality])).values()].slice(0, 12));
      }
      if (event.type === "completed") {
        completed = event.resolution;
      }
    };
    const resolveWithAgent = async () => {
      const resolver = agentResolve ?? agentResolveRef.current;
      if (!canAgentResolve || !resolver) throw new Error("Connect your paired Mac to continue extraction with Lustre CLI.");
      handleEvent({ type: "provider_started", at: new Date().toISOString(), provider: "Lustre CLI", message: "Modal requires browser verification. Handing extraction to the paired Mac." });
      const result = await resolver();
      setResolution(result);
      setPartialQualities([]);
      setProgress((current) => [...current.slice(-23), { type: "completed", at: new Date().toISOString(), resolution: result }]);
      setResolving(false);
      notify({ kind: "success", title: "Resolved by Lustre CLI", message: "The paired Mac returned playable sources." });
    };
    try {
      const response = await fetch("/api/watch/resolve/stream", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ sourcePageURL }), signal: controller.signal });
      await readResolutionStream(response, handleEvent);
      if (completed) {
        const resolved = await resolveClientBoundSources(completed, fetch, controller.signal);
        setResolution(resolved);
        setPartialQualities([]);
        setProgress((current) => [...current.slice(-23), { type: "completed", at: new Date().toISOString(), resolution: resolved }]);
        setResolving(false);
        return;
      }
      if (lastEvent?.type === "browser_required" && supportsBrowserAssistance(sourcePageURL)) {
        await resolveWithAgent();
        return;
      }
      if (!completed && !controller.signal.aborted) {
        if (!eventCount) throw new Error("Resolution stream returned no events.");
        throw new Error(lastEvent?.type === "failed" ? lastEvent.message : "No playable sources were returned.");
      }
    }
    catch (reason) {
      if (controller.signal.aborted) return;
      if (!eventCount) {
        try {
          handleEvent({ type: "started", at: new Date().toISOString(), provider: "Compatibility mode", message: "The live stream was unavailable. Retrying with the standard resolver." });
          const result = await json<FeedPlaybackResolution>("/api/watch/resolve", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ sourcePageURL }) });
          const resolved = await resolveClientBoundSources(result, fetch, controller.signal);
          setResolution(resolved);
          setProgress((current) => [...current.slice(-23), { type: "completed", at: new Date().toISOString(), resolution: resolved }]);
          setResolving(false);
          notify({ kind: "info", title: "Compatibility mode", message: "Sources resolved without live provider updates." });
          return;
        } catch (fallbackReason) {
          reason = fallbackReason;
        }
      }
      if (supportsBrowserAssistance(sourcePageURL) && (!eventCount || lastEvent?.type === "browser_required")) {
        try {
          await resolveWithAgent();
          return;
        } catch (agentError) { reason = agentError; }
      }
      const message = reason instanceof Error ? reason.message : "Unable to resolve.";
      if (completed?.clientResolverURL) {
        const safeMessage = reason instanceof HQPornerRefreshError ? reason.message : "HQPorner device validation failed. Refresh and try again.";
        setProgress((current) => [...current.filter((event) => event.type !== "completed").slice(-23), {
          type: "failed",
          at: new Date().toISOString(),
          code: "provider_unavailable",
          message: safeMessage,
        }]);
        setPartialQualities([]);
        setPartialAttempts([{ provider: "HQPorner", status: "failed", message: safeMessage }]);
      }
      setError(message); setResolving(false);
      notify({ kind: "error", title: "Extraction failed", message });
    }
    finally { setBusy(false); }
  }

  function cancelResolve() {
    abortRef.current?.abort();
    setResolving(false);
    if (!resolution && !partialQualities.length) setActiveSource(undefined);
    notify({ kind: "info", title: "Extraction cancelled", message: partialQualities.length ? "Already resolved sources remain available." : "The active provider checks were stopped." });
  }

  async function copyValue(key: string, value: string, label: string) {
    try {
      await copyText(value);
      setCopied(key);
      window.setTimeout(() => setCopied((current) => current === key ? "" : current), 1_500);
      notify({ kind: "success", title: `${label} copied`, message: label === "Source URL" ? "The original provider page is ready to paste." : "Ready to paste into another player." });
    } catch {
      notify({ kind: "error", title: `Could not copy ${label.toLowerCase()}`, message: "Allow clipboard access and try again." });
    }
  }

  async function toggleWatched(item: WatchlistItem) {
    const watched = !item.watched;
    setWatchlist((current) => current.map((entry) => entry.id === item.id ? { ...entry, watched } : entry));
    try {
      const response = await fetch(`/api/watch/watchlist/${item.id}`, { method: "PATCH", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ watched }) });
      if (!response.ok) throw new Error("Watchlist update failed.");
      notify({ kind: "success", title: watched ? "Marked as watched" : "Returned to your queue", message: item.title });
    } catch (reason) {
      setWatchlist((current) => current.map((entry) => entry.id === item.id ? item : entry));
      notify({ kind: "error", title: "Could not update Watchlist", message: reason instanceof Error ? reason.message : "Try again." });
    }
  }

  async function removeWatchlist(item: WatchlistItem) {
    setWatchlist((current) => current.filter((entry) => entry.id !== item.id));
    setWatchSelection((current) => { const next = new Set(current); next.delete(item.id); return next; });
    try {
      const response = await fetch(`/api/watch/watchlist/${item.id}`, { method: "DELETE" });
      if (!response.ok) throw new Error("Watchlist removal failed.");
      notify({
        kind: "warning",
        title: "Removed from your void",
        message: item.title,
        duration: 8_000,
        action: {
          label: "Undo",
          run: async () => {
            try {
              const restored = await json<WatchlistItem>("/api/watch/watchlist", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ sourcePageURL: item.sourcePageURL, title: item.title, provider: item.provider, thumbnailURL: item.thumbnailURL }) });
              if (item.watched) await json(`/api/watch/watchlist/${restored.id}`, { method: "PATCH", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ watched: true }) });
              await loadWatchlist();
              notify({ kind: "success", title: "Restored to your void", message: item.title });
            } catch (reason) {
              setWatchlist((current) => current.some((entry) => entry.sourcePageURL === item.sourcePageURL) ? current : [item, ...current]);
              notify({ kind: "error", title: "Could not restore scene", message: reason instanceof Error ? reason.message : "The item was returned locally. Try saving it again." });
            }
          },
        },
      });
    } catch (reason) {
      setWatchlist((current) => [item, ...current]);
      notify({ kind: "error", title: "Could not remove scene", message: reason instanceof Error ? reason.message : "Try again." });
    }
  }

  useEffect(() => {
    if (!activeSource) return;
    const previous = document.body.style.overflow;
    document.body.style.overflow = "hidden";
    requestAnimationFrame(() => modalRef.current?.querySelector<HTMLElement>("button")?.focus());
    const keydown = (event: KeyboardEvent) => {
      if (event.key === "Escape") {
        if (resolving) cancelResolve();
        else setActiveSource(undefined);
        return;
      }
      if (event.key !== "Tab" || !modalRef.current) return;
      const focusable = [...modalRef.current.querySelectorAll<HTMLElement>("button:not(:disabled), a[href], input:not(:disabled), [tabindex]:not([tabindex='-1'])")];
      if (!focusable.length) return;
      const first = focusable[0]!;
      const last = focusable.at(-1);
      if (event.shiftKey && document.activeElement === first) { event.preventDefault(); last?.focus(); }
      else if (!event.shiftKey && document.activeElement === last) { event.preventDefault(); first.focus(); }
    };
    window.addEventListener("keydown", keydown);
    return () => {
      document.body.style.overflow = previous;
      window.removeEventListener("keydown", keydown);
      triggerRef.current?.focus();
    };
  }, [activeSource, resolving]);

  const displayedQualities = resolution?.qualities ?? partialQualities;
  const displayedAttempts = resolution?.providerAttempts ?? partialAttempts;
  const displayTitle = resolution?.title ?? activeSource?.title ?? "Resolving scene";
  const displayThumbnail = resolution?.thumbnailURL ?? activeSource?.thumbnailURL;
  const watchProviders = useMemo(() => [...new Set(watchlist.map((item) => item.provider))].sort((a, b) => a.localeCompare(b)), [watchlist]);
  const visibleWatchlist = useMemo(() => {
    const normalizedQuery = watchQuery.trim().toLocaleLowerCase();
    return watchlist
      .filter((item) => watchStatus === "all" || item.watched === (watchStatus === "watched"))
      .filter((item) => watchProvider === "all" || item.provider === watchProvider)
      .filter((item) => !normalizedQuery || `${item.title} ${item.provider}`.toLocaleLowerCase().includes(normalizedQuery))
      .toSorted((a, b) => {
        if (watchSort === "oldest") return Date.parse(a.createdAt) - Date.parse(b.createdAt);
        if (watchSort === "title") return a.title.localeCompare(b.title);
        if (watchSort === "provider") return a.provider.localeCompare(b.provider) || a.title.localeCompare(b.title);
        return Date.parse(b.createdAt) - Date.parse(a.createdAt);
      });
  }, [watchProvider, watchQuery, watchSort, watchStatus, watchlist]);
  const watchGroups = useMemo(() => {
    if (watchGroup === "none") return [{ key: "all", label: "", items: visibleWatchlist }];
    const grouped = new Map<string, WatchlistItem[]>();
    for (const item of visibleWatchlist) {
      const key = watchGroup === "provider" ? item.provider : item.watched ? "Watched" : "Unwatched";
      grouped.set(key, [...(grouped.get(key) ?? []), item]);
    }
    return [...grouped].map(([label, items]) => ({ key: label.toLocaleLowerCase(), label, items }));
  }, [visibleWatchlist, watchGroup]);
  const watchedCount = watchlist.filter((item) => item.watched).length;
  const visibleWatchIDs = new Set(visibleWatchlist.map((item) => item.id));
  const allVisibleSelected = visibleWatchlist.length > 0 && visibleWatchlist.every((item) => watchSelection.has(item.id));

  return <LayoutGroup><div className="lustre-watch">
    <div className="workspace">
    {error && <div className="notice">{error}</div>}
    {tab === "feed" ? <>
      <section className="section-heading"><div><p className="eyebrow">Explore the void</p><h1>Immersive feed</h1></div><p>Fresh scenes from your selected source, arranged for visual discovery.</p></section>
      <section className="controls">
        <div className="site-picker" role="group" aria-label="Feed provider">{sites.map((item) => <button key={item.id} className={site === item.id ? "selected" : ""} onClick={() => setSite(item.id)}>{item.displayName}</button>)}</div>
        <form onSubmit={(event) => { event.preventDefault(); void loadFeed(1); }}><span aria-hidden="true">⌕</span><input value={query} onChange={(event) => setQuery(event.target.value)} maxLength={120} placeholder="Search the void..." aria-label="Search this feed" /><button className="search-submit" disabled={busy}>Search</button></form>
      </section>
      <section className="batch-toolbar" aria-label="Feed batch actions">
        <button onClick={() => setSelection(selection.size === page.items.length ? new Set() : new Set(page.items.map(itemKey)))}>{selection.size === page.items.length && page.items.length ? "Clear all" : "Select all"}</button>
        <span>{selection.size ? `${selection.size} selected` : "Select cards for batch actions"}</span>
        <div>
          <button disabled={!selectedItems.length || !!batchAction || !canQueue} onClick={() => void downloadSelected()}>{batchAction === "download" ? "Queueing…" : "↓ Download all"}</button>
          <button disabled={!selectedItems.length || !!batchAction || !canAgentResolve} onClick={() => void extractSelected()}>{batchAction === "extract" ? "Extracting…" : "▶ Extract all"}</button>
          <button disabled={!selectedItems.length || !!batchAction} onClick={() => void watchlistSelected()}>{batchAction === "watchlist" ? "Saving…" : "＋ Watchlist all"}</button>
          {selection.size > 0 && <button onClick={() => setSelection(new Set())}>Clear</button>}
        </div>
      </section>
      {busy && !page.items.length
        ? <section className="grid skeleton-grid" aria-label="Loading feed">{Array.from({ length: 6 }, (_, index) => <div className="skeleton-card" key={index} />)}</section>
        : <motion.section className="grid" initial="hidden" animate="shown" variants={{ shown: { transition: { staggerChildren: reducedMotion ? 0 : .035 } } }}>{page.items.map((item, index) => <motion.article layout className={`card card-${index % 7} ${selection.has(itemKey(item)) ? "selected" : ""}`} key={`${item.siteID}:${item.id}`} variants={{ hidden: { opacity: 0, y: reducedMotion ? 0 : 18, scale: reducedMotion ? 1 : .985 }, shown: { opacity: 1, y: 0, scale: 1 } }} transition={{ duration: reducedMotion ? .12 : .34 }}>
          <FeedArtwork item={item} />
          <div className="card-scrim" />
          <button className="card-select" onClick={() => toggleSelection(item)} aria-pressed={selection.has(itemKey(item))} aria-label={`${selection.has(itemKey(item)) ? "Deselect" : "Select"} ${item.title}`}>{selection.has(itemKey(item)) ? "✓" : ""}</button>
          <div className="card-badge"><span />{sites.find((value) => value.id === item.siteID)?.displayName ?? item.siteID}</div>
          <div className="card-body">
            <div className="card-meta"><span>{formatDate(item.uploadedAt)}</span><span>{formatViews(item.viewCount)} views</span>{item.studio && <span>{item.studio}</span>}</div>
            <h2>{item.title}</h2>
            <div className="actions"><button className="card-play" onClick={() => void resolve(item.sourcePageURL, item.title, item.thumbnailURL, onAgentResolveFeed ? () => onAgentResolveFeed(item) : undefined)} aria-label={`Extract ${item.title}`}>▶ <span>Extract</span></button>{onQueue && <button disabled={!canQueue || queueingSource === item.sourcePageURL} onClick={() => void queue(item)} title={canQueue ? "Add to the paired Mac download queue" : "Pair or connect a Mac to download"}>↓ <span>{queueingSource === item.sourcePageURL ? "Queuing…" : "Download"}</span></button>}<button onClick={() => void copyValue(`feed-source:${item.siteID}:${item.id}`, item.sourcePageURL, "Source URL")} aria-label={`Copy source URL for ${item.title}`}>⧉ <span>{copied === `feed-source:${item.siteID}:${item.id}` ? "Copied ✓" : "Copy URL"}</span></button><button className={`icon-action ${savedSource === item.sourcePageURL ? "saved" : ""}`} onClick={() => void save(item)} aria-label={`Add ${item.title} to Watchlist`}>{savedSource === item.sourcePageURL ? "✓" : "＋"}</button></div>
          </div>
        </motion.article>)}</motion.section>}
      {!busy && !page.items.length && <div className="empty">No scenes returned for this page.</div>}
      <footer className="pagination"><button disabled={page.page <= 1 || busy} onClick={() => void loadFeed(page.page - 1)}>← Previous</button><span>Page {page.page}</span><button disabled={!page.hasMore || busy} onClick={() => void loadFeed(page.page + 1)}>Next →</button></footer>
    </> : <>
      <section className="section-heading watch-heading"><div><p className="eyebrow">Your collection</p><h1>Your void</h1></div><p>A private collection of scenes waiting to be explored.</p></section>
      <section className="watch-metrics" aria-label="Watchlist metrics">
        <button className={watchStatus === "all" ? "active" : ""} onClick={() => setWatchStatus("all")}><span>All scenes</span><strong>{watchlist.length}</strong></button>
        <button className={watchStatus === "unwatched" ? "active" : ""} onClick={() => setWatchStatus("unwatched")}><span>Unwatched</span><strong>{watchlist.length - watchedCount}</strong></button>
        <button className={watchStatus === "watched" ? "active" : ""} onClick={() => setWatchStatus("watched")}><span>Watched</span><strong>{watchedCount}</strong></button>
        <div><span>Providers</span><strong>{watchProviders.length}</strong></div>
      </section>
      <section className="watch-controls" aria-label="Watchlist organization">
        <label className="watch-search"><span aria-hidden="true">⌕</span><input value={watchQuery} onChange={(event) => setWatchQuery(event.target.value)} placeholder="Search your collection..." aria-label="Search Watchlist" /></label>
        <label><span>Provider</span><select value={watchProvider} onChange={(event) => setWatchProvider(event.target.value)}><option value="all">All providers</option>{watchProviders.map((provider) => <option value={provider} key={provider}>{provider}</option>)}</select></label>
        <label><span>Sort</span><select value={watchSort} onChange={(event) => setWatchSort(event.target.value as typeof watchSort)}><option value="newest">Newest added</option><option value="oldest">Oldest added</option><option value="title">Title A–Z</option><option value="provider">Provider</option></select></label>
        <label><span>Group</span><select value={watchGroup} onChange={(event) => setWatchGroup(event.target.value as typeof watchGroup)}><option value="none">No grouping</option><option value="provider">Provider</option><option value="status">Watch status</option></select></label>
      </section>
      <section className="batch-toolbar" aria-label="Watchlist batch actions">
        <button disabled={!visibleWatchlist.length} onClick={() => setWatchSelection((current) => { const next = new Set(current); if (allVisibleSelected) visibleWatchIDs.forEach((id) => next.delete(id)); else visibleWatchIDs.forEach((id) => next.add(id)); return next; })}>{allVisibleSelected ? "Clear visible" : "Select visible"}</button>
        <span>{watchSelection.size ? `${watchSelection.size} selected` : `${visibleWatchlist.length} scene${visibleWatchlist.length === 1 ? "" : "s"} shown`}</span>
        <div>
          <button disabled={!selectedWatchItems.length || !!batchAction || !canQueue || !onQueueWatchlist} onClick={() => void downloadWatchlistSelected()}>{batchAction === "download" ? "Queueing…" : "↓ Download all"}</button>
          <button disabled={!selectedWatchItems.length || !!batchAction || !canAgentResolve} onClick={() => void extractWatchlistSelected()}>{batchAction === "extract" ? "Extracting…" : "▶ Extract all"}</button>
          {watchSelection.size > 0 && <button onClick={() => setWatchSelection(new Set())}>Clear</button>}
        </div>
      </section>
      <div className="watch-groups">{watchGroups.map((group) => <section className="watch-group" key={group.key}>
        {group.label && <header><h2>{group.label}</h2><span>{group.items.length} scene{group.items.length === 1 ? "" : "s"}</span></header>}
        <motion.div layout className="watchlist">{group.items.map((item) => <motion.article layout initial={{ opacity: 0, scale: reducedMotion ? 1 : .97 }} animate={{ opacity: 1, scale: 1 }} exit={{ opacity: 0, scale: .94 }} className={`watch-row ${item.watched ? "watched" : ""} ${watchSelection.has(item.id) ? "selected" : ""}`} key={item.id}>
          <button className="watch-select" onClick={() => setWatchSelection((current) => { const next = new Set(current); if (next.has(item.id)) next.delete(item.id); else next.add(item.id); return next; })} aria-pressed={watchSelection.has(item.id)} aria-label={`${watchSelection.has(item.id) ? "Deselect" : "Select"} ${item.title}`}>{watchSelection.has(item.id) ? "✓" : ""}</button>
          <div className="watch-art">{item.thumbnailURL ? <AssetImage url={item.thumbnailURL} /> : <div className="placeholder">No preview</div>}<div className="card-scrim" />{item.watched && <div className="watched-badge"><span>✓</span> Watched</div>}<p className="provider">{item.provider}</p></div>
          <div className="watch-content"><p className="watch-added">Added {formatDate(item.createdAt)}</p><h2>{item.title}</h2><div className="actions"><button className="card-play" onClick={() => void resolve(item.sourcePageURL, item.title, item.thumbnailURL ?? undefined, onAgentResolveWatchlist ? () => onAgentResolveWatchlist(item) : undefined)}>▶ <span>Extract</span></button>{onQueueWatchlist && <button disabled={!canQueue || queueingSource === item.sourcePageURL} onClick={() => void queueWatchlist(item)}>↓ <span>{queueingSource === item.sourcePageURL ? "Queuing…" : "Download"}</span></button>}<button onClick={() => void copyValue(`source:${item.id}`, item.sourcePageURL, "Source URL")} aria-label={`Copy source URL for ${item.title}`}>{copied === `source:${item.id}` ? "Copied ✓" : "Copy source URL"}</button><button onClick={() => void toggleWatched(item)}>{item.watched ? "Mark unwatched" : "Mark watched"}</button><button className="danger" onClick={() => void removeWatchlist(item)}>Remove</button></div></div>
        </motion.article>)}</motion.div>
      </section>)}</div>
      {!watchlist.length && <div className="empty">Your void is empty. Save a scene from the Feed to begin.</div>}
      {!!watchlist.length && !visibleWatchlist.length && <div className="empty">No saved scenes match these filters.</div>}
    </>}
    <AnimatePresence>
      {showBatchResults && <motion.div className="modal-backdrop batch-backdrop" onClick={() => setShowBatchResults(false)} initial={{ opacity: 0 }} animate={{ opacity: 1 }} exit={{ opacity: 0 }}>
        <motion.section className="batch-results-modal" role="dialog" aria-modal="true" aria-labelledby="batch-results-title" onClick={(event) => event.stopPropagation()} initial={{ opacity: 0, y: 20 }} animate={{ opacity: 1, y: 0 }} exit={{ opacity: 0, y: 12 }}>
          <header><div><p className="eyebrow">Batch extraction</p><h2 id="batch-results-title">{batchResolutions.filter((entry) => entry.state === "resolved").length} of {batchResolutions.length} ready</h2></div><button onClick={() => setShowBatchResults(false)} aria-label="Close batch extraction results">×</button></header>
          <div className="batch-result-list">{batchResolutions.map((entry) => <article key={itemKey(entry.item)} className={entry.state}>
            <div><strong>{entry.item.title}</strong><span>{entry.state === "extracting" ? "Extracting with Lustre CLI…" : entry.state === "failed" ? entry.error : `${entry.resolution?.qualities.length ?? 0} source${entry.resolution?.qualities.length === 1 ? "" : "s"} ready`}</span></div>
            {entry.resolution?.qualities.map((quality) => <div className="batch-quality" key={`${quality.label}:${quality.url}`}><b>{quality.label}</b><button onClick={() => void copyValue(`batch:${quality.url}`, quality.url, "URL")}>{copied === `batch:${quality.url}` ? "Copied ✓" : "Copy URL"}</button><button onClick={() => { window.location.href = infusePlaybackURL(entry.resolution!.title, quality); }}>Infuse ↗</button></div>)}
          </article>)}</div>
        </motion.section>
      </motion.div>}
      {activeSource && <motion.div className="modal-backdrop" onClick={() => resolving ? cancelResolve() : setActiveSource(undefined)} initial={{ opacity: 0 }} animate={{ opacity: 1 }} exit={{ opacity: 0 }} transition={{ duration: reducedMotion ? .12 : .3 }}>
        <motion.section ref={modalRef} role="dialog" aria-modal="true" aria-labelledby="playback-title" className="modal" onClick={(event) => event.stopPropagation()} initial={reducedMotion ? { opacity: 0 } : { opacity: 0, scale: .985, y: 24 }} animate={{ opacity: 1, scale: 1, y: 0 }} exit={reducedMotion ? { opacity: 0 } : { opacity: 0, scale: .99, y: 18 }} transition={{ duration: reducedMotion ? .12 : .38, ease: [0.22, 1, 0.36, 1] }}>
          <div className="modal-ambient">{displayThumbnail && <AssetImage url={displayThumbnail} />}</div><div className="modal-scrim" />
          <header className="modal-header"><motion.div initial={{ opacity: 0, y: reducedMotion ? 0 : 14 }} animate={{ opacity: 1, y: 0 }}><p className="eyebrow">{resolving ? "Live extraction" : "Playback workspace"}</p><h2 id="playback-title">{displayTitle}</h2><p className="session-note">{resolving ? "Providers are reporting progress in real time" : "Temporary session links · Infuse requires an Apple device"}</p></motion.div><button className="close" onClick={() => resolving ? cancelResolve() : setActiveSource(undefined)} aria-label={resolving ? "Cancel extraction" : "Close playback links"}>{resolving ? "■" : "×"}</button></header>
          <div className="modal-workspace">
            <div className="source-panel">
              <div className="source-heading"><h3>{displayedQualities.length ? "Available sources" : "Extraction timeline"}</h3>{resolution && <button onClick={() => void resolve(resolution.sourcePageURL, resolution.title, resolution.thumbnailURL)}>↻ Refresh</button>}{!resolving && !resolution && error && <button onClick={() => void resolve(activeSource.sourcePageURL, activeSource.title, activeSource.thumbnailURL)}>↻ Refresh</button>}{resolving && <button onClick={cancelResolve}>Cancel</button>}</div>
              <AnimatePresence initial={false}>
                {progress.map((event, index) => <motion.div className={`progress-event progress-${event.type}`} key={`${event.at}:${event.type}:${index}`} initial={{ opacity: 0, x: reducedMotion ? 0 : -14 }} animate={{ opacity: 1, x: 0 }} exit={{ opacity: 0 }}>
                  <span className="progress-node">{event.type === "provider_completed" ? event.attempt.status === "resolved" ? "✓" : "!" : event.type === "failed" ? "×" : "•"}</span>
                  <div><strong>{event.type === "provider_started" ? event.provider : event.type === "provider_completed" ? event.attempt.provider : event.type.replaceAll("_", " ")}</strong><p>{event.type === "started" || event.type === "provider_started" || event.type === "validating" || event.type === "browser_required" || event.type === "failed" ? event.message : event.type === "metadata" ? `${event.candidateCount ?? 0} provider candidates discovered.` : event.type === "provider_completed" ? event.attempt.message ?? event.attempt.status.replaceAll("_", " ") : `${event.resolution.qualities.length} sources are ready.`}</p></div>
                </motion.div>)}
              </AnimatePresence>
              {resolving && <div className="progress-live"><span /><span /><span /> Waiting for provider updates</div>}
              {!resolving && !resolution && error && <div className="notice"><strong>HQPorner validation did not finish</strong><p>{error}</p><button onClick={() => void resolve(activeSource.sourcePageURL, activeSource.title, activeSource.thumbnailURL)}>↻ Refresh from source</button></div>}
              <AnimatePresence initial={false}>
                {displayedQualities.map((quality, index) => <motion.article layout className="quality" key={`${quality.label}:${quality.url}`} initial={{ opacity: 0, y: reducedMotion ? 0 : 15 }} animate={{ opacity: 1, y: 0 }} transition={{ delay: reducedMotion ? 0 : Math.min(index * .05, .3) }}>
                  <div className="quality-number">{String(index + 1).padStart(2, "0")}</div>
                  <div className="quality-main"><div><p>{quality.provider ?? "Direct source"}</p><h4>{quality.label}</h4></div><div className="quality-tags"><span>{quality.mediaKind === "hls" ? "HLS" : "VIDEO"}</span><span>{Object.keys(quality.headers).length ? "HEADERS" : "DIRECT"}</span>{quality.infuseCompatibility === "verified" && <span>Infuse verified</span>}{quality.infuseCompatibility === "header_required" && <span>Headers may be required</span>}{quality.resolutionMethod === "browser_capture" && <span>Browser capture</span>}</div></div>
                  <div className="quality-actions"><button className="infuse" onClick={() => { if (quality.infuseCompatibility === "header_required") notify({ kind: "warning", title: "Provider headers may be required", message: "Infuse cannot receive Referer or User-Agent headers, so this source may not play." }); else notify({ kind: "info", title: "Opening Infuse", message: quality.label }); window.location.href = infusePlaybackURL(displayTitle, quality); }}>Open in Infuse ↗</button><button onClick={() => void copyValue(`url:${quality.url}`, quality.url, "URL")}>{copied === `url:${quality.url}` ? "Copied ✓" : "Copy URL"}</button><button onClick={() => void copyValue(`headers:${quality.url}`, JSON.stringify(quality.headers, null, 2), "Headers")}>{copied === `headers:${quality.url}` ? "Copied ✓" : "Copy headers"}</button></div>
                </motion.article>)}
              </AnimatePresence>
            </div>
            <motion.aside className="status-panel" initial={{ opacity: 0, x: reducedMotion ? 0 : 18 }} animate={{ opacity: 1, x: 0 }} transition={{ delay: reducedMotion ? 0 : .15 }}>
              <p className="eyebrow">Resolution status</p><div className={`status-ready ${resolving ? "working" : !resolution && error ? "failed" : ""}`}><span>{resolving ? "◌" : !resolution && error ? "×" : "✓"}</span><div><strong>{resolving ? "Extraction active" : !resolution && error ? "No validated sources" : `${displayedQualities.length} source${displayedQualities.length === 1 ? "" : "s"} ready`}</strong><small>{resolving ? "Live provider stream" : !resolution && error ? "Refresh from the original source" : "Session links resolved"}</small></div></div>
              {displayedAttempts?.map((attempt) => <div className={`attempt ${attempt.status}`} key={`${attempt.provider}:${attempt.status}`}><span>{attempt.status === "resolved" ? "●" : "○"}</span><div><strong>{attempt.provider}</strong><small>{attempt.message ?? attempt.status.replace("_", " ")}</small></div></div>)}
            </motion.aside>
          </div>
        </motion.section>
      </motion.div>}
    </AnimatePresence>
    <ToastStack toasts={toasts} dismiss={dismissToast} />
    </div>
  </div></LayoutGroup>;
}
