"use client";

import { useCallback, useEffect, useMemo, useState } from "react";
import type { DestinationProfile } from "./destinations-view";

type Stage = { destination: string; state: string; updatedAt: string };
export type LibraryItem = { id: string; kind: "video" | "link" | "upload" | "favorite"; sourcePageURL: string; title: string; provider: string; thumbnailURL?: string | null; timestamp: string; tags: string[]; collection?: string | null; favorite: boolean; duplicateKey: string; mediaKind: "video" | "audio" | "web"; pipeline: Stage[] };
type Props = { deviceID: string; connected: boolean; destinations: DestinationProfile[]; onReExtract: (url: string) => void; onJobsChanged: () => Promise<void> | void };

async function begin(deviceID: string, body: Record<string, unknown>) {
  const response = await fetch(`/api/cloud/v1/devices/${deviceID}/commands`, { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(body), cache: "no-store" });
  const payload = await response.json().catch(() => ({}));
  if (!response.ok) throw new Error(payload.error?.message ?? "Unable to contact the paired Mac.");
  return payload.command.id as string;
}

async function wait(deviceID: string, commandID: string, attempts = 150) {
  for (let attempt = 0; attempt < attempts; attempt += 1) {
    if (attempt) await new Promise((resolve) => window.setTimeout(resolve, 2_000));
    const response = await fetch(`/api/cloud/v1/devices/${deviceID}/commands/${commandID}`, { cache: "no-store" });
    const payload = await response.json().catch(() => ({}));
    if (!response.ok) throw new Error(payload.error?.message ?? "Library command status is unavailable.");
    if (payload.command.status === "completed") return payload.command.result as { library?: { revision: number; items: LibraryItem[]; verification?: { message: string } } };
    if (payload.command.status === "failed") throw new Error("The paired Mac could not complete this Library action.");
  }
  throw new Error("Update paired Mac to enable Library sync and actions.");
}

function destinationValue(destination: DestinationProfile) {
  return `${destination.kind === "google_drive" ? "gdrive" : "webdav"}:${destination.id}`;
}

function LibraryThumbnail({ deviceID, item }: { deviceID: string; item: LibraryItem }) {
  const [source, setSource] = useState<string | null>(null);
  useEffect(() => {
    if (!item.thumbnailURL) return;
    let active = true;
    let objectURL: string | null = null;
    void (async () => {
      const ticketResponse = await fetch(`/api/cloud/v1/devices/${deviceID}/feed-assets/ticket`, { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ url: item.thumbnailURL, kind: "image" }) });
      const ticket = await ticketResponse.json().catch(() => ({}));
      if (!ticketResponse.ok) return;
      const asset = await fetch(ticket.assetURL, { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ ticket: ticket.ticket }) });
      if (!asset.ok || !active) return;
      objectURL = URL.createObjectURL(await asset.blob());
      setSource(objectURL);
    })();
    return () => { active = false; if (objectURL) URL.revokeObjectURL(objectURL); };
  }, [deviceID, item.thumbnailURL]);
  return source ? <img src={source} alt="" /> : <span>{item.mediaKind === "audio" ? "♫" : item.kind === "upload" ? "☁" : "▶"}</span>;
}

