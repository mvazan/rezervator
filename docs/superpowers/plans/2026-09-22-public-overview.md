# Veřejný přehled — implementační plán

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Kuželna si v Správě zapne veřejný read-only přehled rozvrhu na `rezervator.online/#/prehled/<slug>` — bez přihlášení, bez jmen.

**Architecture:** Nové sloupce `tenants.public_slug` / `public_enabled` (migrace 0043). Jediná funkce pro `anon`, `public_week`, vrací data týdne s maskovanými jmény; appka je přečte existujícími `fromJson` továrnami, obsazená místa převede na syntetické rezervace „Obsazeno" a vykreslí je stejnou tabulí jako přihlášená appka (`WeekBoard`, vytažený z `WeekScreen`). Správce nastavuje slug a přepínač přes admin RPC.

**Tech Stack:** Supabase Postgres (plpgsql, security definer), Flutter + Riverpod 3, go_router (hash URL), flutter_test.

**Spec:** `docs/superpowers/specs/2026-09-22-public-overview-design.md`

## Global Constraints

- Slug: regex `^[a-z0-9]([a-z0-9-]{1,38}[a-z0-9])?$` (3–40 znaků), v DB i v appce stejný.
- `public_week` je **jediná** nová funkce s `execute` pro `anon`. Každá další nová funkce: `revoke all on function … from public, anon;` (default privileges z 0017 dávají `anon` execute automaticky).
- Z `public_week` nesmí odejít: `player_id`, jméno hráče, id rezervace, `renter_name`, `note` pronájmu, `created_by`, `tenant_id`, `created_at`.
- Neexistující, vypnutý i neschválený slug → **stejná** chyba `unknown_tenant`.
- Grant na `tenants` pro `authenticated` (`select (id, name, status)`) se **nemění**.
- Text na obsazené buňce i pronájmu: `Obsazeno` (konstanta `publicOccupiedLabel`).
- Chybové hlášky: `'invalid_slug': 'Adresa smí mít 3–40 znaků: malá písmena, číslice a pomlčky.'`, `'slug_taken': 'Tuhle adresu už má jiná kuželna.'`; na veřejné stránce `unknown_tenant` → `'Tahle kuželna veřejný přehled nemá.'`
- Route: `/prehled/:slug` (hash URL `#/prehled/<slug>`).
- Žádné copy-paste: tabule přes `WeekBoard` + `WeekNavigation`, adresa přes `CopyableAddress`, kořen URL přes `appRootUrl`.
- Commit po každém tasku, zprávy česky ve stylu repa (`feat(…): …`), zakončené `Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>`. Nepushovat.
- Každý nový test falzifikovat (ověřit, že bez změny padá).

---

### Task 1: Migrace 0043 + SQL testy + snapshot + SCHEMA.md

**Files:**
- Create: `supabase/migrations/0043_public_overview.sql`
- Modify: `supabase/tests/tenancy_rls.sql` (nové bloky těsně před závěrečné `reset role;` / `rollback;`)
- Modify: `supabase/schema.sql` (regenerace), `docs/SCHEMA.md`

**Interfaces:**
- Produces (SQL): `public_week(p_slug text, p_monday date) returns jsonb` s klíči `tenant_name`, `settings`, `blocks`, `slot_types`, `overrides`, `priority_slots`, `rentals`, `occupied` (`[{block_id, date, lane, club_color}]`); `set_public_overview(p_slug text, p_enabled boolean) returns void`; `my_public_overview() returns jsonb` (`{public_slug, public_enabled, tenant_name}`); chyby `unknown_tenant`, `invalid_slug`, `slug_taken`, `not_allowed`, `not_authenticated`.

- [ ] **Step 1: Napsat SQL testy (padají — funkce neexistují)**

Vložit do `supabase/tests/tenancy_rls.sql` před závěrečné `reset role;` + `rollback;`:

```sql
-- 0043 veřejný přehled ------------------------------------------------------
reset role;
do $$
begin
  if not has_function_privilege('anon', 'public_week(text, date)', 'execute') then
    raise exception 'FAIL: anon cannot call public_week';
  end if;
  if has_function_privilege('anon', 'set_public_overview(text, boolean)', 'execute')
     or has_function_privilege('anon', 'my_public_overview()', 'execute')
     or has_function_privilege('anon', 'public_tenant_id(text)', 'execute')
     or has_function_privilege('authenticated', 'public_tenant_id(text)', 'execute') then
    raise exception 'FAIL: an admin/internal public-overview function is callable by anon (or the helper by the app)';
  end if;
  if not has_function_privilege('authenticated', 'set_public_overview(text, boolean)', 'execute')
     or not has_function_privilege('authenticated', 'my_public_overview()', 'execute') then
    raise exception 'FAIL: the app cannot manage its public overview';
  end if;
  if has_column_privilege('authenticated', 'public.tenants', 'public_slug', 'select') then
    raise exception 'FAIL: tenants.public_slug is readable directly — every alley''s slug would leak';
  end if;
  raise notice 'OK: public_week is the one door for anon; the rest is admin-only or internal (0043)';
end $$;

-- Fixtures: an approved tenant A with a club-coloured reservation, a
-- cancelled one, a named rental with a note and a match — all on a block of
-- their own (06:00), so nothing else in this suite shares the cells.
do $$
declare
  v_a constant uuid := '00000000-0000-0000-0000-00000000000a';
  v_uid constant uuid := '10000000-0000-0000-0000-000000000001';
  v_monday constant date :=
    date_trunc('week', (now() at time zone 'Europe/Prague')::date)::date;
  v_club uuid;
  v_block uuid;
  v_type uuid;
begin
  update tenants set status = 'approved' where id = v_a;
  insert into clubs (tenant_id, name, color) values (v_a, 'Pub Oddíl', 5)
    returning id into v_club;
  update profiles set club_id = v_club where id = v_uid;
  insert into time_blocks (tenant_id, starts_at, ends_at, position)
    values (v_a, '06:00', '06:30', 99) returning id into v_block;
  perform set_config('probe.pub_block', v_block::text, true);
  perform set_config('probe.pub_monday', v_monday::text, true);
  insert into reservations
    (tenant_id, player_id, date, block_id, lane, created_via, created_by)
  values (v_a, v_uid, v_monday + 2, v_block, 1, 'app', v_uid);
  insert into reservations
    (tenant_id, player_id, date, block_id, lane, created_via, created_by,
     cancelled_at, cancelled_via)
  values (v_a, v_uid, v_monday + 2, v_block, 2, 'app', v_uid, now(), 'app');
  insert into rentals
    (tenant_id, renter_name, note, lanes, date, starts_at, ends_at, created_by)
  values (v_a, 'Firma Tajná', 'tajná poznámka', '{1}', v_monday + 4,
          '05:00', '05:30', v_uid);
  select id into v_type from priority_slot_types
    where tenant_id = v_a and is_match and builtin;
  insert into priority_slots
    (tenant_id, date, starts_at, ends_at, type_id, home_team, away_team,
     prep_minutes, description, is_away, created_by)
  values (v_a, v_monday + 5, '05:00', '05:45', v_type, 'Pub Domácí',
          'Pub Hosté', 0, '', false, v_uid);
end $$;

-- Admin A: format checks, then a disabled save (trimmed + lower-cased).
set local role authenticated;
set local request.jwt.claims =
  '{"sub":"10000000-0000-0000-0000-000000000001","role":"authenticated"}';
do $$
declare
  v jsonb;
begin
  begin
    perform set_public_overview('Ab', false);
    raise exception 'FAIL: a 2-character slug was accepted';
  exception when others then
    if sqlerrm <> 'invalid_slug' then raise; end if;
  end;
  begin
    perform set_public_overview('kuzelna_a', false);
    raise exception 'FAIL: an underscore slug was accepted';
  exception when others then
    if sqlerrm <> 'invalid_slug' then raise; end if;
  end;
  begin
    perform set_public_overview('', true);
    raise exception 'FAIL: switched on without a slug';
  exception when others then
    if sqlerrm <> 'invalid_slug' then raise; end if;
  end;
  perform set_public_overview('  Kuzelna-A ', false);
  v := my_public_overview();
  if v->>'public_slug' is distinct from 'kuzelna-a'
     or (v->>'public_enabled')::boolean
     or v->>'tenant_name' is distinct from 'Kuželna A' then
    raise exception 'FAIL: my_public_overview returned %', v;
  end if;
  raise notice 'OK: set_public_overview validates the slug and stores it normalised; my_public_overview reads it back (0043)';
end $$;

-- Admin B cannot take A's slug; pending C is no admin.
reset role;
set local role authenticated;
set local request.jwt.claims =
  '{"sub":"10000000-0000-0000-0000-000000000002","role":"authenticated"}';
do $$
begin
  begin
    perform set_public_overview('kuzelna-a', true);
    raise exception 'FAIL: tenant B took tenant A''s slug';
  exception when others then
    if sqlerrm <> 'slug_taken' then raise; end if;
  end;
  if (my_public_overview()->>'public_slug') is not null then
    raise exception 'FAIL: the refused save still wrote tenant B';
  end if;
end $$;
reset role;
set local role authenticated;
set local request.jwt.claims =
  '{"sub":"10000000-0000-0000-0000-000000000003","role":"authenticated"}';
do $$
begin
  begin
    perform set_public_overview('cizi-slug', true);
    raise exception 'FAIL: a non-admin set the public overview';
  exception when others then
    if sqlerrm <> 'not_allowed' then raise; end if;
  end;
  begin
    perform my_public_overview();
    raise exception 'FAIL: a non-admin read the public overview setting';
  exception when others then
    if sqlerrm <> 'not_allowed' then raise; end if;
  end;
  raise notice 'OK: a slug is one alley''s, and only its admin sets it (0043)';
end $$;

-- Anon: unknown and switched-off slugs look the same.
reset role;
set local role anon;
set local request.jwt.claims = '{"role":"anon"}';
do $$
begin
  begin
    perform public_week('nikdo-tu-neni', current_date);
    raise exception 'FAIL: an unknown slug answered';
  exception when others then
    if sqlerrm <> 'unknown_tenant' then raise; end if;
  end;
  begin
    perform public_week('kuzelna-a', current_date);
    raise exception 'FAIL: a switched-off slug answered';
  exception when others then
    if sqlerrm <> 'unknown_tenant' then raise; end if;
  end;
  raise notice 'OK: unknown and switched-off slugs give the same unknown_tenant (0043)';
end $$;

-- Switched on: anon reads the week — occupancy and club colour, no names.
reset role;
set local role authenticated;
set local request.jwt.claims =
  '{"sub":"10000000-0000-0000-0000-000000000001","role":"authenticated"}';
select set_public_overview('kuzelna-a', true);
reset role;
set local role anon;
set local request.jwt.claims = '{"role":"anon"}';
do $$
declare
  v_block constant text := current_setting('probe.pub_block');
  v_monday constant date := current_setting('probe.pub_monday')::date;
  v jsonb;
begin
  -- Mid-week date: the function snaps it to the Monday.
  v := public_week('kuzelna-a', v_monday + 3);
  if v->>'tenant_name' is distinct from 'Kuželna A' then
    raise exception 'FAIL: tenant_name %', v->>'tenant_name';
  end if;
  if not v->'occupied' @> jsonb_build_array(jsonb_build_object(
       'block_id', v_block, 'date', (v_monday + 2)::text, 'lane', 1,
       'club_color', 5)) then
    raise exception 'FAIL: the live reservation is not an occupied cell in the club colour: %', v->'occupied';
  end if;
  if v->'occupied' @> jsonb_build_array(jsonb_build_object(
       'block_id', v_block, 'lane', 2)) then
    raise exception 'FAIL: a cancelled reservation shows as occupied';
  end if;
  if not v->'rentals' @> '[{"renter_name": "", "note": ""}]'
     or not v->'priority_slots' @> '[{"home_team": "Pub Domácí"}]'
     or jsonb_array_length(v->'blocks') = 0
     or jsonb_array_length(v->'slot_types') = 0
     or v->'settings'->'lane_count' is null then
    raise exception 'FAIL: the week is incomplete: %', v;
  end if;
  if v::text like '%10000000-0000-0000-0000-000000000001%'
     or v::text like '%Hráč A%'
     or v::text like '%Firma Tajná%'
     or v::text like '%tajná poznámka%'
     or v::text like '%00000000-0000-0000-0000-00000000000a%'
     or v::text like '%Kuželna B%' then
    raise exception 'FAIL: public_week leaks a name, an id or another tenant: %', v;
  end if;
  raise notice 'OK: public_week shows occupancy in club colours and the matches, never a name (0043)';
end $$;
```

