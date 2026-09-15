# Nepravidelné pronájmy — implementační plán

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Jeden pronájem s víc termíny — každý s vlastním datem, časem a drahami — a obrazovka Pronájmy rozdělená na *Pravidelné* a *Nepravidelné*.

**Architecture:** Nová tabulka `rental_groups` drží identitu nájemce (jméno, barva); každý termín zůstává obyčejný jednorázový řádek `rentals` s `group_id`. Nic v kolizní logice (`rental_occurrences`, `rental_conflicts`, `create_reservation`, kaskáda 0018, `rentalsOn`) se nemění — termín ve skupině *je* jednorázový pronájem. Jediný vícerádkový zápis (osvojení řádku bez skupiny + nový termín) dělá RPC `rental_add_date`; skupina bez termínů zaniká triggerem. Appka skupiny odvozuje z řádků `rentals` (`rentalGroupsOf`), tabulku `rental_groups` nestreamuje.

**Tech Stack:** Flutter 3 / Riverpod 3, Supabase (Postgres RLS, plpgsql), `supabase/tests/tenancy_rls.sql` přes psql, `tool/schema_snapshot.sh`.

Spec: `docs/superpowers/specs/2026-09-15-rentals-irregular-design.md`.

## Global Constraints

- Branch `rental-groups` z `origin/main`. Commit per change; **push a PR až na pokyn**.
- Migrace append-only: jediný nový soubor `supabase/migrations/0041_rental_groups.sql` (Task 1 ho založí, Task 2 do něj přidá RPC — soubor ještě není nasazený). Po každé změně migrace `tool/schema_snapshot.sh` → `supabase/schema.sql` (CI diffuje). `supabase/tests/tenancy_rls.sql` musí končit `reset role;` + `rollback;`.
- **Beze změny:** `rental_occurs`, `rental_occurrences`, `rental_conflicts`, `create_reservation`, `move_reservation`, `move_day_reservations`, kaskáda 0018, `rentalsOn`, `RentalExceptionsDialog`, `RentalOccurrenceDialog`.
- Do skupiny smí jen řádek s `date is not null and parent_id is null` (DB check `rentals_group_shape_check`).
- Jméno a barva patří skupině a propagují se na řádky (`rental_group_guard` při vložení, `rental_group_changed` při úpravě). Poznámka patří termínu.
- Texty přesně: nadpisy sekcí `Pravidelné` / `Nepravidelné`; řádek termínu `3. 10. · 18:00–20:00 · dráhy 1, 2` (`dayLabel` · `HourMinute.display()`–`display()` · `dráhy ${lanes.join(', ')}`); zbytek `…a ještě 1 termín` / `…a další 3 termíny` / `…a dalších 5 termínů`; FAB `Přidat pronájem`; rozcestník `Pravidelný` / `Nepravidelný`; tituly dialogů `Přidat pravidelný pronájem`, `Přidat nepravidelný pronájem`, `Upravit pronájem`, `Přidat termín`, `Upravit termín`, `Termíny · <nájemce>`; snack `Termín uložen. Kolidující rezervace byly zrušeny.`; potvrzovací dialog (`confirmDelete` → `confirmDialog`) potvrzuje tlačítkem `Ano`, ruší `Zrušit`.
- Řazení: nepravidelné podle nejbližšího nadcházejícího termínu, skupiny jen s minulými termíny na konec (nejnověji skončená první), remíza `compareCzech(renterName)`; pravidelné podle dne v týdnu, začátku, `compareCzech(renterName)`.
- Každý nový test **falzifikovat** (test musí spadnout, když se oprava/funkce vrátí zpět) a výsledek uvést v commit message.
- Chybové kódy: `unknown_rental` → `'Tenhle pronájem už neexistuje.'`, `rental_group_invalid` → `'Termín nejde přiřadit k tomuhle pronájmu.'` (`friendlyDbError` v `lib/core/ui.dart`).
- SQL testy: fixtury tenant A `00000000-0000-0000-0000-00000000000a`, tenant B `00000000-0000-0000-0000-000000000002`; admin A `10000000-0000-0000-0000-000000000001`, admin B `10000000-0000-0000-0000-000000000002`, čekající hráč C (tenant A, ne admin) `10000000-0000-0000-0000-000000000003`. Impersonace: `set local role authenticated;` + `set local request.jwt.claims = '{"sub":"<uuid>","role":"authenticated"}';`. Styl bloků `do $$ … raise notice 'OK: …'; end $$;`, `FAIL:` výjimky uvnitř.
- Lokální stack: `supabase start` (jednou), `supabase db reset` po změně migrace, testy `psql postgresql://postgres:postgres@127.0.0.1:54322/postgres -X -v ON_ERROR_STOP=1 -f supabase/tests/tenancy_rls.sql`.

---

## Soubory

| Soubor | Role |
|---|---|
| `supabase/migrations/0041_rental_groups.sql` (nový) | tabulka, RLS, vazba + check, guard, propagace, prune, RPC |
| `supabase/tests/tenancy_rls.sql` | nové bloky 0041, `v_streamed` |
| `supabase/schema.sql` | snapshot |
| `docs/SCHEMA.md` | řádky tabulky/RPC, Checks |
| `lib/domain/models.dart` | `Rental.groupId` |
| `lib/domain/rental_groups.dart` (nový) | `RentalGroup`, `rentalGroupsOf` |
| `lib/domain/labels.dart` | `rentalDateCountLabel`, `rentalMoreDatesLabel` |
| `lib/core/ui.dart` | `friendlyDbError` |
| `lib/data/providers.dart` | `Api.saveRentalDate`, `addRentalDate`, `saveRentalGroup`, `deleteRentalGroup` |
| `lib/features/admin/widgets/rental_date_dialog.dart` (nový) | jeden termín |
| `lib/features/admin/widgets/rental_dates_dialog.dart` (nový) | seznam termínů skupiny |
| `lib/features/admin/widgets/rental_group_dialog.dart` (nový) | jméno + barva skupiny |
| `lib/features/admin/widgets/rental_dialog.dart` | `RentalKind`, bez přepínače |
| `lib/features/admin/rentals_screen.dart` | sekce, dlaždice skupin, rozcestník |
| `lib/features/profile/changelog_data.dart` | záznam |
| `test/domain/rental_groups_test.dart`, `test/domain/labels_test.dart`, `test/features/rental_date_dialog_test.dart`, `test/features/rental_dates_dialog_test.dart`, `test/features/rental_group_dialog_test.dart`, `test/features/rentals_screen_test.dart` | testy |

---

### Task 1: Migrace 0041 — tabulka, vazba, guard, propagace, prune

**Files:**
- Create: `supabase/migrations/0041_rental_groups.sql`
- Modify: `supabase/tests/tenancy_rls.sql` (před závěrečné `reset role;` + `rollback;`; pole `v_streamed` na řádku ~1704)
- Modify: `supabase/schema.sql` (snapshot), `docs/SCHEMA.md` (tabulka `## Tables`, `## Checks`)

**Interfaces:**
- Produces: tabulka `rental_groups(id, tenant_id, renter_name, color, created_by, created_at)`; sloupec `rentals.group_id`; triggery `rental_group_guard` (before insert/update on rentals when group_id not null: tenant check + kopie jména/barvy, chyba `rental_group_invalid`), `rental_group_changed` (after update on rental_groups: propagace), `rental_group_prune` (after delete on rentals: prázdná skupina zaniká).

- [ ] **Step 1: Založit branch**

```bash
cd ~/Home/rezervator && git fetch -q origin && git checkout -q -b rental-groups origin/main
```

- [ ] **Step 2: Napsat SQL testy (nejdřív — musí spadnout)**

Do `supabase/tests/tenancy_rls.sql` vlož **před** poslední dva řádky (`reset role;` / `rollback;`):

```sql
-- ---------------------------------------------------------------------------
-- 0041 — rental_groups: one renter, many one-time dates. A grouped date IS a
-- one-time rental; the group only lends it a name and a colour.
-- ---------------------------------------------------------------------------
set local role authenticated;
set local request.jwt.claims =
  '{"sub":"10000000-0000-0000-0000-000000000001","role":"authenticated"}';
do $$
declare
  v_uid constant uuid := '10000000-0000-0000-0000-000000000001';
  v_blk uuid;
  v_g uuid;
  v_r1 uuid;
  v_r2 uuid;
  v_d date := (now() at time zone 'Europe/Prague')::date + 90;
  v_weekdays smallint[];
  v_name text;
  v_color integer;
begin
  update schedule_settings set lane_count = 4
  where tenant_id = current_tenant_id();
  insert into time_blocks (starts_at, ends_at, position)
  values ('20:00', '21:00', 9) returning id into v_blk;
  select training_weekdays into v_weekdays from schedule_settings
  where tenant_id = current_tenant_id();
  while not (extract(isodow from v_d)::smallint = any (v_weekdays)) loop
    v_d := v_d + 1;
  end loop;

  -- 1) shape: a weekly series cannot join a group
  insert into rental_groups (renter_name, color, created_by)
  values ('Firma G', 5, v_uid) returning id into v_g;
  begin
    insert into rentals (group_id, renter_name, lanes, weekday, starts_at,
                         ends_at, created_by)
    values (v_g, 'Firma G', '{1}', 1, '20:00', '21:00', v_uid);
    raise exception 'FAIL: a weekly series joined a group';
  exception when check_violation then null;
  end;

  -- 2) the guard copies the group's name and colour onto the date
  insert into rentals (group_id, renter_name, lanes, date, starts_at, ends_at,
                       created_by)
  values (v_g, 'jiné jméno', '{1}', v_d, '20:00', '21:00', v_uid)
  returning id into v_r1;
  select renter_name, color into v_name, v_color from rentals where id = v_r1;
  if v_name <> 'Firma G' or v_color <> 5 then
    raise exception 'FAIL: rental_group_guard did not copy renter_name/color';
  end if;

  -- 3) a grouped date blocks its lane exactly like a lone one-time rental
  begin
    perform create_reservation(v_uid, v_d, v_blk, 1::smallint);
    raise exception 'FAIL: a grouped date did not block its lane';
  exception when others then
    if sqlerrm <> 'blocked_by_rental' then raise; end if;
  end;
  perform create_reservation(v_uid, v_d, v_blk, 2::smallint);

  -- 4) editing the group propagates to its dates
  update rental_groups set renter_name = 'Firma H', color = 7 where id = v_g;
  select renter_name, color into v_name, v_color from rentals where id = v_r1;
  if v_name <> 'Firma H' or v_color <> 7 then
    raise exception 'FAIL: a group edit did not propagate to its dates';
  end if;

  -- 5) the group lives while a date remains, and vanishes with the last one
  insert into rentals (group_id, renter_name, lanes, date, starts_at, ends_at,
                       created_by)
  values (v_g, 'Firma H', '{3}', v_d + 7, '20:00', '21:00', v_uid)
  returning id into v_r2;
  delete from rentals where id = v_r2;
  if not exists (select 1 from rental_groups where id = v_g) then
    raise exception 'FAIL: the group was pruned while a date remained';
  end if;
  delete from rentals where id = v_r1;
  if exists (select 1 from rental_groups where id = v_g) then
    raise exception 'FAIL: an empty group survived its last date';
  end if;

  -- 6) deleting a group takes its dates along and frees the lanes
  insert into rental_groups (renter_name, created_by)
  values ('Firma K', v_uid) returning id into v_g;
  insert into rentals (group_id, renter_name, lanes, date, starts_at, ends_at,
                       created_by)
  values (v_g, 'Firma K', '{1}', v_d + 14, '20:00', '21:00', v_uid);
  delete from rental_groups where id = v_g;
  if exists (select 1 from rentals where group_id = v_g) then
    raise exception 'FAIL: the cascade left a date behind';
  end if;
  perform create_reservation(v_uid, v_d + 14, v_blk, 1::smallint);

  raise notice 'OK: rental_groups hold one-time dates only, copy and propagate name/colour, block like a lone rental and vanish with their last date (0041)';
end $$;

-- A group belongs to its tenant: invisible and unusable from the other one.
set local request.jwt.claims =
  '{"sub":"10000000-0000-0000-0000-000000000002","role":"authenticated"}';
do $$
begin
  insert into rental_groups (id, renter_name, created_by)
  values ('30000000-0000-0000-0000-000000000001', 'Firma B',
          '10000000-0000-0000-0000-000000000002');
end $$;
set local request.jwt.claims =
  '{"sub":"10000000-0000-0000-0000-000000000001","role":"authenticated"}';
do $$
begin
  if exists (select 1 from rental_groups
             where id = '30000000-0000-0000-0000-000000000001') then
    raise exception 'FAIL: tenant A sees tenant B''s group';
  end if;
  begin
    insert into rentals (group_id, renter_name, lanes, date, starts_at,
                         ends_at, created_by)
    values ('30000000-0000-0000-0000-000000000001', 'x', '{1}',
            (now() at time zone 'Europe/Prague')::date + 100,
            '20:00', '21:00', '10000000-0000-0000-0000-000000000001');
    raise exception 'FAIL: a date attached itself to a foreign group';
  exception when others then
    if sqlerrm <> 'rental_group_invalid' then raise; end if;
  end;
  raise notice 'OK: a rental group is invisible and unusable across tenants (0041)';
end $$;

reset role;
do $$
begin
  if not (has_table_privilege('authenticated', 'public.rental_groups', 'select')
      and has_table_privilege('authenticated', 'public.rental_groups', 'insert')
      and has_table_privilege('authenticated', 'public.rental_groups', 'update')
      and has_table_privilege('authenticated', 'public.rental_groups', 'delete')) then
    raise exception 'FAIL: authenticated lacks DML on rental_groups (RLS decides the rows)';
  end if;
  if has_table_privilege('anon', 'public.rental_groups', 'select') then
    raise exception 'FAIL: anon can read rental_groups';
  end if;
  raise notice 'OK: rental_groups is full DML for the app, RLS decides, anon nothing (0041)';
end $$;
```

