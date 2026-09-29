import { assertEquals, assertStringIncludes } from "jsr:@std/assert@1";
import type { Delivery } from "./delivery.ts";
import {
  deliverDueDutyReminders,
  dutyCancelReason,
  type DueDutyReminder,
  dutyReminderBody,
  dutyReminderHtml,
  dutyReminderReceipt,
  dutyReminderTitle,
} from "./duty_reminders.ts";

// due_duty_reminders (0050) hands the period over as plain dates; the
// lead is the alley's, in whole days.
const base: DueDutyReminder = {
  user_id: "u1",
  email: "hrac@example.com",
  fcm_token: "tok",
  period_id: "p1",
  starts_on: "2026-10-05",
  ends_on: "2026-10-11",
  days: 1,
  co_assignees: [],
};

const at = (iso: string) => new Date(iso);

// --- the title: Prague calendar days until the duty ---------------------

Deno.test("sent at 18:00 the day before, the title says tomorrow", () => {
  // 18:00 CEST on 4. 10. = 16:00Z.
  assertEquals(
    dutyReminderTitle("2026-10-05", at("2026-10-04T16:00:00Z")),
    "Zítra sloužíš na kantýně",
  );
});

Deno.test("two or more days ahead, the title counts them in Czech", () => {
  assertEquals(
    dutyReminderTitle("2026-10-05", at("2026-10-03T16:00:00Z")),
    "Za 2 dny sloužíš na kantýně",
  );
  assertEquals(
    dutyReminderTitle("2026-10-05", at("2026-09-28T16:00:00Z")),
    "Za 7 dnů sloužíš na kantýně",
  );
  // Winter: 18:00 CET = 17:00Z.
  assertEquals(
    dutyReminderTitle("2026-12-07", at("2026-12-05T17:00:00Z")),
    "Za 2 dny sloužíš na kantýně",
  );
});

Deno.test("late, the title counts the Prague days actually left", () => {
  // A week's lead, sent on 3. 10. (notify was down, or the player was
  // assigned inside the lead): two days, not seven.
  assertEquals(
    dutyReminderTitle("2026-10-05", at("2026-10-03T09:00:00Z")),
    "Za 2 dny sloužíš na kantýně",
  );
  // 23:59 Prague on the eve is still tomorrow.
  assertEquals(
    dutyReminderTitle("2026-10-05", at("2026-10-04T21:59:00Z")),
    "Zítra sloužíš na kantýně",
  );
  // 00:30 Prague on 4. 10. is 22:30Z on the 3rd: the Prague date counts,
  // not the UTC one.
  assertEquals(
    dutyReminderTitle("2026-10-05", at("2026-10-03T22:30:00Z")),
    "Zítra sloužíš na kantýně",
  );
});

Deno.test("across a clock change the days are still Prague calendar days", () => {
  // 25. 10. 2026 the clocks go back; a duty from Monday 26. 10.
  assertEquals(
    dutyReminderTitle("2026-10-26", at("2026-10-25T17:00:00Z")),
    "Zítra sloužíš na kantýně",
  );
  // 29. 3. 2026 the clocks go forward; a duty from Tuesday 31. 3.
  assertEquals(
    dutyReminderTitle("2026-03-31", at("2026-03-29T16:00:00Z")),
    "Za 2 dny sloužíš na kantýně",
  );
});

// --- the body: the period, and who serves with you ----------------------

Deno.test("the body is the period, day and month apart as the roster writes them", () => {
  assertEquals(dutyReminderBody(base), "po 5. 10. – ne 11. 10.");
  assertEquals(
    dutyReminderBody({ ...base, starts_on: "2026-12-28", ends_on: "2027-01-03" }),
    "po 28. 12. – ne 3. 1.",
  );
});

Deno.test("a one-day duty names its day once", () => {
  assertEquals(
    dutyReminderBody({ ...base, starts_on: "2026-10-10", ends_on: "2026-10-10" }),
    "so 10. 10.",
  );
});

Deno.test("the others on the duty follow, Czech-alphabetically", () => {
  assertEquals(
    dutyReminderBody({ ...base, co_assignees: ["Jana Nováková"] }),
    "po 5. 10. – ne 11. 10., spolu s: Jana Nováková",
  );
  const names = [
    "Šimon Říha",
    "Jana Nováková",
    "Chrudoš Brabec",
    "Čeněk Hora",
    "Cyril Adam",
    "Hana Malá",
  ];
  assertEquals(
    dutyReminderBody({ ...base, co_assignees: names }),
    "po 5. 10. – ne 11. 10., spolu s: Cyril Adam, Čeněk Hora, Hana Malá, " +
      "Chrudoš Brabec, Jana Nováková, Šimon Říha",
  );
  // The row itself is left as it came.
  assertEquals(names[0], "Šimon Říha");
});

