/// Reminders before a training or a match (0040): the text notify sends.
/// Kept apart from notify/index.ts so it can be tested.

import { dayLabel, pragueDateTime, timeLabel } from "./format.ts";

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
