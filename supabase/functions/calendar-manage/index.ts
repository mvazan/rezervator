// calendar-manage — actions on the linked calendar that the player asked for
// and that must finish before the app shows the result.
//
// `disconnect`, `reminders`, `teams`, `team_colors`, `secondary`,
// `training_color` and `match_teams` (a thin back-compat wrapper over
// `teams` for the shipped 1.2.1 app, which only ever sends a bare
// team-name list — see setTeams' call site below; drop it once a build
// with the new screen is the oldest one still talking to this backend).
// Deployed WITHOUT
// --no-verify-jwt (unlike notify and calendar-oauth-callback): a signed-in
// player calls it from the app through functions.invoke, which attaches
// their JWT, and the platform verifies it before the function even runs.
// Inside we still ask auth.getUser() — without a session the client sends
// only the anon key and that yields no user.
//
// Why synchronous and not a job: disconnecting must first DELETE the calendar
// in Google and only then revoke the token — after the revoke the app can
// never reach the calendar again (calendarList.list 403, calendars.get 404
// across the grant boundary, verified 2026-08-10 in Termínátor). A minutely
// cron would leave a window in which the profile card offered "Propojit";
// whoever caught it got an extra orphaned calendar. Here the status changes
// only after Google answered, so there is nothing to catch.
//
// A failure that can be retried (Google 5xx, network) changes NOTHING and
// returns an error — a half-done disconnect never sticks.
//
// CORS: the app also runs as a PWA on rezervator.online, where
// functions.invoke is a cross-origin fetch with a preflight — OPTIONS is
// answered and every reply stamped, otherwise the browser build could never
// disconnect. The JWT check above is the actual gate; the origin is not.

import { createClient } from "@supabase/supabase-js";
import {
  CALENDAR_DESCRIPTION_SECONDARY,
  createSecondaryCalendar,
  deleteCalendar,
  deleteEvent,
  GoogleAuthError,
  mapLegacyMatchTeams,
  matchEventId,
  possibleMatchCalendars,
  refreshAccessToken,
  revokeToken,
  type TeamChoice,
  isEventColorId,
  validateTeamChoices,
  validateTeamColors,
  writeFutureMatches,
  writeFutureReservations,
} from "../_shared/google_calendar.ts";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;

const admin = createClient(
  SUPABASE_URL,
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
);

const CORS_HEADERS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS_HEADERS, "Content-Type": "application/json" },
  });
}

/** Forgets the link: tokens gone, the row stays as 'unlinked' together with
 * reminder_minutes (and, 0032, reminder_minutes_secondary/training_color_id/
 * calendar_teams), so those preferences come back by themselves after a new
 * link. `secondary_enabled` is the one exception: it is reset to false here
 * because it is not just a preference, it asserts a second calendar EXISTS
 * — and disconnect() just deleted it (or there never was one). A
 * calendar_teams row still pointed at 'secondary' is harmless in the
 * meantime: matchTarget already falls back to primary for a team whose
 * calendar does not (yet) exist, so nothing is stranded if the player
 * relinks without turning the second calendar back on. The Google e-mail is
 * personal data — no reason to keep it once disconnected. */
async function forget(userId: string) {
  await admin.from("google_calendar_tokens").delete().eq("user_id", userId);
  await admin.from("google_calendar_links")
    .update({
      status: "unlinked",
      google_email: null,
      last_error: null,
      secondary_enabled: false,
      updated_at: new Date().toISOString(),
    })
    .eq("user_id", userId);
}

/** Which of the two calendars a disconnect could not get rid of. Google
 * still has them, and after the revoke below the app can never reach them
 * again — only the player can delete them now, so the app has to be able
 * to name them. `orphaned` stays a plain boolean next to the list because
 * the shipped 1.2.1 app reads exactly that field (the same back-compat
 * reasoning as the `match_teams` wrapper up top); it is simply
 * `orphaned_calendars` being non-empty. */
type CalendarSlot = "primary" | "secondary";

function disconnected(orphaned: CalendarSlot[]): Response {
  return json({ orphaned: orphaned.length > 0, orphaned_calendars: orphaned });
}

