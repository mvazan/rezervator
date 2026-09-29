import { assertEquals } from "jsr:@std/assert@1";
import { base64urlEncode, signCancelToken } from "./cancel_token.ts";
import { REACT_TOKEN_DAYS, signReactToken, verifyReactToken } from "./react_token.ts";

const SECRET = "test-secret";
const MSG = "3f6b0a4e-1c2d-4e5f-8a9b-0c1d2e3f4a5b";
const USER = "9a8b7c6d-5e4f-3a2b-1c0d-9e8f7a6b5c4d";
const OTHER_USER = "1b2c3d4e-5f6a-4b7c-8d9e-0f1a2b3c4d5e";

Deno.test("sign -> verify roundtrip returns the payload", async () => {
  const token = await signReactToken({ m: MSG, u: USER, r: "up" }, SECRET);
  assertEquals(await verifyReactToken(token, SECRET), { m: MSG, u: USER, r: "up" });
});

Deno.test("tampered signature is invalid", async () => {
  const token = await signReactToken({ m: MSG, u: USER, r: "down" }, SECRET);
  const [payload, signature] = token.split(".");
  const flipped = (signature[0] === "A" ? "B" : "A") + signature.slice(1);
  assertEquals(
    await verifyReactToken(`${payload}.${flipped}`, SECRET),
    { error: "invalid" },
  );
});

// The attack that matters: rewrite who (u), what (m) or how (r) and keep
// the original signature. The signature must cover the payload itself.
Deno.test("tampered payload is invalid", async () => {
  const issuedAt = Date.now();
  const token = await signReactToken({ m: MSG, u: USER, r: "up" }, SECRET, issuedAt);
  const signature = token.split(".")[1];
  const forged = base64urlEncode(
    JSON.stringify({ m: MSG, u: OTHER_USER, r: "down", x: issuedAt }),
  );
  assertEquals(
    await verifyReactToken(`${forged}.${signature}`, SECRET),
    { error: "invalid" },
  );
});

// Both token kinds share the secret and the wire format; a cancel link
// must never pass as a reaction.
Deno.test("a cancel token is not a react token", async () => {
  const cancel = await signCancelToken(MSG, Date.now() + 86400_000, SECRET);
  assertEquals(await verifyReactToken(cancel, SECRET), { error: "invalid" });
});

Deno.test("different secret is invalid", async () => {
  const token = await signReactToken({ m: MSG, u: USER, r: "up" }, SECRET);
  assertEquals(await verifyReactToken(token, "other-secret"), { error: "invalid" });
});

// The clock is injected as a plain epoch-ms number (third parameter of
// verifyReactToken, default Date.now()), so expiry is tested without
// waiting or hand-crafting a signature.
Deno.test("older than REACT_TOKEN_DAYS is expired, younger is not", async () => {
  const issuedAt = Date.now();
  const token = await signReactToken({ m: MSG, u: USER, r: "up" }, SECRET, issuedAt);
  const later = issuedAt + (REACT_TOKEN_DAYS + 1) * 86400_000;
  assertEquals(await verifyReactToken(token, SECRET, later), { error: "expired" });
  assertEquals(
    await verifyReactToken(token, SECRET, issuedAt + (REACT_TOKEN_DAYS - 1) * 86400_000),
    { m: MSG, u: USER, r: "up" },
  );
});

Deno.test("garbage token is invalid", async () => {
  assertEquals(await verifyReactToken("abc", SECRET), { error: "invalid" });
  assertEquals(await verifyReactToken("", SECRET), { error: "invalid" });
});
