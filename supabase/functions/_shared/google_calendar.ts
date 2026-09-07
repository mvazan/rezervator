// Google Calendar API — shared by calendar-oauth-callback (linking the
// account + creating the calendar), calendar-manage (disconnect, reminders)
// and notify (the ongoing `calendar_sync` jobs).
//
// Scope: calendar.app.created — everything here touches ONLY the secondary
// calendar "Rezervátor" the app created for itself. The user's other
// calendars are out of reach, and that is the point.
//
// Secrets: GOOGLE_CLIENT_ID, GOOGLE_CLIENT_SECRET. Read lazily, never at
// module load, so the pure helpers below stay testable under a plain
// `deno test` (no --allow-env).

function env(name: string, fallback = ""): string {
  return Deno.env.get(name) ?? fallback;
}

// Overridable only for tests against a fake Google; never set in production.
const calendarApi = () =>
  env("GOOGLE_CALENDAR_API", "https://www.googleapis.com/calendar/v3");
const tokenEndpoint = () =>
  env("GOOGLE_TOKEN_ENDPOINT", "https://oauth2.googleapis.com/token");

export const CALENDAR_SUMMARY = "Rezervátor";
export const CALENDAR_DESCRIPTION = "Tvoje tréninky z appky Rezervátor.";
/** The second calendar ("Rezervátor 2") never holds a training by design —
 * only matches of the teams routed to it — so it gets its own description
 * rather than inheriting the primary's, which would be a lie. */
export const CALENDAR_DESCRIPTION_SECONDARY =
  "Zápasy sledovaných týmů z appky Rezervátor.";
export const CALENDAR_TIMEZONE = "Europe/Prague";

/** The user revoked access (or the token expired after 7 days while the
 * consent screen is in Testing) — the link is dead, retrying is pointless. */
export class GoogleAuthError extends Error {
  constructor(readonly code: "invalid_grant" | "other", message: string) {
    super(message);
    this.name = "GoogleAuthError";
  }
}

/** Refresh token -> short-lived access token. Not cached across jobs: tokens
 * are per user and one batch of jobs can mix several people. */
export async function refreshAccessToken(
  refreshToken: string,
): Promise<string> {
  const response = await fetch(tokenEndpoint(), {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      client_id: env("GOOGLE_CLIENT_ID"),
      client_secret: env("GOOGLE_CLIENT_SECRET"),
      refresh_token: refreshToken,
      grant_type: "refresh_token",
    }),
  });
  if (!response.ok) {
    const text = await response.text();
    throw new GoogleAuthError(
      text.includes("invalid_grant") ? "invalid_grant" : "other",
      `token refresh failed: ${text}`,
    );
  }
  return (await response.json()).access_token as string;
}

/** Authorization code -> tokens (the callback function only). */
export async function exchangeCode(
  code: string,
  redirectUri: string,
): Promise<{ accessToken: string; refreshToken?: string; idToken?: string }> {
  const response = await fetch(tokenEndpoint(), {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      code,
      client_id: env("GOOGLE_CLIENT_ID"),
      client_secret: env("GOOGLE_CLIENT_SECRET"),
      redirect_uri: redirectUri,
      grant_type: "authorization_code",
    }),
  });
  if (!response.ok) {
    throw new Error(`code exchange failed: ${await response.text()}`);
  }
  const json = await response.json();
  return {
    accessToken: json.access_token,
    refreshToken: json.refresh_token,
    idToken: json.id_token,
  };
}

/** E-mail of the linked account from the id_token (scope `email`) — shown in
 * Můj profil, nothing more. The signature is deliberately not verified: the
 * token came straight from googleapis.com over HTTPS in the reply to our own
 * request, not from the client. */
export function emailFromIdToken(idToken?: string): string | null {
  if (!idToken) return null;
  try {
    const payload = idToken.split(".")[1];
    if (!payload) return null;
    const json = atob(payload.replace(/-/g, "+").replace(/_/g, "/"));
    return (JSON.parse(json).email as string) ?? null;
  } catch {
    return null;
  }
}

/** Is the calendar still alive and reachable under this grant? The stored id
 * is the only way back to "our" calendar — calendarList.list is a 403 under
 * this scope and there is no lookup by name (verified 2026-08-10, Termínátor).
 * false = deleted by the user OR behind a revoked consent (404); either way
 * the right move is to create a fresh one. */