async function disconnect(userId: string): Promise<Response> {
  const { data: token } = await admin.from("google_calendar_tokens")
    .select("refresh_token, google_calendar_id, google_calendar_id_secondary")
    .eq("user_id", userId).maybeSingle();

  // Nothing to disconnect (never linked / already done / a second tap) or
  // only a token without a calendar (a failed link) — just tidy up.
  if (!token?.refresh_token) {
    await forget(userId);
    return disconnected([]);
  }
  const calendarId = token.google_calendar_id as string | null;
  const secondaryId = token.google_calendar_id_secondary as string | null;

  let accessToken: string | null = null;
  try {
    accessToken = await refreshAccessToken(token.refresh_token as string);
  } catch (error) {
    if (!(error instanceof GoogleAuthError && error.code === "invalid_grant")) {
      console.error(`disconnect: token refresh failed for ${userId}:`, error);
      return json({ error: "google_unavailable" }, 503);
    }
    // Access is gone (revoked in the Google account, expired). Neither
    // calendar can be deleted — and never will be; say so and tidy up our
    // side.
    console.warn(`disconnect: grant already revoked for ${userId}`);
    await forget(userId);
    return disconnected([
      ...(calendarId ? ["primary" as const] : []),
      ...(secondaryId ? ["secondary" as const] : []),
    ]);
  }

  // Both calendars, if the player ever turned the second one on — deleting
  // takes each one's events with it, so no per-event cleanup either way.
  // Tried in either order: a "retry" on one leaves the tokens row (and so
  // the whole DB state) untouched, so the next disconnect() call safely
  // re-attempts both — deleteCalendar treats an already-gone calendar as
  // "ok" (404/410), so whichever one already succeeded is just a cheap
  // no-op the second time, never repeated for real.
  const orphaned: CalendarSlot[] = [];
  for (
    const [slot, id] of [
      ["primary", calendarId],
      ["secondary", secondaryId],
    ] as const
  ) {
    if (!id) continue;
    const result = await deleteCalendar(accessToken, id);
    if (result === "retry") {
      // Nothing was changed — let the player try again, the state is whole.
      return json({ error: "google_unavailable" }, 503);
    }
    // "ok" (404/410 included = already gone) as well as "auth" mean there
    // is no way left to delete this calendar; carry on tidying up. Only
    // "auth" actually LEAVES ONE BEHIND, though, and the refresh above
    // having succeeded makes that the surprising case — so the slot is
    // collected and named back to the app, the way the "grant already
    // revoked" branch above does: the player is told WHICH calendar is
    // still sitting in their Google account instead of a plain "smazán".
    // Not guarded by a unit test: disconnect() is unexported and importing
    // this module starts the server, so it would take a fake Google (the
    // GOOGLE_CALENDAR_API seam) plus a DB to reach. The mapping underneath
    // it, classify(401) = "auth", is covered in _shared/google_calendar_test;
    // the app's side of the contract is covered in profile_screen_test.
    if (result === "auth") orphaned.push(slot);
    if (result !== "ok") {
      console.warn(`disconnect: calendar ${id} delete ended as ${result}`);
    }
  }

  await revokeToken(token.refresh_token as string);
  await forget(userId);
  return disconnected(orphaned);
}

/** Which of the player's two Google calendars is actually live right now —
 * gated on `secondary_enabled` even though the id lives in a separate
 * table, same reasoning as notify's calendarLink: the two are meant to
 * change together, and gating here is one more guard against a stale id
 * ever being treated as live if they ever drifted apart. */
function secondaryCalendarIdOf(
  link: { secondary_enabled: boolean | null },
  token: { google_calendar_id_secondary: string | null },
): string | null {
  return link.secondary_enabled
    ? token.google_calendar_id_secondary ?? null
    : null;
}

/** Stores the reminders preference for ONE of the player's calendars (the
 * `calendar` argument) and writes it RIGHT AWAY into every future
 * reservation and match. The events carry the reminders themselves
 * (calendarList is off limits under this scope), so "change the reminder"
 * = rewrite the events; both trainings (always primary) and matches (each
 * in its own followed team's calendar) draw their reminders from
 * writeFutureReservations/writeFutureMatches, which read BOTH reminder
 * columns themselves — rewriting everything keeps every event correct
 * regardless of which of the two lists just changed, at the cost of a few
 * redundant (but harmless) rewrites of the calendar that did not. Through
 * jobs it took two turns of the minutely cron (~2 min) and looked as if
 * nothing happened; the player is watching, so it is done on the spot.
 * Whatever fails is caught up by a job — the count of rewritten events and
 * the remainder flag are returned. */
