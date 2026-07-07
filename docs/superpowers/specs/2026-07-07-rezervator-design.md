# Rezervátor — rezervačný systém tréningov na kolkáreň

## Kontext

Nový samostatný projekt (repo `~/Home/rezervator`, vlastný Supabase projekt) pre jednu kolkáreň s ≤50 registrovanými hráčmi z viacerých klubov. Jedinečnosť: **dva režimy** — klasická appka/web s prihlásením a **kiosk na kolkárni** (tablet, bez prihlásenia, na dôveru) s poistkou „ak si to nebol ty, jedným klikom zrušíš". Stack a vzory sa preberajú z overeného súrodenca **Termínátor** (`~/Home/terminator`): Flutter + Riverpod + Supabase (Postgres/RLS/Realtime/magic-link/Edge Functions), tentokrát **aj s web targetom**.

Schválené požiadavky:
- Rozvrh = mriežka **čas × dráha**; počet dráh, časové bloky, tréningové dni v týždni, horizont rezervácií aj limit na hráča **konfigurovateľné adminom**; override pre konkrétny deň (iné bloky / zavreté s dôvodom). Zavreté dni zobrazujú dôvod + zápasy (fanúšikovia vidia, kto hrá).
- Kiosk: **len vytvorenie rezervácie**, flow „najprv hráč, potom termíny" (detail v sekcii Kiosk UX). Rušenie len v appke/webe alebo cez odkaz.
- Notifikácia po kioskovej rezervácii: **push ak má appku, inak e-mail** (Resend), vždy s jednoklikovým zrušením.
- Auth: magic link + schválenie adminom; prvý registrovaný = admin (founder pattern).
- Zápasy: ručný formulár (import zväzového formátu odložený — v `matches` rezervované pole `import_key`).
- Prenájmy: admin, jednorazové aj týždenne opakujúce sa, na vybrané dráhy.
- Dochádzka: nezrušená rezervácia = účasť; admin môže dodatočne zrušiť no-show. Mesačný report + CSV.
- Hosting: web na GitHub Pages, kiosk = Fully Kiosk Browser na tablete. Hobby projekt, free tiers, **CZ UI** (jednojazyčné).
- iOS: teraz sa nestavia ani netestuje, ale projekt sa scaffolduje aj s `ios/` priečinkom a kód sa píše platform-guarded (ako Termínátor — push/deep-link iOS-ready). iPhone užívatelia medzitým používajú web/PWA (notifikácie im chodia e-mailom). Neskoršie zapnutie iOS = konfigurácia, nie kód: Apple Developer účet ($99/rok), URL scheme v Info.plist, APNs kľúč do Firebase, signing + TestFlight.

## Architektúra

Jeden Flutter codebase (`main.dart`, go_router — web potrebuje URL routing), tri podoby: Android APK, web pre hráčov, kiosk (web na tablete). Kiosk shell sa vyberá podľa `profile.role == 'kiosk'` — RLS je zámok, UI len fasáda. **Virtuálny rozvrh**: žiadne materializované sloty; týždeň sa počíta čistou Dart funkciou z konfigurácie + výnimiek + zápasov + prenájmov + rezervácií.

### DB schéma (Supabase, jedna migrácia `0001_schema.sql` v štýle Termínátora)

