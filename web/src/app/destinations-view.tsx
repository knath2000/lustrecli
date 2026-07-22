"use client";

import { FormEvent, useMemo, useState } from "react";
import { destinationSecurityLabel, destinationUsageCounts, safeDestinationHost } from "@/lib/destination-model";

export type DestinationProfile = {
  id: string;
  name: string;
  baseURL: string;
  username: string;
  remotePath: string;
  allowInvalidCertificate: boolean;
};

type DestinationJob = { destination: string };
type DestinationInput = Omit<DestinationProfile, "id"> & { password: string };
type TestState = { kind: "testing" | "success" | "error"; message: string };

type DestinationsViewProps = {
  destinations: DestinationProfile[];
  jobs: DestinationJob[];
  error: string | null;
  onSave: (input: DestinationInput) => Promise<void>;
  onTest: (id: string) => Promise<string>;
  onDelete: (id: string) => Promise<void>;
};

function ServerGlyph() {
  return <svg width="21" height="21" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.7" aria-hidden><rect x="3" y="4" width="18" height="6" rx="1.5" /><rect x="3" y="14" width="18" height="6" rx="1.5" /><path d="M7 7h.01M7 17h.01M11 7h6M11 17h6" /></svg>;
}

function FolderGlyph() {
  return <svg width="21" height="21" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.7" aria-hidden><path d="M3.5 7.5h6l2 2h9V18a2 2 0 0 1-2 2h-13a2 2 0 0 1-2-2Z" /><path d="M3.5 7.5V6a2 2 0 0 1 2-2h4l2 2h7a2 2 0 0 1 2 2v1.5" /></svg>;
}

