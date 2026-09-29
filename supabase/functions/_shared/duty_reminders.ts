/// The canteen duty (0050) in notify: the reminder before a duty, and the
/// reason a training cancelled by the player on duty gives. Kept apart from
/// notify/index.ts so it can be tested.

import { pragueEpoch } from "./cancel_token.ts";
import type { Delivery } from "./delivery.ts";
import { dutyDayLabel, escapeHtml, leadLabel, pragueDateTime } from "./format.ts";

/// One row of due_duty_reminders(): a player to remind of a duty. The
/// dates are plain Prague dates (`YYYY-MM-DD`), both included; `days` is
/// the alley's lead; `co_assignees` are the others on the roster, in no
/// particular order.
export type DueDutyReminder = {
  user_id: string;
  email: string;
  fcm_token: string | null;
  period_id: string;
  starts_on: string;
  ends_on: string;
  days: number;
  co_assignees: string[];
};

/// What the player on duty may do, told once in the e-mail (the push is
/// too short for it). The same sentence as the footer of Klubovna → Služby.
const DUTY_RIGHTS =
  "Během služby můžeš rezervovat a rušit tréninky ostatním a upravovat " +
  "bloky v jednotlivých dnech.";

const czech = new Intl.Collator("cs");

/// Whole Prague calendar days from [now] until [startsOn]: 1 on the eve,
/// 0 once the duty's first day has begun.
function daysUntil(startsOn: string, now: Date): number {
  const today = pragueDateTime(now.toISOString()).date;
  return Math.round(
    (Date.parse(`${startsOn}T00:00:00Z`) - Date.parse(`${today}T00:00:00Z`)) /
      86400000,
  );
}

/// "Zítra sloužíš na kantýně", "Za 2 dny sloužíš na kantýně". Counts the
/// Prague calendar days actually left, so a late send (notify was down, the
/// player was assigned inside the lead) says the truth rather than the
/// alley's lead. Never „Dnes“: a duty that has started is never due, and
/// [deliverDueDutyReminders] drops one that started while the tick ran.
export function dutyReminderTitle(startsOn: string, now: Date): string {
  const lead = leadLabel(Math.max(daysUntil(startsOn, now), 1) * 1440);
  return `${lead[0].toUpperCase()}${lead.slice(1)} sloužíš na kantýně`;
}

/// "po 5. 10. – ne 11. 10., spolu s: Jana Nováková" — the period (a
/// one-day duty names its day once) and the others on it, sorted
/// Czech-alphabetically; nobody else, no „spolu s“.
export function dutyReminderBody(row: DueDutyReminder): string {
  const range = row.starts_on === row.ends_on
    ? dutyDayLabel(row.starts_on)
    : `${dutyDayLabel(row.starts_on)} – ${dutyDayLabel(row.ends_on)}`;
  if (row.co_assignees.length === 0) return range;
  const names = [...row.co_assignees].sort(czech.compare);
  return `${range}, spolu s: ${names.join(", ")}`;
}

/// The e-mail variant: the body, then what the duty may do.
export function dutyReminderHtml(row: DueDutyReminder): string {
  return `<p>${escapeHtml(dutyReminderBody(row))}</p><p>${DUTY_RIGHTS}</p>`;
}

/// The arguments of mark_reminder_sent for [row]: the ledger key
/// `d:<period id>`, the lead in minutes, and the start the reminder was
/// for — Prague midnight of the first day — so a period moved to other
/// dates rings again (0049).
export function dutyReminderReceipt(row: DueDutyReminder): {
  p_user: string;
  p_event_key: string;
  p_offset: number;
  p_starts_at: string;
} {
  return {
    p_user: row.user_id,
    p_event_key: `d:${row.period_id}`,
    p_offset: row.days * 1440,
    p_starts_at: new Date(pragueEpoch(row.starts_on, "00:00") * 1000)
      .toISOString(),
  };
}

/// Sends what [rows] (due_duty_reminders) make due and marks each one when
/// it was delivered, or could not be (no address, refused for good): trying
/// again would not help. A retry (FCM or Resend busy or down, a dead push
/// token) or a send that throws leaves it unmarked, so it is due again on
/// the next tick — the contract of deliverDueReminders. A duty whose first
/// day began between the query and the send (midnight) is skipped: it is
/// under way, and due_duty_reminders will not offer it again.
export async function deliverDueDutyReminders(
  rows: DueDutyReminder[],
  now: Date,
  send: (row: DueDutyReminder, title: string, body: string) => Promise<Delivery>,
  mark: (row: DueDutyReminder) => Promise<void>,
): Promise<void> {
  for (const row of rows) {
    const key = `d:${row.period_id} for ${row.user_id}`;
    if (daysUntil(row.starts_on, now) < 1) continue;
    let delivery: Delivery;
    try {
      delivery = await send(
        row,
        dutyReminderTitle(row.starts_on, now),
        dutyReminderBody(row),
      );
    } catch (error) {
      console.error(`duty reminder ${key} failed:`, error);
      continue;
    }
    if (delivery === "retry") {
      console.error(`duty reminder ${key} not delivered, due again next tick`);
      continue;
    }
    try {
      await mark(row);
    } catch (error) {
      console.error(`duty reminder ${key} not marked:`, error);
    }
  }
}

/// Why a training the player on duty cancelled is gone: their note when
/// they wrote one, otherwise who did it — never „zrušeno správcem“, which
/// would blame the admin.
export function dutyCancelReason(note: string, by: string): string {
  const trimmed = note.trim();
  return trimmed.length > 0 ? trimmed : `zrušil(a) ${by} (služba na kantýně)`;
}
