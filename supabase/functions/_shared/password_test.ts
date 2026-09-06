import { assert, assertEquals, assertMatch } from "jsr:@std/assert";

import { newKioskPassword } from "./password.ts";

Deno.test("shape: four groups of four, dash separated", () => {
  assertMatch(newKioskPassword(), /^[a-z0-9]{4}-[a-z0-9]{4}-[a-z0-9]{4}-[a-z0-9]{4}$/);
});

Deno.test("no look-alike characters — it gets typed on a tablet", () => {
  const chars = new Set(
    Array.from({ length: 200 }, () => newKioskPassword()).join("").split(""),
  );
  for (const banned of ["0", "o", "1", "l", "i", "5", "s", "2", "z"]) {
    assert(!chars.has(banned), `password may not contain ${banned}`);
  }
});

Deno.test("bytes outside the unbiased range are rejected, not folded", () => {
  // 250 is past the rejection limit (256 - 256 % 26 = 234): it must be
  // skipped, so the password is built from the 3s that follow.
  const bytes = [250, 3];
  let i = 0;
  const password = newKioskPassword((n) =>
    Uint8Array.from({ length: n }, () => bytes[i++ % bytes.length])
  );
  assertEquals(password.replaceAll("-", "").split("").every((c) => c === "d"), true);
});

Deno.test("two passwords in a row differ", () => {
  assert(newKioskPassword() !== newKioskPassword());
});
