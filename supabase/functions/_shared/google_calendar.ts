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

/** Creates the secondary calendar and returns its id. No calendar-level
 * reminders — the player sets those in Můj profil and they travel on the
 * events themselves; a fresh calendar from the API has no defaultReminders,
 * which is also the wanted default. */
export async function createSecondaryCalendar(
  accessToken: string,
): Promise<string> {
  const response = await fetch(`${calendarApi()}/calendars`, {
    method: "POST",
    headers: {
      Authorization: `Bearer ${accessToken}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({
      summary: CALENDAR_SUMMARY,
      description: CALENDAR_DESCRIPTION,
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
};

/** What the calendar should show for one reservation. The alley's name is
 * the tenant's name, the lane goes to the description. No location (the
 * player knows where their own alley is) and no colour. `status: confirmed`
 * also revives an event the user deleted by hand (see upsertEvent). */
export function reservationEventBody(
  row: ReservationEventSource,
  reminderMinutes: number[],
): EventBody {
  return {
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
 * backfill_calendar_jobs. */
export async function writeFutureReservations(
  // deno-lint-ignore no-explicit-any
  db: any,
  userId: string,
  accessToken: string,
  calendarId: string,
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
          reservationEventBody(row, reminderMinutes),
        );
        if (result === "ok") written++;
      }),
    );
  }
  return written;
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