- [ ] **Step 2: Spustit testy, ověřit pád**

```bash
supabase start >/dev/null && supabase db reset
psql postgresql://postgres:postgres@127.0.0.1:54322/postgres -v ON_ERROR_STOP=1 -f supabase/tests/tenancy_rls.sql 2>&1 | tail -5
```
Expected: `ERROR: … function public_week(unknown, date) does not exist` nebo `FAIL: anon cannot call public_week`.

- [ ] **Step 3: Napsat migraci**

`supabase/migrations/0043_public_overview.sql`:

```sql
-- 0043: veřejný přehled. A kuželna may publish a read-only week board at
-- rezervator.online/#/prehled/<slug>. Self-service: its admin picks the slug
-- and switches it on (off by default). Anyone — anon included — reads it
-- through ONE function, public_week, which hands out no names: reservations
-- become bare occupied cells with the club colour, rentals lose renter and
-- note. The slug columns stay outside the tenants column grant; only the
-- functions below read them.

alter table tenants add column public_slug text;
alter table tenants add column public_enabled boolean not null default false;
alter table tenants add constraint tenants_public_slug_key unique (public_slug);
alter table tenants add constraint tenants_public_slug_format
  check (public_slug ~ '^[a-z0-9]([a-z0-9-]{1,38}[a-z0-9])?$');
alter table tenants add constraint tenants_public_needs_slug
  check (not public_enabled or public_slug is not null);

-- The published, approved alley behind a slug. Unknown, switched off and
-- not yet approved all raise the SAME error, so nobody can probe which
-- slugs exist.
create or replace function public_tenant_id(p_slug text)
returns uuid
language plpgsql stable security definer set search_path = public
as $$
declare
  v_tenant uuid;
begin
  select id into v_tenant from tenants
   where public_slug = lower(trim(coalesce(p_slug, '')))
     and public_enabled
     and status = 'approved';
  if v_tenant is null then
    raise exception 'unknown_tenant';
  end if;
  return v_tenant;
end;
$$;
revoke all on function public_tenant_id(text) from public, anon, authenticated;

-- One week of one published alley, shaped like the app's own streams so the
-- client's fromJson factories read it unchanged. overrides/priority_slots/
-- rentals cover Sunday before … Monday after the week: the phone's day
-- pager previews the neighbouring day from the same lists mid-swipe.
create or replace function public_week(p_slug text, p_monday date)
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
declare
  v_tenant constant uuid := public_tenant_id(p_slug);
  v_monday constant date :=
    date_trunc('week', coalesce(p_monday, current_date))::date;
  v_from constant date := v_monday - 1;
  v_to constant date := v_monday + 7;
begin
  return jsonb_build_object(
    'tenant_name', (select name from tenants where id = v_tenant),
    'settings', (select to_jsonb(s) - 'tenant_id'
                   from schedule_settings s where s.tenant_id = v_tenant),
    'blocks', coalesce((
      select jsonb_agg(to_jsonb(b) - 'tenant_id')
        from time_blocks b where b.tenant_id = v_tenant), '[]'),
    'slot_types', coalesce((
      select jsonb_agg(to_jsonb(t) - 'tenant_id' - 'created_at')
        from priority_slot_types t where t.tenant_id = v_tenant), '[]'),
    'overrides', coalesce((
      select jsonb_agg(to_jsonb(o) - 'tenant_id' - 'created_by' - 'created_at')
        from day_overrides o
       where o.tenant_id = v_tenant and o.date between v_from and v_to), '[]'),
    'priority_slots', coalesce((
      select jsonb_agg(to_jsonb(p) - 'tenant_id' - 'created_by' - 'created_at')
        from priority_slots p
       where p.tenant_id = v_tenant and p.date between v_from and v_to), '[]'),
    -- Names and notes never leave: the board says "Obsazeno" instead.
    'rentals', coalesce((
      select jsonb_agg((to_jsonb(r) - 'tenant_id' - 'created_by' - 'created_at')
                       || jsonb_build_object('renter_name', '', 'note', ''))
        from rentals r
       where r.tenant_id = v_tenant
         and (r.date between v_from and v_to
              or (r.weekday is not null
                  and (r.valid_from is null or r.valid_from <= v_to)
                  and (r.valid_until is null or r.valid_until >= v_from)))),
      '[]'),
    -- Who holds a lane is exactly what the public board must not say: a
    -- live reservation is its cell and the player's club colour, nothing more.
    'occupied', coalesce((
      select jsonb_agg(jsonb_build_object(
               'block_id', x.block_id, 'date', x.date, 'lane', x.lane,
               'club_color', coalesce(c.color, -1))
             order by x.date, x.block_id, x.lane)
        from reservations x
        join profiles pr on pr.id = x.player_id
        left join clubs c on c.id = pr.club_id
       where x.tenant_id = v_tenant
         and x.cancelled_at is null
         and x.date between v_monday and v_monday + 6), '[]')
  );
end;
$$;
revoke all on function public_week(text, date) from public;
grant execute on function public_week(text, date) to anon, authenticated;

-- The admin's switch: slug (trimmed, lower-cased, '' = none) and on/off for
-- their own alley.
create or replace function set_public_overview(p_slug text, p_enabled boolean)
returns void
language plpgsql security definer set search_path = public
as $$
declare
  v_slug constant text := nullif(lower(trim(coalesce(p_slug, ''))), '');
begin
  if auth.uid() is null then
    raise exception 'not_authenticated';
  end if;
  if not is_admin() then
    raise exception 'not_allowed';
  end if;
  if coalesce(p_enabled, false) and v_slug is null then
    raise exception 'invalid_slug';
  end if;
  update tenants
     set public_slug = v_slug, public_enabled = coalesce(p_enabled, false)
   where id = current_tenant_id();
exception
  when check_violation then raise exception 'invalid_slug';
  when unique_violation then raise exception 'slug_taken';
end;
$$;
revoke all on function set_public_overview(text, boolean) from public, anon;
grant execute on function set_public_overview(text, boolean) to authenticated;

-- What the admin screen shows: the setting and the name to suggest a slug from.
create or replace function my_public_overview()
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
begin
  if not is_admin() then
    raise exception 'not_allowed';
  end if;
  return (
    select jsonb_build_object('public_slug', t.public_slug,
                              'public_enabled', t.public_enabled,
                              'tenant_name', t.name)
      from tenants t where t.id = current_tenant_id());
end;
$$;
revoke all on function my_public_overview() from public, anon;
grant execute on function my_public_overview() to authenticated;
```

