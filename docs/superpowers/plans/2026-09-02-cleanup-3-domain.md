# Rezervátor — cleanup 3: doména nasáva pravidlá z widgetov (plan)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Every booking/cancel/schedule rule and every "what does this event look like" decision has exactly one, unit-tested home in `lib/domain`; widgets only render and sequence dialogs. Behaviour is unchanged except one real fix: the kiosk stops offering "＋" to a player already at the reservation limit.

**Architecture:** Pure-Dart additions to `lib/domain` (no Flutter imports except `palette.dart`, which already imports material for `Color`), each with tests in `test/domain`, then the widgets call them. Three streams run in parallel on separate branches from `main` and merge into `cleanup-3-domain`:
- **Stream B** (subagent): tints, event labels, limits, grouping + the admin screens that use them.
- **Stream C** (subagent): `canCancel(isAdmin:)`, `bookableSlotCount`, `isDayOpen`/`nextTrainingDay` move, `dropFits`, kiosk `canBook` — and the schedule/kiosk widgets.
- **Stream D** (controller): `domain/day_edit.dart` — the day-scoped block edit planner extracted from `block_dialog.dart` `_save`/`_removeForDay`/`_restoreTemplate`, plus the stranded-reservation helpers.
- **Task E** (controller, after merges): wire the Stream B labels/tints into the schedule/kiosk widgets, docs, final gate.

**Tech Stack:** Flutter 3.38 / Dart 3.10 (`flutter analyze`, `flutter test`), no backend changes.

