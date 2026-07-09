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

### Task 1: Splash / AuthLogo — remove white ring

**Files:** modify `lib/core/widgets/auth_background.dart` (AuthLogo), `lib/features/auth/auth_gate.dart` (_Splash).

**Root cause:** AuthLogo wraps the circular logo image in a `scheme.surface`-filled circle (auth_background.dart:84-88) inside the gradient ring. `logo_circle.png` is a circular image with transparent corners; with `BoxFit.cover` at the same diameter it fills the ring, so the `scheme.surface` disc shows as a light rim between the gradient ring and the image (a "white border" in light mode). The `_Splash` shows the bare `ClipOval` image on a `Scaffold` — on a light theme the scaffold background reads as a border-ish disc too.

**Fix:**
- AuthLogo (auth_background.dart): remove the inner `scheme.surface` circle entirely — put the `ClipOval(Image.asset(logo_circle.png, fit: cover))` DIRECTLY inside the gradient-ring padding so the image meets the gradient with no light gap. Keep the 2px gradient ring. Net: gradient ring hugs the round logo, no white rim.
- `_Splash` (auth_gate.dart): the bare `ClipOval` logo is fine but to kill any perceived rim, reuse `AuthLogo()` (now ring-only, no white disc) OR keep the plain image but ensure no decoration/background is added. Simplest + consistent: replace the `_Splash` body's `ClipOval(Image...)` with `const AuthLogo(size: 96)` so splash and login match. Verify it renders centered on the scaffold with no extra container.

**Verify:** analyze + tests green (no test asserts splash internals; if any does, adapt). `flutter build apk --debug`. Commit `fix: drop white disc behind auth/splash logo`.

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
