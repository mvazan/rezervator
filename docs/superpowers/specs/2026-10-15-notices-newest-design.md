# Nástěnka: nejnovější nahoře, čerstvé oznamy na kiosku, nové v appce

Requested by the user on 2026-10-15. The app speaks Czech; the user writes Slovak. Branch `notices-newest` from `main` (f103e28, migrations up to 0078). Migration `0080_kiosk_notices_fresh.sql` — `0079` is taken by another branch (`0079_kiosk_zapis_nav.sql`); whichever merges second renumbers, never `db push --include-all`.

## Decided with the user

- **Newest first** on the Nástěnka, in the app and on the kiosk — an explicit exception to the rule that lists go alphabetically or chronologically (recorded in memory). Active notices and the collapsed „Starší“ go newest first; the admin's „Naplánované“ stays chronological by when each will show (upcoming first).
- **Kiosk — fresh notices**: a notice is *fresh* while it has been up for less than N days (the admin sets N, 1–14, default 3). What a fresh notice gets is the admin's choice: nothing, a highlight, a longer turn, or both (default: the highlight).
- **App — new notices**: the notices that were unread when the board opened are highlighted for that visit only; the next visit they are read and plain, like the badge.

## Order (`lib/domain/messages.dart`)

`splitNotices(notices, now)`: `active` and `expired` sorted by the posting time **descending** (`createdAt`, ties by `id` descending, so the order stays total); `scheduled` stays by `visibleFrom` ascending. `kioskNotices` (`lib/domain/kiosk_panel.dart`) uses `splitNotices(...).active`, so the kiosk follows. The posting time shown and compared is the one the notice became visible at: `visibleFrom ?? createdAt` (a scheduled notice that has gone up counts from when it went up) — `noticePostedAt(Message m)`, used for the order and for freshness. Tests that pin the old order are updated (`test/domain/messages_test.dart` `splitNotices` group, `test/domain/kiosk_panel_test.dart` kioskNotices, the kiosk notice tests in `test/features/kiosk_test.dart` and `test/features/kiosk_headline_test.dart`), and `docs/superpowers/specs/2026-09-28-messages-design.md`'s „oldest first“ sentence gets a note that it is newest first since 2026-10-15.

## Kiosk

### Data (0080)

`schedule_settings`:

- `kiosk_notices_fresh_mode text not null default 'highlight'`, named check `schedule_settings_kiosk_notices_fresh_mode_check` in (`off`, `highlight`, `longer`, `both`).
- `kiosk_notices_fresh_days smallint not null default 3`, named check `schedule_settings_kiosk_notices_fresh_days_check` 1–14.

Re-runnable (`add column if not exists`, checks guarded). `public_week` is an allow-list — nothing to do. Tenancy suite: new-alley defaults, an unknown mode and 0/15 days refused, the columns off the public overview. `supabase/schema.sql` from a fresh throwaway stack, `docs/SCHEMA.md`.

### Model

`lib/domain/models.dart`: `enum KioskNoticesFresh { off, highlight, longer, both }` (`parse` — unknown or missing → `highlight`; getters `highlights`, `lingers`), `ScheduleSettings.kioskNoticesFresh` (default `highlight`) and `kioskNoticesFreshDays` (default 3).

`lib/domain/kiosk_panel.dart` (pure, unit-tested):

- `bool isFreshNotice(Message m, DateTime now, int days)` — `now.difference(noticePostedAt(m)) < Duration(days: days)`, never for a notice scheduled for later (`visibleFrom` ahead of `now`). A posting time after `now` otherwise counts as just posted (a negative difference is fresh): the kiosk's minute clock runs up to ~75 s behind, so a notice that has just gone up is usually ahead of it.
- `Duration kioskNoticeTurn(Message m, {required DateTime now, required Duration turn, required KioskNoticesFresh fresh, required int days})` — `turn × 2` when `fresh.lingers` and the notice is fresh, else `turn`.

### Card and status bar

- **`_NoticesCard`** (`lib/features/kiosk/kiosk_info_panel.dart`): the rotation becomes a one-shot `Timer(kioskNoticeTurn(current, …))` re-armed after every step (timer or swipe), so each notice gets its own turn. When the list's first notice changes (a new one posted, or the order changed), the card goes back to the first (newest) and restarts its turn; a shrunk list clamps the index so a dot is always lit. A fresh notice with `fresh.highlights` shows a „NOVÉ“ chip (11 px w800, `primary` fill, `onPrimary` text, radius 6) before its title and a 4 px `primary` stripe along the card's left edge; its dot is `primary` too (filled while it is shown, a `primary` ring while it waits for its turn).
- **`KioskHeadline`** (`lib/features/kiosk/kiosk_headline.dart`): the same one-shot per-notice turn and the same jump to the newest on a new first notice; a fresh highlighted notice gets the same „NOVÉ“ chip between the icon and the title.
- Both read `kioskNoticesFresh` and `kioskNoticesFreshDays` from the settings and `now` from `nowProvider` (a notice stops being fresh as the minutes go by, without a reload).

### Admin (Správa → Kiosk → Nástěnka)

Under „Střídání oznamů“ (shown when the notices are in the header or a panel):

- Dropdown **„Čerstvé oznamy“**: „Nezvýrazňovat“ (off), „Zvýraznit“ (highlight), „Zobrazit déle“ (longer), „Zvýraznit i zobrazit déle“ (both); helper „Oznam vyvěšený před méně než N dny dostane štítek NOVÉ, nebo zůstane na obrazovce dvakrát déle.“ (N = the current days).
- **„Čerstvý je do“** — `_number`, unit „dní“, 1–14 (shown unless the mode is off).

## App (Klubovna → Nástěnka)

- `lib/features/clubhouse/notice_board_screen.dart`: the set the board already keeps of the notices it found unread and marked read on this visit (`_requested`) is handed (an unmodifiable copy) to the list and each card as `isNew`. A new card: a „Nové“ chip before the title (`primaryContainer` fill, `onPrimaryContainer` text) and a 4 px `primary` stripe along its left edge. The highlight lasts the visit (the optimistic `read_at` write does not clear it) and is gone the next time (the notice is read). Author's own notices, notices without a recipient row and expired ones are never new — the same rule as the badge (`unreadCounts`).
- Order newest first (above).

## Testing

- **Unit:** `splitNotices` newest first (ties, expired newest first, scheduled ascending); `noticePostedAt`; `isFreshNotice` (edges: exactly N days, scheduled for later, posted just after the kiosk's clock); `kioskNoticeTurn`; `KioskNoticesFresh.parse` and `ScheduleSettings` parsing/defaults.
- **Widget (kiosk):** the card and the status bar start on the newest; a fresh notice with highlight shows „NOVÉ“ (and the stripe), an old one does not; with `longer` the fresh notice stays twice the turn, an old one the turn; a newly posted notice is shown at once; the existing rotation tests updated to the new order.
- **Widget (admin):** the two controls PATCH `kiosk_notices_fresh_mode` / `kiosk_notices_fresh_days`, the days field hidden when off.
- **Widget (app):** the board lists newest first; the notices unread on opening show „Nové“ for the visit (also after the optimistic read), not the read ones, not the author's own; a notice that arrives while the board is open and is marked read on this visit is new too; reopening shows none.
- **SQL:** 0080 as above.
- **Browser** on the local stack: the kiosk card and status bar (new notice posted → shown first with NOVÉ; longer turn), the admin controls, the app board with a fresh unread notice.
