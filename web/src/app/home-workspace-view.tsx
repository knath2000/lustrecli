"use client";

import { KeyboardEvent, useCallback, useEffect, useMemo, useState } from "react";
import { previewURLBatches } from "@/lib/home-workspace-model";
import type { DestinationProfile } from "./destinations-view";

export type HomeReadiness = { ytDlp: boolean; ffmpeg: boolean; browserBridge: boolean };
export type HomePreviewQuality = { label: string; mediaKind: "direct" | "hls" | "yt-dlp" };
export type HomePreviewItem = {
  sourcePageURL: string;
  state: "resolved" | "verificationRequired" | "unsupported" | "failed";
  title?: string | null;
  thumbnailURL?: string | null;
  provider?: string | null;
  qualities: HomePreviewQuality[];
  errorCode?: string | null;
};

type ReviewItem = HomePreviewItem & {
  selected: boolean;
  quality: string;
  destination: string;
  queueState: "ready" | "queueing" | "queued" | "queueFailed";
  requestID: string;
};

type PendingPreviewBatch = {
  commandID?: string;
  currentURLs?: string[];
  remainingBatches: string[][];
  completedPreview: HomePreviewItem[];
  submittedURLs: string[];
  replace: boolean;
};

type Props = {
  deviceID: string;
  connected: boolean;
  jobCounts: {
    active: number;
    queued: number;
    failed: number;
    completed: number;
  };
  destinations: DestinationProfile[];
  onJobsChanged: () => Promise<void>;
  onOpenDownloads: (status: "active" | "queued" | "failed" | "completed") => void;
};

function commandMessage(code: unknown) {
  if (code === "provider_verification_required") return "Complete browser verification on the paired Mac, then retry.";
  if (code === "provider_unreachable") return "The paired Mac could not reach this source.";
  if (code === "provider_changed") return "This source is unsupported or its page format changed.";
  if (code === "result_too_large") return "The extraction result exceeded the safe Cloud limit.";
  if (code === "command_expired") return "The paired Mac did not receive this command in time.";
  return "The paired Mac could not complete this request.";
}

async function waitForCommand(deviceID: string, commandID: string, maximumAttempts = 150) {
  for (let attempt = 0; attempt < maximumAttempts; attempt += 1) {
    if (attempt) await new Promise((resolve) => window.setTimeout(resolve, 2_000));
    const response = await fetch(`/api/cloud/v1/devices/${deviceID}/commands/${commandID}`, { cache: "no-store" });
    const payload = await response.json().catch(() => ({}));
    if (!response.ok) throw new Error(payload.error?.message ?? "Command status is unavailable.");
    if (payload.command.status === "completed") return payload.command.result as Record<string, unknown>;
    if (payload.command.status === "failed") throw new Error(commandMessage(payload.command.result?.code));
  }
  throw new Error(maximumAttempts < 150 ? "Update paired Mac to enable extraction preview." : "The paired Mac did not respond within five minutes.");
}

async function beginCommand(deviceID: string, body: Record<string, unknown>) {
  const response = await fetch(`/api/cloud/v1/devices/${deviceID}/commands`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(body),
    cache: "no-store",
  });
  const payload = await response.json().catch(() => ({}));
  if (!response.ok) throw new Error(payload.error?.message ?? "Unable to contact the paired Mac.");
  return payload.command.id as string;
}

function destinationValue(item: DestinationProfile) {
  return `${item.kind === "google_drive" ? "gdrive" : "webdav"}:${item.id}`;
}

function parseURLs(text: string) {
  const lines = text.split(/\r?\n/).map((line) => line.trim()).filter(Boolean);
  const valid: string[] = [];
  const invalid: string[] = [];
  for (const line of lines) {
    try {
      const url = new URL(line);
      if (url.protocol !== "https:" || url.username || url.password) throw new Error();
      if (!valid.includes(url.toString())) valid.push(url.toString());
    } catch {
      invalid.push(line);
    }
  }
  return { lines, valid, invalid };
}

function previewToReview(item: HomePreviewItem, destination: string): ReviewItem {
  return {
    ...item,
    selected: item.state === "resolved",
    quality: "",
    destination,
    queueState: "ready",
    requestID: crypto.randomUUID(),
  };
}

function PreviewThumbnail({ deviceID, url }: { deviceID: string; url?: string | null; title: string }) {
  const [source, setSource] = useState<string | null>(null);
  useEffect(() => {
    if (!url) return;
    let active = true;
    let objectURL: string | null = null;
    void (async () => {
      const ticketResponse = await fetch(`/api/cloud/v1/devices/${deviceID}/feed-assets/ticket`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ url, kind: "image" }),
        cache: "no-store",
      });
      const ticket = await ticketResponse.json();
      if (!ticketResponse.ok) return;
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
  }, [deviceID, url]);
  return source ? <img src={source} alt="" /> : <span aria-hidden>▶</span>;
}

