const api = globalThis.browser;
const origin = "https://lustrecli.vercel.app";
const providerHosts = ["allpornstream.com", "luluvid.com", "luluvdo.com", "lulustream.com", "playmogo.com", "ds2play.com", "doodstream.com", "dood.wf", "vide0.net", "dooodster.com"];

window.postMessage({ source: "lustre-watch-extension", type: "ready" }, origin);

api.runtime.onMessage.addListener((message) => {
  if (message?.type !== "capture_progress" || !/^[0-9a-f-]{36}$/i.test(message.requestID ?? "")) return;
  window.postMessage({ source: "lustre-watch-extension", ...message }, origin);
});

window.addEventListener("message", (event) => {
  const message = event.data;
  if (event.source !== window || event.origin !== origin || message?.source !== "lustre-watch-app") return;
  if (message.type === "ping") {
    window.postMessage({ source: "lustre-watch-extension", type: "ready", requestID: message.requestID }, origin);
    return;
  }
  if (!["resolve_provider", "capture_allpornstream_feed", "cancel_provider"].includes(message.type)) return;
  if (!/^[0-9a-f-]{36}$/i.test(message.requestID ?? "")) return;
  if (message.type === "cancel_provider") {
    api.runtime.sendMessage(message).catch(() => {});
    return;
  }
  if (message.type === "capture_allpornstream_feed") {
    if (!Number.isSafeInteger(message.page) || message.page < 1 || message.page > 1000 || typeof message.q !== "string" || message.q.length > 120) return;
  } else {
    let url;
    try { url = new URL(message.sourcePageURL); } catch { return; }
    if (url.protocol !== "https:" || !providerHosts.some((host) => url.hostname === host || url.hostname.endsWith(`.${host}`))) return;
  }
  api.runtime.sendMessage(message).then((response) => {
    window.postMessage({ source: "lustre-watch-extension", requestID: message.requestID, ...response }, origin);
  }).catch(() => {
    window.postMessage({ source: "lustre-watch-extension", requestID: message.requestID, type: "capture_failed", message: "Firefox extension capture failed." }, origin);
  });
});
