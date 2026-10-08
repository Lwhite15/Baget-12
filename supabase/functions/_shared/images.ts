// Finds the real product photo for a listing.
// 1. Candidates: an image search for the product's name (most stores block servers from reading their pages),
//    plus the store page's own product photo when the page does answer.
// 2. Drop logos, banners, icons and placeholders.
// 3. Download a few and let Claude pick the one that shows this exact product, or none.
// 4. Keep a copy in our own storage, so the app can always load it (stores also block apps from loading their images).
// A wrong photo is worse than no photo, so anything uncertain stays empty and the app shows the brand tile.
import { SUPABASE_URL, claude, db, env } from "./platform.ts";

const BLOCKED_HOST = /^(localhost|.+\.local|.+\.internal|.+\.localdomain|metadata\.google\.internal)$/i;
const GENERIC = /(^|[\/_.-])(logo|logos|favicon|sprite|placeholder|no[-_]?image|default[-_]?(image|share|og|social)?|social[-_]?(share|card)|share[-_]?(image|card)|og[-_]?(default|image[-_]?default)|banner|hero[-_]?banner|icon|icons|apple-touch|brand[-_]?(image|mark)|fallback|blank|spacer|pixel)([\/_.-]|$)/i;

/** Only public https URLs on the default port. No IP literals, so nothing internal is reachable. */
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

/** Images of every schema.org Product in the page's JSON-LD. */
function productSchemaImages(html: string): string[] {
  const out: string[] = [];
  const take = (img: unknown) => {
    if (typeof img === "string") out.push(img);
    else if (Array.isArray(img)) img.forEach(take);
    else if (img && typeof img === "object") {
      const o = img as Record<string, unknown>;
      take(o.url ?? o.contentUrl);
    }
  };
  const walk = (node: unknown, depth = 0) => {
    if (!node || typeof node !== "object" || depth > 6) return;
    if (Array.isArray(node)) { node.forEach((n) => walk(n, depth + 1)); return; }
    const o = node as Record<string, unknown>;
    const type = ([] as unknown[]).concat(o["@type"] ?? []).map(String);
    if (type.some((t) => /Product|ProductGroup|IndividualProduct|Vehicle|Car/i.test(t))) take(o.image);
    for (const v of Object.values(o)) if (v && typeof v === "object") walk(v, depth + 1);
  };
  for (const m of html.matchAll(/<script[^>]+application\/ld\+json[^>]*>([\s\S]*?)<\/script>/gi)) {
    try { walk(JSON.parse(m[1].trim())); } catch { /* broken JSON-LD is common */ }
  }
  return out;
}

