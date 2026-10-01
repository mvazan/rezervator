import { assertEquals } from "jsr:@std/assert@1";
import { freedSpotMessage } from "./freed_spot.ts";

Deno.test("freedSpotMessage names the spot and says to book it", () => {
  assertEquals(freedSpotMessage("st 8.10. 17:00–18:00, dráha 2"), {
    title: "Uvolnilo se místo 🎳",
    body: "st 8.10. 17:00–18:00, dráha 2 — zarezervuj si ho, dokud je volné.",
  });
});