export function DestinationsView({ destinations, jobs, error, onSave, onTest, onDelete }: DestinationsViewProps) {
  const [showForm, setShowForm] = useState(false);
  const [saving, setSaving] = useState(false);
  const [formError, setFormError] = useState<string | null>(null);
  const [tests, setTests] = useState<Record<string, TestState>>({});
  const [deletingId, setDeletingId] = useState<string | null>(null);
  const usage = useMemo(() => destinationUsageCounts(jobs), [jobs]);

  const save = async (event: FormEvent<HTMLFormElement>) => {
    event.preventDefault();
    setFormError(null);
    const form = new FormData(event.currentTarget);
    const baseURL = String(form.get("baseURL") ?? "").trim();
    const remotePath = String(form.get("remotePath") ?? "").trim() || "/";
    try {
      const parsed = new URL(baseURL);
      if (parsed.protocol !== "https:") throw new Error("The WebDAV endpoint must use HTTPS.");
      if (!remotePath.startsWith("/") || remotePath.split("/").some((part) => part === "." || part === "..")) throw new Error("Remote path must be absolute and cannot contain traversal segments.");
      setSaving(true);
      await onSave({
        name: String(form.get("name") ?? "").trim(),
        baseURL,
        username: String(form.get("username") ?? "").trim(),
        password: String(form.get("password") ?? ""),
        remotePath,
        allowInvalidCertificate: form.get("allowInvalidCertificate") === "on",
      });
      setShowForm(false);
    } catch (reason) {
      setFormError(reason instanceof Error ? reason.message : "Unable to save this destination.");
    } finally {
      setSaving(false);
    }
  };

  const test = async (profile: DestinationProfile) => {
    setTests((current) => ({ ...current, [profile.id]: { kind: "testing", message: "Checking authentication, folders, and write access…" } }));
    try {
      const message = await onTest(profile.id);
      setTests((current) => ({ ...current, [profile.id]: { kind: "success", message } }));
    } catch (reason) {
      setTests((current) => ({ ...current, [profile.id]: { kind: "error", message: reason instanceof Error ? reason.message : "Connection test failed." } }));
    }
  };

  const remove = async (profile: DestinationProfile) => {
    if (!window.confirm(`Remove ${profile.name}? Existing job records will keep their destination identifier, but new transfers cannot use this profile.`)) return;
    setDeletingId(profile.id);
    try { await onDelete(profile.id); }
    finally { setDeletingId(null); }
  };

  return <div className="destinations-page">
    <header className="destinations-header">
      <div><p className="eyebrow">Transfer endpoints</p><h2>Destinations</h2><p>Control where the local Lustre agent writes completed media.</p></div>
      <button className="queue-button" onClick={() => setShowForm(true)}>＋ Add WebDAV</button>
    </header>

    <section className="destination-summary" aria-label="Destination summary">
      <div><span>Available targets</span><strong>{destinations.length + 1}</strong></div>
      <div><span>Remote profiles</span><strong>{destinations.length}</strong></div>
      <div><span>Remote jobs</span><strong>{jobs.filter((job) => /^webdav:/i.test(job.destination)).length}</strong></div>
      <p><i /> Credentials stay in the macOS Keychain</p>
    </section>

    {error && <p className="inline-error destinations-error" role="alert">{error}</p>}

    <section className="destination-grid" aria-label="Saved destinations">
      <article className="destination-card local-destination glass-panel">
        <header><span className="destination-icon"><FolderGlyph /></span><div><p className="eyebrow">Built-in target</p><h3>Local Downloads</h3></div><span className="destination-kind">Local</span></header>
        <p className="destination-description">Files remain on this Mac under Lustre’s managed Downloads folder.</p>
        <dl><div><dt>Location</dt><dd>~/Downloads/Lustre</dd></div><div><dt>Security</dt><dd>On-device filesystem</dd></div><div><dt>Used by</dt><dd>{usage.local ?? 0} job{(usage.local ?? 0) === 1 ? "" : "s"}</dd></div></dl>
        <footer><span className="destination-health ready"><i /> Always available</span><span className="managed-label">Managed by agent</span></footer>
      </article>

      {destinations.map((profile) => {
        const state = tests[profile.id];
        return <article className="destination-card glass-panel" key={profile.id}>
          <header><span className="destination-icon remote"><ServerGlyph /></span><div><p className="eyebrow">WebDAV profile</p><h3>{profile.name}</h3></div><span className="destination-kind">Remote</span></header>
          <p className="destination-description">{safeDestinationHost(profile.baseURL)}</p>
          <dl><div><dt>Remote path</dt><dd>{profile.remotePath}</dd></div><div><dt>Username</dt><dd>{profile.username}</dd></div><div><dt>Security</dt><dd className={profile.allowInvalidCertificate ? "certificate-warning" : ""}>{destinationSecurityLabel(profile.allowInvalidCertificate)}</dd></div><div><dt>Used by</dt><dd>{usage[profile.id.toLowerCase()] ?? 0} job{(usage[profile.id.toLowerCase()] ?? 0) === 1 ? "" : "s"}</dd></div></dl>
          {state && <p className={`destination-test-result ${state.kind}`} role="status"><i />{state.message}</p>}
          <footer><button className="destination-test" disabled={state?.kind === "testing"} onClick={() => void test(profile)}>{state?.kind === "testing" ? "Testing…" : "Test connection"}</button><button className="destination-delete" disabled={deletingId === profile.id} onClick={() => void remove(profile)}>{deletingId === profile.id ? "Removing…" : "Remove"}</button></footer>
        </article>;
      })}

      {!destinations.length && <article className="destination-empty glass-panel"><span><ServerGlyph /></span><h3>No remote destinations</h3><p>Add a WebDAV profile to stream compatible transfers off-device.</p><button className="queue-button" onClick={() => setShowForm(true)}>Add WebDAV</button></article>}
    </section>

    <section className="destination-privacy glass-panel"><span>⌾</span><div><h3>Local-first credential boundary</h3><p>Profile settings stay in the agent’s Application Support directory. Passwords are written directly to macOS Keychain and are never returned by the API or stored in this browser.</p></div></section>

    {showForm && <div className="modal-backdrop" role="presentation"><section className="destination-sheet" role="dialog" aria-modal="true" aria-labelledby="destination-form-title"><button className="modal-close" aria-label="Close destination form" onClick={() => setShowForm(false)}>×</button><header><p className="eyebrow">New transfer endpoint</p><h2 id="destination-form-title">Add WebDAV destination</h2><p>Lustre verifies HTTPS configuration when saving. Run a connection test afterward to validate authentication, folder creation, writing, and cleanup.</p></header><form onSubmit={save}>
      <div className="destination-form-grid"><label className="field-label">Profile name<input name="name" required autoFocus placeholder="Media server" /></label><label className="field-label">HTTPS WebDAV URL<input name="baseURL" type="url" required placeholder="https://server.example/dav" /></label><label className="field-label">Username<input name="username" required autoComplete="username" placeholder="lustre" /></label><label className="field-label">Password<input name="password" type="password" required autoComplete="new-password" placeholder="Stored in Keychain" /></label><label className="field-label full">Remote path<input name="remotePath" required defaultValue="/" placeholder="/downloads" /></label></div>
      <label className="certificate-toggle"><input type="checkbox" name="allowInvalidCertificate" /><span><strong>Allow this host’s invalid TLS certificate</strong><small>Use only for a trusted private server. The exception is restricted to the exact configured host.</small></span></label>
      {formError && <p className="form-error" role="alert">{formError}</p>}
      <footer><p>Passwords travel only over the authenticated loopback bridge to the local agent.</p><div><button type="button" className="secondary-button" onClick={() => setShowForm(false)}>Cancel</button><button className="initiate-button" disabled={saving}>{saving ? "Saving…" : "Save destination"}</button></div></footer>
    </form></section></div>}
  </div>;
}
