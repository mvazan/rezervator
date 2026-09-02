# Rezervátor — audit kódu a plán vyčistenia pred ďalším rozvojom

*Stav k 2026-09-02, verzia 1.1.0+3, migrácie 0001–0015.*

## Prečo

Pred novými funkciami chceme pevnejšie základy: menej duplikácie, pravidlá
v doméne namiesto vo widgetoch, čitateľný backend. Tento dokument je výsledok
auditu celého repa (Flutter app, Supabase migrácie + edge funkcie, testy,
dokumentácia) a poradie, v akom sa čistenie robí. Každý bod = samostatný
plán v `docs/superpowers/plans/2026-09-02-cleanup-N-*.md` a samostatný PR.

## Východiskový stav (čo je dobré, na tom staviame)

- Doména (`lib/domain`) je čistý Dart bez Flutteru, plne testovaná
  (`buildWeekSchedule`, `calendar_layout`, `name_index`, …).
- `flutter analyze` bez nálezu, 210 testov prechádza (216 s nezlúčenou
  vetvou `sentry-filter-network`).
- Widgety nevolajú Supabase priamo — všetko ide cez `Api` v
  `lib/data/providers.dart`; `core/ui.dart` (`tryAction`, `confirmDialog`,
  `pickTime`, `friendlyDbError`) sa používa konzistentne.
- RLS: každá politika ide cez `current_tenant_id()`; všetkých 70
  SECURITY DEFINER funkcií má pripnutý `search_path`; žiadna tabuľka bez RLS;
  všetky mutácie rezervácií len cez RPC.
- Git je čistý: `build/`, `.idea`, `supabase/.temp`, keystore — všetko
  ignorované, nič z toho nie je trackované.

## Nálezy

### A. Rozvrh UI: duplikované vykreslenie

- `_DayColumn` existuje dvakrát, takmer doslovne:
  `features/schedule/week_calendar_view.dart:332-783` vs
  `features/kiosk/kiosk_board_view.dart:516-854` (`_entries`,
  `_closedBackground`, `_blockCard`, lane digit, window/halfHourMarks).
- Kiosk `_laneRow` (`kiosk_board_view.dart:710-809`) je štvrtý `switch`
  cez `SlotState` s tými istými farebnými fallbackmi ako
  `widgets/slot_tile.dart`. Doc komentár slot_tile tvrdí opak.
- Idiom `ClubColors.of(x, brightness)?.$1 ?? scheme.fallback` ~9×; štítky
  udalostí (`🏆/⛔ title`, `🔒 renter`) 5× s tromi rôznymi konvenciami
  (doména má `headerEventLabel` s 🏠/⛔).
- `_freeLabel` (week_calendar_view:159) ≡ day_pager_view:362; mapy mien a
  farieb hráčov 3×; booking flow + summary string 2×; loading/error
  scaffold 2×; odvodenie pondelka 5×.
- Magické čísla nezdieľané: lane row 40 px, block header 14 px, brand
  gradient `[0xFF6366F1, 0xFF22D3EE]` 3×.

### B. WeekScreen, kiosk a stav

- `_WeekScreenState.build` ~460 riadkov; sleduje 9 providerov, každý tick
  (hráči, prenájmy, nastavenia…) prestaví celú obrazovku a prepočíta
  `buildWeekSchedule` (volané na 3 miestach: week_screen:310,
  day_pager_view:286, kiosk_board_view:50 a :321).
- Kiosk shell má 20-sekundový timer so `setState`, ktorý prestaví celú
  tabuľu vrátane `nextTrainingDay` slučky (skladá celý `WeekSchedule`,
  aby zistil, či je deň otvorený).
- Tri nezávislé zdroje času (`DateTime.now()` v build week_screen:165,
  kiosk_board:253, kiosk_shell `_now`).
- Vedľajšie efekty v build: kiosk_board 405-411 mení `_window`,
  `_pxPerMinute`; week_calendar_view 227-240 plánuje `jumpTo` z build.
