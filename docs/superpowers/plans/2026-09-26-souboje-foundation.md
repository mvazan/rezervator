# Souboje (foundation) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add the „Souboje“ view to the match detail (a scoreboard, a remembered [Souboje | Zápis] switch, duel cards with live states and a Družstva card) as a foundation to iterate on.

**Architecture:** A pure domain layer (`lib/domain/duels.dart`) turns `MatchPlayerResult` rows into per-position `Duel`s: state, lane winners, the live-safe difference, and the point winner. Three stateless widgets (`MatchScoreboard`, `DuelCard`, `TeamTotalsCard`) render it. `MatchDetailScreen` assembles them with the existing `LegacyScoreSheet` behind a `SegmentedButton` whose choice lives in `local_prefs`.

**Tech Stack:** Flutter, Riverpod 3 (`NotifierProvider`, `StreamProvider`), shared_preferences, flutter_test.

Spec: `docs/superpowers/specs/2026-09-26-match-detail-souboje-design.md`.

## Global Constraints

- Czech UI strings exactly as written in this plan or the spec (e.g. „Souboje“, „Zápis“, „bod“, „čeká“, „rozhodly kuželky“, „Rozbalit vše“, „Sbalit vše“).
- Home is always on the left, away on the right.
- Every number in the scoreboard, duel cards and Družstva card uses `FontFeature.tabularFigures()`.
- Only these Manrope weights exist: w400, w500, w700, w800. Never w600 or w900.
- A duel/lane winner is never told by colour alone: weight, position (bar side, dot side) or the „bod“ pill says it too. Loser numbers keep full `onSurface` contrast (never grey).
- A lane counts as thrown only when its `total != null`.
- During a live match, a duel's difference counts only lanes BOTH players have thrown.
- The embedded `LegacyScoreSheet` and its full-screen page stay unchanged.
- All colours from `Theme.of(context).colorScheme` (no hard-coded colours in the new widgets).
- The view choice is stored with `SharedPreferences` key `match_detail_view`; default is Souboje.
- Follow the repo's existing patterns: widget tests with `ProviderScope` overrides (see `test/features/match_detail_screen_test.dart`), `nowProvider` for time, no fixed "today".
- Commit after each task; message ends with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`. Never push.
- Run `flutter analyze` (must print "No issues found!") and the task's tests before committing. Run tests with `TZ=Europe/Prague`.

## Out of scope for this plan (later iterations)

Landscape TV table, wide two-pane layout, the large-text stacked card, „Kopírovat výsledek“, the pinned mini score bar, tapping a points tile to scroll, the three embedded-Zápis improvements, the „Ty“ strip. Until the responsive layouts land, the Souboje column is centred at `maxWidth: 720`.

## Real match used by tests

The finished fixture match „TJ Sokol Rudná A 7 : 1 TJ Sokol Vršovice A“ (T100, 2 lanes, TEAMS_OF_6). Team: points 7 : 1, total 2555 : 2321, fulls 1809 : 1653, spares 746 : 668, errors 44 : 74, set points 8.5 : 3.5.

| pos | home (total, SB, TB, lanes as total/setPoints) | away (total, SB, TB, lanes) |
|---|---|---|
| 1 | Lucie Mičanová 407, 1, 1, [213/0 (156+57 e5), 194/1 (141+53 e4)] | Lukáš Pelánek 385, 1, 0, [216/1 (137+79 e5), 169/0 (126+43 e9)] |
| 2 | Pavel Strnad 435, 2, 1, [209/1 (147+62 e5), 226/1 (163+63 e5)] | Miroslav Kettner 378, 0, 0, [194/0 (131+63 e7), 184/0 (131+53 e10)] |
| 3 | Miluše Kohoutová 395, 1, 1, [195/0 (143+52 e3), 200/1 (149+51 e2)] | Miroslav Klabík 391, 1, 0, [200/1 (146+54 e5), 191/0 (131+60 e5)] |
| 4 | Ludmila Erbanová 437, 2, 1, [208/1 (145+63 e3), 229/1 (139+90 e0)] | Antonín Krejza 382, 0, 0, [207/0 (147+60 e6), 175/0 (132+43 e4)] |
| 5 | Jan Rokos 450, 2, 1, [209/1 (146+63 e4), 241/1 (163+78 e3)] | Pavel Brož 351, 0, 0, [181/0 (138+43 e9), 170/0 (135+35 e9)] |
| 6 | Jiří Spěváček 431, 0.5, 0, [215/0.5 (162+53 e4), 216/0 (155+61 e6)] | Zbyněk Vilímovský 434, 1.5, 1, [215/0.5 (152+63 e2), 219/1 (147+72 e3)] |

Per-player fulls/spares/errors (home): 297/110/9, 310/125/10, 292/103/5, 284/153/3, 309/141/7, 317/114/10. Away: 263/122/14, 262/116/17, 277/114/10, 279/103/10, 273/78/18, 299/135/5.

Task 1 creates `test/support/rudna_vrsovice.dart` with this data so every later task imports it.

---

### Task 1: Domain — duels

**Files:**
- Create: `lib/domain/duels.dart`
- Modify: `lib/domain/results.dart` (add public `teamBonusPoints`)
- Modify: `lib/features/clubhouse/widgets/legacy_score_sheet.dart` (use `teamBonusPoints`, delete private `_teamBonusPoints`)
- Create: `test/support/rudna_vrsovice.dart`
- Create: `test/domain/duels_test.dart`

**Interfaces:**
- Consumes: `MatchPlayerResult`, `PlayerLane`, `MatchResult` (`lib/domain/models.dart`), `MatchSide`, `numLabel` (`lib/domain/results.dart`).
- Produces (exact):
```dart
// lib/domain/results.dart
num? teamBonusPoints(num? sidePoints, List<MatchPlayerResult> players, String side);

