import { assertEquals } from "jsr:@std/assert@1";
import {
  groupBookedMessage,
  groupCancelledMessage,
  groupInviteMessage,
  groupJoinedMessage,
} from "./group_messages.ts";

Deno.test("invite names who invites and where to accept", () => {
  assertEquals(groupInviteMessage("Petr"), {
    title: "Pozvánka do skupiny",
    body: "Petr tě zve do skupiny — přijmi ji v Můj profil.",
  });
});

Deno.test("a new member is announced by name", () => {
  assertEquals(groupJoinedMessage("Jana"), {
    title: "Nový člen skupiny",
    body: "Jana je teď ve skupině.",
  });
});

Deno.test("booking and cancelling say who did it and when", () => {
  const when = "čt 24.9. 17:30–18:30, dráha 2";
  assertEquals(groupBookedMessage("Petr", when), {
    title: "Trénink zarezervován",
    body: "Petr ti zarezervoval(a) trénink: čt 24.9. 17:30–18:30, dráha 2.",
  });
  assertEquals(groupCancelledMessage("Petr", when), {
    title: "Trénink zrušen",
    body: "Petr ti zrušil(a) trénink: čt 24.9. 17:30–18:30, dráha 2.",
  });
});
