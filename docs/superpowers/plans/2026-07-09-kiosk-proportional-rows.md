# Rezervátor — Kiosk board: proportional row heights (plan)

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:subagent-driven-development. Checkbox steps.

**Goal:** Fix kiosk board row misalignment (live screenshot). Root cause: every time-block row is `laneCount * _rowHeight` tall regardless of the block's DURATION, so a 30-min block and a 60-min block render the same height. When a match/prep window spans blocks of unequal duration the banner cells drift out of alignment with neighbour columns' lane rows. Fix = **row height proportional to block duration**, shared identically by the rail and every day column. Also **unify the two match→block overlap mappings** (open day via domain, closed day via the board's private `_overlapsBlock`) so they can't disagree on a boundary.

**Branch:** `kiosk-proportional-rows` (from fix-push-foreground — that branch has the working push fix not yet merged; base on it so this stacks cleanly). Czech UI. No schema/domain-model change. No web/app grid change (club-color behaviour stays: mine=indigo, others=club — user confirmed).

## Global Constraints
- `flutter analyze` "No issues found!" + full test suite green each task. Commits end `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.
- ONLY touch kiosk board rendering (`lib/features/kiosk/kiosk_board_view.dart`) + a small pure helper + its tests. Do NOT change `schedule.dart` domain results, `slot_tile.dart`, web views, or any RPC.
- Preserve every existing kiosk behaviour: dark/light theme, booking-only, idle scroll-to-now, gridlines, club colors, nick, 7 columns from today, closed columns, match/prep cells.

---

### Task 1: Proportional row-height helper (TDD)

**Files:** create `lib/features/kiosk/board_layout.dart`; test `test/features/board_layout_test.dart`.

**Spec:** A pure helper computes per-block heights from durations so all columns share one vertical grid.
```dart
import '../../domain/models.dart';

/// Height (px) of one lane-row inside a block whose duration is [minutes],
/// scaled so a [refMinutes]-long block is exactly [refLaneRowHeight] tall.
/// Guards a floor so very short blocks stay tappable.
double laneRowHeight(int minutes, {
  int refMinutes = 60,
  double refLaneRowHeight = 40.0,
  double minLaneRowHeight = 22.0,
}) {
  final h = refLaneRowHeight * minutes / refMinutes;
  return h < minLaneRowHeight ? minLaneRowHeight : h;
}

/// Total height of a block's row-group = laneCount lane-rows.
double blockGroupHeight(TimeBlock block, int laneCount, {
  int refMinutes = 60,
  double refLaneRowHeight = 40.0,
  double minLaneRowHeight = 22.0,
}) =>
    laneCount *
    laneRowHeight(block.durationMinutes,
        refMinutes: refMinutes,
        refLaneRowHeight: refLaneRowHeight,
        minLaneRowHeight: minLaneRowHeight);
```
Add `int get durationMinutes => endsAt.minutesFromMidnight - startsAt.minutesFromMidnight;` to `TimeBlock` in `lib/domain/models.dart` (pure getter, no behaviour change; covered by a models test).

**Tests** (`board_layout_test.dart` + a `durationMinutes` case in models_test):
- 60-min block → laneRowHeight 40; 30-min → 22 (floored, since 20 < 22); 90-min → 60; 120-min → 80.
- `blockGroupHeight` with laneCount 4, 60-min → 160; 30-min → 88.
- `durationMinutes`: block 18:30–19:30 → 60; 18:00–18:30 → 30.

**Verify:** analyze + tests green. Commit `feat: proportional kiosk row-height helper`.

---

### Task 2: Apply proportional heights to the board

**Files:** modify `lib/features/kiosk/kiosk_board_view.dart`.

**Spec:** Replace the single scalar `rowGroupHeight = laneCount * _rowHeight` with a per-block height list derived from `blockGroupHeight`, used identically by `_Rail`, each `_DayColumn`, `gridHeight`/`totalHeight`, and `resetToNow`'s scroll math.
1. After building `railBlocks`, compute `final rowHeights = [for (final b in railBlocks) blockGroupHeight(b, settings.laneCount)];` and `final gridHeight = rowHeights.fold(0.0, (a, b) => a + b);`. Keep `totalHeight = _headerHeight + gridHeight`.
2. Snapshot for `resetToNow`: replace the `_rowGroupHeight` field with `List<double> _rowHeights` (and keep `_railBlocks`). In `resetToNow`, the vertical offset of block index `i` becomes `_headerHeight + _rowHeights.take(i).fold(0.0, (a,b)=>a+b)` (was `_headerHeight + i * _rowGroupHeight`). Keep the hasClients/clamp guards.
3. `_Rail`: take `List<double> rowHeights` instead of a scalar; each label container uses `height: rowHeights[i]`.
4. `_DayColumn`: take `List<double> rowHeights`; the per-block cell `Container` uses `height: rowHeights[i]`. Inside `_openCell`'s lane `Column`, keep `Expanded` per lane (each lane row auto-splits the block's height evenly) — so a 30-min block's lanes are shorter, a 60-min block's taller, always aligned to the rail.
5. Delete the now-unused `_rowHeight`/`rowGroupHeight` scalars (or keep `_rowHeight` as the `refLaneRowHeight` default source — pass it through so there's a single constant).
6. The match/prep banner cell (`_matchCell`) and closed cell already fill their block `Container`, so they inherit the proportional height automatically — a match spanning a 30-min + 60-min + 60-min block now paints three correctly-sized stacked banners that line up with neighbour columns.

**Verify:** analyze + full tests green (kiosk tests: the dark/7-column/booking/gridline/prep/nick assertions must still pass — they don't assert exact pixel heights; if one does, update it to the proportional value). Add/extend a kiosk test: a day with an uneven block set (one 30-min + one 60-min block) renders rail labels and both columns at matching offsets (assert the 30-min block's rendered height < the 60-min block's via `tester.getSize`). Commit `fix: kiosk board rows scale with block duration so columns align`.

---

### Task 3: Unify match/prep overlap mapping (open + closed days)

**Files:** modify `lib/features/kiosk/kiosk_board_view.dart` (+ maybe a tiny domain helper).

**Spec:** Today open-day cells read match/prep state from `buildWeekSchedule` (`openDay.slot(...)` → MatchSlot with isPrep), while closed-day cells recompute it with the board's private `_overlapsBlock`. Make closed days go through the SAME domain overlap logic so a boundary case can't render a match on a different row for open vs closed columns.
- Extract the domain's block-vs-match resolution into a small pure function usable by both — either reuse `MatchSlot`/the `_overlaps` rule from `schedule.dart` by exposing a pure `matchStateForBlock(block, matches) → (Match?, bool isPrep)` in `lib/domain/schedule.dart` (no behaviour change to `buildWeekSchedule`; refactor it to call the same helper), and have the board's closed-day path call it instead of `_overlapsBlock`. Delete the board's private `_overlapsBlock` once unused.
- Keep results identical for the common case; this only removes the divergent second implementation.

**Verify:** analyze + tests green. Add a domain test for `matchStateForBlock` (prep-only block → isPrep true; real-window block → isPrep false; no overlap → null) if not already covered by existing schedule tests. Commit `refactor: single match/prep block-overlap mapping for open and closed days`.

---

### Task 4: Verify + review + PR + rebuild/install
- Full analyze/tests; `flutter build web --release --base-href /rezervator/` + `flutter build apk --release` (with dart-defines).
- Controller: whole-branch review (focus: alignment correctness, resetToNow math with variable heights, no regression to club/nick/prep/theme); fixes; push; PR. Then rebuild+install APK on device and (optionally) redeploy so the user can see the kiosk fixed.
