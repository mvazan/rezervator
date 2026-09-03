// calendar-manage — actions on the linked calendar that the player asked for
// and that must finish before the app shows the result.
//
// `disconnect` and `reminders`. Deployed WITHOUT --no-verify-jwt (unlike
// notify and calendar-oauth-callback): a signed-in player calls it from the
// app through functions.invoke, which attaches their JWT, and the platform
// verifies it before the function even runs. Inside we still ask
// auth.getUser() — without a session the client sends only the anon key and
// that yields no user.
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
// CORS: the app also runs as a PWA on mvazan.github.io, where
// functions.invoke is a cross-origin fetch with a preflight — OPTIONS is
// answered and every reply stamped, otherwise the browser build could never
// disconnect. The JWT check above is the actual gate; the origin is not.

import { createClient } from "@supabase/supabase-js";
import {
  deleteCalendar,
  GoogleAuthError,
  refreshAccessToken,
  revokeToken,
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
 * reminder_minutes, so the reminders come back by themselves after a new
 * link. The Google e-mail is personal data — no reason to keep it once
 * disconnected. */
async function forget(userId: string) {
  await admin.from("google_calendar_tokens").delete().eq("user_id", userId);
  await admin.from("google_calendar_links")
    .update({
      status: "unlinked",
      google_email: null,
      last_error: null,
      updated_at: new Date().toISOString(),
    })
    .eq("user_id", userId);
}

async function disconnect(userId: string): Promise<Response> {
  const { data: token } = await admin.from("google_calendar_tokens")
    .select("refresh_token, google_calendar_id")
    .eq("user_id", userId).maybeSingle();

  // Nothing to disconnect (never linked / already done / a second tap) or
  // only a token without a calendar (a failed link) — just tidy up.
  if (!token?.refresh_token) {
    await forget(userId);
    return json({ orphaned: false });
  }
  const calendarId = token.google_calendar_id as string | null;

  let accessToken: string | null = null;
  try {
    accessToken = await refreshAccessToken(token.refresh_token as string);
  } catch (error) {
    if (!(error instanceof GoogleAuthError && error.code === "invalid_grant")) {
      console.error(`disconnect: token refresh failed for ${userId}:`, error);
      return json({ error: "google_unavailable" }, 503);
    }
    // Access is gone (revoked in the Google account, expired). The calendar
    // cannot be deleted — and never will be; say so and tidy up our side.
    console.warn(`disconnect: grant already revoked for ${userId}`);
    await forget(userId);
    return json({ orphaned: !!calendarId });
  }

  if (calendarId) {
    const result = await deleteCalendar(accessToken, calendarId);
    if (result === "retry") {
      // Nothing was changed — let the player try again, the state is whole.
      return json({ error: "google_unavailable" }, 503);
    }
    // "ok" (404/410 included = already gone) as well as "auth"/"gone" mean
    // there is no way left to delete this calendar; carry on tidying up.
    if (result !== "ok") {
      console.warn(`disconnect: calendar delete ended as ${result}`);
    }
  }

  await revokeToken(token.refresh_token as string);
  await forget(userId);
  return json({ orphaned: false });
}

/** Stores the reminders preference and writes it RIGHT AWAY into every
 * future reservation. The events carry the reminders themselves
 * (calendarList is off limits under this scope), so "change the reminder"
 * = rewrite the events. Through jobs it took two turns of the minutely cron
 * (~2 min) and looked as if nothing happened; the player is watching, so it
 * is done on the spot. Whatever fails is caught up by a job — the count of
 * rewritten events and the remainder flag are returned. */
async function setReminders(
  userId: string,
  minutes: number[],
): Promise<Response> {
  // Normalisation and validation live in the RPC (0023) — it is the source
  // of truth; here it is only called on the player's behalf.
  const { error } = await admin.rpc("set_calendar_reminders_for", {
    p_user: userId,
    p_minutes: minutes,
  });
  if (error) {
    console.error(`set reminders failed for ${userId}:`, error);
    return json({ error: "bad_reminders" }, 400);
  }

  const { data: link } = await admin.from("google_calendar_links")
    .select("status, reminder_minutes").eq("user_id", userId).maybeSingle();
  const saved = (link?.reminder_minutes as number[] | null) ?? [];
  if (link?.status !== "linked") return json({ rewritten: 0, saved });

  const { data: token } = await admin.from("google_calendar_tokens")
    .select("refresh_token, google_calendar_id")
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

  const written = await writeFutureReservations(
    admin,
    userId,
    accessToken,
    token.google_calendar_id as string,
  );
  const { data: total } = await admin.rpc("my_future_reservations", {
    p_user: userId,
  });
  const failed = written < ((total ?? []) as unknown[]).length;
  // Whatever did not go through is caught up by a job — the preference is
  // stored, so nothing is lost.
  if (failed) await admin.rpc("backfill_calendar_jobs", { p_user: userId });
  return json({ rewritten: written, saved, deferred: failed });
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
      return await setReminders(user.id, minutes);
    }
    return json({ error: "unknown_action" }, 400);
  } catch (error) {
    console.error("calendar-manage failed:", error);
    return json({ error: "internal" }, 500);
  }
});