- `ref.invalidate(playersProvider)` na 4 miestach ako ručné cache-busting.
- day_pager_view: tri reentrancy flagy (`_shiftPending`, `_syncing`,
  `_animatingToPage`) — rodič a `PageController` súperia o `dayIndex`.

### C. Pravidlá vo widgetoch (patria do `lib/domain`)

- **Kiosk eligibility obchádza limit**: `kiosk_board_view.dart:767` skladá
  `interactive && selected != null && !inPast && !beyondHorizon` bez
  `maxActiveReservations` — ukáže „+“, ktoré RPC odmietne. Má volať `canBook`.
- **„Admin ruší čokoľvek“** je v `slot_tile.dart:264` (`me.isAdmin ||
  ownFuture`), `canCancel` v doméne to nepozná.
- `isDayOpen`/`nextTrainingDay` (kiosk_board_view:43-89) sú čisté funkcie.
- Drag&drop fit check (`week_calendar_view.dart:410-467`) je intervalová
  matematika patriaca k `freeGapAt`.
- `block_dialog.dart:329-680 _save`: ~200 riadkov plánovania (dissolve
  twin, hidden template, kept ids, find-or-create special) prepletených
  s 5 confirm dialógmi; testovateľné len cez widget testy.
- `move_reservations_dialog.dart:79-98` `laneBlocked`/`laneTaken` znovu
  odvodzuje to, čo `buildWeekSchedule` už vracia.
- Stranded-count počítaný tromi spôsobmi (schedule_screen:66,
  block_dialog:15, overrides_screen:67); club grouping dvakrát
  (players_screen:110, report_screen:78); limity 1–12/1–90/1–50/0–240
  roztrúsené vo widgetoch.

### D. Admin obrazovky: opakovaná kostra

- Gate „Jen pro správce“ 11×; save-dialog kostra (`_saving`, `Ukládám…`,
  pop-on-success) 8–9×; delete flow (confirm → tryAction) 8×;
  `showDatePicker` s `Locale('cs')` 5×; „konec po začátku“ 4×;
  Date/Start/End `ListTile` trojica 5×; lane `FilterChip` wrap 3×;
  `_ClubSwatch` ≡ `_TypeSwatch`.
- `.value ?? const []` v 8 obrazovkách prehltne loading aj error — RLS
  alebo sieťová chyba sa zobrazí ako „Zatím žádné oddíly“.
- `schedule_screen.dart:208` inicializuje controllery v build z provideru
  (zmena z iného zariadenia sa pri otvorenom formulári ignoruje);
  register_screen:72 rovnaký vzor.
- `schedule_screen.dart` importuje `supabase_flutter` len pre
  `PostgrestException` kód `23503` — storage detail vo widgete.
- Nekonzistentné umiestnenie dialógov: Blockage/Match sú súbory,
  Rental/Club/Type/Override privátne triedy.

### E. Backend

- **Migrácie**: 3 516 riadkov; `create_reservation` definovaná 6×
  (0001, 0002, 0004, 0005, 0009, 0010), `cancel_res_for_priority_slot` 5×,
  `move_reservation` 4×, `players` view 5×, všetkých ~27 politík
  dropnutých a znovu vytvorených v 0005. Nič v repe nehovorí, ktorá
  definícia je platná.
- **Git ≠ prod**: `0001:562,565` má placeholder `<PROJECT_REF>` /
  `<WEBHOOK_SECRET>`, žiadna neskoršia migrácia `notify_webhook`
  neprepisuje. Prod bol opravený ručne; čerstvý `db push` z gitu
  nainštaluje webhook na neexistujúci host. Overené lokálne: pg_net
  placeholder host odmietne, takže na čerstvej DB z gitu padá každý insert
  do `tenants`/`profiles`/`reservations`. Opravené migráciou 0016 (Vault).
