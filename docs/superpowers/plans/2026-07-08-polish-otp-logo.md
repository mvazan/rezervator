# Rezervátor — OTP fallback, logo, kiosk scroll+gridlines, web spacing (plan)

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:subagent-driven-development. Checkbox steps.

**Goal:** Five user-requested polish items on branch `polish-otp-logo` (from kiosk-board):
1. Numeric login-code fallback (OTP) for mail apps that drop the magic-link `?code=` (Seznam) — mirroring terminator's proven fix, INCLUDING the RLS/session-refresh fix so streams reload after OTP login.
2. Czech custom email template (link + `{{ .Token }}` code).
3. App logo everywhere (login screens + app/web icons) from `assets/images/logo.png`.
4. Kiosk idle: smooth-scroll to today's column AND to the current-time row; add subtle horizontal time-slot gridlines (no vertical lane dividers).
5. Web week view: fix cramped table spacing.

**Branch:** `polish-otp-logo`. Logo files already in `assets/images/` (logo.png master 1024², logo_circle.png circular, logo_512.png). Czech UI. Spec-less (this doc is the spec).

## Global Constraints
- `flutter analyze` "No issues found!" + full `flutter test` green each task. Commits end `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.
- Do NOT modify domain/RPC/reservation logic. UI + auth-plumbing + assets only.
- Reference implementation for Task 1: `/Users/mvazan/Home/terminator/lib/data/providers.dart` (Api.verifyEmailOtp lines 204-212, `_userIdProvider` lines 32-35) and `login_screen.dart` (_enterCode 58-72, "Zadat kód z e-mailu" button). Mirror, adapt to rezervator's names.

---

### Task 1: OTP verify + login-code UI + RLS stream refresh

**Files:** modify `lib/data/providers.dart`, `lib/features/auth/login_screen.dart`, `lib/core/ui.dart` (friendlyDbError: OTP errors → Czech).

**A — RLS/session refresh (do this FIRST, it's the load-bearing fix):**
In providers.dart add:
```dart
/// Re-emits on every auth change so RLS-dependent streams reopen under the
/// new JWT. Supabase `.stream()` only refetches on socket reconnect, not on
/// a plain token update — without this, a stream first opened while
/// session-less (the OTP-login path) stays stuck on its empty anon snapshot.
final _authUidProvider = Provider<String?>((ref) {
  ref.watch(authStateProvider);
  return currentUserId;
});
```
Then make EVERY RLS-gated stream provider `ref.watch(_authUidProvider)` at its top and return `Stream.value(const [])` (or the empty-equivalent) when it's null. Audit these in providers.dart: `myProfileProvider`, `profilesProvider`, `settingsProvider`, `timeBlocksProvider`, `dayOverridesProvider`, `matchesProvider`, `rentalsProvider`, `weekReservationsProvider` (family), `myActiveReservationsProvider`, and `playersProvider` (FutureProvider — also gate: return `[]` when uid null, and it's already refetched on demand). `myProfileProvider` already keys on auth; ensure it too returns null cleanly when uid null. Keep behavior identical when signed in.

**B — verifyEmailOtp** in `class Api`:
```dart
/// Fallback for mail apps that drop the code from the magic link
/// (e.g. Seznam's in-app browser): the e-mail also carries a numeric code.
static Future<void> verifyEmailOtp(String email, String code) =>
    _db.auth.verifyOTP(type: OtpType.email, email: email, token: code.trim());
```
(import `OtpType` — it's from supabase_flutter, already imported via the package.)

**C — login_screen UI:** in the `_sent` branch add below the resend button a `TextButton('Zadat kód z e-mailu')` → `_enterCode()`:
```dart
Future<void> _enterCode() async {
  final email = _email.text.trim();
  final code = await promptText(context,
      title: 'Kód z e-mailu',
      hint: 'např. 123456',
      confirmLabel: 'Přihlásit',
      keyboardType: TextInputType.number);
  if (code == null || code.trim().isEmpty || !mounted) return;
  await tryAction(context, () => Api.verifyEmailOtp(email, code));
  // AuthGate re-routes via the (now-refreshing) auth stream on success.
}
```
Add explanatory line in the sent-state text: that if the link doesn't open the app (some mail apps), they can type the 6-digit code from the e-mail.

**Verify:** analyze + all tests green (add a provider unit test if feasible: `_authUidProvider`-gated stream returns [] when signed out — otherwise a widget test that the "Zadat kód z e-mailu" button appears in sent state). Commit `feat: email otp login fallback and rls stream refresh on auth change`.

---

### Task 2: Czech email template (docs + config)

**Files:** create `supabase/templates/magic_link.html`, `supabase/templates/README.md`; modify `supabase/config.toml` (add `[auth.email.template.magic_link]` pointing at the file + subject), `SETUP.md` (§3 note the template + `{{ .Token }}` requirement, and how to apply via `supabase config push`).

**Template** (`magic_link.html`) — Czech, MUST contain both the link and the code:
```html
<h2>Přihlášení do Rezervátoru</h2>
<p>Klikni na tlačítko a přihlásíš se:</p>
<p><a href="{{ .ConfirmationURL }}">Přihlásit se</a></p>
<p>Pokud odkaz neotevře aplikaci (stává se v některých e-mailových aplikacích),
zadej v přihlašovací obrazovce tento kód:</p>
<p style="font-size:24px;font-weight:bold;letter-spacing:3px">{{ .Token }}</p>
<p style="color:#888;font-size:13px">Kód i odkaz platí hodinu. Pokud ses nepřihlašoval(a) ty, tento e-mail ignoruj.</p>
```
config.toml:
```toml
[auth.email.template.magic_link]
subject = "Přihlášení do Rezervátoru"
content_path = "./supabase/templates/magic_link.html"
```
(Verify against the existing config.toml structure — it already has `[auth.email.smtp]`; keep `pass = env(SMTP_PASS)`.) SETUP.md: document that `supabase config push` applies it, and the Management-API caveat (SMTP first, template second) is avoided by config push.

**Verify:** analyze + tests unaffected (no Dart change). This task's real verification is the controller applying it via `supabase config push` at the end (Task 6). Commit `feat: czech magic-link email template with code fallback`.

---

### Task 3: Logo everywhere + app icons

**Files:** modify `pubspec.yaml` (assets block + flutter_launcher_icons dev dep + config), `lib/core/widgets/auth_background.dart` (AuthLogo), `lib/features/auth/auth_gate.dart` (splash 🎳), `lib/main.dart` (NotConfigured 🎳 optional); run icon generation.

1. pubspec `flutter:` — add:
```yaml
  assets:
    - assets/images/logo.png
    - assets/images/logo_circle.png
