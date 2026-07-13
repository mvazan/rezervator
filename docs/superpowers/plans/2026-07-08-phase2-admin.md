# Rezervátor — Phase 2 (Admin Console) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Admin can run the alley from the app: edit schedule settings and time blocks, set per-day overrides, manage matches and rentals, manage player roles, book on behalf of any player and cancel any reservation with a note.

**Architecture:** Admin CRUD goes through direct table writes (RLS `is_admin()` policies already exist) except `set_day_override` (RPC — cancels invalidated reservations). Grid gains admin affordances driven by `Profile.isAdmin`. All screens follow the established patterns in `lib/features/admin/players_screen.dart` and `lib/features/auth/register_screen.dart` (Card/ListTile lists, `tryAction` + Czech snackbars, `confirmDialog`/`promptText` from `core/ui.dart`).

**Tech Stack:** unchanged. No new dependencies.

## Global Constraints

- Repo `/Users/mvazan/Home/rezervator`, branch `phase-1-reservations`. Czech UI strings everywhere.
- Reservations still mutated ONLY via RPCs. Day overrides ONLY via `set_day_override` RPC (it cascades cancellations); deleting an override row is a direct delete (returns the day to the weekday rule).
- Matches/rentals/blocks/settings: direct table writes (admin RLS). Times sent as `HourMinute.toSql()`, dates as `Day.toSql()`, weekday arrays as `List<int>`.
- Domain stays pure Dart, TDD for domain changes.
- Admin-only screens must be unreachable AND harmless for non-admins (RLS is the lock, UI the paint).
- Every task: `flutter analyze` clean, `flutter test` green. Commits end with `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.
- Czech labels used below are binding copy. Time input UI: `showTimePicker` (24h via `alwaysUse24HourFormat: true` builder); date input: `showDatePicker` with `locale: Locale('cs')`.

---

### Task 1: Domain — admin exemptions in canBook (TDD)

**Files:**
- Modify: `lib/domain/schedule.dart`, `test/domain/schedule_test.dart`

**Interfaces:**
- `canBook` gains `bool isAdmin = false`: admin may book any FREE slot regardless of `inPast`/`beyondHorizon`/limit (mirrors RPC: admin skips date_past/beyond_horizon/limit_reached; RPC still rejects non-free states). Non-admin behavior unchanged.
- `canCancel` unchanged (admin cancel is a UI affordance calling the RPC directly — RPC allows admin anytime).

- [ ] **Step 1: Extend tests** — in the `booking rules` group add:

```dart
    test('admin may book past/beyond-horizon free slots and ignores limit', () {
      const past = FreeSlot(inPast: true, beyondHorizon: false);
      const far = FreeSlot(inPast: false, beyondHorizon: true);
      expect(canBook(state: past, myActiveCount: 99, settings: settings, isAdmin: true), isTrue);
      expect(canBook(state: far, myActiveCount: 99, settings: settings, isAdmin: true), isTrue);
      expect(
          canBook(
              state: ReservedSlot(res(date: thursday, blockId: 'b1', lane: 1),
                  inPast: false, beyondHorizon: false),
              myActiveCount: 0,
              settings: settings,
              isAdmin: true),
          isFalse);
    });
