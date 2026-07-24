"use client";

import { useState } from "react";
import { pollingIntervalLabel, supportedPollingIntervals, type PollingInterval } from "@/lib/settings-model";
import { pornHubAuthAction, pornHubAuthLabel, type PornHubAuthState } from "@/lib/pornhub-auth-model";

type PornHubAuthStatus = { state: PornHubAuthState; lastValidatedAt?: string; message?: string };

type Props = {
  connected: boolean;
  pollingInterval: PollingInterval;
  jobsCount: number;
  destinationsCount: number;
  error: string | null;
  onPollingIntervalChange: (value: PollingInterval) => void;
  onRefresh: () => Promise<void>;
  onDisconnect: () => void;
  pornHubAuth: PornHubAuthStatus | null;
  onPornHubSignIn: () => Promise<void>;
  onPornHubSignOut: () => Promise<void>;
};

export function SettingsView({ connected, pollingInterval, jobsCount, destinationsCount, error, onPollingIntervalChange, onRefresh, onDisconnect, pornHubAuth, onPornHubSignIn, onPornHubSignOut }: Props) {
  const [refreshing, setRefreshing] = useState(false);
  const [authWorking, setAuthWorking] = useState(false);
  const refresh = async () => { setRefreshing(true); try { await onRefresh(); } finally { setRefreshing(false); } };
  const authAction = pornHubAuthAction(pornHubAuth?.state);

  return <div className="settings-page">
    <header className="settings-header"><div><p className="eyebrow">Local workspace configuration</p><h2>Settings</h2><p>Control this browser tab’s connection behavior and review the agent security boundary.</p></div><span className="settings-session"><i /> Session only</span></header>
    {error && <p className="inline-error" role="alert">{error}</p>}
    <div className="settings-layout">
      <aside className="settings-index glass-panel" aria-label="Settings sections"><a href="#connection">Connection</a><a href="#pornhub">PornHub</a><a href="#refresh">Live refresh</a><a href="#capabilities">Capabilities</a><a href="#privacy">Privacy & security</a></aside>
      <div className="settings-sections">
        <section className="settings-section glass-panel" id="connection"><header><div><p className="eyebrow">Local agent</p><h3>Connection</h3></div><span className={`settings-status ${connected ? "connected" : ""}`}><i />{connected ? "Connected" : "Disconnected"}</span></header><div className="settings-row"><div><strong>Agent endpoint</strong><p>The development bridge is restricted to the fixed loopback listener.</p></div><code>127.0.0.1:63406</code></div><div className="settings-row"><div><strong>Authenticated session</strong><p>The bearer token remains in React memory and disappears when this tab reloads.</p></div><span>{connected ? "Active" : "Not connected"}</span></div><footer><button className="secondary-button" disabled={!connected || refreshing} onClick={() => void refresh()}>{refreshing ? "Refreshing…" : "Refresh now"}</button><button className="settings-danger" disabled={!connected} onClick={onDisconnect}>Disconnect agent</button></footer></section>

        <section className="settings-section glass-panel" id="pornhub">
          <header><div><p className="eyebrow">Provider session</p><h3>PornHub</h3></div><span className={`settings-status ${authAction === "signOut" ? "connected" : ""}`}><i />{pornHubAuthLabel(pornHubAuth?.state)}</span></header>
          <div className="settings-row"><div><strong>Visible sign-in only</strong><p>Sign-in opens a separate macOS PornHub window. Your credentials go directly to PornHub; Lustre never reads or stores them.</p></div><span>Keychain session</span></div>
          <div className="settings-row"><div><strong>Authenticated feeds</strong><p>Subscriptions, liked videos, and favorites use the local agent’s private session only.</p></div><span>{pornHubAuth?.lastValidatedAt ? "Validated" : "Not validated"}</span></div>
          {pornHubAuth?.message && <p className="settings-note" role="status">{pornHubAuth.message}</p>}
          <footer>{authAction === "signOut" ? <button className="settings-danger" disabled={authWorking} onClick={() => { setAuthWorking(true); void onPornHubSignOut().finally(() => setAuthWorking(false)); }}>{authWorking ? "Signing out…" : "Sign out"}</button> : authAction === "cancel" ? <button className="settings-danger" disabled={authWorking} onClick={() => { setAuthWorking(true); void onPornHubSignOut().finally(() => setAuthWorking(false)); }}>{authWorking ? "Cancelling…" : "Cancel sign-in"}</button> : <button className="secondary-button" disabled={!connected || authWorking} onClick={() => { setAuthWorking(true); void onPornHubSignIn().finally(() => setAuthWorking(false)); }}>{authWorking ? "Opening sign-in…" : "Sign in with PornHub"}</button>}</footer>
        </section>

        <section className="settings-section glass-panel" id="refresh"><header><div><p className="eyebrow">Browser session</p><h3>Live refresh</h3></div><span className="settings-value">{pollingIntervalLabel(pollingInterval)}</span></header><div className="settings-row settings-control"><div><label htmlFor="polling-interval"><strong>Polling cadence</strong></label><p>Controls how often this tab reloads jobs and destination profiles from the local agent.</p></div><select id="polling-interval" value={pollingInterval} onChange={(event) => onPollingIntervalChange(Number(event.target.value) as PollingInterval)}>{supportedPollingIntervals.map((value) => <option value={value} key={value}>{pollingIntervalLabel(value)}</option>)}</select></div><p className="settings-note">This preference applies immediately and is intentionally not persisted beyond the current tab.</p></section>

        <section className="settings-section glass-panel" id="capabilities"><header><div><p className="eyebrow">Detected API surface</p><h3>Agent capabilities</h3></div><span className="settings-value">Live state</span></header><div className="capability-grid"><div><span>Durable jobs</span><strong>{jobsCount}</strong><small>Queue and lifecycle actions</small></div><div><span>WebDAV profiles</span><strong>{destinationsCount}</strong><small>Create, test, and remove</small></div><div><span>Local folders</span><strong>Native</strong><small>macOS folder selection</small></div><div><span>Credentials</span><strong>Keychain</strong><small>Never returned by API</small></div></div><p className="settings-note">Transfer concurrency, bandwidth limits, update channels, and notifications are not shown because the current agent does not expose configuration APIs for them.</p></section>

        <section className="settings-section privacy-section glass-panel" id="privacy"><header><div><p className="eyebrow">Security boundary</p><h3>Privacy & security</h3></div><span className="settings-lock">⌾</span></header><ul><li><i />The browser proxy accepts only normalized <code>/v1/*</code> agent paths.</li><li><i />The Swift listener remains bound to authenticated loopback.</li><li><i />WebDAV passwords and optional PornHub session cookies remain in macOS Keychain and are never returned to the browser.</li><li><i />No Lustre cloud account, device pairing, or public remote-control channel exists in this development build.</li></ul></section>
      </div>
    </div>
  </div>;
}