A do pole `v_streamed` (řádek ~1704) přidej `'rental_groups'` za `'match_exceptions'`:

```sql
    'day_overrides', 'priority_slot_types', 'priority_slots', 'rentals',
    'match_exceptions', 'rental_groups'
```

- [ ] **Step 3: Ověřit, že testy padají**

```bash
cd ~/Home/rezervator && supabase start >/dev/null 2>&1; supabase db reset >/dev/null 2>&1 && psql postgresql://postgres:postgres@127.0.0.1:54322/postgres -X -v ON_ERROR_STOP=1 -f supabase/tests/tenancy_rls.sql 2>&1 | grep -E "ERROR|OK: rental_groups" | head -3
```
Expected: `ERROR:  relation "rental_groups" does not exist` (žádné `OK: rental_groups`).

- [ ] **Step 4: Napsat migraci**

`supabase/migrations/0041_rental_groups.sql`:

```sql
-- 0041 — nepravidelné pronájmy: jeden nájemce, víc termínů.
--
-- Nájemce, který si dráhy bere opakovaně, ale nepravidelně, dosud znamenal
-- tolik pronájmů, kolik má termínů. rental_groups drží jeho identitu (jméno,
-- barvu); každý termín zůstává obyčejný jednorázový řádek rentals s vlastním
-- datem, časem a drahami — a s group_id.
--
-- Proto se tu NEMĚNÍ nic v kolizní logice: rental_occurs, rental_occurrences,
-- rental_conflicts ani kaskáda 0018. Termín ve skupině JE jednorázový
-- pronájem; že ho někdo drží za ruku, resolver nezajímá. Alternativa
-- (hlavička přes parent_id) by znamenala zvolnit tři omezení rentals a přepsat
-- rental_occurrences tak, aby děti hlavičky platily samy o sobě — dnes dítě
-- sérii jen upravuje (0021). Za čistší diagram to nestojí.
--
-- Týdenní série do skupiny nesmí (rentals_group_shape_check): série je
-- pravidlo bez konce, skupina je konečný seznam. Jsou to dvě různé věci.

create table rental_groups (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null default current_tenant_id()
    references tenants (id) on delete cascade,
  renter_name text not null,
  -- integer, ne smallint: ručně vybraná barva je 0x1000000|rgb (až 33 554 431)
  -- a do smallintu (max 32 767) se nevejde. Stejná doména jako rentals.color.
  color integer not null default -2,
  constraint rental_groups_color_check check (
    color between -2 and 8 or color between 16777216 and 33554431),
  created_by uuid not null references profiles (id),
  created_at timestamptz not null default now()
);
comment on table rental_groups is
  'One renter with several one-time rental dates (0041): the identity (name, colour) its rentals rows carry a copy of. A lone one-time rental has no group; rental_add_date creates one when a second date arrives, rental_group_prune removes it with the last date.';

alter table rental_groups enable row level security;
create policy rental_groups_select on rental_groups for select
  using (tenant_id = current_tenant_id() and is_approved_or_kiosk());
create policy rental_groups_insert on rental_groups for insert
  with check (tenant_id = current_tenant_id() and is_admin());
create policy rental_groups_update on rental_groups for update
  using (tenant_id = current_tenant_id() and is_admin())
  with check (tenant_id = current_tenant_id() and is_admin());
create policy rental_groups_delete on rental_groups for delete
  using (tenant_id = current_tenant_id() and is_admin());
-- Stejný tvar jako rentals (0017): plné DML pro přihlášené, řádky řeší RLS.
grant select, insert, update, delete on rental_groups to authenticated;
revoke all on rental_groups from anon;
alter publication supabase_realtime add table rental_groups;

-- ---------------------------------------------------------------------------
-- Vazba: do skupiny smí jen jednorázový řádek, který není výjimkou.
-- ---------------------------------------------------------------------------
alter table rentals
  add column group_id uuid references rental_groups (id) on delete cascade,
  add constraint rentals_group_shape_check check (
    group_id is null or (date is not null and parent_id is null));
create index rentals_group_idx on rentals (group_id) where group_id is not null;
comment on column rentals.group_id is
  'The rental_groups row this one-time date belongs to (0041); null for a lone one-time rental, a weekly series or an exception row.';

-- Při vložení/úpravě termínu ve skupině: skupina musí být z téhož tenantu a
-- jméno s barvou se berou z ní — vzor rental_exception_guard (0021).
create or replace function rental_group_guard()
returns trigger
language plpgsql security definer set search_path = public
as $$
declare
  v_group rental_groups;
begin
  select * into v_group from rental_groups where id = new.group_id;
  if not found or v_group.tenant_id <> new.tenant_id then
    raise exception 'rental_group_invalid';
  end if;
  new.renter_name := v_group.renter_name;
  new.color := v_group.color;
  return new;
end;
$$;
create trigger rental_group_guard
  before insert or update on rentals
  for each row when (new.group_id is not null)
  execute function rental_group_guard();

-- Úprava skupiny propíše jméno a barvu na její termíny — vzor
-- rental_series_changed (0021). Kopie na řádku musí zůstat: rental_occurrences
-- vrací renter_name tabuli i kiosku a nesmí kvůli tomu joinovat dál.
create or replace function rental_group_changed()
returns trigger
language plpgsql security definer set search_path = public
as $$
begin
  if old.renter_name is distinct from new.renter_name
     or old.color is distinct from new.color then
    update rentals set renter_name = new.renter_name, color = new.color
    where group_id = new.id;
  end if;
  return new;
end;
$$;
create trigger rental_group_changed
  after update on rental_groups
  for each row
  execute function rental_group_changed();

-- Skupina bez termínů nemá co držet: s posledním smazaným termínem zaniká.
-- Při mazání celé skupiny (kaskáda) je řádek skupiny už pryč a delete níže
-- nezasáhne nic — to je v pořádku.
create or replace function rental_group_prune()
returns trigger
language plpgsql security definer set search_path = public
as $$
begin
  if not exists (select 1 from rentals where group_id = old.group_id) then
    delete from rental_groups where id = old.group_id;
  end if;
  return null;
end;
$$;
create trigger rental_group_prune
  after delete on rentals
  for each row when (old.group_id is not null)
  execute function rental_group_prune();
```

- [ ] **Step 5: Spustit testy**

```bash
cd ~/Home/rezervator && supabase db reset >/dev/null 2>&1 && psql postgresql://postgres:postgres@127.0.0.1:54322/postgres -X -v ON_ERROR_STOP=1 -f supabase/tests/tenancy_rls.sql 2>&1 | grep -E "ERROR|FAIL|OK: (rental_groups|a rental group)|streamed"
```
Expected: tři řádky `NOTICE:  OK: …(0041)` (skupiny, tenant, práva), řádek `OK: … streamed …` beze změny, žádný `ERROR`/`FAIL`.

- [ ] **Step 6: Falzifikovat**

Dočasně zakomentuj v migraci celý `create trigger rental_group_prune …` (4 řádky) → `supabase db reset` + psql → očekáváno `FAIL: an empty group survived its last date`. Vrať zpět. Pak dočasně smaž `add constraint rentals_group_shape_check …` → očekáváno `FAIL: a weekly series joined a group`. Vrať zpět, znovu reset + psql = zelené.

- [ ] **Step 7: Snapshot a dokumentace**

```bash
cd ~/Home/rezervator && tool/schema_snapshot.sh && git diff --stat supabase/schema.sql
```
Expected: `supabase/schema.sql regenerated`, diff jen přidává `rental_groups`, `group_id`, tři funkce a triggery.

`docs/SCHEMA.md`: do tabulky `## Tables` za řádek `rentals` přidej

```markdown
| `rental_groups` | `renter_name`, `color` (−2 = default tint). One renter with several one-time dates (0041): `rentals.group_id → rental_groups` (cascade delete), allowed only on a row with `date` and no `parent_id` (`rentals_group_shape_check`). `rental_group_guard` copies name/colour onto a grouped row and refuses a foreign tenant (`rental_group_invalid`); `rental_group_changed` propagates a group edit; `rental_group_prune` deletes a group with its last date. A lone one-time rental has no group. | select approved/kiosk; write admin. |
```

a v řádku `rentals` za `color (−2 = default tint).` vlož `**Grouped dates** (0041): \`group_id\` — see \`rental_groups\`.`. Do `## Checks` (odrážka `supabase/tests/tenancy_rls.sql`) připoj: `the 0041 rental groups (one-time dates only, name/colour copied and propagated, a grouped date blocks like a lone rental, the group vanishes with its last date, invisible across tenants, full-DML privileges)`.

- [ ] **Step 8: Commit**

```bash
cd ~/Home/rezervator && git add supabase/migrations/0041_rental_groups.sql supabase/tests/tenancy_rls.sql supabase/schema.sql docs/SCHEMA.md && git commit -q -F - <<'EOF'
feat(db): rental_groups — jeden nájemce, víc jednorázových termínů (0041)

Skupina drží jen jméno a barvu; termín zůstává obyčejný jednorázový řádek
rentals, takže rental_occurrences ani kaskáda se nemění. Guard kopíruje
jméno/barvu a odmítá cizí tenant, propagace při úpravě skupiny, prune s
posledním termínem. Série do skupiny nesmí (check).

Falzifikováno: bez prune triggeru padá "an empty group survived", bez
shape checku "a weekly series joined a group".

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
EOF
```

