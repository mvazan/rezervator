/// Reminders before a training or a match (0040): the text notify sends.
/// Kept apart from notify/index.ts so it can be tested.

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
  const start = new Date(row.starts_at);
  const left = Math.ceil((start.getTime() - now.getTime()) / 60000);
  if (left >= row.offset_minutes - ON_TIME_SLACK_MINUTES) {
    return leadLabel(row.offset_minutes);
  }
  if (left < 120) return leadLabel(Math.max(left, 0));
  if (left < 1440) return leadLabel(Math.min(Math.round(left / 60), 23) * 60);
  const days = (Date.parse(`${pragueDateTime(row.starts_at).date}T00:00:00Z`) -
    Date.parse(`${pragueDateTime(now.toISOString()).date}T00:00:00Z`)) / 86400000;
  return leadLabel(Math.max(days, 1) * 1440);
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