async function setReminders(
  userId: string,
  minutes: number[],
  calendar: "primary" | "secondary",
): Promise<Response> {
  // Normalisation and validation live in the RPC (0023/0032) — it is the
  // source of truth; here it is only called on the player's behalf.
  const { error } = await admin.rpc("set_calendar_reminders_for", {
    p_user: userId,
    p_minutes: minutes,
    p_calendar: calendar,
  });
  if (error) {
    console.error(`set reminders failed for ${userId}:`, error);
    return json({ error: "bad_reminders" }, 400);
  }

  const { data: link } = await admin.from("google_calendar_links")
    .select(
      "status, secondary_enabled, reminder_minutes, reminder_minutes_secondary, training_color_id",
    )
    .eq("user_id", userId).maybeSingle();
  const saved = calendar === "secondary"
    ? (link?.reminder_minutes_secondary as number[] | null) ?? []
    : (link?.reminder_minutes as number[] | null) ?? [];
  if (link?.status !== "linked") return json({ rewritten: 0, saved });

  const { data: token } = await admin.from("google_calendar_tokens")
    .select("refresh_token, google_calendar_id, google_calendar_id_secondary")
    .eq("user_id", userId).maybeSingle();
  if (!token?.refresh_token || !token.google_calendar_id) {
    return json({ rewritten: 0, saved });
  }

  let accessToken: string;
  try {
    accessToken = await refreshAccessToken(token.refresh_token as string);
  } catch (_) {
    // The preference is stored; the events are caught up by a job once
    // Google is reachable again.
    await admin.rpc("backfill_calendar_jobs", { p_user: userId });
    return json({ rewritten: 0, saved, deferred: true });
  }

  const calendarId = token.google_calendar_id as string;
  const calendars = {
    primary: calendarId,
    secondary: secondaryCalendarIdOf(link, token as { google_calendar_id_secondary: string | null }),
  };
  const trainingColorId = (link.training_color_id as number | null) ?? null;
  const reservationsWritten = await writeFutureReservations(
    admin,
    userId,
    accessToken,
    calendarId,
    trainingColorId,
  );
  const { written: matchesWritten, sweepFailed } = await writeFutureMatches(
    admin,
    userId,
    accessToken,
    calendars,
  );
  const written = reservationsWritten + matchesWritten;
  const [{ data: reservations }, { data: matches }] = await Promise.all([
    admin.rpc("my_future_reservations", { p_user: userId }),
    admin.rpc("my_future_matches", { p_user: userId }),
  ]);
  const expected = ((reservations ?? []) as unknown[]).length +
    ((matches ?? []) as unknown[]).length;
  // A failed SWEEP (a team's match left duplicated in the calendar it just
  // moved out of) is exactly as unfinished as a failed write — both need
  // the backfill job.
  const failed = written < expected || sweepFailed;
  // Whatever did not go through is caught up by a job — the preference is
  // stored, so nothing is lost.
  if (failed) await admin.rpc("backfill_calendar_jobs", { p_user: userId });
  return json({ rewritten: written, saved, deferred: failed });
}

/** Stores the colour of the player's trainings (0034) and repaints the
 * future ones. Trainings always live in the primary calendar, so unlike
 * teams there is nothing to route — only the colour changes. */
async function setTrainingColor(
  userId: string,
  colorId: number | null,
): Promise<Response> {
  const { error } = await admin.rpc("set_training_color_for", {
    p_user: userId,
    p_color: colorId,
  });
  if (error) {
    console.error(`set training colour failed for ${userId}:`, error);
    return json({ error: "bad_color" }, 400);
  }

  const { data: link } = await admin.from("google_calendar_links")
    .select("status").eq("user_id", userId).maybeSingle();
  if (link?.status !== "linked") return json({ rewritten: 0, saved: colorId });

  const { data: token } = await admin.from("google_calendar_tokens")
    .select("refresh_token, google_calendar_id")
    .eq("user_id", userId).maybeSingle();
  if (!token?.refresh_token || !token.google_calendar_id) {
    return json({ rewritten: 0, saved: colorId });
  }

  let accessToken: string;
  try {
    accessToken = await refreshAccessToken(token.refresh_token as string);
  } catch (_) {
    // Stored either way; a job repaints the events once Google answers.
    await admin.rpc("backfill_calendar_jobs", { p_user: userId });
    return json({ rewritten: 0, saved: colorId, deferred: true });
  }

  const written = await writeFutureReservations(
    admin,
    userId,
    accessToken,
    token.google_calendar_id as string,
    colorId,
  );
  const { data: reservations } = await admin.rpc("my_future_reservations", {
    p_user: userId,
  });
  const failed = written < ((reservations ?? []) as unknown[]).length;
  if (failed) await admin.rpc("backfill_calendar_jobs", { p_user: userId });
  return json({ rewritten: written, saved: colorId, deferred: failed });
}

