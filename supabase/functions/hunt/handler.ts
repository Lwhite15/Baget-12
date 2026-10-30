// "What are you hunting?" One sentence in, a ready agent out.
// Claude turns the sentence into a brief (mission, brands, styles, keywords, size) and the agent is created for the person.
import { ADULT_REFUSAL, isAdultText } from "../_shared/adult.ts";
import { CATEGORIES, firstName, langCode, langOf } from "../_shared/match.ts";
import { HttpError, claude, db, handle, json, parseJSON, quota, requireUser, textOf } from "../_shared/platform.ts";

export interface Plan {
  name: string;
  category: string | null;
  custom: string | null;
  keywords: string[];
  makers: string[];
  traits: string[];
  creators: string[];
  size: string;
  voice: "hype" | "chill" | "straight";
  intro: string;
  /** "interest": built around what they're into and hunts wide; "specific": one thing (a grail, a size, a price). */
  focus: "interest" | "specific";
  /** What they said they don't want ("nothing too sweet" -> "sweet"); seeded as passes so the scout steers clear. */
  avoid: string[];
}

export const cleanFocus = (v: unknown): "interest" | "specific" => v === "specific" ? "specific" : "interest";

const strs = (v: unknown, n: number, lower = false) =>
  Array.isArray(v) ? v.filter((x) => typeof x === "string").map((x) => (x as string).trim()).filter((x) => x && x.length <= 40)
    .map((x) => (lower ? x.toLowerCase() : x)).slice(0, n) : [];

/** Validates Claude's plan so only sane values reach the database. */
export function cleanPlan(raw: unknown, text: string, size?: string, focus: "interest" | "specific" = "interest"): Plan {
  const r = (raw ?? {}) as Record<string, unknown>;
  const category = typeof r.category === "string" && (CATEGORIES as string[]).includes(r.category) && r.category !== "other" ? r.category : null;
  let custom = !category ? (typeof r.custom === "string" && r.custom.trim() ? r.custom.trim() : text.trim()).slice(0, 80) : null;
  if (custom !== null && custom.length < 1) custom = "Anything I'd love";
  const voice = r.voice === "hype" || r.voice === "straight" ? r.voice : "chill";
  const name = (typeof r.name === "string" && r.name.trim() ? r.name.trim() : "Scout").slice(0, 40);
  return {
    name, category, custom,
    keywords: strs(r.keywords, 8, true), makers: strs(r.makers, 8), traits: strs(r.traits, 10, true), creators: strs(r.creators, 6),
    size: (size?.trim() || (typeof r.size === "string" ? r.size.trim() : "")).slice(0, 40),
    voice, intro: (typeof r.intro === "string" ? r.intro.trim() : "").slice(0, 240),
    focus, avoid: strs(r.avoid, 6, true),
  };
}

const BRIEF_FIELDS = `{"name": "a short fun agent name (2-3 words, e.g. Oud Hunter, Grail Scout)",
 "category": one of ${JSON.stringify(CATEGORIES.filter((c) => c !== "other"))} if it clearly fits, else null,
 "custom": if category is null, a short mission like "high-rise apartments in McLean" (else null),
 "keywords": specific things to look for (models, product lines, 0-6 short lowercase terms),
 "makers": brands, houses, makers or dealers they named or clearly imply (0-6),
 "traits": styles, materials, notes, colors, specs they want (0-8 short lowercase terms),
 "creators": designers, perfumers, artists, collaborators (0-4),
 "size": their size if they said one, else "",
 "voice": "hype" for streetwear and sneakers, "straight" for cars and big purchases, else "chill",
 "intro": one friendly sentence in the agent's voice saying what it will hunt, specific to their taste}`;

type Img = { media_type: string; data: string };
const IMG_TYPES = ["image/jpeg", "image/png", "image/webp"];

