// Hourly jobs: price drops on watched finds, and the morning "Today's Drop" digest.
import { db } from "./platform.ts";
import { firstName } from "./match.ts";
import { shoppingOffers } from "./sources.ts";
import { pageStock } from "./images.ts";

type FetchFn = (input: string, init?: RequestInit) => Promise<Response>;
const money = (n: number) => `$${n >= 100 ? Math.round(n).toLocaleString("en-US") : n.toFixed(2).replace(/\.00$/, "")}`;

interface Watched {
  id: string; user_id: string; agent_id: string | null; watch_price: number | null;
  listing: { id: string; title: string; brand?: string | null; price: number | null; low_price: number | null; offers_checked_at: string | null } | null;
  agent: { name: string } | null;
}

/** Re-prices up to `limit` watched finds (each at most every 12 hours) and texts on a drop of 5% or more. */
export async function watchCheck(limit = 6, now = new Date(), fetchFn: FetchFn = fetch): Promise<{ checked: number; drops: number }> {
  const rows = await db.select<Watched>("finds",
    "select=id,user_id,agent_id,watch_price,listing:listings(id,title,brand,price,low_price,offers_checked_at),agent:agents(name)" +
    "&watching=eq.true&status=in.(open,liked)&order=created_at.desc&limit=60");
  const names = new Map<string, string>();
  const due = rows.filter((r) => r.listing && (!r.listing.offers_checked_at || now.getTime() - Date.parse(r.listing.offers_checked_at) > 12 * 3600_000)).slice(0, limit);
  let drops = 0;
  for (const r of due) {
    const l = r.listing!;
    const offers = await shoppingOffers(l.title, fetchFn, { brand: l.brand, price: l.price });
    await db.update("listings", `id=eq.${l.id}`, {
      offers, low_price: offers[0]?.price ?? l.low_price, low_store: offers[0]?.store ?? null, offers_checked_at: now.toISOString(),
    }).catch(() => {});
    const base = r.watch_price ?? l.low_price ?? l.price;
    const best = offers[0];
    if (base && best && best.price <= base * 0.95) {
      drops++;
      if (!names.has(r.user_id)) {
        const [p] = await db.select<{ display_name: string }>("profiles", `select=display_name&id=eq.${r.user_id}`).catch(() => []);
        names.set(r.user_id, firstName(p?.display_name));
      }
      const name = names.get(r.user_id);
      const off = Math.round(base - best.price);
      await db.insert("notes", {
        user_id: r.user_id, agent_id: r.agent_id, sender_name: r.agent?.name ?? "Baget", kind: "drop", find_id: r.id,
        body: `${name ? `${name}, the` : "The"} ${l.title} you're watching just dropped to ${money(best.price)} at ${best.store}. That's ${money(off)} off what it was.`.slice(0, 480),
      }, false);
      await db.update("finds", `id=eq.${r.id}`, { watch_price: best.price }).catch(() => {});
    } else if (!r.watch_price && base) {
      await db.update("finds", `id=eq.${r.id}`, { watch_price: base }).catch(() => {});
    }
  }
  return { checked: due.length, drops };
}

interface SoldOutWatch {
  id: string; user_id: string; agent_id: string | null;
  listing: { id: string; title: string; source: string; url: string | null; sold_out: boolean; stock_checked_at: string | null } | null;
  agent: { name: string } | null;
}

/** Sold-out finds someone is watching: open the store's page (at most hourly per product) and text everyone watching
 *  the moment it says it's back in stock. A page that doesn't say either way changes nothing. */
