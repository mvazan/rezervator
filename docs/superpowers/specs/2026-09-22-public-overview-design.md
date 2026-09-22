# Rezervátor — veřejný přehled rozvrhu

*Stav k 2026-09-22, verze 1.2.7+11, migrace 0001–0042.*

## Proč

Rozvrh kuželny dnes uvidí jen přihlášený a schválený hráč (nebo kiosk).
Kdo se chce jen podívat, jestli je ve čtvrtek volno — host, rodič, nový
zájemce — nemá jak. Chceme **veřejnou, read-only stránku** na
rezervator.online, kterou si každá kuželna může sama zapnout.

## Rozhodnutí

- **Self-service.** Slug i zapnutí nastavuje správce kuželny sám v Správa,
  ne superadmin při schvalování. Vypnuto je výchozí stav — nic se nezveřejní
  bez vědomého kliknutí.
- **Jen obsazenost, bez jmen.** Obsazená dráha je „Obsazeno" v barvě oddílu
  hráče (barva klubu zůstává, jméno ne). Pronájem je také „Obsazeno" — bez
  jména nájemce a poznámky. Zápasy a blokace se ukazují celé (rozpis je
  veřejný).
- **Procházení týdnů** jako v appce (šipky), nic dalšího — žádné přihlášení,
  žádná akce.
- **Adresa:** `https://rezervator.online/#/prehled/<slug>`. Web běží na
  GitHub Pages s hash URL strategií; hash cesta nepotřebuje serverový rewrite.

## Datový model — migrace `0043_public_overview.sql`

```sql
alter table tenants
  add column public_slug text unique
    check (public_slug ~ '^[a-z0-9]([a-z0-9-]{1,38}[a-z0-9])?$'),
  add column public_enabled boolean not null default false,
  add constraint tenants_public_needs_slug
    check (not public_enabled or public_slug is not null);
```

Slug: 3–40 znaků, malá písmena bez diakritiky, číslice, pomlčka uvnitř.
Grant `select (id, name)` na `tenants` pro `authenticated` se **nerozšiřuje** —
nové sloupce čtou jen RPC níže.

## RPC

Všechny `security definer`, `set search_path = public`.

1. **`public_tenant_id(p_slug text) returns uuid`** — interní pomocník:
   tenant se slugem **a** `public_enabled`, jinak `raise 'unknown_tenant'`.
   Neexistující i vypnutý slug dávají **stejnou** chybu (nejde zjistit, které
   slugy existují). `revoke all … from public, anon, authenticated`.

2. **`public_week(p_slug text, p_monday date) returns jsonb`** — jediná
   funkce volatelná z `anon` (i `authenticated`). Vrací:
   - `tenant_name`
   - `settings` — řádek `schedule_settings` (`to_jsonb(…) - 'tenant_id'`,
     ať ho přečte existující továrna; nic citlivého v něm není)
   - `blocks`, `overrides` (týden `p_monday … +6`), `priority_slots` (týden;
     zápasy i blokace celé)
   - `rentals` — platné v týdnu, s `renter_name = ''` a `note = ''`
   - `occupied` — pole `{block_id, date, lane, club_color}` pro nezrušené
     rezervace týdne; `club_color` = `clubs.color` klubu hráče, `-1` bez
     klubu. **Žádné `player_id`, jméno ani id rezervace.**

   Klíče kopírují sloupce DB (`to_jsonb` řádku / výběr sloupců), aby je
   přečetly existující `fromJson` továrny. `p_monday` se normalizuje na
   pondělí (`date_trunc('week', …)`), rozsah je vždy 7 dní.

3. **`set_public_overview(p_slug text, p_enabled boolean) returns void`** —
   jen správce vlastní kuželny (`is_admin()`, `current_tenant_id()`), jinak
   `not_allowed`. Slug se před uložením `lower(trim(…))`; prázdný → `null`.
   Chyby: `check_violation` → `invalid_slug`, `unique_violation` →
   `slug_taken`, zapnutí bez slugu → `invalid_slug`.
   `revoke all … from public, anon`.

4. **`my_public_overview() returns table(public_slug text, public_enabled
   boolean)`** — správce čte nastavení své kuželny (jiný než admin →
   `not_allowed`). `revoke all … from public, anon`.

Pozor na default privileges z 0017: `execute` na nové funkce dostane `anon`
automaticky — každá kromě `public_week` ho musí explicitně odebrat.

## Appka

### Veřejná stránka

- **Route:** `GoRoute(path: '/prehled/:slug')` vedle `/` a `/kiosk-login`
  v `lib/main.dart`; mimo `AuthGate`, funguje bez session.
- **`Api.publicWeek(slug, monday)`** → `PublicWeek` (nový model v
  `lib/domain/public_week.dart`: `tenantName`, `settings`, `blocks`,
  `overrides`, `prioritySlots`, `rentals`, `occupied`).