// lib/domain/duels.dart
enum DuelState { waiting, playing, done }

class LanePair {
  const LanePair({required this.lane, this.home, this.away});
  final int lane;
  final PlayerLane? home;
  final PlayerLane? away;
  /// Both players threw this lane (both totals non-null).
  bool get played;
  /// Higher total when [played]; null on a tie or when not played.
  MatchSide? get winner;
  /// Played and equal totals.
  bool get tie;
}

class Duel {
  final int position;
  final MatchPlayerResult? home;
  final MatchPlayerResult? away;
  final List<LanePair> lanes;      // lane 1..n, the union of both sides' lane numbers
  final DuelState state;
  final int playedLanes;           // lanes both threw
  final int laneCount;             // lanes.length
  /// home − away. done: player totals; playing: sum over lanes both threw;
  /// waiting: null. Also null when a needed total is missing.
  final int? diff;
  /// done only: the side whose teamPoints is 1; null on a split (0.5 each) or unknown.
  final MatchSide? pointWinner;
  /// done only: teamPoints 0.5 each.
  final bool pointSplit;
  /// done only: equal set points and a pointWinner (pins decided it).
  final bool decidedByPins;
}

/// One Duel per position present in [players], sorted by position.
List<Duel> duelsOf(List<MatchPlayerResult> players);

/// max(50, the biggest |diff| among [duels]); 50 when none has a diff.
int diffScale(List<Duel> duels);

/// '◂ 22' (home leads), '3 ▸' (away leads), '=' (0), '' (null).
String leadLabel(int? diff);

/// Duel points per side (sum of teamPoints) and the pin points
/// (teamBonusPoints); null when [result] or a needed value is missing.
({num duelsHome, num duelsAway, num pinsHome, num pinsAway})?
    matchPointsBreakdown(MatchResult? result, List<MatchPlayerResult> players);

