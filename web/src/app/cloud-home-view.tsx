"use client";
import { useCallback, useEffect, useState } from "react";
import { CloudDashboardView } from "./cloud-dashboard-view";

type Device = { id: string; displayName: string; revokedAt: string | null };
const selectedDeviceKey = "lustre.cloud.selected-device";
async function api<T>(path: string): Promise<T> { const response = await fetch(path, { cache: "no-store" }); const payload = await response.json().catch(() => ({})); if (!response.ok) throw new Error(payload.error?.message ?? "Unable to load Lustre Cloud."); return payload as T; }

export function CloudHomeView() {
  const [devices, setDevices] = useState<Device[]>([]); const [selectedDeviceID, setSelectedDeviceID] = useState<string | null>(null); const [error, setError] = useState<string | null>(null);
  const load = useCallback(async () => { try { const next = (await api<{ devices: Device[] }>("/api/cloud/v1/devices")).devices.filter((device) => !device.revokedAt); setDevices(next); const saved = window.localStorage.getItem(selectedDeviceKey); setSelectedDeviceID((current) => current && next.some((device) => device.id === current) ? current : next.find((device) => device.id === saved)?.id ?? next[0]?.id ?? null); } catch (reason) { setError(reason instanceof Error ? reason.message : "Unable to load your Macs."); } }, []);
  useEffect(() => { void load(); }, [load]);
  const select = (id: string) => { window.localStorage.setItem(selectedDeviceKey, id); setSelectedDeviceID(id); };
  const selected = devices.find((device) => device.id === selectedDeviceID);
  if (error) return <main className="cloud-devices"><section className="cloud-empty"><h1>Lustre Cloud</h1><p>{error}</p><a className="secondary-button" href="/devices">Manage devices</a></section></main>;
  if (!selected) return <main className="cloud-devices"><section className="cloud-empty"><h1>Lustre Cloud</h1><p>Pair a Mac before opening the remote dashboard.</p><a className="initiate-button" href="/devices">Manage devices</a></section></main>;
  return <main className="cloud-devices"><header><div><p className="eyebrow">Lustre Cloud</p><h1>Remote dashboard</h1><p>Controlling {selected.displayName} through its paired agent.</p></div><div>{devices.length > 1 && <select value={selected.id} onChange={(event) => select(event.target.value)} aria-label="Paired Mac">{devices.map((device) => <option key={device.id} value={device.id}>{device.displayName}</option>)}</select>}<a className="secondary-button" href="/devices">Devices</a></div></header><CloudDashboardView deviceID={selected.id} deviceName={selected.displayName} /></main>;
}
