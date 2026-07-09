# Rezervátor — Kiosk board na absolutní 30-min časové ose (plan)

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:subagent-driven-development. Checkbox steps.

**Goal:** Implement spec `docs/superpowers/specs/2026-07-09-absolute-time-axis-design.md`: replace the kiosk board's per-block/normalized geometry with an ABSOLUTE 30-minute time axis. Every block (default or shifted) is placed at its true time — a block at 16:00 sits vertically at the rail's 16:00 mark in EVERY column, so shifted days line up with the axis and with standard days. A 60-min block spans 2 units, a 30-min prep spans 1.

**Branch:** `absolute-time-axis` (from `slot-shift-hybrid` — builds on PR #12; base on it so it stacks). Czech UI. No schema/RPC change. App/web grid unchanged. shiftBlocks + ±30 buttons (from PR #12) stay.

## Global Constraints
- `flutter analyze` "No issues found!" + full tests green each task. Commits end `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.
- Preserve: dark/light, booking-only, idle scroll-to-now, gridlines, club colors, nick, DNES gradient, closed columns, match/prep cells, time labels on shifted-day cells.
- 30 min is the finest unit (shift is ±30) — axis granularity = 30 min.

---

### Task 1: Domain/layout — axis math (TDD)

**Files:** modify `lib/features/kiosk/board_layout.dart`; test `test/features/board_layout_test.dart`.

**Spec:** Pure helpers for the absolute axis.
```dart
/// Height of one 30-min axis unit for [laneCount] lanes. A block spanning N
/// half-hours is N*unit tall; lanes split that height. refLaneRowHeight is the
/// per-lane height of a 30-min unit.
double axisUnit(int laneCount, {double laneUnit30 = 22.0}) => laneCount * laneUnit30;

/// The axis start (earliest block start across all days, floored to :00/:30)
/// and the number of 30-min slots to the latest block end (ceiled to :00/:30).
({HourMinute start, int slots}) axisRange(List<TimeBlock> blocks) {
  // min start, max end over blocks; floor start to 30, ceil end to 30.
  // slots = (ceilEnd - floorStart) / 30. Empty → (00:00, 0).
}

/// Where a block sits on the axis: (startSlot index from axisStart, spanSlots).
({int startSlot, int spanSlots}) slotOffset(TimeBlock block, HourMinute axisStart) {
  final s = (block.startsAt.minutesFromMidnight - axisStart.minutesFromMidnight) ~/ 30;
  final span = (block.endsAt.minutesFromMidnight - block.startsAt.minutesFromMidnight) ~/ 30;
  return (startSlot: s, spanSlots: span);
}
```
Implement axisRange precisely: floorStart = start - start%30; ceilEnd = end rounded up to next 30. Guard non-30-aligned blocks (all are 30-aligned in practice since shift is ±30 and defaults are hourly — but floor/ceil handles any).

**Tests:** axisRange over default hourly blocks 15:30–21:30 → start 15:30, slots 12 (15:30→21:30 = 6h = 12×30). slotOffset(16:30–17:30, axisStart 15:30) → startSlot 2, spanSlots 2. 30-min block → spanSlots 1. axisUnit(4) → 88. Mixed default+shifted set → start = earliest, slots to latest. Empty → (00:00, 0).

**Verify:** analyze + tests green. Commit `feat: absolute 30-min axis math helpers`.

---

### Task 2: Board renders on the absolute axis

**Files:** modify `lib/features/kiosk/kiosk_board_view.dart`.

**Spec:** Rebuild the geometry around `axisRange` over ALL visible days' blocks (default + shifted), NOT the per-block rowHeights list.
1. Collect all blocks across visible OpenDays (default active + each day's own blocks), compute `(axisStart, slotCount) = axisRange(allBlocks)`, `unit = axisUnit(laneCount)`. `gridHeight = slotCount * unit`, `totalHeight = _headerHeight + gridHeight`.
2. Snapshot for resetToNow: store `_axisStart`, `_unit`, `_slotCount` (replace `_railBlocks`/`_rowHeights`). resetToNow offset = `_headerHeight + ((now - axisStart)/30 clamped to [0,slotCount]) * unit`. `_currentOrNextBlockIndex` → compute now's slot directly.
3. `_Rail`: for each 30-min slot i in 0..slotCount-1, a `SizedBox(height: unit)` with a label `axisStart + i*30min` (small font ~9; make whole-hour or default-boundary lines slightly bolder — optional). Gridline (faint) at each slot boundary.
4. Each `_DayColumn` (both standard and shifted now use the SAME absolute placement — no more isShifted branch for geometry, though shifted days still get the ⚡ header + in-cell time labels): build a `Column` (or Stack) of height `gridHeight` where the day's blocks are placed at their slots:
   - Iterate the day's blocks sorted by start. Track a cursor slot (start at 0). For each block: if its `startSlot` > cursor, emit an empty dim `SizedBox(height: (startSlot-cursor)*unit)` gap; then emit the block cell `SizedBox(height: spanSlots*unit, child: _openCell/_matchCell(...))`; advance cursor to `startSlot+spanSlots`. After the last block, if cursor < slotCount, emit a trailing empty gap. (Standard days' hourly blocks are contiguous → no gaps; shifted days may have their own contiguous set at shifted times → placed at the right offset, empty above/below if their range is narrower than the axis.)
   - Closed day: a single dim `SizedBox(height: gridHeight)` with the vertical "✕ zavřeno" (as today) + its match cells if any (place matches at their slots too — or keep today's simpler closed rendering; match the current closed behaviour but sized to gridHeight).
5. Cell rendering (`_openCell`, `_laneRow`, `_matchCell`): keep lanes = Column of Expanded (split the block's `spanSlots*unit` height). Keep the shifted-day in-cell time label (top-right, from PR #12) — now optional since the axis shows time, but spec keeps it for shifted days; standard days no label.
6. Delete now-unused `blockGroupHeight`/`rowHeights`/`_shiftedStrip`/`isShiftedDay`-geometry paths (keep `isShiftedDay` only if still used for the ⚡ header + time-label flag; the geometry no longer branches on it).

Key correctness: a block at time T has the same `startSlot` in every column → same y-offset → vertical alignment across columns and with the rail. Verify no rounding: slot math is integer (÷30), heights are `slots*unit` (exact).

**Verify:** analyze + full tests green (existing kiosk tests use default hourly blocks on all days → contiguous, axis = their range, no gaps → same visual as before, aligned; some tests may assert on rail structure — update to axis-slot equivalents WITHOUT weakening dark/columns/booking/prep/nick/club asserts). ADD tests: (a) a shifted block at 16:00 and a default block at 16:00-on-axis share the same top y (getTopLeft.dy within 1px); (b) a 30-min prep cell is exactly half the height of a 60-min block; (c) rail has slotCount 30-min labels. `flutter build web --release --base-href /rezervator/` + `flutter build apk --debug`. Commit `feat: kiosk board on absolute 30-min time axis`.

---

### Task 3: Verify + review + PR + rebuild/install
- Full analyze/tests; web + apk release builds.
- Controller whole-branch review (focus: axis alignment across columns, resetToNow slot math, gap handling for shifted days narrower than axis, no regression to standard-day appearance, integer slot math exactness); fixes; push; PR. Rebuild+install APK; note this stacks on PR #12 → merge #12 first.