---

### Task 2: RPC `rental_add_date`

**Files:**
- Modify: `supabase/migrations/0041_rental_groups.sql` (připojit na konec)
- Modify: `supabase/tests/tenancy_rls.sql` (za bloky z Task 1, před `reset role;` bloku práv), `supabase/schema.sql`, `docs/SCHEMA.md` (`## RPCs`)

**Interfaces:**
- Consumes: `rental_groups`, `rentals.group_id`, `rental_group_guard` (Task 1).
- Produces: `rental_add_date(p_rental uuid, p_date date, p_starts_at time, p_ends_at time, p_lanes smallint[], p_note text default '') returns uuid` — id nového termínu; chyby `not_authenticated`, `not_allowed`, `unknown_rental`.

- [ ] **Step 1: Testy (padají)**

Vlož **za** blok `OK: a rental group is invisible…` a **před** `reset role;` bloku práv z Task 1 (stále pod claims admina A):

```sql
do $$
declare
  v_uid constant uuid := '10000000-0000-0000-0000-000000000001';
  v_lone uuid;
  v_new uuid;
  v_new2 uuid;
  v_series uuid;
  v_g uuid;
  v_g2 uuid;
  v_d date := (now() at time zone 'Europe/Prague')::date + 120;
begin
  insert into rentals (renter_name, lanes, date, starts_at, ends_at, color,
                       created_by)
  values ('Firma L', '{1}', v_d, '20:00', '21:00', 4, v_uid)
  returning id into v_lone;

  -- a lone rental adopts a group with the new date
  v_new := rental_add_date(v_lone, v_d + 3, '19:00', '20:00', '{2,3}',
                           'druhý termín');
  select group_id into v_g from rentals where id = v_lone;
  if v_g is null then
    raise exception 'FAIL: the lone rental did not adopt a group';
  end if;
  select group_id into v_g2 from rentals where id = v_new;
  if v_g2 is distinct from v_g then
    raise exception 'FAIL: the new date is not in the same group';
  end if;
  if (select renter_name from rental_groups where id = v_g) <> 'Firma L'
     or (select color from rental_groups where id = v_g) <> 4 then
    raise exception 'FAIL: the group did not take the rental''s name and colour';
  end if;
  if (select note from rentals where id = v_new) <> 'druhý termín'
     or (select lanes from rentals where id = v_new) <> '{2,3}'::smallint[]
     or (select starts_at from rentals where id = v_new) <> '19:00'::time then
    raise exception 'FAIL: the new date lost its own lanes, time or note';
  end if;

  -- a second call reuses the group
  v_new2 := rental_add_date(v_new, v_d + 10, '20:00', '21:00', '{1}');
  if (select count(*) from rentals where group_id = v_g) <> 3 then
    raise exception 'FAIL: expected three dates in the group';
  end if;

  -- a weekly series has exceptions, not dates
  insert into rentals (renter_name, lanes, weekday, starts_at, ends_at,
                       created_by)
  values ('Firma S', '{1}', 2, '20:00', '21:00', v_uid)
  returning id into v_series;
  begin
    perform rental_add_date(v_series, v_d, '20:00', '21:00', '{1}');
    raise exception 'FAIL: a date was added to a weekly series';
  exception when others then
    if sqlerrm <> 'unknown_rental' then raise; end if;
  end;
  begin
    perform rental_add_date(gen_random_uuid(), v_d, '20:00', '21:00', '{1}');
    raise exception 'FAIL: an unknown rental accepted a date';
  exception when others then
    if sqlerrm <> 'unknown_rental' then raise; end if;
  end;
  raise notice 'OK: rental_add_date adopts a lone rental into a group and grows it; series and strangers are refused (0041)';
end $$;

-- Not an admin: refused before anything is looked up.
set local request.jwt.claims =
  '{"sub":"10000000-0000-0000-0000-000000000003","role":"authenticated"}';
do $$
begin
  begin
    perform rental_add_date(gen_random_uuid(),
      (now() at time zone 'Europe/Prague')::date + 5, '20:00', '21:00', '{1}');
    raise exception 'FAIL: a non-admin added a rental date';
  exception when others then
    if sqlerrm <> 'not_allowed' then raise; end if;
  end;
  raise notice 'OK: rental_add_date is admin-only (0041)';
end $$;
set local request.jwt.claims =
  '{"sub":"10000000-0000-0000-0000-000000000001","role":"authenticated"}';
```

A do bloku práv (Task 1, po `reset role;`) před jeho `raise notice` přidej:

```sql
  if not has_function_privilege('authenticated',
       'rental_add_date(uuid, date, time, time, smallint[], text)', 'execute') then
    raise exception 'FAIL: the app cannot call rental_add_date';
  end if;
  if has_function_privilege('anon',
       'rental_add_date(uuid, date, time, time, smallint[], text)', 'execute') then
    raise exception 'FAIL: anon can call rental_add_date';
  end if;
```

Run (stejný příkaz jako Task 1 Step 5). Expected: `ERROR:  function rental_add_date(uuid, date, ...) does not exist`.

- [ ] **Step 2: RPC**

Připoj na konec `0041_rental_groups.sql`:

```sql
-- ---------------------------------------------------------------------------
-- rental_add_date: jediný zápis, který sahá na víc řádků najednou.
-- ---------------------------------------------------------------------------
-- Přidání termínu k pronájmu, který skupinu ještě nemá: skupina vznikne z jeho
-- jména a barvy, řádek si ji osvojí a nový termín se zapíše k ní — v jedné
-- transakci. Ostatní zápisy (úprava termínu, skupiny, mazání) jdou přímo přes
-- RLS; tohle RPC je tu kvůli atomicitě, ne kvůli oprávněním.
-- Chyby ve stylu set_match_exception (0039).
create or replace function rental_add_date(
  p_rental uuid, p_date date, p_starts_at time, p_ends_at time,
  p_lanes smallint[], p_note text default '')
returns uuid
language plpgsql security definer set search_path = public
as $$
declare
  v_src rentals;
  v_group uuid;
  v_new uuid;
begin
  if auth.uid() is null then
    raise exception 'not_authenticated';
  end if;
  if not is_admin() then
    raise exception 'not_allowed';
  end if;
  select * into v_src from rentals
   where id = p_rental and tenant_id = current_tenant_id();
  -- Týdenní série termíny nepřidává — má výjimky (0021).
  if not found or v_src.parent_id is not null or v_src.weekday is not null then
    raise exception 'unknown_rental';
  end if;

  v_group := v_src.group_id;
  if v_group is null then
    insert into rental_groups (tenant_id, renter_name, color, created_by)
    values (v_src.tenant_id, v_src.renter_name, v_src.color, auth.uid())
    returning id into v_group;
    update rentals set group_id = v_group where id = v_src.id;
  end if;

  insert into rentals (tenant_id, group_id, renter_name, color, date, lanes,
                       starts_at, ends_at, note, created_by)
  values (v_src.tenant_id, v_group, v_src.renter_name, v_src.color, p_date,
          p_lanes, p_starts_at, p_ends_at, coalesce(p_note, ''), auth.uid())
  returning id into v_new;
  return v_new;
end;
$$;
revoke all on function rental_add_date(uuid, date, time, time, smallint[], text)
  from public, anon;
grant execute on function rental_add_date(uuid, date, time, time, smallint[], text)
  to authenticated, service_role;
```

- [ ] **Step 3: Spustit testy**

Stejný příkaz jako Task 1 Step 5, grep rozšiř o `rental_add_date`. Expected: `OK: rental_add_date adopts…`, `OK: rental_add_date is admin-only`, práva zelená, nic červeného.

- [ ] **Step 4: Falzifikovat**

V RPC dočasně nahraď `if not found or v_src.parent_id is not null or v_src.weekday is not null then` za `if not found then` → reset + psql → očekáváno `FAIL: a date was added to a weekly series`. Vrať.

- [ ] **Step 5: Snapshot, docs, commit**

```bash
cd ~/Home/rezervator && tool/schema_snapshot.sh
```
`docs/SCHEMA.md` `## RPCs` — přidej řádek:

```markdown
| `rental_add_date(rental, date, starts_at, ends_at, lanes, note)` | admin | Adds a one-time date next to `rental` (a one-time row of the caller's tenant): creates its `rental_groups` row from the rental's name/colour and adopts it when it has none, then inserts the date with its own lanes/times/note. Returns the new row id. Raises `not_authenticated`, `not_allowed`, `unknown_rental` (foreign, exception or weekly row). |
```

```bash
cd ~/Home/rezervator && git add supabase/migrations/0041_rental_groups.sql supabase/tests/tenancy_rls.sql supabase/schema.sql docs/SCHEMA.md && git commit -q -F - <<'EOF'
feat(db): rental_add_date — termín navíc k pronájmu, skupina vzniká až druhým

Jediný zápis přes víc řádků: osvojení řádku bez skupiny + nový termín v jedné
transakci. Série a cizí řádky vrací unknown_rental, neadmin not_allowed.

Falzifikováno: bez kontroly weekday/parent_id padá "a date was added to a
weekly series".

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
EOF
```

---

### Task 3: Doména — `Rental.groupId`, `RentalGroup`, `rentalGroupsOf`, popisky

**Files:**
- Modify: `lib/domain/models.dart` (třída `Rental`, řádky ~610–712)
- Create: `lib/domain/rental_groups.dart`
- Modify: `lib/domain/labels.dart` (za `rentalExceptionCountLabel`)
- Test: `test/domain/rental_groups_test.dart` (nový), `test/domain/labels_test.dart`

**Interfaces:**
- Produces: `Rental.groupId` (`String?`, z JSON `group_id`); `class RentalGroup { String? id; String renterName; int color; List<Rental> dates; Day? nextDate(Day today); }`; `List<RentalGroup> rentalGroupsOf(List<Rental> rentals, {required Day today})`; `String rentalDateCountLabel(int n)`; `String rentalMoreDatesLabel(int n)`.

- [ ] **Step 1: Testy (padají)**

