// notify — push/e-mail notifications for Rezervátor.
//
// Triggered by Supabase Database Webhooks (triggers in 0001_schema.sql) on:
//   INSERT profiles      -> "new player waiting for approval" (to admins)
//   INSERT reservations  -> kiosk booking confirmation to the player; or,
//                           created_via = 'group' (0044) or 'duty' (0050,
//                           the player on duty), "X ti zarezervoval(a)
//                           trénink" to the player it's for. All three: the
//                           push opens the calendar at the reservation, the
//                           e-mail carries a one-click cancel link
//   UPDATE reservations  -> admin cancelled an upcoming reservation, or an
//                           admin MOVED it ("termín přesunut z X na Y") —
//                           both honour the per-change notify_player flag +
//                           optional notify_message the RPCs stamp (0011);
//                           a cancel by the player on duty (cancelled_via
//                           'duty', 0050) the same way, with "zrušil(a) X
//                           (služba na kantýně)" as the default reason;
//                           or, cancelled_via = 'group' (0044), "X ti zrušil(a)
//                           trénink" to the player it was for
//                           and ANY cancellation of an upcoming reservation
//                           (0058): the player's who watch that day get "a
//                           spot was freed", when it is really bookable again
//   INSERT tenants       -> "new kuželna waiting for approval" (to the
//                           superadmins — trigger added in 0014)
//   INSERT/UPDATE player_group_members -> player-group notifications (0044):
//                           an invite (to the invitee), and a new member
//                           joining (to the rest of the group)
//   INSERT messages       -> a new notice or message (0051) fans out to its
//                           already-materialised recipients, unless
//                           notify = false
//   UPDATE message_recipients (reaction/reply) -> notifies the message's
//                           author, unless it was cleared
//   CRON notification_jobs -> deferred jobs (0023): Google Calendar sync —
//                           the one branch that talks to the Calendar API
//                           instead of FCM/Resend. Posted by the minutely
//                           pg_cron tick through the same Vault-configured
//                           webhook (URL + x-webhook-secret). The same tick
//                           also carries the due reminders (0040): "za 2
//                           hodiny trénink", by the same push-or-e-mail
//                           rule as everything else — and, after them, the
//                           reminder before a canteen duty (0050): "Zítra
//                           sloužíš na kantýně".
//   CRON notification_jobs -> federation_* jobs (0045): vysledky.kuzelky.cz sync
//
// Channel per recipient: FCM push when profiles.fcm_token is set AND
// FIREBASE_SERVICE_ACCOUNT is configured; otherwise e-mail via Resend.
// Secrets: WEBHOOK_SECRET, RESEND_API_KEY, CANCEL_TOKEN_SECRET,
// GOOGLE_CLIENT_ID / GOOGLE_CLIENT_SECRET (the OAuth client for the
// Calendar sync), optional FIREBASE_SERVICE_ACCOUNT, optional RESEND_FROM.
// SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY are injected automatically.
// Deploy with --no-verify-jwt (DB triggers can't mint JWTs; the
// x-webhook-secret header is the gate).

import { createClient } from "@supabase/supabase-js";
import { pragueEpoch, pragueToday, signCancelToken } from "../_shared/cancel_token.ts";
import { firebaseConfigured, sendPush } from "../_shared/fcm.ts";
import { processFederationJobs, siteFetcher } from "../_shared/federation_jobs.ts";
import { dayLabel, escapeHtml, timeLabel } from "../_shared/format.ts";
import type { Delivery } from "../_shared/delivery.ts";
import {
  resendBatch,
  type ResendConfig,
  resendEmail,
  resendOneOfBatch,
} from "../_shared/resend.ts";
import { deliverDueReminders, type DueReminder } from "../_shared/reminders.ts";
import {
  deliverDueDutyReminders,
  dutyCancelReason,
  type DueDutyReminder,
  dutyReminderHtml,
  dutyReminderReceipt,
} from "../_shared/duty_reminders.ts";
import { freedSpotMessage } from "../_shared/freed_spot.ts";
import {
  groupBookedMessage,
  groupCancelledMessage,
  groupInviteMessage,
  groupJoinedMessage,
} from "../_shared/group_messages.ts";
import { signReactToken } from "../_shared/react_token.ts";
import {
  deliverMessage,
  deliverReaction,
  type MessageRecipientRow,
  type MessageRow,
  reactionChange,
} from "../_shared/message_notify.ts";
import {
  appPlayersUrl,
  appTenantsUrl,
  messageContext,
} from "../_shared/message_texts.ts";
import type { Membership } from "../_shared/membership.ts";
import {
  clearSecondaryCalendar,
  deleteEvent,
  eventIdFor,
  GoogleAuthError,
  matchEventBody,
  matchEventId,
  matchTarget,
  type MatchRow,
  possibleMatchCalendars,
  refreshAccessToken,
  reservationEventBody,
  upsertEvent,
  type WriteResult,
  worstResult,
} from "../_shared/google_calendar.ts";

const supabase = createClient(
  Deno.env.get("SUPABASE_URL")!,
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
);

// ---------------------------------------------------------------------------
// E-mail via Resend
// ---------------------------------------------------------------------------

/// RESEND_API_KEY / RESEND_FROM as read now, and the real fetch.
function resendConfig(): ResendConfig {
  return {
    apiKey: Deno.env.get("RESEND_API_KEY"),
    from: Deno.env.get("RESEND_FROM") ?? "Rezervátor <onboarding@resend.dev>",
    fetch,
  };
}

