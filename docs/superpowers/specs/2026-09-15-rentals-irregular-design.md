# Rezervátor — nepravidelné pronájmy (jeden nájemce, víc termínů)

*Stav k 2026-09-15, verze 1.2.6+10, migrace 0001–0040.*

## Proč

Nájemce, který si dráhy bere opakovaně, ale nepravidelně — jednou ve čtvrtek,
pak za dva týdny v sobotu — dnes znamená tolik pronájmů, kolik má termínů.
Každý se zakládá znovu: jméno, barva, dráhy, čas. A když se firma přejmenuje,
obejít se musí všechny.

Chceme jeden pronájem, který **obsahuje víc termínů**, každý s vlastním časem
a drahami.

## Co už v appce je (a nebude se stavět znovu)

Při průzkumu se ukázalo, že dvě třetiny původního zadání existují:

- **Jednorázový pronájem.** `RentalDialog` má přepínač *Jednorázový / Týdenní*
  a DB drží `check ((date is null) <> (weekday is null))` už od migrace 0001.
- **Výběr termínu kalendářem.** `PickerTile` → `pickDay` → Material
  `showDatePicker`, plnohodnotný měsíční kalendář.
- **Oddělené řazení.** `_compareRentals` řadí jednorázové první podle data,
  pak týdenní podle dne v týdnu — jen bez vizuálního předělu.

Nové je tedy **jen** seskupení víc termínů pod jeden pronájem a viditelné
oddělení pravidelných od nepravidelných.

## Rozhodnutí

**Pravidelné a nepravidelné jsou dvě různé věci, ne dva režimy jedné.**
Týdenní série je *pravidlo*: neohraničené (`valid_until` smí být prázdné),
takže její termíny nejdou vypsat. Nepravidelný pronájem je *seznam*: konečný,
vyjmenovaný. Dialog, který obojí cpe do jednoho formuláře, vždycky trochu lže.

**Skupina stojí nad jednorázovými pronájmy, nenahrazuje je.** Každý termín
zůstane obyčejný jednorázový řádek v `rentals` — s vlastním datem, časem
a drahami. Skupina drží jen identitu nájemce.

Tím se nemění nic v tom, jak pronájem blokuje rezervace. To je hlavní důvod
téhle volby: `rental_occurrences` je funkce, přes kterou jde **každá** kontrola
kolizí i rušení rezervací při změně rozvrhu. Alternativa (hlavička přes
`parent_id`) by vyžadovala zvolnit tři omezení v `rentals` a přepsat tenhle
resolver tak, aby děti hlavičky platily samy o sobě — dnes dítě sérii jen
*upravuje*. Za čistší diagram to nestojí.

