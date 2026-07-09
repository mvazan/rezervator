# Rezervátor — Posun slotů ±30 + hybridní kioskový board (plan)

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:subagent-driven-development. Checkbox steps.

**Goal:** Implement spec `docs/superpowers/specs/2026-07-09-slot-shift-hybrid-board-design.md`: (1) ±30-min shift buttons in the day-exception editor that pre-fill custom times; (2) kiosk board hybrid — standard days share a swimline/rail, a day with shifted (non-default) times renders as its own continuous column with per-cell times shown even on free cells; (3) prep becomes its own short block via the shift.

**Branch:** `slot-shift-hybrid` (from main). Czech UI. No schema/RPC change. App/web grid unchanged (only kiosk board). Uses existing `matchSpecialBlocks`, `set_day_override`, `blockGroupHeight`, `matchStateForBlock`.

## Global Constraints
- `flutter analyze` "No issues found!" + full tests green each task. Commits end `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.
- Preserve all kiosk behaviour: dark/light, booking-only, idle scroll-to-now, gridlines, club colors, nick, DNES gradient, closed columns, proportional heights, match/prep cells.

---

### Task 1: Domain `shiftBlocks` (TDD)

**Files:** create `lib/domain/shift.dart` (or add to an existing domain file — pick blocks.dart if it exists, else new); test `test/domain/shift_test.dart`.

**Spec:**
```dart
import 'models.dart';

/// Shift every block's [start,end] by [offsetMinutes] (e.g. -30 / +30).
/// Blocks that would run before 00:00 or past 24:00 are dropped. Returns
/// (start,end) HourMinute pairs sorted by start — feed into the custom-times
/// editor rows.
List<(HourMinute, HourMinute)> shiftBlocks(
    List<TimeBlock> blocks, int offsetMinutes) {
  final out = <(HourMinute, HourMinute)>[];
  for (final b in blocks) {
    final s = b.startsAt.minutesFromMidnight + offsetMinutes;
    final e = b.endsAt.minutesFromMidnight + offsetMinutes;
    if (s < 0 || e > 24 * 60) continue;
    out.add((HourMinute(s ~/ 60, s % 60), HourMinute(e ~/ 60, e % 60)));
  }
  out.sort((a, b) => a.$1.minutesFromMidnight.compareTo(b.$1.minutesFromMidnight));
  return out;
}
```

**Tests:** +30 shifts 15:30–16:30 → 16:00–17:00; −30 → 15:00–16:00; a 23:30–00:30-ending block (e.g. 23:30–24:00 impossible — use 23:00–24:00 +30 → dropped); empty input → []; sorted output.

**Verify:** analyze + tests green. Commit `feat: shiftBlocks domain helper`.

---

### Task 2: Admin — ±30 shift buttons in the day-exception editor

**Files:** modify `lib/features/admin/overrides_screen.dart`.

**Spec:** In the "Otevřeno — vlastní časy" mode, above the od–do row list, add a Row with two buttons `− 30 min` and `+ 30 min` (OutlinedButton or TextButton.icon). On tap: take the **default active blocks** (from `timeBlocksProvider` where active, sorted — NOT the current editor rows), call `shiftBlocks(active, ∓30)`, and REPLACE the editor rows with the result (each row = a start/end time pair). If shift drops all blocks (edge), show a snack `Posun by přesáhl půlnoc.` and keep current rows. The rest (save via matchSpecialBlocks + addSpecialTimeBlock + setDayOverride) is unchanged. READ overrides_screen.dart first to match its row-state structure (the rows list the editor holds) and mode toggle.

**Verify:** analyze + tests green. ADD a widget test: tapping "+ 30 min" fills the editor rows with the default blocks shifted +30 (assert a shifted time like 16:00 appears in a row field). Commit `feat: ±30 min shift buttons in day-exception editor`.

---

### Task 3: Kiosk board hybrid — swimline for standard days, own-times column for shifted days

**Files:** modify `lib/features/kiosk/kiosk_board_view.dart` (+ maybe a small helper in board or domain to classify a day).

**Spec (the core change):**
1. **Swimline = default active blocks only.** Replace the current `railBlocks` (union over all days) with `railBlocks = <default active blocks>` sorted (from settings/timeBlocks active). `rowHeights` computed from these (proportional, as now). The `_Rail` and rowHeights use only these.
2. **Classify each day** (helper `bool isShiftedDay(OpenDay day, List<TimeBlock> defaultActive)`): a day is "shifted/custom" when its resolved block set (day.blocks) differs from the default active set (compare id sets). Standard day = same set → renders in swimline. Closed day = as today.
3. **Standard `_DayColumn`** (unchanged behaviour): one cell per `railBlocks[i]`, height `rowHeights[i]`, cells WITHOUT time labels (time from the rail). Lanes, match/prep, club/nick — as now.
4. **Shifted `_DayColumn` variant** (new): the column is ONE continuous strip of total height = sum(rowHeights) (so it aligns top/bottom with the swimline columns), split into the DAY's OWN blocks at proportional heights (blockGroupHeight over the day's blocks, normalized so their sum == the swimline total height — scale factor = swimlineTotal / sum(dayBlockHeights), so the strip fills the same vertical extent). Each block cell shows its TIME as a small label (top-left, `startsAt–endsAt`), on free AND occupied AND prep AND match cells (spec §3). Booking taps work per the day's block+lane as usual.
   - Time label format: `${b.startsAt.display()}–${b.endsAt.display()}` small (fontSize ~9, onSurfaceVariant), above the cell content.
   - Header gets a subtle marker that it's custom (e.g. the day already shows its date; optionally a small „⚡" or nothing — keep minimal, spec shows ⚡ but that's optional; DO add a tiny indicator so it reads as different — a ⚡ before the date in the day header is fine).
5. Missing-block empty cells only occur for standard days that lack a default block (rare) — keep the dim empty cell. Shifted days never have swimline gaps (own strip).
6. `resetToNow` vertical math: unchanged for the rail (uses swimline rowHeights). The now-line targets a swimline row; shifted columns scroll with it (same SingleChildScrollView) — fine.

Implementation approach: keep `_DayColumn` taking the day + railBlocks + rowHeights, and branch internally: if `isShiftedDay` → build the own-times strip (iterate day.blocks, per-cell height = rowHeights-total * blockGroupHeight(dayBlock)/sum, with time labels); else → current swimline path. Reuse `_openCell`/`_laneRow`/`_matchCell` but pass a `showTime`/`timeLabel` flag for the shifted variant.

**Verify:** analyze + full tests green. Existing kiosk tests use default blocks on all days (standard path) → must pass unchanged. ADD tests: (a) a standard day renders swimline cells with NO time label; (b) a shifted day (override with non-default block_ids → day.blocks differ) renders a column whose free cells DO show a time label (assert a `HH:MM–HH:MM` text appears in that column incl. on a free ＋ cell); (c) shifted column total height ≈ swimline total (alignment). Commit `feat: kiosk hybrid board — own-times column for shifted days`.

---

### Task 4: Verify + review + PR + rebuild/install
- Full analyze/tests; web + apk release builds.
- Controller whole-branch review (focus: shifted-day strip height normalization + alignment, time labels on all cell types incl. free, standard-day path unchanged, shift buttons pre-fill correctly, prep now a short block); fixes; push; PR. Rebuild+install APK; note web redeploy after merge + kiosk cache reload.
