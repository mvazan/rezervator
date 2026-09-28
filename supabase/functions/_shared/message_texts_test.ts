import { assertEquals } from "jsr:@std/assert@1";
import {
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
  const cut = cutOnWord(long, 20);
  assertEquals(cut.length <= 20, true);
  assertEquals(long.startsWith(cut), true);
  assertEquals(cut.endsWith(" "), false);
});

Deno.test("noticeText: title as given, body cut to 120 chars", () => {
  const long = "A".repeat(200);
  const t = noticeText("Nové dráhy", long);
  assertEquals(t.title, "Nové dráhy");
  assertEquals(t.body.length <= 120, true);
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
      title: "Zpráva od Petr Novák",
      body: "Přijdu později.\nk tréninku ne 5. 10. · 18:00–19:00",
    },
  );
  assertEquals(
    playerMessageText("Petr Novák", "Ahoj.", null),
    { title: "Zpráva od Petr Novák", body: "Ahoj." },
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