/** Stores which teams' matches go to which calendar (calendar_teams, 0036 —
 * colour moved off this table onto team_colors, see setTeamColors below)
 * and settles the events on the spot: the matches of teams dropped ENTIRELY
 * are deleted, everything kept or new is (re)written into its chosen
 * calendar — the player is watching. Every rewrite still carries whatever
 * colour team_colors already has for that team (my_future_matches joins it
 * in), so nothing goes uncoloured; this action just never CHANGES a colour.
 * `teams` was already validated by the caller (validateTeamChoices), so
 * this only talks to Postgres and Google. Whatever fails is caught up by a
 * job. Returns the stored teams. */
async function setTeams(
  userId: string,
  teams: TeamChoice[],
): Promise<Response> {
  // set_calendar_teams_for (0036) returns the PREVIOUS rows — bounds
  // (≤ 20 items, calendar) are enforced by the table's own CHECK
  // constraints and surface as a generic Postgres error, same as "bad_teams"
  // to the caller; the item shape itself was already validated above.
  const { data: previous, error } = await admin.rpc("set_calendar_teams_for", {
    p_user: userId,
    p_teams: teams,
  });
  if (error) {
    console.error(`set teams failed for ${userId}:`, error);
    return json({ error: "bad_teams" }, 400);
  }
  const previousTeams =
    (previous as { team: string; calendar: string }[] | null) ?? [];

  const { data: link } = await admin.from("google_calendar_links")
    .select("status, secondary_enabled").eq("user_id", userId).maybeSingle();
  if (link?.status !== "linked") return json({ rewritten: 0, saved: teams });

  const { data: token } = await admin.from("google_calendar_tokens")
    .select("refresh_token, google_calendar_id, google_calendar_id_secondary")
    .eq("user_id", userId).maybeSingle();
  if (!token?.refresh_token || !token.google_calendar_id) {
    return json({ rewritten: 0, saved: teams });
  }

  let accessToken: string;
  try {
    accessToken = await refreshAccessToken(token.refresh_token as string);
  } catch (_) {
    await admin.rpc("backfill_calendar_jobs", { p_user: userId });
    return json({ rewritten: 0, saved: teams, deferred: true });
  }
  const calendars = {
    primary: token.google_calendar_id as string,
    secondary: secondaryCalendarIdOf(link, token as { google_calendar_id_secondary: string | null }),
  };

  // Matches of the teams that were dropped ENTIRELY (present before, gone
  // now): their events are deleted outright. The list is read with the OLD
  // choice re-applied through the same "live future match" rule, so nothing
  // past or foreign is touched; a derby where only one of the two teams was
  // dropped is correctly left alone (still followed via the other team).
  const savedNames = new Set(teams.map((t) => t.team));
  const dropped = previousTeams.filter((t) => !savedNames.has(t.team));
  let removed = 0;
  if (dropped.length > 0) {
    const droppedNames = new Set(dropped.map((t) => t.team));
    const { data: profile } = await admin.from("profiles")
      .select("tenant_id").eq("id", userId).maybeSingle();
    const { data: gone } = await admin.from("priority_slots")
      .select("id, home_team, away_team")
      .eq("tenant_id", profile?.tenant_id)
      .is("parent_id", null)
      .gte("date", new Date().toISOString().slice(0, 10));
    for (const row of (gone ?? []) as { id: string; home_team: string; away_team: string }[]) {
      const stillFollowed = savedNames.has(row.home_team) || savedNames.has(row.away_team);
      const wasFollowed = droppedNames.has(row.home_team) || droppedNames.has(row.away_team);
      if (stillFollowed || !wasFollowed) continue;
      const eventId = await matchEventId(userId, row.id);
      // The dropped team could have been assigned to either calendar —
      // delete from every one its event could be sitting in (idempotent:
      // the one it was never in just answers 404/410 = "ok").
      const results = await Promise.all(
        possibleMatchCalendars(calendars).map((calendarId) =>
          deleteEvent(accessToken, calendarId, eventId)
        ),
      );
      if (results.every((r) => r === "ok")) removed++;
    }
  }

  const { written, sweepFailed } = await writeFutureMatches(admin, userId, accessToken, calendars);
  const { data: total } = await admin.rpc("my_future_matches", { p_user: userId });
  const failed = written < ((total ?? []) as unknown[]).length || sweepFailed;
  if (failed) await admin.rpc("backfill_calendar_jobs", { p_user: userId });
  return json({ rewritten: written, removed, saved: teams, deferred: failed });
}

