import { assertEquals } from "jsr:@std/assert@1";
import {
  dayLabel,
  escapeHtml,
  leadLabel,
  pragueDateTime,
  timeLabel,
} from "./format.ts";

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

Deno.test("leadLabel: whole days read as days, and tomorrow says so", () => {
  assertEquals(leadLabel(1440), "zítra");
  assertEquals(leadLabel(2880), "za 2 dny");
  assertEquals(leadLabel(7200), "za 5 dnů");
});

Deno.test("leadLabel: hours, with Czech counting three ways", () => {
  assertEquals(leadLabel(60), "za hodinu");
  assertEquals(leadLabel(120), "za 2 hodiny");
  assertEquals(leadLabel(300), "za 5 hodin");
});

Deno.test("leadLabel: anything that is not a whole hour stays in minutes", () => {
  assertEquals(leadLabel(1), "za minutu");
  assertEquals(leadLabel(30), "za 30 minut");
  assertEquals(leadLabel(90), "za 90 minut");
  // 25 hours is not a whole day, but it is whole hours — and "za 25 hodin"
  // is a great deal easier to read than "za 1500 minut".
  assertEquals(leadLabel(1500), "za 25 hodin");
});

Deno.test("leadLabel: no lead time at all is not 'za 0 minut'", () => {
  assertEquals(leadLabel(0), "právě teď");
});

// The database hands an event's start over as an instant, and PostgREST
// writes instants in UTC ("…T14:30:00+00:00"). The text must read Prague
// wall-clock time, summer or winter, and the Prague date around midnight.
Deno.test("pragueDateTime reads a summer instant as CEST (UTC+2)", () => {
  assertEquals(pragueDateTime("2026-09-26T14:30:00+00:00"), {
    date: "2026-09-26",
    time: "16:30",
  });
});

Deno.test("pragueDateTime reads a winter instant as CET (UTC+1)", () => {
  assertEquals(pragueDateTime("2026-12-12T15:30:00+00:00"), {
    date: "2026-12-12",
    time: "16:30",
  });
});

Deno.test("pragueDateTime moves past midnight to the Prague day", () => {
  assertEquals(pragueDateTime("2026-09-26T22:30:00+00:00"), {
    date: "2026-09-27",
    time: "00:30",
  });
});

Deno.test("pragueDateTime follows both clock changes", () => {
  // Spring forward: 29. 3. 2026 at 01:00 UTC, 02:00 CET → 03:00 CEST.
  assertEquals(pragueDateTime("2026-03-29T00:30:00Z").time, "01:30");
  assertEquals(pragueDateTime("2026-03-29T01:30:00Z").time, "03:30");
  // Fall back: 25. 10. 2026 at 01:00 UTC, 03:00 CEST → 02:00 CET.
  assertEquals(pragueDateTime("2026-10-25T00:30:00Z").time, "02:30");
  assertEquals(pragueDateTime("2026-10-25T01:30:00Z").time, "02:30");
});

Deno.test("pragueDateTime reads midnight as 00:00, never 24:00", () => {
  assertEquals(pragueDateTime("2026-09-25T22:00:00+00:00"), {
    date: "2026-09-26",
    time: "00:00",
  });
});

Deno.test("pragueDateTime takes the fractional seconds PostgREST may send", () => {
  assertEquals(pragueDateTime("2026-09-26T14:30:00.123456+00:00").time, "16:30");
});
