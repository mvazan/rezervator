# Oddíly s barvami + barevné pronájmy + téma kiosku (design spec)

Schváleno uživatelem 2026-07-08 (brainstorming + visual companion paleta).

## 1. Oddíly (kluby) jako entita s barvou

Nová tabulka `clubs` nahrazuje dnešní volný text `profiles.club`:
- `clubs`: `id uuid`, `name text unique not null`, `color smallint not null`
  (index do palety 0–11; -1 = žádná = neutrální), `created_at`.
- `profiles.club_id uuid null references clubs(id) on delete set null` přibude;
  starý text `profiles.club` se **zachová** (read-only historie) a při migraci se
  z jeho distinct neprázdných hodnot založí kluby (default barvy round-robin
  z palety) a hráči se napojí podle shody názvu. `players` view + `PlayerName`
  dostanou `club_id` a `club_color` (barvu klubu, -1 když žádný).
- Přiřazení: **admin** v Hráčích mění hráčův oddíl přes dropdown (RPC
  `set_player_club(p_user_id, p_club_id)` — admin only). Správa oddílů
  (přidat/přejmenovat/barva/smazat) v Nastavení kuželny → nová sekce „Oddíly".
- RLS: `clubs` čitelné `is_approved_or_kiosk()`, zápis admin. Přidání do
  realtime publikace.

## 2. Barevná paleta (sdílená, doména)

`lib/domain/palette.dart` — 12 klubových barev, každá `{darkBg, darkFg,
lightBg, lightFg}` (hodnoty z companion mockupu, viz níže), + index -1 =
neutrální (dnešní surfaceVariant tóny). Čistá mapa `clubColor(int index,
Brightness) → (Color bg, Color fg)`; unit-test na rozsah/fallback (index mimo
0–11 → neutrální).

Barvy (bg/fg pro dark, pak light): Modrá 1E3A8A/BFDBFE · DBEAFE/1E3A8A;
Zelená 14532D/BBF7D0 · DCFCE7/166534; Červená 7F1D1D/FECACA · FEE2E2/991B1B;
Oranžová 7C2D12/FED7AA · FFEDD5/9A3412; Fialová 4C1D95/DDD6FE · EDE9FE/5B21B6;
Tyrkys 134E4A/99F6E4 · CCFBF1/115E59; Růžová 831843/FBCFE8 · FCE7F3/9D174D;
Žlutá 713F12/FDE68A · FEF9C3/854D0E; Limetka 365314/D9F99D · ECFCCB/3F6212;
Indigo 312E81/C7D2FE · E0E7FF/3730A3; Hnědá 44403C/E7E5E4 · E7E5E4/44403C;
Šedá 334155/CBD5E1 · E2E8F0/334155.

## 3. Barva pronájmu (per pronájem)

- `rentals.color smallint not null default -2` (-2 = výchozí jantar jako dnes;
  0–11 = klubová paleta; použijeme paletu i pro pronájmy pro konzistenci).
  Formulář pronájmu dostane výběr barvy z palety (+ „výchozí").
- `Rental` model + `rentals` stream + board/grid render barvu použijí; když -2,
  ponechají stávající amber.

## 4. Téma kiosku (admin light/dark)

- `schedule_settings.kiosk_dark boolean not null default true` (dnešek = dark).
- Nastavení kuželny → přepínač „Kiosk: tmavý / světlý režim".
- KioskShell/board použije `buildTheme(kioskDark ? dark : light)` místo napevno
  dark. Status bar, gridlines, prep/match/rental/club barvy musí být čitelné
  v obou (paleta §2 na to má light i dark variantu; gridlines alpha ladí podle
  brightness).

## 5. Kde se barva oddílu zobrazí

- **Kiosk board**: jméno/nick hráče dostane podklad `clubColor(club_color,
  kioskBrightness).bg` + text `.fg` (místo dnešního neutrálního „obsazeno").
  Moje-rezervace zvýraznění zůstává (indigo rámeček/akcent nad klubovou barvou,
  aby se neztratilo). Prázdné/prep/match/rental beze změny (rental má vlastní
  barvu §3).
- **Appka mřížka** (week list + day pager, `SlotTile`): cizí rezervace tónovaná
  klubovou barvou (kompaktní i velká), „moje" zůstává primary. SlotTile dostane
  volitelný `clubColorIndex` + použije `clubColor(...)` podle aktuální
  `Theme.brightness`.

## 6. Migrace `0003_clubs.sql`
`clubs` tabulka + `profiles.club_id` + `rentals.color` + `schedule_settings.
kiosk_dark`; data-migrace textových klubů → clubs + napojení hráčů;
`players` view rebuild (club_id, club_color); RPC `set_player_club`,
`upsert_club`, `delete_club`; RLS + realtime. Atomická (begin/commit).

## 7. Testy
Doména: `clubColor` rozsah/fallback obou brightness; migrace-helper (distinct
klubů → indexy) pokud čistá. Widget: board dlaždice má klubovou barvu (dark i
light kiosk); appka cizí rezervace tónovaná; nastavení přepne kiosk theme;
admin dropdown oddílu v Hráčích; barva pronájmu. Existující texty beze změny.

## Mimo rozsah
Hráč si sám nemění oddíl (jen admin), auto den/noc kiosku, gradientové klubové
barvy, per-hráč barva.
