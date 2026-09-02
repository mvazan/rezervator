# Rezervátor — cleanup 6: admin scaffolding (plan)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The eleven admin screens and nine dialogs stop re-implementing the same frame: role gate, AppBar + width-limited body, loading/error/data, the save-dialog shell, date/time picker tiles, lane chips, colour dots, the delete flow. An RLS or network error shows as an error with a retry, not as "Zatím žádné…". Adding an admin screen is a `AdminScaffold` + `AsyncBody` + `FormDialog`.

**Architecture:** The helpers land first (one commit, unit-tested):
`AdminScaffold` / `AsyncBody` (`admin/widgets/admin_scaffold.dart`), `FormDialog<T>` (`admin/widgets/form_dialog.dart`), `PickerTile` / `LaneChips` / `ColorDot` (`admin/widgets/form_fields.dart`), `pickDay` / `confirmDelete` (`core/ui.dart`), `attendanceProvider` (`data/providers.dart`). Then three streams wire disjoint screen groups in parallel worktrees; each adds a smoke widget test for every screen that had none.

**Tech Stack:** Flutter 3.38 / Dart 3.10; no backend change.

**Branch:** `cleanup-6-admin` from `main` (after PR #55).

## Global Constraints

- No behaviour change: same Czech copy, same dialogs, same RPC calls. Existing widget tests (`players`, `overrides`, `tenants`, `kiosk_screen`, `move_reservations_dialog`, `block_dialog_day`) pass unchanged.
- Every screen a stream touches that has no widget test gets one smoke test (renders for an admin, main list/empty state visible, the add dialog opens) in `test/features/<screen>_test.dart`.
- Streams touch only their own files (listed below) plus their new test files. `flutter analyze` clean, `flutter test` green after every task.
- Commit per task, `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>`; controller opens the PR.

## Helper contract (committed before the streams start)

```dart
AdminScaffold({required String title, required Widget body, Widget? floatingActionButton, List<Widget> actions = const [], bool superadminOnly = false})
AsyncBody<T>({required AsyncValue<T> value, required Widget Function(T) builder, VoidCallback? onRetry})
FormDialog<T>({required String title, required List<Widget> children, required Future<T?> Function() onSave, String saveLabel = 'Uložit', String savingLabel = 'Ukládám…', String cancelLabel = 'Zrušit', CrossAxisAlignment crossAxisAlignment = .start, List<Widget> leadingActions = const []})
  // onSave: validate (snack + return null to stay open) → RPC via tryAction → return true (or a value) to pop
PickerTile({required String label, required String value, required VoidCallback onTap})
LaneChips({required int laneCount, required Set<int> selected, required ValueChanged<Set<int>> onChanged})
ColorDot({required int colorIndex, Color? fallback})
Future<Day?> pickDay(BuildContext, {Day? initial, required Day first, required Day last})
Future<bool> confirmDelete(BuildContext, {required String title, required String message, required Future<void> Function() action, String? success})
attendanceProvider((year, month)) → AsyncValue<List<AttendanceRow>>
```

---

### Stream 1 — list screens: `clubs_screen`, `slot_types_screen`, `players_screen`, `tenants_screen`, `kiosk_screen`, `report_screen`

- [x] Gate/AppBar/AdminBody → `AdminScaffold` (tenants: `superadminOnly: true`); `ref.watch(x).value ?? []` → `AsyncBody` with retry; swatches → `ColorDot`; delete flows → `confirmDelete`; `_ClubDialog` / `_TypeDialog` → `FormDialog` and moved to `admin/widgets/club_dialog.dart` / `slot_type_dialog.dart`; lane chips → `LaneChips`.
- [x] `report_screen`: `attendanceProvider((year, month))` + `AsyncBody` replace `_future`/`_load`/two `FutureBuilder`s; export button reads the same `AsyncValue`; `friendlyDbError` no longer used for the FileSaver failure (plain message).
- [x] Smoke tests: `clubs_screen_test`, `slot_types_screen_test`, `report_screen_test`.

### Stream 2 — event screens: `matches_screen`, `rentals_screen`, `overrides_screen`, `widgets/blockage_dialog`

- [x] `AdminScaffold`, `AsyncBody`, `confirmDelete`; every `showDatePicker` → `pickDay`; Date/Start/End tiles → `PickerTile`; lane chips → `LaneChips`; `_RentalDialog` → `admin/widgets/rental_dialog.dart`, `_OverrideDialog` → `admin/widgets/override_dialog.dart`, `MatchDialog` → `admin/widgets/match_dialog.dart` (update the two importers: `matches_screen.dart`, `lib/features/schedule/schedule_actions.dart`); all four dialogs on `FormDialog`.
- [x] `overrides_screen`: the `_OverrideDialog`'s `ref.read(dayOverridesProvider)` inside a picker callback → pass `overrides` in; the closure/fork/blockage tile builders declared inside `build` → private widgets.
- [x] Smoke tests: `matches_screen_test`, `rentals_screen_test` (overrides has one).

### Stream 3 — `schedule_screen`, `widgets/move_reservations_dialog`, `auth/register_screen`

- [x] `schedule_screen`: `AdminScaffold`; the settings form no longer initialises controllers inside `build` (`if (!_initialized) _initFrom(settings)`) — seed once from the first data and `ref.listen(settingsProvider, …)` re-seeds while the form is untouched; `_GeneratorDialog` → `admin/widgets/generator_dialog.dart` on `FormDialog`; `_deleteBlock` → `confirmDelete` where it fits (delete-or-deactivate keeps its two-step logic).
- [x] `move_reservations_dialog`: `_laneTarget` stops `ref.read`ing `weekReservationsProvider` inside build — the reservations watched once at the top are passed down.
- [x] `register_screen`: the `_tenantId` assignment inside `build` → `ref.listen(tenantsProvider, …)` preselecting the single alley once.
- [x] Smoke test: `schedule_screen_test`.

### Controller — after the merges

- [x] `admin_screen` (the hub) keeps its own layout but uses `AdminScaffold` for the gate if it fits; delete `widgets/admin_body.dart` only if nothing imports it any more.
- [x] Audit spec status, plan outcome, final gate, PR.

---

## Outcome (2026-09-02)

Landed on `cleanup-6-admin`: helpers + hub by the controller, the three
screen streams by subagents in parallel worktrees (merged without a single
conflict — disjoint file lists). `flutter analyze` clean, 301 tests
(272 → 301: 10 helper tests, 19 screen smoke tests for clubs, slot types,
report, matches, rentals, schedule).

- Every admin screen sits on `AdminScaffold` (the hub with
  `constrainBody: false`); every provider-backed list renders through
  `AsyncBody` with a retry — an RLS/network error is now an error, not
  "Zatím žádné…".
- Nine dialogs on `FormDialog` (`saveEnabled` added for the block
  generator's up-front gating); `ClubDialog`, `SlotTypeDialog`,
  `MatchDialog`, `RentalDialog`, `OverrideDialog`, `GeneratorDialog` live in
  `admin/widgets/` like `BlockageDialog` already did. `BlockDialog` keeps its
  own action row (three destructive/restore actions).
- `pickDay` replaced five `showDatePicker` copies, `PickerTile` the
  date/time tiles, `LaneChips` three chip wraps, `ColorDot` two swatches,
  `confirmDelete` eight delete flows.
- The settings form and the register screen no longer mutate state inside
  `build` (`ref.listen`); `MoveReservationsDialog` reads its reservations
  once; the report screen watches `attendanceProvider((year, month))`.
- Intentional visible changes: retry buttons on error states; the report's
  export failure says "Export se nepovedl." instead of a DB-error mapping.
- Left: the settings form's own Uložit (a page, not a dialog) and
  `register_screen`'s button keep their inline saving state.