- [ ] **Step 4: Spustit testy, ověřit průchod**

```bash
supabase db reset
psql postgresql://postgres:postgres@127.0.0.1:54322/postgres -v ON_ERROR_STOP=1 -f supabase/tests/tenancy_rls.sql 2>&1 | grep -E "0043|FAIL|ERROR"
```
Expected: pět řádků `NOTICE:  OK: … (0043)`, žádný `FAIL`/`ERROR`, konec `ROLLBACK`.

- [ ] **Step 5: Falzifikace** (každou změnu po ověření vrátit, pak `supabase db reset`)
  1. V migraci smazat `|| jsonb_build_object('renter_name', '', 'note', '')` → musí padnout `FAIL: the week is incomplete` nebo `leaks`.
  2. Smazat `- 'created_by'` u `priority_slots` → `FAIL: public_week leaks …`.
  3. Smazat `revoke … set_public_overview … from public, anon` → `FAIL: an admin/internal …`.
  4. V `public_tenant_id` smazat `and public_enabled` → `FAIL: a switched-off slug answered`.

- [ ] **Step 6: Snapshot a dokumentace**

```bash
tool/schema_snapshot.sh
```

V `docs/SCHEMA.md`:
- do tabulky `## RPCs` přidat řádky:
  - `` | `public_week(slug, monday)` (0043) | **anon** i signed-in | Veřejný přehled: týden (`monday` se zarovná na pondělí) publikované a schválené kuželny — `tenant_name`, `settings`, `blocks`, `slot_types`, `overrides`/`priority_slots`/`rentals` za neděli před … pondělí po, `occupied` (`block_id, date, lane, club_color`) za týden. Žádná jména, `player_id`, `renter_name`, `note`, `created_by`. `unknown_tenant` pro neznámý, vypnutý i neschválený slug (stejně). | ``
  - `` | `set_public_overview(slug, enabled)`, `my_public_overview()` (0043) | admin | Slug (trim + lower, `''` = žádný) a přepínač vlastní kuželny; čtení vrací `{public_slug, public_enabled, tenant_name}`. `not_allowed`, `invalid_slug` (formát / zapnutí bez slugu), `slug_taken`. | ``
- do věty „Internal, no EXECUTE for app roles:" přidat `` `public_tenant_id` ``.
- za odstavec o `rental_occurrences` (konec `## RPCs`) přidat odstavec:
  „**`public_week` skládá týden znovu, na serveri (0043).** Anon nemá na tabulky žádný grant a jména se musí maskovat na serveru, takže veřejný přehled nečte streamy appky. Nový vstup do `buildWeekSchedule` (nový parametr = nová tabulka ovlivňující sloty) proto znamená doplnit ho i do `public_week` a do `PublicWeek.fromJson` — klientskou stranu vynutí kompilátor (parametry jsou povinné), SQL stranu ne."
- do `## Checks` za „the 0041 rental groups (…)," doplnit: „the 0043 public overview (anon may call only `public_week`; slug format, normalisation and uniqueness; admin-only setting; unknown and switched-off slugs indistinguishable; occupancy in club colours without any name, player id, renter, note or other tenant),".

- [ ] **Step 7: Commit**

```bash
git add supabase/migrations/0043_public_overview.sql supabase/tests/tenancy_rls.sql supabase/schema.sql docs/SCHEMA.md
git commit -m "feat(db): veřejný přehled — slug kuželny a public_week bez jmen (0043)

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 2: Doména, adresa, API a hlášky (čistý Dart)

**Files:**
- Create: `lib/domain/public_week.dart`, `lib/domain/slug.dart`
- Modify: `lib/core/kiosk_url.dart`, `lib/core/ui.dart` (friendlyDbError), `lib/data/providers.dart` (Api + 2 providery)
- Test: `test/domain/public_week_test.dart`, `test/domain/slug_test.dart`, `test/core/kiosk_url_test.dart`, `test/core/errors_test.dart` (nebo kde se dnes testuje `friendlyDbError` — `grep -rln friendlyDbError test/core`)

**Interfaces:**
- Consumes: JSON tvar `public_week` / `my_public_overview` z Tasku 1.
- Produces:
  - `const publicOccupiedLabel = 'Obsazeno';`
  - `class PublicCell { blockId, date (Day), lane, clubColor; String get id; factory fromJson }`
  - `List<Reservation> publicReservations(List<PublicCell> cells)`
  - `class PublicWeek { tenantName, settings, blocks, overrides, prioritySlots, rentals, reservations, nameById, clubColorById; factory fromJson(Map<String, dynamic>) }`
  - `class PublicOverview { String? slug; bool enabled; String tenantName; factory fromJson }`
  - `String suggestSlug(String name)`, `final slugPattern`
  - `String appRootUrl(Uri)`, `String kioskUrlFrom(Uri)` (beze změny chování), `String publicUrlFrom(Uri, String slug)`
  - `Api.publicWeek(String slug, Day monday) → Future<Map<String, dynamic>>`, `Api.myPublicOverview() → Future<Map<String, dynamic>>`, `Api.setPublicOverview(String slug, bool enabled) → Future<void>`
  - `publicWeekProvider = FutureProvider.autoDispose.family<PublicWeek, (String, Day)>`, `publicOverviewProvider = FutureProvider.autoDispose<PublicOverview>`

- [ ] **Step 1: Testy**

`test/domain/slug_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:rezervator/domain/slug.dart';

void main() {
  group('suggestSlug', () {
    test('folds diacritics, lower-cases and hyphenates', () {
      expect(suggestSlug('Kuželna Sokol Brno'), 'kuzelna-sokol-brno');
      expect(suggestSlug('TJ  Lokomotiva – Ústí n/L'), 'tj-lokomotiva-usti-n-l');
    });
    test('trims hyphens at both ends', () {
      expect(suggestSlug(' „Veverky“ '), 'veverky');
    });
    test('caps at 40 characters without a trailing hyphen', () {
      final s = suggestSlug('Kuželkářský oddíl Tělovýchovné jednoty Lokomotiva');
      expect(s.length, lessThanOrEqualTo(40));
      expect(s.endsWith('-'), isFalse);
      expect(slugPattern.hasMatch(s), isTrue);
    });
    test('too short a name suggests nothing', () {
      expect(suggestSlug('Ž'), '');
      expect(suggestSlug('!!'), '');
    });
  });

  group('slugPattern mirrors the DB check', () {
    test('accepts', () {
      for (final s in ['abc', 'kuzelna-a', 'a1-b2', 'x' * 40]) {
        expect(slugPattern.hasMatch(s), isTrue, reason: s);
      }
    });
    test('rejects', () {
      for (final s in ['ab', '-abc', 'abc-', 'Abc', 'a_b', 'kuželna', 'x' * 41]) {
        expect(slugPattern.hasMatch(s), isFalse, reason: s);
      }
    });
  });
}
```

`test/domain/public_week_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:rezervator/domain/models.dart';
import 'package:rezervator/domain/public_week.dart';