```

- [ ] **Step 2: RED** (named param missing), then implement:

```dart
bool canBook({
  required SlotState state,
  required int myActiveCount,
  required ScheduleSettings settings,
  bool isAdmin = false,
}) {
  if (state is! FreeSlot) return false;
  if (isAdmin) return true;
  return !state.inPast &&
      !state.beyondHorizon &&
      myActiveCount < settings.maxActiveReservations;
}
```

- [ ] **Step 3:** `flutter test` green, analyze clean. Commit `feat: admin exemptions in canBook`.

---

### Task 2: Data layer — admin Api methods

**Files:**
- Modify: `lib/data/providers.dart`

**Interfaces (exact signatures later tasks call):**

```dart
  // --- admin: settings & blocks ---
  static Future<void> updateSettings({
    required int laneCount,
    required Set<int> trainingWeekdays,
    required int bookingHorizonDays,
    required int maxActiveReservations,
  }) =>
      _db.from('schedule_settings').update({
        'lane_count': laneCount,
        'training_weekdays': trainingWeekdays.toList()..sort(),
        'booking_horizon_days': bookingHorizonDays,
        'max_active_reservations': maxActiveReservations,
      }).eq('id', true);

  static Future<void> addTimeBlock(HourMinute startsAt, HourMinute endsAt, int position) =>
      _db.from('time_blocks').insert({
        'starts_at': startsAt.toSql(),
        'ends_at': endsAt.toSql(),
        'position': position,
      });

  static Future<void> updateTimeBlock(String id,
          {HourMinute? startsAt, HourMinute? endsAt, int? position, bool? active}) =>
      _db.from('time_blocks').update({
        if (startsAt != null) 'starts_at': startsAt.toSql(),
        if (endsAt != null) 'ends_at': endsAt.toSql(),
        if (position != null) 'position': position,
        if (active != null) 'active': active,
      }).eq('id', id);

  /// Delete only works for never-referenced blocks (FK restrict) — callers
  /// fall back to deactivation on failure.
  static Future<void> deleteTimeBlock(String id) =>
      _db.from('time_blocks').delete().eq('id', id);

  // --- admin: day overrides (RPC — cascades reservation cancellations) ---
  static Future<void> setDayOverride({
    required Day date,
    required bool closed,
    String reason = '',
    List<String>? blockIds,
  }) =>
      _db.rpc('set_day_override', params: {
        'p_date': date.toSql(),
        'p_closed': closed,
        'p_reason': reason,
        'p_block_ids': blockIds,
      });

  static Future<void> deleteDayOverride(Day date) =>
      _db.from('day_overrides').delete().eq('date', date.toSql());

  // --- admin: matches ---
  static Future<void> saveMatch({
    String? id,
    required Day date,
    required HourMinute startsAt,
    required HourMinute endsAt,
    required String opponent,
    String description = '',
  }) async {
    final row = {
      'date': date.toSql(),
      'starts_at': startsAt.toSql(),
      'ends_at': endsAt.toSql(),
      'opponent': opponent,
      'description': description,
      if (id == null) 'created_by': currentUserId!,
    };
    if (id == null) {
      await _db.from('matches').insert(row);
    } else {
      await _db.from('matches').update(row).eq('id', id);
    }
  }

  static Future<void> deleteMatch(String id) =>
      _db.from('matches').delete().eq('id', id);

  // --- admin: rentals ---
  static Future<void> saveRental({
    String? id,
    required String renterName,
    required List<int> lanes,
    Day? date,
    int? weekday,
    required HourMinute startsAt,
    required HourMinute endsAt,
    Day? validFrom,
    Day? validUntil,
    String note = '',
  }) async {
    final row = {
      'renter_name': renterName,
      'lanes': lanes,
      'date': date?.toSql(),
      'weekday': weekday,
      'starts_at': startsAt.toSql(),
      'ends_at': endsAt.toSql(),
      'valid_from': validFrom?.toSql(),
      'valid_until': validUntil?.toSql(),
      'note': note,
      if (id == null) 'created_by': currentUserId!,
    };
    if (id == null) {
      await _db.from('rentals').insert(row);
    } else {
      await _db.from('rentals').update(row).eq('id', id);
    }
  }

  static Future<void> deleteRental(String id) =>
      _db.from('rentals').delete().eq('id', id);

  // --- admin: roles ---
  static Future<void> setRole(String userId, Role role) =>
      _db.rpc('set_role', params: {'p_user_id': userId, 'p_role': role.name});