- **Edge funkcie**: `CANCEL_TOKEN_SECRET ?? ""` v notify:322 aj cancel:63
  zlyháva otvorene (HMAC s prázdnym kľúčom podpisuje aj overuje);
  `escapeHtml`/`dayLabel`/`timeLabel`/`base64url` duplikované napriek
  `_shared/`; `JSON.parse(FIREBASE_SERVICE_ACCOUNT ?? "{}")` na module
  scope zhodí cold start; ~115 riadkov spiaceho FCM kódu; `cancel` píše
  do `reservations` priamo namiesto `cancel_reservation`; žiadny lock
  verzie supabase-js; žiadny `*_test.ts`.
- **Tenancy drobnosti**: `create_reservation` používa `v_caller.tenant_id`,
  ostatné `current_tenant_id()`; `reject_tenant` zmaže aj profil
  superadmina, ak je práve prepnutý do rušenej kuželne.
- **Klient vs server**: pravidlá horizont/limit/inPast/overlap sú vedome
  zrkadlené v Darte (0004:131) — bez spoločných fixtures. Klient používa
  lokálny čas, SQL `Europe/Prague`.
- **Testy**: 21 z 53 lib súborov bez testu (admin obrazovky, auth_gate,
  name_picker, day_pager_view, slot_tile, providers ako cieľ);
  `supabase/tests/tenancy_rls.sql` nie je v CI a nepokrýva superadmin.
  Na lokálnom stacku (CLI 2.109) navyše padá na chýbajúcich grantoch:
  `authenticated` nemá SELECT/INSERT/UPDATE/DELETE na tabuľkách v `public`
  (migrácie granty nezapisujú, prod ich má z hosted default privileges) —
  plán 2 musí granty explicitne pridať do migrácie, inak test v CI nepôjde.

### F. Mŕtvy kód a zastarané doc

- `week_screen.dart:16-18` `enum ScheduleView` + odkaz na neexistujúci
  `scheduleViewPrefKey`; `const fitWidth = true` (174) → celá
  horizontal-scroll vetva day_pager_view (420-449) nedosiahnuteľná.
- `DayPagerView.onLongPressBlock/onAddBlockInGap` nikdy nepredané →
  `_blockLabel` InkWell a `EmptyGapRow.onAdd` mŕtve.
- `KioskBoardView.onBooked` — shell predáva `() {}`; re-exporty
  calendar_board symbolov len kvôli testu.
- `matches_screen.dart:271` `const isMatch = true` a `type.isMatch ? … : ''`.
- Zastarané doc: slot_tile 1-5 a 232-237 (kiosk SlotTile nepoužíva),
  week_calendar_view:83 (snap 15 vs 5 min).
- SETUP.md: ručný seed bez `tenant_id` zlyhá, „prvý = admin“ neplatí,
  odkaz na neexistujúci `google-services.json.example`, chýba Sentry,
  `DEMO_PASSWORD`, superadmin, `config.toml`. CICD.md končí na 0011 a
  popisuje starý whatsnew mechanizmus. README neodkazuje na CICD/PLAY.

## Rozhodnutia

### 1. Osirelé rezervácie po zmene nastavení → server-side kaskáda

Zmena `lane_count`, `training_weekdays` alebo deaktivácia bloku dnes len
varuje v klientovi (`_countStranded`, `confirmIfBlockStrands`) a po
potvrdení necháva budúce rezervácie živé, ale neviditeľné: stále sa
počítajú do limitu hráča aj do dochádzky a nedajú sa zrušiť z mriežky.
Druhý klient alebo SQL editor varovanie obíde.

**Rozhodnutie:** trigger na `schedule_settings` a `time_blocks`, ktorý
budúce živé rezervácie mimo novej mriežky zruší rovnako, ako to už robia
kaskády pre prenájmy a prioritné sloty (`cancelled_via = 'admin'`,
`cancel_note = 'změna rozvrhu'`, s notifikáciou). Rešpektuje day
overrides (blok explicitne uvedený v `block_ids` dňa ostáva platný).
Klientske varovanie zostáva ako pre-flight UX. Implementácia v pláne 2
s SQL testom; predikát „blok platí v deň“ sa vytiahne z
`create_reservation` do helpera, aby obe strany mali jedno pravidlo.