export async function calendarExists(
  accessToken: string,
  calendarId: string,
): Promise<boolean> {
  try {
    const response = await fetch(
      `${calendarApi()}/calendars/${encodeURIComponent(calendarId)}`,
      { headers: { Authorization: `Bearer ${accessToken}` } },
    );
    return response.ok;
  } catch (error) {
    console.error("calendars.get probe failed (treated as gone):", error);
    return false;
  }
}

/** Deletes the app's calendar (on disconnect — otherwise they pile up in the
 * account, because once consent is revoked the app can never reach it again:
 * calendarList.list is 403 under this scope and calendars.get across the
 * grant boundary is 404, verified 2026-08-10). 404/410 = already gone = done. */
export async function deleteCalendar(
  accessToken: string,
  calendarId: string,
): Promise<WriteResult> {
  const response = await fetch(
    `${calendarApi()}/calendars/${encodeURIComponent(calendarId)}`,
    { method: "DELETE", headers: { Authorization: `Bearer ${accessToken}` } },
  );
  if (response.ok || response.status === 404 || response.status === 410) {
    return "ok";
  }
  console.error(
    `calendar DELETE ${response.status}: ${await response.text()}`,
  );
  return classify(response.status);
}

/** Revokes the refresh token at Google (best effort — when it fails the token
 * is forgotten anyway, and access can be removed in the Google account
 * settings too). */
export async function revokeToken(refreshToken: string): Promise<void> {
  try {
    await fetch(
      `https://oauth2.googleapis.com/revoke?token=${
        encodeURIComponent(refreshToken)
      }`,
      { method: "POST" },
    );
  } catch (error) {
    console.error("token revoke failed (ignored):", error);
  }
}

/** Clears the player's secondary calendar (id + `secondary_enabled`) without
 * touching anything else — the one shared fix for two different moments the
 * SECOND calendar's Google side can go stale while the primary is still
 * fine:
 *  - calendar-oauth-callback, relinking under a FRESH consent (the previous
 *    primary was unreachable, so a new one had to be created): the old
 *    consent's secondary calendar is gone right along with it, and a stale
 *    id left behind would route a team into a calendar nothing can ever
 *    reach again.
 *  - notify's matchSync, when a write lands on a SECONDARY calendar the
 *    player deleted by hand in Google (404/410, "gone") while the primary
 *    is untouched: the fix is to fall back to the primary, not break the
 *    whole link.
 *
 * Deliberately leaves calendar_teams alone: a row still pointed at
 * 'secondary' just falls back to the primary on its own (matchTarget
 * treats a null `calendars.secondary` as "route to primary" regardless of
 * the team's own column), and reappears in the second calendar by itself if
 * the player turns it back on — exactly the behaviour calendar-manage's
 * `disconnect`/`secondary` OFF path already relies on. `secondary_enabled`
 * is reset here for the same reason `forget()` (calendar-manage) resets it
 * on disconnect: it does not just record a preference, it asserts a second
 * calendar EXISTS, and it no longer does. */
export async function clearSecondaryCalendar(
  // deno-lint-ignore no-explicit-any
  db: any,
  userId: string,
): Promise<void> {
  const now = new Date().toISOString();
  await db.from("google_calendar_tokens")
    .update({ google_calendar_id_secondary: null, updated_at: now })
    .eq("user_id", userId);
  await db.from("google_calendar_links")
    .update({ secondary_enabled: false, updated_at: now })
    .eq("user_id", userId);
}

/** Creates a calendar the app owns and returns its id. `summary` defaults to
 * CALENDAR_SUMMARY ("Rezervátor", the one every player already has); pass
 * "Rezervátor 2" (and CALENDAR_DESCRIPTION_SECONDARY) to create a player's
 * optional second calendar instead — its own description, since it never
 * holds a training. No calendar-level reminders — the player sets those in
 * Můj profil and they travel on the events themselves; a fresh calendar from
 * the API has no defaultReminders, which is also the wanted default. */
