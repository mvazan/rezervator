# Rezervátor — Phase 4 (Kiosk) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Kiosk mode: fullscreen week schedule with a status bar (clock, today info, „Rezervovat" button), adaptive letter-drill-down name picker, selected-player multi-booking with confirm dialogs, ✕/60s-idle deselect. Password login route `/kiosk-login`; the kiosk role account lands in `KioskShell` via the existing AuthGate branch.

**Architecture:** Pure-Dart `domain/name_index.dart` computes the picker levels (unit-tested like `schedule.dart`). `KioskShell` reuses `buildWeekSchedule` + the existing providers (realtime for free); its grid is display-only until a player is selected, then free cells book for THAT player via `create_reservation` (the RPC's kiosk branch authorizes booking for any approved player; per-player limits enforced server-side — the kiosk client cannot know another player's full active count, so `limit_reached` surfaces as a friendly snack).

**Tech Stack:** unchanged; no new dependencies.

## Global Constraints

- Repo `/Users/mvazan/Home/rezervator`, branch `phase-1-reservations`. Czech UI. Big touch targets (min 56 px tiles) — this runs on a tablet.
- Kiosk performs exactly ONE action type: create reservation. No cancel, no admin, no navigation elsewhere.
- Selected-player state resets: ✕ tap, 60 s of no pointer activity (also aborts a half-finished picker), and after idle the week view returns to the current week.
- `playersProvider` re-fetched (ref.invalidate) on every picker open and on idle reset.
- Domain pure Dart + TDD. `flutter analyze` "No issues found!", `flutter test` green each task. Commits end with `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.

---

### Task 1: `domain/name_index.dart` (TDD)

**Files:**
- Create: `lib/domain/name_index.dart`
- Test: `test/domain/name_index_test.dart`

**Interfaces:**
- Produces: `sealed class NameIndexNode`; `PrefixesNode(List<String> prefixes, List<PlayerName> exactMatches)`; `NamesNode(List<PlayerName> players)`; `NameIndexNode nameIndex({required List<PlayerName> players, required String prefix, required int capacity})`

Semantics: candidates = players whose case-folded (uppercased, trimmed) display name starts with the case-folded prefix; ≤ capacity → `NamesNode` (sorted by folded name); else `PrefixesNode` with the distinct next-character prefixes (folded, sorted) of candidates longer than the prefix, plus `exactMatches` = candidates whose whole folded name equals the prefix (they cannot extend — the UI lists them as name tiles above the prefix tiles). Diacritics are NOT folded (Š is its own tile — names render as entered).

- [ ] **Step 1: failing tests** — `test/domain/name_index_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:rezervator/domain/models.dart';
import 'package:rezervator/domain/name_index.dart';

