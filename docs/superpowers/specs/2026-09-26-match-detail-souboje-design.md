# Match detail: „Souboje“ next to „Zápis“

Chosen by the user on 2026-09-26 (variant A of three, mockups shown in chat). The app speaks Czech; the user writes Slovak. The legacy „Zápis“ stays as it is (its full-screen page was improved the same day: bigger numbers, whole display, system back).

## Why

The match detail shows one view of a match: „Zápis“, a 1:1 replica of the federation's paper sheet. It is wide and dense. On a phone held upright it is drawn at under half size, so its numbers are hard to read, and the answers a player wants first need reading a grid:
- who won the match, and how the score came about;
- who won each duel, by how much;
- how each lane went.

„Souboje“ tells the match as its 6 (or 4) duels, with numbers sized for a phone, and adapts to landscape, tablet and web. „Zápis“ stays one tap away.

## Scope

In this release:
- a shared scoreboard at the top of the match detail (both views);
- a switch [Souboje | Zápis], remembered per device;
- the Souboje view: one card per duel (collapsed and expanded), a Družstva card, live states;
- responsive layouts: phone portrait, phone landscape (a TV-style table), tablet and web (two panes);
- a stacked layout for large text;
- „Kopírovat výsledek“;
- three improvements to the embedded Zápis (a visible horizontal scroll, a white „paper“ in dark mode, one TalkBack label per pairing);
- a pure domain layer (`lib/domain/duels.dart`) with tests.

Deferred (not in this release):
- the „Ty“ strip (needs a reliable player ↔ profile match);
- „Ukázat v zápisu“ with a highlighted pairing, and „Otevřít v Soubojích“ from the Zápis;
- a flash on numbers that changed after a refresh;
- the „Rozhodnuto“ chip (a match already decided);
- a progress chart, a shareable image;
- substitutes (`replacedPlayerName` is not in the database yet).

## Screen structure

Top to bottom, in a `CustomScrollView`:
1. AppBar as today („Divize AS · 1. kolo“, ⟳ when live) plus a ⋮ menu with „Kopírovat výsledek“.
2. **Scoreboard** (shared by both views).
3. Buttons „Záznam“ / „Sledovat živě“ and „Na webu ČKA“, as today.
4. **Switch** `SegmentedButton` [Souboje | Zápis]; in Souboje also „Rozbalit vše“ / „Sbalit vše“ on the right.
5. The chosen view.

When the scoreboard scrolls away, a pinned 48dp bar keeps „Rudná A **7 : 1** Vršovice A“ in view.

Every number in the scoreboard and the Souboje view uses `FontFeature.tabularFigures()`, so digits don't jump when live values change. Weights: only the bundled Manrope cuts, 400/500/700/800.

## Scoreboard

About 220dp tall on a phone. Replaces today's header card and the „Výsledky z webu: …“ line.
- **First line:** „St 16. 9. · 17:30“ (13dp) on the left. A status chip on the right: „Dokončeno“, „Naplánováno“, „Příprava“, „Kontumace“, or „● Živě · před 2 min“ (the freshness moves into the chip when live).
- **Teams and score:** team names 16dp, up to 2 lines; winner w800, loser w400. Score „7 : 1“ at 44dp w800 (the colon 32dp w500).
- **Pins:** „2555“ and „2321“ at 22dp w700, and between them a pill with the lead „◂ 234“ (15dp w800). The arrow points at the leader. A tie reads „=“.
- **Match points strip:** one 40×40dp tile per position (1–6), then a pill „+2 kuž.“ for the higher pin total.
  - Under each tile a 4dp bar sits on the winner's side: left = home, right = away, full width = a tie, dashed = not decided yet. The winner is told by position, not by colour alone.
  - Tapping a tile scrolls the Souboje list to that duel.
- **Explanation line** (13dp): „Souboje 5 : 1 · Kuželky 2 : 0 · SB 8,5 : 3,5“.
- **Last line:** „6 hráčů · 100 HS · Kuželna Rudná ›“ (the venue link as today).

States:
- **Before the lineup is out:** dashed tiles and „Sestavy zatím nejsou k dispozici.“
- **Live:** the score reads „průběžně 3 : 1“, the explanation „Souboje 3 : 1 · 2 rozehrané“, and the pin pill is dashed with „Kuželky zatím ◂ 87“.
- **Forfeit:** the chip „Kontumace“, the score, and „Zápas skončil kontumací – souboje se nehrály.“

## Switch

- `SegmentedButton` [Souboje | Zápis], 40dp.
- The choice is stored on the device in `local_prefs` under `match_detail_view`. Souboje is the default.
- The scoreboard is shared, so the score does not jump when switching.

## Souboje: a duel card (phone portrait, 360–412dp)

