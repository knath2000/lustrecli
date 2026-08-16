const api = globalThis.browser;
const appOrigin = "https://lustrecli.vercel.app";
const captures = new Map();
const providerHosts = ["allpornstream.com", "luluvid.com", "luluvdo.com", "lulustream.com", "playmogo.com", "ds2play.com", "doodstream.com", "dood.wf", "vide0.net", "dooodster.com"];
const delay = (milliseconds) => new Promise((resolve) => setTimeout(resolve, milliseconds));

function headersByName(values = []) {
  return Object.fromEntries(values.flatMap(({ name, value }) => typeof value === "string" ? [[name.toLowerCase(), value]] : []));
}

function progress(capture, message) {
  api.tabs.sendMessage(capture.originTabId, {
    type: "capture_progress",
    requestID: capture.requestID,
    message
  }).catch(() => {});
}

function finish(tabId, response) {
  const capture = captures.get(tabId);
  if (!capture) return;
  captures.delete(tabId);
  clearTimeout(capture.timer);
  api.tabs.remove(tabId).catch(() => {});
  capture.resolve(response);
}

api.webRequest.onBeforeSendHeaders.addListener((details) => {
  const capture = captures.get(details.tabId);
  if (capture) capture.requests.set(details.requestId, headersByName(details.requestHeaders));
}, { urls: ["<all_urls>"] }, ["requestHeaders"]);

api.webRequest.onHeadersReceived.addListener((details) => {
  if (!captures.has(details.tabId)) return;
  const responseHeaders = headersByName(details.responseHeaders);
  const mime = String(responseHeaders["content-type"] ?? "").toLowerCase();
  const media = globalThis.LustreMediaCapture.classifyMediaResponse(details.url, mime, Number(details.statusCode));
  if (!media) return;
  const requestHeaders = captures.get(details.tabId).requests.get(details.requestId) ?? {};
  const headers = {};
  for (const [source, target] of [["referer", "Referer"], ["origin", "Origin"], ["user-agent", "User-Agent"]]) {
    const value = requestHeaders[source];
    if (typeof value === "string" && value.length <= 1000) headers[target] = value;
  }
  progress(captures.get(details.tabId), media.cloudAta ? "Playmogo media response detected." : "Playable media response observed.");
  finish(details.tabId, {
    type: "capture_resolved",
    title: "AllPornStream video",
    quality: {
      label: "Firefox capture",
      url: media.url,
      mediaKind: media.mediaKind,
      headers,
      provider: new URL(media.url).hostname,
      resolutionMethod: "browser_capture",
      infuseCompatibility: Object.keys(headers).some((name) => name === "Referer" || name === "Origin") ? "header_required" : "unknown"
    }
  });
}, { urls: ["<all_urls>"] }, ["responseHeaders"]);

function waitForLoad(tabId, timeout = 20_000) {
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => {
      api.tabs.onUpdated.removeListener(listener);
      reject(new Error("timeout"));
    }, timeout);
    const listener = (updatedTabId, info) => {
      if (updatedTabId !== tabId || info.status !== "complete") return;
      clearTimeout(timer);
      api.tabs.onUpdated.removeListener(listener);
      resolve();
    };
    api.tabs.onUpdated.addListener(listener);
  });
}

async function captureFeed(message) {
  const page = Number(message.page);
  const q = String(message.q ?? "").trim();
  if (!Number.isSafeInteger(page) || page < 1 || page > 1000 || q.length > 120) return { type: "capture_failed", message: "Invalid feed request." };
  const target = new URL("https://allpornstream.com/");
  if (q) target.searchParams.set("s", q);
  if (page > 1) target.searchParams.set("page", String(page));
  const tab = await api.tabs.create({ url: target.href, active: true });
  try {
    await waitForLoad(tab.id);
    await delay(1000);
    const execution = await api.scripting.executeScript({
      target: { tabId: tab.id },
      args: [page],
      func: (currentPage) => {
        const output = [];
        const seen = new Set();
        const visit = (value) => {
          if (!value || typeof value !== "object") return;
          if (!Array.isArray(value) && value["@type"] === "VideoObject") {
            try {
              const source = new URL(value.url, location.origin);
              const id = source.pathname.match(/^\/post\/([0-9a-f-]{36})\//i)?.[1];
              const title = typeof value.name === "string" ? value.name.replace(/\s+/g, " ").trim() : "";
              if (id && title && !seen.has(source.href)) {
                seen.add(source.href);
                const card = [...document.querySelectorAll("[data-href],[data-slug]")].find((node) =>
                  node.getAttribute("data-href") === source.pathname || node.getAttribute("data-slug") === source.pathname);
                let extras = [];
                try { extras = JSON.parse(card?.getAttribute("data-images") || "[]"); } catch {}
                const rawImages = [...extras, ...(Array.isArray(value.thumbnailUrl) ? value.thumbnailUrl : [value.thumbnailUrl])];
                const images = [...new Set(rawImages.flatMap((raw) => {
                  try {
                    const direct = new URL(raw, location.origin);
                    if (direct.protocol !== "https:") return [];
                    const proxy = new URL("/api/images", location.origin);
                    proxy.searchParams.set("src", direct.href);
                    proxy.searchParams.set("width", "384");
                    proxy.searchParams.set("quality", "60");
                    return [proxy.href];
                  } catch { return []; }
                }))].slice(0, 5);
                const statistic = Array.isArray(value.interactionStatistic) ? value.interactionStatistic[0] : value.interactionStatistic;
                const views = Number(statistic?.userInteractionCount);
                const date = typeof value.uploadDate === "string" && !Number.isNaN(Date.parse(value.uploadDate)) ? new Date(value.uploadDate).toISOString() : new Date(0).toISOString();
                const studio = title.match(/^\[([^\]]+)\]/)?.[1]?.trim();
                output.push({
                  id: `allpornstream-${id}`,
                  siteID: "allpornstream",
                  title,
                  sourcePageURL: source.href,
                  ...(images[0] ? { thumbnailURL: images[0] } : {}),
                  previewURLs: images.slice(1, 5),
                  uploadedAt: date,
                  uploadedAtIsApproximate: false,
                  viewCount: Number.isSafeInteger(views) && views >= 0 ? views : 0,
                  ...(studio ? { studio } : {})
                });
              }
            } catch {}
          }
          for (const child of Object.values(value)) Array.isArray(child) ? child.forEach(visit) : visit(child);
        };
        for (const script of document.querySelectorAll("script[type='application/ld+json']")) {
          try { visit(JSON.parse(script.textContent || "")); } catch {}
        }
        return { items: output.slice(0, 50), page: currentPage, hasMore: output.length >= 50 || Boolean(document.querySelector("a[rel='next']")) };
      }
    });
    const result = execution[0]?.result;
    return result?.items?.length
      ? { type: "feed_captured", result }
      : { type: "capture_failed", message: "AllPornStream did not return feed cards after browser verification." };
  } catch {
    return { type: "capture_failed", message: "AllPornStream Firefox feed capture timed out." };
  } finally {
    api.tabs.remove(tab.id).catch(() => {});
  }
}

