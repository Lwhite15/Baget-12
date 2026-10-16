import { makeHandler } from "./handler.ts";
import { verifyAppleJWS } from "../_shared/appstore_verify.ts";

Deno.serve(makeHandler(verifyAppleJWS));
