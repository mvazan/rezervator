# Rezervátor — cleanup 4: dátová vrstva (plan)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** One clock, one place that assembles a week, no manual cache-busting, and no storage detail (`PostgrestException`) in a widget. The screens shrink to rendering + gestures; the data layer owns time, composition and refresh.

**Architecture:** Two new providers in `lib/data/` — `nowProvider` (minute-granular wall clock every time-dependent widget watches) and `weekScheduleProvider(monday)` (an `AsyncValue<WeekView>` composing settings, blocks, overrides, priority slots, rentals, the week's reservations and the roster into the `WeekSchedule` plus the name/colour maps every board needs). `playersProvider` refreshes itself (club stream + a 5-minute tick) so screens stop invalidating it. `Api` gains `deleteTimeBlock → bool` (FK-restrict handled inside) and `restoreDayToTemplate` (the two-call sequence three widgets repeated).

**Tech Stack:** Flutter 3.38 / Dart 3.10, flutter_riverpod 3; no backend change.

**Branch:** `cleanup-4-data` from `main` (after PR #53).

## Global Constraints

- No schema/RPC/edge-function changes. No new dependencies.
- `flutter analyze` clean, `flutter test` green (266 on main) after every task; existing widget tests keep passing unchanged unless a task names them.
- Providers stay cancel-safe in widget tests: periodic work uses `Stream.periodic` inside `async*` (the timer dies with the provider), never `Future.delayed` loops (see `cache.dart` / `offlineProvider`).
- Commit per task, `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>`; the controller opens the PR.

---

### Task 1: `nowProvider` + kiosk clock as a leaf

**Files:** Create `lib/data/clock.dart`, `test/data/clock_test.dart`; Modify `lib/features/kiosk/kiosk_shell.dart` (drop `_clockTimer`/`_now`; `_StatusBar` watches the clock), `lib/features/schedule/week_screen.dart` (`DateTime.now()` in build → `nowProvider`), `lib/features/kiosk/kiosk_board_view.dart` (same).

**Interface:**
```dart
/// Wall clock, minute granularity: emits immediately, then whenever the
/// minute changes (polled every 15 s — the timer dies with the provider).
final nowProvider = StreamProvider<DateTime>(...);
/// Pure, testable core of nowProvider.
Stream<DateTime> minuteClock({required DateTime Function() clock, Duration poll = const Duration(seconds: 15)});
/// Convenience: the current [Day] / [HourMinute] from nowProvider (falls
/// back to DateTime.now() before the first emission).
Day todayOf(WidgetRef ref); HourMinute nowOf(WidgetRef ref);
```
Test (`fakeAsync`): first value immediately; no second value while the minute is unchanged; a value once the clock crosses a minute boundary.

- [x] Write `clock_test.dart` (red) → `clock.dart` (green).
- [x] `_StatusBar` gets `now` from `ref.watch(nowProvider)`; the shell keeps only the idle timer. Board + week screen read `nowProvider`. Tests green. Commit `refactor(data): one wall clock — nowProvider; kiosk clock no longer rebuilds the shell`.

### Task 2: `weekScheduleProvider(monday)`

**Files:** Create `lib/data/week_schedule.dart`, `test/data/week_schedule_test.dart`; Modify `week_screen.dart`, `kiosk_board_view.dart`.

**Interface:**
```dart
class WeekView {
  final WeekSchedule week;
  final List<TimeBlock> blocks;      // DB blocks, or the placeholder grid
  final bool blocksFromDb;           // false = placeholder → never interactive
  final bool reservationsLoaded;     // this week's stream has a value
  final List<Reservation> reservations;
  final Map<String, String> nameById;   // nick when set, else display name
  final Map<String, int> clubColorById;
  final Day today; final HourMinute now;
  bool get interactive => blocksFromDb && reservationsLoaded;
}
/// Loading/error follow timeBlocksProvider (the one stream the grid cannot
/// render without); every other input falls back to empty/defaults.
final weekScheduleProvider = Provider.autoDispose.family<AsyncValue<WeekView>, Day>(...);
```
Tests with a `ProviderContainer` and the same overrides the widget tests use: loading while blocks load; error propagates; composed week uses the nick; placeholder grid → `interactive == false`; the same Monday returns one instance while nothing changed.

- [x] Red → green → wire `week_screen.dart` (keeps watching blocks/overrides/priority for the admin edit closures; takes `week`, maps and `interactive` from the provider) and `kiosk_board_view.dart` (one `weekScheduleProvider(monday)` per visible Monday; `selectedCount` from the views' `reservations`). Commit `refactor(data): weekScheduleProvider composes the week once for every board`.

### Task 3: `playersProvider` refreshes itself

**Files:** Modify `lib/data/providers.dart` (watch `clubsProvider` + a 5-minute `Stream.periodic` tick), `week_screen.dart` (drop the two `ref.invalidate(playersProvider)`), `kiosk_shell.dart` (drop the idle one). `name_picker.dart` keeps its open/retry refresh (user-triggered).

- [x] Commit `refactor(data): playersProvider re-reads on club changes and every 5 min`.

### Task 4: `Api.deleteTimeBlock` reports "in use" instead of leaking PostgrestException

**Files:** Modify `lib/data/providers.dart` (`Future<bool> deleteTimeBlock` — false on FK restrict `23503`), `lib/features/admin/schedule_screen.dart` (no `supabase_flutter` import).

- [x] Commit `refactor(data): deleteTimeBlock returns false when the block is in use`.

### Task 5: `Api.restoreDayToTemplate`

**Files:** Modify `lib/data/providers.dart`, `lib/features/admin/overrides_screen.dart` (`_restore`), `lib/features/admin/widgets/block_dialog.dart` (`_restoreTemplate`, dissolve unwind).

**Interface:**
```dart
/// Returns [date] to the weekly rules: a training day gets the template
/// block ids written first (cancelling anything off-template), a
/// non-training day is closed first; then the override row is deleted.
/// The closed/template write lands BEFORE the delete so a failure between
/// the two can't leave the day wide open.
static Future<void> restoreDayToTemplate(Day date, {required bool isTraining, required List<String> templateIds});
```
Widget tests (`overrides_screen_test`, `block_dialog_day_test`) pin the HTTP sequence and stay unchanged.

- [x] Commit `refactor(data): Api.restoreDayToTemplate replaces three inline call pairs`.

### Task 6: docs + PR

- [x] Audit spec status line, plan outcome, `flutter analyze && flutter test`, push, PR.

---

## Outcome (2026-09-02)

Landed on `cleanup-4-data` in three commits; `flutter analyze` clean, 272
tests (266 → 272: clock + weekScheduleProvider unit tests).

- `lib/data/clock.dart` — `nowProvider` / `minuteClock`; the kiosk shell has
  no clock timer, the status bar repaints alone on a minute tick; the week
  screen and the kiosk board read the same clock.
- `lib/data/week_schedule.dart` — `weekScheduleProvider(monday)` → `WeekView`;
  `buildWeekSchedule` is called from exactly one place in the app (plus the
  day pager's sentinel preview, which keeps its plain-input contract).
- `playersProvider` re-reads on club changes and every 5 minutes; the two
  navigation-time and the idle-reset invalidations are gone (the name
  picker keeps its on-open refresh).
- `Api.deleteTimeBlock → bool` (no `PostgrestException` in a widget),
  `Api.restoreDayToTemplate` (three inline call pairs).
- Test gotchas recorded: a `Stream.periodic`-based provider must not be
  awaited to cancel inside `testWidgets` (FakeAsync never flushes the
  cancel future) — test it with a plain `test()` and a short real poll;
  family overrides must create a fresh stream per call.
- Left for later: `week_calendar_view` still schedules its anchor `jumpTo`
  from build and the kiosk board mutates `_window`/`_pxPerMinute` in
  `LayoutBuilder` (audit B); `move_reservations_dialog` reads a provider
  inside a build-time helper.

