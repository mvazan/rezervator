import { assertEquals } from "jsr:@std/assert@1";
import {
  pragueEpoch,
  pragueToday,
  signCancelToken,
  verifyCancelToken,
} from "./cancel_token.ts";

const SECRET = "test-secret";
const RID = "3f6b0a4e-1c2d-4e5f-8a9b-0c1d2e3f4a5b";

function nowSeconds(): number {
  return Math.floor(Date.now() / 1000);
}

Deno.test("sign → verify roundtrip returns the rid", async () => {
  const token = await signCancelToken(RID, nowSeconds() + 3600, SECRET);
  assertEquals(await verifyCancelToken(token, SECRET), { rid: RID });
});

Deno.test("tampered signature is invalid", async () => {
  const token = await signCancelToken(RID, nowSeconds() + 3600, SECRET);
  const [payload, signature] = token.split(".");
  const flipped = (signature[0] === "A" ? "B" : "A") + signature.slice(1);
  assertEquals(
    await verifyCancelToken(`${payload}.${flipped}`, SECRET),
    { error: "invalid" },
  );
});

Deno.test("different secret is invalid", async () => {
  const token = await signCancelToken(RID, nowSeconds() + 3600, SECRET);
  assertEquals(await verifyCancelToken(token, "other-secret"), {
    error: "invalid",
  });
});

Deno.test("exp in the past is expired", async () => {
  const token = await signCancelToken(RID, nowSeconds() - 60, SECRET);
  assertEquals(await verifyCancelToken(token, SECRET), { error: "expired" });
});

Deno.test("garbage token is invalid", async () => {
  assertEquals(await verifyCancelToken("abc", SECRET), { error: "invalid" });
  assertEquals(await verifyCancelToken("abc.def", SECRET), { error: "invalid" });
  assertEquals(await verifyCancelToken("", SECRET), { error: "invalid" });
});

Deno.test("pragueEpoch: summer time is CEST (UTC+2)", () => {
  assertEquals(
    pragueEpoch("2026-07-13", "17:30"),
    Date.UTC(2026, 6, 13, 15, 30) / 1000,
  );
});

Deno.test("pragueEpoch: winter time is CET (UTC+1)", () => {
  assertEquals(
    pragueEpoch("2026-01-13", "17:30"),
    Date.UTC(2026, 0, 13, 16, 30) / 1000,
  );
});

Deno.test("pragueEpoch accepts SQL time with seconds", () => {
  assertEquals(
    pragueEpoch("2026-07-13", "17:30:00"),
    pragueEpoch("2026-07-13", "17:30"),
  );
});

// calendar-manage decides which of a dropped team's matches are still to
// come by today's date; between midnight and 02:00 Prague (01:00 in winter)
// the UTC date is still yesterday.
Deno.test("pragueToday is the Prague date, not the UTC one, after midnight", () => {
  assertEquals(pragueToday(new Date("2026-09-25T22:30:00Z")), "2026-09-26");
  assertEquals(pragueToday(new Date("2026-12-12T23:30:00Z")), "2026-12-13");
  assertEquals(pragueToday(new Date("2026-09-26T10:00:00Z")), "2026-09-26");
});