Cards 12dp from the edges, 8dp apart. Home always on the left, as in the Zápis and on the federation site.

Collapsed card, about 150dp:
```
Lucie Mičanová        (1)       Lukáš Pelánek      names 15dp, up to 2 lines
407 [bod]             ◂ 22               385       totals 32dp
▓▓▓▓▓▓▓▓░░░░░┃░░░░░░░░░░░░░░                       6dp difference bar
Dr. 1  213 : 216•        Dr. 2  •194 : 169         lanes 16dp
SB 1 : 1 · rozhodly kuželky                   ⌄    12dp
```
- **Totals:** 32dp. The duel winner's total is w800 and the loser's w500. Both use `onSurface`, never grey.
- **Point:** a pill „bod“ (12dp w800) next to the winner's total. A half point each on a tie reads „½“ on both.
- **Lead:** „◂ 22“ (the arrow points at the leader) between the totals.
- **Difference bar:** it grows from the centre towards the leader's side. The scale is shared by all duels of the match: `max(50, the biggest |difference|)`. In the sample, duel 5 (+99) fills its half and duel 3 (+4) is a sliver.
- **Lanes:** „Dr. 1 213 : 216“ per lane; the lane winner is w800 with a 6dp dot on its side. A tied lane reads „215 = 215“. T120 (4 lanes) puts the lanes in a 2×2 grid.
- **Verdict line:** „SB 1 : 1 · rozhodly kuželky“ when set points tie and pins decide, else „SB 2 : 0“.
- **Winner edge:** a 4dp stripe on the winner's outer edge, in the side's colour.
  - The side's colour is the team's own colour where the viewer has one (`myTeamColorsProvider`, the same map Výsledky and the calendar use).
  - Otherwise it is `primary` for home and `tertiary` for away.
  - Marks carry a 1.5dp outline, so pale colours (Banánová) still show.
- **Tapping** anywhere on the card expands or collapses it. Semantics: one label per card, e.g. „1. souboj: Lucie Mičanová 407, Lukáš Pelánek 385, o 22, bod domácím“.

Expanded card, about 110dp more:
- A mirrored table per lane: Plné · Dor. · Ch. · Celkem on each side (14dp; Celkem w700), and a Celkem row.
- A sentence: „SB 1 : 1 → rozhodly kuželky 407 : 385 → bod Mičanová“.

Expansion is keyed by position, so it survives a live refresh.

## Souboje: the Družstva card

Below the duels. Mirrored rows, 44dp tall, values 18dp, the leader's value w800:
- Kuželky 2555 ◂ 234 2321
- Plné 1809 ◂ 156 1653
- Dorážka 746 ◂ 78 668
- Chyby 44 ◂ 30 74, with „(méně = lépe)“: the side with fewer errors leads
- SB 8,5 : 3,5

## Live match

A duel's state comes from its lanes. A lane counts as thrown only when its `total` is not null.
- **čeká** (no lane thrown by either player): a slim 56dp card with the names and „čeká“.
- **hraje se** (some lanes thrown):
  - totals stay big, labelled „po 1 ze 2 drah“;
  - the difference and its bar count only lanes **both** players have thrown („po 1. dráze ◂ 15“), so a late update from one side never shows a false +200;
  - the bar is hatched;
  - unthrown lanes read „– : –“ in a dashed frame;
  - no winner styling and no „bod“ yet.
- **hotovo** (every lane of both players thrown): as a finished match.

Refreshing:
- pull-to-refresh on the whole screen while live (calls the existing `Api.refreshMatch`);
- the ⟳ in the AppBar stays;
- the scroll position and the expanded cards survive a refresh.

## Responsive layouts

`LayoutBuilder` on the body decides, not `MediaQuery`, so split screen and web windows work too.
- **Phone portrait (< 600dp wide):** as above.
- **Phone landscape (≥ 600dp wide and < 480dp tall):**
  - The AppBar collapses into a 40dp top bar: „← Rudná A 7 : 1 Vršovice A · 2555 : 2321 · [Souboje | Zápis]“.
  - Souboje becomes one full-width TV table, one 40dp row per duel:
    `│1│Lucie Mičanová│213│194│ 407 │◂ 22│ 385 │216│169│Lukáš Pelánek│`
  - Columns: position 24 | name (flex, full name 15dp) | lanes 2 × 44 (16dp; the lane winner w800 with a 3dp underline) | total 56 (24dp) | centre 72 („◂ 22“ over a 4dp bar) | the away side mirrored.
  - A 20dp header plus 6 rows fit on one screen at text scale up to 1.15; beyond that the table scrolls.
  - T120 has 4 × 40dp lanes and shortens names to „L. Mičanová“.
  - Tapping a row opens a bottom sheet with that duel's expanded card. The Družstva card follows the table.