/** Likely product photos in a page, best first, as absolute https URLs. */
export function imageCandidates(html: string, pageUrl: string): string[] {
  const ranked: { rank: number; url: string }[] = productSchemaImages(html).map((url) => ({ rank: 0, url }));
  const rankOf: Record<string, number> = {
    "og:image:secure_url": 1, "og:image:url": 1, "og:image": 1, "product:image": 1, "twitter:image": 2, "twitter:image:src": 2, "image": 3,
  };
  for (const m of html.matchAll(/<meta\b[^>]*>/gi)) {
    const a = attrs(m[0]);
    const rank = rankOf[(a.property ?? a.name ?? a.itemprop ?? "").toLowerCase()];
    if (rank !== undefined && a.content) ranked.push({ rank, url: a.content });
  }
  for (const m of html.matchAll(/<link\b[^>]*>/gi)) {
    const a = attrs(m[0]);
    if ((a.rel ?? "").toLowerCase() === "image_src" && a.href) ranked.push({ rank: 3, url: a.href });
  }
  ranked.sort((x, y) => x.rank - y.rank);
  const seen = new Set<string>();
  const out: string[] = [];
  for (const r of ranked) {
    const raw = decode(r.url.replace(/\\\//g, "/"));
    if (raw.startsWith("data:")) continue;
    const u = safePublicUrl(raw.startsWith("//") ? "https:" + raw : raw, pageUrl);
    if (!u || /\.(svg|ico)$/i.test(u.pathname) || GENERIC.test(u.pathname)) continue;
    const key = u.toString();
    if (!seen.has(key)) { seen.add(key); out.push(key.slice(0, 500)); }
  }
  return out;
}

/** The best single candidate (kept for callers that don't verify). */
export function extractImage(html: string, pageUrl: string): string | null {
  return imageCandidates(html, pageUrl)[0] ?? null;
}

type FetchFn = (input: string, init?: RequestInit) => Promise<Response>;
const UA = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1";

/** GET with up to 3 safe redirects. */
async function safeGet(start: string, accept: string, fetchFn: FetchFn, timeoutMs: number): Promise<{ res: Response; url: string } | null> {
  let url = safePublicUrl(start);
  for (let hop = 0; url && hop < 4; hop++) {
    const res = await fetchFn(url.toString(), {
      redirect: "manual",
      signal: AbortSignal.timeout(timeoutMs),
      headers: { "user-agent": UA, "accept": accept, "accept-language": "en-US,en;q=0.9" },
    });
    if (res.status >= 300 && res.status < 400) {
      const loc = res.headers.get("location");
      await res.body?.cancel();
      url = loc ? safePublicUrl(loc, url.toString()) : null;
      continue;
    }
    if (!res.ok) { await res.body?.cancel(); return null; }
    return { res, url: url.toString() };
  }
  return null;
}

/** Candidate photos from a product page. */
export async function pageImages(pageUrl: string, fetchFn: FetchFn = fetch, timeoutMs = 6000): Promise<string[]> {
  const got = await safeGet(pageUrl, "text/html,application/xhtml+xml", fetchFn, timeoutMs);
  if (!got) return [];
  if (!(got.res.headers.get("content-type") ?? "text/html").includes("html")) { await got.res.body?.cancel(); return []; }
  return imageCandidates(await readBytes(got.res, 800_000, true), got.url);
}

/** Back-compat: the top candidate without verification. */
export async function findImage(pageUrl: string, fetchFn: FetchFn = fetch, timeoutMs = 5000): Promise<string | null> {
  return (await pageImages(pageUrl, fetchFn, timeoutMs))[0] ?? null;
}

async function readBytes(res: Response, limit: number, stopAtHead = false): Promise<string> {
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
    // Product JSON-LD often sits after </head>, so keep reading a little past it.
    if (stopAtHead && /<\/head>/i.test(text) && /application\/ld\+json[\s\S]*?<\/script>/i.test(text) && bytes > 200_000) break;
  }
  await reader.cancel().catch(() => {});
  return text;
}

const IMAGE_TYPES = ["image/jpeg", "image/png", "image/webp", "image/gif"];

/** Downloads an image for checking: a real photo (8 KB to 3.7 MB) in a format Claude reads. */
export async function downloadImage(url: string, fetchFn: FetchFn = fetch, minBytes = 8_000): Promise<{ media_type: string; data: string } | null> {
  const got = await safeGet(url, "image/jpeg,image/png,image/webp,image/*;q=0.8", fetchFn, 8000);
  if (!got) return null;
  const type = (got.res.headers.get("content-type") ?? "").split(";")[0].trim().toLowerCase();
  if (!IMAGE_TYPES.includes(type)) { await got.res.body?.cancel(); return null; }
  const buf = new Uint8Array(await got.res.arrayBuffer());
  if (buf.byteLength < minBytes || buf.byteLength > 3_700_000) return null;
  let bin = "";
  for (let i = 0; i < buf.length; i += 0x8000) bin += String.fromCharCode(...buf.subarray(i, i + 0x8000));
  return { media_type: type, data: btoa(bin) };
}

type Claude = typeof claude;

export interface ImageHit { url: string; thumb?: string }

/** The product name as someone would type it into an image search: no mileage, sizes, item numbers or seller notes. */
export function searchQuery(title: string, brand = ""): string {
  let q = title
    .replace(/\([^)]*\)/g, " ")                                  // (Certified, 1,280 mi), (listed size 36)
    .replace(/\b(size|sz)\s*[\w.\/]+/gi, " ")
    .replace(/\b\d[\d,]*\s*(mi|miles|km)\b/gi, " ")
    .replace(/\s[-–|]\s*[A-Z0-9]{5,}\b/g, " ")                    // - 818989
    .replace(/\b(new|used|pre-?owned|certified|authentic|nwt|ds|vnds|brand new|in hand|free shipping)\b/gi, " ")
    .replace(/[®™]/g, "")
    .replace(/\s+/g, " ").trim()
    .replace(/[\s\-–|,]+$/g, "").replace(/^[\s\-–|,]+/g, "");
  if (brand && !q.toLowerCase().includes(brand.toLowerCase())) q = `${brand} ${q}`;
  return q.slice(0, 120);
}