void main() {
  // What public_week returns (0043), trimmed to one row per list.
  final json = <String, dynamic>{
    'tenant_name': 'Kuželna Test',
    'settings': {
      'lane_count': 2,
      'training_weekdays': [1, 2, 3, 4, 5, 6, 7],
      'booking_horizon_days': 14,
      'max_active_reservations': 3,
      'kiosk_dark': true,
      'kiosk_fit_day': true,
    },
    'blocks': [
      {'id': 'b1', 'starts_at': '10:00:00', 'ends_at': '11:00:00', 'position': 0, 'active': true},
    ],
    'slot_types': [
      {'id': 't-match', 'name': 'Zápas', 'color': -1, 'lanes': null, 'is_match': true, 'builtin': true},
    ],
    'overrides': [
      {'date': '2026-09-12', 'closed': true, 'reason': 'Údržba', 'block_ids': null},
    ],
    'priority_slots': [
      {
        'id': 'm1', 'date': '2026-09-11', 'starts_at': '10:00:00', 'ends_at': '11:00:00',
        'type_id': 't-match', 'home_team': 'Sokol', 'away_team': 'Slavia',
        'prep_minutes': 0, 'description': '', 'parent_id': null, 'is_away': false,
        'import_key': null, 'hand_edited': false,
      },
    ],
    'rentals': [
      {
        'id': 'r1', 'renter_name': '', 'lanes': [2], 'date': '2026-09-10', 'weekday': null,
        'starts_at': '10:00:00', 'ends_at': '11:00:00', 'valid_from': null, 'valid_until': null,
        'note': '', 'color': -2, 'parent_id': null, 'skipped': false, 'group_id': null,
      },
    ],
    'occupied': [
      {'block_id': 'b1', 'date': '2026-09-09', 'lane': 1, 'club_color': 3},
      {'block_id': 'b1', 'date': '2026-09-09', 'lane': 2, 'club_color': -1},
    ],
  };

  test('PublicWeek.fromJson reads every list with the app\'s own factories', () {
    final w = PublicWeek.fromJson(json);
    expect(w.tenantName, 'Kuželna Test');
    expect(w.settings.laneCount, 2);
    expect(w.blocks.single.id, 'b1');
    expect(w.overrides.single.closed, isTrue);
    expect(w.prioritySlots.single.title, 'Sokol – Slavia');
    expect(w.prioritySlots.single.type.isMatch, isTrue);
    expect(w.rentals.single.lanes, [2]);
  });

  test('a rental says Obsazeno — the server sent no name', () {
    expect(PublicWeek.fromJson(json).rentals.single.renterName, publicOccupiedLabel);
    expect(publicOccupiedLabel, 'Obsazeno');
  });

  test('each occupied cell becomes one live reservation named Obsazeno in its club colour', () {
    final w = PublicWeek.fromJson(json);
    expect(w.reservations, hasLength(2));
    final first = w.reservations.first;
    expect(first.blockId, 'b1');
    expect(first.date, Day(2026, 9, 9));
    expect(first.lane, 1);
    expect(first.isLive, isTrue);
    expect(first.createdVia, 'public');
    // Two cells, two distinct ids — the board keys tiles by them.
    expect(w.reservations.map((r) => r.id).toSet(), hasLength(2));
    for (final r in w.reservations) {
      expect(r.playerId, r.id);
      expect(w.nameById[r.playerId], 'Obsazeno');
    }
    expect(w.clubColorById[first.playerId], 3);
    expect(w.clubColorById[w.reservations.last.playerId], -1);
  });

  test('missing lists and settings fall back to empty / defaults', () {
    final w = PublicWeek.fromJson({'tenant_name': 'X'});
    expect(w.blocks, isEmpty);
    expect(w.reservations, isEmpty);
    expect(w.settings.laneCount, ScheduleSettings.defaults.laneCount);
  });

  test('PublicOverview.fromJson', () {
    final o = PublicOverview.fromJson(
        {'public_slug': null, 'public_enabled': false, 'tenant_name': 'Kuželna A'});
    expect(o.slug, isNull);
    expect(o.enabled, isFalse);
    expect(o.tenantName, 'Kuželna A');
  });
}
```

Do `test/core/kiosk_url_test.dart` přidat (existující skupina `kioskUrlFrom` zůstává beze změny):

```dart
  group('publicUrlFrom', () {
    test('the public overview of a slug, same root rules as the kiosk', () {
      expect(publicUrlFrom(Uri.parse('https://rezervator.online/#/prehled/x'), 'sokol'),
          'https://rezervator.online/#/prehled/sokol');
      expect(publicUrlFrom(Uri.parse('https://kuzelky.example/rezervator/?x=1'), 'sokol'),
          'https://kuzelky.example/rezervator/#/prehled/sokol');
    });
  });

  test('appRootUrl ends with exactly one slash', () {
    expect(appRootUrl(Uri.parse('https://rezervator.online')), 'https://rezervator.online/');
    expect(appRootUrl(Uri.parse('http://localhost:8765/#/')), 'http://localhost:8765/');
  });
```

Do testu `friendlyDbError` přidat:

```dart
  test('public overview slug errors', () {
    expect(friendlyDbError(Exception('invalid_slug')),
        'Adresa smí mít 3–40 znaků: malá písmena, číslice a pomlčky.');
    expect(friendlyDbError(Exception('slug_taken')), 'Tuhle adresu už má jiná kuželna.');
  });
```

- [ ] **Step 2: Spustit, ověřit pád**

Run: `flutter test test/domain/slug_test.dart test/domain/public_week_test.dart test/core/kiosk_url_test.dart test/core/errors_test.dart`
Expected: kompilační chyby (`slug.dart`, `public_week.dart`, `publicUrlFrom` neexistují).

- [ ] **Step 3: Implementace**

`lib/domain/slug.dart`:

```dart
/// The public overview's address part (0043): what an admin types after
/// `#/prehled/`. Pure Dart, unit-tested.
library;

import 'collation.dart';

/// Mirrors the DB check `tenants_public_slug_format`, so the form can hint
/// before the round trip: 3–40 characters, lower-case letters without
/// diacritics, digits, a hyphen only inside.
final slugPattern = RegExp(r'^[a-z0-9]([a-z0-9-]{1,38}[a-z0-9])?$');

/// A slug suggested from the alley's name — diacritics folded, lower case,
/// every run of anything else one hyphen, at most 40 characters. '' when the
/// name leaves fewer than 3 characters (the admin then types their own).
String suggestSlug(String name) {
  var s = foldDiacritics(name)
      .toLowerCase()
      .replaceAll(RegExp('[^a-z0-9]+'), '-')
      .replaceAll(RegExp(r'^-+|-+$'), '');
  if (s.length > 40) {
    s = s.substring(0, 40).replaceAll(RegExp(r'-+$'), '');
  }
  return s.length < 3 ? '' : s;
}
```

`lib/domain/public_week.dart`:

```dart
/// The public board's data (0043): one week of one published alley as
/// `public_week` returns it, and the admin's own setting
/// (`my_public_overview`). Pure Dart.
///
/// The server hands out no names, so the board has none to show: an
/// occupied lane arrives as a bare cell and becomes a synthetic
/// [Reservation] named [publicOccupiedLabel] in its club colour — the
/// schedule code (`buildWeekSchedule`, the tiles) then renders it exactly as
/// it renders a real one.
library;

import 'models.dart';

/// What every occupied lane and every rental reads on the public board.
const publicOccupiedLabel = 'Obsazeno';

final _epoch = DateTime.utc(1970);

/// One occupied lane: where, and the holder's club colour (−1 = no club).
class PublicCell {
  const PublicCell({
    required this.blockId,
    required this.date,
    required this.lane,
    required this.clubColor,
  });

  final String blockId;
  final Day date;
  final int lane;
  final int clubColor;

  /// Stands in for both the reservation and the player id — unique per
  /// cell, and it names no one.
  String get id => 'pub-$blockId-${date.toSql()}-$lane';

  factory PublicCell.fromJson(Map<String, dynamic> json) => PublicCell(
        blockId: json['block_id'] as String,
        date: Day.parse(json['date'] as String),
        lane: json['lane'] as int,
        clubColor: json['club_color'] as int? ?? -1,
      );
}

/// The cells as live reservations the board can draw.
List<Reservation> publicReservations(List<PublicCell> cells) => [
      for (final c in cells)
        Reservation(
          id: c.id,
          playerId: c.id,
          date: c.date,
          blockId: c.blockId,
          lane: c.lane,
          createdVia: 'public',
          createdAt: _epoch,
        ),
    ];

class PublicWeek {
  const PublicWeek({
    required this.tenantName,
    required this.settings,
    required this.blocks,
    required this.overrides,
    required this.prioritySlots,
    required this.rentals,
    required this.reservations,
    required this.nameById,
    required this.clubColorById,
  });

  final String tenantName;
  final ScheduleSettings settings;
  final List<TimeBlock> blocks;
  final List<DayOverride> overrides;
  final List<PrioritySlot> prioritySlots;
  final List<Rental> rentals;
  final List<Reservation> reservations;
  final Map<String, String> nameById;
  final Map<String, int> clubColorById;

