// Extra data sources the agents use alongside web search. Each turns on when its key is set
// (GitHub secret -> Supabase secret); without a key it quietly does nothing.
//  * eBay Browse API (EBAY_CLIENT_ID + EBAY_CLIENT_SECRET): real fixed-price listings with exact item pages and photos.
//  * Google Shopping via Serper (SERPER_API_KEY): current products, prices and stores, handed to Claude as leads to verify.
import { type Agent, norm } from "./match.ts";
import { db, env } from "./platform.ts";

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
  // Short terms only: chat sometimes saves whole sentences as keywords ("wants updates on every drop").
  const short = (t: string) => t.trim().split(/\s+/).length <= 4 && !/\b(wants?|likes?|loves?|updates?|every|prefers?|looking)\b/i.test(t);
  const keywords = a.keywords.filter(short), traits = a.traits.filter(short);
  const pool: string[] = [];
  for (const m of a.makers.filter(short)) {
    for (const k of [...keywords, ...traits.slice(0, 3), ""]) {
      // Don't repeat the maker: "Nike" + "nike dunk" -> "Nike dunk"
      const kk = norm(k).startsWith(norm(m)) ? k.slice(m.length).trim() : k;
      pool.push(`${m} ${kk}`.trim());
    }
  }
  for (const k of keywords) pool.push(k);
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

// ── Prices elsewhere (for deal verdicts and price-drop watches) ──

export interface Offer { store: string; price: number }

const money = (s: string | undefined) => {
  const m = (s ?? "").replace(/,/g, "").match(/\$\s*(\d+(?:\.\d{1,2})?)/);
  return m ? Number(m[1]) : null;
};

const PARTIAL_WORDS = /\b(samples?|decants?|decanted|vials?|minis?|miniatures?|travel[- ]size|travel spray|atomi[sz]ers?|splits?|discovery set|sampler|carded)\b/i;
const sizeMl = (t: string) => {
  const ml = t.match(/(\d+(?:\.\d+)?)\s?ml\b/i);
  if (ml) return Number(ml[1]);
  const oz = t.match(/(\d*\.?\d+)\s?(?:fl\.?\s?)?oz\b/i);
  return oz ? Number(oz[1]) * 29.57 : null;
};
/** True when a shopping result is a sample, decant or small size the product name didn't ask for. */
export function partialSize(offerTitle: string, productTitle: string): boolean {
  if (PARTIAL_WORDS.test(offerTitle) && !PARTIAL_WORDS.test(productTitle)) return true;
  const got = sizeMl(offerTitle), want = sizeMl(productTitle);
  if (got === null) return false;
  if (want !== null) return Math.abs(got - want) > want * 0.15;
  return got < 30;
}

// ── Who counts as a real store ──
// Google Shopping mixes real stores with replica shops ("Saint store", "suntreeshopping.com") and one-person sellers on
// marketplaces. "Cheaper elsewhere" only shows stores you can trust to send the real thing: big retailers, known
// boutiques, authenticated resale, brands' own shops, and the stores on Baget's map. Everything else is dropped.

/** "Saks Fifth Avenue" → "saksfifthavenue", "Jomashop.com" → "jomashop", "snkrdunk.com/en" → "snkrdunk". */
export function sellerKey(name: string): string {
  return name.normalize("NFKD").replace(/[\u0300-\u036f]/g, "").toLowerCase()
    .replace(/\/.*$/, "").replace(/^(www\.|us\.|shop\.|store\.)/, "")
    .replace(/\.(com|net|co|us|shop|store|co\.uk|com\.au|jp)\b.*$/, "").replace(/^the\s+/, "")
    .replace(/&/g, "and").replace(/[^a-z0-9]/g, "");
}