export function LibraryView({ deviceID, connected, destinations, onReExtract, onJobsChanged }: Props) {
  const sessionKey = `lustre.library.view.${deviceID}`;
  const [items, setItems] = useState<LibraryItem[]>([]);
  const [syncedAt, setSyncedAt] = useState<string | null>(null);
  const [query, setQuery] = useState("");
  const [filter, setFilter] = useState("all");
  const [scope, setScope] = useState("all");
  const [mode, setMode] = useState<"list" | "grid">("list");
  const [selection, setSelection] = useState<Set<string>>(new Set());
  const [detailID, setDetailID] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [verification, setVerification] = useState<string | null>(null);
  const [destination, setDestination] = useState("local");

  useEffect(() => {
    try {
      const stored = JSON.parse(sessionStorage.getItem(sessionKey) ?? "{}");
      if (typeof stored.query === "string") setQuery(stored.query);
      if (typeof stored.filter === "string") setFilter(stored.filter);
      if (typeof stored.scope === "string") setScope(stored.scope);
      if (stored.mode === "list" || stored.mode === "grid") setMode(stored.mode);
      if (Array.isArray(stored.selection)) setSelection(new Set(stored.selection));
      if (typeof stored.detailID === "string") setDetailID(stored.detailID);
    } catch {}
  }, [sessionKey]);

  useEffect(() => {
    sessionStorage.setItem(sessionKey, JSON.stringify({ query, filter, scope, mode, selection: [...selection], detailID }));
  }, [detailID, filter, mode, query, scope, selection, sessionKey]);

  const loadCache = useCallback(async () => {
    const response = await fetch(`/api/cloud/v1/devices/${deviceID}/library`, { cache: "no-store" });
    const payload = await response.json().catch(() => ({}));
    if (response.ok && payload.library) {
      setItems(payload.library.items as LibraryItem[]);
      setSyncedAt(payload.library.syncedAt);
    }
  }, [deviceID]);

  const refresh = useCallback(async () => {
    await loadCache();
    if (!connected) return;
    setBusy(true); setError(null);
    try {
      const result = await wait(deviceID, await begin(deviceID, { kind: "library_list", page: 1 }), 10);
      if (result.library) {
        setItems(result.library.items);
        setSyncedAt(new Date().toISOString());
      }
    } catch (reason) {
      setError(reason instanceof Error ? reason.message : "Unable to refresh Library.");
    } finally {
      setBusy(false);
    }
  }, [connected, deviceID, loadCache]);

  useEffect(() => { void refresh(); }, [refresh]);

  const counts = useMemo(() => ({
    all: items.length,
    videos: items.filter((item) => item.kind === "video").length,
    links: items.filter((item) => item.kind === "link").length,
    uploads: items.filter((item) => item.kind === "upload").length,
    favorites: items.filter((item) => item.favorite || item.kind === "favorite").length,
  }), [items]);
  const duplicateKeys = useMemo(() => {
    const counts = new Map<string, number>();
    items.forEach((item) => counts.set(item.duplicateKey, (counts.get(item.duplicateKey) ?? 0) + 1));
    return new Set([...counts].filter(([, count]) => count > 1).map(([key]) => key));
  }, [items]);
  const visible = useMemo(() => items.filter((item) => {
    const text = `${item.title} ${item.provider} ${item.sourcePageURL} ${item.tags.join(" ")} ${item.collection ?? ""} ${item.pipeline.map((stage) => `${stage.destination} ${stage.state}`).join(" ")}`.toLowerCase();
    if (query.trim() && !text.includes(query.trim().toLowerCase())) return false;
    if (filter === "videos" && item.kind !== "video") return false;
    if (filter === "links" && item.kind !== "link") return false;
    if (filter === "uploads" && item.kind !== "upload") return false;
    if (filter === "favorites" && !item.favorite && item.kind !== "favorite") return false;
    if (scope === "remote" && !item.pipeline.some((stage) => stage.destination !== "Local Downloads" && stage.state === "succeeded")) return false;
    if (scope === "unfiled" && (item.tags.length || item.collection)) return false;
    if (scope === "duplicates" && !duplicateKeys.has(item.duplicateKey)) return false;
    return true;
  }), [duplicateKeys, filter, items, query, scope]);
  const detail = items.find((item) => item.id === detailID) ?? null;

  const runMutation = async (kind: "library_update" | "library_remove" | "library_verify", itemID: string, fields: Record<string, unknown> = {}) => {
    const result = await wait(deviceID, await begin(deviceID, { kind, itemID, ...fields }));
    if (result.library) {
      setItems(result.library.items);
      setVerification(result.library.verification?.message ?? null);
    }
    return result;
  };

  const mutate = async (kind: "library_update" | "library_remove" | "library_verify", itemID: string, fields: Record<string, unknown> = {}) => {
    if (!connected) return;
    setBusy(true); setError(null);
    try {
      await runMutation(kind, itemID, fields);
      if (kind === "library_remove") { setDetailID(null); setSelection((current) => { const next = new Set(current); next.delete(itemID); return next; }); }
    } catch (reason) {
      setError(reason instanceof Error ? reason.message : "Library action failed.");
    } finally { setBusy(false); }
  };

  const mutateSelected = async (kind: "library_remove" | "library_verify") => {
    const pending = [...selection];
    const succeeded = new Set<string>();
    const failures: string[] = [];
    setBusy(true); setError(null);
    try {
      for (let start = 0; start < pending.length; start += 3) {
        const batch = pending.slice(start, start + 3);
        const results = await Promise.allSettled(batch.map((id) => runMutation(kind, id)));
        results.forEach((result, index) => {
          if (result.status === "fulfilled") succeeded.add(batch[index]);
          else failures.push(batch[index]);
        });
      }
      if (kind === "library_remove") {
        setSelection((current) => new Set([...current].filter((id) => !succeeded.has(id))));
        if (detailID && succeeded.has(detailID)) setDetailID(null);
      }
      if (failures.length) setError(`${failures.length} Library action${failures.length === 1 ? "" : "s"} failed. Successful items were not resubmitted.`);
    } finally {
      setBusy(false);
    }
  };

  const sendSelected = async () => {
    const targets = items.filter((item) => selection.has(item.id));
    const succeeded = new Set<string>();
    const failures: string[] = [];
    setBusy(true); setError(null);
    try {
      for (let start = 0; start < targets.length; start += 3) {
        const batch = targets.slice(start, start + 3);
        const results = await Promise.allSettled(batch.map(async (item) => {
          const commandID = await begin(deviceID, { kind: "queue_url", requestID: crypto.randomUUID(), url: item.sourcePageURL, destination });
          await wait(deviceID, commandID);
        }));
        results.forEach((result, index) => {
          if (result.status === "fulfilled") succeeded.add(batch[index].id);
          else failures.push(batch[index].id);
        });
      }
      if (succeeded.size) await onJobsChanged();
      setSelection((current) => new Set([...current].filter((id) => !succeeded.has(id))));
      if (failures.length) setError(`${failures.length} item${failures.length === 1 ? "" : "s"} could not be queued. Retry will submit failed items only.`);
    } finally {
      setBusy(false);
    }
  };

  const toggle = (id: string) => setSelection((current) => { const next = new Set(current); next.has(id) ? next.delete(id) : next.add(id); return next; });
  const grouped = Map.groupBy(visible, (item) => new Date(item.timestamp).toLocaleDateString(undefined, { year: "numeric", month: "long", day: "numeric" }));

  return <section className="studio-library">
    <div className="studio-library-panel">
      <header><div><h1>Library</h1><p>Review downloaded videos, saved links, uploads, and favorites.</p></div><div className="studio-library-pills"><span>{visible.length === items.length ? `${items.length} items` : `${visible.length} of ${items.length}`}</span><span>{counts.videos} videos</span><span>{counts.favorites} favorites</span></div></header>
      <div className="studio-library-tools">
        <label><span>⌕</span><input value={query} onChange={(event) => setQuery(event.target.value)} placeholder="Search title, provider, URL, destination, or tag" /></label>
        <select value={scope} onChange={(event) => setScope(event.target.value)}><option value="all">All items</option><option value="remote">Remote copies</option><option value="unfiled">Unfiled</option><option value="duplicates">Possible duplicates</option></select>
        <div className="studio-library-mode"><button className={mode === "list" ? "active" : ""} onClick={() => setMode("list")}>☷</button><button className={mode === "grid" ? "active" : ""} onClick={() => setMode("grid")}>▦</button></div>
        <button onClick={() => void refresh()} disabled={busy}>{busy ? "Refreshing…" : "↻ Refresh"}</button>
      </div>
      <nav className="studio-library-filters">{(["all", "videos", "links", "uploads", "favorites"] as const).map((value) => <button key={value} className={filter === value ? "active" : ""} onClick={() => setFilter(value)}>{value[0].toUpperCase() + value.slice(1)} <b>{counts[value]}</b></button>)}</nav>
      <div className="studio-library-sync">{connected ? "Paired Mac online" : "Offline snapshot"}{syncedAt ? ` · Synced ${new Date(syncedAt).toLocaleString()}` : ""}</div>
      {error && <p className="inline-error" role="alert">{error}</p>}
      {!connected && <p className="studio-library-offline">Update paired Mac to enable Library sync and actions. Cached browsing remains available.</p>}
      {!visible.length ? <div className="studio-library-empty"><span>▣</span><h2>{items.length ? "No matching items" : "Your Library is ready"}</h2><p>Completed downloads will appear here after the next sync.</p></div> :
        <div className={`studio-library-content ${mode}`}>
          {[...grouped].map(([day, entries]) => <section key={day}><h2>{day} <b>{entries.length}</b></h2><div>{entries.map((item) => <article key={item.id} className={selection.has(item.id) ? "selected" : ""}>
            <button className="studio-library-check" aria-label={`Select ${item.title}`} onClick={(event) => { event.stopPropagation(); toggle(item.id); }}>{selection.has(item.id) ? "✓" : ""}</button>
            <button className="studio-library-card" onClick={() => setDetailID(item.id)}>
              <div className="studio-library-thumb"><LibraryThumbnail deviceID={deviceID} item={item} />{item.favorite && <i>♥</i>}</div>
              <div className="studio-library-card-copy"><strong>{item.title}</strong><span>{item.provider} · {item.kind}</span><small>{item.pipeline.map((stage) => `${stage.destination}: ${stage.state}`).join(" · ") || "No destination record"}</small>{item.tags.length > 0 && <em>{item.tags.join(" · ")}</em>}</div>
              {duplicateKeys.has(item.duplicateKey) && <b className="studio-library-duplicate">Duplicate</b>}
            </button>
          </article>)}</div></section>)}
        </div>}
    </div>
    {selection.size > 0 && <div className="studio-library-selection"><strong>{selection.size} selected</strong><select value={destination} onChange={(event) => setDestination(event.target.value)}><option value="local">Local Downloads</option>{destinations.map((item) => <option key={item.id} value={destinationValue(item)}>{item.name}</option>)}</select><button disabled={!connected || busy} onClick={() => void sendSelected()}>Send</button><button disabled={!connected || busy} onClick={() => void mutateSelected("library_verify")}>Verify Copies</button><button className="danger" disabled={!connected || busy} onClick={() => void mutateSelected("library_remove")}>Remove</button><button onClick={() => setSelection(new Set())}>Clear</button></div>}
    {detail && <LibraryDetail item={detail} connected={connected} busy={busy} verification={verification} destinations={destinations} onClose={() => { setDetailID(null); setVerification(null); }} onReExtract={onReExtract} onUpdate={(fields) => mutate("library_update", detail.id, fields)} onVerify={() => mutate("library_verify", detail.id)} onRemove={() => mutate("library_remove", detail.id)} onSend={async (target) => { const commandID = await begin(deviceID, { kind: "queue_url", requestID: crypto.randomUUID(), url: detail.sourcePageURL, destination: target }); await wait(deviceID, commandID); await onJobsChanged(); }} />}
  </section>;
}