  factory PublicWeek.fromJson(Map<String, dynamic> json) {
    List<Map<String, dynamic>> rows(String key) => [
          for (final row in json[key] as List? ?? const [])
            Map<String, dynamic>.from(row as Map),
        ];
    final typeById = {
      for (final t in rows('slot_types').map(PrioritySlotType.fromJson)) t.id: t,
    };
    final cells = rows('occupied').map(PublicCell.fromJson).toList();
    final settings = json['settings'];
    return PublicWeek(
      tenantName: json['tenant_name'] as String? ?? '',
      settings: settings == null
          ? ScheduleSettings.defaults
          : ScheduleSettings.fromJson(Map<String, dynamic>.from(settings as Map)),
      blocks: rows('blocks').map(TimeBlock.fromJson).toList(),
      overrides: rows('overrides').map(DayOverride.fromJson).toList(),
      prioritySlots: [
        for (final row in rows('priority_slots')) PrioritySlot.fromJson(row, typeById),
      ],
      rentals: [
        for (final row in rows('rentals'))
          Rental.fromJson({...row, 'renter_name': publicOccupiedLabel}),
      ],
      reservations: publicReservations(cells),
      nameById: {for (final c in cells) c.id: publicOccupiedLabel},
      clubColorById: {for (final c in cells) c.id: c.clubColor},
    );
  }
}

/// The admin's view of their own alley's setting.
class PublicOverview {
  const PublicOverview({
    required this.slug,
    required this.enabled,
    required this.tenantName,
  });

  final String? slug;
  final bool enabled;

  /// The slug suggestion is made from it.
  final String tenantName;

  factory PublicOverview.fromJson(Map<String, dynamic> json) => PublicOverview(
        slug: json['public_slug'] as String?,
        enabled: json['public_enabled'] as bool? ?? false,
        tenantName: json['tenant_name'] as String? ?? '',
      );
}
```

`lib/core/kiosk_url.dart` — nahradit tělo `kioskUrlFrom` a přidat dvě funkce (doc komentář knihovny doplnit větou „The public overview's address (0043) follows the same rules."):

```dart
/// The root the app is served at, ending with exactly one '/' — a full page
/// URL is fine, its query and fragment are dropped, which is what makes it
/// safe to pass `Uri.base` while the admin sits deep inside the app on a
/// route of their own.
String appRootUrl(Uri appUrl) {
  final root = Uri(
    scheme: appUrl.scheme,
    host: appUrl.host,
    port: appUrl.hasPort ? appUrl.port : null,
    // A deployment under a sub-path (…/rezervator/) has to keep it; the
    // path of a hash route ("/#/kiosk-login") never reaches the server, so
    // there is nothing else in here to strip.
    path: appUrl.path,
  ).toString();
  return root.endsWith('/') ? root : '$root/';
}

/// The kiosk address for an app served at [appUrl].
String kioskUrlFrom(Uri appUrl) => '${appRootUrl(appUrl)}#/kiosk-login';

/// The public overview (0043) of the alley published under [slug].
String publicUrlFrom(Uri appUrl, String slug) =>
    '${appRootUrl(appUrl)}#/prehled/$slug';
```

`lib/core/ui.dart` — do mapy v `friendlyDbError` za `'match_past'`:

```dart
    'invalid_slug': 'Adresa smí mít 3–40 znaků: malá písmena, číslice a pomlčky.',
    'slug_taken': 'Tuhle adresu už má jiná kuželna.',
```

`lib/data/providers.dart` — import `../domain/public_week.dart`; do `class Api` (za `setMatchException`):

```dart
  /// The public board of one alley (0043). Anyone may call it — signed in or
  /// not — and the slug picks the alley; `unknown_tenant` when it is unknown
  /// or switched off.
  static Future<Map<String, dynamic>> publicWeek(String slug, Day monday) async =>
      Map<String, dynamic>.from(await _db.rpc('public_week',
          params: {'p_slug': slug, 'p_monday': monday.toSql()}) as Map);

  /// The admin's own alley: `{public_slug, public_enabled, tenant_name}`.
  static Future<Map<String, dynamic>> myPublicOverview() async =>
      Map<String, dynamic>.from(await _db.rpc('my_public_overview') as Map);

  /// Admin: publish (or not) the alley's board under [slug].
  static Future<void> setPublicOverview(String slug, bool enabled) => _db.rpc(
      'set_public_overview',
      params: {'p_slug': slug, 'p_enabled': enabled});
```

a na konec souboru:

```dart
/// One public week (0043), keyed by (slug, Monday). No auth and no tenant
/// scoping — the slug IS the alley — so it lives outside
/// [resetTenantScopedProviders].
final publicWeekProvider =
    FutureProvider.autoDispose.family<PublicWeek, (String, Day)>(
  (ref, key) async => PublicWeek.fromJson(await Api.publicWeek(key.$1, key.$2)),
);

/// The admin's public-overview setting (Správa → Veřejný přehled).
final publicOverviewProvider = FutureProvider.autoDispose<PublicOverview>(
  (ref) async => PublicOverview.fromJson(await Api.myPublicOverview()),
);
```

- [ ] **Step 4: Spustit, ověřit průchod**

Run: `flutter test test/domain/slug_test.dart test/domain/public_week_test.dart test/core/ && flutter analyze`
Expected: vše PASS, `No issues found!`

- [ ] **Step 5: Falzifikace** — dočasně v `PublicWeek.fromJson` vynechat přepis `renter_name` → test „a rental says Obsazeno" padá; v `PublicCell.id` vynechat `-$lane` → test „two distinct ids" padá. Vrátit.

- [ ] **Step 6: Commit**

```bash
git add lib/domain/public_week.dart lib/domain/slug.dart lib/core/kiosk_url.dart lib/core/ui.dart lib/data/providers.dart test/
git commit -m "feat(přehled): data veřejného týdne, slug a adresa přehledu

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 3: Vytáhnout `WeekBoard` + `WeekNavigation` z `WeekScreen` (refaktor beze změny chování)

**Files:**
- Create: `lib/features/schedule/week_board.dart`
- Modify: `lib/features/schedule/week_screen.dart`
- Test: `test/features/week_screen_test.dart` (beze změny — musí zůstat zelený)

**Interfaces:**
- Produces:
  - `mixin WeekNavigation<T extends StatefulWidget> on State<T>` s `int weekOffset`, `int dayIndex`, `Day mondayOf(Day today)`, `void goWeek(int delta)`, `void shiftWeek(int weekDelta, int landingDayIndex)`, `void selectDay(int index)`
  - `class WeekBoard extends StatelessWidget` s parametry: `week, weekOffset, dayIndex, today, now, settings, blocks, overrides, priority, rentals, me, myCount, myCountByIndex, nameById, clubColorById, interactive, slot, admin = CalendarAdminHooks.none, onSelectDay, onShiftWeek`

- [ ] **Step 1: Ověřit výchozí stav**

Run: `flutter test test/features/week_screen_test.dart` → PASS (zapsat počet testů).

- [ ] **Step 2: Vytvořit `lib/features/schedule/week_board.dart`**

```dart
/// The schedule board both week screens render — the signed-in app's
/// [WeekScreen] and the public read-only overview — and the week/day
/// navigation they share, so the two look and page identically.
///
/// The view follows the device orientation: portrait reads day by day
/// ([DayPagerView]), landscape shows the whole week ([WeekCalendarView]);
/// both always fit the screen width, so there are no toggle buttons.
library;

import 'package:flutter/material.dart';

import '../../domain/models.dart';
import '../../domain/schedule.dart';
import 'day_pager_view.dart';
import 'schedule_callbacks.dart';
import 'week_calendar_view.dart';

/// Which week and day a schedule screen shows, and the moves between them.
mixin WeekNavigation<T extends StatefulWidget> on State<T> {
  /// Weeks away from the current one (0 = this week).
  int weekOffset = 0;

  /// 0 (Monday) .. 6 (Sunday): the day the portrait pager shows.
  int dayIndex = Day.fromDateTime(DateTime.now()).weekday - 1;

  Day mondayOf(Day today) =>
      today.addDays(1 - today.weekday + 7 * weekOffset);

  /// The header's arrows (±1) and its „dnes" (0: back to today).
  void goWeek(int delta) {
    setState(() {
      weekOffset = delta == 0 ? 0 : weekOffset + delta;
      if (delta == 0) {
        dayIndex = Day.fromDateTime(DateTime.now()).weekday - 1;
      }
    });
  }

  /// Called by [DayPagerView] when a swipe crosses the Monday/Sunday edge:
  /// [weekDelta] is +1/-1 and [landingDayIndex] (0=Mon..6=Sun) is the day to
  /// land on in the adjacent week (Sunday when moving back, Monday when
  /// moving forward).
  void shiftWeek(int weekDelta, int landingDayIndex) {
    setState(() {
      weekOffset += weekDelta;
      dayIndex = landingDayIndex;
    });
  }

  void selectDay(int index) => setState(() => dayIndex = index);
}

class WeekBoard extends StatelessWidget {
  const WeekBoard({
    super.key,
    required this.week,
    required this.weekOffset,
    required this.dayIndex,
    required this.today,
    required this.now,
    required this.settings,
    required this.blocks,
    required this.overrides,
    required this.priority,
    required this.rentals,
    required this.me,
    required this.myCount,
    required this.myCountByIndex,
    required this.nameById,
    required this.clubColorById,
    required this.interactive,
    required this.slot,
    this.admin = CalendarAdminHooks.none,
    required this.onSelectDay,
    required this.onShiftWeek,
  });

  final WeekSchedule week;
  final int weekOffset;
  final int dayIndex;
  final Day today;
  final HourMinute now;
  final ScheduleSettings settings;

  /// What the pager's sentinel pages rebuild the neighbouring day from.
  final List<TimeBlock> blocks;
  final List<DayOverride> overrides;
  final List<PrioritySlot> priority;
  final List<Rental> rentals;

  final Profile? me;
  final int myCount;
  final List<int> myCountByIndex;
  final Map<String, String> nameById;
  final Map<String, int> clubColorById;
  final bool interactive;
  final SlotCallbacks slot;

  /// Calendar-only (landscape): the pager has no admin gestures.
  final CalendarAdminHooks admin;
  final ValueChanged<int> onSelectDay;
  final void Function(int weekDelta, int landingDayIndex) onShiftWeek;

  @override
  Widget build(BuildContext context) {
    final landscape =
        MediaQuery.orientationOf(context) == Orientation.landscape;
    if (landscape) {
      return WeekCalendarView(
        week: week,
        today: today,
        now: now,
        me: me,
        myCount: myCount,
        settings: settings,
        nameById: nameById,
        clubColorById: clubColorById,
        interactive: interactive,
        slot: slot,
        admin: admin,
      );
    }
    return DayPagerView(
      week: week,
      weekOffset: weekOffset,
      dayIndex: dayIndex,
      today: today,
      now: now,
      settings: settings,
      blocks: blocks,
      overrides: overrides,
      priority: priority,
      rentals: rentals,
      me: me,
      myCount: myCount,
      myCountByIndex: myCountByIndex,
      nameById: nameById,
      clubColorById: clubColorById,
      interactive: interactive,
      slot: slot,
      onSelectDay: onSelectDay,
      onShiftWeek: onShiftWeek,
    );
  }
}
```