/// TalkBack text for one duel, e.g.
/// '1. souboj: Lucie Mičanová 407, Lukáš Pelánek 385, o 22, bod domácím'.
String duelSemantics(Duel duel);
```

Rules:
- **State:**
  - *waiting:* no lane with a non-null total on either side, and no non-null player total on either side.
  - *done:* both sides present, and either every LanePair is `played`, or neither side has lanes and both player totals are non-null.
  - *playing:* everything else.
- **diff:** in *done*, `home.total − away.total` (null if either total is null). In *playing*, the sum over played LanePairs of `home.total − away.total` (null if `playedLanes == 0`). In *waiting*, null.
- **pointWinner / pointSplit / decidedByPins:** only in *done*.
  - `pointWinner`: the side with `teamPoints == 1`.
  - `pointSplit`: both teamPoints are 0.5.
  - `decidedByPins`: `pointWinner != null` and `home.setPoints == away.setPoints`.
- **duelSemantics:** `'{pos}. souboj: {home name} {home total}, {away name} {away total}'`, then:
  - `', o {|diff|}'` when diff ≠ 0 and not null;
  - `', bod domácím'` / `', bod hostům'` / `', body napůl'` in *done*;
  - `', čeká'` in *waiting*;
  - `', hraje se'` in *playing*.

  Missing totals print `–` (use `numLabel`).

- [ ] **Step 1: Write the test fixture** `test/support/rudna_vrsovice.dart` exporting `final rudnaSlot` (a `PrioritySlot`: id 'rv', date `Day(2026, 9, 16)`, starts 17:30, ends 20:00, `type: PrioritySlot.fallbackMatchType`, home/away team names as above, `competition: 'Divize AS'`, `round: 1`, `venue: 'TJ Sokol Rudná'`), `final rudnaResult` (`MatchResult.fromJson` with status 'finished', match_type 'TEAMS_OF_6', discipline 'T100', all team values from the table, fetched_at '2026-09-17T08:00:00+00:00') and `final rudnaPlayers` (12 `MatchPlayerResult.fromJson` rows from the table: ids 'h1'..'h6', 'a1'..'a6', lanes with keys `lane, fulls, spares, errors, total, setPoints`). Check the `PrioritySlot` constructor's actual parameter names in `lib/domain/models.dart` before writing.

- [ ] **Step 2: Write failing tests** in `test/domain/duels_test.dart`:
```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:rezervator/domain/duels.dart';
import 'package:rezervator/domain/models.dart';
import 'package:rezervator/domain/results.dart';

import '../support/rudna_vrsovice.dart';

MatchPlayerResult player(String side, int pos, List<Map<String, Object?>> lanes,
        {int? total, num? sb, num? tb}) =>
    MatchPlayerResult.fromJson({
      'id': '$side$pos', 'match_id': 'x', 'side': side, 'position': pos,
      'player_name': '$side $pos', 'total': total, 'set_points': sb,
      'team_points': tb, 'lanes': lanes,
    });
Map<String, Object?> lane(int n, int? total, [num? sp]) =>
    {'lane': n, 'fulls': null, 'spares': null, 'errors': null, 'total': total, 'setPoints': sp};