```
2. `AuthLogo` (auth_background.dart:64-94): replace the inner `Text('🎳')` with `ClipOval(child: Image.asset('assets/images/logo_circle.png', width: size, height: size, fit: BoxFit.cover))` — keep the gradient ring (ringDiameter = size+24, 2px pad). Ensure the ring still shows around the circular image.
3. auth_gate.dart splash (line ~53): replace `Text('🎳', fontSize: 64)` with `ClipOval(child: Image.asset('assets/images/logo_circle.png', width: 96, height: 96))`.
4. App icons via `flutter_launcher_icons`: add dev dependency (`flutter pub add --dev flutter_launcher_icons`), config in pubspec:
```yaml
flutter_launcher_icons:
  image_path: "assets/images/logo.png"
  android: true
  web:
    generate: true
    image_path: "assets/images/logo.png"
  # ios: false  (iOS not built)
```
Run `dart run flutter_launcher_icons`. This regenerates android mipmaps + web/icons + favicon + manifest icon refs. Verify web/manifest.json still has valid icon entries and `web/index.html` favicon works. Set manifest `theme_color`/`background_color` to the app's indigo if the tool doesn't (theme_color `#6366F1`).

**Verify:** analyze; tests green; `flutter build web --release --base-href /rezervator/` (icons/assets resolve); `flutter build apk --debug` (mipmaps valid). Commit `feat: app logo on auth screens and generated app icons`.

---

### Task 4: Kiosk idle scroll-to-now + horizontal gridlines

**Files:** modify `lib/features/kiosk/kiosk_board_view.dart`, `lib/features/kiosk/kiosk_shell.dart`.

1. **Scroll to current-time row**: give the outer vertical `SingleChildScrollView` (board_view ~line 336) a `ScrollController _vScroll`. Extend `resetToToday()` → also compute the vertical offset of the rail block covering `now` (HourMinute now from injected clock/DateTime at call site — the shell passes `today`/now; use the block whose `[startsAt,endsAt)` contains now, else nearest upcoming, else 0) and `animateTo(offset, 300ms, Curves.easeInOut)`; horizontal jump to today becomes `animateTo(0, …)` too (smooth per user's "smooth scroll"). Offset = `_headerHeight + indexOfBlock * rowGroupHeight` clamped to scroll extent. Guard `hasClients`.
   - The shell's `_onIdle` already calls `resetToToday()` — no shell change beyond passing `now` if not already available (it has the clock timer; thread current HourMinute into the board or read once in resetToToday).
2. **Horizontal time-slot gridlines**: add a subtle bottom divider between block row-groups — in `_DayColumn` each block cell gets `border: Border(bottom: BorderSide(color: scheme.outlineVariant.withValues(alpha:0.25)))` (skip after the last), and the `_Rail` mirrors the same lines so labels align. NO vertical dividers between lanes (leave `_rowShell` untouched). Keep it faint on the dark kiosk theme.

**Verify:** analyze; kiosk tests green (adapt any assertion that counted exact widget structure; don't weaken dark/7-column/booking asserts). Add a test: after building, `resetToToday` doesn't throw and a gridline (Divider/Border) is present. Commit `feat: kiosk idle scrolls to today and current time, time-slot gridlines`.

---

### Task 5: Web week view spacing

**Files:** modify `lib/features/schedule/week_screen.dart` (`_grid` ~496-551, `WeekListView` ~404), possibly `lib/features/schedule/widgets/slot_tile.dart`.

Fix the cramped `Table`: drop `TableBorder.all` in favor of breathing room — either (a) add `Padding(EdgeInsets.all(4))` around each `slotTileFor(...)` cell and each header/label cell and replace the hard table border with none or a very light horizontal-only divider, and widen columns (`FixedColumnWidth(84)`, label col 92), OR (b) switch the grid to a `Column` of `Row`s with `SizedBox`/`Spacer` gaps. Pick (a) (minimal, keeps horizontal scroll). Also add spacing between day cards: in `WeekListView` give the `ListView` `SizedBox(height: 4)` isn't needed since Cards have margin — verify Card margin exists (theme CardTheme margin `symmetric(vertical:6)`); if day sections still touch, add gap. Ensure compact `SlotTile` inside has consistent internal padding (slot_tile `_shell`). Goal: tiles have visible gaps, grid reads cleanly on web at wide widths.

**Verify:** analyze; tests green (week_screen_test finders must still work — they find texts/`Icons.add`, not padding; if a test measures exact geometry, adapt). `flutter build web`. Commit `fix: roomier week-view grid spacing`.

---

### Task 6: Verify + apply + review + PR
- Full analyze/tests; web + apk builds.
- Controller: apply email template via `supabase config push` (SMTP_PASS env); phase review; fixes; push; PR (note migration 0002 still needs applying with merge — this branch stacks on kiosk-board).
