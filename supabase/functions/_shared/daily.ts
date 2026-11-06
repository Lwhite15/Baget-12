// Hourly jobs: price drops on watched finds, and the morning drop (and its one text).
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
export async function watchCheck(limit = 20, now = new Date(), fetchFn: FetchFn = fetch): Promise<{ checked: number; drops: number }> {
  const rows = await db.select<Watched>("finds",
    "select=id,user_id,agent_id,watch_price,listing:listings(id,title,brand,price,low_price,offers_checked_at),agent:agents(name)" +
    "&watching=eq.true&status=in.(open,liked)&order=created_at.desc&limit=400");
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
interface Payoff { kind: string; find: { listing: { title: string } | null } | null }

const short = (t: string) => t.length > 38 ? t.slice(0, 37).trimEnd() + "…" : t;

/** "Morning Larry! Your drop is in: 9 picks from 3 scouts. Plus the Goldwin Terry Zip Hoodie you're watching dropped in price." */
export function digestText(name: string, picks: number, scouts: number, payoff?: { kind: string; title: string }): string {
  const hi = name ? `Morning ${name}!` : "Morning!";
  const lead = picks === 1 ? "Your drop is in: 1 pick for you." :
    `Your drop is in: ${picks} picks from ${scouts === 1 ? "your scout" : `${scouts} scouts`}.`;
  const extra = !payoff ? "" : payoff.kind === "restock"
    ? ` Plus the ${short(payoff.title)} you're watching is back in stock.`
    : ` Plus the ${short(payoff.title)} you're watching dropped in price.`;
  return `${hi} ${lead}${extra}`.slice(0, 480);
}

/** At each person's drop time (9 AM local unless they changed it): make today's drop and send one text about it,
 *  leading with a payoff from yesterday when there is one. */
export async function morningDigest(now = new Date()): Promise<number> {
  const people = await db.select<{ id: string; tz: string; last_digest_on: string | null; display_name?: string; settings?: { dropHour?: number } | null }>(
    "profiles", "select=id,tz,last_digest_on,display_name,settings&limit=1000");
  let sent = 0;
  for (const p of people) {
    const { date, hour } = localNow(p.tz || "America/New_York", now);
    const dropHour = typeof p.settings?.dropHour === "number" ? p.settings.dropHour : 9;
    if (hour !== dropHour || p.last_digest_on === date) continue;
    await db.update("profiles", `id=eq.${p.id}`, { last_digest_on: date }).catch(() => {});
    await db.rpc("make_drop", { p_user: p.id, p_date: date }).catch((e) => console.error("make_drop", e));
    const picks = await db.select<Pick>("finds",
      `select=id,score,listing:listings(title),agent:agents(name)&user_id=eq.${p.id}&drop_on=eq.${date}&order=score.desc`);
    if (!picks.length || !picks[0].listing) continue;
    const since = new Date(now.getTime() - 24 * 3600_000).toISOString();
    const [pay] = await db.select<Payoff>("notes",
      `select=kind,find:finds(listing:listings(title))&user_id=eq.${p.id}&kind=in.(drop,restock)&created_at=gt.${since}&order=created_at.desc&limit=1`).catch(() => []);
    const payoff = pay?.find?.listing?.title ? { kind: pay.kind, title: pay.find.listing.title } : undefined;
    const scouts = new Set(picks.map((x) => x.agent?.name ?? "")).size;
    await db.insert("notes", {
      user_id: p.id, agent_id: null, sender_name: "Today's Drop", kind: "digest", find_id: picks[0].id,
      body: digestText(firstName(p.display_name), picks.length, scouts, payoff),
    }, false);
    sent++;
  }
  return sent;
}