### 2. Legacy stĺpec `profiles.club` → dropnúť

`register_profile` doň kopíruje meno klubu pri registrácii, ale
`set_player_club` mení len `club_id` — text zostarne po prvom preradení.
Čítajú ho `Profile.club` (Můj profil „Oddíl“, podtituly čakajúcich a
kiosk účtov v Hráči) a `players` view; `monthly_attendance` už používa
`coalesce(c.name, …)`.

**Rozhodnutie:** klient prestane text čítať hneď (plán 1, meno klubu
z `clubsProvider` cez `club_id`); v pláne 2 migrácia dropne stĺpec,
prestaví `players` view, `monthly_attendance` a `register_profile`
a zruší column grant `update (club)`.

## Poradie (každý bod = plán + PR)

1. **Quick wins** — `2026-09-02-cleanup-1-quick-wins.md`: mŕtvy kód (F),
   zastarané doc, `CANCEL_TOKEN_SECRET` fail-closed, `notify_webhook`
   z Vaultu (migrácia 0016 + SETUP/CICD), meno klubu z `clubs`.
2. **Backend hygiena** — `supabase/schema.sql` snapshot (`supabase db
   dump --schema public`) + `docs/SCHEMA.md` (tabuľky → politiky → RPC);
   explicitné granty pre `authenticated` v migrácii + `tenancy_rls.sql`
   do CI (`supabase start` + psql) a rozšíriť o superadmin; edge funkcie: `_shared` dedup, `cancel_token_test.ts`,
   FCM do `_shared/fcm.ts`, lock verzie supabase-js, FIREBASE parse
   lazy; kaskáda z rozhodnutia 1; drop `profiles.club` z rozhodnutia 2;
   zjednotiť `v_caller.tenant_id` vs `current_tenant_id()`; guard v
   `reject_tenant`.
3. **Doména nasáva pravidlá** — `canBook` v kiosku, `canCancel(isAdmin:)`,
   `isDayOpen`/`nextTrainingDay`, drop-fit matematika k `freeGapAt`,
   `domain/day_edit.dart` (plán úprav dňa z `block_dialog._save`),
   `bookableSlotCount(OpenDay)`, jedna funkcia štítkov udalostí, farebné
   páry v `domain/palette.dart`, `strandedCount`, club grouping, limity
   ako konštanty. Widget testy → unit testy.
4. **Dátová vrstva** — `weekScheduleProvider(monday)` (WeekSchedule +
   nameById + clubColorById), `nowProvider`, hodiny kiosku ako list
   widget, periodický refresh `playersProvider` namiesto ručných
   invalidate, `Api.deleteTimeBlock` bez `PostgrestException` vo widgete,
   `Api.restoreDayToTemplate`.
5. **UI dedup rozvrhu** — jeden `_DayColumn`
   (`widgets/schedule_day_column.dart`) s voliteľnými admin hookmi, kiosk
   lane row ako `SlotTile` variant, `ScheduleCallbacks` objekt,
   `WeekScreen.build` → `_WeekHeader` + `ScheduleActions`, zdieľané
   konštanty (lane row, header, gradient), `dayBands(DaySchedule)`.
6. **Admin scaffolding** — `AdminScaffold` (gate + AppBar + `.when` s
   `friendlyDbError`), `saveAndPop`/`FormDialog`, `confirmDelete`,
   `pickDay`, `PickerTile`, `LaneChips`, `ColorDot`; dialógy do
   `widgets/`; `ref.listen` namiesto init v build; `report_screen` na
   `FutureProvider.family`. Generický list screen nestavať.
7. **Dokumentácia** — SETUP.md prepísať (link + db push, Vault, Sentry,
   DEMO_PASSWORD, superadmin, `config.toml`), CICD.md aktualizovať
   (migrácie, whatsnew z `changelog_data.dart`, `SENTRY_DSN`), README
   odkazy na CICD/PLAY/SCHEMA; test, že `changelog_data` má záznam pre
   verziu z pubspec.

