// Talk to an agent. Claude plays the agent, can search the live web, and acts through tools that run here
// on the server against the user's own data. It never buys anything: the most it does is line up checkout.
import { type Agent, intel, match, missionLabel, norm, words } from "../_shared/match.ts";
import { type Block, type ClaudeMessage, HttpError, claude, db, enc, handle, json, requireUser, textOf } from "../_shared/platform.ts";
import { cleanListings } from "../sweep/handler.ts";

interface Turn { role: "user" | "assistant"; content: string }
type Action = { type: "profile_updated" } | { type: "find"; find_id: string; title: string } | { type: "checkout"; find_id: string; title: string };

const TOOLS = [
  { type: "web_search_20250305", name: "web_search", max_uses: 3, user_location: { type: "approximate", country: "US" } },
  {
    name: "search_saved_listings",
    description: "Search listings your squad already found (fast, free). Returns up to 6 with id, title, brand, price, market, source, url, availability, traits and fit score for this person.",
    input_schema: { type: "object", properties: { query: { type: "string" }, max_price: { type: "number" } } },
  },
  {
    name: "update_profile",
    description: "Record what you learned about the person's taste, size or budget. Every field optional. Returns the updated profile.",
    input_schema: {
      type: "object",
      properties: {
        add_traits: { type: "array", items: { type: "string" } }, remove_traits: { type: "array", items: { type: "string" } },
        add_makers: { type: "array", items: { type: "string" } }, remove_makers: { type: "array", items: { type: "string" } },
        add_creators: { type: "array", items: { type: "string" } }, add_keywords: { type: "array", items: { type: "string" } },
        dislikes: { type: "array", items: { type: "string" } }, size: { type: "string" },
        max_per_item: { type: "number" }, monthly_limit: { type: "number" },
      },
    },
  },
  {
    name: "flag_find",
    description: "Put a product in the person's Finds feed with a one-sentence reason in your voice. Pass listing_id for a saved listing, or the product's details (title, url, price, source, brand, traits) for something you just found on the web. Returns the find id.",
    input_schema: {
      type: "object",
      properties: {
        listing_id: { type: "string" }, reason: { type: "string" },
        title: { type: "string" }, url: { type: "string" }, price: { type: "number" }, source: { type: "string" },
        brand: { type: "string" }, traits: { type: "array", items: { type: "string" } }, drop_at: { type: "string" },
      },
      required: ["reason"],
    },
  },
  {
    name: "propose_purchase",
    description: "Line up checkout for a find so the person can review it and buy it themselves at the store. Buys nothing. Returns what checkout will show.",
    input_schema: { type: "object", properties: { find_id: { type: "string" } }, required: ["find_id"] },
  },
];