- **600–839dp:** one column, at most 720dp wide, cards expanded.
- **≥ 840dp (`hubWideBreakpoint`):**
  - a sticky 360dp left pane holds the scoreboard (score 56dp, pins 28dp) and the Družstva card;
  - on the right, the cards are always expanded;
  - from 1200dp, two columns of cards in the order 1|2, 3|4, 5|6 (the pairs that play at the same time).
- **Large text (text scale > 1.3) or narrower than 340dp:** a card becomes two stacked „tennis“ rows:
  - „1 Lucie Mičanová ●○ 407 bod“
  - „   Lukáš Pelánek ○● 385“

  Numbers sit in a `FittedBox` and never go below 28dp.

## Kopírovat výsledek

In the ⋮ menu. Copies plain text with `Clipboard.setData`; no new dependency:
```
TJ Sokol Rudná A 7 : 1 TJ Sokol Vršovice A (2555 : 2321)
1. Mičanová 407 : 385 Pelánek ✓
2. Strnad 435 : 378 Kettner ✓
…
6. Spěváček 431 : 434 Vilímovský ✓ hosté
```
Then a snack „Výsledek zkopírován.“

## The embedded Zápis: three improvements

Its look stays 1:1:
1. **Horizontal scroll that shows it continues:** a permanent `Scrollbar` under the sheet, and a 16dp fade on the cut edge.
2. **Dark mode:** the sheet sits on a white „paper“ (radius 8, 1dp outline, 8dp padding), so it no longer reads as a bright stain.
3. **TalkBack:** each pairing block is one `MergeSemantics` label, the same text as the duel card's (built by the same domain helper).

## Domain (`lib/domain/duels.dart`)

Pure functions, unit-tested, used by the scoreboard, the cards, the TV table, the copy text and the Zápis semantics:
- `duelsOf(players) → List<Duel>` — per position: home, away, state (waiting / playing / done), lanes paired with their winner, the difference over lanes both have thrown, the set points, the point winner and „decided by pins“.
- `matchPointsBreakdown(result, duels)` — duel points and the +2 for pins, for „Souboje 5 : 1 · Kuželky 2 : 0“.
- `diffScale(duels)` — `max(50, the biggest |difference|)`.
- `leadLabel(diff)` — „◂ 22“, „3 ▸“, „=“.
- `duelSemantics(duel)` and `resultCopyText(slot, result, duels)`.

`_teamBonusPoints` moves from `legacy_score_sheet.dart` to `lib/domain/results.dart` as public `teamBonusPoints`.

Tests run on the real Rudná–Vršovice match (the federation fixture):
- differences [22, 57, 4, 55, 99, −3];
- duel points 5 : 1, plus 2 for pins, 7 : 1;
- duels 1 and 3 decided by pins;
- duel 6 has a tied lane (215 = 215) and goes to the away side;
- plus T120 (4 lanes), a live match with half the lanes thrown, a duel waiting, a forfeit, and a missing discipline.

## Theming and accessibility

- Light and dark: all colours come from the theme (`colorScheme`), except the Zápis replica, which keeps its fixed colours on its white paper.
- The app's text size setting applies to Souboje (up to 200%, see the stacked layout); the Zápis keeps its own, as today.
- `test/core/theme_contrast_test.dart` gains the side colours: text 4.5:1, marks 3:1, in every theme variant.
- A winner is never told by colour alone: position (bar side), weight and the „bod“ pill say it too.

## Tests (app)

- **Widget tests** at 360×800, 412×915, 800×360 and 1280×800, each at text scale 1.0 and 2.0, light and dark: no overflow, nothing truncated.
- **Scoreboard:** the explanation line, the tiles (bar side per winner, the „+2 kuž.“ pill), the status chip per status, the live wording, the forfeit text, the missing lineup.
- **Duel cards:**
  - collapsed and expanded;
  - a tied lane, a half point, a duel decided by pins;
  - T120 as a 2×2 grid;
  - a live duel: the difference over both-thrown lanes only, the dashed lanes, no winner styling yet.
- **The switch:** it remembers the view, and the scoreboard stays.
- **Landscape phone:** the TV table's 6 rows fit, and a row tap opens the sheet.
- **Wide:** two panes, then two columns.
- **Copy:** the exact text.
- **Zápis:** the scrollbar, the paper in dark mode, and one semantics label per pairing.

## Release

- The web batch at the top of `changelog_data.dart` gets a line: „Detail zápasu: nový pohled Souboje — velká čísla, kdo vyhrál který souboj a dráhu, na šířku celý zápas na jedné obrazovce. Původní zápis je o ťuk vedle, na celé obrazovce s většími čísly.“ Add a `store:` summary if the batch goes over 500 characters.
- The Android release then follows the usual pipeline (version bump, tag `v*`, `release.yml`, PLAY.md). The version number is the user's call.