- `profiles` — id (FK auth.users), display_name, club, email, **role** ('player'|'admin'|'kiosk'), status ('pending'|'approved'), fcm_token, approved_by/at. Admin = stĺpec role (žiadne JWT claims), helper `is_admin()` ako Termínátorov `is_approved()`.
- `schedule_settings` — singleton: lane_count, training_weekdays smallint[] (ISO), booking_horizon_days, max_active_reservations.
- `time_blocks` — id uuid, starts_at/ends_at time, position, active (deaktivácia namiesto mazania; FK restrict).
- `day_overrides` — date PK, closed bool, reason, block_ids uuid[] null (null = default bloky; môže odkázať aj na neaktívne „špeciálne" bloky).
- `reservations` — player_id, date, block_id, lane, created_via ('app'|'kiosk'|'admin'), created_by, cancelled_at/via ('app'|'one_click'|'admin'), cancel_note. **Dvojrezervácia:** partial unique index `(date, block_id, lane) where cancelled_at is null` → prehratý race = priateľská chyba „obsadené".
- `matches` — date, starts_at/ends_at, opponent, description, **import_key text unique null** (idempotencia pre budúci import). Zápas blokuje všetky dráhy.
- `rentals` — renter_name, lanes smallint[], date (jednorazový) XOR weekday (opakujúci), starts_at/ends_at, valid_from/valid_until, note.

RPCs (security definer): `register_profile` (prvý užívateľ = auto-approved admin), `approve_player`, `set_role`, **`create_reservation`** (jediná cesta zápisu; validuje deň otvorený, blok platný, dráhu, kolízie so zápasmi/prenájmami, horizont, limit hráča — admin výnimky; kiosk smie rezervovať pre kohokoľvek schváleného, hráč len pre seba), **`cancel_reservation`** (vlastník do začiatku bloku; admin kedykoľvek = no-show marking), `set_day_override` (upsert + zrušenie kolidujúcich rezervácií), `monthly_attendance(year, month)`.

Triggery: `cancel_conflicting_reservations()` after insert/update na matches+rentals (nikto nie je ticho double-booked); pg_net webhook → Edge Function `notify` (vzor Termínátor) na profiles INSERT a reservations INSERT/UPDATE.

RLS: čítanie rozvrhových tabuliek `is_approved_or_kiosk()`; `reservations` **bez priamych insert/update — len RPC**; admin CRUD na matches/rentals/blocks/settings/overrides; view **`players`** (id, display_name, club z approved profiles) — jediné, čo kiosk vidí z profilov (žiadne e-maily/tokeny).

### Kiosk bezpečnosť

Vyhradené auth konto `kiosk@…` s heslom (password provider len preň), `set_role(uid,'kiosk')`. Prihlási sa raz, session sa drží v localStorage. Smie: čítať rozvrh + `players` view, volať `create_reservation`. Nesmie: rušiť, meniť, čítať profily. Ukradnutý tablet → len falošné rezervácie, ktoré sa samy hlásia dotknutým hráčom; kill switch = zmazať/resetnúť kioskové konto.

### Kiosk UX

Celá obrazovka = týždenný rozvrh (mriežka čas × dráha). Hore stavový riadok: hodiny, aktuálne info z kolkárne (dnešné zápasy / dôvod zatvorenia / najbližší tréning) a tlačidlo **„Rezervovať"**. (Pozícia hore/dole je jedna konštanta — ľahko preklopiteľná.)

Flow rezervácie — najprv hráč, potom termíny:
1. Tap na „Rezervovať" → **adaptívny výber mena po písmenách**: obrazovka ukáže prvé písmená mien schválených hráčov; tap na písmeno → dvojpísmenové prefixy… drill-down pokračuje, kým sa zostávajúce mená nezmestia na obrazovku — vtedy sa zobrazia celé mená. Počet úrovní je dynamický podľa zloženia mien (pri ≤50 hráčoch typicky 1–2 úrovne).
2. Po výbere mena sa kiosk prepne do režimu vybraného hráča: banner **„Rezervuje: Ján Novák [✕]"**, v mriežke sa zvýraznia voľné termíny.
3. Tap na voľný termín → potvrdzovací dialóg („Ján Novák · streda 15. 7. · 18:00–19:00 · dráha 2 — Rezervovať?") → zápis cez `create_reservation` + notifikácia. Hráč môže hneď ťukať ďalšie termíny (limit na hráča stráži RPC).
4. Deselect: tap na ✕ v banneri alebo **60 s nečinnosti** (timeout resetuje aj rozrobený výber mena).

Doménová logika výberu mien = čistá Dart funkcia `domain/name_index.dart`: `(zoznam mien, kapacita obrazovky) → uzol s prefixami alebo menami`, unit-testovaná (krátke mená, diakritika, nerovnomerné rozloženie prefixov).

### Jednoklikové zrušenie

Stateless HMAC token `base64url({rid, exp}).podpis` (secret `CANCEL_TOKEN_SECRET`), platnosť do začiatku bloku. Edge Function `cancel` (`--no-verify-jwt`): **GET = potvrdzovacia stránka s tlačidlom, POST = zrušenie** (GET/POST split kvôli e-mailovým prefetch skenerom). Push variant token nepotrebuje — appka má session.

### Notifikácie (Edge Function `notify`)

Rozhodnutie: `fcm_token != null` → FCM HTTP v1 push (kód prevziať z terminator/supabase/functions/notify/index.ts takmer doslova, vrátane čistenia neplatných tokenov); inak e-mail cez **Resend** REST API. Tri druhy: `pending_player` (adminom), `kiosk_booking` (hráčovi, so zrušovacím odkazom), `admin_cancelled` (len pri budúcom dátume — retro no-show sa neposiela). Bez notification-prefs tabuľky, bez web pushu (YAGNI); FCM voliteľné ako v Termínátore.

### Doménová vrstva (pure Dart, unit-tested — najvyššia hodnota TDD)

`domain/schedule.dart`: `buildWeekSchedule({monday, today, settings, blocks, overrides, matches, rentals, reservations}) → WeekSchedule` so sealed `DaySchedule` (ClosedDay/OpenDay) a `SlotState` (Free/Reserved/Rented/Match + inPast/beyondHorizon). Poradie riešenia: override → weekday rule → zápas (celý riadok) → prenájom (dráha ∩ + čas ∩, opakovanie podľa ISO weekday vo valid okne) → rezervácia → voľné. Companion `canBook(...)` zrkadlí pravidlá RPC pre poctivé UI. `Day`/`HourMinute` skopírovať z terminator/lib/domain/models.dart. Ďalej `attendance.dart`, `csv.dart` (UTF-8 BOM + `;` pre CZ Excel).

### Realtime

Publication: reservations, day_overrides, matches, rentals, time_blocks, schedule_settings, profiles. `reservationsProvider` ako **family podľa pondelka týždňa** (bounded stream aj po sezónach); ostatné whole-table (desiatky riadkov). `players` view = FutureProvider s refetchom (views nestreamujú). Kiosk aj mobil sledujú ten istý stream → zmena viditeľná do ~1 s.

### Štruktúra repa

```
rezervator/
├── lib/{main.dart, config.dart, core/ui.dart, data/providers.dart,
│        domain/{models,schedule,name_index,attendance,csv}.dart,
│        features/{auth,schedule,kiosk,admin}/, push/push.dart}
├── supabase/{migrations/0001_schema.sql, functions/{notify,cancel}/index.ts}
├── test/domain/
├── web/  (PWA manifest)
├── .github/workflows/{deploy-web.yml, apk.yml, keepalive.yml}
└── SETUP.md
```

Predlohy z Termínátora: `lib/config.dart` (dart-defines + NotConfigured screen), `lib/data/providers.dart` (streams + static Api), `lib/features/auth/auth_gate.dart` (rozšíriť o kiosk vetvu), `supabase/migrations/0001_schema.sql`, `supabase/functions/notify/index.ts`, `lib/push/push.dart` (guard `kIsWeb`), SETUP.md/CICD.md štýl.

## Fázy výstavby (každá končí demom)

0. **Skeleton** — `flutter create` (android+web), kompletná `0001_schema.sql`, auth flow (login → register → waiting → gate, prvý = admin), statická mriežka, deploy na Pages. *Demo: prihlásenie web+mobil, admin schváli druhé konto.*
1. **Rezervácie** — `domain/schedule.dart` + kompletné testy (TDD; zavreté dni, overridy s neaktívnymi blokmi, kolízie, opakované prenájmy, horizont/limit), week grid + booking sheet + RPCs + realtime. *Demo: dva telefóny, rezervácia sa objaví live; race → „obsadené".*
2. **Admin konzola** — settings, bloky, overridy, zápasy, prenájmy, hráči (approve/role), conflict-cancel triggery. *Demo: admin zavrie štvrtok s dôvodom, kolidujúca rezervácia sa zruší.*
3. **Notifikácie + one-click cancel** — `notify` + `cancel` Edge Functions, pg_net triggery, Resend. (Zámerne PRED kioskom — „nebol si to ty?" mail je jeho poistka.) *Demo: admin-cancel pošle CZ e-mail, odkaz zruší bez prihlásenia.*
4. **Kiosk** — kioskové konto + policies, `/kiosk-login`, `domain/name_index.dart` + testy, KioskShell (fullscreen rozvrh + stavový riadok s hodinami/infom/tlačidlom, adaptívny výber mena po písmenách, banner vybraného hráča s ✕, confirm dialog, viacnásobné rezervácie, 60 s idle reset), Fully Kiosk na tablete. *Demo: na tablete výber mena cez písmená, dve rezervácie za sebou, e-mail príde, klik ju zruší.*
5. **Reporty + hardening** — `monthly_attendance` + admin obrazovka + CSV export (file_saver), retro no-show akcia v admin dennom pohľade, APK s FCM, keepalive workflow, finálny SETUP.md.

## Overenie

- **Doménové testy**: `flutter test` — schedule (najkritickejšie: overridy, kolízie, opakovanie prenájmov, horizont/limit), name_index (drill-down po písmenách), attendance, csv.
- **E2E po fáze 1**: dve sessions (web + `flutter run` na zariadení/emulátore), súčasná rezervácia toho istého políčka → jedna prejde, druhá „obsadené"; realtime propagácia.
- **RLS testy**: cez SQL editor overiť, že kiosk rola nevidí `profiles.email` a nedokáže volať `cancel_reservation`; hráč nedokáže rezervovať za iného.
- **Edge Functions lokálne**: `supabase functions serve` — notify (push/e-mail vetvenie), cancel (GET nezruší, POST áno, expirovaný token nie).
- **Kiosk UX**: web build na tablete/prehliadači, celý flow meno→termín→potvrdenie→notifikácia.

## Mimo rozsahu (YAGNI)

Multi-venue, platby, čakacie listiny, iCal import (len `import_key` rezervovaný), notifikačné preferencie, web push, iOS build (kód ostáva iOS-ready, viď Kontext).
