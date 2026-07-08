# Rezervátor — Redesign „Noční liga" Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:subagent-driven-development. Checkbox steps.

**Goal:** Implement the approved visual redesign (spec: `docs/superpowers/specs/2026-07-08-redesign-nocna-liga-design.md`) — indigo/cyan theme with bundled Manrope, shared SlotTile/DayHeader components, day-pager + week-list views with an AppBar toggle, always-dark kiosk, auth/admin polish. **Presentation only:** domain, data, RPCs, and all user-facing Czech strings stay byte-identical (53 tests depend on them).

**Branch:** `redesign-nocna-liga`. Fonts are ALREADY in `assets/fonts/` (4 static Manrope weights + OFL.txt) — do not download anything.

## Global Constraints

- Spec decisions are binding; where this plan and the spec disagree, the spec wins.
- Palette anchors: seed `0xFF6366F1`; accent `0xFF22D3EE`; dark surfaces `0xFF0F172A` (background) / `0xFF1E293B` (containers); rental amber tones, match rose tones (pick shades via ColorScheme roles where possible, hardcode only the slate surface overrides).
- No text/copy changes anywhere. Existing 53 tests must pass UNMODIFIED except where a test asserts pure styling internals (none known); if one breaks, fix the implementation, not the test — report BLOCKED if impossible.
- `flutter analyze` "No issues found!" (info lints count) + full test suite green each task. Commits end `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.

---

### Task 1: Theme, fonts, GradientButton

**Files:** create `lib/core/theme.dart`, `lib/core/widgets/gradient_button.dart`; modify `pubspec.yaml`, `lib/main.dart`.

**Spec:**
1. `pubspec.yaml`: register assets/fonts family:
```yaml
  fonts:
    - family: Manrope
      fonts:
        - asset: assets/fonts/Manrope-Regular.ttf
          weight: 400
        - asset: assets/fonts/Manrope-Medium.ttf
          weight: 500
        - asset: assets/fonts/Manrope-Bold.ttf
          weight: 700
        - asset: assets/fonts/Manrope-ExtraBold.ttf
          weight: 800
