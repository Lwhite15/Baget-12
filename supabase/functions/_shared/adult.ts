// Baget never hunts porn or other adult content. One word list, used everywhere a scout's mission or a listing is
// checked; the database has the same check (public.is_adult) on scouts and finds as a backstop.
// Words are matched whole, so "unisex", "Nude Pink" (a color) or "Naked Sundays" (a brand) are fine.

export const ADULT_WORDS = String.raw`porn\w*|xxx(?!-?\s?l)|nsfw|onlyfans|only fans|fansly|hentai|sex ?toys?|sex ?dolls?|sex ?tapes?|sex ?shops?|` +
  String.raw`adult ?toys?|adult ?videos?|adult ?films?|adult ?entertainment|adult ?content|dildos?|vibrators?|fleshlights?|butt ?plugs?|cock ?rings?|` +
  String.raw`bdsm|bondage|erotica?|camgirls?|cam ?girls?|cam ?sites?|webcam ?models?|strip ?clubs?|lap ?dances?|escort ?services?|nudes|` +
  String.raw`masturbat\w*|orgasm\w*|playboy ?magazine|penthouse ?magazine|hustler ?magazine`;
const WORDS = new RegExp(String.raw`\b(${ADULT_WORDS})\b`, "i");
const HOSTS = /(porn|xxx|xvideos|xnxx|xhamster|hentai|onlyfans|fansly|chaturbate|stripchat|bongacams|livejasmin|myfreecams|camsoda|brazzers|redtube|spankbang|adultempire|adameve|lovehoney|fleshlight|bellesa|manyvids|clips4sale)/i;

export function isAdultText(...parts: (string | null | undefined | string[])[]): boolean {
  const s = parts.flat().filter((x): x is string => typeof x === "string").join(" ");
  return WORDS.test(s);
}

export function isAdultHost(url: string | null | undefined): boolean {
  if (!url) return false;
  try { return HOSTS.test(new URL(url).hostname); } catch { return false; }
}

/** A listing that's adult content: by its words, or by the site it's on. */
export function isAdultListing(l: { title: string; brand?: string | null; url?: string | null; source?: string | null; traits?: string[] }): boolean {
  return isAdultText(l.title, l.brand, l.source, l.traits) || isAdultHost(l.url);
}

export const ADULT_REFUSAL = "Baget doesn't hunt adult content. Try something else you're into.";