```

Note: `matches.created_by` also needs setting on INSERT for day_overrides? No — overrides go via RPC (sets created_by from auth.uid()). For matches/rentals INSERT the schema requires `created_by` — included above.

- [ ] **Step 1:** Append the methods to `Api` exactly as above.
- [ ] **Step 2:** `flutter analyze` clean, `flutter test` green. Commit `feat: admin api methods`.

---

### Task 3: Admin hub, settings screen, blocks screen

**Files:**
- Create: `lib/features/admin/admin_screen.dart`, `lib/features/admin/settings_screen.dart`, `lib/features/admin/blocks_screen.dart`
- Modify: `lib/features/schedule/home_shell.dart`

**Spec (follow existing patterns; complete code not repeated here — the reviewer checks this spec):**

1. `AdminScreen` — Scaffold, AppBar `Správa kuželny`, body = ListView of navigation ListTiles with leading icons:
   - `Hráči` (Icons.group_outlined) → `PlayersScreen`
   - `Nastavení rozvrhu` (Icons.tune) → `SettingsScreen`
   - `Tréninkové bloky` (Icons.schedule) → `BlocksScreen`
   - `Výjimky dnů` (Icons.event_busy) → `OverridesScreen` (Task 4)
   - `Zápasy` (Icons.emoji_events_outlined) → `MatchesScreen` (Task 4)
   - `Pronájmy` (Icons.storefront_outlined) → `RentalsScreen` (Task 4)
   For this task create the three Task-4 screens as minimal stubs (AppBar title + `Zatím nic.` body) — Task 4 replaces them.
2. `HomeShell`: replace the group-icon action with an admin-only `Icons.admin_panel_settings_outlined` IconButton (tooltip `Správa`) → `AdminScreen`. Non-admins see only logout.
3. `SettingsScreen` — form editing the `schedule_settings` singleton:
   - Fields: `Počet drah` (1–12, numeric stepper or TextField with validation), `Tréninkové dny` (7 `FilterChip`s po/út/st/čt/pá/so/ne backed by `weekdaysShort`), `Rezervace dopředu (dní)` (1–90), `Max. aktivních rezervací na hráče` (1–50).
   - Initial values from `settingsProvider` (loading spinner until data; error → Czech message).
   - Save button `Uložit` → `Api.updateSettings` via `tryAction(success: 'Uloženo.', errorText: friendlyDbError)`. Client-side range validation with Czech messages mirroring DB checks (e.g. `Počet drah musí být 1–12.`).
4. `BlocksScreen` — list of ALL blocks from `timeBlocksProvider` sorted by position:
   - Each row: `{label}` + position + `Switch` for `active` (updateTimeBlock), edit icon → dialog with two time pickers (start/end, validate end > start → `Konec musí být po začátku.`), delete icon → `confirmDialog` then `Api.deleteTimeBlock`; on failure (FK restrict) fall back automatically to `updateTimeBlock(active: false)` and snack `Blok už má rezervace — místo smazání deaktivován.`.
   - FAB `Přidat blok` → same dialog; position defaults to max+1.
5. All admin screens: watch `myProfileProvider`; if not admin, render `Scaffold` with `Jen pro správce.` (harmless paint; RLS enforces anyway).

- [ ] **Step 1:** Implement per spec. **Step 2:** analyze + tests green. **Step 3:** Commit `feat: admin hub, settings and blocks screens`.

---

### Task 4: Overrides, matches, rentals screens

**Files:**
- Replace stubs: `lib/features/admin/overrides_screen.dart`, `lib/features/admin/matches_screen.dart`, `lib/features/admin/rentals_screen.dart`

**Spec:**

1. `OverridesScreen` — list of existing overrides from `dayOverridesProvider` sorted by date (each: `dayFull(date)`, `Zavřeno — reason` or `Vlastní bloky (N)` or `Otevřeno (výchozí bloky)`, delete icon → confirm `Smazat výjimku? Den se vrátí k týdennímu pravidlu.` → `Api.deleteDayOverride`). FAB `Přidat výjimku` → editor dialog/sheet:
   - `showDatePicker` for the date (first: today, last: +365 days).
   - Mode radio: `Zavřeno` (with `Důvod` TextField, e.g. hint `Malování drah`) / `Otevřeno` (with optional block multi-select: `FilterChip` per block from `timeBlocksProvider` INCLUDING inactive ones — inactive labeled `{label} (neaktivní)`; nothing selected = default blocks → pass `blockIds: null`; some selected → pass their ids).
   - Save → `Api.setDayOverride` via tryAction, success `Výjimka uložena. Kolidující rezervace byly zrušeny.`.
2. `MatchesScreen` — list from `matchesProvider` sorted by date desc (each: `dayLabel(date) · startsAt–endsAt · opponent`, subtitle description, edit + delete icons). FAB `Přidat zápas` → form dialog: date picker, two time pickers (default 3h span: end = start + 3h when start picked first), `Soupeř` TextField (required → `Vyplň soupeře.`), `Popis` TextField (optional). Save → `Api.saveMatch` success `Zápas uložen. Kolidující rezervace byly zrušeny.`; delete → confirm → `Api.deleteMatch`.
3. `RentalsScreen` — list from `rentalsProvider` (each: renterName, subtitle `jednorázově {dayLabel}` or `každý {weekday name} {startsAt}–{endsAt}` + lanes `dráhy 1, 2` + validity window when set; edit + delete). FAB `Přidat pronájem` → form: `Nájemce` (required), mode radio `Jednorázový` (date picker) / `Týdenní` (weekday dropdown po–ne + optional `Platí od`/`Platí do` date pickers), two time pickers, lanes multi-select (`FilterChip` `Dráha N` for 1..laneCount from settings; ≥1 required → `Vyber aspoň jednu dráhu.`). Save → `Api.saveRental` success `Pronájem uložen. Kolidující rezervace byly zrušeny.`; delete → confirm → `Api.deleteRental`.
4. Shared bits: extract a small `Future<HourMinute?> pickTime(BuildContext, {HourMinute? initial})` helper (wraps `showTimePicker`, converts to `HourMinute`, forces 24h) into `lib/core/ui.dart` and reuse in Tasks 3+4 (blocks dialog too — refactor if Task 3 inlined it).

- [ ] **Step 1:** Implement per spec. **Step 2:** analyze + tests green. **Step 3:** Commit `feat: overrides, matches and rentals admin screens`.

---

### Task 5: Roles management + admin grid affordances (+ widget tests)

**Files:**
- Modify: `lib/features/admin/players_screen.dart`, `lib/features/schedule/week_screen.dart`
- Test: `test/features/week_screen_test.dart` (extend)

**Spec:**

1. `PlayersScreen`: approved-list rows gain a trailing `PopupMenuButton` (admin actions): `Udělat správcem` / `Odebrat správce` (→ `Api.setRole(id, Role.admin/Role.player)`, guard: cannot demote self — RPC enforces, map `cannot_demote_self` in `friendlyDbError` to `Sám sebe správcovství nezbavíš.`), and `Nastavit jako kiosk` behind a `confirmDialog` explaining consequences (`Účet se změní na kioskový — po přihlášení uvidí jen kioskovou obrazovku.`). Show kiosk accounts in a separate small section `Kiosk` below (they were filtered out of the players list in Phase 0 — keep that, list them separately from `profilesProvider` where `role == Role.kiosk`).
2. `friendlyDbError`: add `'cannot_demote_self': 'Sám sebe správcovství nezbavíš.'` and change the generic fallback to `'Něco se nepovedlo. ($error)'` (carry-over polish).
3. `week_screen.dart` admin affordances (all gated on `me.isAdmin` AND the existing `interactive` flag):
   - `canBook(..., isAdmin: me.isAdmin)` wiring; admin-bookable-but-normally-locked cells (inPast/horizon) render the `+` at 0.25 alpha (visually quieter).
   - Booking dialog for admins gains a player picker: default `Rezervovat pro: mě`, dropdown of approved players from `playersProvider` — selected player's id goes to `Api.createReservation(playerId: ...)`.
   - Admin tap on ANY `ReservedSlot` (own or foreign, past or future) → cancel flow. For foreign/past cancels use `promptText(title: 'Zrušit rezervaci — poznámka', hint: 'nepřišel', confirmLabel: 'Zrušit rezervaci')`; empty/whitespace note allowed (pass '' — schema default). Own-future cancels keep the existing confirm dialog (no note).
4. Widget tests (extend the existing override-based harness): (a) admin sees the player-picker dropdown in the booking dialog (override `myProfileProvider` with an admin profile); (b) admin tap on a foreign reservation opens the note prompt (find `Zrušit rezervaci — poznámka`); (c) non-admin foreign reservation stays inert (tap → no dialog).

- [ ] **Step 1:** TDD for the widget tests where practical (write, RED, implement, GREEN). **Step 2:** analyze + full suite green. **Step 3:** Commit `feat: role management and admin grid affordances`.

---

### Task 6: Phase verification

- [ ] `flutter analyze` clean; `flutter test` all green; `flutter build web --release --base-href /rezervator/` succeeds.
- [ ] Deferred-E2E note (needs live backend): settings edit propagates to grid live; closed override cancels a colliding reservation and the player is notified in Phase 3; match/rental conflict cascades verified via SQL editor.
- [ ] Phase review follows (controller).