- **Adaptér** `publicReservations(occupied)` (čistá funkce, tamtéž): z každého
  obsazeného místa syntetická `Reservation` s `id = playerId =
  'pub-<block>-<date>-<lane>'`, `created_via = 'public'`; k tomu
  `nameById` → vše „Obsazeno" a `clubColorById` → `club_color` podle
  syntetického id.
- **`PublicScheduleScreen`** (`lib/features/public/public_schedule_screen.dart`):
  drží `weekOffset`, data přes `FutureProvider.family<PublicWeek, (String,
  Day)>`, vykreslí `WeekHeader(trailing: const [])` + `WeekCalendarView(me:
  null, interactive: false, …)` s nečinnými `SlotCallbacks` a
  `CalendarAdminHooks.none`. Stav načítání/chyby přes `AsyncBody`.
  Titulek = název kuželny. Znovupoužité `buildWeekSchedule` — žádná vlastní
  logika rozvrhu.
- `unknown_tenant` → „Tahle kuželna veřejný přehled nemá." (na této stránce
  vlastní text místo obecného „Tahle kuželna už neexistuje.").
- Bez realtime: stránka se načte při otevření a při přepnutí týdne; tlačítko
  obnovit není potřeba (F5).

### Správa

- **Nová položka v hubu Správa:** *Veřejný přehled*
  (`lib/features/admin/public_overview_screen.dart`, `AdminScaffold`).
- Obsah: přepínač *Zveřejnit přehled*, pole *Adresa* (slug, s náhledem
  `rezervator.online/#/prehled/<slug>`), tlačítko **Uložit** (volá
  `set_public_overview`), po uložení se zapnutým přehledem **Kopírovat odkaz**.
- Kořen URL přes sdílenou logiku z `core/kiosk_url.dart` (vytáhnout
  `appRootUrl(Uri)`, kterou použije `kioskUrlFrom` i nový `publicUrlFrom(Uri,
  slug)`) — žádné kopírování.
- Návrh slugu při prázdném poli: název kuželny bez diakritiky, malými
  písmeny, mezery → pomlčky (jen předvyplnění, uloží se až tlačítkem).
- `friendlyDbError` += `'invalid_slug': 'Adresa smí mít 3–40 znaků: malá
  písmena, číslice a pomlčky.'`, `'slug_taken': 'Tuhle adresu už má jiná
  kuželna.'`.

## Changelog

Do `changelog_data.dart` do web-only dávky `Release(null, '22. 9. 2026', …)`
(nebo nové, podle dne nasazení):

> Veřejný přehled: správce ho zapne v Správa → Veřejný přehled a kuželna
> dostane vlastní adresu, kde kdokoli uvidí rozvrh bez přihlášení — jen
> obsazenost, bez jmen.

## Testy

**SQL** (`supabase/tests/tenancy_rls.sql`, styl `do $$ … raise notice 'OK: …'`):
- vypnutý i neexistující slug → stejná chyba `unknown_tenant`;
- zapnutý: `public_week` vrátí obsazená místa s `club_color`, a výstup
  (`::text`) neobsahuje `player_id` hráče, jméno nájemce ani poznámku;
  zrušená rezervace ve výstupu není; data jiného tenantu tam nejsou;
- `anon` smí `public_week`, nesmí `set_public_overview`,
  `my_public_overview`, `public_tenant_id` (`has_function_privilege`);
- `set_public_overview`: ne-admin → `not_allowed`; špatný formát →
  `invalid_slug`; slug jiné kuželny → `slug_taken`; zapnutí bez slugu →
  `invalid_slug`; úspěch mění jen vlastní tenant.
- Každý blok falzifikovat (vrátit grant / vynechat maskování).
- `tool/schema_snapshot.sh` → `supabase/schema.sql`; `docs/SCHEMA.md` doplnit.

**Dart:**
- `publicReservations`: id, jméno „Obsazeno", barva klubu;
- `PublicWeek.fromJson` na vzorku odpovědi RPC;
- `PublicScheduleScreen`: vykreslí „Obsazeno" a zápas, ťuknutí na buňku
  nic neotevře, šipky mění týden (volá RPC s dalším pondělím),
  `unknown_tenant` → vlastní text;
- `PublicOverviewScreen`: uložení volá RPC se slugem a přepínačem, chyba
  ukáže `friendlyDbError`, odkaz ke kopírování má správný tvar;
- `appRootUrl` / `publicUrlFrom` a beze změny `kioskUrlFrom`.

## Mimo rozsah

- Vlastní doména / path URL bez `#`.
- Denní pohled, realtime, SEO, embed do cizího webu.
- Superadmin přehled slugů (dá se kdykoli dotázat v SQL).