async function sendEmail(
  to: string,
  subject: string,
  html: string,
): Promise<Delivery> {
  return await resendEmail({ to, subject, html }, resendConfig());
}

type Recipient = {
  id: string;
  email: string;
  fcm_token: string | null;
};

/// Push when possible, e-mail otherwise. Says what became of it; only the
/// reminders act on that (a retry stays due), every other message is sent
/// once, as before.
async function notifyRecipient(
  recipient: Recipient,
  title: string,
  body: string,
  options: { data?: Record<string, string>; html?: string } = {},
): Promise<Delivery> {
  if (firebaseConfigured() && recipient.fcm_token) {
    return await sendPush(
      supabase,
      recipient.id,
      recipient.fcm_token,
      title,
      body,
      options.data,
    );
  }
  return await sendEmail(
    recipient.email,
    title,
    options.html ?? `<p>${escapeHtml(body)}</p>`,
  );
}

// ---------------------------------------------------------------------------
// Google Calendar sync (0023)
// ---------------------------------------------------------------------------

/** Link + tokens of one player, or null (not linked / broken / the primary
 * calendar was never created) — then nothing is synced, silently.
 * `secondaryCalendarId` is gated on `secondary_enabled` even though it lives
 * in a separate table: the two are meant to change together (calendar-manage
 * clears both on the way out), and gating here is one more guard against a
 * stale id ever being treated as live if they ever drifted apart. */
type CalendarLinkInfo = {
  refreshToken: string;
  calendarId: string;
  secondaryCalendarId: string | null;
  reminderMinutes: number[];
  reminderMinutesSecondary: number[];
  trainingColorId: number | null;
};

async function calendarLink(userId: string): Promise<CalendarLinkInfo | null> {
  const { data: link } = await supabase.from("google_calendar_links")
    .select(
      "status, secondary_enabled, reminder_minutes, reminder_minutes_secondary, training_color_id",
    )
    .eq("user_id", userId).maybeSingle();
  if (link?.status !== "linked") return null;
  const { data: token } = await supabase.from("google_calendar_tokens")
    .select("refresh_token, google_calendar_id, google_calendar_id_secondary")
    .eq("user_id", userId).maybeSingle();
  if (!token?.refresh_token || !token.google_calendar_id) return null;
  return {
    refreshToken: token.refresh_token as string,
    calendarId: token.google_calendar_id as string,
    secondaryCalendarId: link.secondary_enabled
      ? (token.google_calendar_id_secondary as string | null) ?? null
      : null,
    reminderMinutes: (link.reminder_minutes as number[] | null) ?? [],
    reminderMinutesSecondary:
      (link.reminder_minutes_secondary as number[] | null) ?? [],
    trainingColorId: (link.training_color_id as number | null) ?? null,
  };
}

/** The link is dead (revoked consent, deleted calendar, expired token) —
 * Můj profil offers to link again, and the player hears about it once
 * (push when they have a token, e-mail otherwise), so they don't find out a
 * month later when a training was missing from the calendar.
 *
 * The `status = linked` condition does two things at once: the notice goes
 * out only on the TRANSITION to broken (further failing jobs of the same
 * player send nothing; a race is settled by the row lock — the second
 * UPDATE sees broken after waiting and returns no row), and a disconnect
 * that finished while the job was talking to Google is not overwritten
 * from the fresh 'unlinked' back to 'broken'. It is a service message about
 * a feature the player switched on themselves, so no preference gates it. */
async function markCalendarBroken(userId: string, reason: string) {
  console.error(`calendar link broken for ${userId}: ${reason}`);
  const { data: flipped } = await supabase.from("google_calendar_links")
    .update({
      status: "broken",
      last_error: reason,
      updated_at: new Date().toISOString(),
    })
    .eq("user_id", userId)
    .eq("status", "linked")
    .select("user_id");
  if (!flipped?.length) return;

  const { data: profile } = await supabase.from("profiles")
    .select("id, email, fcm_token").eq("id", userId).maybeSingle();
  if (!profile) return;
  await notifyRecipient(
    profile as Recipient,
    "Google kalendář se odpojil",
    "Tréninky se přestaly synchronizovat. Propoj kalendář znovu v Můj profil.",
    { data: { kind: "calendar_broken" } },
  );
}

/** What the calendar should show for this reservation — or null when it is
 * (no longer) this player's live future training: deleted, re-assigned to
 * someone else, cancelled, or already past (backfill and
 * my_future_reservations draw the same line at Prague-today). Revalidation:
 * the truth is the DB at run time, not the job payload. Trainings always go
 * to the primary calendar, with the player's own training colour. */
