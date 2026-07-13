# Kalendárový view rozvrhu (kiosk + týždenný view v appke)

Schválené v konverzácii 2026-07-13.

## Zámer

Zobrazenia s dňami v stĺpcoch (kiosková tabuľa, týždenný grid v appke) sa
**nahrádzajú** kalendárovým layoutom: vľavo hodinová os, sloty ako udalosti
pozicované a vysoké podľa skutočného času. Slot v sebe drží počet
rezervačných miest podľa počtu dráh (dnešné lane bunky). Deň-pager na
mobile ostáva nezmenený (dni v stĺpcoch nemá).

Knižnica (calendar_view/kalender/syncfusion) zamietnutá: dodala by len
časovú os (triviálna matika, v kóde už je), zatiaľ čo obsah slotu — lane
bunky, farby oddielov, priority, prenájmy, admin gestá — by sa aj tak
renderoval celý vlastný; navyše overlap algoritmy knižníc a licencie
(syncfusion) by prekážali.

## Rozhodnutia

- **Jeden zdieľaný layout, dve použitia** — admin nemá separátny view,
  edituje priamo v týždennom kalendári (ťuknutie do prázdnej plochy = nový
  blok s časom predvyplneným podľa miesta ťuknutia; long-press na slot =
  úprava bloku). `BlockDialog` + admin callbacky z PR #15 sa len prepoja.
- **Kiosk = fit-height**: časové okno (najskorší začiatok → najneskorší
  koniec bloku aj mimo-blokovej udalosti v zobrazených dňoch) sa roztiahne
  na výšku obrazovky — celý deň bez scrollu. Read-only, bez admin gest.
- **Appka = pevná mierka px/min, scroll**: mierka zvolená tak, aby typický
  60-min blok ≈ dnešná výška riadku. Fit-width prepínač ostáva (šírka
  stĺpcov), day-pager ostáva.
- **Geometria**: y = čas. Invariant z PR #12–14 (všetky stĺpce zdieľajú
  jednu vertikálnu geometriu) platí z princípu — os aj stĺpce počítajú
  pozíciu z tej istej funkcie okna. Kompresia prázdnych medzier sa ruší
  (prázdny čas je viditeľná plocha — u admina klikateľná).
- **Now-line**: červená čiara aktuálneho času cez dnešný stĺpec (kiosk aj
  appka); nahrádza kioskový highlight aktuálneho segmentu.
- Hodinová os je vľavo (kalendárová konvencia).

## Komponenty

1. `lib/domain/calendar_layout.dart` (pure Dart): `CalendarWindow`
   (startMin/endMin, zaokrúhlené na celé hodiny), `calendarWindowFor(...)`
   z blokov + mimo-blokových udalostí, `topFor/heightFor` v px/min mierke,
   `timeAt(dy)` pre tap-to-add (zaokrúhlenie na 15 min).
2. `lib/features/schedule/widgets/calendar_board.dart`: hodinový ruler,
   gridlines, `CalendarDayColumn` s Positioned kartami (builder per entry),
   now-line, tap na prázdno (nullable callback).
3. Kiosk `kiosk_board_view.dart`: prepis na calendar_board (fit-height);
   obsah kariet (lane riadky, priority, prenájmy, zavreté dni) sa zachová.
4. Appka `week_screen.dart`: `_grid` (chunkované Tables + gap_rows) →
   calendar_board; obsah kariet = dnešné bunky s dráhami.

## Testy

Unit: okno (zaokrúhlenie, mimo-blokové udalosti rozširujú okno, prázdny
týždeň), topFor/heightFor/timeAt round-trip. Widget: kiosk (obsah kariet,
zavreté dni, ruler zarovnaný so stĺpcami — invariant), appka (rezervácia
ťuknutím, admin tap-to-add prefill, non-admin bez gest, long-press dialóg).
Existujúce testy segmentácie/gap_rows sa nahradia.
