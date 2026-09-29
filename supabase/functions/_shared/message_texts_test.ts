import { assertEquals } from "jsr:@std/assert@1";
import {
  adminToStaffMessageText,
  appMessageUrl,
  appNoticeUrl,
  cutOnWord,
  messageContext,
  messageEmailHtml,
  noticeEmailHtml,
  noticeText,
  playerMessageText,
  reactionText,
  staffMessageText,
} from "./message_texts.ts";

Deno.test("messageContext: block, day, training-context and none", () => {
  assertEquals(
    messageContext({ audience: "block", onDate: "2026-10-02", blockStart: "16:00", blockEnd: "17:00" }),
    "pá 2. 10. · 16:00–17:00",
  );
  assertEquals(
    messageContext({ audience: "day", onDate: "2026-10-02", blockStart: null, blockEnd: null }),
    "celý den pá 2. 10.",
  );
  assertEquals(
    messageContext({ audience: "duty", onDate: "2026-10-05", blockStart: "18:00", blockEnd: "19:00" }),
    "k tréninku po 5. 10. · 18:00–19:00",
  );
  assertEquals(
    messageContext({ audience: "admins", onDate: null, blockStart: null, blockEnd: null }),
    null,
  );
  assertEquals(
    messageContext({ audience: "all", onDate: null, blockStart: null, blockEnd: null }),
    null,
  );
});

Deno.test("cutOnWord: short text passes through, long text cuts on a word within max", () => {
  assertEquals(cutOnWord("Krátký text.", 120), "Krátký text.");
  const long = "Slovo ".repeat(30).trim();
  assertEquals(cutOnWord(long, 20), "Slovo Slovo Slovo");
  // The cut lands right before a space: the last word is whole, keep it.
  assertEquals(cutOnWord("aa bb cc", 5), "aa bb");
  // A line break is a word boundary too.
  assertEquals(cutOnWord("Nové dráhy\nzítra", 13), "Nové dráhy");
});

Deno.test("cutOnWord: no whitespace to break on — hard cut, never half an emoji", () => {
  assertEquals(cutOnWord("A".repeat(200), 120), "A".repeat(120));
  // "🎳" is two UTF-16 units; the 120th unit is the first half of one.
  const cut = cutOnWord("Hurá!" + "🎳".repeat(60) + " Díky všem.", 120);
  assertEquals(cut, "Hurá!" + "🎳".repeat(57));
  assertEquals(cut.isWellFormed(), true);
});

Deno.test("noticeText: title as given, body cut to 120 chars", () => {
  const long = "A".repeat(200);
  const t = noticeText("Nové dráhy", long);
  assertEquals(t.title, "Nové dráhy");
  assertEquals(t.body.length <= 120, true);
  const emoji = noticeText("Vyhráli jsme", "Hurá!" + "🎳".repeat(60) + " Díky všem.");
  assertEquals(emoji.body.isWellFormed(), true);
});

Deno.test("staffMessageText: admin vs duty title, context appended", () => {
  assertEquals(
    staffMessageText("Přijďte dřív.", { fromAdmin: true, context: "pá 2. 10. · 16:00–17:00" }),
    { title: "Zpráva od správce", body: "Přijďte dřív.\npá 2. 10. · 16:00–17:00" },
  );
  assertEquals(
    staffMessageText("Meškám.", { fromAdmin: false, context: null }),
    { title: "Zpráva od služby", body: "Meškám." },
  );
});

Deno.test("playerMessageText: names the author, context optional", () => {
  assertEquals(
    playerMessageText("Petr Novák", "Přijdu později.", "k tréninku ne 5. 10. · 18:00–19:00"),
    {
      title: "Zpráva od hráče: Petr Novák",
      body: "Přijdu později.\nk tréninku ne 5. 10. · 18:00–19:00",
    },
  );
  assertEquals(
    playerMessageText("Petr Novák", "Ahoj.", null),
    { title: "Zpráva od hráče: Petr Novák", body: "Ahoj." },
  );
});

Deno.test("adminToStaffMessageText: names the admin as the tile does, context optional", () => {
  // An admin writing to „Správci“ / „Službě“: the app's „Od správce (…)“
  // header, as a title.
  assertEquals(
    adminToStaffMessageText("Adam Správce", "Zítra zavřeno.", "k tréninku ne 5. 10. · 18:00–19:00"),
    {
      title: "Zpráva od správce (Adam Správce)",
      body: "Zítra zavřeno.\nk tréninku ne 5. 10. · 18:00–19:00",
    },
  );
  assertEquals(
    adminToStaffMessageText("Adam Správce", "Ahoj.", null),
    { title: "Zpráva od správce (Adam Správce)", body: "Ahoj." },
  );
});

Deno.test("reactionText: reaction and optional reply, or a reply alone", () => {
  assertEquals(
    reactionText("Petr Novák", "up", "Přijdu dřív."),
    { title: "Reakce na tvou zprávu", body: "Petr Novák: 👍 Přijdu dřív." },
  );
  assertEquals(
    reactionText("Petr Novák", "down", null),
    { title: "Reakce na tvou zprávu", body: "Petr Novák: 👎" },
  );
  assertEquals(
    reactionText("Petr Novák", null, "Přijdu dřív."),
    { title: "Reakce na tvou zprávu", body: "Petr Novák: Přijdu dřív." },
  );
});

Deno.test("app links point at the hash routes", () => {
  assertEquals(appMessageUrl("abc"), "https://rezervator.online/#/zpravy/abc");
  assertEquals(appNoticeUrl("abc"), "https://rezervator.online/#/nastenka/abc");
});

Deno.test("messageEmailHtml escapes the body, keeps its context line once, embeds both react links", () => {
  const html = messageEmailHtml(
    { title: "Zpráva od správce", body: "Přijďte <dřív>.\npá 2. 10." },
    { upLink: "https://x/react?t=1", downLink: "https://x/react?t=2",
      appLink: "https://rezervator.online/#/zpravy/abc" },
  );
  assertEquals(html.includes("&lt;dřív&gt;"), true);
  assertEquals(html.split("pá 2. 10.").length, 2);
  assertEquals(html.includes("https://x/react?t=1"), true);
  assertEquals(html.includes("https://x/react?t=2"), true);
  assertEquals(html.includes("https://rezervator.online/#/zpravy/abc"), true);
});

Deno.test("noticeEmailHtml links to the board", () => {
  const html = noticeEmailHtml("Nové dráhy", "Od pondělí.", "https://rezervator.online/#/nastenka/abc");
  assertEquals(html.includes("Nové dráhy"), true);
  assertEquals(html.includes("https://rezervator.online/#/nastenka/abc"), true);
});