export async function restockCheck(limit = 15, now = new Date(), fetchFn: FetchFn = fetch): Promise<{ checked: number; restocked: number }> {
  const rows = await db.select<SoldOutWatch>("finds",
    "select=id,user_id,agent_id,listing:listings!inner(id,title,source,url,sold_out,stock_checked_at),agent:agents(name)" +
    "&watching=eq.true&status=in.(open,liked)&listing.sold_out=eq.true&order=created_at.desc&limit=200");
  const byListing = new Map<string, SoldOutWatch[]>();
  for (const r of rows) {
    const l = r.listing;
    if (!l?.url || !l.sold_out) continue;
    if (l.stock_checked_at && now.getTime() - Date.parse(l.stock_checked_at) < 3600_000) continue;
    byListing.set(l.id, [...(byListing.get(l.id) ?? []), r]);
  }
  let checked = 0, restocked = 0;
  for (const [lid, watchers] of [...byListing.entries()].slice(0, limit)) {
    const l = watchers[0].listing!;
    const stock = await pageStock(l.url!, fetchFn).catch(() => null);
    checked++;
    await db.update("listings", `id=eq.${lid}`, { stock_checked_at: now.toISOString(), ...(stock === "in" ? { sold_out: false } : {}) }).catch(() => {});
    if (stock !== "in") continue;
    restocked++;
    for (const r of watchers) {
      const [p] = await db.select<{ display_name: string }>("profiles", `select=display_name&id=eq.${r.user_id}`).catch(() => []);
      const name = firstName(p?.display_name);
      await db.insert("notes", {
        user_id: r.user_id, agent_id: r.agent_id, sender_name: r.agent?.name ?? "Baget", kind: "restock", find_id: r.id,
        body: `${name ? `${name}, the` : "The"} ${l.title} is back in stock at ${l.source}. You asked me to watch it, so grab it before it sells out again.`.slice(0, 480),
      }, false).catch((e) => console.error("restock note", e));
    }
  }
  return { checked, restocked };
}

/** Local date and hour for a timezone. */
export function localNow(tz: string, now = new Date()): { date: string; hour: number } {
  let parts: Intl.DateTimeFormatPart[];
  try {
    parts = new Intl.DateTimeFormat("en-CA", { timeZone: tz, year: "numeric", month: "2-digit", day: "2-digit", hour: "2-digit", hourCycle: "h23" }).formatToParts(now);
  } catch {
    parts = new Intl.DateTimeFormat("en-CA", { timeZone: "America/New_York", year: "numeric", month: "2-digit", day: "2-digit", hour: "2-digit", hourCycle: "h23" }).formatToParts(now);
  }
  const get = (t: string) => parts.find((p) => p.type === t)?.value ?? "";
  return { date: `${get("year")}-${get("month")}-${get("day")}`, hour: Number(get("hour")) };
}

interface Pick { id: string; score: number; listing: { title: string } | null; agent: { name: string } | null }

const short = (t: string) => t.length > 38 ? t.slice(0, 37).trimEnd() + "…" : t;

/** "Morning Larry! Your squad found 3 things for you: the Jordan 1 Low Mocha, Le Labo Santal 33 and one more. Swipe through them." */
export function digestText(name: string, titles: string[], topAgent?: string): string {
  const n = titles.length;
  const named = titles.slice(0, 2).map(short);
  const rest = n - named.length;
  const list = rest > 0 ? `${named.join(", ")} and ${rest} more` : named.length === 2 ? `${named[0]} and ${named[1]}` : named[0];
  const hi = name ? `Morning ${name}!` : "Morning!";
  const lead = n === 1 ? `${topAgent ?? "Your squad"} found something for you: ${list}.` : `Your squad found ${n} things for you: ${list}.`;
  return `${hi} ${lead} Take a look when you have a sec.`.slice(0, 480);
}

/** At 8am local time, one text with the day's best picks. */
export async function morningDigest(now = new Date()): Promise<number> {
  const people = await db.select<{ id: string; tz: string; last_digest_on: string | null; display_name?: string }>("profiles", "select=id,tz,last_digest_on,display_name&limit=500");
  let sent = 0;
  for (const p of people) {
    const { date, hour } = localNow(p.tz || "America/New_York", now);
    if (hour !== 8 || p.last_digest_on === date) continue;
    const since = new Date(now.getTime() - 4 * 86400_000).toISOString();
    const picks = await db.select<Pick>("finds",
      `select=id,score,listing:listings(title),agent:agents(name)&user_id=eq.${p.id}&status=eq.open&created_at=gt.${since}&order=score.desc,created_at.desc&limit=5`);
    await db.update("profiles", `id=eq.${p.id}`, { last_digest_on: date }).catch(() => {});
    if (!picks.length || !picks[0].listing) continue;
    const top = picks[0];
    await db.insert("notes", {
      user_id: p.id, agent_id: null, sender_name: "Today's Drop", kind: "digest", find_id: top.id,
      body: digestText(firstName(p.display_name), picks.map((x) => x.listing?.title ?? "").filter(Boolean), top.agent?.name),
    }, false);
    sent++;
  }
  return sent;
}
