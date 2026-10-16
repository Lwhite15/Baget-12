// Verifies data signed by the App Store (StoreKit 2 transactions and App Store Server Notifications V2).
// A signed item is a JWS whose header carries Apple's certificate chain (x5c). It's genuine only if:
//   the chain ends at Apple Root CA - G3 (pinned by fingerprint), each certificate is signed by the next,
//   the certificates carry Apple's App Store receipt-signing markers, and the leaf key signed the data.
// Deno only (uses an npm package); the edge function wires it in, tests inject a fake.
import * as x509 from "npm:@peculiar/x509@1.12.3";

const APPLE_ROOT_G3_SHA256 = "63343abfb89a6a03ebb57e9b3f5fa7be7c4f5c756f3017b3a8c488c3653e9179";
const LEAF_OID = "1.2.840.113635.100.6.11.1";
const INTERMEDIATE_OID = "1.2.840.113635.100.6.2.1";

x509.cryptoProvider.set(crypto);

function b64url(s: string): Uint8Array {
  const b = s.replace(/-/g, "+").replace(/_/g, "/") + "===".slice((s.length + 3) % 4);
  return Uint8Array.from(atob(b), (c) => c.charCodeAt(0));
}
const hex = (buf: ArrayBuffer) => [...new Uint8Array(buf)].map((x) => x.toString(16).padStart(2, "0")).join("");

export async function verifyAppleJWS(jws: string): Promise<Record<string, unknown>> {
  const parts = jws.split(".");
  if (parts.length !== 3) throw new Error("not a JWS");
  const header = JSON.parse(new TextDecoder().decode(b64url(parts[0])));
  if (header.alg !== "ES256" || !Array.isArray(header.x5c) || header.x5c.length < 3) throw new Error("unexpected JWS header");
  const [leaf, inter, root] = header.x5c.slice(0, 3).map((c: string) => new x509.X509Certificate(c));
  const thumb = hex(await root.getThumbprint("SHA-256", crypto));
  if (thumb !== APPLE_ROOT_G3_SHA256) throw new Error("not signed by Apple");
  if (!(await root.verify({ publicKey: root.publicKey, signatureOnly: true }, crypto))) throw new Error("bad root");
  if (!(await inter.verify({ publicKey: root.publicKey, signatureOnly: true }, crypto))) throw new Error("bad intermediate");
  if (!(await leaf.verify({ publicKey: inter.publicKey, signatureOnly: true }, crypto))) throw new Error("bad leaf");
  if (!inter.getExtension(INTERMEDIATE_OID) || !leaf.getExtension(LEAF_OID)) throw new Error("not an App Store signing certificate");
  const key = await leaf.publicKey.export({ name: "ECDSA", namedCurve: "P-256" }, ["verify"], crypto);
  const ok = await crypto.subtle.verify({ name: "ECDSA", hash: "SHA-256" }, key, b64url(parts[2]), new TextEncoder().encode(`${parts[0]}.${parts[1]}`));
  if (!ok) throw new Error("bad signature");
  return JSON.parse(new TextDecoder().decode(b64url(parts[1])));
}
