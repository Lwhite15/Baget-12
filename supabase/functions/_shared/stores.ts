// The store map in action.
//  * storeLeads: each hunt searches a rotating slice of its category's stores directly (site: searches), so every
//    store on the map gets checked regularly, not only when Google happens to rank it.
//  * storeFeeds: Shopify stores publish their whole catalog (/products.json). Between hunts Baget reads them directly:
//    exact names, prices, sizes and stock, no AI and no search. Matching products feed For You (nothing is texted).
//  * Sites that aren't stores (news, droplists, encyclopedias) never become finds.
import { type Agent, type Listing, match, missionLabel, norm } from "./match.ts";
import { db } from "./platform.ts";
import { type WebHit, serperSearch } from "./search.ts";
import { queriesFor } from "./sources.ts";

type FetchFn = typeof fetch;
const hostOf = (url: string) => { try { return new URL(url).hostname.toLowerCase().replace(/^www\./, ""); } catch { return ""; } };

// ── Not stores ──

let blocks: { at: number; set: Set<string> } | null = null;
export async function blockedDomains(): Promise<Set<string>> {
  if (blocks && Date.now() - blocks.at < 10 * 60_000) return blocks.set;
  const rows = await db.select<{ domain: string }>("source_blocks", "select=domain").catch(() => []);
  blocks = { at: Date.now(), set: new Set(rows.map((r) => r.domain)) };
  return blocks.set;
}
export function resetBlocks(set?: Set<string>) { blocks = set ? { at: Date.now(), set } : null; }

/** A page that can't be a find: a blocked site, or a dealer/valuation site's search page rather than one listing. */
export function notAProduct(url: string, blocked: Set<string>): boolean {
  const host = hostOf(url);
  if (!host) return true;
  for (const b of blocked) if (host === b || host.endsWith("." + b)) return true;
  const path = (() => { try { return new URL(url).pathname.toLowerCase(); } catch { return ""; } })();
  if (host === "edmunds.com" && !path.includes("/inventory/")) return true;
  if (host === "kbb.com" && !path.startsWith("/cars-for-sale/vehicle/")) return true;
  if (host === "cars.com" && !path.startsWith("/vehicledetail/")) return true;
  if (host === "autotrader.com" && !path.includes("/cars-for-sale/vehicle/") && !path.includes("vehicledetails")) return true;
  if (host === "cargurus.com" && !/listing|inventorylisting|details/.test(url.toLowerCase())) return true;
  return false;
}

// ── Rotation: site: searches ──

/** Searches `n` stores from the map for this scout and returns the hits as a prompt section. */
export async function storeLeads(a: Agent, n: number, now: Date, fetchFn: FetchFn = fetch): Promise<{ text: string; searches: number; stores: string[] }> {
  const cat = a.mission_category;
  if (!cat || cat === "other" || n <= 0) return { text: "", searches: 0, stores: [] };
  const stores = await db.rpc<{ domain: string; name: string }[]>("claim_stores", { p_category: cat, p_n: n, p_prefer: a.makers.slice(0, 8) }).catch(() => []);
  if (!stores.length) return { text: "", searches: 0, stores: [] };
  const qs = queriesFor(a, [], now, 2);
  const blocked = await blockedDomains();
  const parts: string[] = [];
  let searches = 0;
  await Promise.all(stores.map(async (s, i) => {
    const q = `site:${s.domain} ${qs[i % Math.max(qs.length, 1)] ?? missionLabel(a)}`.slice(0, 200);
    searches++;
    const hits: WebHit[] = await serperSearch(q, fetchFn).catch(() => []);
    const good = hits.filter((h) => hostOf(h.link).endsWith(s.domain.replace(/^www\./, "")) && !notAProduct(h.link, blocked)).slice(0, 4);
    parts[i] = good.length
      ? `${s.name} (${s.domain}):\n${good.map((h) => `  • ${h.title}\n    ${h.link}\n    ${h.snippet}`).join("\n")}`
      : `${s.name} (${s.domain}): nothing matching came up this time.`;
  }));
  const text = `Stores on your rotation this run (searched directly for you; open and confirm any that fit before including them):\n${parts.filter(Boolean).join("\n")}`;
  return { text, searches, stores: stores.map((s) => s.domain) };
}

// ── Shopify catalogs ──

interface ShopifyVariant { title?: string; price?: string; available?: boolean; option1?: string | null; option2?: string | null }
interface ShopifyProduct { title?: string; handle?: string; vendor?: string; product_type?: string; tags?: string[] | string;
  published_at?: string; updated_at?: string; images?: { src?: string }[]; variants?: ShopifyVariant[] }

const SHOE = /\b(shoe|shoes|sneaker|sneakers|footwear|trainer|trainers|boot|boots|runner|slide|clog|mule|loafer)\b/i;
const SCENT = /\b(fragrance|parfum|perfume|cologne|eau de|edp|edt|extrait|scent)\b/i;
const SIZE = /^(\d{1,2}(\.5)?|x{0,3}s|m|x{0,3}l|one size|os)$/i;

/** Reads a Shopify store's newest products. null = not a Shopify catalog (or not in US dollars). */
export async function shopifyProducts(domain: string, checkCurrency: boolean, fetchFn: FetchFn = fetch): Promise<ShopifyProduct[] | null> {
  const headers = { "User-Agent": "Mozilla/5.0 (compatible; BagetBot/1.0; +https://github.com/Lwhite15/Baget-12)", Accept: "application/json" };
  if (checkCurrency) {
    const c = await fetchFn(`https://${domain}/cart.js`, { headers, signal: AbortSignal.timeout(8000) }).catch(() => null);
    if (!c?.ok) return null;
    const cart = await c.json().catch(() => null) as { currency?: string } | null;
    if (cart?.currency !== "USD") return null;
  }
  const r = await fetchFn(`https://${domain}/products.json?limit=120`, { headers, signal: AbortSignal.timeout(10000) }).catch(() => null);
  if (!r?.ok || !(r.headers.get("content-type") ?? "").includes("json")) return null;
  const j = await r.json().catch(() => null) as { products?: ShopifyProduct[] } | null;
  return Array.isArray(j?.products) ? j!.products : null;
}

