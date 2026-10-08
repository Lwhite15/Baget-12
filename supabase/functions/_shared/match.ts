// Matching, sizes and friend-style texts. Mirrors Baget/Engine/Engine.swift so the phone and the server
// score finds the same way. Plain TypeScript with no imports: runs on Supabase (Deno) and in tests (Node).

export type Category = "sneakers" | "apparel" | "fragrance" | "watches" | "cars" | "furniture" | "accessories" | "collectibles";
export const CATEGORIES: Category[] = ["sneakers", "apparel", "fragrance", "watches", "cars", "furniture", "accessories", "collectibles"];

export interface Agent {
  id: string;
  user_id: string;
  name: string;
  mission_category: Category | null;
  mission_custom: string | null;
  keywords: string[];
  traits: string[];
  makers: string[];
  creators: string[];
  size: string;
  mode: "alert" | "ask" | "auto";
  voice: "hype" | "chill" | "straight";
  learned: Record<string, number>;
  price_note: number;
}

export interface Listing {
  title: string;
  brand: string;
  category: string;
  price: number | null;
  market: number | null;
  source: string;
  url?: string | null;
  drop_at?: string | null;
  sold_out?: boolean;
  creator?: string | null;
  traits: string[];
  tags: string[];
  sizes_in_stock?: string[] | null;
}

export interface Match { score: number; why: string[]; notInSize?: boolean }

interface Info { label: string; sizeRequired: boolean; traitNoun: string; makerNoun: string; creatorVerb: string; creatorNoun: string }
const INFO: Record<Category, Info> = {
  sneakers: { label: "Sneakers", sizeRequired: true, traitNoun: "details", makerNoun: "brand", creatorVerb: "Made with", creatorNoun: "a collaborator" },
  apparel: { label: "Clothing", sizeRequired: true, traitNoun: "details", makerNoun: "label", creatorVerb: "Made with", creatorNoun: "a collaborator" },
  fragrance: { label: "Fragrance", sizeRequired: false, traitNoun: "notes", makerNoun: "house", creatorVerb: "Composed by", creatorNoun: "a perfumer" },
  watches: { label: "Watches", sizeRequired: false, traitNoun: "specs", makerNoun: "manufacture", creatorVerb: "Designed by", creatorNoun: "a designer" },
  cars: { label: "Cars", sizeRequired: false, traitNoun: "specs", makerNoun: "make", creatorVerb: "Built by", creatorNoun: "a builder" },
  furniture: { label: "Furniture", sizeRequired: false, traitNoun: "details", makerNoun: "maker", creatorVerb: "Designed by", creatorNoun: "a designer" },
  accessories: { label: "Accessories", sizeRequired: false, traitNoun: "details", makerNoun: "maker", creatorVerb: "Designed by", creatorNoun: "a designer" },
  collectibles: { label: "Collectibles", sizeRequired: false, traitNoun: "details", makerNoun: "brand", creatorVerb: "By", creatorNoun: "an artist" },
};
const CUSTOM: Info = { label: "Custom", sizeRequired: false, traitNoun: "traits", makerNoun: "maker", creatorVerb: "By", creatorNoun: "a creator" };

export function info(c: string | null | undefined): Info {
  return c && (CATEGORIES as string[]).includes(c) ? INFO[c as Category] : CUSTOM;
}
export function missionLabel(a: Agent): string { return a.mission_category ? INFO[a.mission_category].label : (a.mission_custom ?? ""); }

// ── text ──
const STOP = new Set(["the", "and", "for", "any", "all", "with", "new", "old", "from", "that", "stuff", "things"]);
export function norm(s: string): string {
  return (s ?? "").normalize("NFD").replace(/[̀-ͯ]/g, "").toLowerCase().trim();
}
export function loose(a: string, b: string): boolean {
  const x = norm(a), y = norm(b);
  return !!x && !!y && (x.includes(y) || y.includes(x));
}
export function words(q: string): string[] {
  return norm(q).split(/[\s,]+/).filter((w) => w.length > 1 && !STOP.has(w)).map((w) => (w.endsWith("s") && w.length > 2 ? w.slice(0, -1) : w));
}
function haystack(l: Listing): string {
  return norm([l.title, l.brand, info(l.category).label, l.creator ?? "", ...l.traits, ...l.tags].join(" "));
}

// ── sizes ──
const EU_US: Record<string, number> = { "36": 4, "36.5": 4.5, "37.5": 5, "38": 5.5, "38.5": 6, "39": 6.5, "40": 7, "40.5": 7.5, "41": 8, "42": 8.5,
  "42.5": 9, "43": 9.5, "44": 10, "44.5": 10.5, "45": 11, "45.5": 11.5, "46": 12, "47": 12.5, "47.5": 13, "48": 13.5, "48.5": 14, "49": 15 };
