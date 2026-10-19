// Sweeps: each agent searches the live web with Claude and turns what it finds into finds + friend-style notifications.
//  * Scheduled (every 15 minutes by pg_cron, with the shared secret): agents whose owner's interval has passed.
//  * Manual (the app, with the user's session): that user's agents, at most once per agent every 10 minutes.
// Cost guards: agents per run, searches per agent, and sweeps per user per day are all capped (see env below).
import { type Agent, CATEGORIES, GROUP_OF, type Listing, firstName, friendLine, localHour, heldForMorning, kindFor, match, missionLabel, norm } from "../_shared/match.ts";
import { type Block, type ClaudeMessage, HttpError, claude, db, env, handle, isScheduler, json, parseJSON, requireUser, textOf } from "../_shared/platform.ts";
import { addImages, linkIsDead, traceImage } from "../_shared/images.ts";
import { setupDemo, setupShots } from "./demo.ts";
import { SEARCH_TOOL, hitsText, serperSearch, serperUsable } from "../_shared/search.ts";
export { firstName };
import { type Lead, attachOffers, ebayConfigured, ebaySearch, queriesFor, shoppingLeads, shoppingOffers } from "../_shared/sources.ts";

const num = (name: string, fallback: number) => {
  const v = Number(env(name));
  return Number.isFinite(v) && v > 0 ? v : fallback;
};

interface Candidate extends Agent { tz: string; settings: Record<string, unknown>; last_swept_at: string | null; display_name?: string; pro?: boolean }

