# Posun slotů (±30) + hybridní kioskový board (design spec)

Schváleno uživatelem 2026-07-09 (visual companion).

## Kontext / problém

Zápas s přípravou dráh (`prep_minutes`) blokuje celý překrývaný blok, i když
příprava trvá jen část (30 min z 60min bloku) → ztráta tréninkového času.
Řešení: admin může pro daný den **posunout tréninkové bloky o ±30 min** tak,
aby poslední blok lícoval se začátkem přípravy (žádná mezera, příprava se stane
vlastním krátkým blokem). To ale vytváří den s **jinými časy** než ostatní dny;
kioskový board (dnes sdílená „union" lavice) je pak děravý/duplicitní.

## 1. Editor výjimky dne — tlačítka posunu ±30 min

Do dialogu „Otevřeno — vlastní časy" (řádkový editor od/do) přibudou nad seznam
řádků dvě tlačítka **„− 30 min"** a **„+ 30 min"**:
- Vezmou **výchozí aktivní bloky** dne (settings, ne aktuální řádky) a posunou
  všechny jejich časy o ∓30 / ±30 min, výsledek nasypou do řádkového editoru
  (přepíšou stávající řádky). Uživatel pak může doladit (zkrátit poslední blok
  na 18:00–18:30 apod.).
- Čistá doménová funkce `shiftBlocks(List<TimeBlock> active, int offsetMinutes)
  → List<(HourMinute start, HourMinute end)>` (unit-testovaná): posune každý
  blok o offset; blok, který by přetekl přes půlnoc (start < 0 nebo end > 24:00)
  se vynechá. Nemění DB — jen předvyplní editor; uložení jde stávající cestou
  (find-or-create special blocks + `set_day_override`, viz clubs/board spec).
- Tím se také (find-or-create podle přesných časů) přestanou tvořit duplicitní
  neaktivní bloky se stejným časem jako aktivní — helper `matchSpecialBlocks`
  už existuje a časy hledá přesně; posun generuje jiné časy, takže reuse funguje.

## 2. Kioskový board — hybrid „swimline + vlastní časy pro posunuté dny"

Nahrazuje dnešní čistou union-lavici. Logika:
- **Výchozí (společné) bloky** = aktivní `time_blocks` ze settings, seřazené.
  Tvoří **swimline** = levou časovou lavici (jako dnes railBlocks, ale jen
  z výchozích bloků, NE union přes všechny dny).
- Každý **den** je buď:
  - **„standardní"** — jeho efektivní bloky = výchozí sada (žádný override, nebo
    override jehož block_ids == výchozí sada). Renderuje se do swimline mřížky:
    jedna buňka na výchozí blok, zarovnaná s lavicí; buňky **bez času** (čas
    bere z lavice). Chybějící blok = prázdná ztlumená buňka (u standardních dnů
    ale nikdy nechybí).
  - **„posunutý/vlastní"** — má override s vlastními časy ≠ výchozí sada. Jeho
    sloupec se renderuje jako **jeden souvislý pruh přes celou výšku boardu**
    (výška = součet výšek všech swimline řádků), rozdělený na JEHO vlastní bloky
    v JEHO časech (proporcionálně dle trvání, board_layout helper). Každá buňka
    má **čas napsaný v buňce** (malý label nahoře), a to i pro obsazené i volné
    buňky — viz §3. Nezarovnává se s lavicí (má vlastní vnitřní osu).
- Detekce „posunutý den": den je posunutý, když má `DayOverride` s `blockIds`,
  jejichž množina se liší od výchozí aktivní sady (porovnat množinu id, ne
  pořadí). Closed dny zůstávají jako dnes (ztlumený sloupec „✕ zavřeno").
- Zápas/příprava uvnitř posunutého sloupce se malují na jeho vlastní bloky
  (příprava = krátký blok 18:00–18:30, zápas = svůj blok/y) — díky vlastním
  časům už příprava nezabírá zbytečně celý 60min blok.
- Match strip v hlavičce, DNES gradient, kluby, nick, gridlines, idle-scroll,
  booking-only — beze změny (jen řádková geometrie sloupce se liší dle typu dne).

## 3. Časy ve všech buňkách posunutého dne (i volných)

V posunutém sloupci každá buňka (volná ＋, obsazená jménem, prep, match) ukazuje
svůj čas malým labelem, aby hráč viděl, kdy má přijít:
- volná: `16:00–17:00` + ＋ (dvouřádkově / čas nad ＋)
- obsazená: `17:00–18:00` + jméno/nick
- prep: `18:00–18:30` 🛠 Příprava
- match: `18:30–21:30` 🏆 SKK Veverky

Standardní dny buňky bez času (čas z lavice) — beze změny.

## 4. Rozsah / mimo rozsah
- App (mobil/web) grid: BEZE ZMĚNY — používá per-day bloky ve své tabulce, tam
  žádný union/swimline problém není. Jen kiosk board se mění.
- Prep zůstává „celý blok" jednotka (nedělitelná rezervace) — posun slotů je
  způsob, jak mezeru odstranit; nekreslíme půl-buňkové prep pruhy (varianta B
  z companionu zamítnuta ve prospěch C = posun).
- Žádná změna schématu/RPC (posun jen předvyplní editor; special blocks a
  override jdou stávající cestou).

## 5. Testy
Doména: `shiftBlocks` (posun +30/−30, vynechání přetečení přes půlnoc/nulu,
prázdný vstup). Kiosk widget: (a) standardní dny renderují do swimline
(zarovnané, bez času v buňce); (b) posunutý den (override s ne-výchozími
block_ids) renderuje souvislý sloupec s časy v buňkách včetně volných; (c)
editor: tlačítko „+30 min" předvyplní řádky posunutými časy. Existující kiosk
testy (dark/7 sloupců/booking/prep/nick/gridlines/proporcionální výšky) musí
projít.
