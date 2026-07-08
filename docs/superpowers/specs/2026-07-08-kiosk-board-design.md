# Kiosková tabuľa + príprava dráh + nick (design spec)

Schválené používateľom 2026-07-08 (visual companion, mockup kiosk-board-v2 + voľba
„prep_minutes + automatické posunutie blokov").

## 1. Kiosk „Tabuľa" (nahrádza vertikálny týždenný zoznam kiosku)

Landscape-first zobrazenie inšpirované fyzickou tabuľou:

- **Stĺpce = dni od DNES** (dnešok prvý, zvýraznený gradientovou hlavičkou
  `DNES · st 8.7.`), ďalej dopredu až po `booking_horizon_days`. Žiadne dni
  minulosti, žiadne pevné po–ne.
- **Všetky stĺpce rovnako široké**; šírka = `clamp(160, (šírka−rail)/7, 220) dp`
  → na bežnom tablete presne 7 dní bez scrollu; ďalšie dni horizontálnym
  scrollom (snap po stĺpcoch). Vľavo úzky rail s časmi blokov.
- **Riadky = časové bloky** (union blokov viditeľných dní, zoradené podľa času;
  deň bez daného bloku má bunku prázdnu/stlmenú). Výška bloku = `laneCount`
  riadkov dráh — bunky sú vertikálne zarovnané naprieč stĺpcami.
- **Bunka deň×blok = dráhy pod sebou** (ako magnetky): každý riadok jedna
  dráha — malá číslica dráhy + **celé meno / nick** (ellipsis pri pretečení);
  voľná dráha = riadok `＋` (čiarkovaný, kyan); moja rezervácia zvýraznená
  indigo; prenájom = 🔒 + meno nájomcu (amber).
- **Zápas** = bunka cez celý blok: `🏆 {súper}` + čas `{starts}–{ends}` (rose).
- **Príprava dráh** (viď §2) = bunka cez celý blok: `🛠 Příprava drah` (tlmená
  rose/slate) — hostia vidia skutočný začiatok zápasu na zápasovej bunke.
- **Zavretý deň** = celý stĺpec stlmený, vertikálne `✕ zavřeno[ — dôvod]`;
  zápasy v zavretý deň sa v stĺpci zobrazia (fanúšikovia).
- Status bar (hodiny, info, Rezervovat/banner) a rezervačný flow (meno →
  ťuknúť ＋ → potvrdenie) ostávajú bez zmeny. Idle reset resetuje aj
  horizontálny scroll na DNES.
- Portrait: tabuľa funguje (menej stĺpcov + scroll); SETUP odporučí vo Fully
  zamknúť landscape.
- Appka (mobil/web) tabuľou NEdostáva — jej denný/týždenný pohľad ostáva;
  z novej domény prevezme len 🛠 prep stav bunky (SlotTile variant).

## 2. Príprava dráh pri zápase (`matches.prep_minutes`)

- Nový stĺpec `prep_minutes smallint not null default 0 check (0..240)`.
- **Blokovanie**: rezervácie kolidujú so zápasom v okne
  `[starts_at − prep_minutes, ends_at]`. Platí v `create_reservation`,
  v konflikt-trigri `cancel_res_for_match` aj v doméne (`buildWeekSchedule`).
  POZOR na PG `time − interval` (wrap cez polnoc): clamp na `00:00`
  (`greatest`-ekvivalent cez `case when`). V Dart doméne clamp na 0 minút.
- **Zobrazenie**: bunky prekryté len prípravou (nie samotným zápasom) sú
  `MatchSlot(isPrep: true)` → UI `🛠 Příprava drah`; zápasová bunka ukazuje
  skutočný `starts_at`.
- Formulár zápasu: pole **„Příprava drah (min)"** — presety 0 / 30 / 60 +
  vlastná hodnota.

## 3. Vlastné časy blokov pre konkrétny deň (editor vo výnimke dňa; bez zmeny schémy)

Editor výnimky dňa sa zjednoduší na DVA režimy: **„Zavřeno"** (dôvod ako dnes)
a **„Otevřeno — vlastní časy"**:
- Zoznam riadkov `od–do` (pickTime), predvyplnený efektívnymi blokmi daného
  dňa; riadky možno pridať (＋), zmazať (✕) a upraviť — pokrýva subset,
  posun aj úplne iné časy (použiteľné aj mimo zápasov).
- Validácia: `do > od`, riadky sa nesmú navzájom prekrývať
  (`Časy se nesmí překrývat.`), aspoň 1 riadok.
- Uloženie: pre každý čas **find-or-create** neaktívny „špeciálny" blok
  (`time_blocks.active = false`, zhoda podľa presných `starts_at/ends_at`
  medzi neaktívnymi — žiadne duplikáty; `position` = minúty od polnoci) a
  `set_day_override(date, closed=false, block_ids=[...])`.
  Čistý helper v doméne: `matchSpecialBlocks(existingInactive, requestedRanges)
  → (reuseIds, toCreateRanges)` s unit-testami.
- Pôvodný chips-výber existujúcich blokov režim nahrádza (riadkový editor ho
  plne pokrýva). Existujúce overridy sa zobrazia v editore ako ich časy.
- Kombinácia so zápasom: vlastné bloky normálne podliehajú blokovaniu
  zápasom/prípravou.

## 3b. Zápas: Domácí a Hosté

- `matches.opponent` sa premenuje na `away_team` (dnešný význam = súper/hostia)
  a pribudne `home_team text not null default ''`.
- Formulár zápasu: polia **„Domácí"** (nepovinné) a **„Hosté"** (povinné —
  validácia `Vyplň hosty.` nahrádza dnešné `Vyplň soupeře.`).
- Zobrazenie všade (day header, board, info line kiosku):
  `Match.title` = `home_team.isEmpty ? away_team : '$home_team – $away_team'`
  (formát `🏆 {title} · {čas}` ostáva).
- Model `Match`: `homeTeam`, `awayTeam`, getter `title`; `fromJson` číta nové
  stĺpce. `import_key` bez zmeny.

## 4. Nick — krátke meno na tabuľu (`profiles.nick`)

- Nový stĺpec `nick text not null default '' check (char_length(nick) <= 14)`.
- `players` view sa rozšíri o `nick`; `PlayerName` model tiež.
- Tabuľa (a len ona) zobrazuje `nick.isNotEmpty ? nick : displayName`
  (s ellipsis). Denný/týždenný pohľad appky aj picker ostávajú pri celých
  menách; iniciálky avatarov sa počítajú z displayName.
- Nastavenie: admin v Hráčoch → menu hráča → **„Zkratka na tabuli…"**
  (promptText, prázdna hodnota = zmazať). RPC `set_nick(p_user_id, p_nick)` —
  povolené pre `auth.uid() = p_user_id` alebo admina (hráč sám cez UI zatiaľ
  nemá kde — YAGNI, RPC to už dovoľuje).

## 5. Migrácia `0002_board.sql`

`profiles.nick` + check; `matches.prep_minutes` + check;
`matches.opponent → away_team` (rename) + `matches.home_team` (default '');
drop+create `players` view s nick; `create or replace` upravených funkcií
(`create_reservation` match-okno s prep, `cancel_res_for_match` s prep);
nový RPC `set_nick`. Aplikuje sa na živú DB cez psql (rovnaký postup ako 0001;
bez placeholderov — webhook fn sa nemení).

## 6. Testy

Doména: prep-okno (vrátane polnočného clampu a hraníc), `isPrep` rozlíšenie,
`Match.title` (s/bez domácich), `matchSpecialBlocks` (reuse presných časov,
create zvyšku, prázdny vstup). Widget: tabuľa
renderuje stĺpce od dnes s rovnakou šírkou, nick fallback/ellipsis, 🛠 bunka,
zavretý stĺpec, rezervácia z tabule po výbere mena; existujúce testy bez zmeny
assertov (kiosk testy sa adaptujú na novú štruktúru tabule — texty
'Rezervovat'/'Kdo si rezervuje?'/'Rezervuje:' ostávajú).

## Mimo rozsahu
Tabuľa v mobilnej appke, automatické posúvanie/skracovanie blokov (rieši
ručný editor vlastných časov), editácia nicku hráčom v appke, per-dráhové
zápasy.