/** "US M 10.5", "US W 12", "UK 9.5", "EU 44.5", "10.5" → US men's. */
export function shoeUS(s: string | null | undefined): number | null {
  const up = (s ?? "").toUpperCase();
  const m = up.match(/(\d+(?:\.5)?)/);
  if (!m) return null;
  const n = parseFloat(m[1]);
  if (up.includes("EU")) return EU_US[m[1]] ?? null;
  if (up.includes("UK")) return n + 1;
  if (/\bW\b|WOMEN|WMNS/.test(up)) return n - 1.5;
  return n;
}
export function topSize(s: string | null | undefined): string | null {
  const m = (s ?? "").toUpperCase().replace("2XL", "XXL").match(/\b(XXS|XS|S|M|L|XL|XXL)\b/);
  return m ? m[1] : null;
}
export function sizeRequired(a: Agent): boolean { return !!a.mission_category && INFO[a.mission_category].sizeRequired; }
export function hasSize(a: Agent): boolean {
  if (a.mission_category === "sneakers") return shoeUS(a.size) !== null;
  if (a.mission_category === "apparel") return topSize(a.size) !== null || /\d+\s*x\s*\d+/i.test(a.size ?? "");
  return true;
}
/** true = in stock in your size, false = not, null = unknown or not applicable. */
export function sizeFit(a: Agent, l: Listing): boolean | null {
  const stock = l.sizes_in_stock;
  if (!stock || stock.length === 0) return null;
  if (l.category === "sneakers") {
    const mine = shoeUS(a.size);
    if (mine === null) return null;
    return stock.some((s) => shoeUS(s) === mine);
  }
  if (l.category === "apparel") {
    const mine = topSize(a.size);
    if (!mine) return null;
    return stock.some((s) => topSize(s) === mine);
  }
  return null;
}

// ── matching ──
export function covers(a: Agent, l: Listing): boolean {
  if (a.mission_category) return a.mission_category === l.category;
  const hay = haystack(l);
  return words(a.mission_custom ?? "").some((w) => hay.includes(w));
}
export function intel(a: Agent): number {
  let k = 26 + Math.min(a.keywords.length, 5) * 6 + ((a.size || !sizeRequired(a)) ? 10 : 0) +
    Math.min(a.traits.length, 5) * 6 + Math.min(a.makers.length, 3) * 5 + Math.min(a.creators.length, 2) * 5;
  return Math.min(100, k);
}
export function match(a: Agent, l: Listing, photoTags: string[] = []): Match | null {
  if (!covers(a, l)) return null;
  if (sizeRequired(a) && !hasSize(a)) return null;
  const fit = sizeFit(a, l);
  if (fit === false) return { score: 0, why: [`Not in stock in your size (${a.size})`], notInSize: true };
  const inf = info(l.category);
  const why: string[] = [];
  let pts = 0;
  const hay = norm([l.title, l.brand, ...l.tags, ...l.traits].join(" "));
  const hits = a.keywords.filter((k) => k && hay.includes(norm(k)));
  if (hits.length) { pts += hits.length * 12; why.push(`Matches your keywords: ${hits.slice(0, 3).join(", ")}`); }
  if (a.makers.some((m) => loose(m, l.brand))) { pts += 20; why.push(`From ${l.brand}, a ${inf.makerNoun} you like`); }
  if (l.creator && a.creators.some((c) => loose(c, l.creator!))) { pts += 18; why.push(`${inf.creatorVerb} ${l.creator}, ${inf.creatorNoun} you follow`); }
  const shared = a.traits.filter((t) => l.traits.some((x) => loose(x, t)));
  if (shared.length) {
    pts += shared.length * 9;
    const photo = new Set(photoTags.map(norm));
    const fromPhotos = shared.filter((t) => photo.has(norm(t)));
    const fromBrief = shared.filter((t) => !photo.has(norm(t)));
    if (fromBrief.length) why.push(`Shares your ${fromBrief.join(", ")} ${inf.traitNoun}`);
    if (fromPhotos.length) why.push(`Like your taste photos: ${fromPhotos.join(", ")}`);
  }
  if (a.mission_custom && why.length === 0) { pts += 14; why.push(`Fits your mission: ${a.mission_custom}`); }
  const keys = [...l.traits, l.brand];
  const learned = a.learned ?? {};
  const liked = keys.filter((k) => (learned[norm(k)] ?? 0) > 0);
  const disliked = keys.filter((k) => (learned[norm(k)] ?? 0) < 0);
  if (liked.length) { pts += liked.reduce((t, k) => t + Math.min(3, learned[norm(k)]) * 6, 0); why.push(`You've gone for ${liked.slice(0, 3).join(", ")} before`); }
  if (disliked.length) { pts += disliked.reduce((t, k) => t + Math.max(-3, learned[norm(k)]) * 8, 0); why.push(`Heads up: you passed on ${disliked.slice(0, 2).join(", ")} before`); }
  if (fit === true) why.push(`In stock in your size, ${a.size}`);
  const boost = intel(a);
  if (why.length === 0 || (why.length === 1 && fit === true)) return { score: Math.round(28 + boost * 0.12), why: ["Broad mission match only", ...why] };
  return { score: Math.max(5, Math.min(98, Math.round(35 + pts * 0.55 + boost * 0.1))), why };
}

