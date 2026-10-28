// Sweeps: each agent searches the live web with Claude and turns what it finds into finds + friend-style notifications.
//  * Scheduled (every 15 minutes by pg_cron, with the shared secret): agents whose owner's interval has passed.
//  * Manual (the app, with the user's session): that user's agents, at most once per agent every 10 minutes.
// Cost guards: agents per run, searches per agent, and sweeps per user per day are all capped (see env below).
import { notFindable } from "../_shared/findable.ts";
import { isAdultText } from "../_shared/adult.ts";
import { type Agent, CATEGORIES, GROUP_OF, type Listing, firstName, friendLine, localHour, heldForMorning, kindFor, match, minBudgetOf, deptOf, langOf, missionLabel, norm } from "../_shared/match.ts";
import { type Block, type ClaudeMessage, HttpError, MODEL, batchResults, batchStatus, claude, db, env, handle, isScheduler, json, logBatchUsage, parseJSON, requireUser, submitBatch, textOf } from "../_shared/platform.ts";
import { addImages, linkIsDead, pageProduct, smaller, traceImage } from "../_shared/images.ts";
import { setupDemo, setupShots } from "./demo.ts";
import { restockCheck } from "../_shared/daily.ts";
import { blockedDomains, notAProduct, pageKind, storeFeeds, storeLeads } from "../_shared/stores.ts";
import { geminiHunt, geminiOn } from "../_shared/gemini.ts";
import { SEARCH_TOOL, hitsText, serperSearch, serperUsable } from "../_shared/search.ts";
export { firstName };
import { type Lead, attachOffers, scrubOffers, ebayConfigured, ebaySearch, queriesFor, shoppingLeads, shoppingOffers } from "../_shared/sources.ts";

const num = (name: string, fallback: number) => {
  const v = Number(env(name));
  return Number.isFinite(v) && v > 0 ? v : fallback;
};

interface Candidate extends Agent { tz: string; settings: Record<string, unknown>; last_swept_at: string | null; display_name?: string; pro?: boolean }

/** How hard a hunt digs. Pro: deep (twice the searches, more angles and places, opens up to 6 product pages).
 *  Free: fewer searches, but still opens up to 3 product pages to confirm price and stock, so its finds are reliable. */
export function depthFor(pro: boolean) {
  return pro
    ? { searches: num("SWEEP_MAX_SEARCHES", 12), fetches: num("SWEEP_MAX_FETCHES", 6), angles: 3, sources: 6, minSearches: 8, kinds: 4, deep: true }
    : { searches: num("FREE_MAX_SEARCHES", 6), fetches: num("FREE_MAX_FETCHES", 3), angles: 2, sources: 3, minSearches: 4, kinds: 3, deep: false };
}

const VOICE: Record<string, string> = {
  hype: "excited and hyped, casual slang is fine, like a friend who can't wait to show them",
  chill: "easygoing and warm, like a friend casually putting them on to something",
  straight: "brief and factual, no hype, no emoji",
};

