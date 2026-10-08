// Finds the real product photo for a listing.
// 1. Read the store page for candidates: the Product photo in its structured data first, then its link-preview images.
// 2. Drop logos, banners, icons and placeholders.
// 3. Download up to three and let Claude pick the one that shows this exact product, or none.
// A wrong photo is worse than no photo, so anything uncertain stays empty and the app shows the brand tile.
import { claude, env } from "./platform.ts";

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
export async function downloadImage(url: string, fetchFn: FetchFn = fetch): Promise<{ media_type: string; data: string } | null> {
  const got = await safeGet(url, "image/jpeg,image/png,image/webp,image/*;q=0.8", fetchFn, 8000);
  if (!got) return null;
  const type = (got.res.headers.get("content-type") ?? "").split(";")[0].trim().toLowerCase();
  if (!IMAGE_TYPES.includes(type)) { await got.res.body?.cancel(); return null; }
  const buf = new Uint8Array(await got.res.arrayBuffer());
  if (buf.byteLength < 8_000 || buf.byteLength > 3_700_000) return null;
  let bin = "";
  for (let i = 0; i < buf.length; i += 0x8000) bin += String.fromCharCode(...buf.subarray(i, i + 0x8000));
  return { media_type: type, data: btoa(bin) };
}

type Claude = typeof claude;

/** Claude looks at the candidates and names the one that shows this exact product, or none. */
export async function chooseImage(listing: { title: string; brand?: string; category?: string }, urls: string[],
                                  fetchFn: FetchFn = fetch, ask: Claude = claude): Promise<string | null> {
  const imgs: { url: string; media_type: string; data: string }[] = [];
  for (const u of urls.slice(0, 3)) {
    const d = await downloadImage(u, fetchFn).catch(() => null);
    if (d) imgs.push({ url: u, ...d });
  }
  if (!imgs.length) return null;
  const content: Record<string, unknown>[] = [];
  imgs.forEach((im, i) => {
    content.push({ type: "text", text: `Image ${i + 1}:` });
    content.push({ type: "image", source: { type: "base64", media_type: im.media_type, data: im.data } });
  });
  content.push({ type: "text", text:
    `Product: "${listing.title}"${listing.brand ? ` by ${listing.brand}` : ""}${listing.category ? ` (${listing.category})` : ""}.
Which image is a clear photo of this exact product? It must show the item itself, matching the name, model and colorway or variant when the name gives one.
Not acceptable: logos, banners, text graphics, size charts, gift cards, collages of several products, or a different product or colorway.
A person wearing or holding it is fine if the product is clearly visible.
Reply with only JSON: {"match": <image number, or null if none qualify>}` });
  try {
    const res = await ask({ model: env("IMAGE_MODEL") ?? "claude-haiku-5-5", max_tokens: 30, messages: [{ role: "user", content }] });
    const text = res.content.filter((b) => b.type === "text").map((b) => b.text).join("");
    const m = text.match(/"match"\s*:\s*(null|\d+)/);
    if (!m || m[1] === "null") return null;
    const n = Number(m[1]);
    return n >= 1 && n <= imgs.length ? imgs[n - 1].url : null;
  } catch (e) {
    console.error("image check", (e as Error).message);
    return null;   // a wrong photo is worse than none
  }
}

/** Sets each listing's image_url to a verified product photo, or null. */
export async function addImages<T extends { url: string; image_url: string | null; title: string; brand?: string; category?: string; fingerprint?: string }>(
  listings: T[], fetchFn: FetchFn = fetch, ask: Claude = claude,
): Promise<number> {
  const picked = await Promise.all(listings.map(async (l) => {
    const fromPage = await pageImages(l.url, fetchFn).catch(() => [] as string[]);
    const suggested = l.image_url && safePublicUrl(l.image_url) && !GENERIC.test(new URL(l.image_url).pathname) ? [l.image_url] : [];
    const candidates = [...new Set([...fromPage, ...suggested])];
    return candidates.length ? await chooseImage(l, candidates, fetchFn, ask).catch(() => null) : null;
  }));
  // The same photo on two different products is a store-wide image, not either product.
  const counts = new Map<string, number>();
  for (const p of picked) if (p) counts.set(p, (counts.get(p) ?? 0) + 1);
  let n = 0;
  listings.forEach((l, i) => {
    const p = picked[i];
    l.image_url = p && counts.get(p) === 1 ? p : null;
    if (l.image_url) n++;
  });
  return n;
}