function LibraryDetail({ item, connected, busy, verification, destinations, onClose, onReExtract, onUpdate, onVerify, onRemove, onSend }: { item: LibraryItem; connected: boolean; busy: boolean; verification: string | null; destinations: DestinationProfile[]; onClose: () => void; onReExtract: (url: string) => void; onUpdate: (fields: Record<string, unknown>) => void; onVerify: () => void; onRemove: () => void; onSend: (destination: string) => Promise<void> }) {
  const [tags, setTags] = useState(item.tags.join(", "));
  const [collection, setCollection] = useState(item.collection ?? "");
  const [destination, setDestination] = useState("local");
  return <div className="studio-review-backdrop" role="dialog" aria-modal="true" aria-label="Library item details"><div className="studio-library-detail">
    <header><div><p>{item.kind} · {item.provider}</p><h2>{item.title}</h2></div><button onClick={onClose}>×</button></header>
    <div className="studio-library-detail-grid">
      <section><h3>Source</h3><a href={item.sourcePageURL} target="_blank" rel="noreferrer">{item.sourcePageURL}</a><p>{new Date(item.timestamp).toLocaleString()}</p></section>
      <section><h3>Pipeline</h3>{item.pipeline.map((stage) => <p key={stage.destination}><b>{stage.destination}</b><span>{stage.state}</span></p>)}</section>
      <section><h3>Organize</h3><input value={collection} onChange={(event) => setCollection(event.target.value)} placeholder="Collection" maxLength={80} /><input value={tags} onChange={(event) => setTags(event.target.value)} placeholder="Tags, separated by commas" /><button disabled={!connected || busy} onClick={() => onUpdate({ tags: tags.split(",").map((tag) => tag.trim()).filter(Boolean).slice(0, 20), collection })}>Save Organization</button></section>
      <section><h3>Actions</h3><button onClick={() => window.open(item.sourcePageURL, "_blank", "noopener,noreferrer")}>Open Source</button><button disabled={!connected} onClick={() => onReExtract(item.sourcePageURL)}>Re-extract</button><button disabled={!connected || busy} onClick={() => onUpdate({ tags: item.tags, collection: item.collection ?? "", favorite: !item.favorite })}>{item.favorite ? "Remove Favorite" : "Favorite"}</button><button disabled={!connected || busy} onClick={onVerify}>Verify Copies</button><div><select value={destination} onChange={(event) => setDestination(event.target.value)}><option value="local">Local Downloads</option>{destinations.map((target) => <option key={target.id} value={destinationValue(target)}>{target.name}</option>)}</select><button disabled={!connected || busy} onClick={() => void onSend(destination)}>Send</button></div><button className="danger" disabled={!connected || busy} onClick={onRemove}>Remove from Library</button></section>
    </div>
    {verification && <p className="studio-library-verification">{verification}</p>}
  </div></div>;
}
