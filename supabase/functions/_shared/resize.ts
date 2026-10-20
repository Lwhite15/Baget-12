// Shrinks product photos before they're stored: longest side 1000 px, JPEG quality 80 (PNG stays PNG so cut-out
// transparency survives). Server only (the edge runtime); the tests run without it and store photos unchanged.
import { decode, Image } from "https://deno.land/x/imagescript@1.3.0/mod.ts";

const MAX = 1000;

export async function shrink(bytes: Uint8Array, type: string): Promise<{ bytes: Uint8Array; type: string } | null> {
  const img = await decode(bytes);
  if (!(img instanceof Image)) return null;   // animated GIFs and the like stay as they are
  const long = Math.max(img.width, img.height);
  if (long > MAX) {
    if (img.width >= img.height) img.resize(MAX, Image.RESIZE_AUTO);
    else img.resize(Image.RESIZE_AUTO, MAX);
  }
  if (type === "image/png") return { bytes: await img.encode(2), type: "image/png" };
  return { bytes: await img.encodeJPEG(80), type: "image/jpeg" };
}
