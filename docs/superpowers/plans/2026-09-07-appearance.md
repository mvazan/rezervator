# Vzhled a velikost písma — plán

**Cíl:** hráč si vybere téma (auto / světlé / tmavé / světlé kontrastní / tmavé
kontrastní) a velikost písma (normální / větší / největší), jako to má
Termínátor. Nastavení je v profilu, drží se v zařízení.

**Odkoukáno z Termínátoru** (`~/Home/terminator`): `lib/core/theme_choice.dart`,
`lib/core/text_size.dart`, `lib/data/local_prefs.dart`, wiring v `lib/main.dart`,
`test/core/theme_contrast_test.dart`. Termínátor má jen tři volby (světlá a
tmavá jsou u něj vždycky kontrastní); tady je kontrast vlastní osa, tedy pět.

## Global Constraints

- Nastavení je **zařízení-lokální** (`shared_preferences`), ne v účtu — jako v
  Termínátoru. Klíče `theme_choice`, `text_size`.
- Faktory písma 1.0 / 1.15 / 1.3, škálovač respektuje systémové nastavení a
  stropuje na 200 % návrhové velikosti (WCAG 1.4.4).
- Czech UI copy, English code and comments.
- `flutter analyze` čistý, `flutter test` zelený (543 dnes).
- Commit per task s `Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>`.

## Pozor na paletu

`lib/core/theme.dart` neskládá schéma jen ze semínka — po `ColorScheme.fromSeed`
přepisuje desítky rolí ručně laděnou rampou „Noční liga". Kdyby se ke `fromSeed`
jen přidal `contrastLevel: 1.0`, ty ruční barvy by ho přebily a „kontrastní"
téma by kontrastní nebylo. Proto: **kontrastní varianty berou schéma z
`fromSeed(contrastLevel: 1.0)` a značkovou rampu neaplikují** (semínko zůstává,
takže odstíny jsou pořád z rodiny appky). Test to musí ohlídat, ne oko.

---

## Task 1 — Model, uložení, téma a napojení

**Files:** create `lib/core/theme_choice.dart`, `lib/core/text_size.dart`,
`lib/data/local_prefs.dart`, `test/core/theme_contrast_test.dart`,
`test/data/local_prefs_test.dart`; modify `lib/core/theme.dart`, `lib/main.dart`.

- `enum ThemeChoice { system, light, dark, lightContrast, darkContrast }` a
  `({ThemeMode mode, double contrastLevel}) themePlanFor(ThemeChoice)`:
  `system` → `(system, 0)`, `light` → `(light, 0)`, `dark` → `(dark, 0)`,
  `lightContrast` → `(light, 1)`, `darkContrast` → `(dark, 1)`.
  `parseThemeChoice(String?)` s bezpečným pádem na `system`.
- `enum TextSizeChoice { normal, large, largest }`, `textSizeFactor` 1.0/1.15/1.3,
  `AppTextScaler extends TextScaler` nad systémovým škálovačem se stropem 2×.
- `local_prefs.dart`: dva Riverpod `Notifier`y nad `shared_preferences`, které
  vrátí výchozí hodnotu hned a načtenou dosypou.
- `buildTheme(Brightness brightness, {double contrastLevel = 0})` — značková
  rampa jen při `contrastLevel == 0`; jinak čisté `fromSeed` s kontrastem.
- `main.dart`: `RezervatorApp` na `ConsumerWidget`, `theme`/`darkTheme` ze
  stejného plánu, `themeMode` z něj taky, a `builder:` přebije
  `MediaQuery.textScaler` na `AppTextScaler`.
- **Test kontrastu** přes všechny čtyři vykreslitelné varianty (světlá/tmavá ×
  kontrast 0/1): text na `surface`, na `surfaceContainer*`, na `primary`,
  `primaryContainer`, `secondaryContainer`, `error`, `errorContainer`, a tvary
  (`outline` proti `surface`) — práh 4.5 pro text, 3.0 pro tvary.
  Pomocné funkce `relativeLuminance`/`contrastRatio` do `lib/core/contrast.dart`,
  ať je z čeho počítat i jinde.

---

## Task 2 — Karta v profilu

**Files:** create `lib/features/profile/widgets/appearance_card.dart`; modify
`lib/features/profile/profile_screen.dart`; tests
`test/features/appearance_card_test.dart`, `test/features/profile_screen_test.dart`.

- Karta **„Vzhled"** hned pod jménem (vzhled je to první, co jde upravit, a
  netýká se rezervací): dvě řádky, každá otevře dialog s výběrem.
- „Vzhled": `Podle systému`, `Světlý`, `Tmavý`, `Světlý — vysoký kontrast`,
  `Tmavý — vysoký kontrast`.
- „Velikost písma": `Normální — jako v telefonu`, `Větší (115 %)`,
  `Největší (130 %)`.
- Řádek ukazuje vybranou hodnotu v podtitulku; dialog je `RadioListTile`
  v `SimpleDialog`, jako v Termínátoru.
- Test: výběr se propíše do provideru a řádek to ukáže; profil kartu má.

---

## Task 3 — Changelog

Nový webový záznam o tématech a velikosti písma.
