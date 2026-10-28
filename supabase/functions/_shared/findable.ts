// What can be a find: something you can buy now, or one specific upcoming drop. Calendars, articles, guides, groups,
// forums and collection pages are "reference": scouts read them to discover things, but never hand them over as finds.
// The scout labels every result (product / release / reference); these rules are the backstop for what slips through.

/** A web address that's a list, an article or a community page rather than one product. */
export function referenceUrl(url: string): boolean {
  let u: URL;
  try { u = new URL(url); } catch { return true; }
  const host = u.hostname.toLowerCase().replace(/^www\./, "");
  const path = u.pathname.toLowerCase();
  if (/(^|\.)nike\.com$/.test(host) && /^\/(w|[a-z]{2}\/w)\//.test(path)) return true;   // Nike's product walls
  // Social and community sites: only a marketplace item is a product.
  if (/(^|\.)facebook\.com$/.test(host)) return !/^\/marketplace\/item\//.test(path);
  if (/(^|\.)(instagram|tiktok|youtube|pinterest|reddit|x|twitter|threads|discord)\.(com|gg|net)$/.test(host) || host === "youtu.be") return true;
  // Magazines and news sites (their shops live on other subdomains, e.g. shop.hodinkee.com).
  if (/^(gq|esquire|vogue|elle|harpersbazaar|highsnobiety|hypebeast|complex|sneakernews|solecollector|nicekicks|hodinkee|fragrantica|basenotes|robbreport|wired|theverge|nytimes|wsj|forbes|businessinsider|insider|buzzfeed|cnn|caranddriver|motortrend|jalopnik|topgear|thedrive|wikipedia|fashionbeans|menshealth|mensjournal|refinery29|cosmopolitan|allure|byrdie|thecut|vulture|dappered|gearpatrol|uncrate|coolmaterial|valetmag|bloomberg|footwearnews|wwd|businessoffashion|kicksonfire|sneakerfiles|sneakerbardetroit|niketalk|monochrome-watches|fratellowatches|worndandwound|wornandwound|watchtime|ablogtowatch|teddybaldassarre)\.(com|org|net|co\.uk|de)$/.test(host)
      && !/^(shop|store)\./.test(u.hostname.toLowerCase())) {
    // Some of these also sell: their own product pages still count.
    if (!/\/(products?|shop)\//.test(path)) return true;
  }
  // List, calendar, article and community paths.
  if (/(^|\/)(calendar|release-dates?|release-calendar|sneaker-release-dates|upcoming(-releases)?|blog|blogs|news|articles?|stories|story|journal|magazine|editorial|editorials|guides?|lists?|forums?|threads?|groups?|community|communities|tags?|topics?|category|categories|lookbook|press|events?|podcast|videos?)(\/|$)/.test(path)) return true;
  // A collection is a list, unless the address goes on to one product (Shopify: /collections/x/products/y).
  if (/(^|\/)collections?(\/|$)/.test(path) && !/\/products?\//.test(path)) return true;
  return false;
}

/** A title that names a list, guide or group rather than one item. */
export function referenceTitle(title: string): boolean {
  return /\b(release dates?|release calendar|calendar|drop ?list|droplist|buyer'?s guide|guide to|everything you need|how to|top \d+|\d+ best|best .{1,40} (of|for|in) (19|20)\d\d|roundup|round-up|news|hub|facebook group|forum|community|subreddit|auctions)\b/i.test(title)
    || /\b(group|collector|club)\s*\)?$/i.test(title.trim());
}

/** Last path parts that name a list of products, not one. */
const LIST_PAGES = /^(new-?arrivals?|new-in|whats-new|best-?sellers?|shop-all|all-products|all|sale|on-sale|gifts?|gift-guide|men|mens|women|womens|kids|unisex|shoes|sneakers|footwear|clothing|apparel|accessories|fragrances?|watches|home|catalog|shop|store|brands?|designers?|outlet|clearance|limited-edition|exclusives?|latest|trending|featured|popular|coming-soon)$/;

/** A web address shaped like one product's page. */
export function productUrl(url: string): boolean {
  let u: URL;
  try { u = new URL(url); } catch { return false; }
  const path = u.pathname.toLowerCase();
  if (/\/(products?|p|dp|gp\/product|ip|itm|item|items|listing|listings|lot|lots|vehicles?|vehicledetail|vehicledetails|inventory|pd|sku|buy|launch\/t|t|auctions?)\//.test(path)) return true;
  if (/\d{5,}/.test(path)) return true;   // a product id
  const parts = path.split("/").filter(Boolean);
  const last = (parts[parts.length - 1] ?? "").replace(/\.html?$/, "");
  if (/^[a-z]{1,4}\d{3,}[a-z0-9]*$/i.test(last)) return true;   // a product code, e.g. MBG949
  // A page named after one thing: "/neroli-36.html", "/107-chiris.html", "/range/winter-2026/dascar-jacket/".
  if (!last || LIST_PAGES.test(last)) return false;
  if (/\.html?$/.test(parts[parts.length - 1] ?? "") && /[-\d]/.test(last)) return true;
  const hyphens = (last.match(/-/g) ?? []).length;
  return (hyphens >= 2 && parts.length <= 3) || (hyphens >= 1 && parts.length >= 2);
}

/** A link that can't be opened as a product page: an image or file, or a search engine's redirect. */
export function brokenLink(url: string): boolean {
  let u: URL;
  try { u = new URL(url); } catch { return true; }
  if (/vertexaisearch\.cloud\.google\.com|google\.[a-z.]+\/url|bing\.com\/ck/.test(u.hostname + u.pathname)) return true;
  return /\.(jpe?g|png|webp|gif|avif|svg|pdf|mp4)$/i.test(u.pathname) || /\/cdn\//.test(u.pathname);
}

export interface FindCandidate {
  title: string; url: string; price: number | null; sku?: string | null; sizes_in_stock?: string[] | null; drop_at?: string | null;
  kind?: string | null; tags?: string[];
}

/** Why a result can't be a find (null when it can). */
export function notFindable(l: FindCandidate): string | null {
  if (l.kind === "reference") return "reference";
  if (brokenLink(l.url)) return "broken link";
  if (l.tags?.includes("intel") || l.tags?.includes("search")) return "reference";
  if (referenceUrl(l.url)) return "reference url";
  if (referenceTitle(l.title) && l.price === null) return "reference title";
  const signal = l.price !== null || !!l.sku || !!(l.sizes_in_stock && l.sizes_in_stock.length) || !!l.drop_at || productUrl(l.url);
  if (!signal) return "no product signal";
  if (l.kind === "release" && !l.drop_at && l.price === null) return "release without a date";
  return null;
}
