"use client";

import { useCallback, useEffect, useState } from "react";
import type { FeedPlaybackResolution } from "./feed-view";

type WatchlistItem = {
  id: string;
  sourcePageURL: string;
  title: string;
  provider: string;
  thumbnailURL: string | null;
  watched: boolean;
  watchedAt: string | null;
  createdAt: string;
  updatedAt: string;
};

async function payload(response: Response) {
  const value = await response.json().catch(() => ({}));
  if (!response.ok) throw new Error(value.error?.message ?? "Watchlist request failed.");
  return value;
}

async function resolveWatchlistItem(deviceID: string, watchlistID: string) {
  const base = `/api/cloud/v1/devices/${deviceID}`;
  const created = await payload(await fetch(`${base}/commands`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ kind: "watchlist_resolve", watchlistID }),
    cache: "no-store",
  }));
  for (let attempt = 0; attempt < 90; attempt += 1) {
    const current = await payload(await fetch(`${base}/commands/${created.command.id}`, { cache: "no-store" }));
    if (current.command.status === "completed") return current.command.result as FeedPlaybackResolution;
    if (current.command.status === "failed") throw new Error("The paired Mac could not resolve this video. Refresh and try again.");
    await new Promise((resolve) => window.setTimeout(resolve, 1_000));
  }
  throw new Error("The paired Mac is still resolving this video. Try refresh again shortly.");
}

function WatchlistThumbnail({ deviceID, item }: { deviceID: string; item: WatchlistItem }) {
  const [source, setSource] = useState<string | null>(null);
  useEffect(() => {
    if (!item.thumbnailURL) return;
    let active = true;
    let objectURL: string | null = null;
    void (async () => {
      const ticketResponse = await fetch(`/api/cloud/v1/devices/${deviceID}/feed-assets/ticket`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ url: item.thumbnailURL, kind: "image" }),
        cache: "no-store",
      });
      const ticket = await ticketResponse.json().catch(() => ({}));
      if (!ticketResponse.ok || typeof ticket.ticket !== "string" || typeof ticket.assetURL !== "string") return;
      const assetResponse = await fetch(ticket.assetURL, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ ticket: ticket.ticket }),
        cache: "no-store",
      });
      if (!assetResponse.ok || !active) return;
      objectURL = URL.createObjectURL(await assetResponse.blob());
      setSource(objectURL);
    })();
    return () => {
      active = false;
      if (objectURL) URL.revokeObjectURL(objectURL);
    };
  }, [deviceID, item.thumbnailURL]);
  return <div className="studio-watchlist-thumb">
    {source ? <img src={source} alt="" /> : <span aria-hidden>▶</span>}
    {item.watched && <b>Watched</b>}
  </div>;
}