/** Stores the colour of one or more followed teams (team_colors, 0036) and
 * repaints every future match so it shows at once — same "the player is
 * watching" reasoning as setTrainingColor, but for MATCHES (trainings have
 * no team) and for potentially several teams in one call rather than one
 * scalar. Unlike setTeams this never drops or adds a followed team or
 * changes any routing — set_team_colors_for is a PARTIAL upsert of only the
 * named teams' colours — so there is nothing to delete here, only to
 * rewrite. `colors` was already validated by the caller
 * (validateTeamColors). Whatever fails is caught up by a job. Returns the
 * stored colours. */
async function setTeamColors(
  userId: string,
  colors: { team: string; color_id: number | null }[],
): Promise<Response> {
  // set_team_colors_for (0036) returns the PREVIOUS state of only the named
  // teams — bounds (≤ 40 items, colour 1-11) are enforced by the RPC itself
  // (item count) and the table's own CHECK (colour), surfacing as a generic
  // Postgres error, same as "bad_colors" to the caller; the item shape
  // itself was already validated above.
  const { error } = await admin.rpc("set_team_colors_for", {
    p_user: userId,
    p_colors: colors,
  });
  if (error) {
    console.error(`set team colours failed for ${userId}:`, error);
    return json({ error: "bad_colors" }, 400);
  }

  const { data: link } = await admin.from("google_calendar_links")
    .select("status, secondary_enabled").eq("user_id", userId).maybeSingle();
  if (link?.status !== "linked") return json({ rewritten: 0, saved: colors });

  const { data: token } = await admin.from("google_calendar_tokens")
    .select("refresh_token, google_calendar_id, google_calendar_id_secondary")
    .eq("user_id", userId).maybeSingle();
  if (!token?.refresh_token || !token.google_calendar_id) {
    return json({ rewritten: 0, saved: colors });
  }

  let accessToken: string;
  try {
    accessToken = await refreshAccessToken(token.refresh_token as string);
  } catch (_) {
    // Stored either way; a job repaints the events once Google answers.
    await admin.rpc("backfill_calendar_jobs", { p_user: userId });
    return json({ rewritten: 0, saved: colors, deferred: true });
  }
  const calendars = {
    primary: token.google_calendar_id as string,
    secondary: secondaryCalendarIdOf(
      link,
      token as { google_calendar_id_secondary: string | null },
    ),
  };

  const { written, sweepFailed } = await writeFutureMatches(
    admin,
    userId,
    accessToken,
    calendars,
  );
  const { data: total } = await admin.rpc("my_future_matches", {
    p_user: userId,
  });
  const failed = written < ((total ?? []) as unknown[]).length || sweepFailed;
  if (failed) await admin.rpc("backfill_calendar_jobs", { p_user: userId });
  return json({ rewritten: written, saved: colors, deferred: failed });
}

/** Turns the player's second Google calendar ("Rezervátor 2") on or off and
 * settles matches on the spot, same "the player is watching" reasoning as
 * every other action here.
 *
 * ON: creates the calendar (unless one already exists — idempotent against
 * a repeat call), stores its id, flips `secondary_enabled`, then rewrites
 * every future match so whichever teams were already pointed at 'secondary'
 * in calendar_teams (chosen ahead of the toggle — matchTarget tolerates
 * that) actually land there now.
 *
 * OFF: deletes the calendar in Google FIRST — deleting a calendar takes its
 * events with it, so there is no per-event cleanup to do on the way out,
 * mirroring disconnect()'s "the calendar must go before we let go of the
 * token" ordering — only then clears the stored id, flips
 * `secondary_enabled` off, and resets every calendar_teams row pointed at
 * 'secondary' back to 'primary' (so the picker in Můj profil, hidden once
 * the toggle is off, does not silently keep a choice nothing shows any
 * more). Rewriting future matches then lands those teams' events in the
 * primary calendar, same as a player who never turned it on.
 *
 * A retryable Google failure (5xx, network) changes NOTHING and returns an
 * error, same as disconnect(); only a revoked grant (invalid_grant) is
 * treated as terminal for the OFF direction — the calendar is unreachable
 * and will never be deletable, so the player's own tidy-up still goes
 * through, exactly like disconnect()'s "grant already revoked" case. */
