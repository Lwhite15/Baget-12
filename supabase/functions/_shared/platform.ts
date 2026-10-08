// Small, dependency-free helpers for Supabase edge functions: config, database REST, auth, Claude, JSON responses.
// Uses only web-standard APIs, so the same code runs on Supabase (Deno) and in local tests (Node).

// deno-lint-ignore no-explicit-any
const g = globalThis as any;
export function env(name: string): string | undefined {
  return g.Deno?.env?.get?.(name) ?? g.process?.env?.[name];
}

export const SUPABASE_URL = () => (env("SUPABASE_URL") ?? "").replace(/\/$/, "");

/** Server key: the legacy service_role JWT if present, otherwise the first new-style secret key. */
export function serviceKey(): string {
  const legacy = env("SUPABASE_SERVICE_ROLE_KEY");
  if (legacy) return legacy;
  const keys = env("SUPABASE_SECRET_KEYS");
  if (keys) {
    try {
      const parsed = JSON.parse(keys);
      const first = typeof parsed === "string" ? parsed : Object.values(parsed)[0];
      if (typeof first === "string") return first;
    } catch { /* fall through */ }
  }
  throw new Error("No Supabase server key in the environment");
}

function serverHeaders(extra: Record<string, string> = {}): Record<string, string> {
  const key = serviceKey();
  const h: Record<string, string> = { apikey: key, "Content-Type": "application/json", ...extra };
  // Legacy keys are JWTs and go in Authorization too; new sb_secret_ keys go in apikey only.
  if (key.startsWith("eyJ")) h.Authorization = `Bearer ${key}`;
  return h;
}

export class HttpError extends Error {
  status: number;
  /** The technical reason, kept for the error log; `message` is what people see. */
  detail?: string;
  constructor(status: number, message: string, detail?: string) {
    super(message);
    this.status = status;
    this.detail = detail;
  }
}

/** Server errors go to public.function_errors (server-only table) so they can be diagnosed later. */
async function logError(req: Request, status: number, message: string) {
  try {
    const fn = new URL(req.url).pathname.split("/").filter(Boolean).pop() ?? "?";
    await fetch(`${SUPABASE_URL()}/rest/v1/function_errors`, {
      method: "POST", headers: serverHeaders({ Prefer: "return=minimal" }),
      body: JSON.stringify({ fn: fn.slice(0, 40), status, message: message.slice(0, 1000) }),
    });
  } catch { /* logging must never break a response */ }
}

/** Database access as the server (bypasses row level security, so every query must filter by user itself). */
export const db = {
  async rpc<T = unknown>(fn: string, args: Record<string, unknown>): Promise<T> {
    const r = await fetch(`${SUPABASE_URL()}/rest/v1/rpc/${fn}`, { method: "POST", headers: serverHeaders(), body: JSON.stringify(args) });
    if (!r.ok) throw new HttpError(502, `rpc ${fn} failed: ${r.status} ${await r.text()}`);
    const text = await r.text();
    return (text ? JSON.parse(text) : null) as T;
  },
  async select<T = unknown>(table: string, query: string): Promise<T[]> {
    const r = await fetch(`${SUPABASE_URL()}/rest/v1/${table}?${query}`, { headers: serverHeaders() });
    if (!r.ok) throw new HttpError(502, `select ${table} failed: ${r.status} ${await r.text()}`);
    return await r.json() as T[];
  },
  async insert<T = unknown>(table: string, rows: unknown, returning = true): Promise<T[]> {
    const r = await fetch(`${SUPABASE_URL()}/rest/v1/${table}`, {
      method: "POST",
      headers: serverHeaders({ Prefer: returning ? "return=representation" : "return=minimal" }),
      body: JSON.stringify(rows),
    });
    if (!r.ok) throw new HttpError(502, `insert ${table} failed: ${r.status} ${await r.text()}`);
    return returning ? await r.json() as T[] : [];
  },
  async update(table: string, query: string, patch: unknown): Promise<void> {
    const r = await fetch(`${SUPABASE_URL()}/rest/v1/${table}?${query}`, {
      method: "PATCH", headers: serverHeaders({ Prefer: "return=minimal" }), body: JSON.stringify(patch),
    });
    if (!r.ok) throw new HttpError(502, `update ${table} failed: ${r.status} ${await r.text()}`);
  },
  async remove(table: string, query: string): Promise<void> {
    const r = await fetch(`${SUPABASE_URL()}/rest/v1/${table}?${query}`, { method: "DELETE", headers: serverHeaders({ Prefer: "return=minimal" }) });
    if (!r.ok) throw new HttpError(502, `delete ${table} failed: ${r.status} ${await r.text()}`);
  },
  /** Raw call to another Supabase service (auth admin, storage) with the server key. */
  async raw(path: string, init: RequestInit = {}): Promise<Response> {
    return await fetch(`${SUPABASE_URL()}${path}`, { ...init, headers: { ...serverHeaders(), ...(init.headers as Record<string, string> ?? {}) } });
  },
};

export const enc = encodeURIComponent;

