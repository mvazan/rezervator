import { assertEquals } from "jsr:@std/assert@1";
import { REACT_TOKEN_DAYS, signReactToken, verifyReactToken } from "./react_token.ts";

const SECRET = "test-secret";
const MSG = "3f6b0a4e-1c2d-4e5f-8a9b-0c1d2e3f4a5b";
const USER = "9a8b7c6d-5e4f-3a2b-1c0d-9e8f7a6b5c4d";

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