- [ ] **Step 3: Upravit `lib/features/schedule/week_screen.dart`**

1. `class _WeekScreenState extends ConsumerState<WeekScreen> with WeekNavigation {`
2. Smazat pole `_weekOffset`, `_dayIndex`, metody `_monday`, `initState`, `_go`, `_shiftWeek`, `_selectDay` (i jejich doc komentáře — přesunuly se do mixinu).
3. Přejmenovat použití: `_monday(todayDay)` → `mondayOf(todayDay)`, `_weekOffset` → `weekOffset`, `_go` → `goWeek`.
4. Smazat proměnnou `landscape` a její komentář; blok `Expanded(child: landscape ? WeekCalendarView(…) : DayPagerView(…))` nahradit:

```dart
        Expanded(
          child: WeekBoard(
            week: week,
            weekOffset: weekOffset,
            dayIndex: dayIndex,
            today: todayDay,
            now: now,
            settings: settings,
            blocks: blocks,
            overrides: overrides,
            priority: priority,
            rentals: rentals,
            me: me,
            myCount: myCount,
            myCountByIndex: myCountByIndex,
            nameById: nameById,
            clubColorById: clubColorById,
            interactive: interactive,
            slot: actions.slot,
            admin: actions.admin,
            onSelectDay: selectDay,
            onShiftWeek: shiftWeek,
          ),
        ),
```

5. Importy: `day_pager_view.dart` a `week_calendar_view.dart` nahradit `week_board.dart`. Doc komentář třídy: „delegates rendering to [WeekCalendarView] or [DayPagerView]" → „delegates rendering to [WeekBoard]"; odstavec o orientaci ponechat odkazem „(see [WeekBoard])".

- [ ] **Step 4: Ověřit**

Run: `flutter analyze && flutter test test/features/week_screen_test.dart test/features/home_shell_test.dart`
Expected: `No issues found!`, stejný počet testů jako v kroku 1, vše PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/features/schedule/week_board.dart lib/features/schedule/week_screen.dart
git commit -m "refactor(rozvrh): WeekBoard a WeekNavigation vytažené z WeekScreen

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 4: Veřejná stránka `#/prehled/<slug>`

**Files:**
- Create: `lib/features/public/public_schedule_screen.dart`
- Modify: `lib/features/admin/widgets/admin_scaffold.dart` (`AsyncBody.errorText`), `lib/main.dart` (route)
- Test: `test/features/public_schedule_screen_test.dart`, `test/features/admin_widgets_test.dart` (AsyncBody)

**Interfaces:**
- Consumes: `publicWeekProvider`, `PublicWeek`, `WeekBoard`, `WeekNavigation`, `WeekHeader(monday, weekOffset, onGo, trailing)`, `buildWeekSchedule`, `nowProvider`.
- Produces: `PublicScheduleScreen({required String slug})`, `String publicWeekError(Object e)`, `AsyncBody(errorText: …)` (default `friendlyDbError`).

- [ ] **Step 1: Testy**

Do `test/features/admin_widgets_test.dart` (skupina AsyncBody, nebo nová):

```dart
  testWidgets('AsyncBody uses its own errorText when given', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: AsyncBody<int>(
        value: AsyncError(Exception('unknown_tenant'), StackTrace.empty),
        errorText: (_) => 'Vlastní hláška',
        builder: (_) => const SizedBox(),
      ),
    ));
    expect(find.text('Vlastní hláška'), findsOneWidget);
  });
```

`test/features/public_schedule_screen_test.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rezervator/data/clock.dart';
import 'package:rezervator/data/providers.dart';
import 'package:rezervator/domain/models.dart';
import 'package:rezervator/domain/public_week.dart';
import 'package:rezervator/features/public/public_schedule_screen.dart';
import 'package:rezervator/features/schedule/day_pager_view.dart';
import 'package:rezervator/features/schedule/week_calendar_view.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  // Pinned clock: Wednesday morning, the block at 10:00 not yet past.
  final now = DateTime(2026, 9, 9, 8, 0);
  final monday = Day(2026, 9, 7);

  final week = PublicWeek.fromJson({
    'tenant_name': 'Kuželna Test',
    'settings': {
      'lane_count': 2,
      'training_weekdays': [1, 2, 3, 4, 5, 6, 7],
      'booking_horizon_days': 14,
      'max_active_reservations': 3,
    },
    'blocks': [
      {'id': 'b1', 'starts_at': '10:00:00', 'ends_at': '11:00:00', 'position': 0, 'active': true},
    ],
    'slot_types': [
      {'id': 't-match', 'name': 'Zápas', 'is_match': true, 'builtin': true},
    ],
    'priority_slots': [
      {
        'id': 'm1', 'date': '2026-09-11', 'starts_at': '10:00:00', 'ends_at': '11:00:00',
        'type_id': 't-match', 'home_team': 'Sokol', 'away_team': 'Slavia',
      },
    ],
    'rentals': [
      {
        'id': 'r1', 'renter_name': '', 'lanes': [2], 'date': '2026-09-10',
        'starts_at': '10:00:00', 'ends_at': '11:00:00',
      },
    ],
    'occupied': [
      {'block_id': 'b1', 'date': '2026-09-09', 'lane': 1, 'club_color': 3},
    ],
  });

  void surface(WidgetTester tester, Size size) {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  Widget app({
    List<(String, Day)>? requested,
    Object? error,
  }) =>
      ProviderScope(
        overrides: [
          nowProvider.overrideWith((ref) => Stream.value(now)),
          publicWeekProvider.overrideWith((ref, key) async {
            requested?.add(key);
            if (error != null) throw error;
            return week;
          }),
        ],
        child: const MaterialApp(home: PublicScheduleScreen(slug: 'test')),
      );

  testWidgets('landscape: the week calendar with Obsazeno, the match and the alley name',
      (tester) async {
    surface(tester, const Size(1600, 1200));
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();

    expect(find.byType(WeekCalendarView), findsOneWidget);
    expect(find.text('Kuželna Test'), findsOneWidget);
    // The reservation and the rental — both only „Obsazeno".
    expect(find.text('Obsazeno'), findsNWidgets(2));
    expect(find.textContaining('Sokol'), findsWidgets);
  });

  testWidgets('portrait: the day pager', (tester) async {
    surface(tester, const Size(900, 1600));
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    expect(find.byType(DayPagerView), findsOneWidget);
  });

  testWidgets('tapping an occupied cell does nothing', (tester) async {
    surface(tester, const Size(1600, 1200));
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();

    await tester.tap(find.text('Obsazeno').first);
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.byType(SnackBar), findsNothing);
    expect(find.byType(BottomSheet), findsNothing);
  });

  testWidgets('the arrow asks for the next Monday', (tester) async {
    surface(tester, const Size(1600, 1200));
    final requested = <(String, Day)>[];
    await tester.pumpWidget(app(requested: requested));
    await tester.pumpAndSettle();
    expect(requested, [('test', monday)]);

    await tester.tap(find.byIcon(Icons.chevron_right));
    await tester.pumpAndSettle();
    expect(requested.last, ('test', monday.addDays(7)));
  });

  testWidgets('an unknown or switched-off slug says so', (tester) async {
    surface(tester, const Size(1600, 1200));
    await tester.pumpWidget(app(error: Exception('unknown_tenant')));
    await tester.pumpAndSettle();
    expect(find.text('Tahle kuželna veřejný přehled nemá.'), findsOneWidget);
  });
}
```

