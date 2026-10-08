// Sweeps: each agent searches the live web with Claude and turns what it finds into finds + friend-style notifications.
//  * Scheduled (every 15 minutes by pg_cron, with the shared secret): agents whose owner's interval has passed.
//  * Manual (the app, with the user's session): that user's agents, at most once per agent every 10 minutes.
// Cost guards: agents per run, searches per agent, and sweeps per user per day are all capped (see env below).
import { type Agent, CATEGORIES, GROUP_OF, type Listing, friendLine, heldForMorning, kindFor, match, missionLabel, norm } from "../_shared/match.ts";
import { type Block, type ClaudeMessage, HttpError, claude, db, env, handle, isScheduler, json, parseJSON, requireUser, textOf } from "../_shared/platform.ts";
import { addImages } from "../_shared/images.ts";

const num = (name: string, fallback: number) => {
  const v = Number(env(name));
  return Number.isFinite(v) && v > 0 ? v : fallback;
};

interface Candidate extends Agent { tz: string; settings: Record<string, unknown>; last_swept_at: string | null }

export function sweepPrompt(a: Agent, today: string): string {
  const parts = [
    `Mission: ${missionLabel(a)}`,
    a.keywords.length ? `Must-have keywords: ${a.keywords.join(", ")}` : "",
    a.traits.length ? `Styles and traits they love: ${a.traits.join(", ")}` : "",
    a.makers.length ? `Brands and makers they like: ${a.makers.join(", ")}` : "",
    a.creators.length ? `Creators they follow: ${a.creators.join(", ")}` : "",
    a.size ? `Their size: ${a.size}` : "",
    a.max_per_item > 0 ? `Max price per item: $${a.max_per_item}` : "",
    Object.entries(a.learned ?? {}).filter(([, w]) => w < 0).length
      ? `Not into: ${Object.entries(a.learned).filter(([, w]) => w < 0).map(([k]) => k).join(", ")}` : "",
  ].filter(Boolean).join("\n");
  return `Today is ${today}. You are ${a.name}, a personal shopping scout. Search the web for specific products that fit this person right now.

${parts}

Look for things that are available to buy now, releasing in the next two weeks, or restocking. Prefer official brand sites, authorized retailers, release calendars and reputable marketplaces. Use the person's taste to discover things beyond the exact names they gave.

Rules:
- Only include products you actually found on a page during this search, with that page's URL. Never invent a product, price, date or URL.
- The url must be the product's own page (one item), not a search, category, collection, editorial or home page.
- Price in US dollars as a number, or null if the page doesn't show one. "market" is the typical resale or secondhand price if you saw one, else null.
- drop_at is the release date and time in ISO 8601 if it's upcoming, else null.
- sizes_in_stock only if the page lists them, else null.
- traits are short lowercase descriptors of the product (materials, colors, notes, specs, era).
- At most 6 products. Fewer good ones beat more weak ones. If nothing fits, return an empty list.

End your reply with only this JSON in a \`\`\`json block:
{"listings":[{"title":"","brand":"","category":"${a.mission_category ?? "other"}","price":null,"market":null,"source":"store name","url":"https://...","image_url":null,"drop_at":null,"sold_out":false,"creator":null,"traits":[],"sizes_in_stock":null,"sku":""}]}`;
}

/** Cleans what Claude returned. Anything without a real web address is dropped. */
export function cleanListings(raw: unknown, fallbackCategory: string): (Listing & { fingerprint: string; url: string; sku: string; image_url: string | null })[] {
  const arr = (raw as { listings?: unknown[] })?.listings;
  if (!Array.isArray(arr)) return [];
  const out = [];
  for (const r of arr.slice(0, 8) as Record<string, unknown>[]) {
    const title = typeof r.title === "string" ? r.title.trim().slice(0, 200) : "";
    const url = typeof r.url === "string" ? r.url.trim() : "";
    let host = "";
    try { const u = new URL(url); if (u.protocol === "https:" || u.protocol === "http:") host = u.hostname.replace(/^www\./, ""); } catch { /* bad url */ }
    if (!title || !host) continue;
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
    });
  }
  return out;
}

export async function sweepAgent(a: Candidate, trigger: "scheduled" | "manual", now = new Date()) {
  const run = { user_id: a.user_id, agent_id: a.id, trigger, searches: 0, listings: 0, finds: 0, input_tokens: 0, output_tokens: 0, error: null as string | null };
  try {
    const messages: ClaudeMessage[] = [{ role: "user", content: sweepPrompt(a, now.toISOString().slice(0, 10)) }];
    const tools = [{ type: "web_search_20250305", name: "web_search", max_uses: num("SWEEP_MAX_SEARCHES", 4), user_location: { type: "approximate", country: "US" } }];
    let final: Block[] = [];
    for (let turn = 0; turn < 3; turn++) {
      const res = await claude({ max_tokens: 4000, messages, tools });
      run.input_tokens += res.usage?.input_tokens ?? 0;
      run.output_tokens += res.usage?.output_tokens ?? 0;
      run.searches += res.usage?.server_tool_use?.web_search_requests ?? 0;
      final = res.content;
      if (res.stop_reason !== "pause_turn") break;
      messages.push({ role: "assistant", content: res.content });   // continue a long search turn
    }
    const listings = cleanListings(parseJSON(textOf(final)), a.mission_category ?? "other");
    run.listings = listings.length;
    if (!listings.length) return run;
    await addImages(listings);   // the product photo from each store page

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
      if (!m || m.notInSize || m.score < 45) continue;
      const kind = kindFor(l, now.getTime());
      const wantNote = !groups || groups.includes(GROUP_OF[kind]);
      finds.push({
        listing_id: s.id, score: m.score, why: m.why,
        ...(wantNote ? { note: { kind, body: friendLine(a, kind, l, m.score, now.getTime()), held: heldForMorning(kind, l, a.tz, quiet, now) } } : {}),
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
  const items = rows.map((r) => ({ ...r, image_url: null as string | null }));
  await addImages(items);
  await Promise.all(items.map((r) =>
    db.update("listings", `id=eq.${r.id}`, { image_url: r.image_url, image_checked_at: new Date().toISOString() })));
  return rows.length;
}

export const handler = handle(async (req) => {
  const body = await req.json().catch(() => ({})) as { agent_id?: string };
  const dailyCap = num("SWEEP_DAILY_CAP", 12);
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
  if (trigger === "scheduled") await backfillImages(num("IMAGE_BACKFILL", 8)).catch((e) => console.error("images", e));
  const errors = runs.filter((r) => r.error);
  if (errors.length === runs.length && runs.length > 0 && trigger === "manual") {
    const msg = errors[0].error ?? "";
    throw new HttpError(503, msg.includes("API key") ? msg : "Your agents couldn't reach the web just now. Try again in a minute.");
  }
  return json({ swept: runs.length, found: runs.reduce((t, r) => t + r.finds, 0), searches: runs.reduce((t, r) => t + r.searches, 0) });
});