/** Google Images results through Serper, or Brave image search. Empty when neither key is set. */
export async function imageSearch(query: string, fetchFn: FetchFn = fetch): Promise<ImageHit[]> {
  const serper = env("SERPER_API_KEY"), brave = env("BRAVE_API_KEY");
  try {
    if (serper) {
      const r = await fetchFn("https://google.serper.dev/images", {
        method: "POST", signal: AbortSignal.timeout(8000),
        headers: { "X-API-KEY": serper, "Content-Type": "application/json" },
        body: JSON.stringify({ q: query, num: 10, gl: "us", hl: "en" }),
      });
      if (!r.ok) { console.error("serper", r.status, (await r.text()).slice(0, 200)); return []; }
      const j = await r.json() as { images?: { imageUrl?: string; thumbnailUrl?: string; imageWidth?: number; imageHeight?: number }[] };
      return (j.images ?? [])
        .filter((x) => x.imageUrl && (!x.imageWidth || x.imageWidth >= 300) && (!x.imageHeight || x.imageHeight >= 300))
        .map((x) => ({ url: x.imageUrl!, thumb: x.thumbnailUrl }));
    }
    if (brave) {
      const r = await fetchFn(`https://api.search.brave.com/res/v1/images/search?q=${encodeURIComponent(query)}&count=10&country=us&safesearch=strict`, {
        signal: AbortSignal.timeout(8000), headers: { "X-Subscription-Token": brave, "Accept": "application/json" },
      });
      if (!r.ok) { console.error("brave", r.status, (await r.text()).slice(0, 200)); return []; }
      const j = await r.json() as { results?: { properties?: { url?: string }; thumbnail?: { src?: string } }[] };
      return (j.results ?? []).filter((x) => x.properties?.url).map((x) => ({ url: x.properties!.url!, thumb: x.thumbnail?.src }));
    }
  } catch (e) {
    console.error("image search", (e as Error).message);
  }
  return [];
}

export interface ChosenImage { source: string; media_type: string; data: string }

/** Claude looks at up to four downloadable candidates and names the one that shows this exact product, or none. */
export async function chooseImage(listing: { title: string; brand?: string; category?: string }, candidates: (string | ImageHit)[],
                                  fetchFn: FetchFn = fetch, ask: Claude = claude): Promise<ChosenImage | null> {
  const imgs: ChosenImage[] = [];
  const tried = new Set<string>();
  for (const c of candidates) {
    if (imgs.length >= 4 || tried.size >= 12) break;
    const hit = typeof c === "string" ? { url: c } : c;
    for (const u of [hit.url, hit.thumb].filter(Boolean) as string[]) {
      if (tried.has(u) || GENERIC.test(safePublicUrl(u)?.pathname ?? "/logo")) continue;
      tried.add(u);
      const d = await downloadImage(u, fetchFn, u === hit.thumb ? 3_000 : 8_000).catch(() => null);
      if (d) { imgs.push({ source: u, ...d }); break; }   // full size if it downloads, else Google's thumbnail
    }
  }
  if (!imgs.length) return null;
  const content: Record<string, unknown>[] = [];
  imgs.forEach((im, i) => {
    content.push({ type: "text", text: `Image ${i + 1}:` });
    content.push({ type: "image", source: { type: "base64", media_type: im.media_type, data: im.data } });
  });
  const vehicle = /car|vehicle/i.test(listing.category ?? "");
  content.push({ type: "text", text:
    `Product: "${listing.title}"${listing.brand ? ` by ${listing.brand}` : ""}${listing.category ? ` (${listing.category})` : ""}.
Which image is a clear photo of this product? ${vehicle
      ? "It must be the same make, model, generation and trim (for example a 992 GT3, not a Carrera), and the same body style. Match the color if the title names one. Exterior shots beat interiors."
      : "It must show the item itself and match the name, model and colorway or variant when the name gives one."}
Prefer a clean product shot over a busy scene. Not acceptable: logos, banners, text graphics, size charts, screenshots,
collages of several products, or a different product, model or colorway.
Reply with only JSON: {"match": <image number, or null if none qualify>}` });
  try {
    const res = await ask({ model: env("IMAGE_MODEL") ?? "claude-haiku-5-5", max_tokens: 30, messages: [{ role: "user", content }] });
    const text = res.content.filter((b) => b.type === "text").map((b) => b.text).join("");
    const m = text.match(/"match"\s*:\s*(null|\d+)/);
    if (!m || m[1] === "null") return null;
    const n = Number(m[1]);
    return n >= 1 && n <= imgs.length ? imgs[n - 1] : null;
  } catch (e) {
    console.error("image check", (e as Error).message);
    return null;   // a wrong photo is worse than none
  }
}