/** The text the agent wrote for its push notification, if it's usable. */
export function cleanText(v: unknown): string {
  if (typeof v !== "string") return "";
  const t = v.trim().replace(/^["“']+|["”']+$/g, "").replace(/\s+/g, " ");
  return t.length >= 20 && t.length <= 240 ? t : "";
}

/** What the person did with earlier finds: the clearest signal of taste there is. */
export interface Reactions { liked: string[]; bought: string[]; passed: string[]; seen?: string[] }

export async function reactionsFor(agentId: string): Promise<Reactions> {
  const [rows, recent] = await Promise.all([
    db.select<{ status: string; pass_reason: string | null; listing: { title: string; brand: string } | null }>(
      "finds", `select=status,pass_reason,listing:listings(title,brand)&agent_id=eq.${agentId}&status=in.(liked,acquired,passed)&order=created_at.desc&limit=40`),
    db.select<{ listing: { title: string } | null }>(
      "finds", `select=listing:listings(title)&agent_id=eq.${agentId}&order=created_at.desc&limit=30`).catch(() => []),
  ]);
  const name = (r: typeof rows[number]) => r.listing ? (r.listing.brand && !r.listing.title.includes(r.listing.brand) ? `${r.listing.brand} ${r.listing.title}` : r.listing.title) : "";
  return {
    liked: rows.filter((r) => r.status === "liked").map(name).filter(Boolean).slice(0, 12),
    bought: rows.filter((r) => r.status === "acquired").map(name).filter(Boolean).slice(0, 8),
    passed: rows.filter((r) => r.status === "passed" && (r.pass_reason ?? "").includes("style")).map(name).filter(Boolean).slice(0, 12),
    seen: recent.map((r) => r.listing?.title ?? "").filter(Boolean),
  };
}

/** Each sweep hunts from a different angle, so agents keep turning up new things instead of the same results. */
export const ANGLES = [
  "new releases and drops in the next two weeks (brand sites, release calendars, launch apps)",
  "restocks and back-in-stock items (brand sites, authorized retailers)",
  "deals: items listed below their usual resale or market price",
  "collaborations and limited editions from brands and creators they like",
  "adjacent discoveries: makers, models or creators they haven't named but would likely love, based on their likes",
  "secondhand, vintage and archive pieces on reputable marketplaces (Grailed, eBay, The RealReal, Bring a Trailer, 1stDibs)",
  "smaller boutiques and independent stores that carry what they like",
  "what's trending right now in their lane that fits their taste",
];

/** Sneakers, clothing and fragrance live on release dates: these hunts always look ahead for upcoming and limited drops. */
export const DROP_CATEGORIES = new Set(["sneakers", "apparel", "fragrance"]);
export const UPCOMING_ANGLE = "upcoming releases in the next 60 days and limited releases (release calendars, launch pages, " +
  "brand and retailer raffles, collabs, numbered or limited-quantity runs)";

export function anglesFor(agentId: string, now: Date): string[] {
  let h = 0;
  for (const c of agentId) h = (h * 31 + c.charCodeAt(0)) >>> 0;
  const slot = Math.floor(now.getTime() / (3 * 3600_000));
  const first = (h + slot) % ANGLES.length;
  return [ANGLES[first], ANGLES[(first + 3) % ANGLES.length], ANGLES[(first + 5) % ANGLES.length]];
}

/** Where to dig, by category: official, big retail, resale, boutiques, auctions, communities, international.
 *  Each hunt gets a rotating handful so over a day every corner gets checked. */
export const DEEP_SOURCES: Record<string, string[]> = {
  sneakers: ["Nike SNKRS and Nike.com", "adidas Confirmed", "New Balance", "END. Launches", "SNS (Sneakersnstuff)", "Kith", "Concepts", "Bodega",
    "Extra Butter", "Foot Locker / Champs", "StockX", "GOAT", "Flight Club", "Stadium Goods", "eBay (authenticated)", "Grailed",
    "Sole Retriever and Sneaker News release calendars", "r/sneakermarket and sneaker forums", "Depop and Mercari", "Japanese and European shops that ship to the US"],
  apparel: ["the brands' own sites and drops", "SSENSE", "END.", "Mr Porter", "Kith", "Dover Street Market", "Grailed", "Depop", "Vinted",
    "Poshmark", "The RealReal", "Vestiaire Collective", "eBay", "Mercari", "Highsnobiety and Hypebeast drop roundups", "independent boutiques",
    "archive and vintage shops", "Japanese resellers that ship to the US"],
  fragrance: ["the houses' own boutiques", "Luckyscent", "Twisted Lily", "Aedes", "Osswald NYC", "Nordstrom, Saks and Neiman Marcus",
    "FragranceNet and FragranceX", "Jomashop", "decant shops", "r/fragranceswap", "eBay (sealed bottles)", "Fragrantica news for new releases",
    "European niche boutiques that ship to the US", "discontinued and vintage bottle sellers"],
  watches: ["Chrono24", "WatchCharts", "Bob's Watches", "Hodinkee Shop", "The 1916 Company (WatchBox)", "Crown & Caliber", "Analog/Shift",
    "Jomashop", "authorized dealers and brand boutiques", "r/Watchexchange", "WatchUSeek forums", "eBay (authenticated)",
    "Phillips, Christie's and Sotheby's watch auctions", "independent dealers' inventory pages", "Japanese vintage dealers"],
  cars: ["Bring a Trailer", "Cars & Bids", "PCARMARKET", "Hemmings", "AutoTrader", "Cars.com", "CarGurus", "Collecting Cars",
    "duPont REGISTRY", "eBay Motors", "RM Sotheby's, Mecum and Barrett-Jackson", "marque-specific forums' classifieds (Rennlist, Bimmerpost)",
    "certified pre-owned dealer inventory", "specialist and independent dealers"],
  furniture: ["1stDibs", "Chairish", "Kaiyo", "AptDeco", "Design Within Reach", "Herman Miller and Knoll stores", "Hay and Muuto",
    "LiveAuctioneers and Invaluable", "Etsy vintage", "eBay", "Lumens", "local vintage and estate dealers' sites", "designer outlet sales",
    "European design shops that ship to the US"],
  accessories: ["the brands' own sites", "SSENSE", "Mytheresa", "Farfetch", "Nordstrom", "The RealReal", "Fashionphile", "Rebag",
    "Vestiaire Collective", "eBay", "Grailed", "Depop", "independent eyewear and leather boutiques", "Japanese resellers"],
  collectibles: ["official brand and artist stores", "StockX", "eBay", "Heritage Auctions", "Goldin", "Whatnot replays and listings",
    "Mercari", "Etsy", "specialty toy and art shops", "r/ collector communities", "Japanese hobby shops that ship to the US", "convention exclusives"],
  other: ["official brand sites", "major retailers", "eBay", "specialist marketplaces", "independent shops", "forums and communities",
    "auctions", "classifieds", "international sellers that ship to the US"],
};

export function sourcesFor(category: string | null | undefined, agentId: string, now: Date, n = 6): string[] {
  const list = DEEP_SOURCES[category ?? "other"] ?? DEEP_SOURCES.other;
  let h = 7;
  for (const c of agentId) h = (h * 33 + c.charCodeAt(0)) >>> 0;
  const start = (h + Math.floor(now.getTime() / (3 * 3600_000)) * n) % list.length;
  return Array.from({ length: Math.min(n, list.length) }, (_, i) => list[(start + i) % list.length]);
}

/** Their app is in Spanish, French or Korean: what they read ("pitch", "text") is written in it. */
function langLine(a: Agent): string {
  const lang = langOf((a as Agent & { settings?: Record<string, unknown> }).settings?.lang);
  return lang ? `Write each "pitch" and "text" in ${lang} (keep product, brand and store names as they are). Keep "about" in English.` : "";
}

/** Shops the women's or men's department: say so plainly, so every pick is in their department (or unisex). */
function deptLine(a: Agent): string {
  const d = deptOf((a as Agent & { settings?: Record<string, unknown> }).settings);
  if (!d || !["sneakers", "apparel", "accessories", "fragrance"].includes(a.mission_category ?? "")) return "";
  return d === "women"
    ? "They shop women's: only women's or unisex products, in women's sizing. Never men's-only items."
    : "They shop men's: only men's or unisex products, in men's sizing. Never women's-only items.";
}

export function sweepPrompt(a: Agent, today: string, r: Reactions = { liked: [], bought: [], passed: [] }, angles: string[] = [ANGLES[0], ANGLES[4]], leads: Lead[] = [], name = "", sources: string[] = [], depth = depthFor(true)): string {
  const leaning = Object.entries(a.learned ?? {}).filter(([, w]) => w >= 2).sort((x, y) => y[1] - x[1]).map(([k]) => k).slice(0, 10);
  const parts = [
    `Mission: ${missionLabel(a)}`,
    a.keywords.length ? `Must-have keywords: ${a.keywords.join(", ")}` : "",
    a.traits.length ? `Styles and traits they love: ${a.traits.join(", ")}` : "",
    a.makers.length ? `Brands and makers they like: ${a.makers.join(", ")}` : "",
    a.creators.length ? `Creators they follow: ${a.creators.join(", ")}` : "",
    a.size ? `Their size: ${a.size}` : "",
    deptLine(a),
    langLine(a),
    "Never search for or include porn, sex toys or any other adult or sexual content.",
    a.price_note > 0 ? `Budget: they usually spend up to $${Math.round(a.price_note)} on one item. Mostly stay under it; a standout deal slightly over is fine.` : "",
    minBudgetOf(a) ? `Price floor: they want things from $${Math.round(minBudgetOf(a)!)} up. Skip anything well under that.` : "",
    Object.entries(a.learned ?? {}).filter(([, w]) => w < 0).length
      ? `Not into: ${Object.entries(a.learned).filter(([, w]) => w < 0).map(([k]) => k).join(", ")}` : "",
    leaning.length ? `Leaning into lately (from what they liked and bought): ${leaning.join(", ")}` : "",
    r.bought.length ? `They bought: ${r.bought.join("; ")}` : "",
    r.liked.length ? `They liked: ${r.liked.join("; ")}` : "",
    r.passed.length ? `They passed on as not their style: ${r.passed.join("; ")}` : "",
  ].filter(Boolean).join("\n");
  return `Today is ${today}. You are ${a.name}, this person's personal scout. You work for them like a best friend with great taste who's always hunting: proactive, thorough and opinionated. Don't wait to be told exactly what to look for. Search the web hard and come back with specific products they'd be excited to see.

${parts}

This run, hunt from these angles first:
${angles.map((x, i) => `${i + 1}. ${x}`).join("\n")}
Then use any searches left on whatever looks most promising.${sources.length ? `

Dig through these places this run (others get their turn on later runs): ${sources.join("; ")}.` : ""}

How to hunt${depth.deep ? " (leave no stone unturned)" : ""}:
- Search wide: run at least ${depth.minSearches} different searches across at least ${depth.kinds} kinds of places (official brand sites, big retailers,
  resale marketplaces, small boutiques, auctions, forums and communities, international shops that ship to the US).
  Vary the wording: model names, nicknames, style codes, colorways, misspellings people use in listings, "deadstock", "NOS", "rare".
- Look past page one and past the obvious big stores: the best finds are often on a small boutique, a forum post, an auction or a marketplace listing.${depth.fetches > 0 ? `
- Open the most promising product pages with web_fetch to confirm the price, that it's in stock (and in their size), before you include it.` : ""}
- Come back with lots of options: at least ${depth.deep ? 15 : 8} different products this run (more is better), every one new to them.
  Spread them across many makers and stores rather than several from one place.
- Full-size products only (no samples, decants or minis) unless that's what they asked for.
- Things available now, releasing soon, or restocking.${DROP_CATEGORIES.has(a.mission_category ?? "") ? `
- Upcoming and limited releases matter most here. Check release calendars and launch pages (Nike SNKRS upcoming, adidas
  Confirmed, New Balance and Jordan launch pages, retailer raffles like END. Launches and Kith, streetwear droplists, fragrance
  houses' new launches) for products releasing in the next 60 days, and for limited, numbered or collab releases.
  Include upcoming ones even with no price yet: set drop_at to the release date and time (with the timezone if the page gives
  one) and use the brand's or a retailer's launch or product page for that release as the url (not a news article).
- Set "limited": true for limited, numbered, collab or raffle-only releases.` : ""}
- Every result is one of three kinds. Label each with "kind":
  "product": one specific item someone can buy now (its own product page).
  "release": one specific upcoming item with a drop date (set drop_at; use the brand's or a store's launch or product page for it).
  "reference": a calendar, droplist, article, guide, review, forum or community post, group, auction category or collection page.
  Read reference pages as much as you like to discover things, but never return them: return only products and releases.
  When a calendar or article mentions a specific drop that fits them, return that drop itself as a "release" (with its date
  and its own launch or product page), not the calendar or article.
${a.mission_category === "fragrance" ? `- The world around fragrance counts too: include one or two related picks from houses they like or would like, such as
  candles and home scents, body and hair mists, body wash and lotion, or grooming (mark them "discovery": true).
` : ""}- Take initiative: include at least two discovery picks the person never named (a maker, model, note, collab or era that fits their taste), and mark them "discovery": true.${r.liked.length || r.bought.length ? `
- Their likes and buys are the strongest signal: find more in that spirit (same makers, materials, notes, silhouettes, eras), but not the same items again.` : ""}${r.passed.length ? `
- Steer away from what they passed on as not their style.` : ""}${r.seen?.length ? `
- Already shown to them (find different things): ${r.seen.slice(0, 30).join("; ")}` : ""}
- For each product, write "pitch": one short sentence, in your own voice, on why it's for them, in plain words tied to what
  they told you they like (a vibe, a style, a brand, something they liked). Write for someone who may not know the brand.
- For each product, write "about": 1-2 plain sentences (max 260 characters) about this product: what it actually is${a.mission_category === "fragrance" ? `. For fragrance, say what it smells like in everyday words (e.g. "fresh and clean, like
  soap and citrus" or "warm and sweet, like vanilla and wood"), its main notes, and when it's worn (daytime, night out, summer)` : ", what makes it special, and who or what it's for"}.
  No hype words, no jargon. Describe the product, not the brand (the brand is explained separately). Only facts from the page or well known facts about this exact product; if you're not sure, say less.
- For each product, also write "text": the notification you'd text them about it, max 170 characters. Make it feel personal, like
  a friend who knows their taste texting them: say what you found in a few natural words (not the full product title), the key fact
  (price and store, the drop date, or that it's back in stock), and one specific reason it's for THEM, tied to something above
  (a brand they love, a material or note they're into, or something they liked or bought: "since you liked the ..."). ${name ? `Use their name, ${name}, in some texts, not all.` : "You don't know their name, so don't use one."}
  Vary how texts start. Voice: ${VOICE[a.voice] ?? VOICE.chill}. ${a.voice === "straight" ? "" : "At most one emoji. "}No hashtags. Only facts from the page.${leads.length ? `
- Leads from Google Shopping right now (unverified; check any that fit on the store's own product page and use that page's URL):
${leads.map((l) => `  • ${l.title} | ${l.store}${l.price ? ` | ${l.price}` : ""}`).join("\n")}` : ""}

Rules:
- Only include products you actually found on a page during this search, with that page's URL. Never invent a product, price, date or URL.
- The url must be the product's own page: one item you could add to a cart, or one specific vehicle or marketplace listing
  (eBay /itm/, Grailed /listings/, StockX product page, a dealer's page for that one car). Never a search results,
  category, collection, inventory, editorial or home page. If you only found a search or category page, leave it out.
- The title is the exact product name as the page shows it, including model, colorway or variant.
- Price in US dollars as a number, or null if the page doesn't show one. "market" is the typical resale or secondhand price if you saw one, else null.
- drop_at is the release date and time in ISO 8601 if it's upcoming, else null.
- sizes_in_stock only if the page lists them, else null.
- traits are short lowercase descriptors of the product (materials, colors, notes, specs, era).
- Up to 20 products and releases. Every one should be a strong fit; never pad with weak ones.

End your reply with only this JSON in a \`\`\`json block:
{"listings":[{"title":"","brand":"","category":"${a.mission_category ?? "other"}","price":null,"market":null,"source":"store name","url":"https://...","image_url":null,"drop_at":null,"sold_out":false,"creator":null,"traits":[],"sizes_in_stock":null,"sku":"","kind":"product","discovery":false,"limited":false,"about":"","pitch":"","text":""}]}`;
}

/** Cleans what Claude returned. Anything without a real web address is dropped. */
/** Search results and category pages aren't products. eBay items live under /itm/. */
export function isSearchPage(url: string): boolean {
  let u: URL;
  try { u = new URL(url); } catch { return true; }
  const path = u.pathname.toLowerCase();
  if (/[?&](_nkw|q|query|keyword|keywords|searchterm|search|k|text)=/i.test(u.search)) return true;
  if (/(^|\/)(search|sch|searchresults|results)(\/|$)/.test(path)) return true;
  if (/(^|\.)ebay\./.test(u.hostname) && !path.startsWith("/itm/")) return true;
  if (path === "/" || path === "") return true;
  return false;
}

/** A product description people read: drops the model's notes to itself ("Price and sizes not shown in the snippet",
 *  "I couldn't confirm…"), sentence by sentence. Null when nothing useful is left. */
const META = /\b(snippet|search results?|the (listing|page|source) (doesn't|does not|didn't)|not (shown|listed|provided|mentioned|specified) in|(i|we) (could not|couldn't|can't|cannot|wasn't able to|was unable to)|unable to (confirm|verify|find))\b/i;
export function cleanAbout(text: string): string | null {
  const t = text.trim().replace(/\s+/g, " ");
  const kept = (t.match(/[^.!?]+[.!?]*/g) ?? [t]).map((x) => x.trim()).filter((x) => x && !META.test(x)).join(" ");
  return kept.length > 15 ? kept.slice(0, 400) : null;
}

export function cleanListings(raw: unknown, fallbackCategory: string): (Listing & { fingerprint: string; url: string; sku: string; image_url: string | null; discovery: boolean; about: string | null; pitch: string; text: string })[] {
  const arr = (raw as { listings?: unknown[] })?.listings;
  if (!Array.isArray(arr)) return [];
  const out = [];
  for (const r of arr.slice(0, 24) as Record<string, unknown>[]) {
    const title = typeof r.title === "string" ? r.title.trim().slice(0, 200) : "";
    const url = typeof r.url === "string" ? r.url.trim() : "";
    let host = "";
    try { const u = new URL(url); if (u.protocol === "https:" || u.protocol === "http:") host = u.hostname.replace(/^www\./, ""); } catch { /* bad url */ }
    if (!title || !host || isSearchPage(url)) continue;
    const price = typeof r.price === "number" && r.price >= 0 ? r.price : null;
    const market = typeof r.market === "number" && r.market > 0 ? r.market : null;
    const cat = typeof r.category === "string" && (CATEGORIES as string[]).includes(r.category) ? r.category : fallbackCategory;
    const strs = (v: unknown, n: number) => Array.isArray(v) ? v.filter((x) => typeof x === "string").map((x) => (x as string).trim()).filter(Boolean).slice(0, n) : [];
    let drop: string | null = null;
    if (typeof r.drop_at === "string" && !Number.isNaN(Date.parse(r.drop_at))) drop = new Date(r.drop_at).toISOString();
    let image: string | null = null;
    if (typeof r.image_url === "string" && /^https:\/\//.test(r.image_url)) image = r.image_url.slice(0, 500);
    const sizes = Array.isArray(r.sizes_in_stock) ? strs(r.sizes_in_stock, 40) : null;
    out.push({
      fingerprint: `${host}|${norm(title).replace(/[^a-z0-9]+/g, " ").trim()}`.slice(0, 300),
      title,
      brand: typeof r.brand === "string" ? r.brand.trim().slice(0, 80) : "",
      category: cat,
      price, market,
      source: typeof r.source === "string" && r.source.trim() ? r.source.trim().slice(0, 80) : host,
      url: url.slice(0, 1000),
      image_url: image,
      drop_at: drop,
      sold_out: r.sold_out === true,
      creator: typeof r.creator === "string" && r.creator.trim() ? r.creator.trim().slice(0, 80) : null,
      traits: strs(r.traits, 10).map((t) => t.toLowerCase()),
      tags: [...(r.limited === true ? ["limited"] : []), ...(r.intel === true || r.kind === "reference" ? ["intel"] : []), ...(r.kind === "release" ? ["release"] : [])],
      sizes_in_stock: sizes && sizes.length ? sizes : null,
      sku: typeof r.sku === "string" ? r.sku.trim().slice(0, 60) : "",
      discovery: r.discovery === true,
      about: typeof r.about === "string" ? cleanAbout(r.about) : null,
      pitch: typeof r.pitch === "string" ? r.pitch.trim().slice(0, 160) : "",
      text: cleanText(r.text),
    });
  }
  return out;
}

/** Two titles name the same product (most of one's distinctive words are in the other). */
export function sameProduct(a: string, b: string): boolean {
  const ws = (s: string) => new Set(norm(s).split(/[^a-z0-9]+/).filter((w) => w.length > 2 && !["the", "and", "for", "eau", "parfum", "with", "new"].includes(w)));
  const x = ws(a), y = ws(b);
  if (!x.size || !y.size) return false;
  const shared = [...x].filter((w) => y.has(w)).length;
  return shared / Math.min(x.size, y.size) >= 0.8;
}

/** The last hunt's listings (for the Diagnose model comparison). */
const lastHunt: string[] = [];

/** The model for hunts: SWEEP_MODEL if set, else Haiku. In side-by-side tests (Oct 18) Haiku found as many real,
 *  in-stock products as Sonnet at about a fifth of the cost. Chat and setup keep the app-wide model. */
export const SWEEP_MODEL = () => env("SWEEP_MODEL") ?? "claude-haiku-5-5";

/** A scout whose last 3 hunts found nothing new rests: scheduled hunts are skipped until 3 days after its last real
 *  hunt, then it tries again (and rests again if that one is empty too). Hunting from the app always runs. */
export const REST_AFTER_EMPTY = 3;
/** Empty hunts before this don't count: until then, scouts without a size or with a typed-in mission found nothing
 *  because of a matching bug (fixed Oct 23, 2026), and they deserve fresh hunts now. */
const EMPTY_SINCE = "2026-10-23T14:00:00Z";
export async function restingAfterNothing(agentId: string, now = new Date()): Promise<boolean> {
  const last = await db.select<{ finds: number; created_at: string }>("sweep_runs",
    `select=finds,created_at&agent_id=eq.${agentId}&trigger=in.(scheduled,manual)&error=is.null&created_at=gt.${EMPTY_SINCE}&order=created_at.desc&limit=${REST_AFTER_EMPTY}`).catch(() => []);
  if (!Array.isArray(last) || last.length < REST_AFTER_EMPTY || last.some((r) => !r || r.finds > 0)) return false;
  return now.getTime() - Date.parse(last[0].created_at) < num("REST_HOURS", 72) * 3600_000;
}

/** Where a redirect link really goes (one hop), or null. */
export async function redirectTarget(url: string, fetchFn: typeof fetch = fetch): Promise<string | null> {
  try {
    const r = await fetchFn(url, { method: "GET", redirect: "manual", signal: AbortSignal.timeout(5000) });
    const loc = r.headers.get("location");
    if (!loc || !/^https:\/\//.test(loc)) return null;
    const u = new URL(loc);
    for (const k of [...u.searchParams.keys()]) if (/^(utm_|srsltid|gclid|fbclid)/i.test(k)) u.searchParams.delete(k);
    return u.toString();
  } catch { return null; }
}

/** Finds saved before the product-only rules (Oct 28, 2026) that are really calendars, articles, guides, groups,
 *  collection pages or broken links: archived, if nobody touched them (not liked, watched, reminded or bought). */
const PAGE_FIX = "2026-10-28T21:00:00Z";
export async function scrubPageFinds(limit = 1500) {
  if (Date.now() > Date.parse("2026-11-04T00:00:00Z")) return { checked: 0, removed: 0 };
  const rows = await db.select<{ id: string; user_id: string; listing_id: string; listing: { title: string; url: string | null; price: number | null; sku: string | null; sizes_in_stock: string[] | null; drop_at: string | null; tags: string[] } | null }>(
    "finds", `select=id,user_id,listing_id,listing:listings(title,url,price,sku,sizes_in_stock,drop_at,tags)&status=eq.open&watching=is.false&created_at=lt.${PAGE_FIX}&limit=${limit}`);
  const reminded = new Set((await db.select<{ user_id: string; listing_id: string }>("release_reminders", "select=user_id,listing_id").catch(() => []))
    .map((r) => `${r.user_id}|${r.listing_id}`));
  const bad = rows.filter((f) => f.listing && !reminded.has(`${f.user_id}|${f.listing_id}`)
    && notFindable({ ...f.listing, url: f.listing.url ?? "" }));
  for (let i = 0; i < bad.length; i += 100) {
    const ids = bad.slice(i, i + 100).map((f) => f.id);
    await db.update("finds", `id=in.(${ids.join(",")})&status=eq.open`, { status: "removed" }).catch((e) => console.error("page finds", e));
    await db.update("notes", `find_id=in.(${ids.join(",")})&read=eq.false`, { read: true }).catch(() => {});
  }
  return { checked: rows.length, removed: bad.length };
}

/** More finds from Baget's store map: products read straight from stores' catalogs that fit this scout and that this
 *  person hasn't been shown yet. Strongest first, a few per maker so it's a spread. No texts: they just land in Finds. */
export async function catalogFinds(a: Candidate, skip: Set<string>, pro: boolean, photoTags: string[] = []) {
  if (!a.mission_category) return [];
  const want = pro ? num("CATALOG_FINDS_PRO", 15) : num("CATALOG_FINDS_FREE", 6);
  if (want <= 0) return [];
  const since = new Date(Date.now() - 30 * 86400_000).toISOString();
  const [pool, had] = await Promise.all([
    db.select<Listing & { id: string; image_url: string | null }>("listings",
      `select=id,title,brand,category,price,market,source,url,image_url,traits,tags,sizes_in_stock,sold_out,drop_at,creator` +
      `&category=eq.${a.mission_category}&tags=cs.{catalog}&image_url=not.is.null&url=not.is.null&sold_out=is.false` +
      `&last_seen_at=gte.${since}&order=last_seen_at.desc&limit=800`),
    db.select<{ listing_id: string; status: string; listing?: { brand: string } | null }>("finds",
      `select=listing_id,status,listing:listings(brand)&user_id=eq.${a.user_id}&limit=5000`),
  ]);
  const seen = new Set([...had.map((f) => f.listing_id), ...skip]);
  // Makers they've liked or bought anywhere in Baget rank first.
  const loved = new Set(had.filter((f) => f.status === "liked" || f.status === "acquired").map((f) => norm(f.listing?.brand ?? "")).filter(Boolean));
  const dept = deptOf(a.settings);
  // Anything that fits the mission (category, department, price range, full size) counts; what matches their stated
  // keywords, brands and styles, and makers they love, comes first.
  const rank = (l: Listing, score: number) => score + (loved.has(norm(l.brand)) ? 15 : 0);
  const scored = pool.filter((l) => !seen.has(l.id))
    .map((l) => ({ l, m: match(a, l, photoTags, { own: true, dept }) }))
    .filter((x) => x.m && !x.m.notInSize && x.m.score >= 35)
    .sort((x, y) => rank(y.l, y.m!.score) - rank(x.l, x.m!.score));
  const perMaker = new Map<string, number>();
  const out: { listing_id: string; score: number; why: string[] }[] = [];
  for (const { l, m } of scored) {
    const k = norm(l.brand || l.source);
    if ((perMaker.get(k) ?? 0) >= 3) continue;
    perMaker.set(k, (perMaker.get(k) ?? 0) + 1);
    out.push({ listing_id: l.id, score: m!.score, why: m!.why.slice(0, 5) });
    if (out.length >= want) break;
  }
  return out;
}

export async function sweepAgent(a: Candidate, trigger: "scheduled" | "manual", now = new Date(),
                                 opts: { model?: string; provider?: "serper" | "claude" } = {}) {
  const run = { user_id: a.user_id, agent_id: a.id, trigger, searches: 0, listings: 0, finds: 0, tandem: 0, input_tokens: 0, output_tokens: 0, cache_write_tokens: 0, cache_read_tokens: 0, fetches: 0, error: null as string | null };
  if (trigger === "scheduled" && await restingAfterNothing(a.id, now)) {
    await db.rpc("record_finds", { p_agent: a.id, p_finds: [] }).catch(() => 0);   // stamps the sweep time so it isn't picked again right away
    return run;
  }
  // Baget never hunts adult content: a scout set up for it never searches.
  if (isAdultText(a.name, a.mission_custom, a.keywords, a.makers, a.traits, a.creators)) {
    await db.rpc("record_finds", { p_agent: a.id, p_finds: [] }).catch(() => 0);
    run.error = "adult_content";
    return run;
  }
  try {
    const reactions = await reactionsFor(a.id).catch(() => undefined);
    // Extra sources (each only when its key is set): Google Shopping leads for Claude, and real eBay listings.
    const queries = queriesFor(a, reactions?.liked ?? [], now);
    const [leads, ebayRaw] = await Promise.all([
      shoppingLeads(queries).catch(() => [] as Lead[]),
      ebaySearch(a, queries).catch(() => [] as Record<string, unknown>[]),
    ]);
    const depth = depthFor(a.pro !== false);
    const rotation = await storeLeads(a, a.pro !== false ? num("STORE_SEARCHES_PRO", 4) : num("STORE_SEARCHES_FREE", 2), now).catch(() => ({ text: "", searches: 0, stores: [] as string[] }));
    run.searches += rotation.searches;
    const messages: ClaudeMessage[] = [{ role: "user", content: (rotation.text ? rotation.text + "\n\n" : "") + sweepPrompt(a, now.toISOString().slice(0, 10), reactions, (DROP_CATEGORIES.has(a.mission_category ?? "") ? [UPCOMING_ANGLE, ...anglesFor(a.id, now)] : anglesFor(a.id, now)).slice(0, depth.angles), leads,
      firstName(a.display_name), sourcesFor(a.mission_category, a.id, now, depth.sources), depth) }];
    // The second scout (Gemini + Google Search) hunts the same brief at the same time; its picks are merged below.
    const tandem = geminiOn() ? geminiHunt(String(messages[0].content), Math.ceil(depth.searches / 2)) : Promise.resolve(null);
    // Searching: through Serper (Google, ~10x cheaper) when it's working, else Claude's built-in web search.
    const useSerper = opts.provider ? opts.provider === "serper" : await serperUsable();
    const tools: Record<string, unknown>[] = useSerper ? [SEARCH_TOOL]
      : [{ type: "web_search_20250305", name: "web_search", max_uses: depth.searches, user_location: { type: "approximate", country: "US" } }];
    // Deep hunts (Pro) open product pages to check price, stock and sizes. Capped so one page can't flood the context.
    if (depth.fetches > 0) tools.push({ type: "web_fetch_20250910", name: "web_fetch", max_uses: depth.fetches, max_content_tokens: 6000 });
    const model = opts.model ?? SWEEP_MODEL();
    let final: Block[] = [];
    const started = Date.now();
    let wrapped = false;
    let searchesLeft = depth.searches;
    for (let turn = 0; turn < 20; turn++) {
      const res = await claude({ model, max_tokens: 12000, messages, tools, cache: true, purpose: "sweep" });
      run.input_tokens += res.usage?.input_tokens ?? 0;
      run.output_tokens += res.usage?.output_tokens ?? 0;
      run.cache_write_tokens += res.usage?.cache_creation_input_tokens ?? 0;
      run.cache_read_tokens += res.usage?.cache_read_input_tokens ?? 0;
      run.searches += res.usage?.server_tool_use?.web_search_requests ?? 0;
      run.fetches += res.usage?.server_tool_use?.web_fetch_requests ?? 0;
      final = res.content;
      const timeUp = Date.now() - started > 95_000;
      if (res.stop_reason === "tool_use") {
        messages.push({ role: "assistant", content: res.content });
        const results: Block[] = [];
        for (const b of res.content.filter((x) => x.type === "tool_use")) {
          const q = String((b.input as { query?: string })?.query ?? "").trim();
          let out: string;
          if (b.name !== "search" || !q) out = "Unknown tool.";
          else if (searchesLeft <= 0 || timeUp) out = "No searches left for this run. Reply now with the JSON for the best products you've confirmed.";
          else {
            searchesLeft--;
            run.searches++;
            out = await serperSearch(q).then((hits) => hitsText(q, hits)).catch(() => "Search failed. Try another query or wrap up.");
          }
          results.push({ type: "tool_result", tool_use_id: b.id, content: out });
        }
        if (timeUp && !wrapped) { wrapped = true; results.push({ type: "text", text: "Time's up for this run: reply now with the JSON." }); }
        messages.push({ role: "user", content: results });
        continue;
      }
      if (res.stop_reason !== "pause_turn") break;
      messages.push({ role: "assistant", content: res.content });   // continue a long server-side search turn
      if (!wrapped && timeUp) {
        wrapped = true;
        // Running long: ask for the results so far instead of searching more (keeps the run inside the server's time limit).
        messages.push({ role: "user", content: "Time's up for this run. Don't search any more: reply now with the JSON for the best products you've confirmed so far." });
      }
    }
    const blocked = await blockedDomains();
    // Only products and releases become finds. Calendars, articles, guides, groups and collection pages ("reference")
    // are dropped here, whatever the scout called them: by the scout's own label, then by address, title and product signals.
    const classify = (raw: unknown) => cleanListings(raw, a.mission_category ?? "other").flatMap((l) => {
      if (/vertexaisearch\.cloud\.google\.com/.test(l.url)) return [l];   // resolved (and checked) below
      const k = pageKind(l.url, blocked);
      if (!k || k !== "product") return [];
      return notFindable(l) ? [] : [l];
    });
    let listings = classify(parseJSON(textOf(final)));
    // Merge the second scout's picks. A product both found independently is marked "both" (it ranks higher).
    const second = await tandem;
    if (second) {
      const theirs = classify(second);
      run.tandem = theirs.length;
      for (const l of theirs) {
        const twin = listings.find((x) => x.fingerprint === l.fingerprint || (x.category === l.category && sameProduct(x.title, l.title)));
        if (twin) { if (!twin.tags.includes("both")) twin.tags.push("both"); continue; }
        l.tags = [...l.tags, "scout2"];
        listings.push(l);
      }
    }
    // The second scout's links come as Google redirects: follow them to the store's own page (or drop them).
    listings = (await Promise.all(listings.map(async (l) => {
      if (!/vertexaisearch\.cloud\.google\.com/.test(l.url)) return l;
      const real = await redirectTarget(l.url);
      if (!real) return null;
      const host = new URL(real).hostname.replace(/^www\./, "");
      const r = { ...l, url: real, fingerprint: `${host}|${l.fingerprint.split("|").slice(1).join("|")}`.slice(0, 300),
                  source: /vertexaisearch/.test(l.source) ? host : l.source };
      return notFindable(r) ? null : r;
    }))).filter((l): l is NonNullable<typeof l> => l !== null);
    lastHunt.splice(0, lastHunt.length, ...listings.map((l) => `${l.title} | ${l.source} | ${l.price ?? "?"} | ${l.url}`.slice(0, 220)));
    // Made-up links (404) go; then each real one gets a verified product photo.
    const dead = await Promise.all(listings.map((l) => linkIsDead(l.url)));
    listings = listings.filter((_, i) => !dead[i]);
    if (listings.length) await addImages(listings);
    // eBay listings come straight from eBay with their own item page and photo, so they skip both checks.
    const ebay = cleanListings({ listings: ebayRaw }, a.mission_category ?? "other");
    const seen = new Set(listings.map((l) => l.fingerprint));
    for (const l of ebay) if (!seen.has(l.fingerprint)) { listings.push(l); seen.add(l.fingerprint); }
    run.listings = listings.length;
    if (!listings.length) {
      // Nothing new on the web this time: still bring them more from Baget's store map.
      const more = await catalogFinds(a, new Set(), a.pro !== false).catch((e) => { console.error("catalog finds", e); return []; });
      run.finds = more.length ? await db.rpc<number>("record_finds", { p_agent: a.id, p_finds: more }) : 0;
      if (!more.length) await db.rpc("record_finds", { p_agent: a.id, p_finds: [] });
      return run;
    }

    const saved = await db.rpc<{ fingerprint: string; id: string; already_found: boolean }[]>("upsert_listings", { p_user: a.user_id, p_listings: listings });
    // Remember which products this person's scouts came across: their For You is built only from these.
    if (saved.length) {
      await db.raw("/rest/v1/listing_seen", { method: "POST", headers: { Prefer: "return=minimal,resolution=merge-duplicates" },
        body: JSON.stringify(saved.map((x) => ({ user_id: a.user_id, listing_id: x.id, seen_at: new Date().toISOString() }))) })
        .catch((e) => console.error("listing_seen", e));
    }
    const ids = new Map(saved.map((s) => [s.fingerprint, s]));
    // Other stores' prices for new listings, for the deal verdict.
    const isProduct = (fp: string) => { const t = listings.find((l) => l.fingerprint === fp)?.tags ?? []; return !t.includes("intel") && !t.includes("search"); };
    await attachOffers(saved.filter((s) => !s.already_found && isProduct(s.fingerprint)).map((s) => { const l = listings.find((x) => x.fingerprint === s.fingerprint); return { id: s.id, title: l?.title ?? "", brand: l?.brand, price: l?.price }; })
      .filter((r) => r.title), (id, patch) => db.update("listings", `id=eq.${id}`, patch)).catch(() => 0);
    const photos = await db.select<{ tags: string[] }>("taste_photos", `select=tags&agent_id=eq.${a.id}`);
    const photoTags = photos.flatMap((p) => p.tags);
    const settings = a.settings ?? {};
    const quiet = settings.quietHours !== false;
    const groups = Array.isArray(settings.groups) ? settings.groups as string[] : null;

    const finds = [];
    for (const l of listings) {
      const s = ids.get(l.fingerprint);
      if (!s || s.already_found) continue;
      const m = match(a, l, photoTags, { own: true, dept: deptOf(a.settings) });
      const info = l.tags.includes("intel") || l.tags.includes("search");
      // Discovery picks and intel are the agent's own initiative, so they don't need to hit the stated keywords as hard.
      if (!m || (!info && m.notInSize) || m.score < (l.discovery || info ? 35 : 45)) continue;
      const kind = kindFor(l, now.getTime());
      // No photo, no text: a find only buzzes your phone once Baget has its real photo. Intel and searches never text.
      const wantNote = !info && (!groups || groups.includes(GROUP_OF[kind])) && !!l.image_url;
      const both = l.tags.includes("both");
      const why = [...(l.pitch ? [l.pitch] : []), ...(both ? ["Both scouts found this on their own"] : []),
        ...(l.discovery ? ["Discovery: something new it found for you"] : []), ...m.why].slice(0, 6);
      // The agent's own personal text first; the templates are the fallback.
      const body = l.text ? l.text : l.discovery && l.pitch
        ? `Found something you didn't ask for but I think you'll love: ${l.title}${l.price ? ` ($${Math.round(l.price)})` : ""} at ${l.source}. ${l.pitch}`
        : friendLine(a, kind, l, m.score, now.getTime());
      finds.push({
        listing_id: s.id, score: Math.min(99, Math.max(m.score, l.discovery ? 60 : 0) + (both ? 10 : 0)), why,
        ...(wantNote ? { note: { kind, body: body.slice(0, 480), held: heldForMorning(kind, l, a.tz, quiet, now) } } : {}),
      });
    }
    // Plus more options from Baget's store map (thousands of products read straight from stores), quietly: no texts.
    const more = await catalogFinds(a, new Set(saved.map((x) => x.id)), a.pro !== false, photoTags).catch((e) => { console.error("catalog finds", e); return []; });
    finds.push(...more);
    run.finds = finds.length ? await db.rpc<number>("record_finds", { p_agent: a.id, p_finds: finds }) : 0;
    if (!finds.length) await db.rpc("record_finds", { p_agent: a.id, p_finds: [] });   // still stamps the sweep time
    return run;
  } catch (e) {
    run.error = (e as Error).message.slice(0, 300);
    return run;
  } finally {
    await db.insert("sweep_runs", run, false).catch((e) => console.error("sweep_runs", e));
  }
}

/** Listings saved before photos were looked up (or whose page didn't answer): try each once. */
export async function backfillImages(limit: number) {
  const rows = await db.select<{ id: string; url: string; title: string; brand: string; category: string }>("listings",
    `select=id,url,title,brand,category&image_url=is.null&url=not.is.null` +
    `&or=(image_checked_at.is.null,image_checked_at.lt.${new Date(Date.now() - 24 * 3600_000).toISOString()})` +
    `&order=image_checked_at.asc.nullsfirst,last_seen_at.desc&limit=${limit}`);
  let found = 0;
  for (let i = 0; i < rows.length; i += 6) {
    const items = rows.slice(i, i + 6).map((r) => ({ ...r, fingerprint: r.id, image_url: null as string | null }));
    found += await addImages(items);
    await Promise.all(items.map((r) =>
      db.update("listings", `id=eq.${r.id}`, { image_url: r.image_url, image_checked_at: new Date().toISOString() })));
  }
  return { checked: rows.length, found };
}

/** Matches a batch answer back to what was asked, by id AND by the name the model echoes back. Anything that doesn't
 *  match both (skipped, reordered, mixed up) is dropped, so a blurb can never land on the wrong brand or product. */
export function keyed(raw: unknown, field: string, asked: { id: string; name: string }[]): (string | null)[] {
  const items = (raw as { items?: unknown[] } | null)?.items;
  const byId = new Map<string, Record<string, unknown>>();
  if (Array.isArray(items)) for (const it of items) {
    const r = it as Record<string, unknown>;
    if (r && typeof r.id === "string") byId.set(r.id.trim().toLowerCase().replace(/^\[|\]$/g, ""), r);
  }
  // Same item if the names match, or (long marketplace titles get trimmed when echoed back) most of the words do.
  const words = (x: string) => new Set(norm(x).split(/[^a-z0-9]+/).filter((w) => w.length > 1));
  const same = (a: string, b: string) => {
    if (norm(a).replace(/[^a-z0-9]+/g, "") === norm(b).replace(/[^a-z0-9]+/g, "")) return true;
    const A = words(a), B = words(b);
    if (A.size < 3 || B.size < 3) return false;
    const shared = [...A].filter((w) => B.has(w)).length;
    return shared / Math.min(A.size, B.size) >= 0.8 && shared / Math.max(A.size, B.size) >= 0.5;
  };
  return asked.map((q) => {
    const r = byId.get(q.id.toLowerCase());
    const echoed = r && (typeof r.name === "string" ? r.name : typeof r.title === "string" ? r.title : "");
    if (!r || !echoed || !same(echoed, q.name)) return null;
    const v = r[field];
    return typeof v === "string" && v.trim() ? v.trim().replace(/\s+/g, " ") : null;
  });
}

/** Plain-language "about" lines for products saved without one (older finds, eBay listings). One cheap call per batch,
 *  no web search: only what's well known about that exact product. Unsure → stays empty rather than made up. */
type AboutRow = { id: string; title: string; brand: string; category: string; traits: string[]; source: string };

function aboutRequest(batch: AboutRow[]) {
  const list = batch.map((r, j) => `[p${j + 1}] ${r.title}${r.brand ? ` | brand: ${r.brand}` : ""} | ${r.category}${r.traits?.length ? ` | ${r.traits.join(", ")}` : ""} | sold at ${r.source}`).join("\n");
  return { model: SWEEP_MODEL(), max_tokens: 4000, messages: [{ role: "user", content:
`Write a plain-language description for each product below, for a shopper seeing it for the first time.
1-2 sentences, max 260 characters, everyday words, no hype or jargon: what it is, and what makes it special or who it's for.
For a fragrance: what it smells like in everyday words (e.g. "fresh and clean, like soap and citrus"), main notes, and when it's worn.
Describe the product itself, not the brand: who the brand is is shown separately, so don't explain it here.
Only say what you're confident is true of this exact product. If you don't know a fragrance's notes, don't guess them: describe only
what the name and details show. If you can't say anything useful, use null.

${list}

Reply with only JSON, one entry per product, copying its id and its title:
{"items":[{"id":"p1","title":"<title>","about":"..." or null}, ...]}` }] };
}

/** Saves one reply's descriptions. An unreadable reply changes nothing, so those products are tried again later. */
async function applyAbout(batch: AboutRow[], text: string) {
  const parsed = parseJSON(text) as { items?: Record<string, unknown>[] } | null;
  const items = Array.isArray(parsed?.items) ? parsed!.items : [];
  if (!items.length) return { checked: 0, written: 0 };
  const out = keyed(parsed, "about", batch.map((r, j) => ({ id: `p${j + 1}`, name: r.title })));
  let written = 0;
  await Promise.all(batch.map((r, j) => {
    const a = out[j] ? cleanAbout(out[j]!) : null;
    if (a) written++;
    return db.update("listings", `id=eq.${r.id}`, { about: a, about_checked_at: new Date().toISOString() });
  }));
  return { checked: batch.length, written };
}

const aboutRows = (limit: number) => db.select<AboutRow>("listings",
  `select=id,title,brand,category,traits,source&about=is.null&about_checked_at=is.null` +
  `&last_seen_at=gt.${new Date(Date.now() - 60 * 86400_000).toISOString()}&order=last_seen_at.desc&limit=${limit}`);

/** Plain-language descriptions for older products, right away (small batches of 8 so no reply gets cut off). */
export async function backfillAbout(limit: number) {
  const rows = await aboutRows(limit);
  let written = 0, checked = 0;
  for (let i = 0; i < rows.length; i += 8) {
    const batch = rows.slice(i, i + 8);
    const res = await claude({ ...aboutRequest(batch), purpose: "about" });
    const r = await applyAbout(batch, textOf(res.content));
    checked += r.checked; written += r.written;
  }
  return { checked, written };
}

function brandsRequest(names: string[]) {
  return { model: MODEL(), max_tokens: 3000,   // the app-wide model: written once per brand, so accuracy wins
    messages: [{ role: "user", content:
`For each brand below, write a short blurb for a shopper who may be new to it: who they are, where they're from, what they're
known for and their price range (e.g. "A New York perfume house known for small-batch, unisex scents made fresh to order.
Pricey, around $200+ a bottle."). 1-2 sentences, max 220 characters, everyday words, no hype.
Only what you're confident is true. If you don't know a brand (or it's a store, not a brand), use null.

${names.map((n, i) => `[b${i + 1}] ${n}`).join("\n")}

Reply with only JSON, one entry per brand, copying its id and exact name:
{"items":[{"id":"b1","name":"<exact brand name>","blurb":"..." or null}, ...]}` }] };
}

async function applyBrands(names: string[], text: string) {
  const out = keyed(parseJSON(text), "blurb", names.map((n, i) => ({ id: `b${i + 1}`, name: n })));
  let written = 0;
  const rows = names.map((n, i) => {
    const b = out[i] && out[i]!.length > 20 ? out[i]!.slice(0, 400) : null;
    if (b) written++;
    return { key: n.trim().toLowerCase(), name: n.trim(), blurb: b };
  });
  await db.raw("/rest/v1/brand_blurbs", { method: "POST", headers: { Prefer: "return=minimal,resolution=ignore-duplicates" }, body: JSON.stringify(rows) });
  return written;
}

/** A short blurb about each brand on recent listings, written once per brand and copied onto its listings, right away.
 *  Only well-known facts; a brand the model doesn't know gets no blurb (saved as null so it isn't retried every run). */
export async function backfillBrands(limit: number) {
  const names = (await db.rpc<{ name: string }[]>("brands_needing_blurbs", { p_limit: limit })).map((r) => r.name).filter(Boolean);
  let written = 0;
  if (names.length) written = await applyBrands(names, textOf((await claude({ ...brandsRequest(names), purpose: "brands" })).content));
  const applied = await db.rpc<number>("apply_brand_blurbs", {});
  return { brands: names.length, written, applied };
}

// ── The same two jobs through Anthropic's batch processing: about half the price, results within hours (usually
// minutes). One batch of each kind at a time, so nothing is sent twice; failed or expired requests are simply
// picked up again by the next batch. ──

interface BatchRow { id: string; kind: string; items: Record<string, unknown>; created_at: string }

export async function batchBackfills() {
  const out: Record<string, unknown> = { applied: await collectBatches() };
  const pending = new Set((await db.select<{ kind: string }>("claude_batches", "select=kind&finished_at=is.null")).map((r) => r.kind));
  if (!pending.has("about")) {
    const rows = await aboutRows(num("ABOUT_BACKFILL", 40));
    if (rows.length) {
      const chunks: Record<string, AboutRow[]> = {};
      for (let i = 0; i < rows.length; i += 8) chunks[`about-${i / 8}`] = rows.slice(i, i + 8);
      const id = await submitBatch(Object.entries(chunks).map(([cid, rs]) => ({ custom_id: cid, params: aboutRequest(rs) })));
      await db.insert("claude_batches", { id, kind: "about", items: chunks }, false);
      out.about_sent = rows.length;
    }
  }
  if (!pending.has("brands")) {
    const names = (await db.rpc<{ name: string }[]>("brands_needing_blurbs", { p_limit: num("BRAND_BACKFILL", 15) })).map((r) => r.name).filter(Boolean);
    if (names.length) {
      const id = await submitBatch([{ custom_id: "brands-0", params: brandsRequest(names) }]);
      await db.insert("claude_batches", { id, kind: "brands", items: { "brands-0": names } }, false);
      out.brands_sent = names.length;
    }
  }
  out.brands_applied = await db.rpc<number>("apply_brand_blurbs", {}).catch(() => 0);
  return out;
}

async function collectBatches() {
  const open = await db.select<BatchRow>("claude_batches", "select=id,kind,items,created_at&finished_at=is.null");
  let applied = 0;
  for (const b of open) {
    const st = await batchStatus(b.id).catch(() => null);
    const stale = Date.now() - Date.parse(b.created_at) > 30 * 3600_000;
    if (!st || (st.processing_status !== "ended" && !stale)) continue;
    if (st.processing_status === "ended" && st.results_url) {
      for (const r of await batchResults(st.results_url).catch(() => [])) {
        if (r.result?.type !== "succeeded" || !r.result.message) continue;
        const msg = r.result.message;
        await logBatchUsage(b.kind, String(msg.model ?? ""), msg.usage);
        const text = textOf(msg.content ?? []);
        if (b.kind === "about") applied += (await applyAbout((b.items[r.custom_id] ?? []) as AboutRow[], text)).written;
        else if (b.kind === "brands") applied += await applyBrands((b.items[r.custom_id] ?? []) as string[], text);
      }
    }
    await db.update("claude_batches", `id=eq.${encodeURIComponent(b.id)}`, { finished_at: new Date().toISOString() });
  }
  return applied;
}

/** Starts one scheduled hunt in its own worker and waits for it (each worker has its own time and memory budget). */
async function dispatchOne(a: Candidate) {
  const r = await fetch(`${env("SUPABASE_URL")}/functions/v1/sweep`, {
    method: "POST",
    headers: { "Content-Type": "application/json", "x-baget-secret": env("BAGET_CRON_SECRET") ?? "" },
    body: JSON.stringify({ one: a }),
  });
  await r.body?.cancel().catch(() => {});
  if (!r.ok && r.status !== 546) throw new Error(`hunt ${a.id}: ${r.status}`);
}

/** Upkeep on its own schedule: missing photos, then descriptions, then brand blurbs. Each step's failure is logged
 *  and doesn't stop the next. */
export async function maintain() {
  const out: Record<string, unknown> = {};
  out.images = await backfillImages(num("IMAGE_BACKFILL", 12)).catch((e) => { console.error("images", e); return null; });
  if (env("CLAUDE_BATCH") === "off") {
    out.about = await backfillAbout(num("ABOUT_BACKFILL", 20)).catch((e) => { console.error("about", e); return null; });
    out.brands = await backfillBrands(num("BRAND_BACKFILL", 15)).catch((e) => { console.error("brands", e); return null; });
  } else {
    out.batches = await batchBackfills().catch((e) => { console.error("batches", e); return null; });
  }
  out.restocks = await restockCheck(num("RESTOCK_CHECKS", 15)).catch((e) => { console.error("restocks", e); return null; });
  out.refreshed = await refreshFinds(num("REFRESH_CHECKS", 40)).catch((e) => { console.error("refresh", e); return null; });
  out.pageFinds = await scrubPageFinds().catch((e) => { console.error("page finds", e); return null; });
  out.scrubbed = await scrubOffers(400).catch((e) => { console.error("scrub", e); return null; });
  out.birthdays = await db.rpc<number>("birthday_nudges", {}).catch((e) => { console.error("birthdays", e); return null; });
  out.prices = await repriceOld(num("PRICE_BACKFILL", 10)).catch((e) => { console.error("prices", e); return null; });
  out.stores = await db.rpc<number>("learn_stores", {}).catch((e) => { console.error("stores", e); return null; });
  // Taste Cards for people who share their taste with friends, written fresh every few days.
  out.cards = await refreshTasteCards(num("TASTE_CARDS", 5)).catch((e) => { console.error("cards", e); return null; });
  // Finds nobody touched in a week step aside so Finds stays a short list of what's worth a look.
  out.archived = await db.rpc<number>("archive_stale_finds", { p_days: 7 }).catch((e) => { console.error("archive", e); return null; });
  return out;
}

// ── Taste Cards ──

export interface TasteCard { archetype: string; signature: string[]; notes: string[]; hunts: string[]; grail: string | null; palette: string[] }

/** Cleans what the model wrote into a card the app can show: short strings, real hex colors. */
export function cleanCard(raw: unknown): TasteCard | null {
  const r = (raw ?? {}) as Record<string, unknown>;
  const strs = (v: unknown, n: number, len: number) => Array.isArray(v) ? v.filter((x) => typeof x === "string" && x.trim()).map((x) => (x as string).trim().slice(0, len)).slice(0, n) : [];
  let archetype = typeof r.archetype === "string" ? r.archetype.trim().replace(/^[✦*•\s]+/, "").slice(0, 40) : "";
  if (!archetype) return null;
  if (!/^the\b/i.test(archetype)) archetype = `The ${archetype}`;
  const palette = strs(r.palette, 5, 7).filter((c) => /^#[0-9a-f]{6}$/i.test(c));
  return {
    archetype, signature: strs(r.signature, 2, 30), notes: strs(r.notes, 3, 24), hunts: strs(r.hunts, 3, 24),
    grail: typeof r.grail === "string" && r.grail.trim() ? r.grail.trim().slice(0, 60) : null,
    palette: palette.length >= 3 ? palette : ["#e9dcc3", "#9fb88a", "#6f5a43", "#f4f1ea", "#3b4a5c"],
  };
}

const HUNT_WORDS: Record<string, string> = { sneakers: "Sneakers", apparel: "Clothing", fragrance: "Fragrance", watches: "Watches",
  cars: "Cars", furniture: "Furniture", accessories: "Accessories", collectibles: "Collectibles" };
export function huntWords(v: unknown): string[] {
  return (Array.isArray(v) ? v : []).filter((x) => typeof x === "string" && x.trim())
    .map((x) => HUNT_WORDS[x as string] ?? (x as string).replace(/^./, (c) => c.toUpperCase()).slice(0, 24)).slice(0, 3);
}

export async function refreshTasteCards(limit: number) {
  const due = await db.rpc<string[] | { taste_cards_due: string }[]>("taste_cards_due", { p_limit: limit });
  const ids = (due as unknown[]).map((x) => typeof x === "string" ? x : (x as { taste_cards_due: string }).taste_cards_due).filter(Boolean);
  let written = 0;
  for (const id of ids) {
    const input = await db.rpc<Record<string, unknown>>("taste_card_inputs", { uid: id }).catch(() => null);
    if (!input) continue;
    const res = await claude({ model: SWEEP_MODEL(), max_tokens: 800, purpose: "taste card", messages: [{ role: "user", content:
`Write a collectible "Taste Card" for a shopper, from what they love (JSON):
${JSON.stringify(input)}

Reply with only JSON:
{"archetype": a catchy 2-4 word title starting with "The" that sums up their taste (e.g. "The Fresh Minimalist", "The Oud Collector", "The Quiet Luxury Sneakerhead"),
 "signature": their 1-2 signature brands, "notes": 3 short words for their style or scent (e.g. "vetiver", "earth tones", "suede"),
 "hunts": what they hunt in 1-3 short words, "grail": the one item they'd most want (a short product name from what they liked, or null),
 "palette": 5 hex colors that feel like their taste}
Use only what's in the data. Keep it flattering and specific.` }] }).catch(() => null);
    const card = res ? cleanCard(parseJSON(textOf(res.content))) : null;
    // What they hunt comes straight from their scouts, in plain words.
    if (card && !card.hunts.length) card.hunts = huntWords(input.hunts);
    // No card yet (nothing to go on): try again in 3 days rather than every 15 minutes.
    await db.update("profiles", `id=eq.${id}`, card ? { taste_card: card, taste_card_at: new Date().toISOString() } : { taste_card_at: new Date().toISOString() }).catch(() => {});
    if (card) written++;
  }
  return { due: ids.length, written };
}

/** Prices checked before samples and decants were filtered out (Oct 19, 2026): look them up again, newest first. */
const PRICE_FIX = "2026-10-19T13:30:00Z";
export async function repriceOld(limit: number) {
  const rows = await db.select<{ id: string; title: string; brand: string | null; price: number | null }>("listings",
    `select=id,title,brand,price&offers_checked_at=lt.${PRICE_FIX}&order=last_seen_at.desc&limit=${limit}`);
  const priced = await attachOffers(rows, (id, patch) => db.update("listings", `id=eq.${id}`, patch).then(() => {}));
  return { checked: rows.length, priced };
}

// ── Between hunts: no AI, and nothing is kept unless the store's own page confirms it ──

const pwords = (x: string) => norm(x).split(/[^a-z0-9]+/).filter((w) => w.length > 2);

/** The typical (median) price Baget has seen a brand sell for, from at least 5 listings; null when it doesn't know. */
const medians = new Map<string, number | null>();
async function brandMedian(brand: string): Promise<number | null> {
  if (medians.has(brand)) return medians.get(brand)!;
  const rows = await db.select<{ price: number }>("listings",
    `select=price&brand=ilike.${encodeURIComponent(brand)}&price=gt.0&order=last_seen_at.desc&limit=60`).catch(() => []);
  const ps = rows.map((r) => Number(r.price)).filter((x) => x > 0).sort((a, b) => a - b);
  const m = ps.length >= 5 ? ps[Math.floor(ps.length / 2)] : null;
  medians.set(brand, m);
  return m;
}

/** One scout's quick pulse: one web search from its brief, then each product page is opened and kept only when the
 *  store's own page confirms the product, a US-dollar price, that it's in stock, and a photo, and it fits the scout's
 *  brief as well as a hunt's finds must. Kept products feed For You; nothing is texted. */
export async function pulseAgent(a: Candidate, now = new Date(), fetchFn: typeof fetch = fetch) {
  const q = queriesFor(a, [], now, 1)[0] ?? missionLabel(a);
  if (!q) return { checked: 0, kept: 0 };
  const hits = (await serperSearch(q, fetchFn).catch(() => [])).filter((h) => !isSearchPage(h.link)).slice(0, 6);
  const pages = await Promise.all(hits.map((h) => pageProduct(h.link, fetchFn).catch(() => null)));
  const keep = [];
  for (let i = 0; i < hits.length; i++) {
    const p = pages[i];
    if (!p || p === "gone" || !p.name || !p.price || p.stock !== "in" || !p.image) continue;
    if (notAProduct(hits[i].link, await blockedDomains())) continue;
    // The page's product is the one the search result named.
    const named = pwords(p.name), result = new Set(pwords(hits[i].title));
    if (!named.length || named.filter((w) => result.has(w)).length / named.length < 0.6) continue;
    let host = "";
    try { host = new URL(hits[i].link).hostname.replace(/^www\./, ""); } catch { continue; }
    const l = {
      fingerprint: `${host}|${norm(p.name).replace(/[^a-z0-9]+/g, " ").trim()}`.slice(0, 300),
      title: p.name, brand: (p.brand ?? "").slice(0, 80), category: a.mission_category ?? "other", price: p.price, market: null,
      source: (p.site ?? host).slice(0, 80), url: hits[i].link.slice(0, 1000), image_url: p.image.slice(0, 500), drop_at: null,
      sold_out: false, creator: null, traits: [] as string[], tags: ["pulse"], sizes_in_stock: null, sku: "",
    };
    // No copies, samples or "inspired by" versions passed off as the real thing.
    if (/\b(inspired|dupe|clone|impression|alternative to|version of|decant|sample|tester|replica|knock ?off)\b/i.test(`${p.name} ${hits[i].title}`)) continue;
    // A known brand at a fraction of what Baget has seen it sell for, from a store that isn't the brand's own: skip it.
    const brandKey = norm(p.brand ?? "");
    if (brandKey && !host.includes(brandKey.replace(/[^a-z0-9]/g, ""))) {
      const typical = await brandMedian(brandKey);
      if (typical && p.price < typical * 0.35) continue;
    }
    // Same bar as a hunt's finds: it has to fit this scout's brief.
    const m = match(a, l as unknown as Listing, [], { dept: deptOf(a.settings) });
    if (!m || m.notInSize || m.score < 45) continue;
    keep.push(l);
  }
  if (keep.length) {
    const saved = await db.rpc<{ id: string }[]>("upsert_listings", { p_user: a.user_id, p_listings: keep });
    if (saved.length) {
      await db.raw("/rest/v1/listing_seen", { method: "POST", headers: { Prefer: "return=minimal,resolution=merge-duplicates" },
        body: JSON.stringify(saved.map((x) => ({ user_id: a.user_id, listing_id: x.id, seen_at: now.toISOString() }))) })
        .catch((e) => console.error("pulse seen", e));
    }
  }
  return { checked: hits.length, kept: keep.length };
}

export async function pulseAll(now = new Date()) {
  const due = await db.rpc<Candidate[]>("claim_pulses", { p_limit: num("PULSE_BATCH", 30),
    p_free_minutes: num("PULSE_FREE_MINUTES", 360), p_pro_minutes: num("PULSE_PRO_MINUTES", 180) });
  const runs = await Promise.all(due.map((a) => pulseAgent(a, now).catch((e) => { console.error("pulse", e); return { checked: 0, kept: 0 }; })));
  return { pulsed: due.length, checked: runs.reduce((t, r) => t + r.checked, 0), kept: runs.reduce((t, r) => t + r.kept, 0) };
}

/** Keeps open finds accurate: each one's store page at most once a day. Price changes are updated; a page that says
 *  sold out marks it sold out; a page the store has removed (404/410) takes the find off the list (liked ones stay,
 *  marked sold out). Coming back in stock is left to the restock watcher and the hunts, which text people. */
export async function refreshFinds(limit: number, now = new Date(), fetchFn: typeof fetch = fetch) {
  const rows = await db.select<{ listing: { id: string; url: string | null; price: number | null; sold_out: boolean; page_checked_at: string | null } | null }>("finds",
    "select=listing:listings!inner(id,url,price,sold_out,page_checked_at)&status=in.(open,liked)&listing.tags=not.ov.{intel,search}&order=created_at.desc&limit=400");
  const due = new Map<string, { id: string; url: string; price: number | null; sold_out: boolean }>();
  for (const r of rows) {
    const l = r.listing;
    if (!l?.url || due.has(l.id)) continue;
    if (l.page_checked_at && now.getTime() - Date.parse(l.page_checked_at) < 24 * 3600_000) continue;
    due.set(l.id, { id: l.id, url: l.url, price: l.price, sold_out: l.sold_out });
  }
  const list = [...due.values()].slice(0, limit);
  let updated = 0, gone = 0, soldOut = 0;
  for (let i = 0; i < list.length; i += 10) {
    await Promise.all(list.slice(i, i + 10).map(async (l) => {
      const p = await pageProduct(l.url, fetchFn).catch(() => null);
      const patch: Record<string, unknown> = { page_checked_at: now.toISOString() };
      if (p === "gone") {
        gone++;
        patch.sold_out = true;
        await db.update("finds", `listing_id=eq.${l.id}&status=eq.open`, { status: "removed" }).catch(() => {});
      } else if (p) {
        if (p.price && (!l.price || Math.abs(p.price - l.price) / l.price > 0.01)) { patch.price = p.price; updated++; }
        if (p.stock === "out" && !l.sold_out) { patch.sold_out = true; soldOut++; }
      }
      await db.update("listings", `id=eq.${l.id}`, patch).catch(() => {});
    }));
  }
  return { checked: list.length, repriced: updated, sold_out: soldOut, gone };
}

/** Already-stored product photos over 250 KB: written over with a phone-sized copy at the same address. Each photo is
 *  tried once (a photo that can't be made smaller is left as it is). */
export async function shrinkStored(limit: number) {
  const rows = await db.rpc<{ name: string; mimetype: string; size: number }[]>("large_photos", { p_limit: limit });
  let shrunk = 0, saved = 0;
  for (const r of rows) {
    try {
      const got = await fetch(`${env("SUPABASE_URL")}/storage/v1/object/public/product-photos/${r.name}`);
      if (got.ok) {
        const raw = new Uint8Array(await got.arrayBuffer());
        const out = await smaller(raw, r.mimetype);
        if (out.bytes.length < raw.length && out.type === r.mimetype) {
          const up = await db.raw(`/storage/v1/object/product-photos/${r.name}`, { method: "PUT", body: out.bytes,
            headers: { "Content-Type": r.mimetype, "x-upsert": "true", "cache-control": "max-age=31536000" } });
          if (up.ok) { shrunk++; saved += raw.length - out.bytes.length; }
          else await up.text();
        }
      } else await got.body?.cancel();
    } catch (e) { console.error("shrink stored", (e as Error).message); }
    await db.insert("photo_shrink_done", { name: r.name }, false).catch(() => {});
  }
  return { checked: rows.length, shrunk, saved_kb: Math.round(saved / 1024) };
}

/** Free plan, outside the hunting window: says when the scouts are back. Null when they're allowed to hunt. */
export async function restingMessage(userId: string, now = new Date()): Promise<string | null> {
  const [p] = await db.select<{ plan: string; pro_until: string | null; tz: string; settings: Record<string, unknown> | null }>(
    "profiles", `select=plan,pro_until,tz,settings&id=eq.${userId}`).catch(() => []);
  if (!p) return null;
  if (p.plan === "comp" || (p.plan === "pro" && p.pro_until && Date.parse(p.pro_until) > now.getTime())) return null;
  const raw = Number((p.settings ?? {}).huntStart);
  const start = Number.isInteger(raw) && raw >= 0 && raw <= 23 ? raw : 9;
  const h = localHour(p.tz || "America/New_York", now);
  if ((h - start + 24) % 24 < 4) return null;
  const label = (x: number) => `${x % 12 === 0 ? 12 : x % 12}${x < 12 ? "am" : "pm"}`;
  return `Your scouts are resting. On Free they hunt ${label(start)} to ${label((start + 4) % 24)}. Go Pro to hunt around the clock.`;
}

/** Free, inside the window, but today's hunt is done. */
export async function huntedTodayMessage(userId: string): Promise<string | null> {
  const [p] = await db.select<{ plan: string; pro_until: string | null }>("profiles", `select=plan,pro_until&id=eq.${userId}`).catch(() => []);
  if (!p || p.plan === "comp" || (p.plan === "pro" && p.pro_until && Date.parse(p.pro_until) > Date.now())) return null;
  return "Your scouts already hunted today. On Free each scout hunts once a day. Go Pro for deep hunts every 6 hours.";
}

export const handler = handle(async (req) => {
  const body = await req.json().catch(() => ({})) as { agent_id?: string; backfill?: number; backfill_about?: number; backfill_brands?: number; maintain?: boolean; pulse?: boolean; one?: unknown; shots?: unknown; trace_image?: boolean };
  if (isScheduler(req) && (body as { check_sources?: boolean }).check_sources) {
    // Diagnose: are the extra data sources working? Counts only.
    const [a] = await db.select<Agent>("agents", "select=*&mission_category=not.is.null&order=created_at.desc&limit=1");
    if (!a) return json({ none: true });
    const qs = queriesFor(a, [], new Date());
    const [ebayRows, leads] = await Promise.all([ebaySearch(a, qs), shoppingLeads(qs)]);
    // The image/shopping search service itself: status and its message (never the key).
    let serper: unknown = "no key";
    if (env("SERPER_API_KEY")) {
      const r = await fetch("https://google.serper.dev/images", { method: "POST", signal: AbortSignal.timeout(8000),
        headers: { "X-API-KEY": env("SERPER_API_KEY")!, "Content-Type": "application/json" }, body: JSON.stringify({ q: "air jordan 1", num: 3 }) })
        .catch((e) => ({ status: 0, text: async () => String(e) } as unknown as Response));
      const text = await r.text();
      serper = { status: r.status, images: (() => { try { return (JSON.parse(text).images ?? []).length; } catch { return null; } })(), message: r.status === 200 ? undefined : text.slice(0, 200) };
    }
    return json({ serper, agent: a.name, queries: qs, ebay: { configured: ebayConfigured(), listings: ebayRows.length, sample: ebayRows[0]?.title ?? null },
                  shopping: { configured: !!env("SERPER_API_KEY"), leads: leads.length, sample: leads[0]?.title ?? null } });
  }
  // Diagnose: one real hunt on Baget's house account, to prove the search setup works end to end and compare models.
  const test = (body as { test_hunt?: boolean | { model?: string; provider?: "serper" | "claude"; category?: string; pro?: boolean } }).test_hunt;
  if (isScheduler(req) && test) {
    const o = typeof test === "object" ? test : {};
    const house = "0a99e1e0-5eed-4d3e-8a00-00000000d3e0";
    const [agent] = await db.select<Agent>("agents", `select=*&user_id=eq.${house}&mission_category=eq.${encodeURIComponent(o.category ?? "sneakers")}&limit=1`);
    const [prof] = await db.select<{ tz: string; settings: Record<string, unknown>; display_name: string }>("profiles", `select=tz,settings,display_name&id=eq.${house}`);
    if (!agent || !prof) return json({ none: "no house scout for that category" });
    const t0 = Date.now();
    lastHunt.length = 0;
    const run = await sweepAgent({ ...agent, ...prof, last_swept_at: null, pro: o.pro !== false } as Candidate, "manual", new Date(),
                                 { model: o.model, provider: o.provider });
    return json({ agent: agent.name, model: o.model ?? SWEEP_MODEL(), seconds: Math.round((Date.now() - t0) / 1000), ...run, found_titles: [...lastHunt] });
  }
  const traceTitle = (body as { trace_title?: string }).trace_title;
  if (isScheduler(req) && traceTitle) {
    const [l] = await db.select<{ url: string; title: string; brand: string; category: string }>("listings",
      `select=url,title,brand,category&title=ilike.*${encodeURIComponent(traceTitle.replace(/[*,()]/g, " ").slice(0, 60))}*&url=not.is.null&order=last_seen_at.desc&limit=1`);
    return json(l ? await traceImage(l) : { none: true });
  }
  if (isScheduler(req) && body.trace_image) {
    const [l] = await db.select<{ url: string; title: string; brand: string; category: string }>("listings",
      "select=url,title,brand,category&url=not.is.null&url=like.*carhartt*&order=last_seen_at.desc&limit=1");
    const [any] = l ? [l] : await db.select<{ url: string; title: string; brand: string; category: string }>("listings",
      "select=url,title,brand,category&url=not.is.null&order=last_seen_at.desc&limit=1");
    return json(any ? await traceImage(any) : { none: true });
  }
  const demo = (body as { demo?: { email?: string; password_hash?: string } }).demo;
  if (isScheduler(req) && demo) {
    return json(await setupDemo(String(demo.email ?? ""), String(demo.password_hash ?? ""), async (userId) => {
      const cands = await db.rpc<Candidate[]>("sweep_candidates", { p_limit: 3, p_daily_cap: num("SWEEP_DAILY_CAP", 30), p_user: userId, p_agent: null });
      const runs = await Promise.all(cands.map((a) => sweepAgent(a, "manual")));
      return { swept: runs.length, found: runs.reduce((t, r) => t + r.finds, 0) };
    }));
  }
  if (isScheduler(req) && body.backfill) {
    return json(await backfillImages(Math.min(30, Math.max(1, Number(body.backfill)))));
  }
  // Upkeep, on its own schedule: photos, then descriptions, then brand blurbs.
  if (isScheduler(req) && body.maintain) return json(await maintain());
  if (isScheduler(req) && body.pulse) {
    const pulses = await pulseAll();
    // Shopify catalogs ride along with the pulse tick: a few stores each time, every store about every 3 hours.
    const feeds = await storeFeeds(num("FEED_BATCH", 6)).catch((e) => { console.error("feeds", e); return null; });
    return json({ ...pulses, feeds });
  }
  if (isScheduler(req) && typeof body.shots === "object" && body.shots) {
    return json(await setupShots(String((body.shots as { password_hash?: string }).password_hash ?? "")));
  }
  // One scheduled hunt in its own worker (handed out by the dispatcher below).
  if (isScheduler(req) && body.one && typeof body.one === "object") {
    const run = await sweepAgent(body.one as Candidate, "scheduled");
    return json({ swept: 1, found: run.finds, error: run.error });
  }
  if (isScheduler(req) && body.backfill_brands) {
    return json(await backfillBrands(Math.min(40, Math.max(1, Number(body.backfill_brands)))));
  }
  if (isScheduler(req) && body.backfill_about) {
    return json(await backfillAbout(Math.min(40, Math.max(1, Number(body.backfill_about)))));
  }
  const dailyCap = num("SWEEP_DAILY_CAP", 30);
  let candidates: Candidate[];
  let trigger: "scheduled" | "manual";
  if (isScheduler(req)) {
    trigger = "scheduled";
    // Dispatcher: claim the next scouts due and start each hunt in its own worker, so one slow hunt can't hold up or
    // crash the rest. Every 5 minutes × SWEEP_BATCH (20) = up to 5,760 hunts a day.
    // Release reminders people set are due on the minute they picked, so they're checked every tick.
    const reminders = await db.rpc<number>("send_release_reminders", {}).catch((e) => { console.error("reminders", e); return 0; });
    const due = await db.rpc<Candidate[]>("claim_sweeps", { p_limit: num("SWEEP_BATCH", 20), p_daily_cap: dailyCap });
    const results = await Promise.allSettled(due.map((a) => dispatchOne(a)));
    const failed = results.filter((r) => r.status === "rejected").length;
    if (failed) console.error("dispatch", `${failed} of ${due.length} hunts didn't start`);
    return json({ dispatched: due.length, failed, reminders });
  } else {
    const user = await requireUser(req);
    trigger = "manual";
    candidates = await db.rpc<Candidate[]>("sweep_candidates", { p_limit: 3, p_daily_cap: dailyCap, p_user: user.id, p_agent: body.agent_id ?? null });
    if (!candidates.length) {
      const resting = await restingMessage(user.id) ?? await huntedTodayMessage(user.id);
      return json({ swept: 0, found: 0, resting: !!resting, message: resting ?? "Your agents swept recently. They'll go again in a few minutes." });
    }
  }
  // A deep hunt can take a couple of minutes. Asked from the app, it keeps going on the server and the finds sync in.
  // deno-lint-ignore no-explicit-any
  const edge = (globalThis as any).EdgeRuntime;
  if (trigger === "manual" && edge?.waitUntil) {
    edge.waitUntil(Promise.all(candidates.map((a) => sweepAgent(a, trigger))).catch((e) => console.error("sweep", e)));
    return json({ swept: candidates.length, found: 0, background: true,
      message: `${candidates.length === 1 ? "Your scout is" : "Your scouts are"} digging deep. Finds land here in a few minutes.` });
  }
  const runs = await Promise.all(candidates.map((a) => sweepAgent(a, trigger)));
  const errors = runs.filter((r) => r.error);
  if (errors.length === runs.length && runs.length > 0 && trigger === "manual") {
    const msg = errors[0].error ?? "";
    throw new HttpError(503, msg.includes("API key") ? msg : "Your agents couldn't reach the web just now. Try again in a minute.");
  }
  return json({ swept: runs.length, found: runs.reduce((t, r) => t + r.finds, 0), searches: runs.reduce((t, r) => t + r.searches, 0) });
});