Mimo rozsahu (vedome): prepis state managementu, generický CRUD
framework, zmena histórie migrácií (len snapshot vedľa nej).

## Stav

- **Plán 1 (quick wins)** — merged 2026-09-02 (PR #50), 0016 na prode.
- **Plán 2 (backend hygiena)** — hotový 2026-09-02 na vetve
  `cleanup-2-backend`: migrácie 0017 (granty ako kód), 0018 (kaskáda
  osirelých rezervácií + `block_day_status` + guard v `reject_tenant`),
  0019 (drop `profiles.club`); `supabase/schema.sql` snapshot +
  `tool/schema_snapshot.sh`; `docs/SCHEMA.md`; CI job `backend`
  (snapshot diff, `tenancy_rls.sql`, deno check/test); edge funkcie:
  `_shared/format.ts` + `fcm.ts` (lazy parse), unit testy, supabase-js
  pinnutý cez import mapu. Vedome vynechané: zjednotenie
  `v_caller.tenant_id` vs `current_tenant_id()` (kozmetika, obe sú
  ekvivalentné) a prepis `cancel` EF na RPC (RPC vyžaduje `auth.uid()`).
  Nasadenie nepotrebuje žiadny ručný krok na prode.
- **Plán 3 (doména nasáva pravidlá)** — hotový 2026-09-02 na vetve
  `cleanup-3-domain`: `domain/day_edit.dart` (plánovač úprav dňa z
  `block_dialog`), `labels.dart`, `limits.dart`, `grouping.dart`,
  `canCancel(isAdmin:)`, `bookableSlotCount`, `isDayOpen`/`nextTrainingDay`
  v doméne, `dropFits`, `clubTint`; kiosk rešpektuje limit rezervácií.
  266 testov. Vynechané: swatche v clubs/slot_types/color_picker,
  `move_reservations_dialog` lane pravidlá.
- **Plán 4 (dátová vrstva)** — hotový 2026-09-02 na vetve `cleanup-4-data`:
  `nowProvider` (jedny hodiny, kiosk timer preč), `weekScheduleProvider`
  (`WeekView` pre week screen aj kiosk), `playersProvider` sa obnovuje sám,
  `Api.deleteTimeBlock → bool`, `Api.restoreDayToTemplate`. 272 testov.
  Vynechané: side effecty v build (anchor `jumpTo`, kiosk `_window`),
  `move_reservations_dialog` `ref.read` v build.
- **Plán 5 (UI dedup rozvrhu)** — hotový 2026-09-02 na vetve `cleanup-5-ui`:
  jeden `ScheduleDayColumn` (týždenný kalendár + kiosk), kiosk lane rows ako
  `SlotTile` row variant, `WeekHeader` + `ScheduleActions` z `WeekScreen`,
  `SlotCallbacks`/`CalendarAdminHooks`, zdieľané konštanty. 272 testov bez
  zmeny. Vynechané: anchor `jumpTo` z build, kiosk `_window` snapshot.
- **Plán 6 (admin scaffolding)** — hotový 2026-09-02 na vetve
  `cleanup-6-admin`: `AdminScaffold` + `AsyncBody` (chyby už nie sú „Zatím
  žádné…"), `FormDialog`, `PickerTile`/`LaneChips`/`ColorDot`, `pickDay`,
  `confirmDelete`, `attendanceProvider`; dialógy v `admin/widgets/`;
  `ref.listen` namiesto init v build. 301 testov (+19 smoke testov
  obrazoviek). Tým je roadmap auditu kompletná.
- **Plán 7 (dokumentácia)** — hotový 2026-09-02 na vetve `cleanup-7-docs`
  (paralelne s plánom 6): SETUP.md (registrácia po kuželniach + superadmin
  bootstrap, `config push`, Sentry, lokálny vývoj, preč s neexistujúcim
  google-services.json.example), CICD.md a PLAY.md (release notes z
  `changelog_data.dart`, `SENTRY_DSN`), `test/changelog_test.dart`.