async function reservationEvent(
  userId: string,
  reservationId: string,
  link: CalendarLinkInfo,
) {
  const { data: reservation } = await supabase.from("reservations")
    .select("player_id, date, block_id, lane, cancelled_at, tenant_id")
    .eq("id", reservationId).maybeSingle();
  if (!reservation) return null;
  if (reservation.player_id !== userId) return null;
  if (reservation.cancelled_at !== null) return null;
  if ((reservation.date as string) < pragueToday()) return null;

  const [{ data: block }, { data: tenant }] = await Promise.all([
    supabase.from("time_blocks").select("starts_at, ends_at")
      .eq("id", reservation.block_id).maybeSingle(),
    supabase.from("tenants").select("name")
      .eq("id", reservation.tenant_id).maybeSingle(),
  ]);
  if (!block || !tenant) return null;

  return reservationEventBody(
    {
      date: reservation.date as string,
      starts_at: block.starts_at as string,
      ends_at: block.ends_at as string,
      lane: reservation.lane as number,
      alley_name: tenant.name as string,
    },
    link.reminderMinutes,
    link.trainingColorId,
  );
}

/** Reconciles one (player, reservation): reality decides whether the event
 * is written (into the primary calendar — trainings never go anywhere
 * else) or deleted. */
async function reservationSync(
  userId: string,
  reservationId: string,
  link: CalendarLinkInfo,
  accessToken: string,
): Promise<WriteResult> {
  const eventId = await eventIdFor(userId, reservationId);
  const event = await reservationEvent(userId, reservationId, link);
  return event
    ? await upsertEvent(accessToken, link.calendarId, eventId, event)
    : await deleteEvent(accessToken, link.calendarId, eventId);
}

/** Reconciles one (player, match): my_future_matches (0032) draws the same
 * "still live and followed" line as everywhere else, so asking it for this
 * one match IS the revalidation, and it already carries the followed team's
 * `calendar`/`color_id`. A live match is written into its target calendar
 * (matchTarget) and swept from the OTHER one, same as writeFutureMatches —
 * and only once the write itself succeeded: deleting first (or regardless)
 * would, on a failed write, leave the match in NEITHER calendar until the
 * next sync. The sweep's own result is folded in too (worstResult): a
 * "retry" there must not be reported as "ok" just because the write
 * succeeded, or a duplicate stuck in the other calendar would never be
 * retried. A match that is no longer live (slot gone, unfollowed, already
 * played) is deleted from every calendar it could be sitting in
 * (possibleMatchCalendars): its event id never changes when a team moves
 * calendars, only where it was last WRITTEN, and that history is not kept —
 * so the only safe cleanup is to try both (idempotent: the one it was never
 * in just answers 404/410 = "ok").
 *
 * A write that lands on the SECONDARY calendar and comes back "gone" (the
 * player deleted "Rezervátor 2" by hand in Google) falls back to the
 * primary instead of propagating "gone" up to jobCalendarSync, which would
 * markCalendarBroken and take EVERY sync down — trainings included — over a
 * calendar that was always optional. The primary itself coming back "gone"
 * still propagates untouched: that really is the whole link gone. */
async function matchSync(
  userId: string,
  matchId: string,
  link: CalendarLinkInfo,
  accessToken: string,
): Promise<WriteResult> {
  const { data } = await supabase.rpc("my_future_matches", { p_user: userId });
  const row = ((data ?? []) as MatchRow[])
    .find((m) => m.match_id === matchId);
  const eventId = await matchEventId(userId, matchId);
  const calendars = { primary: link.calendarId, secondary: link.secondaryCalendarId };

  if (!row) {
    const results = await Promise.all(
      possibleMatchCalendars(calendars).map((calendarId) =>
        deleteEvent(accessToken, calendarId, eventId)
      ),
    );
    return worstResult(results);
  }

  const { match_id: _ignored, ...source } = row;
  let to = matchTarget(row.calendar, calendars);
  let result = await upsertEvent(
    accessToken,
    to.calendarId,
    eventId,
    matchEventBody(
      source,
      to.secondary ? link.reminderMinutesSecondary : link.reminderMinutes,
      row.color_id,
    ),
  );

  if (result === "gone" && to.secondary) {
    console.warn(
      `secondary calendar gone for ${userId}, clearing it and falling back to primary`,
    );
    await clearSecondaryCalendar(supabase, userId);
    to = { calendarId: link.calendarId, otherId: null, secondary: false };
    result = await upsertEvent(
      accessToken,
      to.calendarId,
      eventId,
      matchEventBody(source, link.reminderMinutes, row.color_id),
    );
  }

  const sweep = result === "ok" && to.otherId
    ? await deleteEvent(accessToken, to.otherId, eventId)
    : "ok" as const;
  return worstResult([result, sweep]);
}

/** Reconciles one (player, reservation) or (player, match): reality decides
 * whether the event is written or deleted. Returns false = try again later. */
async function jobCalendarSync(
  payload: Record<string, unknown>,
): Promise<boolean> {
  const userId = payload.user_id as string;
  const reservationId = payload.reservation_id as string | undefined;
  const matchId = payload.match_id as string | undefined;
  if (!userId || (!reservationId && !matchId)) return true;

  const link = await calendarLink(userId);
  if (!link) return true; // not linked — the sync is a personal, optional thing

  let accessToken: string;
  try {
    accessToken = await refreshAccessToken(link.refreshToken);
  } catch (error) {
    if (error instanceof GoogleAuthError && error.code === "invalid_grant") {
      await markCalendarBroken(userId, "Google odvolal přístup.");
      return true; // terminal — until the player links again there is nothing to retry
    }
    console.error(`token refresh failed for ${userId}:`, error);
    return false;
  }

  const result = matchId
    ? await matchSync(userId, matchId, link, accessToken)
    : await reservationSync(userId, reservationId!, link, accessToken);

  switch (result) {
    case "ok":
      return true;
    case "auth":
      await markCalendarBroken(userId, "Chybí oprávnění ke kalendáři.");
      return true;
    case "gone":
      // A delete never returns "gone" (there it counts as success) — this
      // is only a write into a calendar the player deleted in Google.
      await markCalendarBroken(userId, "Kalendář Rezervátor už v Googlu není.");
      return true;
    case "retry":
      return false;
  }
}