async function insertAgent(userId: string, plan: Plan, budget: number | null = null): Promise<string> {
  const row: Record<string, unknown> = {
    ...(budget && plan.category !== "cars" ? { price_note: budget } : {}),   // an item budget makes no sense for a car
    user_id: userId, name: plan.name, keywords: plan.keywords, traits: plan.traits, makers: plan.makers,
    creators: plan.creators, size: plan.size, voice: plan.voice, mode: "ask", focus: plan.focus,
    ...(plan.avoid.length ? { learned: Object.fromEntries(plan.avoid.map((x) => [x, -2])) } : {}),
    ...(plan.category ? { mission_category: plan.category } : { mission_custom: plan.custom }),
  };
  try {
    const created = await db.insert<{ id: string }>("agents", row);
    return created[0].id;
  } catch (e) {
    if (/agent_limit/i.test((e as Error).message)) {
      const hint = (e as Error).message.match(/"hint":"([^"]+)"/)?.[1];
      throw new HttpError(409, hint ?? "Your squad is full. Retire a scout to add another.");
    }
    throw e;
  }
}

const needsSize = (p: Plan) => (p.category === "sneakers" || p.category === "apparel") && !p.size;

/** Onboarding: a few categories, an optional sentence and up to 3 photos -> one agent per category, tuned to the photos. */
/** Free 2 scouts, Pro 5, owner accounts 12 (matches the database's limit). */
export async function scoutLimit(userId: string): Promise<number> {
  const [p] = await db.select<{ plan: string; pro_until: string | null }>("profiles", `select=plan,pro_until&id=eq.${userId}`).catch(() => []);
  if (p?.plan === "comp") return 12;
  if (p?.plan === "pro" && p.pro_until && Date.parse(p.pro_until) > Date.now()) return 5;
  return 2;
}

/** Each new agent says hi in the inbox: who it is, what it's hunting, and when to expect finds. Not pushed (kind "learned"). */
const INTRO: Record<string, (name: string, scout: string, intro: string) => string> = {
  en: (n, s, i) => `${n ? `Hey ${n}, ` : "Hey, "}${s} here. ${i || "I'm on the hunt for you."} I'm searching now; my first finds usually land within a few minutes.`,
  es: (n, s, i) => `${n ? `¡Hola, ${n}! ` : "¡Hola! "}Soy ${s}. ${i || "Ya estoy buscando para ti."} Estoy buscando ahora; mis primeros hallazgos suelen llegar en unos minutos.`,
  fr: (n, s, i) => `${n ? `Salut ${n}, ` : "Salut, "}c'est ${s}. ${i || "Je pars à la chasse pour toi."} Je cherche en ce moment ; mes premières trouvailles arrivent en général en quelques minutes.`,
  ko: (n, s, i) => `${n ? `${n}님, 안녕하세요! ` : "안녕하세요! "}${s}예요. ${i || "지금부터 찾아볼게요."} 지금 찾고 있어요. 첫 결과는 보통 몇 분 안에 도착해요.`,
  vi: (n, s, i) => `${n ? `Chào ${n}, ` : "Chào bạn, "}mình là ${s}. ${i || "Mình bắt đầu săn cho bạn đây."} Mình đang tìm ngay bây giờ; những món đầu tiên thường có trong vài phút.`,
  "zh-Hans": (n, s, i) => `${n ? `${n}，你好！` : "你好！"}我是${s}。${i || "我这就开始帮你找。"}我正在搜索，第一批发现通常几分钟内就到。`,
  "zh-Hant": (n, s, i) => `${n ? `${n}，你好！` : "你好！"}我是${s}。${i || "我這就開始幫你找。"}我正在搜尋，第一批發現通常幾分鐘內就到。`,
  ja: (n, s, i) => `${n ? `${n}さん、こんにちは！` : "こんにちは！"}${s}です。${i || "さっそく探しますね。"}いま探しています。最初の発見はたいてい数分で届きます。`,
  th: (n, s, i) => `${n ? `สวัสดี ${n}! ` : "สวัสดี! "}${s} เองนะ ${i || "เริ่มตามหาให้แล้ว"} กำลังค้นหาอยู่ตอนนี้ ของชิ้นแรกมักมาถึงภายในไม่กี่นาที`,
  id: (n, s, i) => `${n ? `Hai ${n}, ` : "Hai, "}ini ${s}. ${i || "Aku mulai berburu untukmu."} Aku sedang mencari sekarang; temuan pertama biasanya datang dalam beberapa menit.`,
  hi: (n, s, i) => `${n ? `नमस्ते ${n}, ` : "नमस्ते, "}मैं ${s} हूँ। ${i || "मैं आपके लिए खोज शुरू कर रहा हूँ।"} मैं अभी खोज रहा हूँ; पहली चीज़ें आमतौर पर कुछ ही मिनटों में आ जाती हैं।`,
  fil: (n, s, i) => `${n ? `Hi ${n}, ` : "Hi, "}si ${s} ito. ${i || "Hahanapan na kita."} Naghahanap na ako ngayon; kadalasan dumarating ang unang finds sa loob ng ilang minuto.`,
};