const TRUSTED = new Set([
  // Department stores and big retail
  "nordstrom", "nordstromrack", "macys", "bloomingdales", "saks", "saksfifthavenue", "saksoff5th", "neimanmarcus", "bergdorfgoodman",
  "dillards", "kohls", "target", "walmart", "amazon", "bestbuy", "costco", "jcpenney", "belk", "harrods", "selfridges", "liberty",
  "libertyus", "libertylondon", "harveynichols", "johnlewis", "shopsimon", "bluefly", "ruelala", "gilt", "theoutnet", "yoox",
  // Sneakers and streetwear
  "footlocker", "champssports", "finishline", "jdsports", "dtlr", "hibbett", "shoepalace", "snipes", "snipesusa", "shiekh", "pacsun",
  "dickssportinggoods", "dicks", "academy", "cabelas", "basspro", "bassproshops", "rei", "zappos", "eastbay", "kith", "endclothing", "end", "hbx", "doverstreetmarket",
  "extrabutter", "sneakerpolitics", "nicekicks", "socialstatus", "bait", "feature", "wishatl", "undefeated", "concepts", "cncpts", "bodega",
  "notre", "amamaniere", "lapstoneandhammer", "fivestory", "lncc", "garmentory", "huckberry", "nepenthesnewyork", "nepenthes",
  "sneakersnstuff", "offspring", "atmos", "atmosusa", "stussy", "supreme", "palace", "aimeleondore", "fearofgod",
  "lemaire", "martinerose", "kapital", "nike", "adidas", "newbalance", "converse", "vans", "puma", "asics", "reebok",
  "jordan", "salomon", "hoka", "onrunning", "birkenstock", "drmartens", "timberland", "carhartt", "carharttwip", "patagonia",
  "thenorthface", "arcteryx", "levis", "uniqlo", "gap", "oldnavy", "jcrew", "hm", "zara", "cos", "urbanoutfitters", "asos",
  "revolve", "fwrd", "ssense", "farfetch", "mrporter", "netaporter", "mytheresa", "matchesfashion", "cettire", "lyst", "modesens",
  "editorialist", "24s", "luisaviaroma", "brownsfashion", "goodhoodstore", "slamjam", "nordstromcom",
  // Authenticated resale and vetted dealers
  "stockx", "goat", "flightclub", "stadiumgoods", "novelship", "snkrdunk", "kickscrew", "therealreal", "vestiairecollective",
  "fashionphile", "rebag", "theluxurycloset", "luxurycloset", "chrono24", "1stdibs", "chairish", "pamono", "bezel",
  "crownandcaliber", "bobswatches", "the1916company", "europeanwatch", "analogshift", "watchbox", "2ndstreet", "2ndstreetusa",
  // Fragrance and beauty
  "sephora", "ulta", "ultabeauty", "fragrancenet", "fragrancex", "jomashop", "luckyscent", "aedes", "aedesperfumery", "twistedlily",
  "osswald", "osswaldnyc", "beautyhabit", "maxaroma", "byredo", "lelabo", "lelabofragrances", "creed", "creedboutique",
  "diptyque", "aesop", "cultbeauty", "spacenk", "bluemercury", "smallflower", "thefragranceshop", "fragranceshop", "notino",
  "strawberrynet", "sweetcare", "beautylish", "dermstore", "lookfantastic", "beautyliv", "nose", "thedrydown", "drydown",
  "houseofamouage", "amouage", "maisonfranciskurkdjian", "parfumsdemarly", "xerjoff", "tomford", "jomalone", "penhaligons",
  // Watches and jewelry
  "watchmaxx", "teddybaldassarre", "hodinkee", "hodinkeeshop", "christopherward", "islandwatch", "longislandwatch",
  "windupwatchshop", "gnomonwatches", "vaerwatches", "worldofwatches", "ashford", "benbridge", "tourneau", "tiffany",
  "tiffanyandco", "cartier", "baltic", "timeandtideus", "timeandtide",
  // Home and design
  "designwithinreach", "dwr", "hermanmiller", "hermanmillerstore", "momadesignstore", "moma", "wayfair", "lumens", "finnishdesignshop",
  "ylighting", "hivemodern", "hive", "crateandbarrel", "cb2", "westelm", "rh", "rejuvenation", "allmodern", "potterybarn", "ikea",
  "knoll", "vitra", "audo",
  // Toys, collectibles, books
  "bigbadtoystore", "sideshow", "entertainmentearth", "hlj", "hobbylinkjapan", "barnesandnoble", "booksamillion", "lego",
]);
// One-person sellers on marketplaces, and shops known for replicas: never "cheaper elsewhere".
const UNTRUSTED = /\b(ebay|etsy|poshmark|mercari|depop|vinted|whatnot|tiktok|shein|temu|aliexpress|alibaba|dhgate|wish|joom|shop app|walmart -|amazon -|seller|outlet sale|wholesale|factory|replica|reps?)\b/i;

let mapped: { at: number; set: Set<string> } | null = null;
/** Stores on Baget's own map (seeded, not learned): retailers, boutiques, brands, resale, dealers. */
async function mapStores(): Promise<Set<string>> {
  if (mapped && Date.now() - mapped.at < 30 * 60_000) return mapped.set;
  const rows = await db.select<{ name: string | null; domain: string; kind: string }>("stores",
    "select=name,domain,kind&source=eq.seed&kind=in.(retailer,boutique,brand,resale,dealer,auction,discount)").catch(() => []);
  const set = new Set<string>();
  for (const r of rows) { if (r.name) set.add(sellerKey(r.name)); set.add(sellerKey(r.domain)); }
  mapped = { at: Date.now(), set };
  return set;
}
export function resetMapStores(set?: Set<string>) { mapped = set ? { at: Date.now(), set } : null; }