async function sha(text: string): Promise<string> {
  const d = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(text));
  return [...new Uint8Array(d)].slice(0, 16).map((b) => b.toString(16).padStart(2, "0")).join("");
}

/** Keeps a copy in the public product-photos bucket and returns its URL (or the original if the upload fails). */
export async function storePhoto(key: string, img: ChosenImage): Promise<string> {
  const ext = img.media_type.split("/")[1].replace("jpeg", "jpg");
  const path = `${await sha(key)}.${ext}`;
  try {
    const bytes = Uint8Array.from(atob(img.data), (c) => c.charCodeAt(0));
    const r = await db.raw(`/storage/v1/object/product-photos/${path}`, {
      method: "POST", body: bytes, headers: { "Content-Type": img.media_type, "x-upsert": "true", "cache-control": "max-age=31536000" },
    });
    if (!r.ok) { console.error("store photo", r.status, (await r.text()).slice(0, 200)); return img.source; }
    return `${SUPABASE_URL()}/storage/v1/object/public/product-photos/${path}`;
  } catch (e) {
    console.error("store photo", (e as Error).message);
    return img.source;
  }
}

/** Sets each listing's image_url to a verified product photo (our stored copy), or null. */
export async function addImages<T extends { url: string; image_url: string | null; title: string; brand?: string; category?: string; fingerprint?: string }>(
  listings: T[], fetchFn: FetchFn = fetch, ask: Claude = claude,
): Promise<number> {
  const picked = await Promise.all(listings.map(async (l) => {
    const [fromPage, fromSearch] = await Promise.all([
      pageImages(l.url, fetchFn).catch(() => [] as string[]),
      imageSearch(searchQuery(l.title, l.brand), fetchFn),
    ]);
    const suggested = l.image_url && safePublicUrl(l.image_url) ? [l.image_url] : [];
    // The store's own photo first (when its page answers), then search results.
    const candidates: (string | ImageHit)[] = [...fromPage.slice(0, 2), ...suggested, ...fromSearch];
    return candidates.length ? await chooseImage(l, candidates, fetchFn, ask).catch(() => null) : null;
  }));
  // The same photo on two different products is a store-wide image, not either product.
  const counts = new Map<string, number>();
  for (const p of picked) if (p) counts.set(p.source, (counts.get(p.source) ?? 0) + 1);
  let n = 0;
  await Promise.all(listings.map(async (l, i) => {
    const p = picked[i];
    l.image_url = p && counts.get(p.source) === 1 ? await storePhoto(l.fingerprint ?? l.url + l.title, p) : null;
    if (l.image_url) n++;
  }));
  return n;
}

/** A link that answers 404 or 410 is a made-up page. Anything else (including a store's bot wall) counts as real. */
export async function linkIsDead(url: string, fetchFn: FetchFn = fetch): Promise<boolean> {
  const got = await fetchFn(url, { method: "GET", redirect: "follow", signal: AbortSignal.timeout(6000),
                                   headers: { "user-agent": UA, "accept": "text/html" } }).catch(() => null);
  if (!got) return false;
  await got.body?.cancel().catch(() => {});
  return got.status === 404 || got.status === 410;
}
