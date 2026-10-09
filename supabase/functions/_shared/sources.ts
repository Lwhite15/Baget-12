// Extra data sources the agents use alongside web search. Each turns on when its key is set
// (GitHub secret -> Supabase secret); without a key it quietly does nothing.
//  * eBay Browse API (EBAY_CLIENT_ID + EBAY_CLIENT_SECRET): real fixed-price listings with exact item pages and photos.
//  * Google Shopping via Serper (SERPER_API_KEY): current products, prices and stores, handed to Claude as leads to verify.
import { type Agent, norm } from "./match.ts";
import { env } from "./platform.ts";

type FetchFn = (input: string, init?: RequestInit) => Promise<Response>;

/** eBay categories worth searching for each mission. */
const EBAY_CATEGORY: Record<string, string> = {
  sneakers: "15709",      // Athletic Shoes (men's)
  apparel: "1059",        // Men's Clothing
  watches: "31387",       // Wristwatches
  accessories: "4250",    // Men's Accessories
  collectibles: "1",      // Collectibles
  fragrance: "180345",    // Fragrances
  cars: "6001",           // eBay Motors: Cars & Trucks
  furniture: "3197",      // Furniture
};

/** Two or three search phrases built from what the agent knows, rotating so each run looks somewhere new. */
export function queriesFor(a: Agent, liked: string[], now: Date, max = 2): string[] {
  const mission = a.mission_category ? "" : (a.mission_custom ?? "");
  const pool: string[] = [];
  for (const m of a.makers) for (const k of [...a.keywords, ...a.traits.slice(0, 3), ""]) pool.push(`${m} ${k}`.trim());
  for (const k of a.keywords) pool.push(k);
  for (const c of a.creators) pool.push(c);
  for (const t of liked.slice(0, 4)) pool.push(t.split(/\s+/).slice(0, 6).join(" "));
  if (mission) pool.push(mission);
  const uniq = [...new Set(pool.map((q) => q.replace(/\s+/g, " ").trim()).filter((q) => q.length > 2))];
  if (!uniq.length) return [];
  const slot = Math.floor(now.getTime() / (3 * 3600_000));
  const out: string[] = [];
  for (let i = 0; i < Math.min(max, uniq.length); i++) out.push(uniq[(slot * max + i) % uniq.length].slice(0, 80));
  return out;
}

// ── eBay ──

let ebayToken: { token: string; until: number } | null = null;

export function ebayConfigured(): boolean { return !!(env("EBAY_CLIENT_ID") && env("EBAY_CLIENT_SECRET")); }

async function ebayAuth(fetchFn: FetchFn): Promise<string | null> {
  if (ebayToken && ebayToken.until > Date.now() + 60_000) return ebayToken.token;
  const id = env("EBAY_CLIENT_ID"), secret = env("EBAY_CLIENT_SECRET");
  if (!id || !secret) return null;
  const r = await fetchFn("https://api.ebay.com/identity/v1/oauth2/token", {
    method: "POST", signal: AbortSignal.timeout(8000),
    headers: { "Content-Type": "application/x-www-form-urlencoded", Authorization: `Basic ${btoa(`${id}:${secret}`)}` },
    body: "grant_type=client_credentials&scope=" + encodeURIComponent("https://api.ebay.com/oauth/api_scope"),
  });
  if (!r.ok) { console.error("ebay auth", r.status, (await r.text()).slice(0, 200)); return null; }
  const j = await r.json() as { access_token: string; expires_in: number };
  ebayToken = { token: j.access_token, until: Date.now() + j.expires_in * 1000 };
  return j.access_token;
}

interface EbayItem {
  itemId: string; title: string; itemWebUrl: string;
  price?: { value: string; currency: string };
  image?: { imageUrl: string }; additionalImages?: { imageUrl: string }[];
  condition?: string; seller?: { username?: string };
}