function rules(a: Agent, profile: unknown): string {
  return `You are ${a.name}, a personal shopping agent in the Baget app. Act as the user's best friend who knows ${missionLabel(a)} inside out: warm, candid, specific. Your job is to learn exactly what they like and help them get it.

What you know about them (JSON):
${JSON.stringify(profile)}

How to work:
- When they reveal a taste, dislike, brand, creator, size or budget, call update_profile, then say in a few words what you picked up.
- To find things: try search_saved_listings first; use web_search for anything current it doesn't have. Only mention products, prices and dates you actually saw. Never invent them.
- When something is a strong fit, call flag_find so it lands in their Finds.
- When they want to buy, call propose_purchase. That only lines up checkout; they finish the purchase themselves at the store. Never say you bought something.
${a.mission_category === "sneakers" || a.mission_category === "apparel" ? (a.size ? `- Their size is ${a.size}. Only recommend items in stock in that size when the page shows sizes.\n` : `- You don't know their size yet. Ask for it first and record it with update_profile.\n`) : ""}- Be the honest friend: say when something is over their cap, above market, or too close to something they already have. Never pressure them to spend.
- Keep replies to 2 to 4 sentences of plain text. No markdown, no lists.`;
}

export const handler = handle(async (req) => {
  const user = await requireUser(req);
  const body = await req.json().catch(() => ({})) as { agent_id?: string; messages?: Turn[] };
  if (!body.agent_id || !Array.isArray(body.messages) || body.messages.length === 0) throw new HttpError(400, "agent_id and messages are required");
  const turns = body.messages
    .filter((m) => (m.role === "user" || m.role === "assistant") && typeof m.content === "string" && m.content.trim())
    .slice(-14)
    .map((m) => ({ role: m.role, content: m.content.slice(0, 2000) }));
  while (turns.length && turns[0].role !== "user") turns.shift();
  if (!turns.length || turns[turns.length - 1].role !== "user") throw new HttpError(400, "The last message must be yours");

  const [agent] = await db.select<Agent>("agents", `select=*&id=eq.${enc(body.agent_id)}&user_id=eq.${user.id}`);
  if (!agent) throw new HttpError(404, "That agent isn't in your squad");
  let a: Agent = agent;

  const recent = await db.select<{ status: string; pass_reason: string | null; listing: { title: string } }>(
    "finds", `select=status,pass_reason,listing:listings(title)&user_id=eq.${user.id}&agent_id=eq.${a.id}&order=created_at.desc&limit=12`);
  const photos = await db.select<{ summary: string; tags: string[] }>("taste_photos", `select=summary,tags&agent_id=eq.${a.id}&limit=6`);
  const profile = () => ({
    name: a.name, mission: missionLabel(a), keywords: a.keywords, traits_they_love: a.traits, makers_they_like: a.makers,
    creators_they_follow: a.creators, size: a.size || null, max_per_item: a.max_per_item || null, monthly_limit: a.monthly_limit,
    learned_from_actions: a.learned, prefers_under: a.price_note || null, taste_photos: photos,
    bought: recent.filter((f) => f.status === "acquired").map((f) => f.listing?.title),
    passed_on: recent.filter((f) => f.status === "passed").map((f) => ({ item: f.listing?.title, reason: f.pass_reason ?? "" })),
    profile_completeness_pct: intel(a),
  });

  const actions: Action[] = [];
  const strs = (v: unknown) => Array.isArray(v) ? v.filter((x) => typeof x === "string").map((x) => (x as string).trim()).filter(Boolean).slice(0, 10) : [];

  async function ensureFind(listingId: string, reason: string): Promise<{ id: string; title: string }> {
    const [l] = await db.select<{ id: string; title: string }>("listings", `select=id,title&id=eq.${enc(listingId)}`);
    if (!l) throw new Error("No listing with that id");
    const existing = await db.select<{ id: string }>("finds", `select=id&user_id=eq.${user.id}&listing_id=eq.${l.id}`);
    if (existing[0]) return { id: existing[0].id, title: l.title };
    const [f] = await db.insert<{ id: string }>("finds", { user_id: user.id, agent_id: a.id, listing_id: l.id, score: 80, why: [reason.slice(0, 160)] });
    return { id: f.id, title: l.title };
  }

  async function run(name: string, input: Record<string, unknown>): Promise<unknown> {
    if (name === "search_saved_listings") {
      const q = words(String(input.query ?? ""));
      const max = Number(input.max_price) || 0;
      const filter = a.mission_category ? `&category=eq.${a.mission_category}` : "";
      const rows = await db.select<Record<string, unknown>>("listings", `select=*&order=last_seen_at.desc&limit=200${filter}`);
      return rows
        .map((r) => ({ r, m: match(a, { ...(r as never), traits: (r.traits as string[]) ?? [], tags: (r.tags as string[]) ?? [] }) }))
        .filter(({ r, m }) => m && !m.notInSize && (!max || ((r.price as number) ?? 0) <= max) &&
          (!q.length || q.some((w) => norm(`${r.title} ${r.brand} ${(r.traits as string[]).join(" ")}`).includes(w))))
        .sort((x, y) => (y.m?.score ?? 0) - (x.m?.score ?? 0))
        .slice(0, 6)
        .map(({ r, m }) => ({ id: r.id, title: r.title, brand: r.brand, price: r.price, market: r.market, source: r.source, url: r.url,
          available: r.sold_out ? "sold out" : r.drop_at && Date.parse(r.drop_at as string) > Date.now() ? `drops ${r.drop_at}` : "now",
          traits: r.traits, fit_score: m?.score, fit_reasons: m?.why }));
    }
    if (name === "update_profile") {
      const add = (list: string[], vals: string[], low = false) => {
        for (let v of vals) { if (low) v = v.toLowerCase(); if (!list.some((x) => norm(x) === norm(v))) list.push(v); }
        return list;
      };
      const drop = (list: string[], vals: string[]) => list.filter((x) => !vals.some((v) => norm(v) === norm(x)));
      const learned = { ...a.learned };
      for (const d of strs(input.dislikes)) learned[norm(d)] = -2;
      const patch: Record<string, unknown> = {
        traits: drop(add([...a.traits], strs(input.add_traits), true), [...strs(input.remove_traits), ...strs(input.dislikes)]).slice(0, 40),
        makers: drop(add([...a.makers], strs(input.add_makers)), [...strs(input.remove_makers), ...strs(input.dislikes)]).slice(0, 20),
        creators: add([...a.creators], strs(input.add_creators)).slice(0, 20),
        keywords: add([...a.keywords], strs(input.add_keywords), true).slice(0, 20),
        learned,
      };
      if (typeof input.size === "string" && input.size.trim()) patch.size = input.size.trim().slice(0, 40);
      if (Number(input.max_per_item) > 0) patch.max_per_item = Number(input.max_per_item);
      if (Number(input.monthly_limit) > 0) patch.monthly_limit = Number(input.monthly_limit);
      await db.update("agents", `id=eq.${a.id}&user_id=eq.${user.id}`, patch);
      a = { ...a, ...patch } as Agent;
      actions.push({ type: "profile_updated" });
      return profile();
    }
    if (name === "flag_find") {
      const reason = String(input.reason ?? "").slice(0, 160);
      let listingId = typeof input.listing_id === "string" ? input.listing_id : "";
      if (!listingId) {
        const cleaned = cleanListings({ listings: [{ ...input, category: a.mission_category ?? "other" }] }, a.mission_category ?? "other");
        if (!cleaned.length) throw new Error("Need a listing_id, or a title and a real https URL for something you found");
        const [saved] = await db.rpc<{ id: string }[]>("upsert_listings", { p_user: user.id, p_listings: cleaned });
        listingId = saved.id;
      }
      const f = await ensureFind(listingId, reason);
      actions.push({ type: "find", find_id: f.id, title: f.title });
      return { find_id: f.id, ok: true };
    }
    if (name === "propose_purchase") {
      const [f] = await db.select<{ id: string; listing: { title: string; price: number | null; url: string | null; source: string } }>(
        "finds", `select=id,listing:listings(title,price,url,source)&id=eq.${enc(String(input.find_id))}&user_id=eq.${user.id}`);
      if (!f) throw new Error("No find with that id");
      actions.push({ type: "checkout", find_id: f.id, title: f.listing.title });
      return { checkout_ready: true, price: f.listing.price, store: f.listing.source, url: f.listing.url,
               within_cap: !a.max_per_item || !f.listing.price || f.listing.price <= a.max_per_item, monthly_limit: a.monthly_limit };
    }
    throw new Error(`Unknown tool ${name}`);
  }

  const messages: ClaudeMessage[] = [...turns];
  const narration: string[] = [];
  let reply = "";
  for (let round = 0; round < 6; round++) {
    const res = await claude({ max_tokens: 1200, system: rules(a, profile()), messages, tools: TOOLS });
    const text = textOf(res.content);
    if (res.stop_reason === "pause_turn") { messages.push({ role: "assistant", content: res.content }); continue; }
    if (res.stop_reason !== "tool_use") { reply = text; break; }
    if (text) narration.push(text);
    messages.push({ role: "assistant", content: res.content });
    const results: Block[] = [];
    for (const b of res.content.filter((b) => b.type === "tool_use")) {
      try {
        const out = await run(b.name, (b.input ?? {}) as Record<string, unknown>);
        results.push({ type: "tool_result", tool_use_id: b.id, content: JSON.stringify(out).slice(0, 20000) });
      } catch (e) {
        results.push({ type: "tool_result", tool_use_id: b.id, content: `Error: ${(e as Error).message}`, is_error: true });
      }
    }
    messages.push({ role: "user", content: results });
  }
  reply = reply || narration.join("\n\n").trim() || "I'm here. Tell me what you're hunting for.";
  return json({ reply, actions });
});