export async function createSecondaryCalendar(
  accessToken: string,
  summary: string = CALENDAR_SUMMARY,
  description: string = CALENDAR_DESCRIPTION,
): Promise<string> {
  const response = await fetch(`${calendarApi()}/calendars`, {
    method: "POST",
    headers: {
      Authorization: `Bearer ${accessToken}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({
      summary,
      description,
      timeZone: CALENDAR_TIMEZONE,
    }),
  });
  if (!response.ok) {
    throw new Error(`calendar create failed: ${await response.text()}`);
  }
  return (await response.json()).id as string;
}

export type EventReminders = {
  useDefault: false;
  overrides: { method: "popup"; minutes: number }[];
};

/** Reminders go on EVERY event (`reminders.overrides`), not as the calendar's
 * defaultReminders: the whole `calendarList` branch is off limits under
 * calendar.app.created — 401 "Invalid Credentials" even for the calendar the
 * app created and whose events it writes just fine (verified against the
 * production API 2026-08-10). Events are the only place this scope lets
 * reminders through. */
export function remindersFor(minutes: number[]): EventReminders {
  return {
    useDefault: false,
    overrides: minutes.map((m) => ({ method: "popup", minutes: m })),
  };
}

// ---------------------------------------------------------------------------
// Events
// ---------------------------------------------------------------------------

const B32HEX = "0123456789abcdefghijklmnopqrstuv";

function base32hex(bytes: Uint8Array): string {
  let bits = 0;
  let value = 0;
  let out = "";
  for (const byte of bytes) {
    value = (value << 8) | byte;
    bits += 8;
    while (bits >= 5) {
      out += B32HEX[(value >>> (bits - 5)) & 31];
      bits -= 5;
    }
  }
  if (bits > 0) out += B32HEX[(value << (5 - bits)) & 31];
  return out;
}

/** Deterministic event id from (user, reservation): the same reservation
 * always maps to the same id, so upsert and delete are idempotent and no
 * mapping table is needed. The Calendar API wants 5–1024 chars from the
 * base32hex alphabet [a-v0-9]. */
export async function eventIdFor(
  userId: string,
  reservationId: string,
): Promise<string> {
  const digest = await crypto.subtle.digest(
    "SHA-256",
    new TextEncoder().encode(`${userId}:${reservationId}`),
  );
  return base32hex(new Uint8Array(digest)).slice(0, 32);
}

/** Naive local time "YYYY-MM-DDTHH:MM:SS", WITHOUT computing the UTC offset:
 * Google resolves summer/winter time itself from timeZone: Europe/Prague.
 * Doing the offset ourselves would be an hour off for half of the year.
 * Accepts SQL `time` ("16:00:00") as well as "16:00"; no duration maths —
 * a training's end is the block's `ends_at`, not start + N minutes. */
export function localDateTime(date: string, time: string): string {
  const [h, m = 0] = time.split(":").map(Number);
  const hh = String(h).padStart(2, "0");
  const mm = String(m).padStart(2, "0");
  return `${date}T${hh}:${mm}:00`;
}

/** One live future reservation as RPC `my_future_reservations` (0023)
 * returns it. */
export type ReservationRow = {
  reservation_id: string;
  /** "YYYY-MM-DD" */
  date: string;
  /** SQL time "HH:MM:SS" from the reservation's block. */
  starts_at: string;
  ends_at: string;
  lane: number;
  /** The tenant's (kuželna's) name. */
  alley_name: string;
};

export type ReservationEventSource = Omit<ReservationRow, "reservation_id">;

/** The Calendar API event resource the app writes — the same shape for the
 * link-time backfill and for the reconciling job. */
export type EventBody = {
  summary: string;
  description: string;
  /** "YYYY-MM-DDTHH:MM:SS" in Europe/Prague. */
  start: { dateTime: string; timeZone: string };
  end: { dateTime: string; timeZone: string };
  status: "confirmed";
  reminders: EventReminders;
  /** Only matches set it (the alley of a home match). */
  location?: string;
  /** Google's own event colour, "1".."11" — never a bare RGB, Google
   * Calendar only accepts its own eleven (see the secondary-calendar design
   * doc). Absent = the event inherits its calendar's colour, exactly like
   * every event before this field existed. */
  colorId?: string;
};

/** What the calendar should show for one reservation. The alley's name is
 * the tenant's name, the lane goes to the description. No location (the
 * player knows where their own alley is). `status: confirmed` also revives
 * an event the user deleted by hand (see upsertEvent). `colorId` is the
 * player's own training colour (google_calendar_links.training_color_id,
 * 0032) — omitted or null means no colour, same as every training before
 * this field existed. */
export function reservationEventBody(
  row: ReservationEventSource,
  reminderMinutes: number[],
  colorId?: number | null,
): EventBody {
  const body: EventBody = {
    summary: `Trénink · ${row.alley_name}`,
    description: `Dráha ${row.lane}\n\n` +
      "— spravuje appka Rezervátor, ruční úpravy se přepíšou —",
    start: {
      dateTime: localDateTime(row.date, row.starts_at),
      timeZone: CALENDAR_TIMEZONE,
    },
    end: {
      dateTime: localDateTime(row.date, row.ends_at),
      timeZone: CALENDAR_TIMEZONE,
    },
    status: "confirmed",
    reminders: remindersFor(reminderMinutes),
  };
  if (colorId != null) body.colorId = String(colorId);
  return body;
}

/** One live future match of a team the player follows, as RPC
 * `my_future_matches` (0032) returns it. `description` is the competition,
 * with the venue appended for an away match ("KP1 Sever · Blansko 1-6" —
 * the import tool writes it that way). */
export type MatchRow = {
  match_id: string;
  /** "YYYY-MM-DD" */
  date: string;
  /** SQL time "HH:MM:SS" — the match itself, not its úklid. */
  starts_at: string;
  ends_at: string;
  home_team: string;
  away_team: string;
  /** Venkovní zápas: played elsewhere, blocks nothing at the alley. */
  is_away: boolean;
  description: string;
  /** The tenant's (kuželna's) name — the venue of a home match. */
  alley_name: string;
  /** Which of the player's two Google calendars this team's matches go to
   * (calendar_teams.calendar, 0032); always 'primary' or 'secondary', never
   * null — the lateral join in my_future_matches only returns a match at
   * all once a calendar_teams row for one of its teams exists. */
  calendar: "primary" | "secondary";
  /** Google event colorId (1-11) for the followed team, or null = no
   * colour (calendar_teams.color_id, 0032). Not read by matchEventBody
   * itself — writeFutureMatches passes it on as that function's own
   * explicit `colorId` argument, same as a training's. */
  color_id: number | null;
};

/** The fields matchEventBody actually builds the event's wording and times
 * from. `calendar` (routing) and `color_id` (colour) are the CALLER's job —
 * writeFutureMatches reads them straight off the MatchRow to pick a target
 * calendar and a colorId argument — so they are deliberately excluded here
 * rather than duplicated as unused properties on every event source. */
export type MatchEventSource = Omit<
  MatchRow,
  "match_id" | "calendar" | "color_id"
>;

/** Deterministic event id for (user, match) — its own namespace next to
 * the reservations', so a match and a reservation can never share an id. */
export function matchEventId(userId: string, matchId: string): Promise<string> {
  return eventIdFor(userId, `match:${matchId}`);
}

/** What the calendar should show for one match: "Zápas · domácí – hosté",
 * home matches located at the alley, away ones carry the venue in the
 * description (the app never stores it structurally). Same reminders and
 * the same managed-by footer as a training. `colorId` is the followed
 * team's own colour (calendar_teams.color_id, 0032) — omitted or null means
 * no colour, same as every match before this field existed. */
export function matchEventBody(
  row: MatchEventSource,
  reminderMinutes: number[],
  colorId?: number | null,
): EventBody {
  const where = row.is_away ? "venku" : "doma";
  const body: EventBody = {
    summary: `Zápas · ${row.home_team} – ${row.away_team}`,
    description: `${row.description} · ${where}\n\n` +
      "— spravuje appka Rezervátor, ruční úpravy se přepíšou —",
    start: {
      dateTime: localDateTime(row.date, row.starts_at),
      timeZone: CALENDAR_TIMEZONE,
    },
    end: {
      dateTime: localDateTime(row.date, row.ends_at),
      timeZone: CALENDAR_TIMEZONE,
    },
    status: "confirmed",
    reminders: remindersFor(reminderMinutes),
  };
  if (!row.is_away) body.location = row.alley_name;
  if (colorId != null) body.colorId = String(colorId);
  return body;
}

export type WriteResult = "ok" | "auth" | "gone" | "retry";

/** Calendar API status -> what the caller should do about it. */
export function classify(status: number): WriteResult {
  if (status >= 200 && status < 300) return "ok";
  if (status === 401) return "auth";
  if (status === 404 || status === 410) return "gone";
  return "retry"; // 403 (quota), 429, 5xx, anything unexpected
}

/** Creates or overwrites the event under its deterministic id.
 * PUT to a non-existent id does NOT create (404) — hence the fallback to a
 * POST with our own id; 409 means a deleted event with that id is still
 * there, and the PUT revives it (status: "confirmed"). */
export async function upsertEvent(
  accessToken: string,
  calendarId: string,
  eventId: string,
  event: EventBody,
): Promise<WriteResult> {
  const body = JSON.stringify({ id: eventId, ...event });
  const headers = {
    Authorization: `Bearer ${accessToken}`,
    "Content-Type": "application/json",
  };
  const eventUrl = `${calendarApi()}/calendars/${
    encodeURIComponent(calendarId)
  }/events/${eventId}`;

  const put = await fetch(eventUrl, { method: "PUT", headers, body });
  if (put.ok) return "ok";
  if (put.status !== 404) {
    console.error(`event PUT ${put.status}: ${await put.text()}`);
    return classify(put.status);
  }
  // 404 = the event (or the calendar) does not exist. Try to create it.
  const post = await fetch(
    `${calendarApi()}/calendars/${encodeURIComponent(calendarId)}/events`,
    { method: "POST", headers, body },
  );
  if (post.ok) return "ok";
  if (post.status === 409) {
    // A deleted event with this id is still there — the PUT revives it.
    const revive = await fetch(eventUrl, { method: "PUT", headers, body });
    if (revive.ok) return "ok";
    console.error(`event revive ${revive.status}: ${await revive.text()}`);
    return classify(revive.status);
  }
  console.error(`event POST ${post.status}: ${await post.text()}`);
  // 404 here too = the calendar is gone (the user deleted it in Google
  // Calendar).
  return classify(post.status);
}

/** Writes ALL future reservations of one player into the calendar, with
 * their reminders, and returns how many went through. Used by linking (so
 * the player sees right away why they did it) and by a reminders change
 * (the events carry the reminders themselves) — both are actions the user
 * is watching, so they do not go through jobs. Callers still enqueue jobs
 * as a safety net for whatever fails.
 *
 * `db` is the caller's service-role client; RPC `my_future_reservations`
 * (0023) holds the same definition of a "live reservation" as
 * backfill_calendar_jobs. `colorId` is the player's training colour
 * (google_calendar_links.training_color_id, 0032) — the caller reads it and
 * passes it on; omitted or null means no colour, same as before this
 * parameter existed. */
export async function writeFutureReservations(
  // deno-lint-ignore no-explicit-any
  db: any,
  userId: string,
  accessToken: string,
  calendarId: string,
  colorId?: number | null,
): Promise<number> {
  const { data: prefs } = await db.from("google_calendar_links")
    .select("reminder_minutes").eq("user_id", userId).maybeSingle();
  const reminderMinutes = (prefs?.reminder_minutes as number[] | null) ?? [];

  const { data: reservations } = await db.rpc("my_future_reservations", {
    p_user: userId,
  });
  const rows = (reservations ?? []) as ReservationRow[];

  let written = 0;
  const CHUNK = 5; // each reservation = 1-2 Google calls; fives keep it quick
  for (let i = 0; i < rows.length; i += CHUNK) {
    await Promise.all(
      rows.slice(i, i + CHUNK).map(async (row) => {
        const result = await upsertEvent(
          accessToken,
          calendarId,
          await eventIdFor(userId, row.reservation_id),
          reservationEventBody(row, reminderMinutes, colorId),
        );
        if (result === "ok") written++;
      }),
    );
  }
  return written;
}

/** Writes every live future match of the teams the player follows into
 * whichever of their two calendars its team was assigned to
 * (calendar_teams.calendar, via my_future_matches), right away like
 * writeFutureReservations — and DELETES the same deterministic event id
 * from the OTHER calendar. That is the entire "team moved calendar" story:
 * the next sync writes it into the new one and cleans up the old one, no
 * separate move path needed (see the design doc). Reminders follow the
 * calendar an event actually lands in (reminder_minutes vs
 * reminder_minutes_secondary), the same split the player sets in Můj
 * profil.
 *
 * `calendars.secondary` is null for a player who never turned the second
 * calendar on (or just turned it off, which resets every calendar_teams row
 * back to 'primary' — see 0032): every row is then written to primary
 * regardless of its own `calendar` column, and there is nothing to delete
 * from — the exact single-calendar behaviour of before this feature, one
 * Google call per row.
 *
 * `db` is the caller's service-role client; RPC `my_future_matches` (0032)
 * holds the same definition of "live" as backfill_calendar_jobs.
 *
 * Returns `written` (how many events went through) AND `sweepFailed`: when a
 * team moves calendars the delete from the OTHER one IS the move, so a
 * transient failure there (Google 5xx/429) — not just a failed write — must
 * still send the caller to a backfill job, or the event stays duplicated in
 * both calendars with nothing to notice and retry it. */
export async function writeFutureMatches(
  // deno-lint-ignore no-explicit-any
  db: any,
  userId: string,
  accessToken: string,
  calendars: { primary: string; secondary: string | null },
): Promise<{ written: number; sweepFailed: boolean }> {
  const { data: prefs } = await db.from("google_calendar_links")
    .select("reminder_minutes, reminder_minutes_secondary")
    .eq("user_id", userId).maybeSingle();
  const primaryReminders = (prefs?.reminder_minutes as number[] | null) ?? [];
  const secondaryReminders =
    (prefs?.reminder_minutes_secondary as number[] | null) ?? [];

  const { data: matches } = await db.rpc("my_future_matches", {
    p_user: userId,
  });
  const rows = (matches ?? []) as MatchRow[];

  let written = 0;
  let sweepFailed = false;
  const CHUNK = 5;
  for (let i = 0; i < rows.length; i += CHUNK) {
    await Promise.all(
      rows.slice(i, i + CHUNK).map(async (row) => {
        const to = matchTarget(row.calendar, calendars);
        const eventId = await matchEventId(userId, row.match_id);

        const result = await upsertEvent(
          accessToken,
          to.calendarId,
          eventId,
          matchEventBody(
            row,
            to.secondary ? secondaryReminders : primaryReminders,
            row.color_id,
          ),
        );
        if (result === "ok") written++;

        // Only once the event is safely in its target calendar. Deleting
        // first (or regardless) would, on a failed write, leave the match in
        // NEITHER calendar until the next sync. A failed sweep is reported
        // (not just logged): the caller enqueues a backfill job so the
        // duplicate in the OTHER calendar actually gets cleaned up instead
        // of sitting there forever.
        if (result === "ok" && to.otherId) {
          const sweep = await deleteEvent(accessToken, to.otherId, eventId);
          if (sweep !== "ok") sweepFailed = true;
        }
      }),
    );
  }
  return { written, sweepFailed };
}

/** Which calendar one match belongs in, and which one it must be swept out
 * of. Pure, because this is the whole of the two-calendar routing: a team
 * moved from one calendar to the other keeps its event id, so the sweep is
 * what makes the move happen. A player without a second calendar has
 * `secondary: null` and everything lands in the primary, with nothing to
 * sweep — exactly what a one-calendar player had before. */
export function matchTarget(
  calendar: MatchRow["calendar"],
  calendars: { primary: string; secondary: string | null },
): { calendarId: string; otherId: string | null; secondary: boolean } {
  const secondary = calendar === "secondary" && calendars.secondary != null;
  return {
    calendarId: secondary ? calendars.secondary! : calendars.primary,
    otherId: secondary ? calendars.primary : calendars.secondary,
    secondary,
  };
}

/** Every calendar id a match's event could currently be sitting in. Its
 * event id never changes when a followed team moves from one calendar to
 * the other — only where it gets WRITTEN does (see matchTarget/
 * writeFutureMatches) — so cleaning up a match that is no longer live at
 * all (deleted, unfollowed, already played) must be attempted against every
 * calendar it could have last landed in, not just today's primary. Without
 * a second calendar there is only ever the one. */
export function possibleMatchCalendars(
  calendars: { primary: string; secondary: string | null },
): string[] {
  return calendars.secondary
    ? [calendars.primary, calendars.secondary]
    : [calendars.primary];
}

/** Folds the results of the same cleanup attempted against every calendar
 * (possibleMatchCalendars) into one verdict for the caller's retry switch:
 * any "retry" wins outright — a transient failure on EITHER calendar must
 * not be swallowed by an "ok" from the other one, or that calendar's stale
 * event would never be retried — otherwise the first non-"ok" wins (auth
 * and gone are both terminal, either is worth reporting), otherwise
 * everything came back "ok". */
export function worstResult(results: WriteResult[]): WriteResult {
  if (results.includes("retry")) return "retry";
  return results.find((r) => r !== "ok") ?? "ok";
}

/** One player's choice for one followed team — calendar-manage's `teams`
 * action payload, once validated. */
export type TeamChoice = {
  team: string;
  calendar: "primary" | "secondary";
  color_id: number | null;
};

/** Google takes only its own eleven event colours, as colorId "1".."11";
 * anything else is a client that made something up. null means "no colour"
 * and is checked by the caller, not here. The type gate runs BEFORE the
 * coercion: bare `Number(raw)` alone would accept a boolean too
 * (`Number(true) === 1`), so `color_id: true` would otherwise pass as
 * colour 1. */
export function isEventColorId(raw: unknown): boolean {
  if (typeof raw !== "number" && typeof raw !== "string") return false;
  const n = Number(raw);
  return Number.isInteger(n) && n >= 1 && n <= 11;
}

/** Normalises and validates an untrusted `teams` payload before it reaches
 * set_calendar_teams_for: the 0032 RPC only checks the item COUNT and that
 * the caller has a links row — per-item shape is the edge function's job,
 * same as every other action's client input. Trims each team name and
 * rejects a blank or implausibly long one (mirrors the 80-char limit the
 * pre-0032 RPC enforced itself, which the table's own CHECK constraints do
 * not), an unknown `calendar`, or a `color_id` outside Google's 1-11 (both
 * a missing key and an explicit `null` mean "no colour"). De-duplicates by
 * team name — first occurrence wins, as if a repeat were just re-ticking
 * the same checkbox — so a client bug can never trip the table's
 * (user_id, team) primary key. Returns `null` to reject the WHOLE payload:
 * not an array, more than 20 entries, or one entry that cannot be made
 * valid. */
export function validateTeamChoices(input: unknown): TeamChoice[] | null {
  if (!Array.isArray(input) || input.length > 20) return null;
  const seen = new Set<string>();
  const out: TeamChoice[] = [];
  for (const item of input) {
    if (typeof item !== "object" || item === null) return null;
    const raw = item as Record<string, unknown>;

    const team = typeof raw.team === "string" ? raw.team.trim() : "";
    if (!team || team.length > 80) return null;

    if (
      raw.calendar != null && raw.calendar !== "primary" &&
      raw.calendar !== "secondary"
    ) {
      return null;
    }
    const calendar = raw.calendar === "secondary" ? "secondary" : "primary";

    let color_id: number | null = null;
    if (raw.color_id != null) {
      if (!isEventColorId(raw.color_id)) return null;
      color_id = Number(raw.color_id);
    }

    if (seen.has(team)) continue; // first occurrence wins
    seen.add(team);
    out.push({ team, calendar, color_id });
  }
  return out;
}

/** Back-compat for the shipped 1.2.1 app (calendar-manage's OLD `match_teams`
 * action, `Api.setCalendarMatchTeams` there — a bare `string[]`, no calendar
 * or colour: that screen cannot express either). Maps that flat list onto
 * the new per-team shape `teams` needs: a name still present keeps whatever
 * `current` (the player's existing calendar_teams rows) already has for it —
 * an old app must never silently reset a calendar/colour choice made in a
 * newer one — a name that is new to `current` defaults to primary/no colour,
 * same as ticking a team for the first time in the new screen; a name
 * dropped from the list just does not appear in the result, same "whole
 * list, not a delta" contract set_calendar_teams_for already has. Trims and
 * de-dupes (first occurrence wins) like validateTeamChoices, since the old
 * client never did either. */
export function mapLegacyMatchTeams(
  names: string[],
  current: TeamChoice[],
): TeamChoice[] {
  const byName = new Map(current.map((t) => [t.team, t]));
  const seen = new Set<string>();
  const out: TeamChoice[] = [];
  for (const raw of names) {
    const team = raw.trim();
    if (!team || seen.has(team)) continue;
    seen.add(team);
    out.push(byName.get(team) ?? { team, calendar: "primary", color_id: null });
  }
  return out;
}

/** Deletes the event. Already gone (404/410) is done — deletion is
 * idempotent: the job may have been created before the event ever existed. */
export async function deleteEvent(
  accessToken: string,
  calendarId: string,
  eventId: string,
): Promise<WriteResult> {
  const response = await fetch(
    `${calendarApi()}/calendars/${
      encodeURIComponent(calendarId)
    }/events/${eventId}`,
    { method: "DELETE", headers: { Authorization: `Bearer ${accessToken}` } },
  );
  if (response.ok || response.status === 404 || response.status === 410) {
    return "ok";
  }
  console.error(`event DELETE ${response.status}: ${await response.text()}`);
  return classify(response.status);
}
