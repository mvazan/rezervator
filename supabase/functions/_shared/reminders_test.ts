import { assertEquals } from "jsr:@std/assert@1";
import {
  type DueReminder,
  oneReminderPerEvent,
  reminderBody,
  reminderTitle,
} from "./reminders.ts";

// due_reminders (0040) returns starts_at as an instant, which reaches notify
// in UTC; ends_at is a plain Prague wall-clock time.
const base: DueReminder = {
  user_id: "u1",
  email: "hrac@example.com",
  fcm_token: "tok",
  event_key: "m:1",
  offset_minutes: 120,
  kind: "match",
  starts_at: "2026-09-26T14:30:00+00:00",
  ends_at: "19:00:00",
  lane: null,
  alley_name: null,
  home_team: "SKK Veverky Brno A",
  away_team: "KK Blansko B",
  is_away: false,
};

Deno.test("a match reminder names the Prague start time, not UTC", () => {
  assertEquals(
    reminderBody(base),
    "SKK Veverky Brno A – KK Blansko B, so 26.9. 16:30, doma",
  );
});

Deno.test("an away match in winter reads its CET start and venku", () => {
  assertEquals(
    reminderBody({
      ...base,
      starts_at: "2026-12-12T09:00:00+00:00",
      is_away: true,
    }),
    "SKK Veverky Brno A – KK Blansko B, so 12.12. 10:00, venku",
  );
});

Deno.test("a training reminder spans Prague start to its end, with the lane", () => {
  assertEquals(
    reminderBody({
      ...base,
      kind: "training",
      event_key: "r:1",
      starts_at: "2026-09-17T16:30:00+00:00",
      ends_at: "19:30:00",
      lane: 2,
      home_team: null,
      away_team: null,
      is_away: null,
    }),
    "čt 17.9. 18:30–19:30, dráha 2",
  );
});

Deno.test("a training just after midnight is dated by the Prague day", () => {
  assertEquals(
    reminderBody({
      ...base,
      kind: "training",
      starts_at: "2026-09-26T22:15:00+00:00",
      ends_at: "01:15:00",
      lane: null,
      home_team: null,
      away_team: null,
      is_away: null,
    }),
    "ne 27.9. 0:15–1:15",
  );
});

// --- the title: on time it names the lead time, late the time left -----

// base starts 2026-09-26 16:30 Prague = 14:30 UTC.
const at = (iso: string) => new Date(iso);

Deno.test("sent on its minute, the title names the lead time", () => {
  assertEquals(reminderTitle(base, at("2026-09-26T12:30:20Z")), "Zápas za 2 hodiny");
  assertEquals(
    reminderTitle({ ...base, kind: "training" }, at("2026-09-26T12:31:00Z")),
    "Trénink za 2 hodiny",
  );
});

Deno.test("a few minutes behind (a slow tick) still reads as on time", () => {
  assertEquals(reminderTitle(base, at("2026-09-26T12:34:00Z")), "Zápas za 2 hodiny");
});

Deno.test("late, the title says the time actually left", () => {
  // Booked 90 minutes before: not "za 2 hodiny".
  assertEquals(reminderTitle(base, at("2026-09-26T13:00:00Z")), "Zápas za 90 minut");
  // After an outage, 20 minutes before.
  assertEquals(reminderTitle(base, at("2026-09-26T14:10:00Z")), "Zápas za 20 minut");
  assertEquals(reminderTitle(base, at("2026-09-26T14:29:30Z")), "Zápas za minutu");
  // Two hours and more round to whole hours, under a day.
  assertEquals(
    reminderTitle({ ...base, offset_minutes: 1440 }, at("2026-09-26T09:10:00Z")),
    "Zápas za 5 hodin",
  );
  assertEquals(
    reminderTitle({ ...base, offset_minutes: 2880 }, at("2026-09-25T15:00:00Z")),
    "Zápas za 23 hodin",
  );
});

Deno.test("late by days, the title counts Prague calendar days", () => {
  // 00:30 Prague on the 25th, 40 h before: tomorrow, not "za 2 dny".
  assertEquals(
    reminderTitle({ ...base, offset_minutes: 10080 }, at("2026-09-24T22:30:00Z")),
    "Zápas zítra",
  );
  // 14:00 Prague on the 24th, 26.5 h before: the day after tomorrow.
  assertEquals(
    reminderTitle({ ...base, offset_minutes: 10080 }, at("2026-09-24T12:00:00Z")),
    "Zápas za 2 dny",
  );
  assertEquals(
    reminderTitle({ ...base, offset_minutes: 40320 }, at("2026-09-20T10:00:00Z")),
    "Zápas za 6 dnů",
  );
});

// --- one push per event -------------------------------------------------

Deno.test("several lead times due at once for one event send one push, the "
  + "closest; the rest are only marked", () => {
  const day = { ...base, offset_minutes: 1440 };
  const twoHours = { ...base, offset_minutes: 120 };
  const other = { ...base, event_key: "m:2", offset_minutes: 1440 };
  const someoneElse = { ...base, user_id: "u2", offset_minutes: 1440 };
  const picked = oneReminderPerEvent([day, twoHours, other, someoneElse]);
  assertEquals(picked.map((p) => [p.send.user_id, p.send.event_key, p.send.offset_minutes]), [
    ["u1", "m:1", 120],
    ["u1", "m:2", 1440],
    ["u2", "m:1", 1440],
  ]);
  assertEquals(picked[0].alsoDue.map((r) => r.offset_minutes), [1440]);
  assertEquals(picked[1].alsoDue, []);
});