/** A new notice or message to its recipients — on the INSERT, or (a notice
 * posted ahead of time) when it shows. */
async function deliverNewMessage(message: MessageRow) {
  const author = await profileOf(message.author_id);
  // A failed load is logged and thrown — the webhook answers 500, which
  // net._http_response shows — never read as "nobody to tell".
  let recipientIds: string[] = [];
  {
    const { data, error } = await supabase.from("message_recipients")
      .select("user_id").eq("message_id", message.id);
    if (error) {
      console.error(`message ${message.id}: recipients not loaded:`, error);
      throw error;
    }
    recipientIds = (data ?? []).map((r) => r.user_id as string);
  }
  if (recipientIds.length === 0) return;
  const { data: recipients, error: profilesError } = await supabase.from("profiles")
    .select("id, email, fcm_token").in("id", recipientIds);
  if (profilesError) {
    console.error(`message ${message.id}: recipient profiles not loaded:`, profilesError);
    throw profilesError;
  }
  let blockTimes: { starts_at: string; ends_at: string } | null = null;
  if (message.block_id) {
    const { data: block } = await supabase.from("time_blocks")
      .select("starts_at, ends_at").eq("id", message.block_id).maybeSingle();
    blockTimes = block as { starts_at: string; ends_at: string } | null;
  }
  const context = messageContext({
    audience: message.audience,
    onDate: message.on_date,
    blockStart: blockTimes?.starts_at ?? null,
    blockEnd: blockTimes?.ends_at ?? null,
  });
  // Fail closed, as the kiosk branch: signing the 👍/👎 links with an
  // empty key would mint links anyone could forge. Checked once here,
  // not in reactLink — deliverMessage logs and skips a recipient whose
  // link throws, which would turn this deployment bug into quiet
  // per-recipient log lines instead of a 500.
  const cancelSecret = Deno.env.get("CANCEL_TOKEN_SECRET");
  if (message.kind === "message" && !cancelSecret) {
    throw new Error("CANCEL_TOKEN_SECRET is not set");
  }
  await deliverMessage(
    message,
    {
      authorName: author?.display_name ?? "?",
      authorIsAdmin: message.author_role === "admin",
      context,
    },
    (recipients ?? []) as Recipient[],
    {
      // notifyRecipient's own choice, so push goes through it.
      byPush: (r) => firebaseConfigured() && !!r.fcm_token,
      push: (r, title, body, opts) => notifyRecipient(r, title, body, opts),
      // One request per 100 e-mails (Resend's per-second rate limit is
      // not in play, and the usual fan-out ends inside the 5 s pg_net
      // waits), under deliverMessage's idempotency key; one by one only
      // as the fallback for a batch refused as invalid — rare, and
      // slower than those 5 s: pg_net records a timeout (no retry)
      // while this runs on. A refusal that is not about the address
      // stops that fallback after its first e-mail (sendOneByOne).
      sendEmails: (emails, key) => resendBatch(emails, key, resendConfig()),
      sendEmail: (email, key) => resendOneOfBatch(email, resendConfig(), key),
      pause: (ms) => new Promise((resolve) => setTimeout(resolve, ms)),
      reactLink: async (userId, reaction) => {
        if (!cancelSecret) throw new Error("CANCEL_TOKEN_SECRET is not set");
        const token = await signReactToken(
          { m: message.id, u: userId, r: reaction },
          cancelSecret,
        );
        return `${Deno.env.get("SUPABASE_URL")}/functions/v1/react?t=${token}`;
      },
    },
  );
}

const CALENDAR_KINDS = new Set(["calendar_sync"]);
const CALENDAR_MAX_ATTEMPTS = 5;
/** How many calendar jobs run at once. Each touches Google twice, so 100
 * jobs in series would easily outgrow the function's time limit. */
const CALENDAR_CONCURRENCY = 5;

/** Cron entry: run every due job once, then drop it. Calendar jobs are the
 * exception: a Google API outage is worth a few retries (an event that was
 * not created does not appear by itself), so their run_at is pushed back
 * with exponential backoff and they are dropped after CALENDAR_MAX_ATTEMPTS.
 * Any other kind is unknown to this build — logged and dropped, so a stray
 * row can never wedge the queue. */
