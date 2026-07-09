# Rezervátor — UI: fit-width mód, splash rámik, logout do profilu (plan)

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:subagent-driven-development. Checkbox steps.

**Goal:** Three UI improvements requested from real use:
1. Remove the white ring/border around the logo on the splash (and anywhere AuthLogo shows an unwanted light disc behind the image).
2. Add a **"fit width" mode** (per-device toggle) that turns OFF horizontal grid scroll in BOTH app views — all lanes fit the screen width (like web 100% width), names clipped with ellipsis, whole day visible. Tighter spacing in portrait to use space efficiently.
3. Move **Logout** from the AppBar into the profile screen.

**Branch:** `ui-fitwidth-splash-logout` (from main — PR #9/#10 already merged). Czech UI. No schema/domain/RPC change.

## Global Constraints
- `flutter analyze` "No issues found!" + full test suite green each task. Commits end `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.
- Kiosk board untouched. No changes to reservation logic/texts.

---

### Task 1: Splash / AuthLogo — remove white ring (mirror Termínátor)

**Files:** modify `lib/core/widgets/auth_background.dart` (AuthLogo), `lib/features/auth/auth_gate.dart` (_Splash).

**Root cause:** AuthLogo wraps the square logo image (logo_circle.png) in a gradient ring PLUS an inner `scheme.surface`-filled circle (auth_background.dart:76-99). That surface disc shows as a light rim between the gradient ring and the image — the "white border" in light mode.

**Fix — use the WORKING pattern from the sibling project /Users/mvazan/Home/terminator** (READ terminator/lib/features/auth/auth_gate.dart:45-59 and login_screen.dart:117-127). Terminator has NO gradient ring and NO surface disc — the logo is just a rounded-rectangle-clipped image:
```dart
ClipRRect(
  borderRadius: BorderRadius.circular(24),
  child: Image.asset('assets/images/logo.png', width: 96, height: 96, fit: BoxFit.cover),
)
```
- AuthLogo (auth_background.dart): REPLACE the gradient-ring + surface-disc + ClipOval structure with a plain `ClipRRect(borderRadius: BorderRadius.circular(size * 0.25), child: Image.asset('assets/images/logo.png', width: size, height: size, fit: BoxFit.cover))`. No ring, no background disc. Use `logo.png` (the full square master) — not `logo_circle.png` — since a rounded rect suits a square image; keep `_gradientColors` only if still referenced elsewhere (else delete). Drop the now-unused `scheme` if nothing else uses it.
- `_Splash` (auth_gate.dart): replace its `ClipOval(Image...)` with `const AuthLogo(size: 96)` (now ring-less) so splash + login + register match. Centered on the scaffold, no extra decoration.

Net: logo is a clean rounded-square image everywhere, no white/surface rim, matching terminator's proven look.

**Verify:** analyze + tests green (no test asserts splash internals; if any does, adapt). `flutter build apk --debug`. Commit `fix: drop white disc behind logo, use rounded-square like terminator`.

---

### Task 2: Fit-width (no horizontal scroll) mode for app views

**Files:** modify `lib/features/schedule/week_screen.dart` (`_grid`, WeekListView, header toggle, prefs), `lib/features/schedule/day_pager_view.dart` (its lane layout), possibly `lib/features/schedule/widgets/slot_tile.dart` (ellipsis on compact tile names — verify it already clips).

**Design:** A new per-device boolean pref `fit_width` (key `scheduleFitWidthPrefKey = 'fit_width'`, default true on width < 700 i.e. phones, false otherwise — most useful on phones). A toggle in the AppBar (icon `Icons.fit_screen_outlined` / `Icons.width_normal_outlined`, tooltip `Roztáhnout na šířku` / `Posuvná mřížka`) that flips it and persists (mirror the existing `_view`/`scheduleViewPrefKey` machinery: field `bool? _fitWidth`, resolve in `_resolveInitialView`/didChangeDependencies alongside `_view`, `_setFitWidth` writes the pref).

**Week list `_grid` (week_screen.dart:507):**
- When `fitWidth` is ON: replace the `SingleChildScrollView(horizontal) + Table(FixedColumnWidth(84), col0 FixedColumnWidth(92))` with a Table using `columnWidths: {0: FixedColumnWidth(<narrow, e.g. 56>)}` + `defaultColumnWidth: FlexColumnWidth()` (or IntrinsicColumnWidth for the label, Flex for lanes) and NO horizontal SingleChildScrollView — the Table takes the full available width, lanes share it equally, names inside compact SlotTile ellipsis-clip. Tighten cell padding to `EdgeInsets.all(2)` and the time-label font/size in portrait.
- When OFF: keep today's scrollable fixed-width Table (unchanged).
- SlotTile compact must clip long names with ellipsis (verify `Text(..., overflow: TextOverflow.ellipsis, maxLines: 1)` in slot_tile.dart's reserved compact rendering; add if missing — this is the "names clipped but whole day visible" requirement).

**Day pager view (day_pager_view.dart):** the day view's lane grid — apply the same fit-width behaviour: when ON, lanes fill width (no horizontal scroll), ellipsis names; when OFF, current behaviour. Find its lane row/Wrap/Row layout (from the earlier lane-header work it uses a fixed-width Row inside a horizontal scroller) and switch to Expanded lanes filling width when fitWidth is ON.

**Portrait spacing:** reduce outer paddings (WeekListView ListView padding, day-section Card padding) modestly when the screen is narrow, so more of the day fits — keep it readable, don't cram.

**Verify:** analyze + full tests green. The existing week_screen tests run at 800px width (fitWidth default false there, so they exercise the scrollable path unchanged — good, no test churn). ADD tests: (a) toggling the fit-width AppBar icon flips it and persists (SharedPreferences mock), (b) in fit-width mode the grid has no horizontal Scrollable / lanes are Flexible (assert no `Scrollable` inside the day card, or that a long name is clipped). Commit `feat: fit-width mode fills lanes to screen, no horizontal scroll`.

---

### Task 3: Move logout to profile screen

**Files:** modify `lib/features/schedule/home_shell.dart` (remove logout AppBar action), `lib/features/profile/profile_screen.dart` (add logout button).

- home_shell.dart: remove the `Icons.logout` IconButton from the AppBar actions (keep admin + profile icons). The profile icon stays as the entry point.
- profile_screen.dart: add an `Odhlásit se` action at the bottom (OutlinedButton or a ListTile with `Icons.logout`), calling the same confirm-then-signout flow. Reuse `confirmDialog(title: 'Odhlásit se', message: 'Opravdu se chceš odhlásit?', confirmLabel: 'Odhlásit se')` then `Api.signOut()`. (If home_shell currently has the confirm logic, move it.)

**Verify:** analyze + tests green. Update/de-dup the existing `home_shell_test.dart` logout test → move the assertion to a profile_screen test (logout button present in profile, confirm dialog appears). home_shell test now asserts NO logout icon in the AppBar. Commit `feat: move logout into the profile screen`.

---

### Task 4: Verify + review + PR + rebuild/install
- Full analyze/tests; web + apk release builds.
- Controller review (focus: fit-width layout correctness both views + portrait, splash has no rim, logout moved cleanly with confirm intact); fixes; push; PR; rebuild+install APK.
