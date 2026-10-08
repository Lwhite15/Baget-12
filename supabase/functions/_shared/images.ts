// Finds a product photo for a listing: the image the store publishes for link previews (og:image and friends).
// Claude's web search rarely returns image links, and the ones it does can be made up, so the page is the source.

const BLOCKED_HOST = /^(localhost|.+\.local|.+\.internal|.+\.localdomain|metadata\.google\.internal)$/i;

/** Only public https pages on the default port. No IP literals, so nothing internal is reachable. */
export function safePublicUrl(raw: string, base?: string): URL | null {
  let u: URL;
  try { u = base ? new URL(raw, base) : new URL(raw); } catch { return null; }
  if (u.protocol !== "https:") return null;
  const h = u.hostname;
  if (!h.includes(".") || BLOCKED_HOST.test(h)) return null;
  if (/^\d{1,3}(\.\d{1,3}){3}$/.test(h) || h.includes(":") || h.startsWith("[")) return null;
  if (u.port && u.port !== "443") return null;
  if (u.username || u.password) return null;
  return u;
}

function attrs(tag: string): Record<string, string> {
  const out: Record<string, string> = {};
  for (const m of tag.matchAll(/([a-zA-Z_:.-]+)\s*=\s*("([^"]*)"|'([^']*)'|([^\s>]+))/g)) {
    out[m[1].toLowerCase()] = (m[3] ?? m[4] ?? m[5] ?? "").trim();
  }
  return out;
}

const decode = (s: string) =>
  s.replace(/&amp;/g, "&").replace(/&quot;/g, '"').replace(/&#39;/g, "'").replace(/&#x2F;/gi, "/").replace(/&lt;/g, "<").replace(/&gt;/g, ">");

/** The best product image in a page's HTML, as an absolute https URL. */
export function extractImage(html: string, pageUrl: string): string | null {
  const found: { rank: number; url: string }[] = [];
  const rankOf: Record<string, number> = {
    "og:image:secure_url": 0, "og:image:url": 1, "og:image": 1, "twitter:image": 2, "twitter:image:src": 2, "product:image": 2,
  };
  for (const m of html.matchAll(/<meta\b[^>]*>/gi)) {
    const a = attrs(m[0]);
    const key = (a.property ?? a.name ?? a.itemprop ?? "").toLowerCase();
    const rank = key === "image" ? 3 : rankOf[key];
    if (rank !== undefined && a.content) found.push({ rank, url: a.content });
  }
  for (const m of html.matchAll(/<link\b[^>]*>/gi)) {
    const a = attrs(m[0]);
    if ((a.rel ?? "").toLowerCase() === "image_src" && a.href) found.push({ rank: 3, url: a.href });
  }
  // JSON-LD Product: "image": "..." or ["..."] or {"url": "..."}
  for (const m of html.matchAll(/<script[^>]+application\/ld\+json[^>]*>([\s\S]*?)<\/script>/gi)) {
    const im = m[1].match(/"image"\s*:\s*(?:\[\s*)?(?:\{[^}]*?"url"\s*:\s*)?"([^"]+)"/);
    if (im) found.push({ rank: 4, url: im[1].replace(/\\\//g, "/") });
  }
  found.sort((x, y) => x.rank - y.rank);
  for (const f of found) {
    const raw = decode(f.url);
    if (raw.startsWith("data:")) continue;
    const u = safePublicUrl(raw.startsWith("//") ? "https:" + raw : raw, pageUrl);
    if (u && !/\.svg(\?|$)/i.test(u.pathname)) return u.toString().slice(0, 500);
  }
  return null;
}

type FetchFn = (input: string, init?: RequestInit) => Promise<Response>;

/** Fetches the page (following up to 3 safe redirects, reading at most 600 KB) and returns its product image. */
export async function findImage(pageUrl: string, fetchFn: FetchFn = fetch, timeoutMs = 5000): Promise<string | null> {
  let url = safePublicUrl(pageUrl);
  for (let hop = 0; url && hop < 4; hop++) {
    const res = await fetchFn(url.toString(), {
      redirect: "manual",
      signal: AbortSignal.timeout(timeoutMs),
      headers: {
        "user-agent": "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1",
        "accept": "text/html,application/xhtml+xml",
        "accept-language": "en-US,en;q=0.9",
      },
    });
    if (res.status >= 300 && res.status < 400) {
      const loc = res.headers.get("location");
      await res.body?.cancel();
      url = loc ? safePublicUrl(loc, url.toString()) : null;
      continue;
    }
    if (!res.ok || !(res.headers.get("content-type") ?? "text/html").includes("html")) { await res.body?.cancel(); return null; }
    const html = await readHead(res, 600_000);
    return extractImage(html, url.toString());
  }
  return null;
}

/** Reads until </head> (where preview tags live) or the byte limit, whichever is first. */
async function readHead(res: Response, limit: number): Promise<string> {
  if (!res.body) return (await res.text()).slice(0, limit);
  const reader = res.body.getReader();
  const dec = new TextDecoder();
  let text = "";
  let bytes = 0;
  while (bytes < limit) {
    const { done, value } = await reader.read();
    if (done) break;
    bytes += value.byteLength;
    text += dec.decode(value, { stream: true });
    if (/<\/head>/i.test(text) && /og:image|twitter:image|ld\+json/i.test(text)) break;
  }
  await reader.cancel().catch(() => {});
  return text;
}

/** Fills in image_url for each listing from its page, keeping what was there when the page has nothing. */
export async function addImages<T extends { url: string; image_url: string | null }>(listings: T[], fetchFn: FetchFn = fetch): Promise<number> {
  const results = await Promise.all(listings.map((l) => findImage(l.url, fetchFn).catch(() => null)));
  let n = 0;
  listings.forEach((l, i) => {
    if (results[i]) { l.image_url = results[i]; n++; }
    else if (l.image_url && !safePublicUrl(l.image_url)) l.image_url = null;
  });
  return n;
}
