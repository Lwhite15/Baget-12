// "What are you hunting?" One sentence in, a ready agent out.
// Claude turns the sentence into a brief (mission, brands, styles, keywords, size) and the agent is created for the person.
import { CATEGORIES } from "../_shared/match.ts";
import { HttpError, claude, db, handle, json, parseJSON, requireUser, textOf } from "../_shared/platform.ts";

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
}

const strs = (v: unknown, n: number, lower = false) =>
  Array.isArray(v) ? v.filter((x) => typeof x === "string").map((x) => (x as string).trim()).filter((x) => x && x.length <= 40)
    .map((x) => (lower ? x.toLowerCase() : x)).slice(0, n) : [];

/** Validates Claude's plan so only sane values reach the database. */
export function cleanPlan(raw: unknown, text: string, size?: string): Plan {
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
 "intro": one friendly sentence in the agent's voice saying what it will hunt}`;

type Img = { media_type: string; data: string };
const IMG_TYPES = ["image/jpeg", "image/png", "image/webp"];

async function insertAgent(userId: string, plan: Plan): Promise<string> {
  const row: Record<string, unknown> = {
    user_id: userId, name: plan.name, keywords: plan.keywords, traits: plan.traits, makers: plan.makers,
    creators: plan.creators, size: plan.size, voice: plan.voice, mode: "ask",
    ...(plan.category ? { mission_category: plan.category } : { mission_custom: plan.custom }),
  };
  try {
    const created = await db.insert<{ id: string }>("agents", row);
    return created[0].id;
  } catch (e) {
    if (/agent_limit|12 agents/i.test((e as Error).message)) throw new HttpError(409, "A squad can have up to 12 agents. Retire one to add another.");
    throw e;
  }
}

const needsSize = (p: Plan) => (p.category === "sneakers" || p.category === "apparel") && !p.size;

/** Onboarding: a few categories, an optional sentence and up to 3 photos -> one agent per category, tuned to the photos. */
async function onboard(userId: string, categories: string[], text: string, size: string | undefined, images: Img[]) {
  const cats = [...new Set(categories.filter((c) => (CATEGORIES as string[]).includes(c) && c !== "other"))].slice(0, 6);
  if (!cats.length && !text) throw new HttpError(400, "Pick at least one thing you're into");
  const content: Record<string, unknown>[] = images.map((im) => ({ type: "image", source: { type: "base64", media_type: im.media_type, data: im.data } }));
  content.push({ type: "text", text: `Someone is setting up their shopping scout app.
They picked these interests: ${cats.length ? cats.join(", ") : "(none)"}.
${text ? `They also said: "${text}".` : ""}
${images.length ? `The ${images.length === 1 ? "photo shows" : `${images.length} photos show`} things they love. Read their taste from them (brands, styles, materials, colors, eras) and use it in the briefs where it fits.` : ""}
Make one agent brief per picked interest${text && !cats.length ? " (or one for what they said)" : ""}${text && cats.length ? ", plus one more if what they said is a separate hunt" : ""}.
Reply with only JSON: {"agents": [${BRIEF_FIELDS}, ...]}
Use only what they said, picked or showed. Keep every list item short (1-4 words).` });
  const res = await claude({ max_tokens: 6000, messages: [{ role: "user", content }] });
  const raw = (parseJSON<{ agents?: unknown[] }>(textOf(res.content))?.agents ?? []).slice(0, 7);
  const plans = raw.map((r) => cleanPlan(r, text || "Anything I'd love", size));
  // Make sure every picked category got an agent, even if Claude skipped one.
  for (const c of cats) if (!plans.some((p) => p.category === c)) plans.push(cleanPlan({ category: c, name: `${c[0].toUpperCase()}${c.slice(1)} Scout` }, c, size));
  const agents = [];
  for (const p of plans) {
    const id = await insertAgent(userId, p);
    agents.push({ agent_id: id, ...p, needs_size: needsSize(p) });
  }
  return { agents };
}

export const handler = handle(async (req) => {
  const user = await requireUser(req);
  const body = await req.json().catch(() => ({})) as { text?: string; size?: string; categories?: string[]; images?: Img[] };
  const text = (body.text ?? "").trim().slice(0, 300);
  if (Array.isArray(body.categories)) {
    const images = (Array.isArray(body.images) ? body.images : [])
      .filter((im) => im && IMG_TYPES.includes(im.media_type) && typeof im.data === "string" && im.data.length < 2_000_000).slice(0, 3);
    return json(await onboard(user.id, body.categories, text, body.size, images));
  }
  if (text.length < 2) throw new HttpError(400, "Tell me what to hunt for");

  const res = await claude({
    max_tokens: 4000,
    messages: [{ role: "user", content: `Someone told their shopping scout app what they want: "${text}"

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
 "intro": one friendly sentence in the agent's voice saying what it will hunt, e.g. "I'm on it: oud-heavy niche fragrances in the Frederic Malle lane."}
Use only what they said or clearly implied. Keep every list item short (1-4 words).` }],
  });
  const plan = cleanPlan(parseJSON(textOf(res.content)), text, body.size);

  const id = await insertAgent(user.id, plan);
  return json({ agent_id: id, ...plan, needs_size: needsSize(plan) });
});