`test/domain/rental_groups_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:rezervator/domain/models.dart';
import 'package:rezervator/domain/rental_groups.dart';

void main() {
  final today = Day(2026, 9, 15);
  Rental date({
    required String id,
    required String name,
    required Day day,
    String? group,
    int color = -2,
    HourMinute start = const HourMinute(18, 0),
  }) =>
      Rental(
        id: id,
        renterName: name,
        lanes: const [1],
        date: day,
        weekday: null,
        startsAt: start,
        endsAt: const HourMinute(20, 0),
        validFrom: null,
        validUntil: null,
        note: '',
        color: color,
        groupId: group,
      );
  final series = Rental(
    id: 's',
    renterName: 'Série',
    lanes: const [1],
    date: null,
    weekday: DateTime.thursday,
    startsAt: const HourMinute(18, 0),
    endsAt: const HourMinute(20, 0),
    validFrom: null,
    validUntil: null,
    note: '',
  );
  final exception = Rental(
    id: 'x',
    renterName: 'Série',
    lanes: const [1],
    date: Day(2026, 9, 17),
    weekday: null,
    startsAt: const HourMinute(18, 0),
    endsAt: const HourMinute(20, 0),
    validFrom: null,
    validUntil: null,
    note: '',
    parentId: 's',
  );

  group('rentalGroupsOf', () {
    test('rows of one group_id become one group, dates chronological', () {
      final groups = rentalGroupsOf([
        date(id: 'b', name: 'Firma', day: Day(2026, 10, 3), group: 'g1'),
        date(id: 'a', name: 'Firma', day: Day(2026, 9, 20), group: 'g1'),
      ], today: today);
      expect(groups, hasLength(1));
      expect(groups.single.id, 'g1');
      expect(groups.single.renterName, 'Firma');
      expect(groups.single.dates.map((d) => d.id), ['a', 'b']);
    });

    test('a lone one-time rental is a group of one with a null id', () {
      final groups = rentalGroupsOf(
          [date(id: 'l', name: 'Oslava', day: Day(2026, 9, 20))],
          today: today);
      expect(groups.single.id, isNull);
      expect(groups.single.dates.single.id, 'l');
    });

    test('weekly series and exception rows are not groups', () {
      expect(rentalGroupsOf([series, exception], today: today), isEmpty);
    });

    test('groups sort by their next upcoming date', () {
      final groups = rentalGroupsOf([
        date(id: 'far', name: 'Pozdější', day: Day(2026, 11, 1), group: 'g2'),
        date(id: 'near', name: 'Bližší', day: Day(2026, 9, 20)),
        // g3 has a past date and a later one — its NEXT date decides.
        date(id: 'old', name: 'Smíšená', day: Day(2026, 9, 1), group: 'g3'),
        date(id: 'mid', name: 'Smíšená', day: Day(2026, 10, 1), group: 'g3'),
      ], today: today);
      expect(groups.map((g) => g.renterName), ['Bližší', 'Smíšená', 'Pozdější']);
    });

    test('groups with only past dates go last, most recently ended first',
        () {
      final groups = rentalGroupsOf([
        date(id: 'p1', name: 'Dávno', day: Day(2026, 5, 1)),
        date(id: 'p2', name: 'Nedávno', day: Day(2026, 9, 10)),
        date(id: 'u', name: 'Budoucí', day: Day(2026, 9, 30)),
      ], today: today);
      expect(groups.map((g) => g.renterName), ['Budoucí', 'Nedávno', 'Dávno']);
      expect(groups[1].nextDate(today), isNull);
    });

    test('same next date sorts by renter name, Czech collation', () {
      // Names picked so plain compareTo CANNOT produce this order: Czech
      // sorts "ch" after "h" (Hora before Chalupa) and Š before Z, while
      // code points give Chalupa, Hora, Zeman, Šimek. Swap compareCzech for
      // compareTo and this test fails — which is the point of having it.
      final groups = rentalGroupsOf([
        date(id: '1', name: 'Zeman', day: Day(2026, 9, 20)),
        date(id: '2', name: 'Chalupa', day: Day(2026, 9, 20)),
        date(id: '3', name: 'Šimek', day: Day(2026, 9, 20)),
        date(id: '4', name: 'Hora', day: Day(2026, 9, 20)),
      ], today: today);
      expect(groups.map((g) => g.renterName),
          ['Hora', 'Chalupa', 'Šimek', 'Zeman']);
    });

    test('today counts as upcoming', () {
      final groups = rentalGroupsOf(
          [date(id: 't', name: 'Dnes', day: today)],
          today: today);
      expect(groups.single.nextDate(today), today);
    });
  });
}
```

Do `test/domain/labels_test.dart` přidej skupinu:

```dart
  group('rental date labels', () {
    test('counts dates three ways', () {
      expect(rentalDateCountLabel(1), '1 termín');
      expect(rentalDateCountLabel(2), '2 termíny');
      expect(rentalDateCountLabel(4), '4 termíny');
      expect(rentalDateCountLabel(5), '5 termínů');
    });
    test('names the dates a tile leaves out', () {
      expect(rentalMoreDatesLabel(1), '…a ještě 1 termín');
      expect(rentalMoreDatesLabel(3), '…a další 3 termíny');
      expect(rentalMoreDatesLabel(5), '…a dalších 5 termínů');
    });
  });
```
(`test/domain/labels_test.dart` už `package:rezervator/domain/labels.dart` importuje — nic nepřidávej.)

Run: `flutter test test/domain/rental_groups_test.dart test/domain/labels_test.dart`
Expected: chyba kompilace (`groupId` není parametr, `rental_groups.dart` neexistuje).

- [ ] **Step 2: Model**

V `lib/domain/models.dart`, třída `Rental`: do konstruktoru přidej `this.groupId,` (za `this.overrideId,`), pole

```dart
  /// The rental_groups row this one-time date belongs to (0041) — null on a
  /// lone one-time rental, a weekly series and an exception row. Name and
  /// colour on a grouped row mirror the group (the server copies them).
  final String? groupId;
```

a do `fromJson`: `groupId: json['group_id'] as String?,`. (`overriddenBy` se nemění — série skupinu nemá.)

- [ ] **Step 3: Doména**

`lib/domain/rental_groups.dart`:

```dart
/// Nepravidelné pronájmy jako skupiny: jeden nájemce, víc jednorázových
/// termínů (0041). Čistý Dart — seskupení i řazení žije tady, ne ve
/// widgetech.
library;

import 'collation.dart';
import 'models.dart';

/// One renter's one-time dates. [id] is the rental_groups row, or null for
/// a lone one-time rental — the UI treats both the same way; the group
/// appears server-side with the second date (rental_add_date).
class RentalGroup {
  const RentalGroup({
    required this.id,
    required this.renterName,
    required this.color,
    required this.dates,
  });

  final String? id;
  final String renterName;
  final int color;

  /// Chronological, never empty; every row has [Rental.date].
  final List<Rental> dates;

  /// The first date on or after [today], null when all are past.
  Day? nextDate(Day today) {
    for (final d in dates) {
      if (!d.date!.isBefore(today)) return d.date;
    }
    return null;
  }
}

/// Groups the one-time rows of [rentals] — by `group_id`, a lone row as a
/// group of one — and skips weekly series and exception rows. Groups sort
/// by their next upcoming date; those with nothing ahead go last, the most
/// recently ended first; ties by renter name (Czech collation).
List<RentalGroup> rentalGroupsOf(List<Rental> rentals, {required Day today}) {
  final byGroup = <String, List<Rental>>{};
  final lone = <Rental>[];
  for (final r in rentals) {
    if (r.parentId != null || r.date == null) continue;
    final g = r.groupId;
    if (g == null) {
      lone.add(r);
    } else {
      (byGroup[g] ??= []).add(r);
    }
  }
  int byDate(Rental a, Rental b) {
    final c = a.date!.compareTo(b.date!);
    return c != 0 ? c : a.startsAt.compareTo(b.startsAt);
  }
  final groups = [
    for (final e in byGroup.entries)
      RentalGroup(
        id: e.key,
        renterName: e.value.first.renterName,
        color: e.value.first.color,
        dates: e.value..sort(byDate),
      ),
    for (final r in lone)
      RentalGroup(id: null, renterName: r.renterName, color: r.color, dates: [r]),
  ];
  groups.sort((a, b) {
    final na = a.nextDate(today);
    final nb = b.nextDate(today);
    if (na != null && nb != null) {
      final c = na.compareTo(nb);
      if (c != 0) return c;
    } else if (na != null) {
      return -1;
    } else if (nb != null) {
      return 1;
    } else {
      final c = b.dates.last.date!.compareTo(a.dates.last.date!);
      if (c != 0) return c;
    }
    return compareCzech(a.renterName, b.renterName);
  });
  return groups;
}
```

`lib/domain/labels.dart`, za `rentalExceptionCountLabel`:

```dart
/// "1 termín" / "2 termíny" / "5 termínů".
String rentalDateCountLabel(int n) {
  if (n == 1) return '1 termín';
  if (n >= 2 && n <= 4) return '$n termíny';
  return '$n termínů';
}

/// The tail of a group tile: how many dates its two shown lines leave out.
String rentalMoreDatesLabel(int n) {
  if (n == 1) return '…a ještě 1 termín';
  if (n >= 2 && n <= 4) return '…a další $n termíny';
  return '…a dalších $n termínů';
}
```

- [ ] **Step 4: Testy zelené + falzifikace**

Run: `flutter test test/domain/rental_groups_test.dart test/domain/labels_test.dart` → Expected: `All tests passed!`
Falzifikace: v `rentalGroupsOf` dočasně vrať `else if (na != null) return 1; else if (nb != null) return -1;` (prohodit) → test `groups with only past dates go last` musí spadnout. Vrať.

- [ ] **Step 5: Commit**

```bash
cd ~/Home/rezervator && git add lib/domain/models.dart lib/domain/rental_groups.dart lib/domain/labels.dart test/domain/rental_groups_test.dart test/domain/labels_test.dart && git commit -q -F - <<'EOF'
feat(domain): skupiny nepravidelných pronájmů — rentalGroupsOf, popisky

Rental nese group_id; rentalGroupsOf z plochého seznamu udělá skupiny
(osamělý jednorázový = skupina o jednom), seřazené podle nejbližšího
nadcházejícího termínu, proběhlé na konec.

Falzifikováno: s prohozeným řazením minulých padá "groups with only past
dates go last".

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
EOF
```

---

### Task 4: `Api` + `friendlyDbError` + `RentalDateDialog`

**Files:**
- Modify: `lib/data/providers.dart` (za `saveRentalException`, ~řádek 824), `lib/core/ui.dart` (`friendlyDbError`, za `'unknown_reservation'`)
- Create: `lib/features/admin/widgets/rental_date_dialog.dart`
- Test: `test/features/rental_date_dialog_test.dart`

**Interfaces:**
- Consumes: `Rental.groupId` (Task 3); `PickerTile`, `LaneChips` (`form_fields.dart`), `FormDialog<bool>` (`form_dialog.dart`), `pickDay`, `snack`, `tryAction`, `friendlyDbError`, `dayFull`, `today` (`core/ui.dart`).
- Produces: `Api.saveRentalDate({required String id, required String renterName, required int color, required Day date, required List<int> lanes, required HourMinute startsAt, required HourMinute endsAt, String note = ''})`; `Api.addRentalDate({required String rentalId, required Day date, required HourMinute startsAt, required HourMinute endsAt, required List<int> lanes, String note = ''}) → Future<String>`; `Api.saveRentalGroup({required String id, required String renterName, required int color})`; `Api.deleteRentalGroup(String id)`; `class RentalDateDialog extends StatefulWidget { RentalDateDialog({required Rental anchor, Rental? existing, required int laneCount}) }` — pops `true` po uložení.

- [ ] **Step 1: Test (padá)**

`test/features/rental_date_dialog_test.dart`:

