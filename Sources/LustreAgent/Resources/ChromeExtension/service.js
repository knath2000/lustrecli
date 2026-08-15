const nativeHost = "com.pmvdl.lustre_browser_bridge";
const extensionAPI = globalThis.browser ?? globalThis.chrome;

function sendNativeMessage(message) {
  if (globalThis.browser) return extensionAPI.runtime.sendNativeMessage(nativeHost, message);
  return new Promise((resolve, reject) => {
    extensionAPI.runtime.sendNativeMessage(nativeHost, message, (response) => {
      if (extensionAPI.runtime.lastError) reject(extensionAPI.runtime.lastError);
      else resolve(response);
    });
  });
}

extensionAPI.runtime.onMessage.addListener((message, sender, sendResponse) => {
  if (message?.type === "pornhub_auth_probe_v1" && sender.tab?.id) {
    const tabId = sender.tab.id;
    const tabURL = new URL(sender.tab.url);
    if (tabURL.protocol !== "https:" || !["pornhub.com", "www.pornhub.com"].includes(tabURL.hostname)) {
      sendResponse({ type: "capture_rejected", code: "unexpected_host" });
      return false;
    }
    const storageKey = `pornhub-auth:${tabId}`;
    const resolveRequestID = async () => {
      if (message.requestID) {
        await extensionAPI.storage.session.set({ [storageKey]: message.requestID });
        return message.requestID;
      }
      const stored = await extensionAPI.storage.session.get(storageKey);
      return stored[storageKey];
    };
    resolveRequestID().then(async (requestID) => {
      if (!requestID) return { type: "capture_pending" };
      const cookies = await extensionAPI.cookies.getAll({ domain: "pornhub.com" });
      if (!cookies.some((cookie) => cookie.name === "il")) return { type: "capture_pending", requestID };
      return sendNativeMessage({
        type: "pornhub_auth_v1",
        version: 1,
        requestID,
        pageURL: sender.tab.url.split("#")[0],
        capturedAt: new Date().toISOString(),
        cookies: cookies.map((cookie) => ({
          name: cookie.name,
          value: cookie.value,
          domain: cookie.domain,
          path: cookie.path,
          expiresAt: cookie.expirationDate ? new Date(cookie.expirationDate * 1000).toISOString() : null,
          secure: cookie.secure,
          hostOnly: cookie.hostOnly
        }))
      });
    }).then(async (response) => {
      if (response?.type === "capture_accepted") {
        await extensionAPI.storage.session.remove(storageKey);
        await extensionAPI.tabs.remove(tabId);
      }
      sendResponse(response ?? { type: "capture_rejected", code: "invalid_native_response" });
    }).catch(() => sendResponse({ type: "capture_rejected", code: "native_host_unavailable" }));
    return true;
  }
  if (!["feed_capture_v1", "post_capture_v1"].includes(message?.type) || !sender.tab?.id) return false;
  const tabId = sender.tab.id;
  let tabURL;
  try { tabURL = new URL(sender.tab.url); }
  catch {
    sendResponse({ type: "capture_rejected", code: "unexpected_host" });
    return false;
  }
  if (tabURL.protocol !== "https:" || !["allpornstream.com", "www.allpornstream.com"].includes(tabURL.hostname)) {
    sendResponse({ type: "capture_rejected", code: "unexpected_host" });
    return false;
  }

  extensionAPI.storage.session.set({ [`capture:${message.requestID}`]: tabId }).then(() => {
    sendNativeMessage(message).then(async (response) => {
      if (!response) {
        sendResponse({ type: "capture_rejected", code: "native_host_unavailable" });
        return;
      }
      if (response?.type === "capture_accepted" && response.requestID === message.requestID) {
        const stored = await extensionAPI.storage.session.get(`capture:${message.requestID}`);
        if (stored[`capture:${message.requestID}`] === tabId) {
          await extensionAPI.storage.session.remove(`capture:${message.requestID}`);
          await extensionAPI.tabs.remove(tabId);
        }
      }
      sendResponse(response ?? { type: "capture_rejected", code: "invalid_native_response" });
    }).catch(() => {
      sendResponse({ type: "capture_rejected", code: "native_host_unavailable" });
    });
  });
  return true;
});

extensionAPI.tabs.onRemoved.addListener(async (tabId) => {
  const captures = await extensionAPI.storage.session.get(null);
  for (const [key, ownedTabID] of Object.entries(captures)) {
    if (key === `pornhub-auth:${tabId}`) {
      await extensionAPI.storage.session.remove(key);
      sendNativeMessage({
        type: "pornhub_auth_closed_v1",
        version: 1,
        requestID: ownedTabID
      }).catch(() => {});
      continue;
    }
    if (!key.startsWith("capture:") || ownedTabID !== tabId) continue;
    const requestID = key.slice("capture:".length);
    await extensionAPI.storage.session.remove(key);
    sendNativeMessage({
      type: "capture_closed_v1",
      version: 1,
      requestID
    }).catch(() => {});
  }
});