Deno.test("the e-mail adds what the duty may do, escaped", () => {
  const html = dutyReminderHtml({ ...base, co_assignees: ["Jan <Novák>"] });
  assertStringIncludes(
    html,
    "<p>po 5. 10. – ne 11. 10., spolu s: Jan &lt;Novák&gt;</p>",
  );
  assertStringIncludes(
    html,
    "Během služby můžeš rezervovat a rušit tréninky ostatním a upravovat " +
      "bloky v jednotlivých dnech.",
  );
});

// --- the receipt: which duty, which lead, which start -------------------

Deno.test("the receipt is the period, the lead in minutes and Prague midnight "
  + "of the first day", () => {
  assertEquals(dutyReminderReceipt({ ...base, days: 2 }), {
    p_user: "u1",
    p_event_key: "d:p1",
    p_offset: 2880,
    p_starts_at: "2026-10-04T22:00:00.000Z",
  });
  // Winter midnight is an hour later in UTC.
  assertEquals(
    dutyReminderReceipt({ ...base, starts_on: "2026-12-07" }).p_starts_at,
    "2026-12-06T23:00:00.000Z",
  );
  // The days the clocks change: midnight still has the old offset.
  assertEquals(
    dutyReminderReceipt({ ...base, starts_on: "2026-10-25" }).p_starts_at,
    "2026-10-24T22:00:00.000Z",
  );
  assertEquals(
    dutyReminderReceipt({ ...base, starts_on: "2026-03-29" }).p_starts_at,
    "2026-03-28T23:00:00.000Z",
  );
});

// --- delivering: what is marked, what is due again ----------------------

Deno.test("a duty reminder is marked when delivered or undeliverable; a retry "
  + "or a throw leaves it due", async () => {
  const outcome: Record<string, Delivery | "throw"> = {
    p1: "delivered",
    p2: "retry",
    p3: "undeliverable",
    p4: "throw",
  };
  const rows = Object.keys(outcome).map((period_id) => ({ ...base, period_id }));
  const sent: string[] = [];
  const marked: string[] = [];
  const error = console.error;
  console.error = () => {};
  try {
    await deliverDueDutyReminders(
      rows,
      at("2026-10-04T16:00:00Z"),
      (row, title, body) => {
        sent.push(`${row.period_id} ${title} | ${body}`);
        const o = outcome[row.period_id];
        return o === "throw" ? Promise.reject(new Error("network")) : Promise.resolve(o);
      },
      (row) => {
        marked.push(row.period_id);
        return Promise.resolve();
      },
    );
  } finally {
    console.error = error;
  }
  assertEquals(sent, [
    "p1 Zítra sloužíš na kantýně | po 5. 10. – ne 11. 10.",
    "p2 Zítra sloužíš na kantýně | po 5. 10. – ne 11. 10.",
    "p3 Zítra sloužíš na kantýně | po 5. 10. – ne 11. 10.",
    "p4 Zítra sloužíš na kantýně | po 5. 10. – ne 11. 10.",
  ]);
  assertEquals(marked, ["p1", "p3"]);
});

Deno.test("a mark that fails does not stop the others", async () => {
  const marked: string[] = [];
  const error = console.error;
  console.error = () => {};
  try {
    await deliverDueDutyReminders(
      [base, { ...base, user_id: "u2" }, { ...base, user_id: "u3" }],
      at("2026-10-04T16:00:00Z"),
      () => Promise.resolve("delivered"),
      (row) => {
        if (row.user_id === "u2") return Promise.reject(new Error("db"));
        marked.push(row.user_id);
        return Promise.resolve();
      },
    );
  } finally {
    console.error = error;
  }
  assertEquals(marked, ["u1", "u3"]);
});

Deno.test("a duty that began while the tick ran (midnight) is not announced", async () => {
  const sent: string[] = [];
  const marked: string[] = [];
  await deliverDueDutyReminders(
    [base, { ...base, period_id: "p2", starts_on: "2026-10-06" }],
    // 00:00:01 Prague on 5. 10.
    at("2026-10-04T22:00:01Z"),
    (row, title) => {
      sent.push(`${row.period_id} ${title}`);
      return Promise.resolve("delivered");
    },
    (row) => {
      marked.push(row.period_id);
      return Promise.resolve();
    },
  );
  assertEquals(sent, ["p2 Zítra sloužíš na kantýně"]);
  assertEquals(marked, ["p2"]);
});

// --- a training the duty cancelled ---------------------------------------

Deno.test("a duty cancel gives the duty's note, or says who cancelled it", () => {
  assertEquals(
    dutyCancelReason("", "Jan Novák"),
    "zrušil(a) Jan Novák (služba na kantýně)",
  );
  assertEquals(
    dutyCancelReason("   ", "Jan Novák"),
    "zrušil(a) Jan Novák (služba na kantýně)",
  );
  assertEquals(dutyCancelReason("  dráha mimo provoz ", "Jan Novák"), "dráha mimo provoz");
});