async function capturePlayback(message) {
  const source = new URL(message.sourcePageURL);
  if (!providerHosts.some((host) => source.hostname === host || source.hostname.endsWith(`.${host}`))) return { type: "capture_failed", message: "Unsupported source." };
  const tab = await api.tabs.create({ url: source.href, active: true });
  return new Promise(async (resolve) => {
    const timer = setTimeout(() => finish(tab.id, { type: "capture_failed", message: "No playable Firefox source was detected." }), 45_000);
    const capture = { resolve, timer, requests: new Map(), originTabId: message.originTabId, requestID: message.requestID };
    captures.set(tab.id, capture);
    progress(capture, "Temporary provider tab opened.");
    try {
      await waitForLoad(tab.id);
      progress(capture, "Provider tab loaded.");
      await delay(1500);
      if (source.hostname !== "allpornstream.com" && !source.hostname.endsWith(".allpornstream.com")) {
        await api.scripting.executeScript({
          target: { tabId: tab.id },
          func: () => {
            for (const selector of ["video", "button[aria-label*='play' i]", ".play", ".vjs-big-play-button", "[class*='play']"]) document.querySelector(selector)?.click();
          }
        }).catch(() => {});
        progress(capture, "Provider player opened; waiting for media.");
        return;
      }
      const extracted = await api.scripting.executeScript({
        target: { tabId: tab.id },
        func: () => {
          const html = document.documentElement.innerHTML.replaceAll("\\/", "/").replaceAll('\\"', '"');
          const urls = [];
          for (const match of html.matchAll(/"(?:embed_url|link)"\s*:\s*"(https:[^"]+)"/gi)) urls.push(match[1]);
          for (const match of html.matchAll(/\[\s*"[^"]+"\s*,\s*"(https:[^"]+)"\s*\]/gi)) urls.push(match[1]);
          return [...new Set(urls)].slice(0, 12);
        }
      });
      const providerURLs = execution[0]?.result ?? [];
      progress(capture, providerURLs.length ? `${providerURLs.length} provider candidate${providerURLs.length === 1 ? "" : "s"} found.` : "No provider metadata found yet.");
      for (const providerURL of providerURLs) {
        if (!captures.has(tab.id)) break;
        let parsed;
        try { parsed = new URL(providerURL); } catch { continue; }
        if (parsed.protocol !== "https:" || parsed.username || parsed.password) continue;
        progress(capture, `Opening ${parsed.hostname} provider tab.`);
        await api.tabs.update(tab.id, { url: parsed.href });
        await waitForLoad(tab.id, 12_000).catch(() => {});
        if (!captures.has(tab.id)) break;
        await api.scripting.executeScript({
          target: { tabId: tab.id },
          func: () => {
            for (const selector of ["video", "button[aria-label*='play' i]", ".play", ".vjs-big-play-button", "[class*='play']"]) document.querySelector(selector)?.click();
          }
        }).catch(() => {});
        await delay(6000);
      }
    } catch {
      finish(tab.id, { type: "capture_failed", message: "Firefox network capture could not start." });
    }
  });
}

api.runtime.onMessage.addListener((message, sender) => {
  if (!["resolve_provider", "capture_allpornstream_feed", "cancel_provider"].includes(message?.type)
    || !sender.tab?.id
    || !sender.url?.startsWith(`${appOrigin}/`)) return undefined;
  if (message.type === "cancel_provider") {
    for (const [tabId, capture] of captures) {
      if (capture.requestID === message.requestID && capture.originTabId === sender.tab.id) {
        finish(tabId, { type: "capture_failed", message: "Browser capture cancelled." });
        break;
      }
    }
    return Promise.resolve({ type: "capture_cancelled" });
  }
  if (message.type === "capture_allpornstream_feed") return captureFeed(message);
  return capturePlayback({ ...message, originTabId: sender.tab.id });
});

api.tabs.onRemoved.addListener((tabId) => {
  if (captures.has(tabId)) finish(tabId, { type: "capture_failed", message: "Provider tab was closed." });
});
