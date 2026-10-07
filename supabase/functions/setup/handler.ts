// One-time setup after a deploy: points the database scheduler (sweeps every 15 minutes, morning release hourly)
// and the push trigger at this project. Called by the deploy pipeline with the shared secret.
import { HttpError, SUPABASE_URL, db, env, handle, isScheduler, json } from "../_shared/platform.ts";

export const handler = handle(async (req) => {
  if (!isScheduler(req)) throw new HttpError(401, "Not allowed");
  const result = await db.rpc<string>("configure_scheduler", { p_url: SUPABASE_URL(), p_secret: env("BAGET_CRON_SECRET") });
  return json({ result, claude: !!env("ANTHROPIC_API_KEY"), apns: !!env("APNS_KEY_P8") });
});
