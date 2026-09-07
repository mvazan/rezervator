import { assertEquals, assertMatch, assertNotEquals } from "jsr:@std/assert@1";
import {
  classify,
  eventIdFor,
  isEventColorId,
  localDateTime,
  mapLegacyMatchTeams,
  matchEventBody,
  matchEventId,
  matchTarget,
  possibleMatchCalendars,
  remindersFor,
  reservationEventBody,
  validateTeamChoices,
  validateTeamColors,
  worstResult,
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

Deno.test("reservationEventBody: no colour given → still no colorId key (byte-identical to before colours existed)", () => {
  assertEquals("colorId" in reservationEventBody(ROW, []), false);
  // An explicit null (the player has no training colour set) must behave
  // exactly like the colour argument being omitted entirely.
  assertEquals(reservationEventBody(ROW, []), reservationEventBody(ROW, [], null));
});

Deno.test("reservationEventBody: a training colour becomes the string colorId", () => {
  assertEquals(reservationEventBody(ROW, [], 5).colorId, "5");
});

const MATCH = "5c1a2b3d-4e5f-4a6b-8c7d-9e0f1a2b3c4d";

Deno.test("matchEventId lives in its own namespace next to reservation ids", async () => {
  assertEquals(await matchEventId(USER, MATCH), await matchEventId(USER, MATCH));
  assertMatch(await matchEventId(USER, MATCH), /^[0-9a-v]{32}$/);
  assertNotEquals(await matchEventId(USER, MATCH), await eventIdFor(USER, MATCH));
});

Deno.test("matchEventBody: a home match is located at the alley", () => {
  const body = matchEventBody(
    {
      date: "2026-09-11",
      starts_at: "18:30:00",
      ends_at: "21:30:00",
      home_team: "TJ Sokol Brno IV",
      away_team: "SK Kuželky Dubňany",
      is_away: false,
      description: "JM divize",
      alley_name: "TJ Sokol Brno IV",
    },
    [120],
  );
  assertEquals(body.summary, "Zápas · TJ Sokol Brno IV – SK Kuželky Dubňany");
  assertEquals(body.location, "TJ Sokol Brno IV");
  assertEquals(body.start, { dateTime: "2026-09-11T18:30:00", timeZone: "Europe/Prague" });
  assertEquals(body.end, { dateTime: "2026-09-11T21:30:00", timeZone: "Europe/Prague" });
  assertEquals(body.reminders, { useDefault: false, overrides: [{ method: "popup", minutes: 120 }] });
  assertMatch(body.description, /^JM divize · doma\n\n— spravuje appka Rezervátor/);
});

Deno.test("matchEventBody: an away match has no location and says venku", () => {
  const body = matchEventBody(
    {
      date: "2026-10-22",
      starts_at: "18:00:00",
      ends_at: "20:30:00",
      home_team: "KK Slovan Rosice D",
      away_team: "KS Devítka Brno B",
      is_away: true,
      description: "KP2 Sever A · Rosice",
      alley_name: "TJ Sokol Brno IV",
    },
    [],
  );
  assertEquals(body.location, undefined);
  assertMatch(body.description, /^KP2 Sever A · Rosice · venku\n/);
  assertEquals(body.reminders, { useDefault: false, overrides: [] });
});

const HOME_MATCH = {
  date: "2026-09-11",
  starts_at: "18:30:00",
  ends_at: "21:30:00",
  home_team: "TJ Sokol Brno IV",
  away_team: "SK Kuželky Dubňany",
  is_away: false,
  description: "JM divize",
  alley_name: "TJ Sokol Brno IV",
};

Deno.test("matchEventBody: a body without a colour is byte-for-byte what today's callers already get", () => {
  const body = matchEventBody(HOME_MATCH, [120]);
  assertEquals(body, {
    summary: "Zápas · TJ Sokol Brno IV – SK Kuželky Dubňany",
    description:
      "JM divize · doma\n\n— spravuje appka Rezervátor, ruční úpravy se přepíšou —",
    start: { dateTime: "2026-09-11T18:30:00", timeZone: "Europe/Prague" },
    end: { dateTime: "2026-09-11T21:30:00", timeZone: "Europe/Prague" },
    status: "confirmed",
    reminders: {
      useDefault: false,
      overrides: [{ method: "popup", minutes: 120 }],
    },
    location: "TJ Sokol Brno IV",
  });
});

Deno.test("matchEventBody: no colour given → no colorId key, same whether omitted or explicitly null", () => {
  assertEquals("colorId" in matchEventBody(HOME_MATCH, [120]), false);
  assertEquals(
    matchEventBody(HOME_MATCH, [120]),
    matchEventBody(HOME_MATCH, [120], null),
  );
});

Deno.test("matchEventBody: the followed team's colour becomes the string colorId", () => {
  const body = matchEventBody(HOME_MATCH, [120], 7);
  assertEquals(body.colorId, "7");
  // Everything else is untouched by adding a colour.
  const { colorId: _colorId, ...rest } = body;
  assertEquals(rest, matchEventBody(HOME_MATCH, [120]));
});

Deno.test("matchTarget: without a second calendar everything stays put", () => {
  const one = { primary: "cal-a", secondary: null };
  assertEquals(matchTarget("primary", one), {
    calendarId: "cal-a",
    otherId: null,
    secondary: false,
  });
  // A team still marked 'secondary' (the player turned the second calendar
  // off) falls back to the primary rather than losing its event.
  assertEquals(matchTarget("secondary", one), {
    calendarId: "cal-a",
    otherId: null,
    secondary: false,
  });
});

Deno.test("matchTarget: with a second calendar each team gets its own, and "
  + "the other one is swept", () => {
  const two = { primary: "cal-a", secondary: "cal-b" };
  assertEquals(matchTarget("primary", two), {
    calendarId: "cal-a",
    otherId: "cal-b",
    secondary: false,
  });
  assertEquals(matchTarget("secondary", two), {
    calendarId: "cal-b",
    otherId: "cal-a",
    secondary: true,
  });
});

Deno.test("possibleMatchCalendars: only the primary without a second calendar", () => {
  assertEquals(possibleMatchCalendars({ primary: "cal-a", secondary: null }), [
    "cal-a",
  ]);
});

Deno.test("possibleMatchCalendars: both, primary first, when there is a second", () => {
  assertEquals(
    possibleMatchCalendars({ primary: "cal-a", secondary: "cal-b" }),
    ["cal-a", "cal-b"],
  );
});

Deno.test("worstResult: all ok stays ok, including the empty case", () => {
  assertEquals(worstResult([]), "ok");
  assertEquals(worstResult(["ok"]), "ok");
  assertEquals(worstResult(["ok", "ok"]), "ok");
});

Deno.test("worstResult: a single non-ok result wins", () => {
  assertEquals(worstResult(["ok", "gone"]), "gone");
  assertEquals(worstResult(["auth", "ok"]), "auth");
});

Deno.test("worstResult: retry always wins, even next to auth/gone", () => {
  assertEquals(worstResult(["ok", "retry"]), "retry");
  assertEquals(worstResult(["gone", "retry"]), "retry");
  assertEquals(worstResult(["retry", "auth"]), "retry");
});

Deno.test("validateTeamChoices: a normal payload passes through, trimmed, calendar defaulted", () => {
  assertEquals(
    validateTeamChoices([
      { team: " SKK Veverky Brno A ", calendar: "secondary" },
      { team: "KS Devítka Brno B" },
    ]),
    [
      { team: "SKK Veverky Brno A", calendar: "secondary" },
      { team: "KS Devítka Brno B", calendar: "primary" },
    ],
  );
});

Deno.test("validateTeamChoices: duplicate team names collapse, first occurrence wins", () => {
  assertEquals(
    validateTeamChoices([
      { team: "X", calendar: "primary" },
      { team: "X", calendar: "secondary" },
    ]),
    [{ team: "X", calendar: "primary" }],
  );
});

Deno.test("validateTeamChoices: rejects a non-array or more than 20 entries", () => {
  assertEquals(validateTeamChoices(null), null);
  assertEquals(validateTeamChoices("nope"), null);
  assertEquals(validateTeamChoices({ team: "X" }), null);
  assertEquals(
    validateTeamChoices(
      Array.from({ length: 21 }, (_, i) => ({ team: `T${i}` })),
    ),
    null,
  );
});

Deno.test("validateTeamChoices: rejects a blank or implausibly long team name", () => {
  assertEquals(validateTeamChoices([{ team: "" }]), null);
  assertEquals(validateTeamChoices([{ team: "   " }]), null);
  assertEquals(validateTeamChoices([{ team: 42 }]), null);
  assertEquals(validateTeamChoices([{ team: "x".repeat(81) }]), null);
});

Deno.test("validateTeamChoices: rejects an unknown calendar", () => {
  assertEquals(validateTeamChoices([{ team: "X", calendar: "tertiary" }]), null);
});

Deno.test("validateTeamChoices: rejects a non-object entry", () => {
  assertEquals(validateTeamChoices(["X"]), null);
  assertEquals(validateTeamChoices([null]), null);
});

Deno.test("validateTeamChoices: a color_id is no longer read at all — garbage or in-range, it never surfaces and never fails the payload (colour moved to validateTeamColors, 0036)", () => {
  assertEquals(
    validateTeamChoices([{ team: "X", color_id: 999 }]),
    [{ team: "X", calendar: "primary" }],
  );
  assertEquals(
    validateTeamChoices([{ team: "X", color_id: "steal-the-database" }]),
    [{ team: "X", calendar: "primary" }],
  );
});

Deno.test("validateTeamColors: a normal payload passes through, trimmed, missing colour becomes null", () => {
  assertEquals(
    validateTeamColors([
      { team: " SKK Veverky Brno A ", color_id: 9 },
      { team: "KS Devítka Brno B" },
    ]),
    [
      { team: "SKK Veverky Brno A", color_id: 9 },
      { team: "KS Devítka Brno B", color_id: null },
    ],
  );
});

Deno.test("validateTeamColors: an explicit null colour is the same as omitting it", () => {
  assertEquals(
    validateTeamColors([{ team: "X", color_id: null }]),
    validateTeamColors([{ team: "X" }]),
  );
  assertEquals(validateTeamColors([{ team: "X", color_id: null }]), [
    { team: "X", color_id: null },
  ]);
});

Deno.test("validateTeamColors: duplicate team names collapse, first occurrence wins", () => {
  assertEquals(
    validateTeamColors([
      { team: "X", color_id: 2 },
      { team: "X", color_id: 5 },
    ]),
    [{ team: "X", color_id: 2 }],
  );
});

Deno.test("validateTeamColors: rejects a non-array, or more than the RPC's 40-entry cap", () => {
  assertEquals(validateTeamColors(null), null);
  assertEquals(validateTeamColors("nope"), null);
  assertEquals(validateTeamColors({ team: "X" }), null);
  assertEquals(
    validateTeamColors(
      Array.from({ length: 41 }, (_, i) => ({ team: `T${i}` })),
    ),
    null,
  );
});

Deno.test("validateTeamColors: exactly 40 entries is still fine (the RPC's own boundary)", () => {
  const input = Array.from(
    { length: 40 },
    (_, i) => ({ team: `T${i}`, color_id: 1 }),
  );
  const out = validateTeamColors(input);
  assertEquals(out?.length, 40);
});

Deno.test("validateTeamColors: rejects a blank or implausibly long team name", () => {
  assertEquals(validateTeamColors([{ team: "" }]), null);
  assertEquals(validateTeamColors([{ team: "   " }]), null);
  assertEquals(validateTeamColors([{ team: 42 }]), null);
  assertEquals(validateTeamColors([{ team: "x".repeat(81) }]), null);
});

Deno.test("validateTeamColors: rejects a colour outside 1-11", () => {
  assertEquals(validateTeamColors([{ team: "X", color_id: 0 }]), null);
  assertEquals(validateTeamColors([{ team: "X", color_id: 12 }]), null);
  assertEquals(validateTeamColors([{ team: "X", color_id: 1.5 }]), null);
  assertEquals(
    validateTeamColors([{ team: "X", color_id: "not a number" }]),
    null,
  );
});

Deno.test("validateTeamColors: rejects a boolean colour rather than coercing it to 0/1", () => {
  assertEquals(validateTeamColors([{ team: "X", color_id: true }]), null);
  assertEquals(validateTeamColors([{ team: "X", color_id: false }]), null);
});

Deno.test("validateTeamColors: rejects a non-object entry", () => {
  assertEquals(validateTeamColors(["X"]), null);
  assertEquals(validateTeamColors([null]), null);
});

Deno.test("validateTeamColors: a malicious extra key (calendar, a bogus role) never reaches the output", () => {
  assertEquals(
    validateTeamColors([
      { team: "X", color_id: 3, calendar: "secondary", role: "admin" },
    ]),
    [{ team: "X", color_id: 3 }],
  );
});

Deno.test("isEventColorId: only Google's eleven", () => {
  for (const ok of [1, 11, "7"]) {
    assertEquals(isEventColorId(ok), true, `${ok} should pass`);
  }
  for (const bad of [0, 12, -1, 1.5, "", "modrá", null, undefined, {}]) {
    assertEquals(isEventColorId(bad), false, `${bad} should fail`);
  }
});

Deno.test("isEventColorId: rejects a boolean rather than coercing it to 0/1", () => {
  // Number(true) === 1 and Number(false) === 0 — without a type gate before
  // the coercion, `color_id: true` would pass as colour 1.
  assertEquals(isEventColorId(true), false);
  assertEquals(isEventColorId(false), false);
});

const TC = (
  team: string,
  calendar: "primary" | "secondary",
) => ({ team, calendar });

Deno.test("mapLegacyMatchTeams: a name already tracked keeps its calendar untouched", () => {
  assertEquals(
    mapLegacyMatchTeams(
      ["SKK Veverky Brno A"],
      [TC("SKK Veverky Brno A", "secondary")],
    ),
    [TC("SKK Veverky Brno A", "secondary")],
  );
});

Deno.test("mapLegacyMatchTeams: a name new to `current` defaults to primary", () => {
  assertEquals(
    mapLegacyMatchTeams(["KS Devítka Brno B"], []),
    [TC("KS Devítka Brno B", "primary")],
  );
});

Deno.test("mapLegacyMatchTeams: a name dropped from the list is just absent from the result", () => {
  assertEquals(
    mapLegacyMatchTeams(
      ["A"],
      [TC("A", "primary"), TC("B", "secondary")],
    ),
    [TC("A", "primary")],
  );
});

Deno.test("mapLegacyMatchTeams: kept and new teams mix in the same call", () => {
  assertEquals(
    mapLegacyMatchTeams(
      ["A", "New"],
      [TC("A", "secondary"), TC("Dropped", "primary")],
    ),
    [TC("A", "secondary"), TC("New", "primary")],
  );
});

Deno.test("mapLegacyMatchTeams: trims and de-dupes, first occurrence wins", () => {
  assertEquals(
    mapLegacyMatchTeams([" A ", "A", "B"], [TC("A", "secondary")]),
    [TC("A", "secondary"), TC("B", "primary")],
  );
});

Deno.test("mapLegacyMatchTeams: a blank name is dropped, an empty list clears everything", () => {
  assertEquals(mapLegacyMatchTeams(["  "], [TC("A", "primary")]), []);
  assertEquals(mapLegacyMatchTeams([], [TC("A", "primary")]), []);
});

Deno.test("the old app's team names face the same caps as the new screen", () => {
  // mapLegacyMatchTeams keeps what a team already had and defaults the rest,
  // but it is not a validator — an 1.2.1 client is still untrusted, so the
  // caller runs the result through validateTeamChoices.
  const current = [
    { team: "Veverky A", calendar: "secondary" as const },
  ];
  const mapped = mapLegacyMatchTeams(
    ["Veverky A", "x".repeat(81)],
    current,
  );
  assertEquals(mapped[0], current[0], "an existing team keeps its calendar");
  assertEquals(validateTeamChoices(mapped), null, "an over-long name is refused");

  const ok = mapLegacyMatchTeams(["Veverky A", "Devítka B"], current);
  assertEquals(validateTeamChoices(ok), [
    { team: "Veverky A", calendar: "secondary" },
    { team: "Devítka B", calendar: "primary" },
  ]);
});