void main() {
  PlayerName p(String name) => PlayerName(id: name, displayName: name, club: '');

  final players = [
    p('Novák Jan'), p('Novotná Eva'), p('Nguyen Bao'),
    p('Svoboda Petr'), p('Světlík Ota'), p('Šimek Aleš'),
    p('Dvořák Karel'), p('dráb pavel'),
  ];

  test('small list fits capacity → NamesNode sorted', () {
    final node = nameIndex(players: players, prefix: '', capacity: 10);
    expect(node, isA<NamesNode>());
    final names = (node as NamesNode).players.map((x) => x.displayName).toList();
    expect(names.first, 'dráb pavel'); // case-folded sort: DRÁB < DVOŘÁK
    expect(names, hasLength(8));
  });

  test('over capacity → first-letter prefixes, diacritics distinct', () {
    final node = nameIndex(players: players, prefix: '', capacity: 3);
    expect(node, isA<PrefixesNode>());
    final prefixes = (node as PrefixesNode).prefixes;
    expect(prefixes, ['D', 'N', 'S', 'Š']);
    expect(node.exactMatches, isEmpty);
  });

  test('drill down one level narrows candidates', () {
    final node = nameIndex(players: players, prefix: 'N', capacity: 2);
    expect(node, isA<PrefixesNode>());
    expect((node as PrefixesNode).prefixes, ['NG', 'NO']);
    final no = nameIndex(players: players, prefix: 'NO', capacity: 2);
    expect(no, isA<NamesNode>());
    expect((no as NamesNode).players.map((x) => x.displayName),
        ['Novotná Eva', 'Novák Jan']..sort());
  });

  test('prefix matching is case-insensitive', () {
    final node = nameIndex(players: players, prefix: 'd', capacity: 10);
    expect(node, isA<NamesNode>());
    expect((node as NamesNode).players.map((x) => x.displayName).toList(),
        ['dráb pavel', 'Dvořák Karel']);
  });

  test('name equal to the prefix lands in exactMatches', () {
    final many = [
      p('AB'), p('ABA'), p('ABB'), p('ABC'), p('ABD'), p('ABE'),
    ];
    final node = nameIndex(players: many, prefix: 'AB', capacity: 3);
    expect(node, isA<PrefixesNode>());
    final prefixNode = node as PrefixesNode;
    expect(prefixNode.exactMatches.single.displayName, 'AB');
    expect(prefixNode.prefixes, ['ABA', 'ABB', 'ABC', 'ABD', 'ABE']);
  });
}
```

Note the drill-down test's second assertion uses a sorted-list comparison — write it as `expect(..., containsAll([...]))` with a length check, or sort both sides; the executor picks the cleanest passing-but-strict form without weakening intent (both names, nothing else, sorted by folded name → `['NOVOTNÁ EVA' < 'NOVÁK JAN'?]` — beware: fold uppercases only, so 'NOVOTNÁ' vs 'NOVÁK': compareTo is code-unit based, 'Á' > 'O'… just assert `unorderedEquals(['Novák Jan', 'Novotná Eva'])`).

- [ ] **Step 2: RED**, then implement `lib/domain/name_index.dart`:

```dart
/// Adaptive letter drill-down for the kiosk name picker: show first letters,
/// then two-letter prefixes, … until the remaining names fit on screen.
/// Pure Dart, unit-tested.
library;

import 'models.dart';

String _fold(String value) => value.trim().toUpperCase();

sealed class NameIndexNode {
  const NameIndexNode();
}

/// Too many candidates — show these next-level prefixes as tiles, plus any
/// players whose whole (folded) name equals the current prefix (they cannot
/// extend by another character; the UI lists them as name tiles).
class PrefixesNode extends NameIndexNode {
  const PrefixesNode(this.prefixes, this.exactMatches);

  final List<String> prefixes;
  final List<PlayerName> exactMatches;
}

/// Few enough candidates — show the names themselves.
class NamesNode extends NameIndexNode {
  const NamesNode(this.players);

  final List<PlayerName> players;
}

