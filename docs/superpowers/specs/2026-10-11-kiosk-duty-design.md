# Služby v kantýně na kiosku

Requested by the user on 2026-10-10/11. The app speaks Czech; the user writes Slovak. Branch `kiosk-duty` from `main` (3bd1d13, migrations up to 0065 there); migration `0073_kiosk_duty.sql` (0066–0072 are taken by the parallel kiosk branches — the second branch to merge renumbers, never `db push --include-all`).

## Why

The app shows the canteen duty (0050, `duty_periods` + `duty_assignments`) as a line under the week range: „Služba: Jan Novák a Petr Svoboda“, or per part of the week „Služba: po–st Jan Novák · čt–ne Petr Svoboda“. The kiosk has no week: its board starts today (minus the admin's past days) and runs on, and duty periods have arbitrary bounds. A visitor at the kiosk wants two answers: **who serves now** (whom to ask in the canteen — the booking note even sends people there) and **when do I serve** (the plan on the wall).

## Decided with the user

Three places, each switched on separately by the admin (Správa → Kiosk → new section „Služby v kantýně“), all off by default:

1. **V záhlaví (header)** — under the clock and the date in the status bar: a compact tinted line „☕ Služba: Jan Novák a Petr Svoboda“ (today's duty). A tap opens the dialog „Služby v kantýně“: the current duty highlighted, then the next ones in date order.
2. **V kalendáři (board)** — a band across the day columns' headers on the kiosk board, like an all-day event: one tinted segment per day of a period, rounded only where the period starts/ends, the names on the period's first day and on the first visible column (a period that began before the board's first visible day still says who). A tap on the band opens the same dialog.
3. **V panelu (drawer)** — a card „SLUŽBA V KANTÝNĚ“ in the side drawer with the current duty large and the next ones listed, taking the admin's share of the drawer's height (a % like the notices' share).

The modes combine freely (independent switches — the admin may pick exactly one or several).

## Data (0073)

`schedule_settings`:

- `kiosk_duty_header boolean not null default false`
- `kiosk_duty_board boolean not null default false`
- `kiosk_duty_drawer boolean not null default false`
- `kiosk_duty_share smallint not null default 30`, named check `schedule_settings_kiosk_duty_share_check` 10–90

Re-runnable (`add column if not exists`, constraint guarded like 0065's). `public_week` on main still masks `schedule_settings`; the migration replaces it with the **allow-list** of the six public settings — the function body copied verbatim from `git show kiosk-warning:supabase/migrations/0068_kiosk_warning.sql` (comment adjusted to „0066–0073“), so all kiosk branches define it identically. The tenancy suite: defaults for a new alley, the share's bounds, `public_week` settings exactly the six keys. `supabase/schema.sql` from a fresh throwaway stack (`snap_repo.sh`), `docs/SCHEMA.md` updated. The kiosk already reads the roster (0050's RLS: approved players and the kiosk).

`ScheduleSettings`: `kioskDutyHeader`, `kioskDutyBoard`, `kioskDutyDrawer` (false when absent), `kioskDutyShare` (30 when absent).

## Domain (pure, unit-tested — `lib/domain/duties.dart`)

- `KioskDutyEntry` — a period and its assignees' display names, Czech-sorted (`compareCzech`). A period with no known assignee is not an entry (the app's header skips unassigned periods too).
- `kioskDutyPlan(periods, assignments, names, today, {ahead = 5})` → `({KioskDutyEntry? now, List<KioskDutyEntry> next})`: `now` = the period covering today (a period ending today still runs — `splitDuties`' rule), `next` = the ones starting after today, date order, at most `ahead`.
- `kioskDutyOn(periods, assignments, names, day)` → `({KioskDutyEntry entry, bool starts, bool ends})?` for the board's band: the period covering `day`, whether `day` is its first/last day.

Labels reuse `dutyRangeLabel`, `dutyDayLabel`, `joinNames`.

## The kiosk

- **Provider:** `kioskDutyPlanProvider` (kiosk feature) from `dutyPeriodsProvider`, `dutyAssignmentsProvider`, `playersProvider` (id → display name) and `nowProvider`.
- **Header (mode 1):** in `KioskShell`'s `_StatusBar`, under the clock column's date: a line on `secondaryContainer` (`onSecondaryContainer` text), `Icons.local_cafe_outlined`, „Služba: <names>“, one line, ellipsis, at most ~420 px wide. Only when mode 1 is on and someone serves today; otherwise nothing. A tap → `showKioskDutyDialog` (through the shell, the touch counts for the idle timer like the notice dialog; the idle reset's `popUntil` closes it).
- **Dialog:** title „Služby v kantýně“; the current duty as a tinted block „Teď slouží: <names>“ + its range; „Další“ and up to 5 rows „<range> — <names>“ (range left, names right, wrapping); none ahead → „Další služby zatím nejsou naplánované.“; „Zavřít“. No current duty → the block is left out.
- **Board (mode 2):** `BoardColumnHeader` (shared with the app's week board — the app passes nothing and stays unchanged) gains an optional band segment drawn as a strip at the top of the header, below the day label; `KioskBoardView` passes each day's `kioskDutyOn(...)` when mode 2 is on, plus whether the day is the first visible column (it already tracks the visible days for `onVisibleDays`). The header grows by the strip's height while mode 2 is on. Segment: `secondaryContainer`, radius only on the start/end sides, names (`labelSmall`, w600, ellipsis) on the period's first day and the first visible column. Hidden in the collapsed header. A tap on the strip opens the dialog (its own gesture — the rest of the header keeps opening the day's matches).
- **Drawer (mode 3):** a card like `_NoticesCard`/`_MatchesCard` (`_Card`, `Icons.local_cafe_outlined`, title „SLUŽBA V KANTÝNĚ“): the current duty („Teď slouží“, names large, range) or „Dnes nikdo neslouží.“, then „Další“ rows; scrolls if it overflows. It stands at the top of the drawer with `flex: kioskDutyShare`, the existing notices/matches column below with `flex: 100 − share` (their own split unchanged); alone it fills the drawer. `KioskPanelContent` gains the duty so a drawer with only the duty card exists. While a match is being played the live view takes the whole drawer, as today.
- **Admin:** section „Služby v kantýně“ after „Nástěnka“, about „Kdo právě slouží v kantýně a kdo přijde na řadu — podle plánu ve Správě → Služby. Každé místo se zapíná zvlášť.“; switches „V záhlaví“ („Pod hodinami „Služba: …“ s dnešní službou; ťuk ukáže plán.“), „V kalendáři“ („Pás se jmény přes dny služby v hlavičkách dnů tabule.“), „V panelu“ („Karta se službou a plánem v postranním panelu.“) and, with the drawer on, the number „Podíl karty v panelu“ (%, 10–90; helper „Kolik výšky panelu karta zabere; zbytek si dělí nástěnka a zápasy.“). Through `_switch` / `_number` / `_panel`.

## Changelog

One line in the unreleased entry: „Kiosk: kdo slouží v kantýně — v záhlaví (ťuk ukáže plán), jako pás v kalendáři nebo karta v panelu; zapíná správce ve Správě → Kiosk → Služby v kantýně.“ The `store:` summary stays ≤ 500 characters (add a short line only if it fits).

## Tests

Domain unit tests (now/next, ending today, unassigned skipped, unknown ids, Czech order, `ahead`, band starts/ends); model parsing; tenancy; admin PATCHes per switch and the share (shown only with the drawer on); kiosk widget tests per mode: header line present/absent, tap → dialog contents (current + next, empty text), band segments per day with names on the start day and the first visible column only, tap → dialog, collapsed header hides it, drawer card with share split and alone, live view hides it, idle reset closes the dialog.

## Out of scope

Editing duties on the kiosk, a „which one is me“ highlight (the kiosk has no user), reminders, the public overview.