async function processJobs() {
  const { data: jobs } = await supabase.from("notification_jobs")
    .select("id, kind, payload, attempts")
    .lte("run_at", new Date().toISOString())
    .not("kind", "like", "federation_%")
    .limit(100);

  const calendarJobs = (jobs ?? []).filter((job) =>
    CALENDAR_KINDS.has(job.kind as string)
  );
  const noticeJobs = (jobs ?? []).filter((job) =>
    job.kind === "notice_visible"
  );
  const otherJobs = (jobs ?? []).filter((job) =>
    !CALENDAR_KINDS.has(job.kind as string) && job.kind !== "notice_visible"
  );

  // A notice posted ahead of time (0064) pings when it shows. Run once and
  // dropped, like the webhook it stands in for: a moved time re-armed the
  // job, a deleted notice or one switched to silent has nothing to send.
  for (const job of noticeJobs) {
    try {
      const id = (job.payload as { message_id?: string }).message_id;
      const { data: message } = await supabase.from("messages")
        .select("*").eq("id", id).maybeSingle();
      if (message && message.notify) {
        await deliverNewMessage(message as unknown as MessageRow);
      }
    } catch (error) {
      console.error(`job ${job.kind}/${job.id} failed:`, error);
    }
    await supabase.from("notification_jobs").delete().eq("id", job.id);
  }

  for (const job of otherJobs) {
    console.error(`unknown job kind: ${job.kind}`);
    await supabase.from("notification_jobs").delete().eq("id", job.id);
  }

  for (let i = 0; i < calendarJobs.length; i += CALENDAR_CONCURRENCY) {
    await Promise.all(
      calendarJobs.slice(i, i + CALENDAR_CONCURRENCY).map(async (job) => {
        const attempts = (job.attempts as number) ?? 0;
        let done = true;
        try {
          done = await jobCalendarSync(job.payload as Record<string, unknown>);
        } catch (error) {
          // An unexpected error (a bug) — don't loop on it, drop the job.
          console.error(`job ${job.kind}/${job.id} failed:`, error);
        }
        if (!done && attempts < CALENDAR_MAX_ATTEMPTS) {
          const backoffMinutes = 2 ** attempts; // 1, 2, 4, 8, 16
          await supabase.from("notification_jobs")
            .update({
              attempts: attempts + 1,
              run_at: new Date(Date.now() + backoffMinutes * 60_000)
                .toISOString(),
            })
            .eq("id", job.id);
          return;
        }
        await supabase.from("notification_jobs").delete().eq("id", job.id);
      }),
    );
  }
}

// ---------------------------------------------------------------------------
// Reminders before a training or a match (0040)
// ---------------------------------------------------------------------------

/// Everything whose moment has come, sent through the same push-or-e-mail
/// door as every other message, one per event (deliverDueReminders). The
/// ledger is written AFTER it goes out, with the start it was for: a send
/// that throws, or that FCM or Resend could not take just now (busy, down,
/// a dead push token — e-mail then), is simply due again on the next tick,
/// which is the behaviour one wants from a reminder — late beats never.
async function sendDueReminders() {
  const { data, error } = await supabase.rpc("due_reminders");
  if (error) {
    console.error("due_reminders failed:", error);
    return;
  }
  await deliverDueReminders(
    (data ?? []) as DueReminder[],
    new Date(),
    (row, title, body) =>
      notifyRecipient(
        { id: row.user_id, email: row.email, fcm_token: row.fcm_token },
        title,
        body,
        { data: { kind: "reminder" } },
      ),
    async (row) => {
      const { error: markError } = await supabase.rpc("mark_reminder_sent", {
        p_user: row.user_id,
        p_event_key: row.event_key,
        p_offset: row.offset_minutes,
        p_starts_at: row.starts_at,
      });
      if (markError) throw markError;
    },
  );
}

/// The reminder before a canteen duty (0050), by the same rules as the
/// ones above: sent through the usual door (the e-mail adds what the duty
/// may do), marked once delivered or undeliverable, due again next tick
/// otherwise. The receipt is 'd:<period>' at the alley's lead for the
/// duty's first day, so a period moved to other dates rings again.
async function sendDueDutyReminders() {
  const { data, error } = await supabase.rpc("due_duty_reminders");
  if (error) {
    console.error("due_duty_reminders failed:", error);
    return;
  }
  await deliverDueDutyReminders(
    (data ?? []) as DueDutyReminder[],
    new Date(),
    (row, title, body) =>
      notifyRecipient(
        { id: row.user_id, email: row.email, fcm_token: row.fcm_token },
        title,
        body,
        { data: { kind: "duty_reminder" }, html: dutyReminderHtml(row) },
      ),
    async (row) => {
      const { error: markError } = await supabase.rpc(
        "mark_reminder_sent",
        dutyReminderReceipt(row),
      );
      if (markError) throw markError;
    },
  );
}

// ---------------------------------------------------------------------------
// Event handlers
// ---------------------------------------------------------------------------

type WebhookPayload = {
  type: "INSERT" | "UPDATE" | "DELETE" | "CRON";
  table: string;
  record: Record<string, unknown> | null;
  old_record: Record<string, unknown> | null;
};

async function reservationContext(record: Record<string, unknown>) {
  const [playerResult, blockResult] = await Promise.all([
    supabase.from("profiles").select("id, email, fcm_token, display_name")
      .eq("id", record.player_id).single(),
    supabase.from("time_blocks").select("starts_at, ends_at")
      .eq("id", record.block_id).single(),
  ]);
  const player = playerResult.data;
  const block = blockResult.data;
  if (!player || !block) return null;
  const when = `${dayLabel(record.date as string)} ` +
    `${timeLabel(block.starts_at)}–${timeLabel(block.ends_at)}, ` +
    `dráha ${record.lane}`;
  return { player: player as Recipient & { display_name: string }, block, when };
}

/// One profile as a notification recipient (and its name for the text).
async function profileOf(id: unknown) {
  if (id == null) return null;
  const { data } = await supabase.from("profiles")
    .select("id, email, fcm_token, display_name").eq("id", id).maybeSingle();
  return data as (Recipient & { display_name: string }) | null;
}