async function setSecondary(userId: string, enabled: boolean): Promise<Response> {
  const { data: link } = await admin.from("google_calendar_links")
    .select("status, secondary_enabled").eq("user_id", userId).maybeSingle();
  if (link?.status !== "linked") return json({ error: "not_linked" }, 400);

  const { data: token } = await admin.from("google_calendar_tokens")
    .select("refresh_token, google_calendar_id, google_calendar_id_secondary")
    .eq("user_id", userId).maybeSingle();
  if (!token?.refresh_token || !token.google_calendar_id) {
    return json({ error: "not_linked" }, 400);
  }
  const calendarId = token.google_calendar_id as string;
  let secondaryId = token.google_calendar_id_secondary as string | null;

  // Idempotent no-ops: a repeat tap (or a race between two devices) should
  // not re-create or re-delete anything.
  if (enabled && link.secondary_enabled === true && secondaryId) {
    return json({ enabled: true });
  }
  if (!enabled && link.secondary_enabled !== true && !secondaryId) {
    return json({ enabled: false });
  }

  if (!enabled) {
    let accessToken: string;
    try {
      accessToken = await refreshAccessToken(token.refresh_token as string);
    } catch (error) {
      if (!(error instanceof GoogleAuthError && error.code === "invalid_grant")) {
        console.error(`secondary off: token refresh failed for ${userId}:`, error);
        return json({ error: "google_unavailable" }, 503);
      }
      // Terminal: access is gone, the calendar (if any) can never be
      // deleted now — tidy up our side anyway and say so, same reasoning
      // as disconnect()'s "grant already revoked" branch.
      await admin.from("google_calendar_tokens")
        .update({ google_calendar_id_secondary: null }).eq("user_id", userId);
      await admin.from("google_calendar_links")
        .update({ secondary_enabled: false, updated_at: new Date().toISOString() })
        .eq("user_id", userId);
      await admin.from("calendar_teams")
        .update({ calendar: "primary" })
        .eq("user_id", userId).eq("calendar", "secondary");
      return json({ enabled: false, orphaned: !!secondaryId });
    }

    // Told the same way disconnect() tells it: an "auth" delete means the
    // calendar is left behind in Google with nothing the app can do about
    // it, so the player needs to hear that rather than a plain "off".
    let orphaned = false;
    if (secondaryId) {
      const result = await deleteCalendar(accessToken, secondaryId);
      if (result === "retry") {
        // Nothing was changed — let the player try again, the state is whole.
        return json({ error: "google_unavailable" }, 503);
      }
      if (result === "auth") orphaned = true;
      if (result !== "ok") {
        console.warn(`secondary off: calendar delete ended as ${result}`);
      }
    }
    await admin.from("google_calendar_tokens")
      .update({ google_calendar_id_secondary: null }).eq("user_id", userId);
    await admin.from("google_calendar_links")
      .update({ secondary_enabled: false, updated_at: new Date().toISOString() })
      .eq("user_id", userId);
    await admin.from("calendar_teams")
      .update({ calendar: "primary" })
      .eq("user_id", userId).eq("calendar", "secondary");

    const { written, sweepFailed } = await writeFutureMatches(admin, userId, accessToken, {
      primary: calendarId,
      secondary: null,
    });
    const { data: total } = await admin.rpc("my_future_matches", { p_user: userId });
    const failed = written < ((total ?? []) as unknown[]).length || sweepFailed;
    if (failed) await admin.rpc("backfill_calendar_jobs", { p_user: userId });
    return json({ enabled: false, rewritten: written, deferred: failed, orphaned });
  }

  // ON.
  let accessToken: string;
  try {
    accessToken = await refreshAccessToken(token.refresh_token as string);
  } catch (error) {
    console.error(`secondary on: token refresh failed for ${userId}:`, error);
    return json({ error: "google_unavailable" }, 503);
  }

  if (!secondaryId) {
    try {
      secondaryId = await createSecondaryCalendar(
        accessToken,
        "Rezervátor 2",
        CALENDAR_DESCRIPTION_SECONDARY,
      );
    } catch (error) {
      // Nothing was changed — same "retry, the state is whole" contract as
      // every other Google call in this file (see disconnect()).
      console.error(`secondary on: calendar create failed for ${userId}:`, error);
      return json({ error: "google_unavailable" }, 503);
    }
    await admin.from("google_calendar_tokens")
      .update({ google_calendar_id_secondary: secondaryId }).eq("user_id", userId);
  }
  await admin.from("google_calendar_links")
    .update({ secondary_enabled: true, updated_at: new Date().toISOString() })
    .eq("user_id", userId);

  const { written, sweepFailed } = await writeFutureMatches(admin, userId, accessToken, {
    primary: calendarId,
    secondary: secondaryId,
  });
  const { data: total } = await admin.rpc("my_future_matches", { p_user: userId });
  const failed = written < ((total ?? []) as unknown[]).length || sweepFailed;
  if (failed) await admin.rpc("backfill_calendar_jobs", { p_user: userId });
  return json({ enabled: true, rewritten: written, deferred: failed });
}