async function introNotes(userId: string, agents: { agent_id: string; name: string; intro: string }[], lang = "en") {
  const [p] = await db.select<{ display_name: string }>("profiles", `select=display_name&id=eq.${userId}`).catch(() => []);
  const name = firstName(p?.display_name);
  const write = INTRO[lang] ?? INTRO.en;
  const rows = agents.map((a) => ({
    user_id: userId, agent_id: a.agent_id, sender_name: a.name, kind: "learned",
    body: write(name, a.name, a.intro).slice(0, 480),
  }));
  if (rows.length) await db.insert("notes", rows, false).catch((e) => console.error("intro notes", e));
}

/** Plain-language vibes picked in setup, per category ("fragrance": ["fresh & clean", "date night"]). */
const words = (x: string) => x.toLowerCase().split(/[^a-z0-9]+/).filter((w) => w.length > 2);

/** Interests tapped in setup that aren't one of the built-in categories ("Tech & gadgets", "Vinyl & music"). */
export const cleanInterests = (v: unknown) => Array.isArray(v)
  ? [...new Set(v.filter((x) => typeof x === "string").map((x) => (x as string).trim().slice(0, 40)).filter(Boolean))].slice(0, 6) : [];

export function cleanVibes(v: unknown, lower = true): Record<string, string[]> {
  const out: Record<string, string[]> = {};
  if (!v || typeof v !== "object" || Array.isArray(v)) return out;
  for (const [k, list] of Object.entries(v as Record<string, unknown>)) {
    if (!(CATEGORIES as string[]).includes(k) || !Array.isArray(list)) continue;
    const xs = list.filter((x) => typeof x === "string").map((x) => (x as string).trim().slice(0, 30)).map((x) => lower ? x.toLowerCase() : x).filter(Boolean).slice(0, 8);
    if (xs.length) out[k] = xs;
  }
  return out;
}

/** Sizes picked in setup, per category ("sneakers": "10.5", "apparel": "M"). */
export function cleanSizes(v: unknown): Record<string, string> {
  const out: Record<string, string> = {};
  if (!v || typeof v !== "object" || Array.isArray(v)) return out;
  for (const k of ["sneakers", "apparel"]) {
    const x = (v as Record<string, unknown>)[k];
    if (typeof x === "string" && x.trim()) out[k] = x.trim().slice(0, 40);
  }
  return out;
}

export const cleanDepartment = (v: unknown) => v === "women" || v === "men" ? v : null;

async function saveDepartment(userId: string, dept: "women" | "men") {
  const [p] = await db.select<{ settings: Record<string, unknown> | null }>("profiles", `select=settings&id=eq.${userId}`);
  await db.update("profiles", `id=eq.${userId}`, { settings: { ...(p?.settings ?? {}), department: dept } });
}

/** Budget picked in setup: the most they'd usually spend on one item, or null for no limit. */
export const cleanBudget = (v: unknown) => typeof v === "number" && v >= 10 && v <= 100000 ? Math.round(v) : null;