/** A Shopify product as a listing in one of the store's categories, or null if it isn't for sale or doesn't fit. */
export function shopifyListing(p: ShopifyProduct, domain: string, storeName: string, categories: string[]) {
  const title = (p.title ?? "").trim();
  const variants = p.variants ?? [];
  const avail = variants.filter((v) => v.available);
  const image = p.images?.[0]?.src;
  if (!title || !p.handle || !avail.length || !image) return null;
  const prices = avail.map((v) => Number(v.price)).filter((x) => x > 0);
  if (!prices.length) return null;
  const tags = (Array.isArray(p.tags) ? p.tags : String(p.tags ?? "").split(",")).map((t) => t.trim().toLowerCase()).filter((t) => t && t.length < 30);
  const kind = `${p.product_type ?? ""} ${tags.join(" ")} ${title}`;
  let category: string | null = null;
  if (SHOE.test(kind)) category = categories.includes("sneakers") ? "sneakers" : null;
  else if (SCENT.test(kind)) category = categories.includes("fragrance") ? "fragrance" : null;
  else category = categories.find((c) => c !== "sneakers" && c !== "fragrance") ?? null;
  if (!category) return null;
  if (/\b(gift card|e-gift|sample|tester|decant|sticker|shipping protection|insurance)\b/i.test(title)) return null;
  const sizes = [...new Set(avail.map((v) => (v.option1 ?? v.title ?? "").trim()).filter((s) => SIZE.test(s)))].slice(0, 40);
  const host = domain.replace(/^www\./, "");
  return {
    fingerprint: `${host}|${norm(title).replace(/[^a-z0-9]+/g, " ").trim()}`.slice(0, 300),
    title: title.slice(0, 200), brand: (p.vendor ?? "").trim().slice(0, 80), category,
    price: Math.min(...prices), market: null, source: storeName.slice(0, 80) || host,
    url: `https://${domain}/products/${p.handle}`.slice(0, 1000), image_url: image.startsWith("//") ? `https:${image}` : image.slice(0, 500),
    drop_at: null, sold_out: false, creator: null,
    traits: [...new Set([...(p.product_type ? [p.product_type.toLowerCase()] : []), ...tags])].slice(0, 10),
    tags: ["catalog"], sizes_in_stock: sizes.length ? sizes : null, sku: "",
  };
}

type Scout = Agent & { pro?: boolean };

/** Reads up to `limit` Shopify catalogs and puts each scout's strongest matches into its person's For You. */
export async function storeFeeds(limit: number, now = new Date(), fetchFn: FetchFn = fetch) {
  const due = await db.rpc<{ domain: string; categories: string[]; shopify: boolean | null }[]>("claim_feeds", { p_n: limit });
  if (!due.length) return { stores: 0, read: 0, kept: 0 };
  const names = new Map((await db.select<{ domain: string; name: string }>("stores",
    `select=domain,name&domain=in.(${due.map((d) => `"${d.domain}"`).join(",")})`).catch(() => [])).map((r) => [r.domain, r.name]));
  const cats = [...new Set(due.flatMap((d) => d.categories))];
  const scouts = await db.rpc<Scout[]>("feed_scouts", { p_categories: cats }).catch(() => [] as Scout[]);
  let read = 0, kept = 0;
  for (const d of due) {
    const products = await shopifyProducts(d.domain, d.shopify !== true, fetchFn).catch(() => null);
    if (!products) {
      if (d.shopify !== false) await db.update("stores", `domain=eq.${d.domain}`, { shopify: false }).catch(() => {});
      continue;
    }
    read++;
    await db.update("stores", `domain=eq.${d.domain}`, { shopify: true, feed_products: products.length }).catch(() => {});
    const listings = products.map((p) => shopifyListing(p, d.domain, names.get(d.domain) ?? d.domain, d.categories)).filter((x) => x !== null);
    if (!listings.length) continue;
    // Each scout keeps its 5 strongest matches from this store.
    const byUser = new Map<string, typeof listings>();
    for (const a of scouts) {
      const scored = listings.map((l) => ({ l, m: match(a, l as unknown as Listing, []) }))
        .filter((x) => x.m && !x.m.notInSize && x.m.score >= 50)
        .sort((x, y) => y.m!.score - x.m!.score).slice(0, 5).map((x) => x.l);
      if (!scored.length) continue;
      const list = byUser.get(a.user_id) ?? [];
      for (const l of scored) if (!list.some((x) => x.fingerprint === l.fingerprint)) list.push(l);
      byUser.set(a.user_id, list);
    }
    for (const [user, list] of byUser) {
      const saved = await db.rpc<{ id: string }[]>("upsert_listings", { p_user: user, p_listings: list }).catch(() => []);
      if (!saved.length) continue;
      kept += saved.length;
      await db.raw("/rest/v1/listing_seen", { method: "POST", headers: { Prefer: "return=minimal,resolution=merge-duplicates" },
        body: JSON.stringify(saved.map((x) => ({ user_id: user, listing_id: x.id, seen_at: now.toISOString() }))) }).catch((e) => console.error("feed seen", e));
    }
  }
  return { stores: due.length, read, kept };
}
