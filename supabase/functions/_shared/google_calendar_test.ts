import { assertEquals, assertMatch, assertNotEquals } from "jsr:@std/assert@1";
import {
  classify,
  eventIdFor,
  localDateTime,
  remindersFor,
  reservationEventBody,
} from "./google_calendar.ts";

const USER = "6f9c1d2e-0a1b-4c3d-8e9f-a0b1c2d3e4f5";
const RESERVATION = "3f6b0a4e-1c2d-4e5f-8a9b-0c1d2e3f4a5b";
const OTHER_RESERVATION = "9a8b7c6d-5e4f-4a3b-9c8d-7e6f5a4b3c2d";

Deno.test("eventIdFor is deterministic", async () => {
  assertEquals(
    await eventIdFor(USER, RESERVATION),
    await eventIdFor(USER, RESERVATION),
  );
});

Deno.test("eventIdFor is 32 chars from the base32hex alphabet", async () => {
  const id = await eventIdFor(USER, RESERVATION);
  assertEquals(id.length, 32);
  assertMatch(id, /^[0-9a-v]{32}$/);
});

Deno.test("eventIdFor differs across reservations and across users", async () => {
  assertNotEquals(
    await eventIdFor(USER, RESERVATION),
    await eventIdFor(USER, OTHER_RESERVATION),
  );
  assertNotEquals(
    await eventIdFor(USER, RESERVATION),
    await eventIdFor(RESERVATION, USER),
  );
});

Deno.test("localDateTime keeps the wall clock, no offset math", () => {
  assertEquals(localDateTime("2026-09-04", "16:00:00"), "2026-09-04T16:00:00");
});

Deno.test("localDateTime normalises HH:MM (and unpadded hours) to HH:MM:SS", () => {
  assertEquals(localDateTime("2026-09-04", "16:00"), "2026-09-04T16:00:00");
  assertEquals(localDateTime("2026-01-05", "9:05"), "2026-01-05T09:05:00");
});

Deno.test("classify maps Calendar API statuses to write results", () => {
  assertEquals(classify(200), "ok");
  assertEquals(classify(401), "auth");
  assertEquals(classify(404), "gone");
  assertEquals(classify(410), "gone");
  assertEquals(classify(500), "retry");
  assertEquals(classify(429), "retry");
  assertEquals(classify(403), "retry");
});

Deno.test("remindersFor never falls back to the calendar defaults", () => {
  assertEquals(remindersFor([]), { useDefault: false, overrides: [] });
  assertEquals(remindersFor([30]), {
    useDefault: false,
    overrides: [{ method: "popup", minutes: 30 }],
  });
});

const ROW = {
  date: "2026-09-04",
  starts_at: "16:00:00",
  ends_at: "17:30:00",
  lane: 2,
  alley_name: "Kuželna č. 1",
};

Deno.test("reservationEventBody wording and times", () => {
  const body = reservationEventBody(ROW, []);
  assertEquals(body.summary, "Trénink · Kuželna č. 1");
  assertEquals(
    body.description,
    "Dráha 2\n\n— spravuje appka Rezervátor, ruční úpravy se přepíšou —",
  );
  assertEquals(body.start, {
    dateTime: "2026-09-04T16:00:00",
    timeZone: "Europe/Prague",
  });
  assertEquals(body.end, {
    dateTime: "2026-09-04T17:30:00",
    timeZone: "Europe/Prague",
  });
  assertEquals(body.status, "confirmed");
  // The alley has one address the player knows; no location, no colour.
  assertEquals("location" in body, false);
  assertEquals("colorId" in body, false);
});

Deno.test("reservationEventBody: no reminders → useDefault false, empty overrides", () => {
  assertEquals(reservationEventBody(ROW, []).reminders, {
    useDefault: false,
    overrides: [],
  });
});

Deno.test("reservationEventBody: reminder minutes become popup overrides", () => {
  assertEquals(reservationEventBody(ROW, [1440, 120]).reminders, {
    useDefault: false,
    overrides: [
      { method: "popup", minutes: 1440 },
      { method: "popup", minutes: 120 },
    ],
  });
});