NameIndexNode nameIndex({
  required List<PlayerName> players,
  required String prefix,
  required int capacity,
}) {
  final folded = _fold(prefix);
  final candidates = players
      .where((p) => _fold(p.displayName).startsWith(folded))
      .toList()
    ..sort((a, b) => _fold(a.displayName).compareTo(_fold(b.displayName)));
  if (candidates.length <= capacity) {
    return NamesNode(candidates);
  }
  final prefixes = <String>{};
  final exactMatches = <PlayerName>[];
  for (final candidate in candidates) {
    final name = _fold(candidate.displayName);
    if (name.length <= folded.length) {
      exactMatches.add(candidate);
    } else {
      prefixes.add(name.substring(0, folded.length + 1));
    }
  }
  final sorted = prefixes.toList()..sort();
  return PrefixesNode(sorted, exactMatches);
}
```

- [ ] **Step 3: GREEN** (`flutter test`), analyze clean. Commit `feat: adaptive name index for kiosk picker`.

---

### Task 2: Kiosk login route

**Files:**
- Create: `lib/features/kiosk/kiosk_login_screen.dart`
- Modify: `lib/main.dart` (add route)

**Spec:**
- Route `/kiosk-login` in the GoRouter: `AppConfig.hasSupabase ? const KioskLoginScreen() : const _NotConfigured()`.
- `KioskLoginScreen`: if a session already exists → immediately `context.go('/')` (post-frame). Otherwise a minimal centered form (max width 400): title `Kiosk — přihlášení`, `E-mail` + `Heslo` (obscureText) fields, button `Přihlásit` → `Supabase.instance.client.auth.signInWithPassword(email:, password:)` via `tryAction` (generic error copy is fine); on success `context.go('/')` (AuthGate routes by role). Czech copy: helper text `Přihlas kioskový účet — vytvoří ho správce podle SETUP.md.`.
- Add `Api.signInWithPassword(String email, String password)` to `lib/data/providers.dart` and call that (keep screens Supabase-free).

- [ ] Implement, analyze/test green, commit `feat: kiosk password login route`.

---

### Task 3: KioskShell (status bar, letter picker, selected-player booking, idle reset)

**Files:**
- Create: `lib/features/kiosk/kiosk_shell.dart`, `lib/features/kiosk/kiosk_week_view.dart`, `lib/features/kiosk/name_picker.dart`
- Modify: `lib/features/auth/auth_gate.dart` (replace `_KioskPlaceholder` with `KioskShell`)

**Spec:**

1. `KioskShell` (ConsumerStatefulWidget) — Scaffold WITHOUT AppBar; `Column`: status bar (top) + `Expanded(KioskWeekView)`. Wrap the whole body in a `Listener(onPointerDown: (_) => _touch(), behavior: HitTestBehavior.translucent, child: ...)` where `_touch()` restarts the 60 s idle `Timer`. On idle fire: `setState` → clear selected player, close any open picker (use `Navigator.popUntil(context, (r) => r.isFirst)` guarded by a `_pickerOpen` flag), reset week offset to 0, and `ref.invalidate(playersProvider)`. Dispose the timer.
2. Status bar: `Container` (surfaceContainerHighest, padding 12–16):
   - Clock `HH:mm` (bold, ~28 px) updated by a 20 s `Timer.periodic` — plus today's date `dayFull(today())`.
   - Middle `Expanded` info line (13–15 px, ellipsis, 2 lines max), priority: today's matches (`🏆 {opponent} {start}–{end}`, joined by ` · `) → else if today closed with reason: `Zavřeno — {reason}` → else if today not a training day: next training day (`Další trénink: {dayFull}` — compute from the week schedule + settings by scanning forward up to horizon days using the SAME data the grid uses) → else empty.
   - Trailing big `FilledButton.icon` (min height 56): icon person_add, label `Rezervovat` → opens the name picker (full-screen `showDialog` with `Dialog.fullscreen`). While a player IS selected the button area instead shows the banner: `Rezervuje: {displayName}` + a 40 px `✕` `IconButton` that clears the selection.
3. `NamePicker` (`Dialog.fullscreen`): header `Kdo si rezervuje?` + close button; body drives `nameIndex(players: <from playersProvider>, prefix: _prefix, capacity: 24)`:
   - `PrefixesNode` → `Wrap` of big square tiles (min 72×72, font 28) for each prefix (label = last character of the prefix — the header shows the accumulated prefix so far, e.g. `NO…`); exactMatches render as name tiles above.
   - `NamesNode` → `Wrap` of name tiles (min 200×64, font 20) → tap returns the `PlayerName` (Navigator.pop with result).
   - Back affordance inside the picker: if `_prefix` non-empty, a `←` tile first that strips the last character.
   - On open: `ref.invalidate(playersProvider)`. Loading/error → spinner / `Nepodařilo se načíst hráče.` + retry.
4. `KioskWeekView` — same data pipeline as `WeekScreen` (settingsProvider, timeBlocksProvider, dayOverridesProvider, matchesProvider, rentalsProvider, weekReservationsProvider(monday), playersProvider for names) and `buildWeekSchedule`; week chevron navigation like WeekScreen (kept in sync with the shell for idle reset — lift `weekOffset` state INTO `KioskShell` and pass down); rendering rules:
   - Cells display-only (names/Zápas/renter, same colors as WeekScreen) when NO player is selected. Bookable-if-selected free cells get a subtle outline so the schedule already reads as "these are free".
   - With a selected player: free && !inPast && !beyondHorizon && blocks-from-DB (`interactive` gate identical to WeekScreen — blocks from DB + reservations hasValue) → prominent `+` tile (primary, alpha 0.9); tap → `confirmDialog(title: 'Rezervovat termín?', message: '{displayName} · {dayFull} · {block.label} · Dráha {lane}', confirmLabel: 'Rezervovat')` → `Api.createReservation(playerId: selected.id, ...)` via `tryAction(success: 'Zarezervováno.', errorText: friendlyDbError)`. Selection PERSISTS after booking (multi-booking per spec).
   - Kiosk must never allow cancel: reserved cells have NO tap handler.
   - Touch targets: cell height ≥ 56 in kiosk view.
5. `auth_gate.dart`: `if (p.role == Role.kiosk) return const KioskShell();` (import swap, delete `_KioskPlaceholder`).

Binding Czech copy: `Rezervovat`, `Rezervuje: {name}`, `Kdo si rezervuje?`, `Zarezervováno.`, dialog per above, `Další trénink: …`, `Zavřeno — …`.

- [ ] Implement, analyze/test green (existing 40+? tests unaffected), commit `feat: kiosk shell with letter picker and multi-booking`.

---

### Task 4: Kiosk widget tests + SETUP.md §Fáze 4

**Files:**
- Test: `test/features/kiosk_test.dart`
- Modify: `SETUP.md`

**Spec:**
1. Widget tests (provider overrides like `test/features/week_screen_test.dart`; kiosk profile override `role: Role.kiosk`): (a) shell renders status bar with `Rezervovat` and NO logout/admin icons; (b) tapping `Rezervovat` opens picker with first-letter tiles from overridden players; (c) drilling to a name and tapping it shows the `Rezervuje:` banner; (d) with a selected player, tapping a `+` cell opens the booking confirm dialog containing the player's name; (e) reserved cells have no cancel affordance (tap → no dialog). Reuse/extract the provider-override harness helpers as sensible (a small shared `kioskApp(...)` builder inside the test file — do NOT modify the week_screen test file).
2. SETUP.md §Fáze 4 (style-matched, Czech): create kiosk auth user (Authentication → Users → Add user, email `kiosk@…` + strong password, auto-confirm), sign in on the tablet at `https://<user>.github.io/rezervator/#/kiosk-login` (note the `#` — Flutter web hash routing; verify against the app's actual URL strategy and document what works), register the profile as `Kiosk` (name shown nowhere public — the players view excludes kiosk), admin approves nothing (role change auto-approves): admin opens Správa → Hráči → kiosk account → `Nastavit jako kiosk`; tablet reloads → kiosk shell. Then Fully Kiosk Browser setup (install, Start URL, kiosk pinning, screen always on, auto-reload). Update `Co zatím nefunguje` (kiosk works now; zbývá reporty F5 + push F5).

- [ ] Implement, all tests green, analyze clean, commit `feat: kiosk widget tests and setup guide`.

---

### Task 5: Phase verification

- [ ] `flutter analyze` clean; `flutter test` all green; `flutter build web --release --base-href /rezervator/` OK.
- [ ] Deferred E2E (needs backend + tablet): kiosk books → e-mail with cancel link arrives → one click frees the slot live on the kiosk.
- [ ] Phase review (controller).