```dart
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:rezervator/domain/models.dart';
import 'package:rezervator/features/admin/widgets/rental_date_dialog.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Pins the date dialog at the HTTP layer: a new date goes through the RPC,
/// an edit is a plain row update carrying the group's name, and the form
/// refuses what the server would.
void main() {
  final anchor = Rental(
    id: 'r1',
    renterName: 'Firma Trak',
    lanes: const [1, 2],
    date: Day(2026, 10, 15),
    weekday: null,
    startsAt: const HourMinute(18, 0),
    endsAt: const HourMinute(20, 0),
    validFrom: null,
    validUntil: null,
    note: '',
    color: 3,
    groupId: 'g1',
  );
  final existing = Rental(
    id: 'r2',
    renterName: 'Firma Trak',
    lanes: const [2],
    date: Day(2026, 10, 22),
    weekday: null,
    startsAt: const HourMinute(19, 0),
    endsAt: const HourMinute(21, 0),
    validFrom: null,
    validUntil: null,
    note: 'bez rozbrusu',
    color: 3,
    groupId: 'g1',
  );

  late List<http.Request> requests;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues({});
    final mock = MockClient((request) async {
      requests.add(request);
      final body = request.url.path.endsWith('/rpc/rental_add_date')
          ? '"new-id"'
          : '{}';
      return http.Response(body, 200,
          headers: {'content-type': 'application/json'}, request: request);
    });
    await Supabase.initialize(
      url: 'http://localhost:54321',
      publishableKey: 'test-anon-key',
      httpClient: mock,
      authOptions: const FlutterAuthClientOptions(
        detectSessionInUri: false,
        localStorage: EmptyLocalStorage(),
      ),
    );
  });

  setUp(() => requests = []);

  Future<void> open(WidgetTester tester, RentalDateDialog dialog) async {
    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      supportedLocales: const [Locale('cs')],
      home: Scaffold(
        body: Builder(
          builder: (context) => Center(
            child: TextButton(
              onPressed: () =>
                  showDialog<bool>(context: context, builder: (_) => dialog),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  Map<String, dynamic> bodyOf(http.Request r) =>
      jsonDecode(r.body) as Map<String, dynamic>;

  testWidgets('a new date pre-fills lanes and times from the anchor and is '
      'added through rental_add_date', (tester) async {
    await open(tester, RentalDateDialog(anchor: anchor, laneCount: 3));
    expect(find.text('Přidat termín'), findsOneWidget);
    expect(find.text('Vybrat'), findsOneWidget, reason: 'the date is not guessed');
    expect(find.text('18:00'), findsOneWidget);
    expect(find.text('20:00'), findsOneWidget);

    // Pick the 20th of the anchor's month in the calendar.
    await tester.tap(find.text('Vybrat'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('20'));
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Uložit'));
    await tester.pumpAndSettle();

    final rpc = requests.singleWhere(
        (r) => r.url.path.endsWith('/rpc/rental_add_date'));
    expect(rpc.method, 'POST');
    final body = bodyOf(rpc);
    expect(body['p_rental'], 'r1');
    expect(body['p_date'], '2026-10-20');
    expect(body['p_starts_at'], '18:00:00');
    expect(body['p_ends_at'], '20:00:00');
    expect(body['p_lanes'], [1, 2]);
    expect(body['p_note'], '');
    expect(find.text('Přidat termín'), findsNothing, reason: 'popped');
  });

  testWidgets('editing a date updates its row and carries the group name',
      (tester) async {
    await open(tester,
        RentalDateDialog(anchor: anchor, existing: existing, laneCount: 3));
    expect(find.text('Upravit termín'), findsOneWidget);
    expect(find.text('bez rozbrusu'), findsOneWidget);

    await tester.tap(find.text('Dráha 3'));
    await tester.pump();
    await tester.tap(find.text('Uložit'));
    await tester.pumpAndSettle();

    final patch = requests.singleWhere((r) => r.method == 'PATCH');
    expect(patch.url.path, '/rest/v1/rentals');
    expect(patch.url.queryParameters['id'], 'eq.r2');
    final body = bodyOf(patch);
    expect(body['renter_name'], 'Firma Trak');
    expect(body['color'], 3);
    expect(body['date'], '2026-10-22');
    expect(body['lanes'], [2, 3]);
    expect(body['note'], 'bez rozbrusu');
    expect(body.containsKey('group_id'), isFalse,
        reason: 'the row keeps its group; the update must not touch it');
  });

  testWidgets('refuses a missing date', (tester) async {
    await open(tester, RentalDateDialog(anchor: anchor, laneCount: 3));
    await tester.tap(find.text('Uložit'));
    await tester.pump();
    expect(find.text('Vyber datum.'), findsOneWidget);
    expect(requests, isEmpty);
  });
}
```

Run: `flutter test test/features/rental_date_dialog_test.dart` → Expected: chyba kompilace (soubor dialogu neexistuje).

**Pozn. z realizace:** fixtury dat musí být odvozené od `today()`, ne natvrdo — okno pickeru je `[dnes−365, dnes+730]`, takže pevné datum ze sady po roce vypadne a testy zčervenají bez jakékoli změny kódu. A pojistka na prázdné dráhy potřebuje vlastní test (datum se kontroluje dřív, dráhy jsou předvyplněné z kotvy, takže v původním testu byla nedosažitelná).

- [ ] **Step 2: `Api` a `friendlyDbError`**

`lib/data/providers.dart`, za `saveRentalException` (před `deleteRental`):

```dart
  /// One date of a nepravidelný pronájem (or a lone one-time rental): its
  /// own lanes, times and note. The group's name and colour ride along the
  /// way an exception carries its series' (the server re-copies them anyway,
  /// rental_group_guard); group_id is deliberately NOT in the row — the
  /// update must not move the date between groups.
  static Future<void> saveRentalDate({
    required String id,
    required String renterName,
    required int color,
    required Day date,
    required List<int> lanes,
    required HourMinute startsAt,
    required HourMinute endsAt,
    String note = '',
  }) =>
      _db.from('rentals').update({
        'renter_name': renterName,
        'color': color,
        'date': date.toSql(),
        'weekday': null,
        'valid_from': null,
        'valid_until': null,
        'lanes': lanes,
        'starts_at': startsAt.toSql(),
        'ends_at': endsAt.toSql(),
        'note': note,
      }).eq('id', id);

  /// Adds a date next to [rentalId] — the group is created and the row
  /// adopted server-side when it has none (rental_add_date, 0041). Returns
  /// the new row's id.
  static Future<String> addRentalDate({
    required String rentalId,
    required Day date,
    required HourMinute startsAt,
    required HourMinute endsAt,
    required List<int> lanes,
    String note = '',
  }) async =>
      await _db.rpc('rental_add_date', params: {
        'p_rental': rentalId,
        'p_date': date.toSql(),
        'p_starts_at': startsAt.toSql(),
        'p_ends_at': endsAt.toSql(),
        'p_lanes': lanes,
        'p_note': note,
      }) as String;

  /// Name and colour of a group; rental_group_changed propagates them.
  static Future<void> saveRentalGroup({
    required String id,
    required String renterName,
    required int color,
  }) =>
      _db
          .from('rental_groups')
          .update({'renter_name': renterName, 'color': color}).eq('id', id);

  /// The whole nepravidelný pronájem — its dates go with it (cascade).
  static Future<void> deleteRentalGroup(String id) =>
      _db.from('rental_groups').delete().eq('id', id);
```

`lib/core/ui.dart`, do mapy `friendlyDbError` za `'unknown_reservation': …`:

```dart
    'unknown_rental': 'Tenhle pronájem už neexistuje.',
    'rental_group_invalid': 'Termín nejde přiřadit k tomuhle pronájmu.',
```

- [ ] **Step 3: Dialog**

`lib/features/admin/widgets/rental_date_dialog.dart`:

```dart
import 'package:flutter/material.dart';

import '../../../core/ui.dart';
import '../../../data/providers.dart';
import '../../../domain/models.dart';
import 'form_dialog.dart';
import 'form_fields.dart';

/// One date of a nepravidelný pronájem: date (calendar), times, lanes,
/// note. [existing] edits that row; otherwise the date is added next to
/// [anchor] — the row the list was opened from — whose lanes and times
/// pre-fill the form (the date never is: a wrong guess left in place
/// would book the wrong day). Pops `true` after a save.
class RentalDateDialog extends StatefulWidget {
  const RentalDateDialog({
    super.key,
    required this.anchor,
    this.existing,
    required this.laneCount,
  });

  /// A date of the same rental — supplies id (for rental_add_date), name,
  /// colour and the pre-fill.
  final Rental anchor;
  final Rental? existing;
  final int laneCount;

  @override
  State<RentalDateDialog> createState() => _RentalDateDialogState();
}

class _RentalDateDialogState extends State<RentalDateDialog> {
  final _note = TextEditingController();
  Day? _date;
  HourMinute? _start;
  HourMinute? _end;
  Set<int> _lanes = {};

  @override
  void initState() {
    super.initState();
    final source = widget.existing ?? widget.anchor;
    _date = widget.existing?.date;
    _start = source.startsAt;
    _end = source.endsAt;
    _lanes = source.lanes.toSet();
    _note.text = widget.existing?.note ?? '';
  }

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  Future<void> _pickDate() async {
    final earliest = today().addDays(-365);
    final picked = await pickDay(
      context,
      initial: _date ?? widget.anchor.date,
      first: earliest,
      last: earliest.addDays(365 * 3),
    );
    if (picked != null) setState(() => _date = picked);
  }

  Future<void> _pickStart() async {
    final t = await pickTime(context, initial: _start);
    if (t != null) setState(() => _start = t);
  }

  Future<void> _pickEnd() async {
    final t = await pickTime(context, initial: _end);
    if (t != null) setState(() => _end = t);
  }

  Future<bool?> _save() async {
    final date = _date;
    if (date == null) {
      snack(context, 'Vyber datum.');
      return null;
    }
    final start = _start;
    final end = _end;
    if (start == null || end == null) {
      snack(context, 'Vyber začátek i konec.');
      return null;
    }
    if (end.compareTo(start) <= 0) {
      snack(context, 'Konec musí být po začátku.');
      return null;
    }
    if (_lanes.isEmpty) {
      snack(context, 'Vyber aspoň jednu dráhu.');
      return null;
    }
    final lanes = _lanes.toList()..sort();
    final note = _note.text.trim();
    final existing = widget.existing;
    final ok = await tryAction(
      context,
      () => existing == null
          ? Api.addRentalDate(
              rentalId: widget.anchor.id,
              date: date,
              startsAt: start,
              endsAt: end,
              lanes: lanes,
              note: note,
            )
          : Api.saveRentalDate(
              id: existing.id,
              renterName: widget.anchor.renterName,
              color: widget.anchor.color,
              date: date,
              lanes: lanes,
              startsAt: start,
              endsAt: end,
              note: note,
            ),
      success: 'Termín uložen. Kolidující rezervace byly zrušeny.',
      errorText: friendlyDbError,
    );
    return ok ? true : null;
  }

  @override
  Widget build(BuildContext context) {
    return FormDialog<bool>(
      title: widget.existing == null ? 'Přidat termín' : 'Upravit termín',
      onSave: _save,
      children: [
        PickerTile(
          label: 'Datum',
          value: _date == null ? 'Vybrat' : dayFull(_date!),
          onTap: _pickDate,
        ),
        PickerTile(
          label: 'Začátek',
          value: _start?.display() ?? '--:--',
          onTap: _pickStart,
        ),
        PickerTile(
          label: 'Konec',
          value: _end?.display() ?? '--:--',
          onTap: _pickEnd,
        ),
        const SizedBox(height: 8),
        LaneChips(
          laneCount: widget.laneCount,
          selected: _lanes,
          onChanged: (lanes) => setState(() => _lanes = lanes),
        ),
        const SizedBox(height: 8),
        TextField(
          controller: _note,
          decoration: const InputDecoration(labelText: 'Poznámka'),
        ),
      ],
    );
  }
}
```

`pickTime(context, initial:)` je existující helper v `core/ui.dart` (24h výběr času, vrací `HourMinute?`) — stejný, který volá `RentalDialog`.

- [ ] **Step 4: Testy zelené + falzifikace**

