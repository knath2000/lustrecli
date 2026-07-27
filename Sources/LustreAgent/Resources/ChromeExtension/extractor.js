globalThis.LustreAllPornStreamExtractor = (() => {
  function values(value) {
    return Array.isArray(value) ? value : value == null ? [] : [value];
  }

  function interactionCount(value) {
    const statistic = Array.isArray(value) ? value[0] : value;
    const number = Number(statistic?.userInteractionCount ?? 0);
    return Number.isSafeInteger(number) && number >= 0 ? number : 0;
  }

  function proxiedImage(raw, origin) {
    try {
      const url = new URL(raw, origin);
      if (url.protocol !== "https:") return null;
      const source = url.origin === origin && url.pathname === "/api/images"
        ? new URL(url.searchParams.get("src"))
        : url;
      if (source.protocol !== "https:") return null;
      const proxy = new URL("/api/images", origin);
      proxy.searchParams.set("src", source.href);
      proxy.searchParams.set("width", "384");
      proxy.searchParams.set("quality", "60");
      return proxy.href;
    } catch {
      return null;
    }
  }

  function itemLists(scripts) {
    const roots = [];
    for (const script of scripts) {
      try { roots.push(JSON.parse(script)); } catch {}
    }
    const lists = [];
    const visit = (value) => {
      if (!value || typeof value !== "object") return;
      if (value["@type"] === "ItemList" && Array.isArray(value.itemListElement)) lists.push(value);
      for (const child of Object.values(value)) {
        if (Array.isArray(child)) child.forEach(visit);
        else if (child && typeof child === "object") visit(child);
      }
    };
    roots.forEach(visit);
    return lists;
  }

  function extract(snapshot) {
    if (/just a moment|verify you are human|checking your browser/i.test(`${snapshot.title} ${snapshot.bodyText}`)) return null;
    const list = itemLists(snapshot.scripts).find((candidate) => candidate.itemListElement.some((item) => item?.["@type"] === "VideoObject"));
    if (!list) return null;
    const cards = [];
    for (const item of list.itemListElement) {
      if (item?.["@type"] !== "VideoObject") continue;
      let sourcePageURL;
      try { sourcePageURL = new URL(item.url, snapshot.origin).href; } catch { continue; }
      const path = new URL(sourcePageURL).pathname;
      const title = Array.from(
        String(item.name ?? "").normalize("NFC").replace(/\p{C}/gu, " ").replace(/\s+/g, " ").trim()
      ).slice(0, 512).join("");
      if (!title) continue;
      const previews = [...new Set((snapshot.previews[path] ?? []).map((raw) => proxiedImage(raw, snapshot.origin)).filter(Boolean))].slice(0, 4);
      const thumbnails = values(item.thumbnailUrl).map((raw) => proxiedImage(raw, snapshot.origin)).filter(Boolean);
      const thumbnailURL = previews[0] ?? thumbnails[0] ?? null;
      cards.push({
        title,
        sourcePageURL,
        thumbnailURL,
        previewURLs: previews.filter((url) => url !== thumbnailURL).slice(0, 4),
        uploadedAt: String(item.uploadDate ?? ""),
        viewCount: interactionCount(item.interactionStatistic),
        studio: null
      });
      if (cards.length === 50) break;
    }
    return cards.length ? { cards, hasMore: list.itemListElement.length > cards.length } : null;
  }

  return { extract };
})();