void main() {
  group('the real Rudná A 7 : 1 Vršovice A', () {
    final duels = duelsOf(rudnaPlayers);

    test('six duels in position order, all done', () {
      expect(duels.map((d) => d.position), [1, 2, 3, 4, 5, 6]);
      expect(duels.every((d) => d.state == DuelState.done), isTrue);
    });
    test('differences from the player totals', () {
      expect(duels.map((d) => d.diff), [22, 57, 4, 55, 99, -3]);
    });
    test('point winners, and which duels pins decided', () {
      expect(duels.map((d) => d.pointWinner), [
        MatchSide.home, MatchSide.home, MatchSide.home,
        MatchSide.home, MatchSide.home, MatchSide.away,
      ]);
      expect(duels.map((d) => d.decidedByPins),
          [true, false, true, false, false, false]);
    });
    test('lane winners, and duel 6 has a tied first lane', () {
      expect(duels[0].lanes.map((l) => l.winner), [MatchSide.away, MatchSide.home]);
      expect(duels[5].lanes[0].tie, isTrue);
      expect(duels[5].lanes[0].winner, isNull);
      expect(duels[5].lanes[1].winner, MatchSide.away);
    });
    test('the shared bar scale is the biggest difference, at least 50', () {
      expect(diffScale(duels), 99);
      expect(diffScale(const []), 50);
    });
    test('5 duels + 2 for pins = 7, 1 duel + 0 = 1', () {
      final b = matchPointsBreakdown(rudnaResult, rudnaPlayers)!;
      expect([b.duelsHome, b.duelsAway, b.pinsHome, b.pinsAway], [5, 1, 2, 0]);
    });
    test('the TalkBack text of duel 1', () {
      expect(duelSemantics(duels[0]),
          '1. souboj: Lucie Mičanová 407, Lukáš Pelánek 385, o 22, bod domácím');
    });
  });

  test('leadLabel points at the leader', () {
    expect(leadLabel(22), '◂ 22');
    expect(leadLabel(-3), '3 ▸');
    expect(leadLabel(0), '=');
    expect(leadLabel(null), '');
  });

  group('live', () {
    test('a duel with no lane thrown is waiting, with no difference', () {
      final d = duelsOf([
        player('home', 1, [lane(1, null), lane(2, null)]),
        player('away', 1, [lane(1, null), lane(2, null)]),
      ]).single;
      expect(d.state, DuelState.waiting);
      expect(d.diff, isNull);
      expect(duelSemantics(d), endsWith(', čeká'));
    });
    test('the difference counts only lanes both players threw', () {
      final d = duelsOf([
        player('home', 1, [lane(1, 213), lane(2, 150)], total: 363),
        player('away', 1, [lane(1, 216), lane(2, null)], total: 216),
      ]).single;
      expect(d.state, DuelState.playing);
      expect(d.playedLanes, 1);
      expect(d.diff, -3);
      expect(d.pointWinner, isNull);
    });
    test('T120: four lanes, done when all four are thrown', () {
      final d = duelsOf([
        player('home', 1, [for (var i = 1; i <= 4; i++) lane(i, 150, 1)],
            total: 600, sb: 4, tb: 1),
        player('away', 1, [for (var i = 1; i <= 4; i++) lane(i, 140, 0)],
            total: 560, sb: 0, tb: 0),
      ]).single;
      expect(d.laneCount, 4);
      expect(d.state, DuelState.done);
      expect(d.diff, 40);
      expect(d.decidedByPins, isFalse);
    });
    test('a split point (0.5 each) has no winner', () {
      final d = duelsOf([
        player('home', 1, [lane(1, 200, 0.5)], total: 200, sb: 0.5, tb: 0.5),
        player('away', 1, [lane(1, 200, 0.5)], total: 200, sb: 0.5, tb: 0.5),
      ]).single;
      expect(d.pointWinner, isNull);
      expect(d.pointSplit, isTrue);
      expect(duelSemantics(d), endsWith(', body napůl'));
    });
  });

  test('teamBonusPoints: Body minus the duel points of that side', () {
    expect(teamBonusPoints(7, rudnaPlayers, 'home'), 2);
    expect(teamBonusPoints(1, rudnaPlayers, 'away'), 0);
    expect(teamBonusPoints(null, rudnaPlayers, 'home'), isNull);
  });
}
```

- [ ] **Step 3: Run** `TZ=Europe/Prague flutter test test/domain/duels_test.dart` — expect compile failure (missing `duels.dart`).

- [ ] **Step 4: Implement.**
  - Move `_teamBonusPoints` from `legacy_score_sheet.dart` (its body and doc comment unchanged) to `lib/domain/results.dart` as `teamBonusPoints`, and point the sheet's calls at it.
  - Write `lib/domain/duels.dart` to the interface and rules above: immutable classes, `const` constructors where possible, and a doc comment on each public member.

- [ ] **Step 5: Run** `TZ=Europe/Prague flutter test test/domain/duels_test.dart test/features/clubhouse/widgets/legacy_score_sheet_test.dart` — all pass; `flutter analyze` clean.

- [ ] **Step 6: Commit** `feat(souboje): the duels of a match, as pure domain functions`.

---

### Task 2: The remembered view choice

**Files:**
- Modify: `lib/data/local_prefs.dart`
- Create: `test/data/match_detail_view_pref_test.dart`

**Interfaces:**
- Produces:
```dart
enum MatchDetailView { souboje, zapis }
MatchDetailView parseMatchDetailView(String? name); // unknown/null → souboje
final matchDetailViewProvider =
    NotifierProvider<MatchDetailViewNotifier, MatchDetailView>(MatchDetailViewNotifier.new);