Run: `flutter test test/features/rental_date_dialog_test.dart` → `All tests passed!`.
Falzifikace: v `saveRentalDate` dočasně přidej do mapy `'group_id': null` → test `editing a date…` padá na `containsKey('group_id')`. Vrať.

- [ ] **Step 5: Commit**

```bash
cd ~/Home/rezervator && git add lib/data/providers.dart lib/core/ui.dart lib/features/admin/widgets/rental_date_dialog.dart test/features/rental_date_dialog_test.dart && git commit -q -F - <<'EOF'
feat(admin): dialog jednoho termínu — přidání přes rental_add_date, úprava řádku

Nový termín jde přes RPC (skupina vzniká na serveru), úprava je prostý update
nesoucí jméno a barvu skupiny a nikdy group_id. Datum se nehádá; dráhy a čas
se předvyplní z termínu, ze kterého se přidává.

Falzifikováno: s group_id v update padá "editing a date updates its row".

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
EOF
```

---

### Task 5: `RentalDatesDialog` (seznam termínů) a `RentalGroupDialog` (jméno, barva)

**Files:**
- Create: `lib/features/admin/widgets/rental_dates_dialog.dart`, `lib/features/admin/widgets/rental_group_dialog.dart`
- Test: `test/features/rental_dates_dialog_test.dart`, `test/features/rental_group_dialog_test.dart`

**Interfaces:**
- Consumes: `RentalGroup`, `rentalGroupsOf` (Task 3); `RentalDateDialog`, `Api.saveRentalGroup`, `Api.deleteRentalGroup`, `Api.saveRental`, `Api.deleteRental` (Task 4 / existing); `rentalsProvider`; `confirmDelete`, `dayFull`, `today`; `ColorPickerGrid` (`color_picker.dart`, parametry `selected`, `noneValue: -2`, `noneLabel: 'Výchozí'`, `onChanged`).
- Produces: `class RentalDatesDialog extends ConsumerWidget { RentalDatesDialog({required RentalGroup group, required int laneCount}) }`; `class RentalGroupDialog extends StatefulWidget { RentalGroupDialog({required RentalGroup group}) }` — pops `true` po uložení.

- [ ] **Step 1: Testy (padají)**

`test/features/rental_dates_dialog_test.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:rezervator/core/ui.dart' show dayFull, today;
import 'package:rezervator/data/providers.dart';
import 'package:rezervator/domain/models.dart';
import 'package:rezervator/domain/rental_groups.dart';
import 'package:rezervator/features/admin/widgets/rental_dates_dialog.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  final next = today().addDays(10);
  final later = today().addDays(20);
  final past = today().addDays(-5);
  Rental date({
    required String id,
    required Day day,
    List<int> lanes = const [1, 2],
    String note = '',
  }) =>
      Rental(
        id: id,
        renterName: 'Firma Trak',
        lanes: lanes,
        date: day,
        weekday: null,
        startsAt: const HourMinute(18, 0),
        endsAt: const HourMinute(20, 0),
        validFrom: null,
        validUntil: null,
        note: note,
        color: 3,
        groupId: 'g1',
      );
  final rows = [
    date(id: 'd-past', day: past, lanes: const [1]),
    date(id: 'd-next', day: next, note: 'bez rozbrusu'),
    date(id: 'd-later', day: later, lanes: const [2]),
  ];

  late List<http.Request> requests;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues({});
    final mock = MockClient((request) async {
      requests.add(request);
      return http.Response('{}', 200,
          headers: {'content-type': 'application/json'}, request: request);
    });
    await Supabase.initialize(
      url: 'http://localhost:54321',
      publishableKey: 'test-anon-key',
      httpClient: mock,
      authOptions: const FlutterAuthClientOptions(
        detectSessionInUri: false,
        localStorage: EmptyLocalStorage(),
      ),
    );
  });

  setUp(() => requests = []);

  Future<void> open(WidgetTester tester, List<Rental> rentals) async {
    final group = rentalGroupsOf(rentals, today: today()).single;
    await tester.pumpWidget(ProviderScope(
      overrides: [
        rentalsProvider.overrideWith((ref) => Stream.value(rentals)),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: TextButton(
                onPressed: () => showDialog<void>(
                  context: context,
                  builder: (_) =>
                      RentalDatesDialog(group: group, laneCount: 3),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  testWidgets('lists the dates chronologically with lanes, times and note; '
      'a past date is shown but inert', (tester) async {
    await open(tester, rows);
    expect(find.text('Termíny · Firma Trak'), findsOneWidget);
    expect(find.text(dayFull(past)), findsOneWidget);
    expect(find.text(dayFull(next)), findsOneWidget);
    expect(find.text(dayFull(later)), findsOneWidget);
    expect(find.text('18:00–20:00 · dráhy 1, 2 · bez rozbrusu'), findsOneWidget);
    expect(find.text('18:00–20:00 · dráhy 2'), findsOneWidget);
    expect(
      tester.getTopLeft(find.text(dayFull(past))).dy,
      lessThan(tester.getTopLeft(find.text(dayFull(next))).dy),
    );
    final pastTile = tester.widget<ListTile>(find.ancestor(
        of: find.text(dayFull(past)), matching: find.byType(ListTile)));
    expect(pastTile.enabled, isFalse);
    expect(find.text('Přidat termín'), findsOneWidget);
    expect(find.text('Zavřít'), findsOneWidget);
  });

  testWidgets('Přidat termín opens the date dialog anchored on the last date',
      (tester) async {
    await open(tester, rows);
    await tester.tap(find.text('Přidat termín'));
    await tester.pumpAndSettle();
    // Title of the inner dialog plus the list's button: two.
    expect(find.text('Přidat termín'), findsNWidgets(2));
    // The last date (d-later) is the anchor: lane 2 only, pre-selected.
    final chip2 = tester.widget<FilterChip>(find.ancestor(
        of: find.text('Dráha 2'), matching: find.byType(FilterChip)));
    final chip1 = tester.widget<FilterChip>(find.ancestor(
        of: find.text('Dráha 1'), matching: find.byType(FilterChip)));
    expect(chip2.selected, isTrue);
    expect(chip1.selected, isFalse);
  });

  testWidgets('tapping a date opens it for editing', (tester) async {
    await open(tester, rows);
    await tester.tap(find.text(dayFull(next)));
    await tester.pumpAndSettle();
    expect(find.text('Upravit termín'), findsOneWidget);
    expect(find.text('bez rozbrusu'), findsOneWidget);
  });

  testWidgets('deleting a date confirms and deletes just that row',
      (tester) async {
    await open(tester, rows);
    final deleteButtons = find.byTooltip('Smazat termín');
    expect(deleteButtons, findsNWidgets(2), reason: 'not on the past date');
    await tester.tap(deleteButtons.first);
    await tester.pumpAndSettle();
    expect(find.text('Smazat termín?'), findsOneWidget);
    expect(find.textContaining(dayFull(next)), findsWidgets);
    await tester.tap(find.text('Ano'));
    await tester.pumpAndSettle();
    final del = requests.singleWhere((r) => r.method == 'DELETE');
    expect(del.url.path, '/rest/v1/rentals');
    expect(del.url.queryParameters['id'], 'eq.d-next');
  });
}
```

`test/features/rental_group_dialog_test.dart`:

```dart
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:rezervator/domain/models.dart';
import 'package:rezervator/domain/rental_groups.dart';
import 'package:rezervator/features/admin/widgets/rental_group_dialog.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  Rental row({String? group}) => Rental(
        id: 'r1',
        renterName: 'Firma Trak',
        lanes: const [1, 2],
        date: Day(2026, 10, 15),
        weekday: null,
        startsAt: const HourMinute(18, 0),
        endsAt: const HourMinute(20, 0),
        validFrom: null,
        validUntil: null,
        note: 'faktura',
        color: 3,
        groupId: group,
      );

  late List<http.Request> requests;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues({});
    final mock = MockClient((request) async {
      requests.add(request);
      return http.Response('{}', 200,
          headers: {'content-type': 'application/json'}, request: request);
    });
    await Supabase.initialize(
      url: 'http://localhost:54321',
      publishableKey: 'test-anon-key',
      httpClient: mock,
      authOptions: const FlutterAuthClientOptions(
        detectSessionInUri: false,
        localStorage: EmptyLocalStorage(),
      ),
    );
  });

  setUp(() => requests = []);

  Future<void> open(WidgetTester tester, RentalGroup group) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => Center(
            child: TextButton(
              onPressed: () => showDialog<bool>(
                  context: context,
                  builder: (_) => RentalGroupDialog(group: group)),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  Map<String, dynamic> bodyOf(http.Request r) =>
      jsonDecode(r.body) as Map<String, dynamic>;

  testWidgets('a grouped rental updates rental_groups', (tester) async {
    await open(tester, RentalGroup(
        id: 'g1', renterName: 'Firma Trak', color: 3, dates: [row(group: 'g1')]));
    expect(find.text('Upravit pronájem'), findsOneWidget);
    await tester.enterText(find.widgetWithText(TextField, 'Nájemce'), 'Firma Trak s.r.o.');
    await tester.tap(find.text('Uložit'));
    await tester.pumpAndSettle();
    final patch = requests.singleWhere((r) => r.method == 'PATCH');
    expect(patch.url.path, '/rest/v1/rental_groups');
    expect(patch.url.queryParameters['id'], 'eq.g1');
    expect(bodyOf(patch), {'renter_name': 'Firma Trak s.r.o.', 'color': 3});
  });

  testWidgets('a lone rental updates its own row, keeping date, lanes and '
      'note', (tester) async {
    await open(tester,
        RentalGroup(id: null, renterName: 'Firma Trak', color: 3, dates: [row()]));
    await tester.enterText(find.widgetWithText(TextField, 'Nájemce'), 'Nové jméno');
    await tester.tap(find.text('Uložit'));
    await tester.pumpAndSettle();
    final patch = requests.singleWhere((r) => r.method == 'PATCH');
    expect(patch.url.path, '/rest/v1/rentals');
    expect(patch.url.queryParameters['id'], 'eq.r1');
    final body = bodyOf(patch);
    expect(body['renter_name'], 'Nové jméno');
    expect(body['date'], '2026-10-15');
    expect(body['lanes'], [1, 2]);
    expect(body['note'], 'faktura');
    expect(body['color'], 3);
  });

  testWidgets('refuses an empty name', (tester) async {
    await open(tester, RentalGroup(
        id: 'g1', renterName: 'Firma Trak', color: 3, dates: [row(group: 'g1')]));
    await tester.enterText(find.widgetWithText(TextField, 'Nájemce'), '  ');
    await tester.tap(find.text('Uložit'));
    await tester.pump();
    expect(find.text('Vyplň nájemce.'), findsOneWidget);
    expect(requests, isEmpty);
  });
}
```

Run: `flutter test test/features/rental_dates_dialog_test.dart test/features/rental_group_dialog_test.dart` → Expected: chyba kompilace.

- [ ] **Step 2: `RentalDatesDialog`**

