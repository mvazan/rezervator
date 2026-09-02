import { assertEquals } from "jsr:@std/assert@1";
import { dayLabel, escapeHtml, timeLabel } from "./format.ts";

Deno.test("escapeHtml escapes & < > \" and leaves ' alone", () => {
  assertEquals(
    escapeHtml(`Tom & Jerry <b>"quoted"</b> it's`),
    "Tom &amp; Jerry &lt;b&gt;&quot;quoted&quot;&lt;/b&gt; it's",
  );
});

Deno.test("escapeHtml leaves plain text untouched", () => {
  const when = "po 13.7. 17:30–18:30, dráha 2";
  assertEquals(escapeHtml(when), when);
});

Deno.test("dayLabel: 2026-07-13 is a Monday", () => {
  assertEquals(dayLabel("2026-07-13"), "po 13.7.");
});

Deno.test("dayLabel: Sunday in December, no zero padding", () => {
  assertEquals(dayLabel("2026-12-06"), "ne 6.12.");
});

Deno.test("timeLabel strips seconds", () => {
  assertEquals(timeLabel("17:30:00"), "17:30");
});

Deno.test("timeLabel drops the leading zero of the hour only", () => {
  assertEquals(timeLabel("09:05"), "9:05");
});
