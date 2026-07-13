# Kioskový board na absolutní 30-min časové ose (design spec)

Schváleno uživatelem 2026-07-09 (visual companion). Navazuje na hybridní board
(PR #12) — nahrazuje jeho normalizované roztažení posunutého sloupce absolutní
časovou osou, kde každý blok začíná/končí přesně na své ose.

## Problém s dnešním stavem

Posunutý den (vlastní časy) se dnes renderuje jako souvislý pruh normalizovaný
na výšku swimline → jeho bloky NElícují vertikálně s časy na levé ose. Uživatel
chce, aby blok 16:00–17:00 v posunutém sloupci byl svisle přesně tam, kde je na
ose 16:00–17:00.

## Řešení: pevná 30-min osa pro celý board

- **Časová osa (rail)** = pravidelná mřížka po **30 minutách** pokrývající celý
  rozsah dne: od `min(všech start časů)` do `max(všech end časů)` napříč VŠEMI
  viditelnými dny (default bloky i posunuté override bloky), zaokrouhleno na
  30-min hranice. Jedna „řádka" = 30 min o pevné výšce `_slotHeight` (např.
  30–34 px × laneCount? NE — viz níže).
  - Výška jedné 30-min řádky = konstanta `rowUnitHeight` (např. 30 px na
    celý blok-slot, NEZ na dráhu — dráhy se dělí uvnitř buňky). Board výška =
    počet 30-min řádků × rowUnitHeight × ? — viz geometrie.
  - Přesná geometrie: jedna 30-min jednotka má výšku `unit` (konstanta, např.
    28 px). Blok trvající N×30 min zabírá N jednotek = N×unit. Uvnitř bloku se
    dráhy dělí (Column of Expanded lanes) jako dnes. Rail label u každé
    30-min čáry (menší font); „hlavní" čáry (celé hodiny nebo default-block
    hranice) mohou být zvýrazněné.
- **Každý blok (default i posunutý)** se umístí do mřížky podle svého
  absolutního času: `topOffset = (block.startsAt − axisStart) / 30min × unit`,
  `height = block.durationMinutes / 30 × unit`. Takže:
  - default 60-min blok = 2 jednotky vysoký, na svém startu;
  - posunutý blok 16:00–17:00 = 2 jednotky, začíná na ose 16:00;
  - příprava 18:00–18:30 = 1 jednotka (30 min);
  - zápas 18:30–21:30 = 6 jednotek.
- **Vertikální lícování**: protože osa je absolutní, blok začínající 18:30 je ve
  VŠECH sloupcích na stejné y-souřadnici. Posunuté i default dny lícují.
- **Prázdné mezery**: v místě 30-min řádky, kde daný den nemá blok (např.
  default den nemá nic mezi svými 60-min bloky — ale ty na sebe navazují, takže
  mezera vzniká jen když den reálně nemá blok v daném čase), se vykreslí
  prázdná ztlumená buňka. Většinou navazující bloky mezery nemají.
- **Časové labely v buňkách**: posunuté dny (a klidně i default — ale spec: jen
  posunuté, aby default zůstal čistý) ukazují čas v buňce jako dnes. Na
  absolutní ose je to méně nutné (osa čas dává), ale ponecháme pro posunuté dny
  pro jistotu (malý label vpravo nahoře).

## Geometrie (klíčové rozhodnutí výšky)

`unit` = výška 30-min jednotky. Dnešní `blockGroupHeight` škáloval výšku dle
laneCount × per-lane výšku. Nově:
- `unit = laneCount * _laneRowHeight30` kde `_laneRowHeight30` je výška dráhy
  pro 30-min blok (např. 22 px — floor z proporcionálního helperu). 60-min
  blok = 2×unit, dráhy uvnitř 2× vyšší. To zachová „proporcionální dle
  trvání" (60min blok 2× vyšší než 30min) A absolutní pozice.
- Rail label u každé 30-min čáry; výška labelu se vejde do `unit`.

Tzn. `board_layout.dart` dostane helper:
`axisRange(days, defaultBlocks) → (HourMinute axisStart, int slotCount)` (počet
30-min slotů) a `slotOffsetFor(block, axisStart) → (int startSlot, int spanSlots)`.

## Rendering

- `_Rail`: pro každý 30-min slot (0..slotCount-1) vykreslí čáru + label
  `axisStart + i*30min`. Výška každého = `unit`.
- Každý sloupec (`_DayColumn`): `Stack` nebo `Column` s prázdnými sloty výšky
  `unit`, do kterých se na správný `startSlot` umístí bloky výšky
  `spanSlots*unit`. Prakticky: vygenerovat pole `slotCount` buněk; pro každý
  blok dne vyplnit jeho `[startSlot, startSlot+spanSlots)` buňkami (první = blok
  s obsahem přes `spanSlots*unit`, ostatní přeskočit) — nebo použít
  `Column` kde iterujeme sloty a sk1 pujeme obsazené. Nejčistší:
  `Column(children: [for each block a SizedBox(height: spanSlots*unit, child:
  cell), a mezi nimi prázdné SizedBox(height: gapSlots*unit) pro mezery])`.
- Match/prep/club/nick/gridlines/dark-light/DNES/booking/idle-scroll — zachovat.
  Gridline mezi 30-min sloty (jemná) místo mezi bloky.
- resetToNow: offset `now` = `(now − axisStart)/30 × unit` + header.

## Rozsah / mimo
- App/web grid beze změny.
- Nahrazuje T3 z PR #12 (normalizovaný pruh) tímto absolutním modelem. shiftBlocks
  (T1) a ±30 tlačítka (T2) zůstávají.
- 30 min je nejmenší jednotka (posun je ±30) → jemnější osa netřeba.

## Testy
board_layout: `axisRange` (default-only → start=min, správný slotCount),
`slotOffsetFor` (60min blok = 2 sloty, 30min = 1, posunutý start na správném
slotu). Kiosk widget: (a) posunutý blok 16:00 je na stejné y jako default blok
16:00-na-ose (getTopLeft.dy shoda / v rámci unit); (b) 30min prep = poloviční
výška 60min bloku; (c) default dny lícují s osou. Existující testy projdou
(default bloky navazují → osa = jejich hranice, žádné mezery).