Deno.serve(async (request) => {
  if (request.method === "OPTIONS") {
    return new Response("ok", { headers: CORS_HEADERS });
  }
  try {
    const authorization = request.headers.get("Authorization");
    if (!authorization) return json({ error: "unauthorized" }, 401);

    // A client with the player's JWT — only to learn WHO is calling. The
    // writes are done by the service-role client (RLS on these tables keeps
    // the client out).
    const asUser = createClient(
      SUPABASE_URL,
      Deno.env.get("SUPABASE_ANON_KEY")!,
      { global: { headers: { Authorization: authorization } } },
    );
    const { data: { user } } = await asUser.auth.getUser();
    if (!user) return json({ error: "unauthorized" }, 401);

    const body = await request.json().catch(() => ({}));
    if (body?.action === "disconnect") return await disconnect(user.id);
    if (body?.action === "reminders") {
      const minutes = Array.isArray(body.minutes)
        ? body.minutes.map((m: unknown) => Number(m)).filter(Number.isFinite)
        : [];
      const calendarRaw = body.calendar;
      if (
        calendarRaw != null && calendarRaw !== "primary" &&
        calendarRaw !== "secondary"
      ) {
        return json({ error: "bad_calendar" }, 400);
      }
      const calendar = calendarRaw === "secondary" ? "secondary" : "primary";
      return await setReminders(user.id, minutes, calendar);
    }
    if (body?.action === "teams") {
      const teams = validateTeamChoices(body.teams);
      if (teams === null) return json({ error: "bad_teams" }, 400);
      return await setTeams(user.id, teams);
    }
    if (body?.action === "team_colors") {
      const colors = validateTeamColors(body.team_colors);
      if (colors === null) return json({ error: "bad_colors" }, 400);
      return await setTeamColors(user.id, colors);
    }
    if (body?.action === "match_teams") {
      // The shipped 1.2.1 app's action: a bare team-name string[], no
      // calendar — see the header comment and mapLegacyMatchTeams. An older
      // client is still just a client: the mapped result goes through the
      // very same validateTeamChoices as `teams`, or a long enough name
      // would walk straight past the caps into the table.
      if (!Array.isArray(body.teams)) return json({ error: "bad_teams" }, 400);
      const names = body.teams.filter((t: unknown) => typeof t === "string");
      const { data: current } = await admin.from("calendar_teams")
        .select("team, calendar").eq("user_id", user.id);
      const teams = validateTeamChoices(
        mapLegacyMatchTeams(names, (current ?? []) as TeamChoice[]),
      );
      if (teams === null) return json({ error: "bad_teams" }, 400);
      return await setTeams(user.id, teams);
    }
    if (body?.action === "secondary") {
      if (typeof body.enabled !== "boolean") {
        return json({ error: "bad_enabled" }, 400);
      }
      return await setSecondary(user.id, body.enabled);
    }
    if (body?.action === "training_color") {
      const raw = body.color_id;
      if (raw !== null && raw !== undefined && !isEventColorId(raw)) {
        return json({ error: "bad_color" }, 400);
      }
      return await setTrainingColor(user.id, raw == null ? null : Number(raw));
    }
    return json({ error: "unknown_action" }, 400);
  } catch (error) {
    console.error("calendar-manage failed:", error);
    return json({ error: "internal" }, 500);
  }
});