`lib/features/admin/widgets/rental_dates_dialog.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/ui.dart';
import '../../../data/providers.dart';
import '../../../domain/models.dart';
import '../../../domain/rental_groups.dart';
import 'rental_date_dialog.dart';

/// The dates of one nepravidelný pronájem — each opening [RentalDateDialog]
/// to edit, a delete per row and Přidat termín for a new one. Watches the
/// rentals stream itself, so the list follows adds and deletes made from
/// the dialogs it opens while it stays up — including the moment a lone
/// rental gains its group: the group is re-found by the row it was opened
/// from, not by an id it may not have had yet.
class RentalDatesDialog extends ConsumerWidget {
  const RentalDatesDialog({
    super.key,
    required this.group,
    required this.laneCount,
  });

  final RentalGroup group;
  final int laneCount;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final rentals = ref.watch(rentalsProvider).value ?? const <Rental>[];
    final now = today();
    final anchorId = group.dates.first.id;
    final live = rentalGroupsOf(rentals, today: now)
            .where((g) => g.dates.any((d) => d.id == anchorId))
            .firstOrNull ??
        group;

    return AlertDialog(
      title: Text('Termíny · ${live.renterName}'),
      content: SizedBox(
        width: 360,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (final d in live.dates) _tile(context, live, d, now),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Zavřít'),
        ),
        FilledButton.icon(
          onPressed: () => showDialog<bool>(
            context: context,
            builder: (_) => RentalDateDialog(
              anchor: live.dates.last,
              laneCount: laneCount,
            ),
          ),
          icon: const Icon(Icons.add),
          label: const Text('Přidat termín'),
        ),
      ],
    );
  }

  Widget _tile(BuildContext context, RentalGroup live, Rental d, Day now) {
    final date = d.date!;
    // A date that has passed stays on the list for the record; there is
    // nothing left to change about it.
    final past = date.isBefore(now);
    final parts = [
      '${d.startsAt.display()}–${d.endsAt.display()}',
      'dráhy ${d.lanes.join(', ')}',
      if (d.note.isNotEmpty) d.note,
    ];
    return ListTile(
      enabled: !past,
      contentPadding: EdgeInsets.zero,
      title: Text(dayFull(date)),
      subtitle: Text(parts.join(' · ')),
      onTap: () => showDialog<bool>(
        context: context,
        builder: (_) => RentalDateDialog(
          anchor: live.dates.last,
          existing: d,
          laneCount: laneCount,
        ),
      ),
      trailing: past
          ? null
          : IconButton(
              icon: const Icon(Icons.delete_outline),
              tooltip: 'Smazat termín',
              onPressed: () => confirmDelete(
                context,
                title: 'Smazat termín?',
                message: '${dayFull(date)} · ${live.renterName}: dráhy se '
                    'uvolní. Je-li to poslední termín, zmizí celý pronájem.',
                action: () => Api.deleteRental(d.id),
                success: 'Termín smazán.',
              ),
            ),
    );
  }
}
```

- [ ] **Step 3: `RentalGroupDialog`**

`lib/features/admin/widgets/rental_group_dialog.dart`:

```dart
import 'package:flutter/material.dart';

import '../../../core/ui.dart';
import '../../../data/providers.dart';
import '../../../domain/rental_groups.dart';
import 'color_picker.dart';
import 'form_dialog.dart';

/// Name and colour of a nepravidelný pronájem. A grouped one edits its
/// rental_groups row (the server propagates); a lone one-time rental has
/// no group row yet, so its own row is updated in place — date, lanes,
/// times and note unchanged. Pops `true` after a save.
class RentalGroupDialog extends StatefulWidget {
  const RentalGroupDialog({super.key, required this.group});

  final RentalGroup group;

  @override
  State<RentalGroupDialog> createState() => _RentalGroupDialogState();
}

class _RentalGroupDialogState extends State<RentalGroupDialog> {
  final _renterName = TextEditingController();
  var _color = -2;

  @override
  void initState() {
    super.initState();
    _renterName.text = widget.group.renterName;
    _color = widget.group.color;
  }

  @override
  void dispose() {
    _renterName.dispose();
    super.dispose();
  }

  Future<bool?> _save() async {
    final name = _renterName.text.trim();
    if (name.isEmpty) {
      snack(context, 'Vyplň nájemce.');
      return null;
    }
    final id = widget.group.id;
    final ok = await tryAction(
      context,
      () {
        if (id != null) {
          return Api.saveRentalGroup(id: id, renterName: name, color: _color);
        }
        final only = widget.group.dates.single;
        return Api.saveRental(
          id: only.id,
          renterName: name,
          lanes: only.lanes,
          date: only.date,
          startsAt: only.startsAt,
          endsAt: only.endsAt,
          note: only.note,
          color: _color,
        );
      },
      success: 'Pronájem uložen.',
      errorText: friendlyDbError,
    );
    return ok ? true : null;
  }

  @override
  Widget build(BuildContext context) {
    return FormDialog<bool>(
      title: 'Upravit pronájem',
      onSave: _save,
      children: [
        TextField(
          controller: _renterName,
          decoration: const InputDecoration(labelText: 'Nájemce'),
        ),
        const SizedBox(height: 16),
        Text('Barva', style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 8),
        ColorPickerGrid(
          selected: _color,
          noneValue: -2,
          noneLabel: 'Výchozí',
          onChanged: (index) => setState(() => _color = index),
        ),
      ],
    );
  }
}
```

- [ ] **Step 4: Testy zelené + falzifikace**

Run: `flutter test test/features/rental_dates_dialog_test.dart test/features/rental_group_dialog_test.dart` → `All tests passed!`.
Falzifikace: v `_RentalGroupDialogState._save` dočasně zaměň větve (`if (id == null)`) → oba první testy skupinového dialogu padnou na cestě PATCHe. Vrať. V `RentalDatesDialog._tile` dočasně `enabled: true` → padá `a past date is shown but inert`. Vrať.

- [ ] **Step 5: Commit**

```bash
cd ~/Home/rezervator && git add lib/features/admin/widgets/rental_dates_dialog.dart lib/features/admin/widgets/rental_group_dialog.dart test/features/rental_dates_dialog_test.dart test/features/rental_group_dialog_test.dart && git commit -q -F - <<'EOF'
feat(admin): seznam termínů skupiny a dialog jména/barvy

Seznam sleduje stream a skupinu hledá podle řádku, ze kterého byl otevřen —
přežije tak okamžik, kdy osamělý pronájem druhým termínem dostane skupinu.
Jméno a barva: skupina přes rental_groups, osamělý řádek na místě.

Falzifikováno: prohozené větve ukládání i zapnutý minulý termín padají.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
EOF
```

---

### Task 6: Obrazovka Pronájmy — sekce, dlaždice skupin, rozcestník; `RentalDialog` bez přepínače; changelog

**Files:**
- Modify: `lib/features/admin/widgets/rental_dialog.dart` (enum `_RentalMode` → veřejný `RentalKind`; konstruktor; `initState`; `build` bez `RadioGroup`; titul)
- Modify: `lib/features/admin/rentals_screen.dart` (celý `build`, `_tile` → `_seriesTile` + `_groupTile`, `_compareRentals` → `_compareSeries`)
- Modify: `lib/features/profile/changelog_data.dart`
- Test: `test/features/rentals_screen_test.dart` (přepsat dotčené testy, přidat nové)

**Interfaces:**
- Consumes: `rentalGroupsOf`, `RentalGroup`, `rentalMoreDatesLabel`, `rentalDateCountLabel` (Task 3); `RentalDatesDialog`, `RentalGroupDialog` (Task 5); `Api.deleteRentalGroup`, `Api.deleteRental`.
- Produces: `enum RentalKind { weekly, irregular }`; `RentalDialog({Rental? existing, RentalKind? kind, required int laneCount})` — `kind` povinný, když `existing == null`.

- [ ] **Step 1: Testy (padají)**

V `test/features/rentals_screen_test.dart`:

(a) Přidej import `import 'package:rezervator/domain/labels.dart' show rentalMoreDatesLabel;` a helper (za `exception(...)`):

```dart
  // A renter with three scattered dates in one group, and a lone one-off.
  Rental grouped({required String id, required Day date, List<int> lanes = const [1]}) =>
      Rental(
        id: id,
        renterName: 'Firma Trak',
        lanes: lanes,
        date: date,
        weekday: null,
        startsAt: const HourMinute(18, 0),
        endsAt: const HourMinute(20, 0),
        validFrom: null,
        validUntil: null,
        note: '',
        color: 3,
        groupId: 'g1',
      );
  final d1 = today().addDays(3);
  final d2 = today().addDays(9);
  final d3 = today().addDays(30);
  final lone = Rental(
    id: 'r-lone',
    renterName: 'Oslava Novákovi',
    lanes: const [1, 2],
    date: today().addDays(5),
    weekday: null,
    startsAt: const HourMinute(19, 0),
    endsAt: const HourMinute(22, 0),
    validFrom: null,
    validUntil: null,
    note: 'dort',
  );
```

(b) První test přepiš (nahraď celý `testWidgets('lists one-time rentals before weekly ones…'`):

```dart
  testWidgets('series under Pravidelné, groups under Nepravidelné by next '
      'date, each tile with its dates and lanes', (tester) async {
    await tester.pumpWidget(app(rentals: [
      weekly,
      grouped(id: 'g1-c', date: d3, lanes: const [3]),
      grouped(id: 'g1-a', date: d1),
      grouped(id: 'g1-b', date: d2, lanes: const [1, 2]),
      lone,
    ]));
    await tester.pumpAndSettle();

    expect(find.text('Pravidelné'), findsOneWidget);
    expect(find.text('Nepravidelné'), findsOneWidget);
    expect(find.text('Firma Kolo'), findsOneWidget);
    expect(find.textContaining('každý čtvrtek 18:00–20:00'), findsOneWidget);
    // The group tile: first two dates, the rest counted.
    expect(find.textContaining('${dayLabel(d1)} · 18:00–20:00 · dráhy 1'),
        findsOneWidget);
    expect(find.textContaining('${dayLabel(d2)} · 18:00–20:00 · dráhy 1, 2'),
        findsOneWidget);
    expect(find.textContaining(dayLabel(d3)), findsNothing);
    expect(find.textContaining(rentalMoreDatesLabel(1)), findsOneWidget);
    // The lone one-off is a group of one, with its note.
    expect(find.textContaining('${dayLabel(lone.date!)} · 19:00–22:00 · dráhy 1, 2 · dort'),
        findsOneWidget);
    // Order: header Pravidelné, series, header Nepravidelné, Trak (d1) before Oslava (d1+2).
    double y(String text) => tester.getTopLeft(find.text(text)).dy;
    expect(y('Pravidelné'), lessThan(y('Firma Kolo')));
    expect(y('Firma Kolo'), lessThan(y('Nepravidelné')));
    expect(y('Nepravidelné'), lessThan(y('Firma Trak')));
    expect(y('Firma Trak'), lessThan(y('Oslava Novákovi')));
  });
```
(Import `dayLabel` z `core/ui.dart` vedle `dayFull, today`.)

(c) Test `Přidat pronájem opens the rental dialog…` nahraď:

```dart
  testWidgets('Přidat pronájem asks which kind; Nepravidelný opens the '
      "dialog with the alley's lanes and no mode switch", (tester) async {
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    await tester.tap(find.text('Přidat pronájem'));
    await tester.pumpAndSettle();
    expect(find.text('Pravidelný'), findsOneWidget);
    expect(find.text('Nepravidelný'), findsOneWidget);
    await tester.tap(find.text('Nepravidelný'));
    await tester.pumpAndSettle();
    expect(find.text('Přidat nepravidelný pronájem'), findsOneWidget);
    expect(find.text('Nájemce'), findsOneWidget);
    expect(find.text('Datum'), findsOneWidget);
    expect(find.text('Jednorázový'), findsNothing);
    expect(find.text('Týdenní'), findsNothing);
    expect(find.text('Den v týdnu'), findsNothing);
    expect(find.text('Dráha 1'), findsOneWidget);
    expect(find.text('Dráha 2'), findsOneWidget);
    expect(find.text('Dráha 3'), findsNothing);
    expect(find.text('Uložit'), findsOneWidget);
  });

  testWidgets('Pravidelný opens the weekly form', (tester) async {
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    await tester.tap(find.text('Přidat pronájem'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Pravidelný'));
    await tester.pumpAndSettle();
    expect(find.text('Přidat pravidelný pronájem'), findsOneWidget);
    expect(find.text('Den v týdnu'), findsOneWidget);
    expect(find.text('Datum'), findsNothing);
  });
```

