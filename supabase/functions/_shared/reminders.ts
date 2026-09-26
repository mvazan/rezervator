/// Reminders before a training or a match (0040): the text notify sends.
/// Kept apart from notify/index.ts so it can be tested.

import type { Delivery } from "./delivery.ts";
import { dayLabel, leadLabel, pragueDateTime, timeLabel } from "./format.ts";

/// One row of due_reminders(). `starts_at` is an instant (timestamptz,
/// arriving in UTC); `ends_at` is a Prague wall-clock time.
export type DueReminder = {
  user_id: string;
  email: string;
  fcm_token: string | null;
  event_key: string;
  offset_minutes: number;
  kind: "training" | "match";
  starts_at: string;
  ends_at: string;
  lane: number | null;
  alley_name: string | null;
  home_team: string | null;
  away_team: string | null;
  is_away: boolean | null;
};

/// "st 17.9. 18:30–19:30, dráha 2" / "SKK Veverky A – KK Blansko, 18:00,
/// doma" — what the reminder is about, under a title that says when.
export function reminderBody(row: DueReminder): string {
  const start = pragueDateTime(row.starts_at);
  const from = timeLabel(start.time);
  const to = timeLabel(row.ends_at);
  if (row.kind === "training") {
    const where = row.lane === null ? "" : `, dráha ${row.lane}`;
    return `${dayLabel(start.date)} ${from}–${to}${where}`;
  }
  return `${row.home_team} – ${row.away_team}, ${dayLabel(start.date)} ${from}, ` +
    `${row.is_away ? "venku" : "doma"}`;
}

/// How far behind its moment a reminder may go out and still read as sent
/// on time: the job tick is a minute, a slow run a few more.
const ON_TIME_SLACK_MINUTES = 5;

/// "Trénink za 2 hodiny" — the lead time the player chose, when the
/// reminder goes out on its minute. A late one (the event was booked, moved
/// or followed inside that lead time, or notify was down) says the time
/// actually left instead (0040: „za 20 minut“): minutes under two hours,
/// whole hours under a day (at most 23), Prague calendar days beyond.
export function reminderTitle(row: DueReminder, now: Date): string {
  const what = row.kind === "training" ? "Trénink" : "Zápas";
  return `${what} ${reminderLead(row, now)}`;
}

function reminderLead(row: DueReminder, now: Date): string {
  const left = Math.ceil((Date.parse(row.starts_at) - now.getTime()) / 60000);
  const onTime = left >= row.offset_minutes - ON_TIME_SLACK_MINUTES;
  if (!onTime && left < 120) return leadLabel(Math.max(left, 0));
  // Whole days read as Prague calendar days ("zítra" = the next date), so
  // a clock change cannot make 24 hours read as the wrong day.
  if (onTime ? row.offset_minutes % 1440 === 0 : left >= 1440) {
    const days = (Date.parse(`${pragueDateTime(row.starts_at).date}T00:00:00Z`) -
      Date.parse(`${pragueDateTime(now.toISOString()).date}T00:00:00Z`)) /
      86400000;
    // The 25-hour day when the clocks go back: 24 hours on is still today.
    if (days < 1) return `za ${Math.round(left / 60)} hodin`;
    return leadLabel(days * 1440);
  }
  if (onTime) return leadLabel(row.offset_minutes);
  return leadLabel(Math.min(Math.round(left / 60), 23) * 60);
}

/// One push per player and event. Several of their lead times fall due at
/// once when the event appears inside them (booked, moved, a team
/// followed, reminders switched on) or after an outage: only the one
/// closest to the start is sent, the others are past and only marked sent
/// ([alsoDue]). Order follows [rows] (due_reminders sorts by start).
export function oneReminderPerEvent(
  rows: DueReminder[],
): { send: DueReminder; alsoDue: DueReminder[] }[] {
  const groups = new Map<string, DueReminder[]>();
  for (const row of rows) {
    const key = `${row.user_id} ${row.event_key}`;
    const group = groups.get(key);
    if (group) group.push(row);
    else groups.set(key, [row]);
  }
  return [...groups.values()].map((group) => {
    const [send, ...alsoDue] = [...group]
      .sort((a, b) => a.offset_minutes - b.offset_minutes);
    return { send, alsoDue };
  });
}

/// Sends what [rows] (due_reminders) make due, one push per event
/// ([oneReminderPerEvent]), and marks it with the lead times it stood in
/// for — when it was delivered, or could not be (no address, refused for
/// good): trying again would not help. A retry (FCM or Resend busy or down,
/// a dead push token) or a send that throws leaves it unmarked, so it is
/// due again on the next tick: late beats never. [mark] records the start
/// each reminder was for (0049).
export async function deliverDueReminders(
  rows: DueReminder[],
  now: Date,
  send: (row: DueReminder, title: string, body: string) => Promise<Delivery>,
  mark: (row: DueReminder) => Promise<void>,
): Promise<void> {
  for (const { send: row, alsoDue } of oneReminderPerEvent(rows)) {
    let delivery: Delivery;
    try {
      delivery = await send(row, reminderTitle(row, now), reminderBody(row));
    } catch (error) {
      console.error(`reminder ${row.event_key} failed:`, error);
      continue;
    }
    if (delivery === "retry") {
      console.error(`reminder ${row.event_key} not delivered, due again next tick`);
      continue;
    }
    for (const done of [row, ...alsoDue]) {
      try {
        await mark(done);
      } catch (error) {
        console.error(`reminder ${done.event_key} not marked:`, error);
      }
    }
  }
}