**Poznámka patří termínu, ne skupině.** Identita nájemce je jméno a barva;
poznámka bývá ke konkrétní akci („bez rozbrusu").

## Datový model — migrace `0041_rental_groups.sql`

### Tabulka

```sql
create table rental_groups (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null default current_tenant_id()
    references tenants (id) on delete cascade,
  renter_name text not null,
  color smallint not null default -2,
  created_by uuid not null references profiles (id),
  created_at timestamptz not null default now()
);
```

RLS přesně podle vzoru `rentals` (0005:692–704): select
`tenant_id = current_tenant_id() and is_approved_or_kiosk()`, insert/update/
delete `… and is_admin()`. Grants: přidat do výčtu v 0017 (`0017_table_grants`
dává `select, insert, update, delete` roli `authenticated`; RLS pak rozhoduje).
Realtime: `alter publication supabase_realtime add table rental_groups`.

### Vazba

```sql
alter table rentals
  add column group_id uuid references rental_groups (id) on delete cascade,
  add constraint rentals_group_shape_check check (
    group_id is null or (date is not null and parent_id is null));
```

Do skupiny smí **jen jednorázový řádek, který není výjimkou**. To je hranice
mezi pravidelným a nepravidelným zapsaná v DB, ne jen v UI.

`group_id` je **nepovinné**: dnešní jednorázový pronájem bez skupiny je
pronájem s jedním termínem. Žádný backfill.

Index `create index rentals_group_idx on rentals (group_id) where group_id is not null;`

### Propagace jména a barvy

```sql
create or replace function rental_group_changed() returns trigger …
  update rentals set renter_name = new.renter_name, color = new.color
  where group_id = new.id
    and (renter_name is distinct from new.renter_name
         or color is distinct from new.color);
```
`after update on rental_groups for each row`, vzor `rental_series_changed`
(0021). Denormalizovaná kopie na řádku **musí** zůstat: `rental_occurrences`
vrací `renter_name` tabuli i kiosku a nesmí kvůli tomu joinovat dál.

### RPC `rental_add_date`

Jediná operace, která sahá na víc řádků najednou — přidání termínu k pronájmu,
který skupinu ještě nemá: vznikne skupina a existující řádek si ji osvojí.

```sql
create or replace function rental_add_date(
  p_rental uuid, p_date date, p_starts_at time, p_ends_at time,
  p_lanes smallint[], p_note text default '')
returns uuid            -- id nového termínu
language plpgsql security definer set search_path = public
```

Chování: `not_authenticated` bez session; `not_allowed` když `not is_admin()`;
`unknown_rental` když `p_rental` není v tenantu volajícího, má `parent_id`
nebo `weekday` (týdenní série termíny nepřidává — má výjimky). Pak: když
zdrojový řádek nemá `group_id`, založí `rental_groups` z jeho `renter_name`
a `color` a přiřadí ji zdrojovému řádku; nakonec vloží nový řádek `rentals`
se stejným `group_id`, `renter_name`, `color` a předanými datem, časem,
drahami a poznámkou. Celé v jedné transakci.

Ostatní zápisy (založení skupiny, úprava termínu, mazání) jdou přímo přes RLS
jako dnes — RPC je tu kvůli atomicitě, ne kvůli oprávněním.

## Co se nemění

`rental_occurs`, `rental_occurrences`, `rental_conflicts`, `create_reservation`,
`move_reservation`, kaskáda z 0018 ani `rentalsOn` na klientu. Termín ve
skupině **je** jednorázový pronájem; že ho někdo drží za ruku, resolver nezajímá.

Výjimky týdenních sérií (0021) zůstávají beze změny a se skupinami se nepotkají
— omezení výše je drží odděleně.

## Appka

### Doména — `lib/domain/rental_groups.dart` (nový)

Třída `RentalGroup { String? id; String renterName; int color; List<Rental>
dates; }` (`id == null` = jednorázový pronájem bez skupiny) a čistá funkce,
kde žije veškerá logika seskupení:

```dart
List<RentalGroup> rentalGroupsOf(List<Rental> rentals, {required Day today})
```
Z plochého seznamu udělá skupiny: řádky s `group_id` sloučí, jednorázové bez
skupiny vrátí jako skupinu o jednom termínu, výjimky a týdenní série vynechá. Termíny
uvnitř chronologicky. Skupiny seřazené podle **nejbližšího nadcházejícího**
termínu; skupiny, které mají všechno za sebou, na konec (pravidlo „chronologicky,
proběhlé sbalené" jako jinde v appce).

### Providery a `Api`

- `rentalGroupsProvider = StreamProvider<List<RentalGroup>>` nad
  `cachedRows(uid, 'rental_groups', …)`, přidat do `resetTenantScopedProviders`.
- `Api.saveRentalGroup({id, renterName, color})`, `Api.deleteRentalGroup(id)`,
  `Api.addRentalDate(...)` (volá RPC výše).
- `friendlyDbError` += `'unknown_rental': 'Tenhle pronájem už neexistuje.'`

### Obrazovka `rentals_screen.dart`

Jeden seznam, dva nadpisy (`titleSmall`, vzor `my_trainings_screen.dart`):

- **Pravidelné** — týdenní série, dlaždice beze změny včetně Výjimek.
- **Nepravidelné** — skupiny. Dlaždice: jméno nájemce; podtitul první dva
  termíny (`3. 10. · 18:00–20:00 · dráhy 1, 2`) a u delších „…a další 3".
  Akce: **Termíny**, **Upravit** (jméno, barva), **Smazat** — potvrzení
  pojmenuje počet termínů, které tím zmizí.

Tlačítko **Přidat** se nejdřív zeptá *Pravidelný / Nepravidelný* a otevře
příslušný dialog.

### Dialogy

Nové `RentalDatesDialog` (seznam termínů skupiny s přidáním, úpravou, mazáním)
a `RentalDateDialog` (jeden termín: datum kalendářem, čas, dráhy, poznámka;
nový termín předvyplněný podle posledního).

**`RentalExceptionsDialog` ani `RentalOccurrenceDialog` se nerecyklují** — jsou
srostlé s logikou série (přeskočení dne, „série se vrátí k pravidelnému
pronájmu", nabídka dat ze série). Sdílené jsou primitivy, které už existují
v `form_fields.dart`: `PickerTile`, `LaneChips`, `FormDialog`.

`RentalDialog` ztrácí přepínač režimu: z rozcestníku přijde buď jako týdenní,
nebo jako nepravidelný. **Nepravidelný založí jen řádek `rentals` bez skupiny**
— skupina vzniká teprve druhým termínem, přes `rental_add_date`. Prázdná
skupina tak nemůže vzniknout a jednorázový pronájem zůstává tím, čím dnes je.

### Changelog

`'Nepravidelný pronájem: jeden nájemce, víc termínů — každý s vlastním časem '
'a drahami. Pronájmy jsou nově rozdělené na pravidelné a nepravidelné.'`

## Testy

### Dart

- `test/domain/rental_groups_test.dart` — seskupení a řazení: dva řádky se
  stejným `group_id` dají jednu skupinu; jednorázový bez skupiny dá skupinu
  o jednom; výjimka a týdenní série se nezapočítají; skupiny podle nejbližšího
  budoucího termínu; skupina s termíny jen v minulosti je poslední.
- `test/features/rentals_screen_test.dart` — obě sekce se vykreslí pod svými
  nadpisy; skupina ukáže počet termínů; Přidat otevře rozcestník; Smazat
  pojmenuje počet termínů.
- `test/features/rental_dates_dialog_test.dart` — přidání volá
  `addRentalDate` s vybraným datem; úprava volá `saveRental`; mazání
  potvrzuje; selhání ukáže `friendlyDbError`.

### SQL (`supabase/tests/tenancy_rls.sql`, končí `ROLLBACK`)

Každý blok stylem `do $$ … raise notice 'OK: …'`, fixtury A/B/kiosk jako jinde.

1. **Práva.** `authenticated` čte jen skupiny svého tenantu, zapisuje jen jako
   admin; `anon` nic. Falzifikace: odebrat policy.
2. **Tvar.** Omezení odmítne ve skupině týdenní sérii i výjimku
   (`rentals_group_shape_check`). Falzifikace: odebrat constraint.
3. **Propagace.** Přejmenování skupiny přepíše `renter_name` jejích řádků;
   změna barvy totéž. Falzifikace: odebrat trigger.
4. **RPC.** `rental_add_date` na pronájmu bez skupiny ji založí a osvojí oba
   řádky; na týdenní sérii a cizím tenantu vrátí `unknown_rental`; neadmin
   `not_allowed`. Falzifikace: vrátit tělo na prostý insert.
5. **Kolize beze změny.** Termín ve skupině blokuje `create_reservation`
   stejně jako osamělý jednorázový pronájem (`blocked_by_rental`), a smazání
   skupiny ty sloty uvolní. **Tohle je důkaz, že `rental_occurrences` opravdu
   nebylo potřeba měnit.**

`tool/schema_snapshot.sh` → `supabase/schema.sql`, `'rental_groups'` do pole
`v_streamed`, řádek tabulky a odstavec do `docs/SCHEMA.md`.

## Známé meze (schválně)

- **Skupina nedrží týdenní série.** Nájemce, který má zároveň pravidelný
  čtvrtek i nárazové soboty, bude mít dvě položky. Sloučit je jde později
  přidáním `group_id` i sériím — omezení stačí zvolnit, nic přepisovat.
- **Nepravidelné opakování vzorcem** (každý druhý týden, jednou měsíčně) není
  součástí. Až bude potřeba, je to generátor termínů nad touhle strukturou.
- **Přesun termínu mezi skupinami** není. Smazat a přidat.

## Nasazení

Po mergi nasadí `deploy-backend.yml` migraci; appka na web hned, do Play
v dalším vydání. Prod je na 1.2.5, čekají #113–#119.