export function HomeWorkspaceView({ deviceID, connected, jobCounts, destinations, onJobsChanged, onOpenDownloads }: Props) {
  const storageKey = `lustre.home.workspace.${deviceID}`;
  const commandKey = `lustre.home.command.${deviceID}`;
  const [draft, setDraft] = useState("");
  const [readiness, setReadiness] = useState<HomeReadiness | null>(null);
  const [previewAvailable, setPreviewAvailable] = useState<boolean | null>(null);
  const [items, setItems] = useState<ReviewItem[]>([]);
  const [defaultDestination, setDefaultDestination] = useState("local");
  const [extracting, setExtracting] = useState(false);
  const [extractionProgress, setExtractionProgress] = useState<{ completed: number; total: number } | null>(null);
  const [showReview, setShowReview] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const parsed = useMemo(() => parseURLs(draft), [draft]);

  useEffect(() => {
    try {
      const stored = JSON.parse(sessionStorage.getItem(storageKey) ?? "{}");
      queueMicrotask(() => {
        if (typeof stored.draft === "string") setDraft(stored.draft);
        if (typeof stored.defaultDestination === "string") setDefaultDestination(stored.defaultDestination);
        if (Array.isArray(stored.items)) setItems(stored.items);
      });
    } catch {}
  }, [storageKey]);

  useEffect(() => {
    sessionStorage.setItem(storageKey, JSON.stringify({ draft, defaultDestination, items }));
  }, [defaultDestination, draft, items, storageKey]);

  const applyPreview = useCallback((preview: HomePreviewItem[], replaceURLs?: Set<string>) => {
    setItems((current) => {
      const replacements = new Map(preview.map((item) => [item.sourcePageURL, previewToReview(item, defaultDestination)]));
      if (!replaceURLs) return preview.map((item) => replacements.get(item.sourcePageURL)!);
      return current.map((item) => replaceURLs.has(item.sourcePageURL) ? replacements.get(item.sourcePageURL) ?? item : item);
    });
    setShowReview(true);
  }, [defaultDestination]);

  const runPreviewBatch = useCallback(async (initial: PendingPreviewBatch) => {
    setExtracting(true);
    setError(null);
    let pending = initial;
    try {
      while (pending.commandID || pending.remainingBatches.length) {
        if (!pending.commandID) {
          const [currentURLs, ...remainingBatches] = pending.remainingBatches;
          if (!currentURLs?.length) break;
          const commandID = await beginCommand(deviceID, { kind: "extract_preview", urls: currentURLs });
          pending = { ...pending, commandID, currentURLs, remainingBatches };
          sessionStorage.setItem(commandKey, JSON.stringify(pending));
        }
        const commandID = pending.commandID;
        if (!commandID) break;
        setExtractionProgress({ completed: pending.completedPreview.length, total: pending.submittedURLs.length });
        const result = await waitForCommand(deviceID, commandID);
        const preview = Array.isArray(result.homePreview) ? result.homePreview as HomePreviewItem[] : [];
        pending = {
          ...pending,
          commandID: undefined,
          currentURLs: undefined,
          completedPreview: [...pending.completedPreview, ...preview],
        };
        sessionStorage.setItem(commandKey, JSON.stringify(pending));
      }
      applyPreview(pending.completedPreview, pending.replace ? new Set(pending.submittedURLs) : undefined);
      sessionStorage.removeItem(commandKey);
    } catch (reason) {
      setError(reason instanceof Error ? reason.message : "Extraction failed.");
    } finally {
      setExtracting(false);
      setExtractionProgress(null);
    }
  }, [applyPreview, commandKey, deviceID]);

  useEffect(() => {
    let active = true;
    if (!connected) return;
    void beginCommand(deviceID, { kind: "home_status" })
      .then((id) => waitForCommand(deviceID, id, 10))
      .then((result) => {
        if (active && result.homeReadiness) {
          setReadiness(result.homeReadiness as HomeReadiness);
          setPreviewAvailable(true);
        }
      })
      .catch(() => {
        if (active) {
          setReadiness(null);
          setPreviewAvailable(false);
          setError("Update paired Mac to enable extraction preview.");
        }
      });
    try {
      const pending = JSON.parse(sessionStorage.getItem(commandKey) ?? "null");
      if (pending && Array.isArray(pending.submittedURLs) && Array.isArray(pending.remainingBatches) && Array.isArray(pending.completedPreview)) {
        queueMicrotask(() => void runPreviewBatch(pending as PendingPreviewBatch));
      }
    } catch {}
    return () => { active = false; };
  }, [commandKey, connected, deviceID, runPreviewBatch]);

  const extract = async (urls?: string[], replace = false) => {
    const submittedURLs = urls ?? parsed.valid;
    if (!connected) return setError("The paired Mac is offline.");
    if (previewAvailable === false) return setError("Update paired Mac to enable extraction preview.");
    if (!submittedURLs.length || (!urls && parsed.invalid.length)) return;
    try {
      await runPreviewBatch({
        remainingBatches: previewURLBatches(submittedURLs),
        completedPreview: [],
        submittedURLs,
        replace,
      });
    } catch (reason) {
      setError(reason instanceof Error ? reason.message : "Unable to begin extraction.");
    }
  };

  const paste = async () => {
    try {
      const value = await navigator.clipboard.readText();
      setDraft((current) => current.trim() ? `${current.trim()}\n${value.trim()}` : value.trim());
    } catch {
      setError("Clipboard access was denied. Paste into the URL field directly.");
    }
  };

  const queueItems = async (targets: ReviewItem[]) => {
    const pending = targets.filter((item) => item.state === "resolved" && item.queueState !== "queued");
    for (let start = 0; start < pending.length; start += 3) {
      await Promise.all(pending.slice(start, start + 3).map(async (item) => {
        setItems((current) => current.map((candidate) => candidate.sourcePageURL === item.sourcePageURL ? { ...candidate, queueState: "queueing" } : candidate));
        try {
          const commandID = await beginCommand(deviceID, {
            kind: "queue_url",
            requestID: item.requestID,
            url: item.sourcePageURL,
            title: item.title || undefined,
            preferredQualityLabel: item.quality || undefined,
            destination: item.destination,
          });
          await waitForCommand(deviceID, commandID);
          setItems((current) => current.map((candidate) => candidate.sourcePageURL === item.sourcePageURL ? { ...candidate, queueState: "queued" } : candidate));
        } catch {
          setItems((current) => current.map((candidate) => candidate.sourcePageURL === item.sourcePageURL ? { ...candidate, queueState: "queueFailed", requestID: crypto.randomUUID() } : candidate));
        }
      }));
    }
    await onJobsChanged();
  };

  const counts = jobCounts;
  const selected = items.filter((item) => item.selected && item.state === "resolved" && item.queueState !== "queued");
  const failed = items.filter((item) => item.state !== "resolved");

  const editorKeyDown = (event: KeyboardEvent<HTMLTextAreaElement>) => {
    if (event.key === "Enter" && (event.metaKey || event.ctrlKey)) {
      event.preventDefault();
      void extract();
    }
  };

  return <div className="studio-home">
    <header className="studio-home-heading">
      <div>
        <p>READY WHEN YOU ARE</p>
        <h1>Extract anything</h1>
      </div>
      <p>Resolve single videos or entire batches, then send them to the destination you choose.</p>
    </header>
    <section className="studio-command-card">
      <header className="studio-brand">
        <span className="studio-mark" aria-hidden>LS</span>
        <div><strong>Lustre Studio</strong><span>Cloud extraction workspace</span></div>
      </header>
      <div className="studio-readiness">
        <span className={connected ? "ready" : "missing"}>● {connected ? "paired Mac" : "Mac offline"}</span>
        <span className={readiness?.ytDlp ? "ready" : "missing"}>● yt-dlp</span>
        <span className={readiness?.ffmpeg ? "ready" : "missing"}>● ffmpeg</span>
        <span className={readiness?.browserBridge ? "ready" : "missing"}>● browser bridge</span>
      </div>

      <div className="studio-editor-card" onDragOver={(event) => event.preventDefault()} onDrop={(event) => { event.preventDefault(); const value = event.dataTransfer.getData("text/plain"); if (value) setDraft((current) => current ? `${current}\n${value}` : value); }}>
        <div><strong>{parsed.valid.length} Ready</strong><small>{parsed.invalid.length ? `${parsed.invalid.length} invalid URL${parsed.invalid.length === 1 ? "" : "s"}` : "Paste supported video URLs, one per line."}</small><em>🔗 {parsed.valid.length}</em></div>
        <textarea value={draft} onChange={(event) => setDraft(event.target.value)} onKeyDown={editorKeyDown} placeholder="https://pmvhaven.com/video/…&#10;Paste one URL per line" aria-label="Video URLs" />
      </div>
      <div className="studio-actions">
        <div><button onClick={() => void paste()}>▣ Paste</button><button onClick={() => { setDraft(""); setItems([]); setError(null); sessionStorage.removeItem(commandKey); }}>× Clear</button></div>
        <button className="studio-extract" disabled={extracting || !connected || !parsed.valid.length || !!parsed.invalid.length} onClick={() => void extract()}>{extracting ? `Extracting${extractionProgress ? ` ${extractionProgress.completed}/${extractionProgress.total}` : "…"}` : "ϟ Extract"}</button>
      </div>
      {error && <p className="studio-error" role="alert">{error}</p>}

      <div className="studio-job-cards">
        {(["active", "queued", "failed", "completed"] as const).map((status) => <button key={status} onClick={() => onOpenDownloads(status)}><span>{status === "active" ? "↓" : status === "queued" ? "◷" : status === "failed" ? "!" : "✓"}</span><strong>{status[0].toUpperCase() + status.slice(1)}</strong><b>{counts[status]}</b></button>)}
      </div>

      <h2>Supported</h2>
      <div className="studio-supported">
        <div><span>▶</span><strong>Video</strong></div>
        <div><span>♪</span><strong>Audio</strong></div>
        <div><span>●●</span><strong>Social</strong></div>
        <div><span>◎</span><strong>Web</strong></div>
      </div>
    </section>

    {showReview && <div className="studio-modal-backdrop">
      <section className="studio-review" role="dialog" aria-modal="true" aria-labelledby="studio-review-title">
        <header><div><p>Extraction review</p><h2 id="studio-review-title">{items.length} source{items.length === 1 ? "" : "s"} reviewed</h2></div><button aria-label="Close extraction review" onClick={() => setShowReview(false)}>×</button></header>
        <div className="studio-review-toolbar">
          <label>Batch destination<select value={defaultDestination} onChange={(event) => { const value = event.target.value; setDefaultDestination(value); setItems((current) => current.map((item) => item.queueState === "ready" ? { ...item, destination: value } : item)); }}><option value="local">Local Downloads</option>{destinations.map((item) => <option key={item.id} value={destinationValue(item)}>{item.name}</option>)}</select></label>
          {failed.length > 0 && <button onClick={() => void extract(failed.map((item) => item.sourcePageURL), true)}>↻ Retry Failed</button>}
        </div>
        <div className="studio-review-list">
          {items.map((item) => <article key={item.sourcePageURL} className={`studio-review-row state-${item.state}`}>
            <input type="checkbox" checked={item.selected} disabled={item.state !== "resolved" || item.queueState === "queued"} onChange={(event) => setItems((current) => current.map((candidate) => candidate.sourcePageURL === item.sourcePageURL ? { ...candidate, selected: event.target.checked } : candidate))} aria-label={`Select ${item.title ?? item.sourcePageURL}`} />
            <PreviewThumbnail deviceID={deviceID} url={item.thumbnailURL} title={item.title ?? "Video"} />
            <div className="studio-review-info"><strong>{item.title ?? new URL(item.sourcePageURL).pathname.split("/").filter(Boolean).at(-1) ?? "Video"}</strong><small>{item.provider ?? "Source"} · {item.state === "resolved" ? `${item.qualities.length} qualities` : commandMessage(item.errorCode)}</small><a href={item.sourcePageURL} target="_blank" rel="noreferrer">{item.sourcePageURL}</a></div>
            {item.state === "resolved" ? <div className="studio-review-controls"><select value={item.quality} onChange={(event) => setItems((current) => current.map((candidate) => candidate.sourcePageURL === item.sourcePageURL ? { ...candidate, quality: event.target.value } : candidate))}><option value="">Automatic quality</option>{item.qualities.map((quality) => <option key={`${quality.label}-${quality.mediaKind}`} value={quality.label}>{quality.label}</option>)}</select><select value={item.destination} onChange={(event) => setItems((current) => current.map((candidate) => candidate.sourcePageURL === item.sourcePageURL ? { ...candidate, destination: event.target.value } : candidate))}><option value="local">Local Downloads</option>{destinations.map((destination) => <option key={destination.id} value={destinationValue(destination)}>{destination.name}</option>)}</select><span>{item.queueState === "queued" ? "Queued ✓" : item.queueState === "queueing" ? "Queueing…" : item.queueState === "queueFailed" ? "Queue failed" : "Ready"}</span></div> : <button className="studio-row-retry" onClick={() => void extract([item.sourcePageURL], true)}>{item.state === "verificationRequired" ? "Retry Verification" : "Retry"}</button>}
          </article>)}
        </div>
        <footer><span>{selected.length} selected</span><div><button onClick={() => setShowReview(false)}>Close</button><button disabled={!selected.length} onClick={() => void queueItems(selected)}>Queue Selected</button><button disabled={!items.some((item) => item.state === "resolved" && item.queueState !== "queued")} onClick={() => void queueItems(items)}>Queue All</button></div></footer>
      </section>
    </div>}
  </div>;
}
