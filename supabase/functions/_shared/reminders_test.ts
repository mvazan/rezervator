import { assertEquals } from "jsr:@std/assert@1";
import { type DueReminder, reminderBody } from "./reminders.ts";

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