```
2. `lib/core/theme.dart`: `ThemeData buildTheme(Brightness brightness)` — move the entire `_theme` body out of main.dart and rebuild it per spec §Architektura: `ColorScheme.fromSeed(seedColor: Color(0xFF6366F1), brightness: …)` then `copyWith(secondary/secondaryContainer & tertiary tuned to cyan 0xFF22D3EE family)`; dark: additionally override `surface: 0xFF0F172A`, `surfaceContainerLowest/Low/…/Highest` with a slate ramp around `0xFF1E293B`, `outlineVariant` slate-700 (`0xFF334155`). `fontFamily: 'Manrope'`; textTheme: headlineMedium/titleLarge w800, titleMedium/titleSmall w700, body w400, labelLarge w700. Component themes: keep the existing ones (cards 16, inputs 12, buttons 12, floating snackbar) adjusted per spec (Dialog radius 20, dark = card side BorderSide slate-700 instead of shadow; light = soft shadow `Color(0x1A6366F1)` blur 16 offset 0,4 via CardThemeData surfaceTintColor/shadowColor).
3. `lib/core/widgets/gradient_button.dart`: `GradientButton({required onPressed, required child, IconData? icon, double minHeight = 48})` — Ink + InkWell over `LinearGradient(colors: [Color(0xFF6366F1), Color(0xFF22D3EE)])`, radius 12, white bold label, disabled (onPressed == null) = solid disabled grey, ripple works.
4. `lib/main.dart`: delete `_theme`, use `theme: buildTheme(Brightness.light), darkTheme: buildTheme(Brightness.dark)`.

**Verify:** analyze clean; 53/53 tests; `flutter build web --release --base-href /rezervator/` succeeds (fonts bundle). Commit `feat: night league theme, manrope fonts, gradient button`.

---

### Task 2: Shared schedule widgets + week list restyle

**Files:** create `lib/features/schedule/widgets/slot_tile.dart`, `lib/features/schedule/widgets/day_header.dart`; modify `lib/core/ui.dart` (`initialsOf`), `lib/features/schedule/week_screen.dart`; test `test/domain/…` add `initialsOf` unit test (in models_test or a small core test file).

**Spec:**
1. `initialsOf(String displayName)` in core/ui.dart: first letters of first two words, uppercased ('Ján Novák'→'JN', single word → first 2 chars, empty → '?'). Unit test with those 3 cases.
2. `SlotTile` — one widget for every cell (constructor: `{required SlotState state, required SlotTileSize size /*compact|large*/, String? playerName, bool isMine = false, VoidCallback? onTap}`): visuals per spec (Free bookable dashed primary outline + ＋; quiet ＋ at 0.25 alpha; inert muted blank; Mine = primaryContainer, name bold; Other = initials avatar circle + name; Rental amber + renter name; Match rose + text 'Zápas'). Sizes: compact minHeight 44 / font 10; large minHeight 56 / font 12 + avatar 24. IMPORTANT: render the SAME texts the current cells render (player display name incl. mine — no 'Ty'; renterName; 'Zápas') so existing finders pass.
3. `DayHeader` — per spec (badge with `weekdaysShort`+day number, day title `dayFull`, trailing chip 'N volných' — compute N = count of FreeSlot non-inert passed in, or accept a preformatted chip label from caller to avoid logic drift; match strip rows for `day.matches` with existing 🏆 text format from week_screen).
4. `week_screen.dart`: replace `_DaySection`/`_SlotCell` internals with `DayHeader` + Table of `SlotTile(compact)` — ALL existing behavior (interactive gate, canBook/canCancel wiring, admin flows, dialogs, handlers, alpha rules) preserved exactly; only the widget tree/styling changes. Keep the file the shell for now (Task 3 splits views).

**Verify:** analyze clean; ALL existing tests green unmodified (esp. `week_screen_test.dart` — names, dialogs, `Icons.add` finders must still find: keep `Icon(Icons.add)` as the ＋ glyph inside SlotTile). Commit `feat: shared slot tile and day header, restyled week list`.

---

### Task 3: Day pager view + AppBar toggle + persistence

**Files:** create `lib/features/schedule/day_pager_view.dart`, `lib/features/schedule/widgets/day_chip_strip.dart`; modify `lib/features/schedule/week_screen.dart` (shell: toggle + delegation), `pubspec.yaml` (`flutter pub add shared_preferences`); test extend `test/features/week_screen_test.dart` (or new file) with the 2 specced tests.

**Spec:**
1. Shell (`WeekScreen`): state `ScheduleView {day, week}`; initial value: stored pref `schedule_view` if present, else width < 700 → day, else week (MediaQuery at first build). Toggle IconButton in the header row (icons `Icons.view_week_outlined` ↔ `Icons.view_day_outlined`, tooltip `Týden`/`Den`), writes pref. Body: `WeekListView` (Task 2 restyle, extracted or inline as today) vs `DayPagerView`. Both receive the same computed `WeekSchedule` + handlers (booking/cancel callbacks with their current signatures) — compute stays in the shell so realtime/providers wiring is untouched.
2. `DayChipStrip`: 7 chips (po–ne + day number); selected = gradient background (reuse GradientButton's gradient via BoxDecoration); closed days 45% opacity; dots under number = count of MY live reservations that day (from `myActiveReservationsProvider` list already watched in shell — pass in). Tap selects day.
3. `DayPagerView`: `PageView.builder` synced with the strip (controller); page = one day: `DayHeader` + lane header row + rows of `SlotTile(large)`; ClosedDay = big card `Zavřeno[ — reason]` + match strips. Swiping past Sunday/before Monday shifts `weekOffset` (call shell callback) and lands on Mon/Sun of the adjacent week. Week chevrons + `dnes` in the shell keep working in both views (`dnes` also selects today's chip).
4. Widget tests: (a) toggling the AppBar icon switches view (find DayChipStrip vs the week Table) and persists (`SharedPreferences.setMockInitialValues` + assert stored value); (b) booking dialog opens from a large free tile in day view (reuse harness/overrides; make all weekdays training days as in existing tests).

**Verify:** analyze; whole suite green (53 + new). Commit `feat: day pager view with toggle and per-device preference`.

---

### Task 4: Kiosk dark restyle + auth/admin polish (+ tests)

**Files:** modify `lib/features/kiosk/kiosk_shell.dart`, `kiosk_week_view.dart`, `name_picker.dart`, `lib/features/auth/{login,register,waiting}_screen.dart`, `lib/features/kiosk/kiosk_login_screen.dart`, `lib/features/admin/admin_screen.dart`; test extend `test/features/kiosk_test.dart`.

**Spec:**
1. Kiosk always dark: wrap KioskShell's Scaffold in `Theme(data: buildTheme(Brightness.dark), child: …)`. Status bar = slate panel (surfaceContainerHighest of dark scheme), clock w800 28px + date, info line 13–15px, `GradientButton` for `Rezervovat` (minHeight 56); selected banner keeps exact texts (`Rezervuje: {name}`) + initials avatar + ✕ 40px.
2. `kiosk_week_view.dart`: replace local cells with `SlotTile(large)` + `DayHeader` (same texts/behavior — booking-only, no cancel taps); keep isDayOpen/nextTrainingDay logic untouched.
3. `name_picker.dart`: dark tiles — indigo outline, selected/pressed gradient fill; sizes unchanged (≥72 prefix tiles, name tiles ≥200×64); texts unchanged.
4. Auth screens + kiosk login: wrap content in centered Card (max 420, radius 20) over a `Container` with subtle radial gradient background (dark: slate→indigo tint; light: indigo 6%→transparent); logo 🎳 inside a circle with 2px gradient border. NO text changes (login_screen's error machinery untouched — style only).
5. `admin_screen.dart`: ListTile leading icons wrapped in 40×40 rounded square `primaryContainer` tint.
6. Tests (extend kiosk_test.dart): (c-spec) kiosk renders dark (`Theme.of(tester.element(find.byType(KioskWeekView))).brightness == Brightness.dark`) and shows the full week (7 DayHeader/day sections); existing 5 kiosk tests pass unmodified.

**Verify:** analyze; suite green; `flutter build web --release --base-href /rezervator/` + `flutter build apk --debug`. Commit `feat: dark kiosk restyle, auth and admin polish`.

---

### Task 5: Verification + review + PR

- Full suite + builds; controller phase review (visual-consistency + no-behavior-change focus); fixes; push branch; PR to main (user merges → Pages auto-deploys → kiosk auto-updates).