(d) Přidej na konec `main`:

```dart
  testWidgets('a group tile offers Termíny, Upravit and Smazat naming the '
      'date count', (tester) async {
    await tester.pumpWidget(app(rentals: [
      grouped(id: 'g1-a', date: d1),
      grouped(id: 'g1-b', date: d2),
    ]));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Termíny'));
    await tester.pumpAndSettle();
    expect(find.text('Termíny · Firma Trak'), findsOneWidget);
    await tester.tap(find.text('Zavřít'));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Smazat'));
    await tester.pumpAndSettle();
    expect(find.text('Smazat pronájem?'), findsOneWidget);
    expect(find.textContaining('včetně 2 termíny'), findsOneWidget);
  });

  testWidgets('a lone one-off is deleted like before, no count', (tester) async {
    await tester.pumpWidget(app(rentals: [lone]));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Smazat'));
    await tester.pumpAndSettle();
    expect(find.text('Opravdu smazat pronájem pro Oslava Novákovi?'),
        findsOneWidget);
  });
```

(e) V testu `a weekly rental counts its exceptions…` nahraď `expect(find.textContaining('jednorázově'), findsNothing);` za `expect(find.text('Nepravidelné'), findsNothing);`.

Run: `flutter test test/features/rentals_screen_test.dart` → Expected: kompilační chyby / padající testy (`groupId` už existuje, ale `Pravidelné`, rozcestník atd. ne).

- [ ] **Step 2: `RentalDialog` bez přepínače**

V `lib/features/admin/widgets/rental_dialog.dart`:

```dart
/// Which kind of rental the add dialog creates — the chooser on Pronájmy
/// decides; the dialog itself no longer asks.
enum RentalKind { weekly, irregular }
```
(nahraď `enum _RentalMode { oneTime, weekly }` tímto a všechny výskyty `_RentalMode.oneTime` → `RentalKind.irregular`, `_RentalMode.weekly` → `RentalKind.weekly`, typ pole `_mode` → `RentalKind`.)

Konstruktor:
```dart
  const RentalDialog({
    super.key,
    this.existing,
    this.kind,
    required this.laneCount,
  }) : assert(existing != null || kind != null,
            'a new rental needs its kind');

  final Rental? existing;
  /// For a new rental: weekly (den v týdnu, platí od/do) or irregular (the
  /// first date; more come through RentalDatesDialog).
  final RentalKind? kind;
```

`initState`: `if (existing == null) { _mode = widget.kind!; } else if (existing.date != null) { _mode = RentalKind.irregular; _date = existing.date; } else { … }`.

`build`: smaž celý blok `RadioGroup<_RentalMode>(…)` i `const SizedBox(height: 8)` před ním; titul:
```dart
      title: widget.existing != null
          ? 'Upravit pronájem'
          : widget.kind == RentalKind.weekly
              ? 'Přidat pravidelný pronájem'
              : 'Přidat nepravidelný pronájem',
```
Doc-komentář třídy uprav: „The kind comes from the chooser on Pronájmy (or from [existing]); only the fields of that kind are ever read when saving, so the other is always sent as null."

- [ ] **Step 3: Obrazovka**

`lib/features/admin/rentals_screen.dart` — nahraď `_compareRentals` za:

```dart
/// Weekly series by weekday (Monday..Sunday), then start time, then renter.
int _compareSeries(Rental a, Rental b) {
  final byWeekday = a.weekday!.compareTo(b.weekday!);
  if (byWeekday != 0) return byWeekday;
  final byStart = a.startsAt.compareTo(b.startsAt);
  return byStart != 0 ? byStart : compareCzech(a.renterName, b.renterName);
}
```

Importy: přidej `'../../domain/rental_groups.dart'`, `'widgets/rental_dates_dialog.dart'`, `'widgets/rental_group_dialog.dart'`, a v `labels.dart` show rozšiř o `rentalDateCountLabel, rentalMoreDatesLabel`.

`_delete` (série) ponech; přidej:

```dart
  Future<void> _deleteGroup(BuildContext context, RentalGroup group) {
    final n = group.dates.length;
    final id = group.id;
    return confirmDelete(
      context,
      title: 'Smazat pronájem?',
      message: n == 1
          ? 'Opravdu smazat pronájem pro ${group.renterName}?'
          : 'Opravdu smazat pronájem pro ${group.renterName} včetně '
              '${rentalDateCountLabel(n)}?',
      action: () => id != null
          ? Api.deleteRentalGroup(id)
          : Api.deleteRental(group.dates.single.id),
    );
  }
```

`_subtitle` zjednoduš na sérii (větev `if (date != null) …` smaž — jednorázové sem už nechodí) a přejmenuj `_tile` → `_seriesTile` (obsah beze změny, tooltip mazacího tlačítka doplň `tooltip: 'Smazat'`). Přidej:

```dart
  String _groupSubtitle(RentalGroup group) {
    String line(Rental d) {
      final parts = [
        dayLabel(d.date!),
        '${d.startsAt.display()}–${d.endsAt.display()}',
        'dráhy ${d.lanes.join(', ')}',
        if (d.note.isNotEmpty) d.note,
      ];
      return parts.join(' · ');
    }
    final shown = group.dates.take(2).map(line).toList();
    final rest = group.dates.length - shown.length;
    if (rest > 0) shown.add(rentalMoreDatesLabel(rest));
    return shown.join('\n');
  }

  Widget _groupTile(BuildContext context, RentalGroup group,
      {required int laneCount}) {
    return ListTile(
      title: Text(group.renterName),
      subtitle: Text(_groupSubtitle(group)),
      isThreeLine: group.dates.length > 1,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            icon: const Icon(Icons.event_note_outlined),
            tooltip: 'Termíny',
            onPressed: () => showDialog<void>(
              context: context,
              builder: (_) =>
                  RentalDatesDialog(group: group, laneCount: laneCount),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.edit_outlined),
            tooltip: 'Upravit',
            onPressed: () => showDialog<bool>(
              context: context,
              builder: (_) => RentalGroupDialog(group: group),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.delete_outline),
            tooltip: 'Smazat',
            onPressed: () => _deleteGroup(context, group),
          ),
        ],
      ),
    );
  }

  Widget _header(BuildContext context, String text) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
        child: Text(text, style: Theme.of(context).textTheme.titleSmall),
      );

  /// Which kind to add — a series is a rule, a group is a list; the two
  /// forms share almost nothing, so the choice comes first.
  Future<void> _add(BuildContext context, int laneCount) async {
    final kind = await showModalBottomSheet<RentalKind>(
      context: context,
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.repeat),
              title: const Text('Pravidelný'),
              subtitle: const Text('Každý týden ve stejný den a čas.'),
              onTap: () => Navigator.of(context).pop(RentalKind.weekly),
            ),
            ListTile(
              leading: const Icon(Icons.event_note_outlined),
              title: const Text('Nepravidelný'),
              subtitle: const Text(
                  'Jeden nájemce, libovolné termíny — každý s vlastním časem a drahami.'),
              onTap: () => Navigator.of(context).pop(RentalKind.irregular),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (kind == null || !context.mounted) return;
    await showDialog<void>(
      context: context,
      builder: (_) => RentalDialog(kind: kind, laneCount: laneCount),
    );
  }
```

Pozor: uvnitř `builder: (_) => …` používej `Navigator.of(context)` **vnějšího** contextu jen přes pojmenovaný parametr builderu — přepiš `builder: (_)` na `builder: (sheetContext)` a volej `Navigator.of(sheetContext).pop(...)`.

`build`:

```dart
        builder: (rentals) {
          final series = <Rental>[];
          final exceptions = <String, int>{};
          for (final rental in rentals) {
            final parentId = rental.parentId;
            if (parentId != null) {
              exceptions[parentId] = (exceptions[parentId] ?? 0) + 1;
            } else if (rental.weekday != null) {
              series.add(rental);
            }
          }
          series.sort(_compareSeries);
          final groups = rentalGroupsOf(rentals, today: today());
          if (series.isEmpty && groups.isEmpty) {
            return const Center(child: Text('Zatím žádné pronájmy.'));
          }
          return ListView(
            children: [
              if (series.isNotEmpty) _header(context, 'Pravidelné'),
              for (final rental in series)
                _seriesTile(
                  context,
                  rental,
                  exceptions: exceptions[rental.id] ?? 0,
                  laneCount: laneCount,
                ),
              if (groups.isNotEmpty) _header(context, 'Nepravidelné'),
              for (final group in groups)
                _groupTile(context, group, laneCount: laneCount),
            ],
          );
        },
```
a FAB: `onPressed: () => _add(context, laneCount),` (label `Přidat pronájem` zůstává).

- [ ] **Step 4: Changelog**

`lib/features/profile/changelog_data.dart`: je-li první položka `appChangelog` `Release(null, …)`, připoj řádek do jejího seznamu; jinak vlož nad `Release('1.2.6', …)`:

```dart
  Release(null, 'D. M. RRRR', [   // datum commitu, např. '16. 9. 2026'
    'Nepravidelný pronájem: jeden nájemce, víc termínů — každý s vlastním '
        'časem a drahami. Pronájmy jsou nově rozdělené na pravidelné a '
        'nepravidelné.',
  ]),
```

- [ ] **Step 5: Vše zelené + falzifikace**

Run: `flutter analyze && flutter test` → `No issues found!`, `All tests passed!` (očekávaný počet ≈ 771 + nové).
Falzifikace: v `_groupSubtitle` dočasně `take(3)` → padá `series under Pravidelné…` na `findsNothing` pro `dayLabel(d3)`. Vrať.

- [ ] **Step 6: Commit**

```bash
cd ~/Home/rezervator && git add lib/features/admin/rentals_screen.dart lib/features/admin/widgets/rental_dialog.dart lib/features/profile/changelog_data.dart test/features/rentals_screen_test.dart && git commit -q -F - <<'EOF'
feat(admin): Pronájmy — Pravidelné a Nepravidelné, skupiny termínů, rozcestník

Série je pravidlo, skupina je seznam: dvě sekce, dva dialogy, volba typu
před formulářem. Dlaždice skupiny ukáže první dva termíny a zbytek spočítá;
Smazat pojmenuje, kolik termínů tím zmizí.

Falzifikováno: s třemi zobrazenými termíny padá test dlaždice.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
EOF
```

---

## Po dokončení

`flutter analyze && flutter test`, lokálně `supabase db reset` + psql testy zelené, `git diff origin/main --stat` odpovídá tabulce Soubory. Pak `superpowers:finishing-a-development-branch` — PR až na pokyn. Po mergi nasadí `deploy-backend.yml` migraci; appka na web hned, do Play v dalším vydání.

## Co plán schválně nedělá (spec § Známé meze)

Skupina nedrží týdenní série; žádné opakování vzorcem; žádný přesun termínu mezi skupinami.