// ── friend-style texts ──
export type Kind = "release" | "available" | "steal" | "watch" | "restock" | "bought" | "budget" | "learned";
export function kindFor(l: Listing, now = Date.now()): Kind {
  if (l.sold_out) return "watch";
  if (l.drop_at && Date.parse(l.drop_at) > now) return "release";
  if (l.price && l.market && l.market > l.price * 1.2) return "steal";
  return "available";
}
export function whenText(l: Listing, now = Date.now()): string {
  if (!l.drop_at) return "soon";
  const m = (Date.parse(l.drop_at) - now) / 60000;
  if (m <= 0) return "right now";
  if (m < 60) return `in ${Math.ceil(m)} minutes`;
  if (m < 1440) return `in about ${Math.round(m / 60)} hours`;
  return m < 2880 ? "tomorrow" : "this week";
}
function money(v: number | null): string {
  return v == null ? "price TBA" : "$" + Math.round(v).toLocaleString("en-US");
}
export function hookFor(a: Agent, l: Listing): string {
  const t = l.traits.find((x) => a.traits.some((y) => loose(x, y)));
  if (t) return t;
  if (a.makers.some((m) => loose(m, l.brand))) return l.brand;
  return l.traits[0] ?? l.brand;
}
export function friendLine(a: Agent, kind: Kind, l: Listing, score = 0, now = Date.now()): string {
  const t = l.title, src = l.source, price = money(l.price), hook = hookFor(a, l), when = whenText(l, now);
  const pct = l.price && l.market ? Math.round((1 - l.price / l.market) * 100) : 0;
  const v = a.voice;
  switch (kind) {
    case "release":
      return v === "hype" ? `Yo! The ${t} drops ${when} at ${src}. Total ${hook} energy. Want me to line up checkout?`
        : v === "straight" ? `${t} releases ${when} at ${src}, ${price}. Matches your ${hook} preference.`
        : `Heads up, the ${t} drops ${when} at ${src}. It's very your ${hook} thing. Want me to get checkout ready?`;
    case "steal":
      return v === "hype" ? `Okay this is a steal: the ${t} is ${price}, about ${pct}% under what it trades for. Don't sleep on it.`
        : v === "straight" ? `${t}: asking ${price}, market ${money(l.market)}. About ${pct}% under.`
        : `The ${t} is going for ${price}, roughly ${pct}% under market. Worth a look if you still want one.`;
    case "watch":
      return v === "hype" ? `Ugh, the ${t} is sold out right now. I'm camped out for the restock.`
        : v === "straight" ? `${t} is sold out. Restock watch is on.`
        : `The ${t} is sold out right now. I'll keep watching and tell you the second it's back.`;
    case "restock":
      return v === "hype" ? `IT'S BACK. The ${t} just restocked at ${src}. Want me to grab it before it's gone again?`
        : v === "straight" ? `Restock: ${t} at ${src}, ${price}. Tap to review.`
        : `Good news, the ${t} is back in stock at ${src}. Want it?`;
    default:
      return v === "hype" ? `Found one for you! The ${t} is up right now at ${src} for ${price}. It's so you.`
        : v === "straight" ? `${t} is available at ${src} for ${price}.${score ? ` ${score}% match.` : ""}`
        : `Found something you'll like: the ${t}, ${price} at ${src}. Has that ${hook} thing you're into.`;
  }
}

/** Hour of day in a timezone, for quiet hours. */
export function localHour(tz: string, now = new Date()): number {
  try {
    return Number(new Intl.DateTimeFormat("en-US", { hour: "numeric", hourCycle: "h23", timeZone: tz }).format(now));
  } catch {
    return now.getUTCHours();
  }
}
export function heldForMorning(kind: Kind, l: Listing, tz: string, quietHours: boolean, now = new Date()): boolean {
  if (!quietHours) return false;
  const urgent = kind === "restock" || (kind === "release" && !!l.drop_at && Date.parse(l.drop_at) - now.getTime() < 90 * 60000);
  if (urgent) return false;
  const h = localHour(tz, now);
  return h >= 22 || h < 8;
}
export const GROUP_OF: Record<Kind, string> = {
  release: "finds", available: "finds", watch: "restocks", restock: "restocks", steal: "steals", bought: "money", budget: "money", learned: "learning",
};