**Branch:** `cleanup-3-domain` from `main` (after PR #52).

## Global Constraints

- No schema/RPC/edge-function changes. No new dependencies.
- Czech copy unchanged unless a task says so. `flutter analyze` clean, `flutter test` green (219 on main) after every task.
- Domain files stay pure Dart (`palette.dart` may import `package:flutter/material.dart` for `Color`/`ColorScheme`/`Brightness` only).
- Commit per task (`type(scope): summary` + `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>`), never push from a stream; the controller opens the PR.
- Interfaces below are the contract between streams — implement them with exactly these names and signatures.

---

## Stream B — domain helpers + admin screens (subagent)

### Task B1: `clubTint` — one tint resolver

**Files:** Modify `lib/domain/palette.dart`; Test `test/domain/palette_test.dart`.

**Interface (produces):**
```dart
/// Background + foreground for a palette index, or the caller's neutral
/// fallback when the index is out of 0–11 (−1 "no club", −2 rental default…).
(Color bg, Color fg) clubTint(
  int index,
  Brightness brightness, {
  required Color fallbackBg,
  required Color fallbackFg,
});
```
Tests: index 0 dark → `ClubColors.of(0, dark)`; index −1 → the fallbacks; index 12 → fallbacks.

### Task B2: event labels

**Files:** Create `lib/domain/labels.dart` (imports `models.dart` + `schedule.dart` for `OffBlockEvent`; kept out of `schedule.dart` so Stream C's additions there never conflict); Test `test/domain/labels_test.dart`.

**Interface (produces):**
```dart
/// '🏆 {title}' for matches, '⛔ {title}' for other blockages — the in-grid
/// and band wording (headers keep headerEventLabel's 🏠/none/⛔).
String slotEventLabel(PrioritySlot m);
/// '🔒 {renterName}'.
String rentalLabel(Rental r);
/// Band text: the label above + ' · od–do' (HourMinute.display()).
String eventBandLabel(OffBlockEvent e);
```
Tests: a match, a blockage, a rental; `eventBandLabel` appends `' · 17:00–18:30'`.

### Task B3: limits + validators

**Files:** Create `lib/domain/limits.dart`; Test `test/domain/limits_test.dart`; Modify `lib/features/admin/schedule_screen.dart` (`_validate` → `validateScheduleSettings`), `lib/features/admin/matches_screen.dart` (prep minutes 0–240 → `validatePrepMinutes`, hint text from `Limits`), `lib/features/admin/overrides_screen.dart` (`span > 92` → `Limits.closureSpanDays`), `lib/features/auth/register_screen.dart` + `lib/features/profile/profile_screen.dart` (nick `maxLength: 14` → `Limits.nickLength`, only where a literal 14 exists).

**Interface (produces):**
```dart
abstract final class Limits {
  static const laneCount = (min: 1, max: 12);
  static const horizonDays = (min: 1, max: 90);
  static const maxActiveReservations = (min: 1, max: 50);
  static const prepMinutes = (min: 0, max: 240);
  static const closureSpanDays = 92;
  static const nickLength = 14;
}
/// Czech error copy (moved verbatim from schedule_screen._validate) or null.
String? validateScheduleSettings({
  required int laneCount,
  required int horizonDays,
  required int maxReservations,
});
/// 'Zadej 0–240 minut.' or null.
String? validatePrepMinutes(int minutes);
```
Tests: each bound in and out of range; messages byte-identical to the current widget copy.

### Task B4: grouping helpers

**Files:** Create `lib/domain/grouping.dart`; Test `test/domain/grouping_test.dart`; Modify `lib/features/admin/players_screen.dart` (`_byClub` → `playersByClub`), `lib/features/admin/report_screen.dart` (`byClub` → `attendanceByClub`), `lib/features/admin/overrides_screen.dart` (`runsOf` → `closureRuns`).

**Interface (produces):**
```dart
/// Clubs by name, members name-sorted within, (null, …) = "Bez oddílu" last.
List<(String? clubName, List<Profile> members)> playersByClub(
    List<Profile> approved, List<Club> clubs);
/// Club sections by attended total desc, 'Bez oddílu' last (moved verbatim).
List<(String header, List<AttendanceRow> members)> attendanceByClub(
    List<AttendanceRow> rows);
/// Consecutive same-reason closures folded into runs (moved verbatim).
List<List<DayOverride>> closureRuns(List<DayOverride> overrides);
```
Tests: one scenario each (existing widget tests keep covering the screens).

---

## Stream C — booking/cancel/day rules (subagent)

### Task C1: `canCancel(isAdmin:)` + `bookableSlotCount`

**Files:** Modify `lib/domain/schedule.dart`, `lib/features/schedule/widgets/slot_tile.dart`, `lib/features/schedule/week_calendar_view.dart` (`_freeLabel`), `lib/features/schedule/day_pager_view.dart` (`freeCount`); Test `test/domain/schedule_test.dart`.

**Interface (produces):**
```dart
/// Own not-yet-started reservation, or ANY reservation for an admin.
bool canCancel({
  required SlotState state,
  required String myPlayerId,
  bool isAdmin = false,
});
/// Slots of [day] the caller could book right now (canBook over every
/// block × lane).
int bookableSlotCount(
  OpenDay day, {
  required int myActiveCount,
  required ScheduleSettings settings,
  bool isAdmin = false,
});
```
`slotTileFor`: `ownFuture = isMine && canCancel(state:, myPlayerId: me.id)` stays; `cancellable = interactive && me != null && canCancel(state:, myPlayerId: me.id, isAdmin: me.isAdmin)`. Both `_freeLabel` and the pager's `freeCount` call `bookableSlotCount`.

### Task C2: `isDayOpen` / `nextTrainingDay` move to the domain

**Files:** Move from `lib/features/kiosk/kiosk_board_view.dart:30-77` to `lib/domain/schedule.dart` (same signatures); update imports in `kiosk_board_view.dart`, `kiosk_shell.dart` and any test; Test: `test/domain/schedule_test.dart` (open training day, closed override, non-training day; `nextTrainingDay` skips a closed override and returns null past the horizon).

### Task C3: `dropFits`

**Files:** Modify `lib/domain/calendar_layout.dart`, `lib/features/schedule/week_calendar_view.dart` (`handleDrop`); Test `test/domain/calendar_layout_test.dart`.

**Interface (produces):**
```dart
/// Whether [candidate] (half-open minutes) lies inside [window] and overlaps
/// nothing in [occupied] once the dragged item's own [self] intervals are
/// subtracted (an item may land on the space it currently occupies).
bool dropFits({
  required (int, int) candidate,
  required List<(int, int)> self,
  required List<(int, int)> occupied,
  required CalendarWindow window,
});
```
`handleDrop` keeps building `candidate`/`self`/`commit` and calls `dropFits` instead of the inline `mergeIntervals`/`subtractInterval`/`any` chain. Tests: fits in free space; refused over a foreign block; allowed over its own old slot; refused outside the window.

### Task C4: kiosk offers "＋" only under the limit

**Files:** Modify `lib/features/kiosk/kiosk_board_view.dart` (`_laneRow` FreeSlot arm + the board computing `selectedCount`); Test `test/features/kiosk_test.dart`.

The board already watches `weekReservationsProvider(monday)` for every visible Monday; compute `selectedCount = activeReservationCount(<all those reservations>, selected.id, today)` once per build and pass it down. FreeSlot arm becomes
```dart
final bookable = interactive && selected != null &&
    canBook(state: state, myActiveCount: selectedCount, settings: settings);
```
Widget test: with `max_active_reservations = 1` and the selected player already holding one live future reservation, no `＋` renders; with none, it does.

---

## Stream D — day-edit planner (controller)

### Task D1: `lib/domain/day_edit.dart` + tests

**Files:** Create `lib/domain/day_edit.dart`, `test/domain/day_edit_test.dart`; Modify `lib/data/providers.dart` (move `StrandableReservation` to `lib/domain/models.dart`, keep a re-export-free import path — providers imports models already).

**Interface (produces):**
```dart
/// Future live rows on [date] whose block is outside [keptIds] — exactly the
/// rows set_day_override cancels.
int strandedOnDate(Iterable<StrandableReservation> rows, Day date, Set<String> keptIds);
/// Rows that would fall outside the grid after a settings change.
int strandedByGrid(Iterable<StrandableReservation> rows, {required int laneCount, required Set<int> trainingWeekdays});
/// Rows on one block (any date).
int strandedOnBlock(Iterable<StrandableReservation> rows, String blockId);
/// max(position) + 1, 0 for an empty list.
int nextBlockPosition(Iterable<TimeBlock> blocks);
/// Active weekly-template block ids (position >= 0).
List<String> templateBlockIds(Iterable<TimeBlock> blocks);

class DayEditContext { date, blocks, baseIds, renderedIds (Set<String>?), isTraining, reason, priority }

sealed class DayEditPlan
class DayEditNoOp extends DayEditPlan            // unchanged times, block already used
class DayEditGlobal extends DayEditPlan          // weekly template edit: overlapping blocks to warn about
class DayEditDay extends DayEditPlan {
  TimeBlock? dissolveTwin; List<TimeBlock> specialOverlaps; List<TimeBlock> hidden;
  List<TimeBlock> noteworthy; int hiddenRows; List<TimeBlock> hiddenToCancel;
  int twinRows; Set<String> keptIds; int cancellations; String cancelNote;
  int movingRows; TimeBlock? reusableSpecial;
  List<String> idsAfter(String specialId);   // override list once the special exists
  List<String> get dissolveIds;              // twin substituted, deduped
  bool get unwindsOverride;                  // dissolve on a training day back to the exact template
}
DayEditPlan planBlockEdit({required HourMinute start, required HourMinute end, required TimeBlock? existing, required List<TimeBlock> blocks, DayEditContext? day, required List<StrandableReservation> rows});

class DayRemovalPlan { List<String> idsAfter; int signUps; List<TimeBlock> targets; Set<String> sweepKeptIds; String cancelNote; }
DayRemovalPlan planBlockRemoval({required TimeBlock existing, required DayEditContext day, required List<TimeBlock> blocks, required List<StrandableReservation> rows});

class RestorePlan { List<String> templateIds; Set<String> keptIds; int cancellations; }
RestorePlan planRestoreTemplate({required DayEditContext day, required List<TimeBlock> blocks, required List<StrandableReservation> rows});
```
Every branch of the current `_save`/`_removeForDay`/`_restoreTemplate` logic maps onto one field; the widget keeps only the dialog sequencing and the `Api` calls. Unit tests mirror the scenarios of `test/features/block_dialog_day_test.dart` (no-op, dissolve, hidden + noteworthy + rows, kept ids, cancellations, ids after, unwind, removal targets + fallback, restore on non-training day).

### Task D2: rewire `block_dialog.dart`, `schedule_screen.dart`, `overrides_screen.dart`

`_save` = validate → fetch rows → `planBlockEdit` → confirms in the same order as today (special overlap, hidden, twin sweep, cancellations, notify choice) → `Api` calls driven by the plan. `_removeForDay` / `_restoreTemplate` likewise. `confirmIfBlockStrands` → `strandedOnBlock`; `schedule_screen._countStranded` → `strandedByGrid`; `overrides_screen._restore` losing count → `strandedOnDate`; `_nextPosition` (both files) → `nextBlockPosition`. Existing widget tests must stay green unchanged.

---

## Task E — wire labels and tints (controller, after B + C merge)

Replace every `ClubColors.of(x, brightness)?.$1 ?? fallback` pair with `clubTint(...)` and every inline `'${isMatch ? '🏆' : '⛔'} …'` / `'🔒 …'` with `slotEventLabel` / `rentalLabel` / `eventBandLabel` in `slot_tile.dart`, `gap_rows.dart`, `week_calendar_view.dart`, `kiosk_board_view.dart`. Then: audit spec status, plan tick, `flutter analyze && flutter test`, PR.

---

## Outcome (2026-09-02)

All three streams landed on `cleanup-3-domain` (Stream B and C as merged
subagent branches, Stream D and Task E by the controller). `flutter analyze`
clean, 266 tests (219 → 266: +47 domain/widget tests).

- New domain files: `day_edit.dart` (planBlockEdit / planBlockRemoval /
  planRestoreTemplate, stranded helpers, nextBlockPosition), `labels.dart`,
  `limits.dart`, `grouping.dart`; `schedule.dart` gained
  `canCancel(isAdmin:)`, `bookableSlotCount`, `isDayOpen`,
  `nextTrainingDay`; `calendar_layout.dart` gained `dropFits`;
  `palette.dart` gained `clubTint`.
- `block_dialog.dart` 738 → 588 lines and holds no rule any more.
- Behaviour changes (both fixes): the kiosk offers ＋ only under the
  reservation limit; a day-special is no longer hidden from the removal
  dialog's move targets by its own interval.
- Left for later: `clubs_screen`, `slot_types_screen`, `color_picker` still
  call `ClubColors.of` directly (swatches, not tints); the
  `move_reservations_dialog` lane rules still mirror the RPC inline.

