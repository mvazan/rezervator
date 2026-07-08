# Rezervátor — redesign „Noční liga" (design spec)

Schváleno uživatelem 2026-07-08 (brainstorming s visual companion: paleta „Nočná liga",
layout deň+týždeň s prepínačom, kiosk vždy týždeň, bez bottom navigace).

## Cíl

Svěžejší a modernější vzhled celé aplikace (mobil, web, kiosk) bez zásahu do domény,
dat a chování rezervací. Vizuální jazyk: indigo `#6366F1` + kyanový akcent `#22D3EE`,
gradienty jen na hlavních CTA, písmo Manrope (bundlované), zaoblení 16/12/pill.

## Rozhodnutí (závazná)

1. **Rozsah:** celá appka — theme, auth obrazovky, rozvrh, admin, kiosk.
2. **Dark mode:** appka sleduje systém (light i dark plnohodnotně vyladěné);
   **kiosk je vždy dark** (slate `#0F172A` pozadí, `#1E293B` karty).
3. **Layout rozvrhu (appka):** DVA pohledy přepínané ikonou v AppBaru
   (view_day ↔ view_week), volba per zařízení přes `shared_preferences`
   (klíč `schedule_view`, hodnoty `day`/`week`, default `day` na šířce < 700 px,
   jinak `week`).
   - **Denní pohled (nový):** pásek 7 chipů dní (po–ne; číslo dne, tečky = moje
     rezervace, tlumené = zavřeno; vybraný chip gradient) + `PageView` s jedním
     dnem na obrazovku — velké buňky (výška ≥ 56), lane headers, swipe mění den
     a synchronizuje pásek. Šipky ‹ › posouvají týden, „dnes" resetuje.
   - **Týdenní pohled:** dnešní vertikální seznam dní, redesign karet
     (DayHeader + kompaktní SlotTile).
4. **Kiosk:** vždy celý týden (beze změny logiky), restyling na dark + velké buňky.
5. **Navigace:** zůstávají ikony v horní liště (správa/odhlášení). Bottom nav ani
   záložka „Moje rezervace" NEVZNIKÁ (uživatel odmítl).
6. **Doména/data/RPC/texty:** beze změn. České UI texty zůstávají doslova
   (testy na nich staví).

## Architektura změn

### `lib/core/theme.dart` (nový; main.dart si jen bere `buildTheme(Brightness)`)
- `ColorScheme.fromSeed(seed 0xFF6366F1)` + `copyWith`: secondary/tertiary kyan
  `0xFF22D3EE`, error rose. Dark varianta: přepsané surface tóny na slate
  (`surface 0xFF0F172A`, `surfaceContainer* 0x1E293B/0x24324A…`), outlineVariant
  slate-700.
- Typografie: **Manrope** variable font v `assets/fonts/` (OFL licence přiložena),
  `fontFamily: 'Manrope'`; nadpisy w800, tituly w700, body w400–500.
- Tvary: karty 16, tlačítka/inputy 12, chipy pill; AppBar bez elevation,
  scrolledUnderElevation 0; SnackBar floating radius 12; Dialog radius 20.
- Stíny: light = jemný indigo-tint stín na kartách; dark = 1px border místo stínů.
- `GradientButton` widget (`lib/core/widgets/gradient_button.dart`):
  indigo→kyan LinearGradient, radius 12, ripple, disabled = šedý; použití:
  hlavní CTA (kiosk Rezervovat, potvrzení v dialozích NE — tam FilledButton).

### Sdílené komponenty `lib/features/schedule/widgets/`
- **`SlotTile`** — jediný widget buňky pro appku i kiosk.
  Vstup: `SlotState`, `size` (compact|large), interakční callbacky (nullable).
  Vzhled: Free bookable = čárkovaný obrys + „＋" (primary), quiet (admin-only) =
  25% alpha, inert = prázdné tlumené; Mine = primary container + „Ty" tučně;
  Other = iniciálový avatar (kruh, 2 písmena) + příjmení, surfaceVariant;
  Rental = amber tón + jméno nájemce; Match = rose tón + „Zápas".
- **`DayHeader`** — datový badge (zkratka dne + číslo v zaobleném čtverci),
  název dne, chip obsazenosti „N volných" (nebo „Zavřeno[ — důvod]"),
  match strip (rose pruh s 🏆 textem).
- **`initialsOf(String displayName)`** helper (2 písmena) v `lib/core/ui.dart`.
- `week_screen.dart` a `kiosk_week_view.dart` tyto komponenty POUŽÍVAJÍ
  (mažou své lokální `_SlotCell`/inline buňky) — logika tapů beze změny.

### Rozvrh v appce (`lib/features/schedule/`)
- `week_screen.dart` → zůstává „shell": AppBar akce + přepínač pohledu +
  navigační řádek; tělo deleguje na `WeekListView` (dnešní seznam, restyling)
  nebo `DayPagerView` (nový soubor `day_pager_view.dart`).
- `DayPagerView`: chip pásek (`DayChipStrip` widget) + `PageView.builder`
  (index = offset dne od pondělí aktuálního týdne; přejezd za neděli přepne
  týden). Buňky `SlotTile(large)`; booking/cancel handlery předané z shellu
  (beze změny). Prázdný/zavřený den = velká karta „Zavřeno[ — důvod]" + zápasy.
- Persistence: `shared_preferences` (nová dependency), čtení při initu shellu,
  zápis při přepnutí. Kiosku se netýká.

### Kiosk (`lib/features/kiosk/`)
- `KioskShell`: `Theme(data: buildTheme(Brightness.dark), child: …)` — vždy dark.
- Status bar: slate panel, hodiny w800 28px, info řádek, `GradientButton`
  Rezervovat (min výška 56); banner „Rezervuje:" s avatarem + ✕.
- `kiosk_week_view.dart`: `SlotTile(large)` + `DayHeader`; týdenní struktura
  a všechna pravidla beze změny.
- `name_picker.dart`: dark, dlaždice s indigo obrysem, vybraná gradient.

### Auth + admin
- `login_screen.dart`/`register_screen.dart`/`waiting_screen.dart`/
  `kiosk_login_screen.dart`: obsah beze změny, obal = karta (max 420) na
  pozadí `Container` s jemným radiálním indigo-slate gradientem; logo 🎳
  v kruhu s gradientovým okrajem.
- Admin huby/formuláře: přebírají novou theme; `admin_screen.dart` ListTily
  dostanou leading ikonu v tónovaném zaobleném čtverci (primaryContainer).

## Mimo rozsah (YAGNI)
Bottom navigace, „Moje rezervace", světlý kiosk, změny textů/chování/RPC,
animace nad rámec implicitních Material přechodů, custom ikony.

## Testy a ověření
- Stávajících 53 testů musí projít beze změn textových assertů
  (SlotTile zachová texty: „Zápas", jména, „Ty" jen jako vizuální bold — POZOR:
  dnešní buňka „mine" zobrazuje jméno hráče, ne „Ty" → SlotTile zachová
  zobrazení jména, „Ty" se NEZAVÁDÍ, aby testy `find.text('Já Hráč')` prošly).
- Nové widget testy: (a) přepínač day↔week přepne pohled a zapíše preference,
  (b) rezervační dialog z denního pohledu, (c) kiosk je vždy dark
  (Theme.of.brightness == dark) a vždy týdenní.
- `flutter analyze` čisté; web + apk build; manuální kontrola light/dark
  na Pages po merge.
