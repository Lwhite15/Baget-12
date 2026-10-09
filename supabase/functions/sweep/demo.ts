// The App Review demo account: an email/password user with a ready squad and real finds, so a reviewer can try everything.
// Called by the "Demo account" workflow with the shared secret. The password never reaches the server in plain text:
// the workflow passes a bcrypt hash, which Supabase Auth stores as is.
import { HttpError, db } from "../_shared/platform.ts";

export const DEMO_USER_ID = "0a99e1e0-5eed-4d3e-8a00-00000000d3e0";

const DEMO_AGENTS = [
  { name: "Sneaker Scout", mission_category: "sneakers", keywords: ["Jordan 1", "New Balance 990", "Nike Dunk"],
    traits: ["retro", "suede", "neutral tones"], makers: ["Nike", "New Balance"], size: "10", voice: "hype" },
  { name: "Scent Hunter", mission_category: "fragrance", keywords: ["niche fragrance", "woody", "citrus"],
    traits: ["fresh", "woody"], makers: ["Le Labo", "Byredo"], size: "", voice: "chill" },
  { name: "Watch Desk", mission_category: "watches", keywords: ["Seiko", "field watch", "dive watch"],
    traits: ["steel", "under 40mm"], makers: ["Seiko", "Tudor"], size: "", voice: "straight" },
];

export async function setupDemo(
  email: string,
  passwordHash: string,
  sweep: (userId: string) => Promise<{ swept: number; found: number }>,
) {
  if (!/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(email)) throw new HttpError(400, "Bad demo email");
  if (!/^\$2[aby]\$\d\d\$[./A-Za-z0-9]{53}$/.test(passwordHash)) throw new HttpError(400, "Demo password must be a bcrypt hash");
  const attrs = { email, password_hash: passwordHash, email_confirm: true, user_metadata: { full_name: "App Review" } };

  // Create the user, or reset its email and password if it already exists.
  let r = await db.raw("/auth/v1/admin/users", { method: "POST", body: JSON.stringify({ id: DEMO_USER_ID, ...attrs }) });
  let created = r.ok;
  if (!r.ok) {
    const first = `${r.status} ${(await r.text()).slice(0, 200)}`;
    r = await db.raw(`/auth/v1/admin/users/${DEMO_USER_ID}`, { method: "PUT", body: JSON.stringify(attrs) });
    if (!r.ok) throw new HttpError(502, "Couldn't set up the demo user", `create ${first}; update ${r.status} ${(await r.text()).slice(0, 200)}`);
    created = false;
  } else await r.text();

  await db.update("profiles", `id=eq.${DEMO_USER_ID}`, { display_name: "App Review" });
  const existing = await db.select<{ id: string }>("agents", `select=id&user_id=eq.${DEMO_USER_ID}`);
  if (!existing.length) {
    await db.insert("agents", DEMO_AGENTS.map((a) => ({ ...a, user_id: DEMO_USER_ID, mode: "ask" })), false);
  }
  const finds = await db.select<{ id: string }>("finds", `select=id&user_id=eq.${DEMO_USER_ID}&limit=50`);
  // Only sweep when there's little to show; sweeps cost API credits.
  const run = finds.length < 6 ? await sweep(DEMO_USER_ID) : { swept: 0, found: 0 };
  const after = run.swept ? (await db.select<{ id: string }>("finds", `select=id&user_id=eq.${DEMO_USER_ID}&limit=200`)).length : finds.length;
  return { user_created: created, agents: existing.length || DEMO_AGENTS.length, swept: run.swept, finds: after };
}