/** The signed-in user making this request, verified with Supabase Auth. */
export async function requireUser(req: Request): Promise<{ id: string; token: string }> {
  const auth = req.headers.get("authorization") ?? "";
  const token = auth.replace(/^Bearer\s+/i, "");
  if (!token || token.startsWith("sb_")) throw new HttpError(401, "Sign in required");
  const r = await fetch(`${SUPABASE_URL()}/auth/v1/user`, { headers: { apikey: serviceKey(), Authorization: `Bearer ${token}` } });
  if (!r.ok) throw new HttpError(401, "Your session expired. Sign in again.");
  const u = await r.json();
  if (!u?.id) throw new HttpError(401, "Sign in required");
  return { id: u.id, token };
}

/** Scheduler and database-trigger calls carry a shared secret. */
export function isScheduler(req: Request): boolean {
  const want = env("BAGET_CRON_SECRET");
  const got = req.headers.get("x-baget-secret");
  if (!want || !got || want.length !== got.length) return false;
  let diff = 0;
  for (let i = 0; i < want.length; i++) diff |= want.charCodeAt(i) ^ got.charCodeAt(i);
  return diff === 0;
}

export function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });
}

/** Wraps a handler: method check, JSON errors, no stack traces leaked to clients. */
export function handle(fn: (req: Request) => Promise<Response>) {
  return async (req: Request): Promise<Response> => {
    if (req.method !== "POST") return json({ error: "Use POST" }, 405);
    try {
      return await fn(req);
    } catch (e) {
      if (e instanceof HttpError) {
        if (e.status >= 500) await logError(req, e.status, e.detail ?? e.message);
        return json({ error: e.message }, e.status);
      }
      console.error(e);
      await logError(req, 500, String((e as Error)?.stack ?? (e as Error)?.message ?? e));
      // Internal callers (the scheduler, the database, the deploy) get the real reason; people never do.
      const internal = isScheduler(req);
      return json({ error: "Something went wrong on our side. Try again in a minute.",
                    ...(internal ? { detail: String((e as Error)?.message ?? e).slice(0, 300) } : {}) }, 500);
    }
  };
}

// ── Claude ─────────────────────────────────────────────────────────────────────

export const MODEL = () => env("ANTHROPIC_MODEL") ?? "claude-sonnet-5-5";

// deno-lint-ignore no-explicit-any
export type Block = Record<string, any>;
export interface ClaudeMessage { role: "user" | "assistant"; content: string | Block[] }
export interface ClaudeResponse {
  content: Block[];
  stop_reason: string;
  usage?: { input_tokens?: number; output_tokens?: number; server_tool_use?: { web_search_requests?: number } };
}

export async function claude(body: Record<string, unknown>): Promise<ClaudeResponse> {
  const key = env("ANTHROPIC_API_KEY");
  if (!key) throw new HttpError(503, "The agents aren't connected to Claude yet (no API key on the server).");
  const payload = JSON.stringify({ model: MODEL(), ...body });
  // Claude is occasionally busy or briefly unavailable: retry twice with a short wait before giving up.
  let last = "";
  for (let attempt = 0; attempt < 3; attempt++) {
    if (attempt) await new Promise((r) => setTimeout(r, attempt === 1 ? 1500 : 4000));
    let r: Response;
    try {
      r = await fetch("https://api.anthropic.com/v1/messages", {
        method: "POST",
        headers: { "x-api-key": key, "anthropic-version": "2023-06-01", "content-type": "application/json" },
        body: payload,
      });
    } catch (e) {
      last = `network: ${(e as Error).message}`;
      continue;
    }
    if (r.ok) return await r.json() as ClaudeResponse;
    last = `${r.status} ${(await r.text()).slice(0, 600)}`;
    if (![408, 429, 500, 502, 503, 504, 529].includes(r.status)) break;   // a real request problem: retrying won't help
  }
  if (/^(429|529)/.test(last)) throw new HttpError(503, "Claude is busy right now. Try again in a minute.", `Claude ${last}`);
  if (/API key|authentication|401/.test(last)) throw new HttpError(503, "The agents can't reach Claude (API key problem).", `Claude ${last}`);
  if (/credit|billing|balance/i.test(last)) throw new HttpError(503, "The agents are out of Claude credit. Add credit at console.anthropic.com.", `Claude ${last}`);
  throw new HttpError(502, "Your agent couldn't reach Claude just now. Try again in a moment.", `Claude ${last}`);
}

export function textOf(content: Block[]): string {
  return content.filter((b) => b.type === "text").map((b) => b.text as string).join("").trim();
}

/** Pulls one JSON value out of a reply: a ```json fence, the whole reply, or the outermost {...}/[...]. */
export function parseJSON<T = unknown>(text: string): T | null {
  const fence = text.match(/```(?:json)?\s*([\s\S]*?)```/);
  const candidates = [fence?.[1], text];
  const i = Math.min(...["{", "["].map((c) => text.indexOf(c)).filter((n) => n >= 0));
  const j = Math.max(text.lastIndexOf("}"), text.lastIndexOf("]"));
  if (Number.isFinite(i) && j > i) candidates.push(text.slice(i, j + 1));
  for (const c of candidates) {
    if (!c) continue;
    try { return JSON.parse(c.trim()) as T; } catch { /* next */ }
  }
  return null;
}
