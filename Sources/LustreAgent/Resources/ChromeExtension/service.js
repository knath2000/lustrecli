const nativeHost = "com.pmvdl.lustre_browser_bridge";

chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
  if (message?.type !== "feed_capture_v1" || !sender.tab?.id) return false;
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

  chrome.storage.session.set({ [`capture:${message.requestID}`]: tabId }).then(() => {
    chrome.runtime.sendNativeMessage(nativeHost, message, async (response) => {
      if (chrome.runtime.lastError) {
        sendResponse({ type: "capture_rejected", code: "native_host_unavailable" });
        return;
      }
      if (response?.type === "capture_accepted" && response.requestID === message.requestID) {
        const stored = await chrome.storage.session.get(`capture:${message.requestID}`);
        if (stored[`capture:${message.requestID}`] === tabId) {
          await chrome.storage.session.remove(`capture:${message.requestID}`);
          await chrome.tabs.remove(tabId);
        }
      }
      sendResponse(response ?? { type: "capture_rejected", code: "invalid_native_response" });
    });
  });
  return true;
});

chrome.tabs.onRemoved.addListener(async (tabId) => {
  const captures = await chrome.storage.session.get(null);
  for (const [key, ownedTabID] of Object.entries(captures)) {
    if (!key.startsWith("capture:") || ownedTabID !== tabId) continue;
    const requestID = key.slice("capture:".length);
    await chrome.storage.session.remove(key);
    chrome.runtime.sendNativeMessage(nativeHost, {
      type: "capture_closed_v1",
      version: 1,
      requestID
    }).catch(() => {});
  }
});