export function WatchlistView({ deviceID, connected }: { deviceID: string; connected: boolean }) {
  const [items, setItems] = useState<WatchlistItem[]>([]);
  const [loading, setLoading] = useState(true);
  const [busyID, setBusyID] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [sourceURL, setSourceURL] = useState("");
  const [playbacks, setPlaybacks] = useState<Record<string, { value: FeedPlaybackResolution["playback"]; resolvedAt: string }>>({});
  const [copied, setCopied] = useState<string | null>(null);
  const [activePlaybackID, setActivePlaybackID] = useState<string | null>(null);

  const load = useCallback(async () => {
    setLoading(true);
    try {
      const result = await payload(await fetch("/api/cloud/v1/watchlist", { cache: "no-store" }));
      setItems(result.items as WatchlistItem[]);
      setError(null);
    } catch (reason) {
      setError(reason instanceof Error ? reason.message : "Unable to load Watchlist.");
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => { void load(); }, [load]);
  useEffect(() => {
    if (!activePlaybackID) return;
    const close = (event: KeyboardEvent) => { if (event.key === "Escape") setActivePlaybackID(null); };
    window.addEventListener("keydown", close);
    return () => window.removeEventListener("keydown", close);
  }, [activePlaybackID]);

  const addURL = async (event: React.FormEvent) => {
    event.preventDefault();
    const url = sourceURL.trim();
    if (!url) return;
    try {
      await payload(await fetch("/api/cloud/v1/watchlist", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ sourcePageURL: url, title: new URL(url).hostname, provider: "Saved link" }),
      }));
      setSourceURL("");
      await load();
    } catch (reason) {
      setError(reason instanceof Error ? reason.message : "Unable to save this link.");
    }
  };

  const setWatched = async (item: WatchlistItem, watched: boolean) => {
    setBusyID(item.id);
    try {
      const result = await payload(await fetch("/api/cloud/v1/watchlist", {
        method: "PATCH",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ id: item.id, watched }),
      }));
      setItems((current) => current.map((candidate) => candidate.id === item.id ? result.item : candidate));
    } catch (reason) {
      setError(reason instanceof Error ? reason.message : "Unable to update watched status.");
    } finally {
      setBusyID(null);
    }
  };

  const remove = async (id: string) => {
    setBusyID(id);
    try {
      await payload(await fetch("/api/cloud/v1/watchlist", {
        method: "DELETE",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ id }),
      }));
      setItems((current) => current.filter((item) => item.id !== id));
      setPlaybacks((current) => { const next = { ...current }; delete next[id]; return next; });
      setActivePlaybackID((current) => current === id ? null : current);
    } catch (reason) {
      setError(reason instanceof Error ? reason.message : "Unable to remove this item.");
    } finally {
      setBusyID(null);
    }
  };

  const extract = async (item: WatchlistItem) => {
    setBusyID(item.id);
    setError(null);
    try {
      const result = await resolveWatchlistItem(deviceID, item.id);
      setPlaybacks((current) => ({ ...current, [item.id]: { value: result.playback, resolvedAt: new Date().toISOString() } }));
      setActivePlaybackID(item.id);
    } catch (reason) {
      setError(reason instanceof Error ? reason.message : "Unable to resolve this video.");
    } finally {
      setBusyID(null);
    }
  };

  const copy = async (text: string, marker: string) => {
    await navigator.clipboard.writeText(text);
    setCopied(marker);
    window.setTimeout(() => setCopied((current) => current === marker ? null : current), 1_500);
  };
  const activeItem = items.find((item) => item.id === activePlaybackID) ?? null;
  const activePlayback = activePlaybackID ? playbacks[activePlaybackID] : null;

  return <section className="studio-watchlist">
    <header>
      <div><p>Experimental</p><h1>Watchlist</h1><span>Save source links, resolve a fresh playback URL when needed, and track what you watched.</span></div>
      <b>{items.filter((item) => !item.watched).length} unwatched</b>
    </header>
    <form onSubmit={addURL}><input type="url" required value={sourceURL} onChange={(event) => setSourceURL(event.target.value)} placeholder="Paste a supported HTTPS video page…" /><button>Save link</button></form>
    {!connected && <p className="studio-library-offline">Your Watchlist is available, but the paired Mac must be online to extract playback links.</p>}
    {error && <p className="feed-error">{error}</p>}
    {loading ? <div className="studio-watchlist-empty">Loading Watchlist…</div> : !items.length ? <div className="studio-watchlist-empty"><strong>No saved videos yet</strong><span>Use “Save” on any Feed card, or paste a supported source page above.</span></div> :
      <div className="studio-watchlist-grid">{items.map((item) => {
        const resolved = playbacks[item.id];
        return <article key={item.id} className={item.watched ? "watched" : ""}>
        <WatchlistThumbnail deviceID={deviceID} item={item} />
        <div className="studio-watchlist-copy"><p>{item.provider}</p><h3>{item.title}</h3><a href={item.sourcePageURL} target="_blank" rel="noreferrer">View source ↗</a></div>
        <footer>
          {!resolved ? <button disabled={!connected || busyID === item.id} onClick={() => void extract(item)}>{busyID === item.id ? "Extracting…" : "Extract"}</button> : <button onClick={() => setActivePlaybackID(item.id)}>View links</button>}
          <button disabled={!connected || busyID === item.id || !resolved} onClick={() => { setActivePlaybackID(item.id); void extract(item); }}>{busyID === item.id && resolved ? "Refreshing…" : "Refresh"}</button>
          <button disabled={busyID === item.id} onClick={() => void setWatched(item, !item.watched)}>{item.watched ? "Mark unwatched" : "Mark watched"}</button>
          <button className="danger" disabled={busyID === item.id} onClick={() => void remove(item.id)}>Remove</button>
        </footer>
      </article>;
      })}</div>}
    {activeItem && activePlayback && <div className="studio-watchlist-modal-backdrop" role="presentation" onMouseDown={() => setActivePlaybackID(null)}>
      <section className="studio-watchlist-modal" role="dialog" aria-modal="true" aria-labelledby="watchlist-results-title" onMouseDown={(event) => event.stopPropagation()}>
        <header><div><p>{activeItem.provider}</p><h2 id="watchlist-results-title">{activeItem.title}</h2><span>Resolved {new Date(activePlayback.resolvedAt).toLocaleTimeString([], { hour: "numeric", minute: "2-digit" })}</span></div><button aria-label="Close extraction results" onClick={() => setActivePlaybackID(null)}>×</button></header>
        <div className="studio-watchlist-modal-actions"><a href={activeItem.sourcePageURL} target="_blank" rel="noreferrer">View source ↗</a><button disabled={!connected || busyID === activeItem.id} onClick={() => void extract(activeItem)}>{busyID === activeItem.id ? "Refreshing…" : "Refresh links"}</button></div>
        <p className="studio-watchlist-modal-note">Temporary provider URLs for external playback. Refresh whenever a URL expires.</p>
        <div className="studio-watchlist-modal-results">{activePlayback.value.qualities.map((quality, index) => {
          const marker = `${activeItem.id}:${index}:${quality.url}`;
          const headers = Object.entries(quality.headers).map(([key, value]) => `${key}: ${value}`).join("\n");
          return <article key={marker}>
            <header><div><strong>{quality.label}</strong><span>{quality.mediaKind === "hls" ? "HLS stream" : "Direct media"}</span></div><b>{index + 1}</b></header>
            <code>{quality.url}</code>
            <footer><button onClick={() => void copy(quality.url, marker)}>{copied === marker ? "Copied" : "Copy URL"}</button>{headers && <button onClick={() => void copy(headers, `${marker}:headers`)}>{copied === `${marker}:headers` ? "Copied" : "Copy headers"}</button>}</footer>
          </article>;
        })}</div>
      </section>
    </div>}
  </section>;
}
