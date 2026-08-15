(() => {
  const extensionAPI = globalThis.browser ?? globalThis.chrome;
  const fragment = new URL(location.href).hash;
  const marker = fragment.match(/(?:^#|&)lustre-(feed|post)-capture=([0-9a-f-]{36})(?:&|$)/i);
  if (!marker) return;
  const captureKind = marker[1].toLowerCase();
  const requestID = marker[2].toLowerCase();
  const startedAt = Date.now();
  let sending = false;

  function snapshot() {
    const previews = {};
    for (const card of document.querySelectorAll("[data-href], [data-slug], article")) {
      const links = [card.getAttribute("data-href"), card.getAttribute("data-slug"), ...[...card.querySelectorAll("a[href]")].map((link) => link.href)];
      const path = links.map((value) => {
        try { return value ? new URL(value, location.origin).pathname : null; } catch { return null; }
      }).find(Boolean);
      if (!path) continue;
      const candidates = [];
      try {
        const images = JSON.parse(card.getAttribute("data-images") ?? "[]");
        if (Array.isArray(images)) candidates.push(...images);
      } catch {}
      if (!candidates.length) {
        const mountedFrames = card.querySelectorAll(".snap-center img, .snap-center source");
        const media = mountedFrames.length
          ? mountedFrames
          : card.querySelectorAll(".relative.w-full img, .relative.w-full source");
        for (const image of media) {
          candidates.push(image.currentSrc, image.src, image.getAttribute("data-src"));
          const srcset = image.srcset || image.getAttribute("data-srcset");
          if (srcset) candidates.push(...srcset.split(",").map((entry) => entry.trim().split(/\s+/)[0]));
        }
      }
      previews[path] = candidates.filter(Boolean);
    }
    return {
      title: document.title,
      bodyText: document.body?.innerText?.slice(0, 1000) ?? "",
      origin: location.origin,
      scripts: [...document.querySelectorAll('script[type="application/ld+json"]')].map((script) => script.textContent),
      metadataScripts: [...document.scripts].map((script) => script.textContent ?? "").filter((source) => /video_urls|hosting_provider/i.test(source)),
      previews
    };
  }

  const timer = setInterval(async () => {
    if (sending || Date.now() - startedAt > 5 * 60 * 1000) {
      if (Date.now() - startedAt > 5 * 60 * 1000) clearInterval(timer);
      return;
    }
    const result = captureKind === "post"
      ? globalThis.LustreAllPornStreamExtractor.extractPost(snapshot())
      : globalThis.LustreAllPornStreamExtractor.extract(snapshot());
    if (!result) return;
    sending = true;
    const response = await extensionAPI.runtime.sendMessage({
      type: captureKind === "post" ? "post_capture_v1" : "feed_capture_v1",
      version: 1,
      requestID,
      siteID: "allpornstream",
      pageURL: location.href.split("#")[0],
      capturedAt: new Date().toISOString(),
      ...(captureKind === "post"
        ? { metadataSources: result.metadataSources }
        : { cards: result.cards, hasMore: result.hasMore })
    }).catch(() => null);
    if (response?.type !== "capture_accepted") sending = false;
  }, 1000);
})();