/// 'po 13.7. 17:30–18:30, dráha 2' for the OLD side of a move — the block
/// row still exists (moves only retarget block_id), so a plain lookup works.
async function whenLabel(record: Record<string, unknown>): Promise<string | null> {
  const { data: block } = await supabase.from("time_blocks")
    .select("starts_at, ends_at").eq("id", record.block_id).single();
  if (!block) return null;
  return `${dayLabel(record.date as string)} ` +
    `${timeLabel(block.starts_at)}–${timeLabel(block.ends_at)}, ` +
    `dráha ${record.lane}`;
}

/// A reservation was cancelled (by anyone, for any reason): tells the players
/// who switched the bell on for that day (0058) that a spot may be free. Which
/// of them hear about it is decided by claim_freed_spot_watchers — only when
/// the cell is bookable again, only the watchers who can book it, and a
/// watcher at most once per ten minutes. Never throws: the cancellation's
/// own notifications must not depend on it.
async function notifyFreedSpot(record: Record<string, unknown>) {
  try {
    const { data: watchers, error } = await supabase.rpc(
      "claim_freed_spot_watchers",
      { p_reservation: record.id },
    );
    if (error) throw error;
    if (!watchers?.length) return;
    const where = await whenLabel(record);
    if (where == null) return;
    const m = freedSpotMessage(where);
    await Promise.all((watchers as { user_id: string; email: string; fcm_token: string | null }[])
      .map((w) =>
        notifyRecipient(
          { id: w.user_id, email: w.email, fcm_token: w.fcm_token },
          m.title,
          m.body,
          {
            // The day, and the cell itself: the app opens the calendar there
            // and outlines the spot while it is still free.
            data: {
              kind: "freed_spot",
              date: String(record.date),
              block_id: String(record.block_id),
              lane: String(record.lane),
              tenant_id: String(record.tenant_id),
            },
            html: `<p>${escapeHtml(m.body)}</p>`,
          },
        )
      ));
  } catch (error) {
    console.error("freed spot notification failed:", error);
  }
}

/// A reservation somebody else made for the player — on the kiosk, by a
/// group mate (0044) or by the player on duty (0050). The push opens the
/// app's calendar at it and outlines it while it is still booked; the
/// e-mail offers a one-click cancel valid until the block starts.
async function notifyBookedFor(
  record: Record<string, unknown>,
  ctx: NonNullable<Awaited<ReturnType<typeof reservationContext>>>,
  m: {
    kind: string;
    title: string;
    body: string;
    intro: string;
    cancelPrompt: string;
  },
) {
  const exp = pragueEpoch(
    record.date as string,
    ctx.block.starts_at as string,
  );
  // Fail closed: signing with an empty key would mint links anyone
  // could forge. A missing secret is a deployment bug — surface it
  // as a 500 in the function logs instead.
  const cancelSecret = Deno.env.get("CANCEL_TOKEN_SECRET");
  if (!cancelSecret) throw new Error("CANCEL_TOKEN_SECRET is not set");
  const token = await signCancelToken(
    record.id as string,
    exp,
    cancelSecret,
  );
  const cancelUrl =
    `${Deno.env.get("SUPABASE_URL")}/functions/v1/cancel?token=${token}`;
  await notifyRecipient(ctx.player, m.title, m.body, {
    data: {
      kind: m.kind,
      reservation_id: String(record.id),
      date: String(record.date),
      block_id: String(record.block_id),
      lane: String(record.lane),
      tenant_id: String(record.tenant_id),
    },
    html: `<p>${m.intro}</p>` +
      `<p><b>${escapeHtml(ctx.when)}</b></p>` +
      `<p>${m.cancelPrompt}</p>` +
      `<p><a href="${cancelUrl}">Zrušit rezervaci</a></p>` +
      `<p>Odkaz platí do začátku tréninku.</p>`,
  });
}