class MatchDetailViewNotifier extends Notifier<MatchDetailView> {
  Future<void> set(MatchDetailView view);
}
```
- Pattern: copy `ThemeChoiceNotifier` exactly (build returns the default and kicks off `_load`, best-effort `try/catch`, `ref.mounted` check), key `'match_detail_view'`.

- [ ] **Step 1: Failing test:**
```dart
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rezervator/data/local_prefs.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('parse: known names, anything else is Souboje', () {
    expect(parseMatchDetailView('zapis'), MatchDetailView.zapis);
    expect(parseMatchDetailView('souboje'), MatchDetailView.souboje);
    expect(parseMatchDetailView(null), MatchDetailView.souboje);
    expect(parseMatchDetailView('x'), MatchDetailView.souboje);
  });

  test('defaults to Souboje, loads the saved choice, saves a new one', () async {
    SharedPreferences.setMockInitialValues({'match_detail_view': 'zapis'});
    final container = ProviderContainer();
    addTearDown(container.dispose);
    expect(container.read(matchDetailViewProvider), MatchDetailView.souboje);
    await Future<void>.delayed(Duration.zero);
    expect(container.read(matchDetailViewProvider), MatchDetailView.zapis);

    await container.read(matchDetailViewProvider.notifier).set(MatchDetailView.souboje);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('match_detail_view'), 'souboje');
  });
}
```
- [ ] **Step 2:** run, expect failure. **Step 3:** implement. **Step 4:** run, pass; analyze clean.
- [ ] **Step 5: Commit** `feat(souboje): remember Souboje or Zápis on the device`.

---

### Task 3: `MatchScoreboard`

**Files:**
- Create: `lib/features/clubhouse/widgets/match_scoreboard.dart`
- Create: `test/features/clubhouse/widgets/match_scoreboard_test.dart`

**Interfaces:**
- Consumes: Task 1 (`duelsOf`, `Duel`, `DuelState`, `leadLabel`, `matchPointsBreakdown`), `lib/domain/results.dart` (`winningSide`, `formatLabel`, `freshnessLabel`, `isLive`, `numLabel`, `MatchSide`), `dayFull` from `lib/core/ui.dart`.
- Produces:
```dart
class MatchScoreboard extends StatelessWidget {
  const MatchScoreboard({super.key, required this.slot, required this.result,
      required this.players, required this.now, this.onVenueTap});
  final PrioritySlot slot;
  final MatchResult? result;
  final List<MatchPlayerResult> players;
  final DateTime now;
  /// Null = the venue is plain text (no known venue page).
  final VoidCallback? onVenueTap;
}
```

Layout (a `Card`, 16dp padding; the spec's „Scoreboard“ section is the reference):
1. Row: `'${dayFull(slot.date)} · ${slot.startsAt.display()}'` (bodySmall) | status chip on the right:
   - `MatchStatus.finished` → „Dokončeno“, `scheduled` → „Naplánováno“, `preparation` → „Příprava“, `forfeit` → „Kontumace“;
   - live (`isLive(slot, result, now)`) → „● Živě · ${freshnessLabel(result.fetchedAt, now)}“ on `errorContainer` / `onErrorContainer`;
   - no result → nothing.
2. Row: home team name (16dp, ≤ 2 lines, end-aligned) | score `'${numLabel(home)} : ${numLabel(away)}'` (44dp w800 digits, the ` : ` at 32dp w500; „–“ when no points) | away team name (16dp, ≤ 2 lines). Winner name w800, loser w400, no winner (a tie, or no points) both w500. When live, a line under the score: „průběžně“ (12dp).
3. Pins row (only when both totals are known): home total 22dp w700 | a pill with `leadLabel(homeTotal − awayTotal)` (15dp w800, `secondaryContainer` / `onSecondaryContainer`) | away total 22dp w700. When live, the pill has a dashed look (use a 1dp `outline` border and a transparent fill) and reads „Kuželky zatím ◂ 87“.
4. Points strip (only when players exist): for each duel a 40×40 tile (`outlineVariant` border, radius 8, the position number 15dp w700). Under it a 4×20dp bar:
   - aligned left for a home point, right for an away point, full width for a split;
   - no bar and a dashed tile border when the duel isn't done.

   After the tiles, a pill „+2 kuž.“ on the pins winner's side colour (only when `matchPointsBreakdown` gives 2 to a side; „+1 kuž.“ each on a split).
5. Explanation line (13dp, `onSurfaceVariant`, centred):
   - finished or forfeit, from `matchPointsBreakdown`: „Souboje 5 : 1 · Kuželky 2 : 0 · SB 8,5 : 3,5“ (omitted when the breakdown is null);
   - live, from the duels themselves, because the breakdown is null until every duel is done: „Souboje {h} : {a} · {n} rozehrané“. `{h}`/`{a}` sum the `teamPoints` of the *done* duels (`numLabel`), and `{n}` counts the duels in `DuelState.playing`.
6. Last row (bodySmall, `onSurfaceVariant`):
   - `formatLabel(result.matchType, result.discipline)`, then „ · “ and the venue name;
   - the venue is an `InkWell` with a chevron when `onVenueTap` is set.
7. Forfeit: under the score, „Zápas skončil kontumací – souboje se nehrály.“ (bodySmall).
8. No players: under the score, „Sestavy zatím nejsou k dispozici.“, and no strip.

Side colours for the „+2 kuž.“ pill: `colorScheme.primary` (home) / `colorScheme.tertiary` (away); `DuelCard` gets real team colours in Task 6.

- [ ] **Step 1: Failing widget tests** (wrap in `MaterialApp(home: Scaffold(body: SingleChildScrollView(child: MatchScoreboard(...))))`, `now = DateTime(2026, 9, 17, 10)`):
  - finished Rudná:
    - finds „7“, „1“, „2555“, „2321“, „◂ 234“, „Dokončeno“;
    - the explanation reads exactly „Souboje 5 : 1 · Kuželky 2 : 0 · SB 8,5 : 3,5“;
    - six tiles „1“..„6“ and „+2 kuž.“;
    - „6 hráčů · 100 HS · TJ Sokol Rudná“ text present;
  - winner weight: the RichText/Text of „TJ Sokol Rudná A“ has fontWeight w800, „TJ Sokol Vršovice A“ w400;
  - live (status 'in_progress', slot today at now − 1h, players with duel 1 done, duel 2 playing, duels 3–6 waiting):
    - chip text starts with „● Živě“;
    - „průběžně“ visible;
    - the explanation contains „1 rozehrané“;
  - forfeit: „Kontumace“ and „Zápas skončil kontumací – souboje se nehrály.“;
  - no players: „Sestavy zatím nejsou k dispozici.“ and no tile „1“;
  - numbers use tabular figures: the style of „2555“ has `FontFeature.tabularFigures()` in `fontFeatures`.
- [ ] **Step 2:** run, fail. **Step 3:** implement. **Step 4:** run, pass; analyze clean.
- [ ] **Step 5: Commit** `feat(souboje): a scoreboard that explains the score`.

---

### Task 4: `DuelCard`

**Files:**
- Create: `lib/features/clubhouse/widgets/duel_card.dart`
- Create: `test/features/clubhouse/widgets/duel_card_test.dart`

**Interfaces:**
- Consumes: Task 1.
- Produces:
```dart
class DuelCard extends StatelessWidget {
  const DuelCard({super.key, required this.duel, required this.scale,
      required this.expanded, required this.onTap,
      required this.homeColor, required this.awayColor});
  final Duel duel;
  final int scale;          // diffScale of the whole match
  final bool expanded;
  final VoidCallback onTap; // toggles expanded in the parent
  final Color homeColor;    // the side's colour (edge stripe, bar, dots)
  final Color awayColor;
}
```

Layout: the spec's „Souboje: a duel card“ section.
- **Waiting:** a slim card (min height 56): „home name“ (15dp) | „čeká“ (13dp `onSurfaceVariant`) | „away name“. Not expandable (`onTap` still called, harmless).
- **Collapsed (playing or done):**
  - Row 1: home name (15dp, ≤ 2 lines) | position in a 24dp circle (`surfaceContainerHighest`) | away name (≤ 2 lines, end-aligned).
  - Row 2: home total (32dp; w800 if the home side won the point, else w500; `onSurface`), then a „bod“ pill next to the winner's total (12dp w800, the winner side colour at 16% alpha, text `onSurface`); `leadLabel(diff)` centred (13dp w700); away total mirrored. A split point: a „½“ pill on both.
  - Playing: under the totals a line „po {playedLanes} ze {laneCount} drah“ (12dp `onSurfaceVariant`); no winner weight (both w500) and no pill.
  - Row 3: the difference bar, 6dp tall, full width, `surfaceContainerHighest` track, a 1dp `outline` tick in the centre.
    - The fill grows from the centre towards the leader's side, width `|diff| / scale × half width`, in the leader's side colour.
    - Playing: the fill is at 50% alpha (the foundation's "hatched").
  - Row 4: one entry per lane (T100 two side by side; T120 in a 2×2 grid):
    - `'Dr. {n}  {home} : {away}'` (16dp); the lane winner's number w800 with a 6dp dot in its side colour on its outer side;
    - a tie `'{h} = {a}'`;
    - an unthrown lane `'– : –'` inside a 1dp dashed-look `outlineVariant` border.
  - Row 5 (done only): „SB {h} : {a}“ plus „ · rozhodly kuželky“ when `decidedByPins` (12dp `onSurfaceVariant`), and on the right an expand chevron (`Icons.expand_more` / `expand_less`).
  - The winner's outer edge: a 4dp stripe in its side colour (the left edge for home, the right edge for away), done only.
- **Expanded (done or playing):** below row 5, a mirrored table (14dp, tabular):
  - per lane, for the home side then the away side: Plné, Dor., Ch., Celkem;
  - a Celkem row from the player's own fulls/spares/errors/total (Celkem w700);
  - then the sentence (done only): „SB {h} : {a} → rozhodly kuželky {homeTotal} : {awayTotal} → bod {surname}“ when decided by pins, else „SB {h} : {a} → bod {surname}“. `{surname}` is the last word of the winner's name; on a split, „→ body napůl“.
- **Whole card:** `InkWell(onTap: onTap)`, wrapped in `Semantics(label: duelSemantics(duel), button: true, excludeSemantics: true)`.
- All numbers use tabular figures.

- [ ] **Step 1: Failing tests** (Rudná duels from Task 1; `homeColor: Colors.teal`, `awayColor: Colors.purple` in tests only):
  - duel 1, collapsed:
    - „407“ w800 and „385“ w500;
    - one „bod“ pill;
    - „◂ 22“;
    - lanes „Dr. 1“ and „Dr. 2“ present;
    - „SB 1 : 1 · rozhodly kuželky“;
    - the Plné value „156“ is absent.
  - duel 1, expanded: „156“, „57“, „297“ present; the sentence „SB 1 : 1 → rozhodly kuželky 407 : 385 → bod Mičanová“.
  - duel 6: „3 ▸“; „434“ is w800; lane 1 shows „215 = 215“.
  - tapping calls `onTap` once.
  - semantics label equals `duelSemantics(duel)`.
  - live (the playing duel from Task 1's test): „po 1 ze 2 drah“, „– : –“ present, no „bod“, the totals both w500.
  - waiting: „čeká“ present and the height < 80.
  - T120 done duel: four „Dr. n“ labels laid out in two rows (Dr. 3 below Dr. 1).
  - at 360dp wide and text scale 1.0 nothing overflows (`tester.takeException()` is null).
- [ ] **Step 2:** run, fail. **Step 3:** implement. **Step 4:** run, pass; analyze clean.
- [ ] **Step 5: Commit** `feat(souboje): a duel card, collapsed, expanded and live`.

---

### Task 5: `TeamTotalsCard` („Družstva“)

**Files:**
- Create: `lib/features/clubhouse/widgets/team_totals_card.dart`
- Create: `test/features/clubhouse/widgets/team_totals_card_test.dart`

**Interfaces:**
- Produces: `class TeamTotalsCard extends StatelessWidget { const TeamTotalsCard({super.key, required this.result}); final MatchResult result; }`. It renders nothing (`SizedBox.shrink`) when `homeTotal` or `awayTotal` is null.

Layout:
- A `Card` with a title „Družstva“ (titleSmall), then five mirrored rows, 44dp tall, values 18dp tabular. The leader's value is w800 and the other w500.
- The middle label is 13dp `onSurfaceVariant`:
  - „Kuželky ◂ 234“
  - „Plné ◂ 156“
  - „Dorážka ◂ 78“
  - „Chyby (méně = lépe)“: the side with FEWER errors is the leader (w800), and no arrow is printed
  - „SB“: set points via `numLabel`
- Arrows use `leadLabel`, with the sign flipped for errors — not printed there.

- [ ] **Step 1: Failing tests** on `rudnaResult`:
  - texts „2555“, „2321“, „Kuželky ◂ 234“, „Plné ◂ 156“, „Dorážka ◂ 78“, „Chyby (méně = lépe)“, „8,5“, „3,5“;
  - „44“ is w800 and „74“ w500;
  - a result with a null total renders no „Družstva“.
- [ ] **Step 2:** run, fail. **Step 3:** implement. **Step 4:** pass; analyze clean.
- [ ] **Step 5: Commit** `feat(souboje): the Družstva card`.

---

### Task 6: Assemble the match detail

**Files:**
- Modify: `lib/features/clubhouse/match_detail_screen.dart`
- Modify: `test/features/match_detail_screen_test.dart`
- Modify: `lib/features/profile/changelog_data.dart` (one line in the unversioned batch at the top)

**Interfaces:**
- Consumes: Tasks 1–5, `matchDetailViewProvider`, `myTeamColorsProvider` (`lib/data/providers.dart`), `googleEventColorOf` (`lib/domain/palette.dart`), the existing `LegacyScoreSheet`.

Changes:
1. **Replace** `_headerCard` and the „Výsledky z webu: …“ / „Výsledky zatím nejsou.“ line with `MatchScoreboard(slot, result, players, now, onVenueTap)`. `onVenueTap` pushes `VenueDetailScreen(slug: venueMatch.slug)` when `venueMatch != null`.
   - Keep „Výsledky zatím nejsou.“ as a line under the scoreboard only when `result == null`.
   - Freshness when live is in the chip; when not live, add under the scoreboard a bodySmall line „Výsledky z webu: {freshnessLabel}“ only when `result != null && !live`.
2. **Keep** `_buttonsRow` as is.
3. **Switch:** add a row with `SegmentedButton<MatchDetailView>` (segments „Souboje“, „Zápis“) bound to `matchDetailViewProvider`. In Souboje, a `TextButton` on the right: „Rozbalit vše“ / „Sbalit vše“.
4. **Souboje:**
   - one `DuelCard` per `duelsOf(players)` (12dp side margin, 8dp gaps), `scale: diffScale(duels)`, then `TeamTotalsCard(result)` when `result != null`;
   - `expanded` state is a `Set<int>` of positions in the State; tapping toggles; „Rozbalit vše“ adds all positions, „Sbalit vše“ clears;
   - `players.isEmpty` → the existing „Sestavy zatím nejsou k dispozici.“ text instead of the cards.
5. **Zápis:** exactly today's `LegacyScoreSheet(slot, result, players)` plus the existing empty-lineup text.
6. **Side colours:**
   - `teamColors = ref.watch(myTeamColorsProvider).value ?? {}`;
   - `homeColor = googleEventColorOf(teamColors[slot.homeTeam]) ?? scheme.primary`;
   - `awayColor = googleEventColorOf(teamColors[slot.awayTeam]) ?? scheme.tertiary`.
7. **Layout:**
   - the `ListView` children sit in `Center(child: ConstrainedBox(maxWidth: 720))`;
   - when live, wrap the `ListView` in `RefreshIndicator(onRefresh: () async { await _refreshQuietly(); })`, with `AlwaysScrollableScrollPhysics`.
8. **Changelog:** add to the top (unversioned) batch the line „Detail zápasu: nový pohled Souboje — velká čísla, kdo vyhrál který souboj a dráhu. Původní zápis je o ťuk vedle.“ Then check `test/changelog_test.dart` and `test/features/store_notes_test.dart` still pass; if the batch exceeds 500 characters, add a `store:` summary as that file's other batches do.

- [ ] **Step 1: Update and add tests** in `test/features/match_detail_screen_test.dart`:
  - add overrides `myTeamColorsProvider.overrideWith((ref) => Stream.value(const {}))` and `matchDetailViewProvider.overrideWith(() => _FixedView(view))` (a tiny `MatchDetailViewNotifier` subclass whose `build` returns the given view and whose `set` updates `state` only) to `app()`;
  - fix the existing tests that asserted the old header card: score text, pins, SB, format, venue, the freshness line. Keep their intent and update the finders to the scoreboard's texts;
  - new: Souboje is the default. With the Rudná data, six `DuelCard`s and a `TeamTotalsCard` are found, and no `LegacyScoreSheet`;
  - new: tapping „Zápis“ shows `LegacyScoreSheet` and hides the cards; the notifier's state becomes `MatchDetailView.zapis`;
  - new: tapping duel 1 expands it („156“ appears); „Rozbalit vše“ expands all (six „Celkem“ rows); „Sbalit vše“ collapses;
  - new: a live match wraps the list in a `RefreshIndicator`; a drag-to-refresh calls `refresh` once more;
  - new: no players → „Sestavy zatím nejsou k dispozici.“ in both views.
- [ ] **Step 2:** run, fail. **Step 3:** implement. **Step 4:** run `TZ=Europe/Prague flutter test` (the whole suite) — all pass; analyze clean.
- [ ] **Step 5: Commit** `feat(souboje): the match detail opens on Souboje, Zápis one tap away`.