- [ ] **Step 2: Spustit, ověřit pád**

Run: `flutter test test/features/public_schedule_screen_test.dart test/features/admin_widgets_test.dart`
Expected: kompilační chyba (`public_schedule_screen.dart` / `errorText` neexistuje).

- [ ] **Step 3: `AsyncBody.errorText`**

V `lib/features/admin/widgets/admin_scaffold.dart`:

```dart
  const AsyncBody({
    super.key,
    required this.value,
    required this.builder,
    this.onRetry,
    this.errorText = friendlyDbError,
  });

  final AsyncValue<T> value;
  final Widget Function(T data) builder;
  final VoidCallback? onRetry;

  /// How a failure reads — the app-wide wording unless a screen knows
  /// better what its error means (the public board's `unknown_tenant`).
  final String Function(Object error) errorText;
```

a v `build`: `Text(friendlyDbError(e), …)` → `Text(errorText(e), …)`.

- [ ] **Step 4: `lib/features/public/public_schedule_screen.dart`**

```dart
/// The public week board at `#/prehled/<slug>` (0043): anyone, no sign-in,
/// read-only. The same board as the app ([WeekBoard]), fed by ONE call,
/// `public_week`, which hands out no names — an occupied lane is a bare
/// cell that reads „Obsazeno" in the player's club colour.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/ui.dart';
import '../../data/clock.dart';
import '../../data/providers.dart';
import '../../domain/models.dart';
import '../../domain/schedule.dart';
import '../admin/widgets/admin_scaffold.dart' show AsyncBody;
import '../schedule/schedule_callbacks.dart';
import '../schedule/week_board.dart';
import '../schedule/widgets/week_header.dart';

/// The public board's own wording for a slug that answers nothing — unknown
/// and switched off look the same on purpose (the server does not say which).
String publicWeekError(Object error) =>
    error.toString().contains('unknown_tenant')
        ? 'Tahle kuželna veřejný přehled nemá.'
        : friendlyDbError(error);

class PublicScheduleScreen extends ConsumerStatefulWidget {
  const PublicScheduleScreen({super.key, required this.slug});

  final String slug;

  @override
  ConsumerState<PublicScheduleScreen> createState() =>
      _PublicScheduleScreenState();
}