async function handle(payload: WebhookPayload) {
  if (payload.type === "CRON" && payload.table === "notification_jobs") {
    // The minutely pg_cron tick (0023): process everything that's due — the
    // calendar jobs, and then the reminders whose moment has come (0040),
    // the canteen duty's last (0050). Its record is null, so it must never
    // reach the row handlers below.
    await processJobs();
    await sendDueReminders();
    await sendDueDutyReminders();
    try {
      await processFederationJobs(supabase, siteFetcher());
    } catch (error) {
      console.error("federation jobs failed:", error);
    }
    return;
  }

  const record = payload.record ?? {};

  switch (payload.table) {
    case "tenants": {
      // A new kuželna waits for the superadmin's approval (0014). Existing
      // tenants only ever UPDATE (approval), which stays silent.
      if (payload.type !== "INSERT" || record.status !== "pending") return;
      const { data: superadmins } = await supabase.from("profiles")
        .select("id, email, fcm_token")
        .eq("superadmin", true);
      const name = escapeHtml(String(record.name ?? "?"));
      const founder = escapeHtml(String(record.founder_email ?? "?"));
      await Promise.all((superadmins ?? []).map((admin) =>
        notifyRecipient(
          admin as Recipient,
          "Nová kuželna čeká na schválení",
          `„${record.name}" (${record.founder_email ?? "?"}). ` +
            `Schval ji v aplikaci: Správa → Kuželny.`,
          {
            data: { kind: "pending_tenant" },
            html: `<p>Někdo založil novou kuželnu <b>${name}</b> ` +
              `(zakladatel: ${founder}).</p>` +
              `<p><a href="${appTenantsUrl}">Schval ji v aplikaci</a> ` +
              `(Správa kuželny → Kuželny).</p>`,
          },
        )
      ));
      return;
    }

    case "profiles": {
      if (payload.type !== "INSERT" || record.status !== "pending") return;
      // Tenant-scoped fan-out (0005): only the new player's own alley's
      // admins are notified; to_jsonb(new) carries tenant_id automatically.
      const { data: admins } = await supabase.from("profiles")
        .select("id, email, fcm_token")
        .eq("role", "admin")
        .eq("status", "approved")
        .eq("tenant_id", record.tenant_id);
      const name = escapeHtml(String(record.display_name ?? "?"));
      await Promise.all((admins ?? []).map((admin) =>
        notifyRecipient(
          admin as Recipient,
          "Nový hráč čeká na schválení",
          `${record.display_name} se zaregistroval(a). Schval ho v sekci Hráči.`,
          {
            // The alley rides along: an admin who is visiting another
            // kuželna is not sent to the wrong list.
            data: {
              kind: "pending_player",
              tenant_id: String(record.tenant_id ?? ""),
            },
            html: `<p><b>${name}</b> se zaregistroval(a) do Rezervátoru.</p>` +
              `<p><a href="${appPlayersUrl}">Schval ho v aplikaci</a> ` +
              `(Správa kuželny → Hráči).</p>`,
          },
        )
      ));
      return;
    }

    case "reservations": {
      if (payload.type === "INSERT") {
        // A booking made for the player by a group mate (0044) or by the
        // player on duty (0050) reads the same: who booked it, and when.
        if (record.created_via === "group" || record.created_via === "duty") {
          const [ctx, by] = await Promise.all([
            reservationContext(record),
            profileOf(record.created_by),
          ]);
          if (!ctx || !by) return;
          const m = groupBookedMessage(by.display_name, ctx.when);
          await notifyBookedFor(record, ctx, {
            kind: record.created_via === "duty" ? "duty_booking" : "group_booking",
            title: m.title,
            body: m.body,
            intro: `${escapeHtml(by.display_name)} ti zarezervoval(a) trénink:`,
            cancelPrompt: "Pokud termín nechceš, zruš ho jedním kliknutím:",
          });
          return;
        }
        if (record.created_via !== "kiosk") return;
        const ctx = await reservationContext(record);
        if (!ctx) return;
        await notifyBookedFor(record, ctx, {
          kind: "kiosk_booking",
          title: "Rezervace z kiosku 🎳",
          body: `${ctx.when}. Pokud jsi to nebyl ty, zruš ji v aplikaci.`,
          intro: "Na kiosku na kuzelně vznikla rezervace na tvé jméno:",
          cancelPrompt:
            "Pokud jsi to nebyl ty — nebo termín nechceš — zruš ji jedním kliknutím:",
        });
        return;
      }

      if (payload.type === "UPDATE") {
        const old = payload.old_record ?? {};
        const wasLive = old.cancelled_at == null;
        if (!wasLive) return;
        // The admin's per-change choice (0011): a silent move/cancel sets
        // notify_player=false on the same UPDATE.
        const wantsNotify = record.notify_player !== false;

        // Whoever cancelled it and however (0058): the watchers of its day.
        if (record.cancelled_at != null) await notifyFreedSpot(record);

        // ADMIN CANCEL of an upcoming reservation.
        if (record.cancelled_at != null) {
          if (record.cancelled_via === "group") {
            if ((record.date as string) < pragueToday()) return;
            const [ctx, by] = await Promise.all([
              reservationContext(record),
              profileOf(record.cancelled_by),
            ]);
            if (!ctx || !by) return;
            const m = groupCancelledMessage(by.display_name, ctx.when);
            await notifyRecipient(ctx.player, m.title, m.body, {
              data: { kind: "group_cancelled" },
            });
            return;
          }
          // The player on duty (0050) cancels like the admin: the same
          // notify choice and the same silence for past dates, but the
          // default reason names who it was, not the admin.
          const byDuty = record.cancelled_via === "duty";
          if (record.cancelled_via !== "admin" && !byDuty) return;
          if (!wantsNotify) return;
          // Retro no-show cancels (past dates) stay silent.
          if ((record.date as string) < pragueToday()) return;
          const [ctx, by] = await Promise.all([
            reservationContext(record),
            byDuty ? profileOf(record.cancelled_by) : null,
          ]);
          if (!ctx) return;
          const note = String(record.cancel_note ?? "").trim();
          let reason = note.length > 0 ? note : "zrušeno správcem";
          if (byDuty) {
            if (!by) return;
            reason = dutyCancelReason(note, by.display_name);
          }
          await notifyRecipient(
            ctx.player,
            "Trénink zrušen",
            `${ctx.when} — ${reason}.`,
            {
              data: { kind: byDuty ? "duty_cancelled" : "admin_cancelled" },
              html: `<p>Tvoje rezervace byla zrušena:</p>` +
                `<p><b>${escapeHtml(ctx.when)}</b></p>` +
                `<p>Důvod: ${escapeHtml(reason)}.</p>`,
            },
          );
          return;
        }

        // ADMIN MOVE of a live reservation (block/lane/date changed).
        const moved = old.block_id !== record.block_id ||
          old.lane !== record.lane ||
          old.date !== record.date;
        if (!moved || !wantsNotify) return;
        const [ctx, oldWhen] = await Promise.all([
          reservationContext(record),
          whenLabel(old),
        ]);
        if (!ctx) return;
        const custom = String(record.notify_message ?? "").trim();
        const standard = oldWhen == null
          ? `Nový termín: ${ctx.when}.`
          : `Z ${oldWhen} na ${ctx.when}.`;
        const body = custom.length > 0 ? `${custom} (${ctx.when})` : standard;
        await notifyRecipient(
          ctx.player,
          "Termín přesunut",
          body,
          {
            data: { kind: "reservation_moved" },
            html: `<p>Tvoje rezervace byla přesunuta:</p>` +
              (oldWhen == null
                ? ""
                : `<p>Původně: ${escapeHtml(oldWhen)}</p>`) +
              `<p>Nově: <b>${escapeHtml(ctx.when)}</b></p>` +
              (custom.length > 0 ? `<p>${escapeHtml(custom)}</p>` : ""),
          },
        );
        return;
      }
      return;
    }

    case "player_group_members": {
      // Invite → the invitee. Accept (invited → member) → everyone else in
      // the group. The founder's own INSERT (status member) says nothing.
      if (payload.type === "INSERT" && record.status === "invited") {
        const [invitee, inviter] = await Promise.all([
          profileOf(record.user_id),
          profileOf(record.invited_by),
        ]);
        if (!invitee || !inviter) return;
        const m = groupInviteMessage(inviter.display_name);
        await notifyRecipient(invitee, m.title, m.body, {
          data: { kind: "group_invite" },
        });
        return;
      }
      const old = payload.old_record ?? {};
      if (payload.type === "UPDATE" && old.status === "invited" &&
          record.status === "member") {
        const joiner = await profileOf(record.user_id);
        if (!joiner) return;
        const { data: others } = await supabase.from("player_group_members")
          .select("user_id").eq("group_id", record.group_id)
          .eq("status", "member").neq("user_id", record.user_id);
        const m = groupJoinedMessage(joiner.display_name);
        for (const row of (others ?? []) as { user_id: string }[]) {
          const recipient = await profileOf(row.user_id);
          if (recipient) {
            await notifyRecipient(recipient, m.title, m.body, {
              data: { kind: "group_joined" },
            });
          }
        }
      }
      return;
    }

    case "messages": {
      // A new notice or message (0051): message_send inserted its
      // recipients in the same transaction, and pg_net posts only after
      // the commit, so they are all there by now. A notice posted ahead of
      // time is sent without its ping; it goes out as a notice_visible job.
      if (payload.type !== "INSERT") return;
      const message = record as unknown as MessageRow;
      if (!message.notify) return;
      await deliverNewMessage(message);
      return;
    }

    case "message_recipients": {
      // A recipient's 👍/👎 or reply (0051) → the message's author. The
      // trigger fires only on an UPDATE OF reaction, reply; a clear (whole
      // or half) is filtered out by reactionChange.
      if (payload.type !== "UPDATE") return;
      const row = record as unknown as MessageRecipientRow;
      const old = (payload.old_record ?? {}) as Partial<MessageRecipientRow>;
      const changed = reactionChange(old, row);
      if (!changed) return;
      const { data: messageData, error: messageError } = await supabase.from("messages")
        .select(
          "id, tenant_id, kind, audience, author_id, author_role, on_date, block_id, title, body, notify",
        )
        .eq("id", row.message_id).maybeSingle();
      if (messageError) throw messageError;
      if (!messageData) return;
      // The author with their standing: deliverReaction tells them only
      // while they may still read the message (isMemberOf) — the service
      // role would otherwise reach an account set as the kiosk, back to
      // pending or moved to another alley.
      const [authorResult, reactor] = await Promise.all([
        messageData.author_id == null
          ? Promise.resolve({ data: null, error: null })
          : supabase.from("profiles")
            .select("id, email, fcm_token, display_name, status, role, tenant_id")
            .eq("id", messageData.author_id).maybeSingle(),
        profileOf(row.user_id),
      ]);
      if (authorResult.error) throw authorResult.error;
      const author = authorResult.data as (Recipient & Membership) | null;
      await deliverReaction(
        row,
        changed,
        { message: messageData as MessageRow, author, reactorName: reactor?.display_name ?? "?" },
        (r, title, body, opts) => notifyRecipient(r, title, body, opts),
      );
      return;
    }
  }
}

Deno.serve(async (request) => {
  // Fail closed: the function is deployed --no-verify-jwt, so a missing
  // WEBHOOK_SECRET must reject everything (loud 401) rather than open the
  // endpoint to forged payloads.
  const secret = Deno.env.get("WEBHOOK_SECRET");
  if (!secret || request.headers.get("x-webhook-secret") !== secret) {
    return new Response("unauthorized", { status: 401 });
  }
  try {
    const payload = await request.json() as WebhookPayload;
    await handle(payload);
    return new Response("ok");
  } catch (error) {
    console.error("notify failed:", error);
    return new Response(`error: ${error}`, { status: 500 });
  }
});