/** How hard a hunt digs. Pro: deep (more searches, opens product pages, more angles and places). Free: standard. */
export function depthFor(pro: boolean) {
  return pro
    ? { searches: num("SWEEP_MAX_SEARCHES", 12), fetches: num("SWEEP_MAX_FETCHES", 6), angles: 3, sources: 6, minSearches: 8, kinds: 4, deep: true }
    : { searches: num("FREE_MAX_SEARCHES", 6), fetches: 0, angles: 2, sources: 3, minSearches: 4, kinds: 3, deep: false };
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

export function sweepPrompt(a: Agent, today: string, r: Reactions = { liked: [], bought: [], passed: [] }, angles: string[] = [ANGLES[0], ANGLES[4]], leads: Lead[] = [], name = "", sources: string[] = [], depth = depthFor(true)): string {
  const leaning = Object.entries(a.learned ?? {}).filter(([, w]) => w >= 2).sort((x, y) => y[1] - x[1]).map(([k]) => k).slice(0, 10);
  const parts = [
    `Mission: ${missionLabel(a)}`,
    a.keywords.length ? `Must-have keywords: ${a.keywords.join(", ")}` : "",
    a.traits.length ? `Styles and traits they love: ${a.traits.join(", ")}` : "",
    a.makers.length ? `Brands and makers they like: ${a.makers.join(", ")}` : "",
    a.creators.length ? `Creators they follow: ${a.creators.join(", ")}` : "",
    a.size ? `Their size: ${a.size}` : "",
    a.price_note > 0 ? `Budget: they usually spend up to $${Math.round(a.price_note)} on one item. Mostly stay under it; a standout deal slightly over is fine.` : "",
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
- Look past page one and past the obvious big stores: the best finds are often on a small boutique, a forum post, an auction or a marketplace listing.${depth.deep ? `
- Open the most promising product pages with web_fetch to confirm the price, that it's in stock (and in their size), before you include it.` : ""}
- Things available now, releasing in the next two weeks, or restocking.
- Take initiative: include at least two discovery picks the person never named (a maker, model, note, collab or era that fits their taste), and mark them "discovery": true.${r.liked.length || r.bought.length ? `
- Their likes and buys are the strongest signal: find more in that spirit (same makers, materials, notes, silhouettes, eras), but not the same items again.` : ""}${r.passed.length ? `
- Steer away from what they passed on as not their style.` : ""}${r.seen?.length ? `
- Already shown to them (find different things): ${r.seen.slice(0, 30).join("; ")}` : ""}
- For each product, write "pitch": one short sentence, in your own voice, on why it's for them, in plain words tied to what
  they told you they like (a vibe, a style, a brand, something they liked). Write for someone who may not know the brand.
- For each product, write "about": 1-2 plain sentences (max 260 characters) about this product: what it actually is${a.mission_category === "fragrance" ? `. For fragrance, say what it smells like in everyday words (e.g. "fresh and clean, like
  soap and citrus" or "warm and sweet, like vanilla and wood"), its main notes, and when it's worn (daytime, night out, summer)` : ", what makes it special, and who or what it's for"}.
  No hype words, no jargon. Only facts from the page or well known facts about this exact product; if you're not sure, say less.
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
- Up to 8 products. Aim for 5 or more strong ones; never pad with weak ones.

End your reply with only this JSON in a \`\`\`json block:
{"listings":[{"title":"","brand":"","category":"${a.mission_category ?? "other"}","price":null,"market":null,"source":"store name","url":"https://...","image_url":null,"drop_at":null,"sold_out":false,"creator":null,"traits":[],"sizes_in_stock":null,"sku":"","discovery":false,"about":"","pitch":"","text":""}]}`;
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

export function cleanListings(raw: unknown, fallbackCategory: string): (Listing & { fingerprint: string; url: string; sku: string; image_url: string | null; discovery: boolean; about: string | null; pitch: string; text: string })[] {
  const arr = (raw as { listings?: unknown[] })?.listings;
  if (!Array.isArray(arr)) return [];
  const out = [];
  for (const r of arr.slice(0, 12) as Record<string, unknown>[]) {
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
      tags: [],
      sizes_in_stock: sizes && sizes.length ? sizes : null,
      sku: typeof r.sku === "string" ? r.sku.trim().slice(0, 60) : "",
      discovery: r.discovery === true,
      about: typeof r.about === "string" && r.about.trim() ? r.about.trim().replace(/\s+/g, " ").slice(0, 400) : null,
      pitch: typeof r.pitch === "string" ? r.pitch.trim().slice(0, 160) : "",
      text: cleanText(r.text),
    });
  }
  return out;
}

/** The last hunt's listings (for the Diagnose model comparison). */
const lastHunt: string[] = [];

/** The model for hunts: SWEEP_MODEL if set, else Haiku. In side-by-side tests (Oct 18) Haiku found as many real,
 *  in-stock products as Sonnet at about a fifth of the cost. Chat and setup keep the app-wide model. */
export const SWEEP_MODEL = () => env("SWEEP_MODEL") ?? "claude-haiku-5-5";

export async function sweepAgent(a: Candidate, trigger: "scheduled" | "manual", now = new Date(),
                                 opts: { model?: string; provider?: "serper" | "claude" } = {}) {
  const run = { user_id: a.user_id, agent_id: a.id, trigger, searches: 0, listings: 0, finds: 0, input_tokens: 0, output_tokens: 0, cache_write_tokens: 0, cache_read_tokens: 0, fetches: 0, error: null as string | null };
  try {
    const reactions = await reactionsFor(a.id).catch(() => undefined);
    // Extra sources (each only when its key is set): Google Shopping leads for Claude, and real eBay listings.
    const queries = queriesFor(a, reactions?.liked ?? [], now);
    const [leads, ebayRaw] = await Promise.all([
      shoppingLeads(queries).catch(() => [] as Lead[]),
      ebaySearch(a, queries).catch(() => [] as Record<string, unknown>[]),
    ]);
    const depth = depthFor(a.pro !== false);
    const messages: ClaudeMessage[] = [{ role: "user", content: sweepPrompt(a, now.toISOString().slice(0, 10), reactions, anglesFor(a.id, now).slice(0, depth.angles), leads,
      firstName(a.display_name), sourcesFor(a.mission_category, a.id, now, depth.sources), depth) }];
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
    let listings = cleanListings(parseJSON(textOf(final)), a.mission_category ?? "other");
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
    if (!listings.length) return run;

    const saved = await db.rpc<{ fingerprint: string; id: string; already_found: boolean }[]>("upsert_listings", { p_user: a.user_id, p_listings: listings });
    // Remember which products this person's scouts came across: their For You is built only from these.
    if (saved.length) {
      await db.raw("/rest/v1/listing_seen", { method: "POST", headers: { Prefer: "return=minimal,resolution=merge-duplicates" },
        body: JSON.stringify(saved.map((x) => ({ user_id: a.user_id, listing_id: x.id, seen_at: new Date().toISOString() }))) })
        .catch((e) => console.error("listing_seen", e));
    }
    const ids = new Map(saved.map((s) => [s.fingerprint, s]));
    // Other stores' prices for new listings, for the deal verdict.
    await attachOffers(saved.filter((s) => !s.already_found).map((s) => ({ id: s.id, title: listings.find((l) => l.fingerprint === s.fingerprint)?.title ?? "" }))
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
      const m = match(a, l, photoTags);
      // Discovery picks are the agent's own initiative, so they don't need to hit the stated keywords as hard.
      if (!m || m.notInSize || m.score < (l.discovery ? 35 : 45)) continue;
      const kind = kindFor(l, now.getTime());
      // No photo, no text: a find only buzzes your phone once Baget has its real photo.
      const wantNote = (!groups || groups.includes(GROUP_OF[kind])) && !!l.image_url;
      const why = [...(l.pitch ? [l.pitch] : []), ...(l.discovery ? ["Discovery: something new it found for you"] : []), ...m.why].slice(0, 6);
      // The agent's own personal text first; the templates are the fallback.
      const body = l.text ? l.text : l.discovery && l.pitch
        ? `Found something you didn't ask for but I think you'll love: ${l.title}${l.price ? ` ($${Math.round(l.price)})` : ""} at ${l.source}. ${l.pitch}`
        : friendLine(a, kind, l, m.score, now.getTime());
      finds.push({
        listing_id: s.id, score: Math.max(m.score, l.discovery ? 60 : 0), why,
        ...(wantNote ? { note: { kind, body: body.slice(0, 480), held: heldForMorning(kind, l, a.tz, quiet, now) } } : {}),
      });
    }
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
export async function backfillAbout(limit: number) {
  const rows = await db.select<{ id: string; title: string; brand: string; category: string; traits: string[]; source: string }>("listings",
    `select=id,title,brand,category,traits,source&about=is.null&about_checked_at=is.null` +
    `&last_seen_at=gt.${new Date(Date.now() - 60 * 86400_000).toISOString()}&order=last_seen_at.desc&limit=${limit}`);
  let written = 0, checked = 0;
  // Small batches: a long list can run past the reply limit, and a cut-off reply can't be read at all.
  for (let i = 0; i < rows.length; i += 8) {
    const batch = rows.slice(i, i + 8);
    const list = batch.map((r, j) => `[p${j + 1}] ${r.title}${r.brand ? ` | brand: ${r.brand}` : ""} | ${r.category}${r.traits?.length ? ` | ${r.traits.join(", ")}` : ""} | sold at ${r.source}`).join("\n");
    const res = await claude({ model: SWEEP_MODEL(), max_tokens: 4000, purpose: "about", messages: [{ role: "user", content:
`Write a plain-language description for each product below, for a shopper seeing it for the first time.
1-2 sentences, max 260 characters, everyday words, no hype or jargon: what it is, and what makes it special or who it's for.
For a fragrance: what it smells like in everyday words (e.g. "fresh and clean, like soap and citrus"), main notes, and when it's worn.
Only say what you're confident is true of this exact product. If you don't know a fragrance's notes, don't guess them: describe only
what the name and details show. If you can't say anything useful, use null.

${list}

Reply with only JSON, one entry per product, copying its id and its title:
{"items":[{"id":"p1","title":"<title>","about":"..." or null}, ...]}` }] });
    const parsed = parseJSON(textOf(res.content)) as { items?: Record<string, unknown>[] } | null;
    const items = Array.isArray(parsed?.items) ? parsed!.items : [];
    const out = keyed(parsed, "about", batch.map((r, j) => ({ id: `p${j + 1}`, name: r.title })));
    console.log("about backfill", JSON.stringify({ asked: batch.length, items: items.length, kept: out.filter(Boolean).length, stop: res.stop_reason }));
    if (!items.length) continue;   // unreadable reply: leave these for the next run rather than marking them done
    checked += batch.length;
    await Promise.all(batch.map((r, j) => {
      const a = out[j] && out[j]!.length > 15 ? out[j]!.slice(0, 400) : null;
      if (a) written++;
      return db.update("listings", `id=eq.${r.id}`, { about: a, about_checked_at: new Date().toISOString() });
    }));
  }
  return { checked, written };
}

/** A short blurb about each brand on recent listings, written once per brand and copied onto its listings.
 *  Only well-known facts; a brand the model doesn't know gets no blurb (saved as null so it isn't retried every run). */
export async function backfillBrands(limit: number) {
  const names = (await db.rpc<{ name: string }[]>("brands_needing_blurbs", { p_limit: limit })).map((r) => r.name).filter(Boolean);
  let written = 0;
  if (names.length) {
    const res = await claude({ max_tokens: 3000, purpose: "brands",   // the app-wide model: written once per brand, so accuracy wins
      messages: [{ role: "user", content:
`For each brand below, write a short blurb for a shopper who may be new to it: who they are, where they're from, what they're
known for and their price range (e.g. "A New York perfume house known for small-batch, unisex scents made fresh to order.
Pricey, around $200+ a bottle."). 1-2 sentences, max 220 characters, everyday words, no hype.
Only what you're confident is true. If you don't know a brand (or it's a store, not a brand), use null.

${names.map((n, i) => `[b${i + 1}] ${n}`).join("\n")}

Reply with only JSON, one entry per brand, copying its id and exact name:
{"items":[{"id":"b1","name":"<exact brand name>","blurb":"..." or null}, ...]}` }] });
    const out = keyed(parseJSON(textOf(res.content)), "blurb", names.map((n, i) => ({ id: `b${i + 1}`, name: n })));
    const rows = names.map((n, i) => {
      const b = out[i] && out[i]!.length > 20 ? out[i]!.slice(0, 400) : null;
      if (b) written++;
      return { key: n.trim().toLowerCase(), name: n.trim(), blurb: b };
    });
    await db.raw("/rest/v1/brand_blurbs", { method: "POST", headers: { Prefer: "return=minimal,resolution=ignore-duplicates" }, body: JSON.stringify(rows) });
  }
  const applied = await db.rpc<number>("apply_brand_blurbs", {});
  return { brands: names.length, written, applied };
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
  out.about = await backfillAbout(num("ABOUT_BACKFILL", 20)).catch((e) => { console.error("about", e); return null; });
  out.brands = await backfillBrands(num("BRAND_BACKFILL", 15)).catch((e) => { console.error("brands", e); return null; });
  out.prices = await repriceOld(num("PRICE_BACKFILL", 10)).catch((e) => { console.error("prices", e); return null; });
  return out;
}

/** Prices checked before samples and decants were filtered out (Oct 19, 2026): look them up again, newest first. */
const PRICE_FIX = "2026-10-19T13:30:00Z";
export async function repriceOld(limit: number) {
  const rows = await db.select<{ id: string; title: string }>("listings",
    `select=id,title&offers_checked_at=lt.${PRICE_FIX}&order=last_seen_at.desc&limit=${limit}`);
  const priced = await attachOffers(rows, (id, patch) => db.update("listings", `id=eq.${id}`, patch).then(() => {}));
  return { checked: rows.length, priced };
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
  const body = await req.json().catch(() => ({})) as { agent_id?: string; backfill?: number; backfill_about?: number; backfill_brands?: number; maintain?: boolean; one?: unknown; shots?: unknown; trace_image?: boolean };
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
    const due = await db.rpc<Candidate[]>("claim_sweeps", { p_limit: num("SWEEP_BATCH", 20), p_daily_cap: dailyCap });
    const results = await Promise.allSettled(due.map((a) => dispatchOne(a)));
    const failed = results.filter((r) => r.status === "rejected").length;
    if (failed) console.error("dispatch", `${failed} of ${due.length} hunts didn't start`);
    return json({ dispatched: due.length, failed });
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