/** True when a Google Shopping seller is a store you can trust (see above). `brand` lets a brand's own shop count. */
export function trustedSeller(store: string, brand?: string | null, extra?: Set<string>): boolean {
  const k = sellerKey(store);
  if (!k) return false;
  if (TRUSTED.has(k)) return true;
  if (UNTRUSTED.test(store)) return false;
  if (extra?.has(k)) return true;
  const b = brand ? sellerKey(brand) : "";
  // The brand's own shop: "Le Labo", "The House of Amouage", "Fear of God" (but not "Nike Outlet Deals 2026").
  return b.length >= 3 && k.includes(b) && k.length <= b.length + 10 && !/outlet|deal|sale|cheap|discount/.test(k);
}

/** What other stores charge for this product right now (Google Shopping), cheapest first. Only trusted stores. */
export async function shoppingOffers(title: string, fetchFn: FetchFn = fetch, opts: { brand?: string | null; price?: number | null } = {}): Promise<Offer[]> {
  const key = env("SERPER_API_KEY");
  if (!key || title.trim().length < 3) return [];
  try {
    const r = await fetchFn("https://google.serper.dev/shopping", {
      method: "POST", signal: AbortSignal.timeout(8000),
      headers: { "X-API-KEY": key, "Content-Type": "application/json" },
      body: JSON.stringify({ q: title.slice(0, 120), gl: "us", hl: "en", num: 10 }),
    });
    if (!r.ok) return [];
    const j = await r.json() as { shopping?: { title?: string; source?: string; price?: string }[] };
    const want = new Set(norm(title).split(/\s+/).filter((w) => w.length > 2));
    const known = await mapStores();
    const out: Offer[] = [];
    for (const s of j.shopping ?? []) {
      const p = money(s.price);
      if (!s.source || p === null || p <= 0) continue;
      if (!trustedSeller(s.source, opts.brand, known)) continue;
      // Even a real store's price under half of what this is selling for is almost always the wrong item.
      if (opts.price && p < opts.price * 0.5) continue;
      // Only the same product: most of the title's words must appear.
      const words = norm(s.title ?? "").split(/\s+/);
      const overlap = words.filter((w) => want.has(w)).length / Math.max(1, Math.min(want.size, 8));
      if (overlap < 0.6) continue;
      // A sample, decant or travel size of the product isn't the product's price.
      if (partialSize(s.title ?? "", title) || /decant|sample/i.test(s.source)) continue;
      out.push({ store: s.source.slice(0, 60), price: p });
    }
    out.sort((a, b) => a.price - b.price);
    const seen = new Set<string>();
    const unique = out.filter((o) => { const k = norm(o.store); if (seen.has(k)) return false; seen.add(k); return true; });
    // Prices far under the rest are almost always a sample or a mislabeled listing.
    const mid = unique.length >= 3 ? unique[Math.floor(unique.length / 2)].price : 0;
    return unique.filter((o) => o.price >= mid * 0.4).slice(0, 5);
  } catch {
    return [];
  }
}

/** Looks up other stores' prices for saved listings and stores them (best effort). */
export async function attachOffers(rows: { id: string; title: string; brand?: string | null; price?: number | null }[],
                                   update: (id: string, patch: Record<string, unknown>) => Promise<void>,
                                   fetchFn: FetchFn = fetch): Promise<number> {
  if (!env("SERPER_API_KEY")) return 0;
  let n = 0;
  await Promise.all(rows.slice(0, 10).map(async (r) => {
    const offers = await shoppingOffers(r.title, fetchFn, { brand: r.brand, price: r.price });
    await update(r.id, {
      offers, low_price: offers[0]?.price ?? null, low_store: offers[0]?.store ?? null, offers_checked_at: new Date().toISOString(),
    }).catch(() => {});
    if (offers.length) n++;
  }));
  return n;
}

/** Prices saved before the trusted-store check (Oct 26, 2026): drop untrusted stores from them, no new lookups. */
export const TRUST_FIX = "2026-10-26T18:00:00Z";
export async function scrubOffers(limit = 400): Promise<{ checked: number; changed: number }> {
  const rows = await db.select<{ id: string; brand: string | null; price: number | null; offers: Offer[] | null }>("listings",
    `select=id,brand,price,offers&offers_checked_at=lt.${TRUST_FIX}&order=last_seen_at.desc&limit=${limit}`);
  const known = await mapStores();
  let changed = 0;
  for (const r of rows) {
    const before = Array.isArray(r.offers) ? r.offers : [];
    const offers = before.filter((o) => o && trustedSeller(o.store, r.brand, known) && !(r.price && o.price < r.price * 0.5))
      .sort((a, b) => a.price - b.price);
    if (offers.length !== before.length) changed++;
    await db.update("listings", `id=eq.${r.id}`, {
      offers, low_price: offers[0]?.price ?? null, low_store: offers[0]?.store ?? null, offers_checked_at: TRUST_FIX,
    }).catch(() => {});
  }
  return { checked: rows.length, changed };
}
