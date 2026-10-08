// Sweeps: each agent searches the live web with Claude and turns what it finds into finds + friend-style notifications.
//  * Scheduled (every 15 minutes by pg_cron, with the shared secret): agents whose owner's interval has passed.
//  * Manual (the app, with the user's session): that user's agents, at most once per agent every 10 minutes.
// Cost guards: agents per run, searches per agent, and sweeps per user per day are all capped (see env below).
import { type Agent, CATEGORIES, GROUP_OF, type Listing, friendLine, heldForMorning, kindFor, match, missionLabel, norm } from "../_shared/match.ts";
import { type Block, type ClaudeMessage, HttpError, claude, db, env, handle, isScheduler, json, parseJSON, requireUser, textOf } from "../_shared/platform.ts";
import { addImages, linkIsDead, traceImage } from "../_shared/images.ts";

const num = (name: string, fallback: number) => {
  const v = Number(env(name));
  return Number.isFinite(v) && v > 0 ? v : fallback;
};

interface Candidate extends Agent { tz: string; settings: Record<string, unknown>; last_swept_at: string | null }

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
  return [ANGLES[first], ANGLES[(first + 3) % ANGLES.length]];
}

export function sweepPrompt(a: Agent, today: string, r: Reactions = { liked: [], bought: [], passed: [] }, angles: string[] = [ANGLES[0], ANGLES[4]]): string {
  const leaning = Object.entries(a.learned ?? {}).filter(([, w]) => w >= 2).sort((x, y) => y[1] - x[1]).map(([k]) => k).slice(0, 10);
  const parts = [
    `Mission: ${missionLabel(a)}`,
    a.keywords.length ? `Must-have keywords: ${a.keywords.join(", ")}` : "",
    a.traits.length ? `Styles and traits they love: ${a.traits.join(", ")}` : "",
    a.makers.length ? `Brands and makers they like: ${a.makers.join(", ")}` : "",
    a.creators.length ? `Creators they follow: ${a.creators.join(", ")}` : "",
    a.size ? `Their size: ${a.size}` : "",
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
1. ${angles[0]}
2. ${angles[1]}
Then use any searches left on whatever looks most promising.

How to hunt:
- Use several different searches, not one. Vary the wording, check brand sites, retailers, release calendars and marketplaces.
- Things available now, releasing in the next two weeks, or restocking.
- Take initiative: include at least two discovery picks the person never named (a maker, model, note, collab or era that fits their taste), and mark them "discovery": true.${r.liked.length || r.bought.length ? `
- Their likes and buys are the strongest signal: find more in that spirit (same makers, materials, notes, silhouettes, eras), but not the same items again.` : ""}${r.passed.length ? `
- Steer away from what they passed on as not their style.` : ""}${r.seen?.length ? `
- Already shown to them (find different things): ${r.seen.slice(0, 30).join("; ")}` : ""}
- For each product, write "pitch": one short sentence, in your own voice, on why it's for them.

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
{"listings":[{"title":"","brand":"","category":"${a.mission_category ?? "other"}","price":null,"market":null,"source":"store name","url":"https://...","image_url":null,"drop_at":null,"sold_out":false,"creator":null,"traits":[],"sizes_in_stock":null,"sku":"","discovery":false,"pitch":""}]}`;
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

export function cleanListings(raw: unknown, fallbackCategory: string): (Listing & { fingerprint: string; url: string; sku: string; image_url: string | null; discovery: boolean; pitch: string })[] {
  const arr = (raw as { listings?: unknown[] })?.listings;
  if (!Array.isArray(arr)) return [];
  const out = [];
  for (const r of arr.slice(0, 10) as Record<string, unknown>[]) {
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
      pitch: typeof r.pitch === "string" ? r.pitch.trim().slice(0, 160) : "",
    });
  }
  return out;
}

export async function sweepAgent(a: Candidate, trigger: "scheduled" | "manual", now = new Date()) {
  const run = { user_id: a.user_id, agent_id: a.id, trigger, searches: 0, listings: 0, finds: 0, input_tokens: 0, output_tokens: 0, error: null as string | null };
  try {
    const reactions = await reactionsFor(a.id).catch(() => undefined);
    const messages: ClaudeMessage[] = [{ role: "user", content: sweepPrompt(a, now.toISOString().slice(0, 10), reactions, anglesFor(a.id, now)) }];
    const tools = [{ type: "web_search_20250305", name: "web_search", max_uses: num("SWEEP_MAX_SEARCHES", 6), user_location: { type: "approximate", country: "US" } }];
    let final: Block[] = [];
    for (let turn = 0; turn < 3; turn++) {
      const res = await claude({ max_tokens: 6000, messages, tools });
      run.input_tokens += res.usage?.input_tokens ?? 0;
      run.output_tokens += res.usage?.output_tokens ?? 0;
      run.searches += res.usage?.server_tool_use?.web_search_requests ?? 0;
      final = res.content;
      if (res.stop_reason !== "pause_turn") break;
      messages.push({ role: "assistant", content: res.content });   // continue a long search turn
    }
    let listings = cleanListings(parseJSON(textOf(final)), a.mission_category ?? "other");
    run.listings = listings.length;
    if (!listings.length) return run;
    // Made-up links (404) go; then each real one gets a verified product photo.
    const dead = await Promise.all(listings.map((l) => linkIsDead(l.url)));
    listings = listings.filter((_, i) => !dead[i]);
    run.listings = listings.length;
    if (!listings.length) return run;
    await addImages(listings);

    const saved = await db.rpc<{ fingerprint: string; id: string; already_found: boolean }[]>("upsert_listings", { p_user: a.user_id, p_listings: listings });
    const ids = new Map(saved.map((s) => [s.fingerprint, s]));
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
      const wantNote = !groups || groups.includes(GROUP_OF[kind]);
      const why = [...(l.pitch ? [l.pitch] : []), ...(l.discovery ? ["Discovery: something new it found for you"] : []), ...m.why].slice(0, 6);
      const body = l.discovery && l.pitch
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
    `select=id,url,title,brand,category&image_url=is.null&url=not.is.null&image_checked_at=is.null&order=last_seen_at.desc&limit=${limit}`);
  let found = 0;
  for (let i = 0; i < rows.length; i += 6) {
    const items = rows.slice(i, i + 6).map((r) => ({ ...r, fingerprint: r.id, image_url: null as string | null }));
    found += await addImages(items);
    await Promise.all(items.map((r) =>
      db.update("listings", `id=eq.${r.id}`, { image_url: r.image_url, image_checked_at: new Date().toISOString() })));
  }
  return { checked: rows.length, found };
}

export const handler = handle(async (req) => {
  const body = await req.json().catch(() => ({})) as { agent_id?: string; backfill?: number; trace_image?: boolean };
  if (isScheduler(req) && body.trace_image) {
    const [l] = await db.select<{ url: string; title: string; brand: string; category: string }>("listings",
      "select=url,title,brand,category&url=not.is.null&url=like.*carhartt*&order=last_seen_at.desc&limit=1");
    const [any] = l ? [l] : await db.select<{ url: string; title: string; brand: string; category: string }>("listings",
      "select=url,title,brand,category&url=not.is.null&order=last_seen_at.desc&limit=1");
    return json(any ? await traceImage(any) : { none: true });
  }
  if (isScheduler(req) && body.backfill) {
    return json(await backfillImages(Math.min(30, Math.max(1, Number(body.backfill)))));
  }
  const dailyCap = num("SWEEP_DAILY_CAP", 30);
  let candidates: Candidate[];
  let trigger: "scheduled" | "manual";
  if (isScheduler(req)) {
    trigger = "scheduled";
    candidates = await db.rpc<Candidate[]>("sweep_candidates", { p_limit: num("SWEEP_BATCH", 3), p_daily_cap: dailyCap, p_user: null, p_agent: null });
  } else {
    const user = await requireUser(req);
    trigger = "manual";
    candidates = await db.rpc<Candidate[]>("sweep_candidates", { p_limit: 3, p_daily_cap: dailyCap, p_user: user.id, p_agent: body.agent_id ?? null });
    if (!candidates.length) {
      return json({ swept: 0, found: 0, message: "Your agents swept recently. They'll go again in a few minutes." });
    }
  }
  const runs = await Promise.all(candidates.map((a) => sweepAgent(a, trigger)));
  if (trigger === "scheduled") await backfillImages(num("IMAGE_BACKFILL", 12)).catch((e) => console.error("images", e));
  const errors = runs.filter((r) => r.error);
  if (errors.length === runs.length && runs.length > 0 && trigger === "manual") {
    const msg = errors[0].error ?? "";
    throw new HttpError(503, msg.includes("API key") ? msg : "Your agents couldn't reach the web just now. Try again in a minute.");
  }
  return json({ swept: runs.length, found: runs.reduce((t, r) => t + r.finds, 0), searches: runs.reduce((t, r) => t + r.searches, 0) });
});

