// calendar-oauth-callback — the return leg of the Google OAuth consent.
//
// Public GET (deployed with --no-verify-jwt): Google cannot attach a Supabase
// JWT to its redirect. Trust rides on the one-time `state` nonce from
// start_calendar_link() (0023) — unguessable, single use, 10-minute TTL,
// issued only to a signed-in approved player. Tokens are decided here, so
// they NEVER travel back to the app: they land in google_calendar_tokens and
// the app only ever sees the status in google_calendar_links.
//
// Secrets: GOOGLE_CLIENT_ID, GOOGLE_CLIENT_SECRET.
// SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY are injected automatically.

import { createClient } from "@supabase/supabase-js";
import {
  calendarExists,
  createSecondaryCalendar,
  emailFromIdToken,
  exchangeCode,
  writeFutureReservations,
} from "../_shared/google_calendar.ts";

const supabase = createClient(
  Deno.env.get("SUPABASE_URL")!,
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
);

/** Must match BYTE FOR BYTE the redirect_uri the app sends
 * (AppConfig.calendarRedirectUri) and the Authorized redirect URI in the
 * Google Cloud Console. */
const REDIRECT_URI = `${
  Deno.env.get("SUPABASE_URL")
}/functions/v1/calendar-oauth-callback`;

/** The result is shown on a static page on GitHub Pages, not from here: the
 * edge runtime rewrites the Content-Type to text/plain (and sends nosniff),
 * so HTML returned by this function would render as source code, mangled
 * diacritics included. A redirect passes through untouched.
 *
 * No deep link back into the app (there is no router for it; the profile
 * card flips on its own through Realtime as soon as the result is written
 * here). The page ships with the Flutter web build: web/calendar-linked.html
 * lands in the site root under /rezervator/. */
const RESULT_PAGE = "https://mvazan.github.io/rezervator/calendar-linked.html";

type Stav = "ok" | "zruseno" | "odkaz" | "google" | "kalendar" | "chyba";

function page(stav: Stav): Response {
  return Response.redirect(`${RESULT_PAGE}?stav=${stav}`, 302);
}

Deno.serve(async (request) => {
  const url = new URL(request.url);
  const code = url.searchParams.get("code");
  const state = url.searchParams.get("state");

  if (url.searchParams.get("error")) {
    return page("zruseno");
  }
  if (!code || !state) {
    return page("odkaz");
  }

  // 1. Nonce -> the user it was bound to (and consume it: single use).
  const { data: userId, error: nonceError } = await supabase
    .rpc("consume_calendar_nonce", { p_nonce: state });
  if (nonceError) {
    // A failed call (a missing grant, say) is not the same as an expired
    // link — telling the player "try again" would send them in circles.
    console.error("consume_calendar_nonce failed:", nonceError);
    return page("chyba");
  }
  if (!userId) {
    return page("odkaz");
  }

  // 2. Code -> tokens.
  let tokens;
  try {
    tokens = await exchangeCode(code, REDIRECT_URI);
  } catch (error) {
    console.error("code exchange failed:", error);
    return page("google");
  }
  if (!tokens.refreshToken) {
    // The app sends access_type=offline&prompt=consent, so a refresh token
    // is expected. When it is missing, fail loudly rather than store half.
    console.error("no refresh_token in token response");
    return page("google");
  }

  // The previous calendar id, BEFORE the tokens are overwritten: a candidate
  // for reuse. (The reminders preference on the links row survives too —
  // a disconnect only strips the tokens — and every event the backfill
  // below creates carries it.)
  const { data: previous } = await supabase.from("google_calendar_tokens")
    .select("google_calendar_id").eq("user_id", userId).maybeSingle();
  const previousCalendarId = previous?.google_calendar_id as string | null;
  const now = new Date().toISOString();
  const { error: tokenError } = await supabase.from("google_calendar_tokens")
    .upsert({
      user_id: userId,
      refresh_token: tokens.refreshToken,
      google_calendar_id: previousCalendarId,
      updated_at: now,
    });
  // reminder_minutes is deliberately NOT sent: on-conflict overwrites only
  // the columns sent, so the preference survives this upsert.
  const { error: linkError } = await supabase.from("google_calendar_links")
    .upsert({
      user_id: userId,
      status: "pending",
      google_email: emailFromIdToken(tokens.idToken),
      last_error: null,
      updated_at: now,
    });
  if (tokenError || linkError) {
    console.error("link save failed:", tokenError ?? linkError);
    return page("chyba");
  }

  // 3. The calendar is handled right away, not through a job: the player is
  // watching, and waiting minutes for "propojeno" would feel wrong. When it
  // fails, the token stays stored (status pending) and linking again works
  // without a fresh consent. Inside a LIVE grant the earlier calendar is
  // reused (repeated "Zkusit znovu" makes no duplicates); across a revoked
  // consent the app cannot reach it (get 404) and a fresh one is created.
  try {
    const reusable = previousCalendarId &&
      await calendarExists(tokens.accessToken, previousCalendarId);
    const calendarId = reusable
      ? previousCalendarId
      : await createSecondaryCalendar(tokens.accessToken);
    await supabase.from("google_calendar_tokens")
      .update({ google_calendar_id: calendarId, updated_at: now })
      .eq("user_id", userId);
    await supabase.from("google_calendar_links")
      .update({ status: "linked", updated_at: now })
      .eq("user_id", userId);

    // Reservations are written right here, not through jobs: after linking
    // the player opens the calendar and wants to see their trainings, not an
    // empty grid and "it shows up in a minute". The reminders ride on the
    // events themselves (calendarList is off limits under this scope), so
    // this restores them as well. Whatever fails is caught up by a job —
    // that is why they are enqueued regardless.
    const { data: enqueued } = await supabase
      .rpc("backfill_calendar_jobs", { p_user: userId });
    const written = await writeFutureReservations(
      supabase,
      userId,
      tokens.accessToken,
      calendarId,
    );
    console.log(
      `calendar linked for ${userId} (${reusable ? "reused" : "created"}), ` +
        `${written} reservations written, ${enqueued} jobs queued as backup`,
    );
    return page("ok");
  } catch (error) {
    console.error("calendar creation failed:", error);
    await supabase.from("google_calendar_links")
      .update({
        last_error: "Kalendář se nepodařilo založit.",
        updated_at: now,
      })
      .eq("user_id", userId);
    return page("kalendar");
  }
});