/** Sizes written in an eBay title: "Size 10.5", "Sz 11", "US 9", "Size L". */
export function sizesFromTitle(title: string, category: string | null): string[] | null {
  if (category === "sneakers") {
    const m = title.match(/\b(?:size|sz|us|men'?s)\s*:?\s*(\d{1,2}(?:\.5)?)\b/i);
    return m ? [m[1]] : null;
  }
  if (category === "apparel") {
    const m = title.match(/\b(?:size|sz)\s*:?\s*(XXS|XS|S|M|L|XL|XXL|2XL|\d{2})\b/i);
    return m ? [m[1].toUpperCase()] : null;
  }
  return null;
}

/** Raw listings in the shape cleanListings() takes. */
export async function ebaySearch(a: Agent, queries: string[], fetchFn: FetchFn = fetch): Promise<Record<string, unknown>[]> {
  if (!ebayConfigured() || !queries.length) return [];
  try {
    const token = await ebayAuth(fetchFn);
    if (!token) return [];
    const cat = a.mission_category ? EBAY_CATEGORY[a.mission_category] : undefined;
    const out: Record<string, unknown>[] = [];
    for (const q of queries) {
      const params = new URLSearchParams({ q, limit: "8", filter: "buyingOptions:{FIXED_PRICE},priceCurrency:USD" });
      if (cat) params.set("category_ids", cat);
      const r = await fetchFn(`https://api.ebay.com/buy/browse/v1/item_summary/search?${params}`, {
        signal: AbortSignal.timeout(8000),
        headers: { Authorization: `Bearer ${token}`, "X-EBAY-C-MARKETPLACE-ID": "EBAY_US" },
      });
      if (!r.ok) { console.error("ebay search", r.status, (await r.text()).slice(0, 200)); continue; }
      const j = await r.json() as { itemSummaries?: EbayItem[] };
      for (const it of (j.itemSummaries ?? []).slice(0, 6)) {
        if (!it.itemWebUrl || !it.title) continue;
        const url = it.itemWebUrl.split("?")[0];
        const maker = a.makers.find((m) => norm(it.title).includes(norm(m)));
        out.push({
          title: it.title, brand: maker ?? "", category: a.mission_category ?? "other",
          price: it.price?.currency === "USD" ? Number(it.price.value) : null, market: null,
          source: "eBay", url, image_url: it.image?.imageUrl ?? null, sold_out: false,
          traits: it.condition ? [it.condition.toLowerCase()] : [],
          sizes_in_stock: sizesFromTitle(it.title, a.mission_category),
          sku: "", discovery: false, pitch: "", from: "ebay",
        });
      }
    }
    return out;
  } catch (e) {
    console.error("ebay", (e as Error).message);
    return [];
  }
}

// ── Google Shopping (Serper) ──

export interface Lead { title: string; store: string; price: string }

/** Current products from Google Shopping, for Claude to check out and verify. */
export async function shoppingLeads(queries: string[], fetchFn: FetchFn = fetch): Promise<Lead[]> {
  const key = env("SERPER_API_KEY");
  if (!key || !queries.length) return [];
  const out: Lead[] = [];
  for (const q of queries) {
    try {
      const r = await fetchFn("https://google.serper.dev/shopping", {
        method: "POST", signal: AbortSignal.timeout(8000),
        headers: { "X-API-KEY": key, "Content-Type": "application/json" },
        body: JSON.stringify({ q, gl: "us", hl: "en", num: 10 }),
      });
      if (!r.ok) { console.error("serper shopping", r.status, (await r.text()).slice(0, 200)); continue; }
      const j = await r.json() as { shopping?: { title?: string; source?: string; price?: string }[] };
      for (const s of (j.shopping ?? []).slice(0, 6)) {
        if (s.title && s.source) out.push({ title: s.title.slice(0, 120), store: s.source.slice(0, 60), price: (s.price ?? "").slice(0, 20) });
      }
    } catch (e) {
      console.error("serper shopping", (e as Error).message);
    }
  }
  const seen = new Set<string>();
  return out.filter((l) => { const k = norm(l.title); if (seen.has(k)) return false; seen.add(k); return true; }).slice(0, 10);
}