async function onboard(userId: string, categories: string[], text: string, size: string | undefined, images: Img[],
                       liked: string[] = [], passed: string[] = [], vibes: Record<string, string[]> = {}, budget: number | null = null,
                       brands: Record<string, string[]> = {}, interests: string[] = [], sizes: Record<string, string> = {},
                       department: "women" | "men" | null = null, lang = "en") {
  if (isAdultText(text)) text = "";
  interests = interests.filter((x) => !isAdultText(x));
  const cats = [...new Set(categories.filter((c) => (CATEGORIES as string[]).includes(c) && c !== "other"))].slice(0, 6);
  if (!cats.length && !interests.length && !text) throw new HttpError(400, "Pick at least one thing you're into");
  const picked = [...cats, ...interests];
  const content: Record<string, unknown>[] = images.map((im) => ({ type: "image", source: { type: "base64", media_type: im.media_type, data: im.data } }));
  content.push({ type: "text", text: `Someone is setting up their shopping scout app.
They picked these interests: ${picked.length ? picked.join(", ") : "(none)"}.
${text ? `They also said: "${text}".` : ""}
${images.length ? `The ${images.length === 1 ? "photo shows" : `${images.length} photos show`} things they love. Read their taste from them (brands, styles, materials, colors, eras) and use it in the briefs where it fits.` : ""}
${liked.length ? `In a quick taste check they hearted: ${liked.join("; ")}. Use the makers, styles and materials these share.` : ""}
${passed.length ? `They passed on: ${passed.join("; ")}. Steer the briefs away from what these share.` : ""}
${Object.keys(vibes).length ? `In plain words, the vibes they picked: ${Object.entries(vibes).map(([c, xs]) => `${c}: ${xs.join(", ")}`).join("; ")}.
Turn these vibes into concrete traits the scout can search for (for fragrance: the notes and
scent families that give that vibe, e.g. "fresh & clean" → citrus, aquatic, musk; "sweet & cozy" → vanilla, tonka, amber).` : ""}
${Object.keys(brands).length ? `Brands they picked: ${Object.entries(brands).map(([c, xs]) => `${c}: ${xs.join(", ")}`).join("; ")}. Put these in that category's makers.` : ""}
${budget ? `They usually spend up to $${budget} on one item.` : ""}
Make one agent brief per picked interest${text && !picked.length ? " (or one for what they said)" : ""}${text && picked.length ? ", plus one more if what they said is a separate hunt" : ""}.
For an interest that isn't one of the categories, set category null and write it as "custom" (e.g. "Tech & gadgets" → custom "tech and gadgets").
Each scout hunts a whole interest for weeks, not one item: make each brief wide (the makers, styles and kinds of things people
into it love, including ones they didn't name), shaped by what they said and showed.
${department ? `They shop the ${department === "women" ? "women's" : "men's"} department: make every brief for that department (sizes, cuts, styles).` : ""}
${langOf(lang) ? `Write each agent's "name" and "intro" in ${langOf(lang)}. Keep keywords, traits, makers and creators in English: they're search terms.` : ""}
Also say who they shop for: "department" is "women" or "men" only when their words, photos, picks or sizes clearly show it
(e.g. women's sizes, "my wife's style" means they shop women's), else null.
Reply with only JSON: {"department": "women" | "men" | null, "agents": [${BRIEF_FIELDS}, ...]}
Use only what they said, picked or showed. Keep every list item short (1-4 words).` });
  const res = await claude({ purpose: "onboarding", max_tokens: 6000, messages: [{ role: "user", content }] });
  const parsed = parseJSON<{ agents?: unknown[]; department?: unknown }>(textOf(res.content));
  const raw = (parsed?.agents ?? []).slice(0, 7);
  // Who they shop for: what they picked in setup, else what Claude read from their words and photos. Every scout and
  // For You stick to that department from the first hunt on.
  const dept = department ?? (parsed?.department === "women" || parsed?.department === "men" ? parsed.department : null);
  if (dept) await saveDepartment(userId, dept).catch((e) => console.error("department", e));
  const plans = raw.map((r) => cleanPlan(r, text || "Anything I'd love", size));
  // Make sure every picked category got an agent, even if Claude skipped one.
  for (const c of cats) if (!plans.some((p) => p.category === c)) plans.push(cleanPlan({ category: c, name: `${c[0].toUpperCase()}${c.slice(1)} Scout` }, c, size));
  // Same for the other interests they tapped (as custom missions).
  const covered = (i: string) => plans.some((p) => p.custom && words(p.custom).some((w) => words(i).includes(w)));
  for (const i of interests) if (!covered(i)) plans.push(cleanPlan({ custom: i.toLowerCase(), name: `${i.split(/[ &]/)[0]} Scout` }, i, size));
  // The vibes they picked always reach the scout, in their own words, alongside what Claude translated them into.
  for (const p of plans) {
    const v = p.category ? vibes[p.category] ?? [] : [];
    p.traits = [...new Set([...v, ...p.traits])].slice(0, 12);
    const b = p.category ? brands[p.category] ?? [] : [];
    p.makers = [...new Set([...b, ...p.makers].map((x) => x.trim()))].slice(0, 10);
    // The size they tapped for this category beats anything guessed from their words.
    if (p.category && sizes[p.category]) p.size = sizes[p.category];
    // Women's sizes: the scout hunts the women's department.
    if (/\bUS W\b|womenswear/i.test(p.size) && !p.traits.some((t) => /women/i.test(t))) p.traits = ["womens", ...p.traits].slice(0, 12);
  }
  // Only as many scouts as the plan allows (Free 2, Pro 5); the strongest picks first.
  const limit = await scoutLimit(userId);
  const existing = (await db.select<{ id: string }>("agents", `select=id&user_id=eq.${userId}`)).length;
  plans.splice(Math.max(0, limit - existing));
  const agents = [];
  for (const p of plans) {
    if (isAdultText(p.name, p.custom, p.keywords, p.makers, p.traits, p.creators)) continue;
    const id = await insertAgent(userId, p, budget);
    agents.push({ agent_id: id, ...p, needs_size: needsSize(p) });
  }
  await introNotes(userId, agents, langOf(lang) ? langCode(lang) : "en");
  return { agents };
}

/** A specific hunt that's done (they bought it): the scout keeps going on the wider interest behind it. */
async function broaden(userId: string, agentId: string, lang = "en") {
  if (!/^[0-9a-f-]{36}$/i.test(agentId)) throw new HttpError(400, "Unknown scout");
  const [a] = await db.select<{ id: string; name: string; mission_category: string | null; mission_custom: string | null; keywords: string[];
    makers: string[]; traits: string[]; creators: string[]; size: string }>("agents",
    `select=id,name,mission_category,mission_custom,keywords,makers,traits,creators,size&id=eq.${agentId}&user_id=eq.${userId}`);
  if (!a) throw new HttpError(404, "Unknown scout");
  const was = [a.mission_custom ?? a.mission_category, a.keywords.join(", "), a.makers.join(", "), a.traits.join(", ")].filter(Boolean).join("; ");
  const res = await claude({
    purpose: "hunt", max_tokens: 3000,
    messages: [{ role: "user", content: `A shopping scout was hunting one specific thing: ${was}. They found and bought it.
Now the scout keeps going on the wider interest behind it (a vintage Rolex Explorer -> tool watches; one Dior sunglass -> designer sunglasses).
Write a wide brief for that interest. Reply with only JSON: ${BRIEF_FIELDS}
Keep every list item short (1-4 words).${langOf(lang) ? ` Write "name" and "intro" in ${langOf(lang)}. Keep the lists in English.` : ""}` }],
  });
  const plan = cleanPlan(parseJSON(textOf(res.content)), a.mission_custom ?? a.mission_category ?? "", a.size, "interest");
  if (isAdultText(plan.name, plan.custom, plan.keywords, plan.makers, plan.traits, plan.creators)) throw new HttpError(400, ADULT_REFUSAL);
  await db.update("agents", `id=eq.${a.id}&user_id=eq.${userId}`, {
    focus: "interest", name: plan.name, keywords: plan.keywords, makers: plan.makers, traits: plan.traits, creators: plan.creators,
    ...(plan.category ? { mission_category: plan.category, mission_custom: null } : { mission_category: null, mission_custom: plan.custom }),
  });
  return { agent_id: a.id, ...plan };
}

export const handler = handle(async (req) => {
  const user = await requireUser(req);
  await quota(user.id, "hunt", 20, 50);
  const body = await req.json().catch(() => ({})) as { text?: string; size?: string; categories?: string[]; images?: Img[]; liked?: string[]; passed?: string[];
    vibes?: unknown; budget?: unknown; brands?: unknown; interests?: unknown; sizes?: unknown; department?: unknown; lang?: unknown };
  const text = (body.text ?? "").trim().slice(0, 1200);
  if (Array.isArray(body.categories)) {
    const images = (Array.isArray(body.images) ? body.images : [])
      .filter((im) => im && IMG_TYPES.includes(im.media_type) && typeof im.data === "string" && im.data.length < 2_000_000).slice(0, 3);
    const titles = (v: unknown) => Array.isArray(v)
      ? v.filter((x) => typeof x === "string" && x.trim()).map((x) => (x as string).trim().slice(0, 80)).slice(0, 12) : [];
    return json(await onboard(user.id, body.categories, text, body.size, images, titles(body.liked), titles(body.passed),
      cleanVibes(body.vibes), cleanBudget(body.budget), cleanVibes(body.brands, false), cleanInterests(body.interests), cleanSizes(body.sizes), cleanDepartment(body.department),
      langCode(body.lang)));
  }
  if (typeof (body as { broaden?: unknown }).broaden === "string") return json(await broaden(user.id, (body as { broaden: string }).broaden, langCode(body.lang)));
  if (text.length < 2) throw new HttpError(400, "Tell me what to hunt for");
  const focus = cleanFocus((body as { focus?: unknown }).focus);
  // Builds before interest scouts don't send a focus: their brief stays as it was.
  const legacy = (body as { focus?: unknown }).focus === undefined;
  if (isAdultText(text)) throw new HttpError(400, ADULT_REFUSAL);

  const res = await claude({
    purpose: "hunt",
    max_tokens: 4000,
    messages: [{ role: "user", content: `Someone told their shopping scout app ${legacy ? "what they want" : focus === "interest" ? "what they're into" : "the one specific thing they're hunting"}: "${text}"

${legacy ? "" : focus === "interest"
  ? `This is an interest, not one item: the scout hunts this whole world for weeks and brings back many different things.
Make the brief wide: the makers, brands, styles and specs people who are into this love (include ones they didn't name),
and keywords for the kinds of things in it (not one model). Name the agent after the interest.`
  : `This is one specific thing: keep the brief tight on exactly what they described (model, size, color, price).`}
Turn it into a brief for a personal shopping agent. Reply with only JSON:
{"name": "a short fun agent name (2-3 words, e.g. Oud Hunter, Grail Scout)",
 "category": one of ${JSON.stringify(CATEGORIES.filter((c) => c !== "other"))} if it clearly fits, else null,
 "custom": if category is null, a short mission like "high-rise apartments in McLean" (else null),
 "keywords": specific things to look for (models, product lines, 0-6 short lowercase terms),
 "makers": brands, houses, makers or dealers they named or clearly imply (0-6),
 "traits": styles, materials, notes, colors, specs they want (0-8 short lowercase terms),
 "creators": designers, perfumers, artists, collaborators (0-4),
 "size": their size if they said one, else "",
 "voice": "hype" for streetwear and sneakers, "straight" for cars and big purchases, else "chill",
 "intro": one friendly sentence in the agent's voice saying what it will hunt, e.g. "I'm on it: oud-heavy niche fragrances in the Frederic Malle lane.",
 "avoid": things they said they don't want (0-4 short lowercase terms, e.g. "nothing too sweet" -> "sweet"), else []}
Use only what they said or clearly implied. Keep every list item short (1-4 words).${langOf(body.lang) ? `
Write "name" and "intro" in ${langOf(body.lang)}. Keep keywords, makers, traits and creators in English: they're search terms.` : ""}` }],
  });
  const plan = cleanPlan(parseJSON(textOf(res.content)), text, body.size, focus);
  if (isAdultText(plan.name, plan.custom, plan.keywords, plan.makers, plan.traits, plan.creators)) throw new HttpError(400, ADULT_REFUSAL);

  const id = await insertAgent(user.id, plan);
  await introNotes(user.id, [{ agent_id: id, name: plan.name, intro: plan.intro }]);
  return json({ agent_id: id, ...plan, needs_size: needsSize(plan) });
});