class _PublicScheduleScreenState extends ConsumerState<PublicScheduleScreen>
    with WeekNavigation {
  /// Nothing on this board reacts to a tap (it is never interactive, and
  /// there is no signed-in player) — the callbacks only fill the contract.
  static final _inert = SlotCallbacks(
    onBook: (_, _, _) {},
    onCancel: (_, _, _, {required ownFuture}) {},
  );

  /// Kept across weeks, so the title does not blink while the next week
  /// loads.
  String? _tenantName;

  @override
  Widget build(BuildContext context) {
    final nowDt = ref.watch(nowProvider).value ?? DateTime.now();
    final today = Day.fromDateTime(nowDt);
    final now = HourMinute(nowDt.hour, nowDt.minute);
    final monday = mondayOf(today);
    final key = (widget.slug, monday);
    final value = ref.watch(publicWeekProvider(key));
    _tenantName = value.value?.tenantName ?? _tenantName;

    return Scaffold(
      appBar: AppBar(title: Text(_tenantName ?? 'Rozvrh')),
      body: Column(
        children: [
          WeekHeader(
            monday: monday,
            weekOffset: weekOffset,
            onGo: goWeek,
            trailing: const [],
          ),
          Expanded(
            child: AsyncBody(
              value: value,
              errorText: publicWeekError,
              onRetry: () => ref.invalidate(publicWeekProvider(key)),
              builder: (pw) => WeekBoard(
                week: buildWeekSchedule(
                  monday: monday,
                  today: today,
                  now: now,
                  settings: pw.settings,
                  blocks: pw.blocks,
                  overrides: pw.overrides,
                  priority: pw.prioritySlots,
                  rentals: pw.rentals,
                  reservations: pw.reservations,
                ),
                weekOffset: weekOffset,
                dayIndex: dayIndex,
                today: today,
                now: now,
                settings: pw.settings,
                blocks: pw.blocks,
                overrides: pw.overrides,
                priority: pw.prioritySlots,
                rentals: pw.rentals,
                me: null,
                myCount: 0,
                myCountByIndex: const [0, 0, 0, 0, 0, 0, 0],
                nameById: pw.nameById,
                clubColorById: pw.clubColorById,
                interactive: false,
                slot: _inert,
                onSelectDay: selectDay,
                onShiftWeek: shiftWeek,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
```

- [ ] **Step 4b: Připomínka u zdroje** — na konec doc komentáře `buildWeekSchedule` v `lib/domain/schedule.dart` přidat:

```dart
///
/// The public overview assembles these same inputs on the server
/// (`public_week`, 0043) — a new input here needs adding there too, and in
/// `PublicWeek.fromJson`.
```

- [ ] **Step 5: Route v `lib/main.dart`**

Import `features/public/public_schedule_screen.dart` a do `routes` za `/kiosk-login`:

```dart
    // The public board (0043) — no sign-in, so outside AuthGate. A hash
    // route (#/prehled/<slug>) needs no server rewrite on GitHub Pages.
    GoRoute(
      path: '/prehled/:slug',
      builder: (_, state) => AppConfig.hasSupabase
          ? PublicScheduleScreen(slug: state.pathParameters['slug']!)
          : const _NotConfigured(),
    ),
```

- [ ] **Step 6: Ověřit**

Run: `flutter analyze && flutter test test/features/public_schedule_screen_test.dart test/features/admin_widgets_test.dart`
Expected: `No issues found!`, vše PASS. Když `find.text('Obsazeno')` najde jiný počet než 2 (tile může jméno vykreslit dvakrát, např. tooltip), upravit očekávání na skutečný počet **a** ověřit, že bez rezervace i pronájmu je `findsNothing` — ne oslabit na `findsWidgets`.

- [ ] **Step 7: Falzifikace** — v `publicWeekError` vrátit rovnou `friendlyDbError(error)` → test „unknown or switched-off" padá; v `PublicScheduleScreen` dát `interactive: true` → test „tapping … does nothing" by měl zachytit otevření dialogu/sheetu (pokud nezachytí, protože `me == null` akci stejně vypne, poznamenat do reportu). Vrátit.

- [ ] **Step 8: Commit**

```bash
git add lib/features/public/ lib/features/admin/widgets/admin_scaffold.dart lib/main.dart lib/domain/schedule.dart test/features/public_schedule_screen_test.dart test/features/admin_widgets_test.dart
git commit -m "feat(přehled): veřejná stránka rozvrhu na #/prehled/<slug>

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 5: Správa → Veřejný přehled + changelog

**Files:**
- Create: `lib/features/admin/widgets/copyable_address.dart`, `lib/features/admin/public_overview_screen.dart`
- Modify: `lib/features/admin/kiosk_screen.dart` (použít `CopyableAddress`), `lib/features/admin/admin_screen.dart` (položka hubu), `lib/features/profile/changelog_data.dart`
- Test: `test/features/public_overview_screen_test.dart`

**Interfaces:**
- Consumes: `publicOverviewProvider`, `PublicOverview`, `Api.setPublicOverview`, `suggestSlug`, `appRootUrl`, `publicUrlFrom`, `AdminScaffold`, `AsyncBody`, `tryAction`, `friendlyDbError`, `UpdateScreen.webUrl`.
- Produces: `CopyableAddress({required String url})`, `PublicOverviewScreen({save = Api.setPublicOverview})`.

- [ ] **Step 1: Vytáhnout `CopyableAddress`**

Přesunout třídu `_KioskAddress` z `kiosk_screen.dart` beze změny těla do `lib/features/admin/widgets/copyable_address.dart` jako veřejnou `CopyableAddress` (importy `package:flutter/material.dart`, `package:flutter/services.dart`, `../../../core/ui.dart`; doc komentář: „An address, readable and copyable: selectable text so it can be read aloud or picked apart on the web, one button for the clipboard. The kiosk's and the public overview's."). V `kiosk_screen.dart` `_KioskAddress(url: _kioskUrl())` → `CopyableAddress(url: _kioskUrl())`, import widgetu, odstranit nepoužitý `package:flutter/services.dart` jen pokud ho už nic nepotřebuje (Clipboard v `_newPassword` ho potřebuje — nechat).

Run: `flutter test test/features/ && flutter analyze` → PASS (kiosk testy beze změny).

- [ ] **Step 2: Testy obrazovky**

`test/features/public_overview_screen_test.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rezervator/data/providers.dart';
import 'package:rezervator/domain/models.dart';
import 'package:rezervator/domain/public_week.dart';
import 'package:rezervator/features/admin/public_overview_screen.dart';

void main() {
  const admin = Profile(
    id: 'a',
    displayName: 'Správce',
    email: 'a@example.com',
    role: Role.admin,
    status: ProfileStatus.approved,
  );

  Widget app(
    PublicOverview overview, {
    Future<void> Function(String, bool)? save,
  }) =>
      ProviderScope(
        overrides: [
          myProfileProvider.overrideWith((ref) => Stream.value(admin)),
          publicOverviewProvider.overrideWith((ref) async => overview),
        ],
        child: MaterialApp(
          home: PublicOverviewScreen(save: save ?? (_, _) async {}),
        ),
      );

  Finder link(String url) => find.byWidgetPredicate(
      (w) => w is SelectableText && w.data == url);

  testWidgets('no slug yet: suggests one from the name, off, no link', (tester) async {
    await tester.pumpWidget(app(const PublicOverview(
        slug: null, enabled: false, tenantName: 'Kuželna Sokol')));
    await tester.pumpAndSettle();

    expect(find.text('Veřejný přehled'), findsOneWidget);
    expect(find.widgetWithText(TextField, 'kuzelna-sokol'), findsOneWidget);
    expect(tester.widget<SwitchListTile>(find.byType(SwitchListTile)).value, isFalse);
    expect(find.text('Odkaz na přehled'), findsNothing);
  });

  testWidgets('published: shows the link to copy', (tester) async {
    await tester.pumpWidget(app(const PublicOverview(
        slug: 'sokol', enabled: true, tenantName: 'Kuželna Sokol')));
    await tester.pumpAndSettle();

    expect(find.widgetWithText(TextField, 'sokol'), findsOneWidget);
    expect(link('https://rezervator.online/#/prehled/sokol'), findsOneWidget);
    expect(find.byTooltip('Kopírovat adresu'), findsOneWidget);
  });

  testWidgets('Uložit sends the typed slug and the switch', (tester) async {
    final calls = <(String, bool)>[];
    await tester.pumpWidget(app(
      const PublicOverview(slug: null, enabled: false, tenantName: 'Kuželna Sokol'),
      save: (slug, enabled) async => calls.add((slug, enabled)),
    ));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), '  Muj-Slug ');
    await tester.tap(find.byType(SwitchListTile));
    await tester.pump();
    await tester.tap(find.text('Uložit'));
    await tester.pumpAndSettle();

    expect(calls, [('muj-slug', true)]);
    expect(find.text('Uloženo.'), findsOneWidget);
  });

  testWidgets('a taken slug says so', (tester) async {
    await tester.pumpWidget(app(
      const PublicOverview(slug: null, enabled: false, tenantName: 'Kuželna Sokol'),
      save: (_, _) async => throw Exception('slug_taken'),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Uložit'));
    await tester.pumpAndSettle();
    expect(find.text('Tuhle adresu už má jiná kuželna.'), findsOneWidget);
  });
}
```

Run: `flutter test test/features/public_overview_screen_test.dart` → FAIL (soubor neexistuje).

- [ ] **Step 3: `lib/features/admin/public_overview_screen.dart`**

```dart
/// Správa → Veřejný přehled (0043): the admin publishes the alley's week
/// board at its own address — occupancy only, no names — or takes it down.
library;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/kiosk_url.dart';
import '../../core/ui.dart';
import '../../data/providers.dart';
import '../../domain/public_week.dart';
import '../../domain/slug.dart';
import '../auth/update_screen.dart' show UpdateScreen;
import 'widgets/admin_scaffold.dart';
import 'widgets/copyable_address.dart';

class PublicOverviewScreen extends ConsumerStatefulWidget {
  const PublicOverviewScreen({super.key, this.save = Api.setPublicOverview});

  /// Injectable so a widget test can drive Uložit without the backend.
  final Future<void> Function(String slug, bool enabled) save;

  @override
  ConsumerState<PublicOverviewScreen> createState() =>
      _PublicOverviewScreenState();
}

class _PublicOverviewScreenState extends ConsumerState<PublicOverviewScreen> {
  final _slug = TextEditingController();
  bool _enabled = false;

  /// The form is filled from the server once; after that it is the admin's
  /// until Uložit (a reload after saving must not undo their typing).
  bool _seeded = false;

  @override
  void dispose() {
    _slug.dispose();
    super.dispose();
  }

  /// Where the app runs (the web build knows) — on Android the public web
  /// app, as for the kiosk address.
  Uri get _appUrl => kIsWeb ? Uri.base : Uri.parse(UpdateScreen.webUrl);

  void _seed(PublicOverview o) {
    if (_seeded) return;
    _seeded = true;
    _slug.text = o.slug ?? suggestSlug(o.tenantName);
    _enabled = o.enabled;
  }

  Future<void> _save() async {
    final ok = await tryAction(
      context,
      () => widget.save(_slug.text.trim().toLowerCase(), _enabled),
      success: 'Uloženo.',
      errorText: friendlyDbError,
    );
    if (ok && mounted) ref.invalidate(publicOverviewProvider);
  }

  @override
  Widget build(BuildContext context) {
    return AdminScaffold(
      title: 'Veřejný přehled',
      body: AsyncBody(
        value: ref.watch(publicOverviewProvider),
        onRetry: () => ref.invalidate(publicOverviewProvider),
        builder: (o) {
          _seed(o);
          final slug = o.slug;
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              const Text(
                'Rozvrh kuželny na vlastní adrese — pro kohokoli, bez '
                'přihlášení. Ukazuje jen obsazenost: jména hráčů ani nájemců '
                'na něm nejsou, zápasy ano.',
              ),
              const SizedBox(height: 8),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Zveřejnit přehled'),
                value: _enabled,
                onChanged: (value) => setState(() => _enabled = value),
              ),
              TextField(
                controller: _slug,
                autocorrect: false,
                decoration: const InputDecoration(
                  labelText: 'Adresa',
                  prefixText: '…/prehled/',
                  helperText: '3–40 znaků: malá písmena, číslice a pomlčky.',
                ),
              ),
              const SizedBox(height: 16),
              Align(
                alignment: Alignment.centerRight,
                child: FilledButton(
                  onPressed: _save,
                  child: const Text('Uložit'),
                ),
              ),
              if (o.enabled && slug != null) ...[
                const SizedBox(height: 24),
                Text('Odkaz na přehled',
                    style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 8),
                CopyableAddress(url: publicUrlFrom(_appUrl, slug)),
              ],
            ],
          );
        },
      ),
    );
  }
}
```

(`appRootUrl` se zde nepoužije — import `kiosk_url.dart` je kvůli `publicUrlFrom`.)

- [ ] **Step 4: Položka v hubu** — v `lib/features/admin/admin_screen.dart` import `public_overview_screen.dart` a do `_entries` za `Kiosk`:

```dart
    (
      label: 'Veřejný přehled',
      icon: Icons.public,
      screen: () => const PublicOverviewScreen(),
    ),
```

- [ ] **Step 5: Changelog** — v `lib/features/profile/changelog_data.dart` do horní dávky `Release(null, '22. 9. 2026', [...])` přidat jako poslední položku:

```dart
    'Veřejný přehled: správce ho zapne v Správa → Veřejný přehled a kuželna '
        'dostane vlastní adresu, kde kdokoli uvidí rozvrh bez přihlášení — '
        'jen obsazenost, bez jmen.',
```

(Když je v době implementace horní dávka datovaná jinak nebo už má verzi, založit novou `Release(null, '<dnešní datum ve tvaru d. m. yyyy>', [...])` nahoře.)

- [ ] **Step 6: Ověřit**

Run: `flutter analyze && flutter test`
Expected: `No issues found!`, celá sada PASS (včetně `test/changelog_test.dart`).

- [ ] **Step 7: Falzifikace** — v `_save` vynechat `.toLowerCase()` → test „Uložit sends…" padá; v `_seed` vynechat `suggestSlug` (dát `o.slug ?? ''`) → test „no slug yet" padá. Vrátit.

- [ ] **Step 8: Commit**

```bash
git add lib/features/admin/ lib/features/profile/changelog_data.dart test/features/public_overview_screen_test.dart
git commit -m "feat(správa): Veřejný přehled — slug, přepínač a odkaz

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 6: Závěrečné ověření

- [ ] `flutter analyze && flutter test` — celé zelené.
- [ ] `supabase db reset && psql … -f supabase/tests/tenancy_rls.sql` — žádný `FAIL`, konec `ROLLBACK`; `git diff --exit-code supabase/schema.sql` po `tool/schema_snapshot.sh` čistý.
- [ ] `flutter build web --release` projde (route a importy pro web).
- [ ] Po merge a nasazení (`deploy-backend.yml` aplikuje 0043, web se nasadí sám) ručně na prod: Správa → Veřejný přehled → zapnout se slugem → otevřít odkaz v anonymním okně: rozvrh s „Obsazeno", zápasy, šipky mění týden, ťuk nic nedělá; vypnout → „Tahle kuželna veřejný přehled nemá."
