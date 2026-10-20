import { setResizer } from "../_shared/images.ts";
import { shrink } from "../_shared/resize.ts";
import { handler } from "./handler.ts";

setResizer(shrink);   // product photos are stored phone-sized
Deno.serve(handler);
