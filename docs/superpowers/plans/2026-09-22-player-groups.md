# Skupiny hráčů — implementační plán

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Hráči si sami založí skupinu (pozvánka + souhlas) a každý člen pak smí rezervovat a rušit tréninky za kteréhokoli jiného člena, se stejnými pravidly jako za sebe.

**Architecture:** Migrace 0044 přidá `player_groups` (jen server) a `player_group_members` (klient čte přes RLS, zapisuje jen přes RPC), rozšíří `create_reservation`/`cancel_reservation` o větev „stejná skupina" (`created_via`/`cancelled_via = 'group'`, nový `reservations.cancelled_by`). Edge funkce `notify` posílá čtyři nové zprávy (texty v čistém modulu s deno testy). Appka: doménový model skupiny, provider nad řádky členství, karta „Moje skupina" v Můj profil, volba „Pro koho" a rušení za člena v rozvrhu, odebrání ze skupiny v Správa → Hráči.

**Tech Stack:** Supabase Postgres (plpgsql, RLS, realtime), Deno edge funkce, Flutter + Riverpod 3, flutter_test.

**Spec:** `docs/superpowers/specs/2026-09-22-player-groups-design.md`

## Global Constraints

- Jedna skupina na hráče: částečný unikátní index `player_group_one_membership on player_group_members (user_id) where status = 'member'`.
- `player_groups` klient nevidí vůbec (RLS bez policy + `revoke all … from anon, authenticated`). `player_group_members`: klient jen `select` (RLS), žádné DML; `anon` nic.
- Každé nové RPC: `security definer set search_path = public`, `revoke all on function … from public, anon;` + `grant execute … to authenticated;`. Interní (`same_group`, `_group_drop_member`) navíc `revoke … from authenticated`. `my_group_id()` smí `authenticated` (používá ho RLS policy).
- Pravidla rezervace za člena = pravidla za sebe: minulost, horizont, limit **cílového hráče**; rušení jen před začátkem (`too_late`). Správcovy výjimky se na skupinu nevztahují.
- Kódy chyb a texty (`friendlyDbError`):
  - `member_at_limit` → `Člen skupiny už má maximální počet rezervací.` (záměrně NE `member_limit_reached` — `friendlyDbError` hledá podřetězec a `limit_reached` by vyhrál s „Máš…")
  - `already_member` → `Už je ve tvé skupině.`
  - `already_invited` → `Pozvánku už má — čeká se, až ji přijme.`
  - `unknown_invite` → `Tahle pozvánka už neplatí.`
  - `already_in_group` → `Už jsi v jiné skupině — nejdřív z ní odejdi.`
- Pozvat nelze: sebe, hráče bez účtu (`placeholder`), kiosk, neschváleného, hráče jiné kuželny → vše `unknown_player`.
- Notifikační texty (přesně):
  - pozvánka: titulek `Pozvánka do skupiny`, text `{jméno} tě zve do skupiny — přijmi ji v Můj profil.`
  - přijetí: titulek `Nový člen skupiny`, text `{jméno} je teď ve skupině.`
  - rezervace za člena: titulek `Trénink zarezervován`, text `{jméno} ti zarezervoval(a) trénink: {when}.`
  - zrušení za člena: titulek `Trénink zrušen`, text `{jméno} ti zrušil(a) trénink: {when}.`
  - `{when}` = existující `ctx.when` z `reservationContext` (`čt 24.9. 17:30–18:30, dráha 2`).
- UI texty: karta `Moje skupina`; vysvětlení `Rezervujte a rušte tréninky za sebe navzájem — třeba rodina nebo dvojice.`; tlačítka `Pozvat do skupiny…`, `Opustit skupinu`, `Přijmout`, `Odmítnout`; pozvánka `{jméno} tě zve do skupiny`; dialog rezervace `Pro koho`, volba `Já`; potvrzení zrušení za člena `Zrušit rezervaci?` + zpráva `{jméno}\n{den} · {blok} · Dráha {n}\nDostane o tom zprávu.`; Správa → Hráči menu `Odebrat ze skupiny`, podtitul `skupina: {jména}`.
- Changelog: `Skupiny: rodina nebo dvojice si může rezervovat a rušit tréninky navzájem — založíš ji v Můj profil.`
- Commit po každém tasku, česky ve stylu repa, zakončený `Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>`. Nepushovat. Každý nový test falzifikovat.

---

### Task 1: Migrace 0044 + SQL testy + snapshot + SCHEMA.md

**Files:**
- Create: `supabase/migrations/0044_player_groups.sql`
- Modify: `supabase/tests/tenancy_rls.sql` (nové bloky před závěrečné `reset role;` / `rollback;`; `'player_group_members'` do pole `v_streamed`)
- Modify: `supabase/schema.sql` (regenerace `tool/schema_snapshot.sh`), `docs/SCHEMA.md`

**Interfaces — Produces:** tabulka `player_group_members(group_id, user_id, tenant_id, status 'invited'|'member', invited_by, created_at)`; RPC `group_invite(p_user uuid)`, `group_accept(p_group uuid)`, `group_decline(p_group uuid)`, `group_leave()`, `group_cancel_invite(p_group uuid, p_user uuid)`, `group_remove_member(p_user uuid)` (všechny `returns void`); `reservations.cancelled_by uuid`; `created_via`/`cancelled_via` hodnota `'group'`; chyba `member_at_limit`.

- [ ] **Step 1: SQL testy (padají — nic z toho neexistuje)**

Do `supabase/tests/tenancy_rls.sql` do pole `v_streamed` přidat `'player_group_members'` a před závěrečné `reset role;` + `rollback;` vložit:

```sql
-- 0044 skupiny hráčů -------------------------------------------------------
reset role;
-- Fixtures: four approved players in tenant A (no auth.users stub needed
-- since 0022), a placeholder, one player in tenant B, a block of their own
-- at 07:00 and a week open every day with a cap of 2.
do $$
declare
  v_a constant uuid := '00000000-0000-0000-0000-00000000000a';
  v_today constant date := (now() at time zone 'Europe/Prague')::date;
  v_block uuid;
begin
  insert into profiles (id, tenant_id, display_name, email, role, status)
  values
    ('20000000-0000-0000-0000-000000000001', v_a, 'Petr', 'p1@example.com', 'player', 'approved'),
    ('20000000-0000-0000-0000-000000000002', v_a, 'Jana', 'p2@example.com', 'player', 'approved'),
    ('20000000-0000-0000-0000-000000000003', v_a, 'Karel', 'p3@example.com', 'player', 'approved'),
    ('20000000-0000-0000-0000-000000000004', v_a, 'Lenka', 'p4@example.com', 'player', 'approved'),
    ('20000000-0000-0000-0000-0000000000b1', '00000000-0000-0000-0000-000000000002',
     'Cizí', 'q@example.com', 'player', 'approved');
  insert into profiles (id, tenant_id, display_name, role, status, placeholder)
  values ('20000000-0000-0000-0000-000000000005', v_a, 'Bez účtu', 'player', 'approved', true);
  update schedule_settings
     set training_weekdays = '{1,2,3,4,5,6,7}', max_active_reservations = 2
   where tenant_id = v_a;
  -- An earlier block closes this week's Sunday; the next three days must
  -- simply be open here.
  delete from day_overrides
   where tenant_id = v_a and date between v_today + 1 and v_today + 3;
  insert into time_blocks (tenant_id, starts_at, ends_at, position)
    values (v_a, '07:00', '07:30', 97) returning id into v_block;
  perform set_config('probe.grp_block', v_block::text, true);
end $$;

do $$
begin
  if has_table_privilege('authenticated', 'public.player_groups', 'select')
     or has_table_privilege('anon', 'public.player_groups', 'select') then
    raise exception 'FAIL: player_groups is readable by the client';
  end if;
  if not has_table_privilege('authenticated', 'public.player_group_members', 'select')
     or has_table_privilege('authenticated', 'public.player_group_members', 'insert')
     or has_table_privilege('authenticated', 'public.player_group_members', 'update')
     or has_table_privilege('authenticated', 'public.player_group_members', 'delete')
     or has_table_privilege('anon', 'public.player_group_members', 'select') then
    raise exception 'FAIL: player_group_members must be select-only for the app, nothing for anon';
  end if;
  if has_function_privilege('authenticated', 'same_group(uuid, uuid)', 'execute')
     or has_function_privilege('authenticated', '_group_drop_member(uuid, uuid)', 'execute')
     or has_function_privilege('anon', 'group_invite(uuid)', 'execute')
     or has_function_privilege('anon', 'my_group_id()', 'execute') then
    raise exception 'FAIL: an internal group function is callable from the app, or one is open to anon';
  end if;
  if not (has_function_privilege('authenticated', 'group_invite(uuid)', 'execute')
      and has_function_privilege('authenticated', 'group_accept(uuid)', 'execute')
      and has_function_privilege('authenticated', 'group_decline(uuid)', 'execute')
      and has_function_privilege('authenticated', 'group_leave()', 'execute')
      and has_function_privilege('authenticated', 'group_cancel_invite(uuid, uuid)', 'execute')
      and has_function_privilege('authenticated', 'group_remove_member(uuid)', 'execute')
      and has_function_privilege('authenticated', 'my_group_id()', 'execute')) then
    raise exception 'FAIL: the app cannot call the group RPCs';
  end if;
  if not exists (select 1 from pg_trigger
                 where tgname = 'notify_player_group_members' and not tgisinternal) then
    raise exception 'FAIL: no webhook on player_group_members';
  end if;
  raise notice 'OK: groups are RPC-written, select-only through RLS, anon nothing (0044)';
end $$;

-- Petr invites Jana: the group is born with Petr in it.
set local role authenticated;
set local request.jwt.claims =
  '{"sub":"20000000-0000-0000-0000-000000000001","role":"authenticated"}';
do $$
begin
  perform group_invite('20000000-0000-0000-0000-000000000002');
  begin
    perform group_invite('20000000-0000-0000-0000-000000000002');
    raise exception 'FAIL: a second invite went through';
  exception when others then
    if sqlerrm <> 'already_invited' then raise; end if;
  end;
  begin
    perform group_invite('20000000-0000-0000-0000-000000000005');
    raise exception 'FAIL: a player without an account was invited';
  exception when others then
    if sqlerrm <> 'unknown_player' then raise; end if;
  end;
  begin
    perform group_invite('10000000-0000-0000-0000-000000000006');
    raise exception 'FAIL: the kiosk was invited';
  exception when others then
    if sqlerrm <> 'unknown_player' then raise; end if;
  end;
  begin
    perform group_invite('20000000-0000-0000-0000-0000000000b1');
    raise exception 'FAIL: a player of another alley was invited';
  exception when others then
    if sqlerrm <> 'unknown_player' then raise; end if;
  end;
  begin
    perform group_invite('20000000-0000-0000-0000-000000000001');
    raise exception 'FAIL: Petr invited himself';
  exception when others then
    if sqlerrm <> 'unknown_player' then raise; end if;
  end;
  if (select count(*) from player_group_members) <> 2 then
    raise exception 'FAIL: Petr should see his own row and Jana''s invite';
  end if;
  raise notice 'OK: an invite founds the group; nobody outside the alley''s approved account holders can be invited (0044)';
end $$;

-- Jana before accepting: sees her invite, may not book for Petr. Karel
-- (not involved) sees nothing.
reset role;
set local role authenticated;
set local request.jwt.claims =
  '{"sub":"20000000-0000-0000-0000-000000000002","role":"authenticated"}';
do $$
begin
  if (select count(*) from player_group_members
      where user_id = '20000000-0000-0000-0000-000000000002' and status = 'invited') <> 1 then
    raise exception 'FAIL: Jana does not see her invite';
  end if;
  begin
    perform create_reservation('20000000-0000-0000-0000-000000000001',
      (now() at time zone 'Europe/Prague')::date + 1,
      current_setting('probe.grp_block')::uuid, 1::smallint);
    raise exception 'FAIL: an invitee booked for the group before accepting';
  exception when others then
    if sqlerrm <> 'not_allowed' then raise; end if;
  end;
end $$;
reset role;
set local role authenticated;
set local request.jwt.claims =
  '{"sub":"20000000-0000-0000-0000-000000000003","role":"authenticated"}';
do $$
begin
  if exists (select 1 from player_group_members) then
    raise exception 'FAIL: Karel sees a group he has nothing to do with';
  end if;
  raise notice 'OK: an invite gives no power until accepted, and outsiders see nothing (0044)';
end $$;

-- Jana accepts.
reset role;
set local role authenticated;
set local request.jwt.claims =
  '{"sub":"20000000-0000-0000-0000-000000000002","role":"authenticated"}';
select group_accept((select group_id from player_group_members
                     where user_id = '20000000-0000-0000-0000-000000000002'));

-- Karel founds his own group (invites Lenka), Petr invites Karel too:
-- Karel cannot accept a second group.
reset role;
set local role authenticated;
set local request.jwt.claims =
  '{"sub":"20000000-0000-0000-0000-000000000003","role":"authenticated"}';
select group_invite('20000000-0000-0000-0000-000000000004');
reset role;
set local role authenticated;
set local request.jwt.claims =
  '{"sub":"20000000-0000-0000-0000-000000000001","role":"authenticated"}';
select group_invite('20000000-0000-0000-0000-000000000003');
reset role;
set local role authenticated;
set local request.jwt.claims =
  '{"sub":"20000000-0000-0000-0000-000000000003","role":"authenticated"}';
do $$
declare
  v_petr_group uuid;
begin
  select group_id into v_petr_group from player_group_members
   where user_id = '20000000-0000-0000-0000-000000000003' and status = 'invited';
  begin
    perform group_accept(v_petr_group);
    raise exception 'FAIL: Karel joined a second group';
  exception when others then
    if sqlerrm <> 'already_in_group' then raise; end if;
  end;
  perform group_decline(v_petr_group);
  begin
    perform group_decline(v_petr_group);
    raise exception 'FAIL: a declined invite declined twice';
  exception when others then
    if sqlerrm <> 'unknown_invite' then raise; end if;
  end;
  raise notice 'OK: one group per player; an invite can be declined once (0044)';
end $$;

reset role;
do $$
begin
  if not same_group('20000000-0000-0000-0000-000000000001',
                    '20000000-0000-0000-0000-000000000002')
     or same_group('20000000-0000-0000-0000-000000000001',
                   '20000000-0000-0000-0000-000000000003') then
    raise exception 'FAIL: same_group is wrong';
  end if;
end $$;

-- Petr books for Jana: the group branch, Jana's cap, not Petr's.
set local role authenticated;
set local request.jwt.claims =
  '{"sub":"20000000-0000-0000-0000-000000000001","role":"authenticated"}';
do $$
declare
  v_today constant date := (now() at time zone 'Europe/Prague')::date;
  v_block constant uuid := current_setting('probe.grp_block')::uuid;
  v_res reservations;
begin
  select * into v_res from create_reservation(
    '20000000-0000-0000-0000-000000000002', v_today + 1, v_block, 1::smallint);
  if v_res.created_via <> 'group'
     or v_res.created_by <> '20000000-0000-0000-0000-000000000001' then
    raise exception 'FAIL: a group booking is not marked as one: %', v_res;
  end if;
  perform set_config('probe.grp_res', v_res.id::text, true);
  perform create_reservation(
    '20000000-0000-0000-0000-000000000002', v_today + 2, v_block, 1::smallint);
  begin
    perform create_reservation(
      '20000000-0000-0000-0000-000000000002', v_today + 3, v_block, 1::smallint);
    raise exception 'FAIL: Jana''s cap did not hold for a group booking';
  exception when others then
    if sqlerrm <> 'member_at_limit' then raise; end if;
  end;
  -- Petr's own cap is untouched by Jana's two.
  perform create_reservation(
    '20000000-0000-0000-0000-000000000001', v_today + 3, v_block, 2::smallint);
  raise notice 'OK: a member books for a member under the member''s own cap (0044)';
end $$;

-- Cancelling: Petr cancels Jana's future one; a started one is too late;
-- Karel (another group) may not.
reset role;
insert into reservations (tenant_id, player_id, date, block_id, lane,
                          created_via, created_by)
values ('00000000-0000-0000-0000-00000000000a',
        '20000000-0000-0000-0000-000000000002',
        (now() at time zone 'Europe/Prague')::date - 1,
        current_setting('probe.grp_block')::uuid, 3, 'app',
        '20000000-0000-0000-0000-000000000002')
returning set_config('probe.grp_past', id::text, true);
set local role authenticated;
set local request.jwt.claims =
  '{"sub":"20000000-0000-0000-0000-000000000001","role":"authenticated"}';
do $$
begin
  perform cancel_reservation(current_setting('probe.grp_res')::uuid);
  begin
    perform cancel_reservation(current_setting('probe.grp_past')::uuid);
    raise exception 'FAIL: a started training was cancelled by a member';
  exception when others then
    if sqlerrm <> 'too_late' then raise; end if;
  end;
end $$;
reset role;
do $$
declare
  v_res reservations;
begin
  select * into v_res from reservations
   where id = current_setting('probe.grp_res')::uuid;
  if v_res.cancelled_via <> 'group'
     or v_res.cancelled_by <> '20000000-0000-0000-0000-000000000001' then
    raise exception 'FAIL: a group cancel is not marked as one: %', v_res;
  end if;
end $$;
set local role authenticated;
set local request.jwt.claims =
  '{"sub":"20000000-0000-0000-0000-000000000003","role":"authenticated"}';
do $$
begin
  begin
    perform cancel_reservation((select id from reservations
      where player_id = '20000000-0000-0000-0000-000000000002'
        and cancelled_at is null
        and date = (now() at time zone 'Europe/Prague')::date + 2));
    raise exception 'FAIL: an outsider cancelled a member''s training';
  exception when others then
    if sqlerrm <> 'not_allowed' then raise; end if;
  end;
  raise notice 'OK: a member cancels a member''s training until it starts, an outsider never (0044)';
end $$;

-- Leaving: Jana leaves (group stays with Petr); Petr withdraws an invite,
-- then leaves — the group is gone.
reset role;
set local role authenticated;
set local request.jwt.claims =
  '{"sub":"20000000-0000-0000-0000-000000000002","role":"authenticated"}';
select group_leave();
reset role;
set local role authenticated;
set local request.jwt.claims =
  '{"sub":"20000000-0000-0000-0000-000000000001","role":"authenticated"}';
do $$
declare
  v_group uuid := my_group_id();
begin
  if v_group is null then
    raise exception 'FAIL: the group went with Jana although Petr is still in it';
  end if;
  perform set_config('probe.grp_petr', v_group::text, true);
  perform group_invite('20000000-0000-0000-0000-000000000004');
  perform group_cancel_invite(v_group, '20000000-0000-0000-0000-000000000004');
  if exists (select 1 from player_group_members
             where group_id = v_group and user_id = '20000000-0000-0000-0000-000000000004') then
    raise exception 'FAIL: a withdrawn invite is still there';
  end if;
  perform group_invite('20000000-0000-0000-0000-000000000004');
  perform group_leave();
end $$;
reset role;
do $$
begin
  if exists (select 1 from player_groups
             where id = current_setting('probe.grp_petr')::uuid)
     or exists (select 1 from player_group_members
                where group_id = current_setting('probe.grp_petr')::uuid) then
    raise exception 'FAIL: the last member left and the group (or its invite) stayed';
  end if;
  raise notice 'OK: leaving keeps the group while anyone is in it, the last one takes it away (0044)';
end $$;

-- The admin: sees Karel's group, removes Karel; the other alley's admin
-- sees nothing and may not.
set local role authenticated;
set local request.jwt.claims =
  '{"sub":"20000000-0000-0000-0000-000000000004","role":"authenticated"}';
select group_accept((select group_id from player_group_members
                     where user_id = '20000000-0000-0000-0000-000000000004'
                       and status = 'invited'));
reset role;
set local role authenticated;
set local request.jwt.claims =
  '{"sub":"10000000-0000-0000-0000-000000000002","role":"authenticated"}';
do $$
begin
  if exists (select 1 from player_group_members) then
    raise exception 'FAIL: another alley''s admin sees our groups';
  end if;
  begin
    perform group_remove_member('20000000-0000-0000-0000-000000000003');
    raise exception 'FAIL: another alley''s admin removed our player';
  exception when others then
    if sqlerrm <> 'not_allowed' then raise; end if;
  end;
end $$;
reset role;
set local role authenticated;
set local request.jwt.claims =
  '{"sub":"10000000-0000-0000-0000-000000000001","role":"authenticated"}';
do $$
begin
  if (select count(*) from player_group_members
      where user_id in ('20000000-0000-0000-0000-000000000003',
                        '20000000-0000-0000-0000-000000000004')) <> 2 then
    raise exception 'FAIL: the admin does not see the alley''s group';
  end if;
  perform group_remove_member('20000000-0000-0000-0000-000000000003');
  if exists (select 1 from player_group_members
             where user_id = '20000000-0000-0000-0000-000000000003') then
    raise exception 'FAIL: the admin could not remove Karel';
  end if;
  raise notice 'OK: the admin sees and prunes the alley''s groups, a foreign admin neither (0044)';
end $$;
```

- [ ] **Step 2: Ověřit pád**

```bash
supabase start >/dev/null && supabase db reset
psql postgresql://postgres:postgres@127.0.0.1:54322/postgres -v ON_ERROR_STOP=1 -f supabase/tests/tenancy_rls.sql 2>&1 | tail -5
```
Expected: chyba (relation `player_groups` does not exist / `player_group_members` chybí v `supabase_realtime`).

- [ ] **Step 3: Migrace** `supabase/migrations/0044_player_groups.sql`:

```sql
-- 0044: skupiny hráčů. Rodina nebo dvojice si rezervuje a ruší tréninky
-- navzájem. Skupinu zakládají hráči sami: pozvánka + souhlas (skupina dává
-- ostatním právo rušit MOJE rezervace, takže souhlasí ten, o koho jde).
-- Jedna skupina na hráče. Správce jen vidí a může někoho odebrat.
-- Rezervace za člena má stejná pravidla jako za sebe; limit se počítá
-- tomu, PRO KOHO je.

create table player_groups (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references tenants(id) on delete cascade,
  created_by uuid references profiles(id) on delete set null,
  created_at timestamptz not null default now()
);
comment on table player_groups is
  'A group of players who may book and cancel trainings for each other (0044). Server-only: the app reads player_group_members.';
alter table player_groups enable row level security;
revoke all on player_groups from anon, authenticated;

create table player_group_members (
  group_id uuid not null references player_groups(id) on delete cascade,
  user_id uuid not null references profiles(id) on delete cascade,
  tenant_id uuid not null references tenants(id) on delete cascade,
  status text not null check (status in ('invited', 'member')),
  invited_by uuid references profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  primary key (group_id, user_id)
);
comment on table player_group_members is
  'Membership and pending invites of player_groups (0044). tenant_id is denormalised so the admin policy never has to read player_groups (no policy cycle). Written only through the group_* RPCs.';
create unique index player_group_one_membership
  on player_group_members (user_id) where status = 'member';

-- The caller's own group (null outside one). Security definer: the policy
-- below reads the very table it guards.
create or replace function my_group_id() returns uuid
language sql stable security definer set search_path = public as $$
  select group_id from player_group_members
   where user_id = auth.uid() and status = 'member'
$$;
revoke all on function my_group_id() from public, anon;
grant execute on function my_group_id() to authenticated;

alter table player_group_members enable row level security;
create policy player_group_members_select on player_group_members
  for select using (
    user_id = auth.uid()
    or group_id = my_group_id()
    or (is_admin() and tenant_id = current_tenant_id())
  );
revoke insert, update, delete on player_group_members from authenticated;
revoke all on player_group_members from anon;

alter publication supabase_realtime add table player_group_members;

create trigger notify_player_group_members
  after insert or update on player_group_members
  for each row execute function notify_webhook();

create or replace function same_group(a uuid, b uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1
      from player_group_members x
      join player_group_members y on y.group_id = x.group_id
     where x.user_id = a and x.status = 'member'
       and y.user_id = b and y.status = 'member')
$$;
revoke all on function same_group(uuid, uuid) from public, anon, authenticated;

-- Removes one member; the group dies with its last member (its pending
-- invites cascade with it).
create or replace function _group_drop_member(p_group uuid, p_user uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  delete from player_group_members
   where group_id = p_group and user_id = p_user and status = 'member';
  if not exists (select 1 from player_group_members
                 where group_id = p_group and status = 'member') then
    delete from player_groups where id = p_group;
  end if;
end;
$$;
revoke all on function _group_drop_member(uuid, uuid) from public, anon, authenticated;

create or replace function group_invite(p_user uuid)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := auth.uid();
  v_caller profiles;
  v_group uuid;
  v_status text;
begin
  if v_uid is null then
    raise exception 'not_authenticated';
  end if;
  select * into v_caller from profiles where id = v_uid;
  if not found or v_caller.status <> 'approved' or v_caller.role = 'kiosk' then
    raise exception 'not_allowed';
  end if;
  if p_user = v_uid or not exists (
    select 1 from profiles
     where id = p_user and tenant_id = v_caller.tenant_id
       and status = 'approved' and role <> 'kiosk' and not placeholder
  ) then
    raise exception 'unknown_player';
  end if;

  select group_id into v_group from player_group_members
   where user_id = v_uid and status = 'member';
  if v_group is null then
    insert into player_groups (tenant_id, created_by)
      values (v_caller.tenant_id, v_uid) returning id into v_group;
    insert into player_group_members (group_id, user_id, tenant_id, status)
      values (v_group, v_uid, v_caller.tenant_id, 'member');
  end if;

  select status into v_status from player_group_members
   where group_id = v_group and user_id = p_user;
  if v_status = 'member' then
    raise exception 'already_member';
  elsif v_status = 'invited' then
    raise exception 'already_invited';
  end if;
  insert into player_group_members (group_id, user_id, tenant_id, status, invited_by)
    values (v_group, p_user, v_caller.tenant_id, 'invited', v_uid);
end;
$$;

create or replace function group_accept(p_group uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then
    raise exception 'not_authenticated';
  end if;
  update player_group_members set status = 'member'
   where group_id = p_group and user_id = auth.uid() and status = 'invited';
  if not found then
    raise exception 'unknown_invite';
  end if;
exception when unique_violation then
  raise exception 'already_in_group';
end;
$$;

create or replace function group_decline(p_group uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then
    raise exception 'not_authenticated';
  end if;
  delete from player_group_members
   where group_id = p_group and user_id = auth.uid() and status = 'invited';
  if not found then
    raise exception 'unknown_invite';
  end if;
end;
$$;

create or replace function group_leave()
returns void language plpgsql security definer set search_path = public as $$
declare
  v_group uuid := my_group_id();
begin
  if auth.uid() is null then
    raise exception 'not_authenticated';
  end if;
  if v_group is not null then
    perform _group_drop_member(v_group, auth.uid());
  end if;
end;
$$;

create or replace function group_cancel_invite(p_group uuid, p_user uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then
    raise exception 'not_authenticated';
  end if;
  if my_group_id() is distinct from p_group then
    raise exception 'not_allowed';
  end if;
  delete from player_group_members
   where group_id = p_group and user_id = p_user and status = 'invited';
  if not found then
    raise exception 'unknown_invite';
  end if;
end;
$$;

create or replace function group_remove_member(p_user uuid)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_group uuid;
begin
  if not is_admin() then
    raise exception 'not_allowed';
  end if;
  if not exists (select 1 from profiles
                 where id = p_user and tenant_id = current_tenant_id()) then
    raise exception 'not_allowed';
  end if;
  select group_id into v_group from player_group_members
   where user_id = p_user and status = 'member';
  if v_group is not null then
    perform _group_drop_member(v_group, p_user);
  end if;
end;
$$;

revoke all on function group_invite(uuid) from public, anon;
revoke all on function group_accept(uuid) from public, anon;
revoke all on function group_decline(uuid) from public, anon;
revoke all on function group_leave() from public, anon;
revoke all on function group_cancel_invite(uuid, uuid) from public, anon;
revoke all on function group_remove_member(uuid) from public, anon;
grant execute on function group_invite(uuid) to authenticated;
grant execute on function group_accept(uuid) to authenticated;
grant execute on function group_decline(uuid) to authenticated;
grant execute on function group_leave() to authenticated;
grant execute on function group_cancel_invite(uuid, uuid) to authenticated;
grant execute on function group_remove_member(uuid) to authenticated;

-- Reservations: who cancelled (for "Petr ti zrušil trénink"), and 'group'
-- as a way in and out.
alter table reservations
  add column cancelled_by uuid references profiles(id) on delete set null;
alter table reservations drop constraint reservations_created_via_check;
alter table reservations add constraint reservations_created_via_check
  check (created_via in ('app', 'kiosk', 'admin', 'group'));
alter table reservations drop constraint reservations_cancelled_via_check;
alter table reservations add constraint reservations_cancelled_via_check
  check (cancelled_via in ('app', 'one_click', 'admin', 'group'));
```

A na konec migrace `create or replace function create_reservation(...)` a `create or replace function cancel_reservation(...)`: **zkopírovat celá současná těla ze `supabase/schema.sql`** (`create_reservation` ř. ~507–617, `cancel_reservation` ř. ~354–405, se stejnou signaturou včetně defaultů `p_note text default ''`, `p_notify boolean default true`) a v nich změnit PŘESNĚ tyto tři místa:

1. `create_reservation` — nová větev za `elsif v_caller.status = 'approved' and p_player_id = v_uid then v_via := 'app';`:
```sql
  elsif v_caller.status = 'approved' and v_caller.role = 'player'
        and same_group(v_uid, p_player_id) then
    v_via := 'group';
```
2. `create_reservation` — limit:
```sql
    if v_active_count >= v_settings.max_active_reservations then
      -- "Máš už…" would be a lie about a member's cap.
      raise exception '%',
        case when v_via = 'group' then 'member_at_limit' else 'limit_reached' end;
    end if;
```
3. `cancel_reservation` — větev „vlastní" nahradit větví „vlastní nebo člen skupiny" a zapisovat `cancelled_by`:
```sql
  elsif v_caller.status = 'approved'
        and (v_res.player_id = v_uid
             or (v_caller.role = 'player' and same_group(v_uid, v_res.player_id))) then
    select * into v_block from time_blocks where id = v_res.block_id;
    v_starts := (v_res.date + v_block.starts_at) at time zone 'Europe/Prague';
    if v_now >= v_starts then
      raise exception 'too_late';
    end if;
    v_via := case when v_res.player_id = v_uid then 'app' else 'group' end;
```
a v závěrečném `update reservations set …` přidat `cancelled_by = v_uid,`.

Oba `create or replace` zachovají vlastníka i granty (nemění signaturu); ověřit v Step 4, že `authenticated` je dál smí volat (existující testy to hlídají).

- [ ] **Step 4: Testy projdou**

```bash
supabase db reset
psql postgresql://postgres:postgres@127.0.0.1:54322/postgres -v ON_ERROR_STOP=1 -f supabase/tests/tenancy_rls.sql 2>&1 | grep -E "0044|FAIL|ERROR"; echo EXIT=$?
```
Expected: 9× `OK: … (0044)`, žádný FAIL, konec `ROLLBACK`, a také `OK: every streamed table is in the supabase_realtime publication`.

- [ ] **Step 5: Falzifikace** (vrátit po každé, `supabase db reset`):
  1. vynechat `and not placeholder` v `group_invite` → padne „a player without an account was invited".
  2. v `create_reservation` limitní větev vždy `limit_reached` → padne `member_at_limit` test.
  3. v `cancel_reservation` vynechat `too_late` kontrolu pro skupinu (např. podmínka `if v_now >= v_starts and v_res.player_id = v_uid`) → padne „a started training was cancelled".
  4. vynechat `grant execute on function my_group_id()` → padne RLS čtení (hráč nevidí svou skupinu) nebo privilegia.
  5. v `_group_drop_member` vynechat mazání skupiny → padne „the last member left and the group stayed".

- [ ] **Step 6: Snapshot + dokumentace**

```bash
tool/schema_snapshot.sh
git diff --stat supabase/schema.sql
```

`docs/SCHEMA.md`:
- `## Tables`: řádky `player_groups` (server-only, 0044) a `player_group_members` (select přes RLS: vlastní řádky, vlastní skupina, správce kuželny; `tenant_id` denormalizovaný kvůli policy; jedna skupina na hráče — částečný unikátní index) a u `reservations` sloupec `cancelled_by` + `'group'` v `created_via`/`cancelled_via`.
- `## RPCs`: řádek `group_invite(user)`, `group_accept(group)`, `group_decline(group)`, `group_leave()`, `group_cancel_invite(group, user)` (hráč) a `group_remove_member(user)` (správce) s chybami ze specu; u `create_reservation` a `cancel_reservation` doplnit „člen stejné skupiny (0044) za člena, pravidla hráče, limit cíle — `member_at_limit`".
- „Internal, no EXECUTE for app roles": += `same_group`, `_group_drop_member`.
- `## Checks`: += „the 0044 player groups (invite/accept/decline/leave/cancel-invite, one group per player, nobody but approved account holders of the alley invitable, a member books and cancels for a member under the member's cap and until the training starts, outsiders never, the group dies with its last member, admin prune and foreign-admin isolation, RLS and privileges)".

- [ ] **Step 7: Commit**

```bash
git add supabase/migrations/0044_player_groups.sql supabase/tests/tenancy_rls.sql supabase/schema.sql docs/SCHEMA.md
git commit -m "feat(db): skupiny hráčů — pozvánky, souhlas, rezervace navzájem (0044)

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 2: Notifikace (edge funkce `notify`)

**Files:**
- Create: `supabase/functions/_shared/group_messages.ts`, `supabase/functions/_shared/group_messages_test.ts`
- Modify: `supabase/functions/notify/index.ts`

**Interfaces — Consumes:** `player_group_members` řádky (webhook INSERT/UPDATE), `reservations.created_via/cancelled_via = 'group'`, `reservations.created_by`, `reservations.cancelled_by` (Task 1).

- [ ] **Step 1: Test** `supabase/functions/_shared/group_messages_test.ts`:

```ts
import { assertEquals } from "jsr:@std/assert";
import {
  groupBookedMessage,
  groupCancelledMessage,
  groupInviteMessage,
  groupJoinedMessage,
} from "./group_messages.ts";

Deno.test("invite names who invites and where to accept", () => {
  assertEquals(groupInviteMessage("Petr"), {
    title: "Pozvánka do skupiny",
    body: "Petr tě zve do skupiny — přijmi ji v Můj profil.",
  });
});

Deno.test("a new member is announced by name", () => {
  assertEquals(groupJoinedMessage("Jana"), {
    title: "Nový člen skupiny",
    body: "Jana je teď ve skupině.",
  });
});

Deno.test("booking and cancelling say who did it and when", () => {
  const when = "čt 24.9. 17:30–18:30, dráha 2";
  assertEquals(groupBookedMessage("Petr", when), {
    title: "Trénink zarezervován",
    body: "Petr ti zarezervoval(a) trénink: čt 24.9. 17:30–18:30, dráha 2.",
  });
  assertEquals(groupCancelledMessage("Petr", when), {
    title: "Trénink zrušen",
    body: "Petr ti zrušil(a) trénink: čt 24.9. 17:30–18:30, dráha 2.",
  });
});
```

Ověřit, jak ostatní `_shared/*_test.ts` importují assert (např. `head -5 supabase/functions/_shared/format_test.ts`) a použít stejný import.

Run: `cd supabase/functions && deno test _shared/group_messages_test.ts` → FAIL (modul neexistuje).

- [ ] **Step 2: Modul** `supabase/functions/_shared/group_messages.ts`:

```ts
// Texts of the player-group notifications (0044) — pure, so the wording is
// tested without a webhook, a database or a phone.

export type Message = { title: string; body: string };

export const groupInviteMessage = (inviter: string): Message => ({
  title: "Pozvánka do skupiny",
  body: `${inviter} tě zve do skupiny — přijmi ji v Můj profil.`,
});

export const groupJoinedMessage = (joiner: string): Message => ({
  title: "Nový člen skupiny",
  body: `${joiner} je teď ve skupině.`,
});

export const groupBookedMessage = (by: string, when: string): Message => ({
  title: "Trénink zarezervován",
  body: `${by} ti zarezervoval(a) trénink: ${when}.`,
});

export const groupCancelledMessage = (by: string, when: string): Message => ({
  title: "Trénink zrušen",
  body: `${by} ti zrušil(a) trénink: ${when}.`,
});
```

Run: `deno test _shared/group_messages_test.ts` → PASS.

- [ ] **Step 3: Zapojení do `notify/index.ts`**

1. Import: `import { groupBookedMessage, groupCancelledMessage, groupInviteMessage, groupJoinedMessage } from "../_shared/group_messages.ts";`
2. Pomocník vedle `reservationContext`:

```ts
/// One profile as a notification recipient (and its name for the text).
async function profileOf(id: unknown) {
  if (id == null) return null;
  const { data } = await supabase.from("profiles")
    .select("id, email, fcm_token, display_name").eq("id", id).maybeSingle();
  return data as (Recipient & { display_name: string }) | null;
}
```

3. `case "reservations"` → větev `INSERT`: nahradit úvodní `if (record.created_via !== "kiosk") return;` tímto (zbytek kioskové větve beze změny):

```ts
        if (record.created_via === "group") {
          const [ctx, by] = await Promise.all([
            reservationContext(record),
            profileOf(record.created_by),
          ]);
          if (!ctx || !by) return;
          const m = groupBookedMessage(by.display_name, ctx.when);
          await notifyRecipient(ctx.player, m.title, m.body, {
            data: { kind: "group_booking", reservation_id: String(record.id) },
          });
          return;
        }
        if (record.created_via !== "kiosk") return;
```

4. Větev `UPDATE` → uvnitř `if (record.cancelled_at != null) {`, PŘED `if (record.cancelled_via !== "admin") return;`:

```ts
          if (record.cancelled_via === "group") {
            if ((record.date as string) < pragueToday()) return;
            const [ctx, by] = await Promise.all([
              reservationContext(record),
              profileOf(record.cancelled_by),
            ]);
            if (!ctx || !by) return;
            const m = groupCancelledMessage(by.display_name, ctx.when);
            await notifyRecipient(ctx.player, m.title, m.body, {
              data: { kind: "group_cancelled" },
            });
            return;
          }
```

5. Nový `case` ve `switch (payload.table)`:

```ts
    case "player_group_members": {
      // Invite → the invitee. Accept (invited → member) → everyone else in
      // the group. The founder's own INSERT (status member) says nothing.
      if (payload.type === "INSERT" && record.status === "invited") {
        const [invitee, inviter] = await Promise.all([
          profileOf(record.user_id),
          profileOf(record.invited_by),
        ]);
        if (!invitee || !inviter) return;
        const m = groupInviteMessage(inviter.display_name);
        await notifyRecipient(invitee, m.title, m.body, {
          data: { kind: "group_invite" },
        });
        return;
      }
      const old = payload.old_record ?? {};
      if (payload.type === "UPDATE" && old.status === "invited" &&
          record.status === "member") {
        const joiner = await profileOf(record.user_id);
        if (!joiner) return;
        const { data: others } = await supabase.from("player_group_members")
          .select("user_id").eq("group_id", record.group_id)
          .eq("status", "member").neq("user_id", record.user_id);
        const m = groupJoinedMessage(joiner.display_name);
        for (const row of (others ?? []) as { user_id: string }[]) {
          const recipient = await profileOf(row.user_id);
          if (recipient) {
            await notifyRecipient(recipient, m.title, m.body, {
              data: { kind: "group_joined" },
            });
          }
        }
      }
      return;
    }
```

6. Úvodní komentář souboru (seznam triggerů) doplnit o `INSERT/UPDATE player_group_members` a skupinové rezervace/zrušení.

- [ ] **Step 4: Ověřit**

```bash
cd supabase/functions && deno check notify/index.ts && deno test _shared/
```
Expected: check bez chyb, všechny testy PASS.

- [ ] **Step 5: Falzifikace** — v `group_messages.ts` změnit `ti zrušil(a)` → `ti zrušil` → test padá; vrátit.

- [ ] **Step 6: Commit**

```bash
git add supabase/functions/_shared/group_messages.ts supabase/functions/_shared/group_messages_test.ts supabase/functions/notify/index.ts
git commit -m "feat(notify): zprávy pro skupiny — pozvánka, nový člen, rezervace a zrušení za člena

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 3: Doména, data a pravidla rozvrhu (Dart)

**Files:**
- Create: `lib/domain/groups.dart`, `test/domain/groups_test.dart`
- Modify: `lib/data/cache.dart` (konstanta), `lib/data/providers.dart` (providery, `Api`, reset), `lib/core/ui.dart` (`friendlyDbError`), `lib/domain/schedule.dart` (`canBook`, `canCancel`), `test/domain/schedule_test.dart`, test `friendlyDbError` (`test/core/errors_test.dart`)

**Interfaces — Produces:**
- `enum GroupStatus { invited, member }`, `class GroupRow { groupId, userId, status, invitedBy; factory fromJson }`
- `class MyGroup { String? groupId; List<String> memberIds; List<String> invitedIds; List<GroupInvite> invitesForMe; Set<String> matesOf(String me); bool get isEmpty; static const none }`, `class GroupInvite { groupId; invitedBy? }`
- `MyGroup myGroupOf(List<GroupRow> rows, String me)`, `Map<String, List<String>> groupMatesByPlayer(List<GroupRow> rows)`
- `const cacheKeyGroups = 'player_groups';`
- `groupRowsProvider` (`StreamProvider<List<GroupRow>>`), `myGroupProvider` (`Provider<MyGroup>`)
- `Api.groupInvite(String userId)`, `groupAccept(String groupId)`, `groupDecline(String groupId)`, `groupLeave()`, `groupCancelInvite(String groupId, String userId)`, `groupRemoveMember(String userId)` — všechny `Future<void>`
- `canBook(..., bool forGroup = false)`, `canCancel(..., Set<String> groupMateIds = const {})`

- [ ] **Step 1: Testy**

`test/domain/groups_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:rezervator/domain/groups.dart';

void main() {
  GroupRow row(String group, String user, GroupStatus status,
          {String? by}) =>
      GroupRow(groupId: group, userId: user, status: status, invitedBy: by);

  final rows = [
    row('g1', 'petr', GroupStatus.member),
    row('g1', 'jana', GroupStatus.member),
    row('g1', 'karel', GroupStatus.invited, by: 'petr'),
    row('g2', 'lenka', GroupStatus.member),
    row('g2', 'petr', GroupStatus.invited, by: 'lenka'),
  ];

  test('GroupRow.fromJson reads the table row', () {
    final r = GroupRow.fromJson({
      'group_id': 'g1',
      'user_id': 'u1',
      'status': 'invited',
      'invited_by': 'u2',
      'tenant_id': 't',
      'created_at': '2026-09-22T10:00:00Z',
    });
    expect(r.groupId, 'g1');
    expect(r.userId, 'u1');
    expect(r.status, GroupStatus.invited);
    expect(r.invitedBy, 'u2');
  });

  test('my group: its members, its pending invites, and invites for me', () {
    final g = myGroupOf(rows, 'petr');
    expect(g.groupId, 'g1');
    expect(g.memberIds.toSet(), {'petr', 'jana'});
    expect(g.invitedIds, ['karel']);
    expect(g.invitesForMe.single.groupId, 'g2');
    expect(g.invitesForMe.single.invitedBy, 'lenka');
    expect(g.matesOf('petr'), {'jana'});
    expect(g.isEmpty, isFalse);
  });

  test('outside any group: only invites', () {
    final g = myGroupOf(rows, 'karel');
    expect(g.groupId, isNull);
    expect(g.memberIds, isEmpty);
    expect(g.matesOf('karel'), isEmpty);
    expect(g.invitesForMe.single.groupId, 'g1');
    expect(g.isEmpty, isFalse, reason: 'a pending invite is something to show');
  });

  test('nothing at all is empty', () {
    expect(myGroupOf(const [], 'x').isEmpty, isTrue);
    expect(MyGroup.none.isEmpty, isTrue);
  });

  test('the admin view: each member with the others of the group', () {
    final byPlayer = groupMatesByPlayer(rows);
    expect(byPlayer['petr'], ['jana']);
    expect(byPlayer['jana'], ['petr']);
    expect(byPlayer['lenka'], isEmpty);
    expect(byPlayer.containsKey('karel'), isFalse, reason: 'invited is not in');
  });
}
```

Do `test/domain/schedule_test.dart` (použít existující fixtury souboru pro `FreeSlot`/`ReservedSlot`/`ScheduleSettings` — najít `canBook`/`canCancel` testy a postavit nové stejně):
- `canBook` s `myActiveCount` na limitu: bez `forGroup` → false, s `forGroup: true` → true; v minulosti ani s `forGroup` → false.
- `canCancel` rezervace člena (`playerId: 'jana'`, `myPlayerId: 'petr'`): bez `groupMateIds` → false, s `{'jana'}` → true, s `{'jana'}` ale `inPast` → false.

Do testu `friendlyDbError` pět nových kódů s přesnými texty z Global Constraints, a zvlášť: `friendlyDbError(Exception('member_at_limit'))` NEvrací text `limit_reached`.

Run: `flutter test test/domain/groups_test.dart test/domain/schedule_test.dart test/core/errors_test.dart` → FAIL (kompilace).

- [ ] **Step 2: `lib/domain/groups.dart`**

```dart
/// Skupiny hráčů (0044): members book and cancel trainings for each other.
/// Pure Dart over `player_group_members` rows — RLS hands the app its own
/// group, its own invites, and (to an admin) the whole alley.
library;

enum GroupStatus { invited, member }

class GroupRow {
  const GroupRow({
    required this.groupId,
    required this.userId,
    required this.status,
    this.invitedBy,
  });

  final String groupId;
  final String userId;
  final GroupStatus status;
  final String? invitedBy;

  factory GroupRow.fromJson(Map<String, dynamic> json) => GroupRow(
        groupId: json['group_id'] as String,
        userId: json['user_id'] as String,
        status: json['status'] == 'member'
            ? GroupStatus.member
            : GroupStatus.invited,
        invitedBy: json['invited_by'] as String?,
      );
}

/// An invite waiting for the signed-in player.
class GroupInvite {
  const GroupInvite({required this.groupId, this.invitedBy});
  final String groupId;
  final String? invitedBy;
}

class MyGroup {
  const MyGroup({
    this.groupId,
    this.memberIds = const [],
    this.invitedIds = const [],
    this.invitesForMe = const [],
  });

  static const none = MyGroup();

  /// Null outside any group.
  final String? groupId;

  /// Everyone in it, me included.
  final List<String> memberIds;

  /// Invited to MY group, not yet accepted.
  final List<String> invitedIds;

  /// Other groups inviting me.
  final List<GroupInvite> invitesForMe;

  /// Whom I may book and cancel for (the group without me).
  Set<String> matesOf(String me) => {
        for (final id in memberIds)
          if (id != me) id,
      };

  bool get isEmpty => groupId == null && invitesForMe.isEmpty;
}

MyGroup myGroupOf(List<GroupRow> rows, String me) {
  final groupId = [
    for (final r in rows)
      if (r.userId == me && r.status == GroupStatus.member) r.groupId,
  ].firstOrNull;
  return MyGroup(
    groupId: groupId,
    memberIds: [
      for (final r in rows)
        if (groupId != null &&
            r.groupId == groupId &&
            r.status == GroupStatus.member)
          r.userId,
    ],
    invitedIds: [
      for (final r in rows)
        if (groupId != null &&
            r.groupId == groupId &&
            r.status == GroupStatus.invited)
          r.userId,
    ],
    invitesForMe: [
      for (final r in rows)
        if (r.userId == me && r.status == GroupStatus.invited)
          GroupInvite(groupId: r.groupId, invitedBy: r.invitedBy),
    ],
  );
}

/// Správa → Hráči: every member with the OTHER members of their group.
Map<String, List<String>> groupMatesByPlayer(List<GroupRow> rows) {
  final byGroup = <String, List<String>>{};
  for (final r in rows) {
    if (r.status == GroupStatus.member) {
      (byGroup[r.groupId] ??= []).add(r.userId);
    }
  }
  return {
    for (final members in byGroup.values)
      for (final id in members) id: [for (final o in members) if (o != id) o],
  };
}
```

- [ ] **Step 3: Data a pravidla**

`lib/data/cache.dart` ke konstantám: `const cacheKeyGroups = 'player_groups';`

`lib/data/providers.dart` — import `../domain/groups.dart`; za `myMatchExceptionsProvider`:

```dart
/// Rows of `player_group_members` (0044) the caller may see: their own
/// group and invites, or — for an admin — the whole alley's. Written only
/// through the group_* RPCs.
final groupRowsProvider = StreamProvider<List<GroupRow>>((ref) {
  final uid = ref.watch(_authUidProvider);
  if (uid == null) return Stream.value(const []);
  return cachedRows(
          uid,
          cacheKeyGroups,
          () => _db
              .from('player_group_members')
              .stream(primaryKey: ['group_id', 'user_id']))
      .map((rows) => rows.map(GroupRow.fromJson).toList());
});

/// The signed-in player's group, pending invites included.
final myGroupProvider = Provider<MyGroup>((ref) {
  final uid = ref.watch(_authUidProvider);
  if (uid == null) return MyGroup.none;
  return myGroupOf(ref.watch(groupRowsProvider).value ?? const [], uid);
});
```

`resetTenantScopedProviders`: += `ref.invalidate(groupRowsProvider);`

`class Api` (za `setMatchException`):

```dart
  // --- skupiny hráčů (0044) ---
  static Future<void> groupInvite(String userId) =>
      _db.rpc('group_invite', params: {'p_user': userId});
  static Future<void> groupAccept(String groupId) =>
      _db.rpc('group_accept', params: {'p_group': groupId});
  static Future<void> groupDecline(String groupId) =>
      _db.rpc('group_decline', params: {'p_group': groupId});
  static Future<void> groupLeave() => _db.rpc('group_leave');
  static Future<void> groupCancelInvite(String groupId, String userId) =>
      _db.rpc('group_cancel_invite',
          params: {'p_group': groupId, 'p_user': userId});
  static Future<void> groupRemoveMember(String userId) =>
      _db.rpc('group_remove_member', params: {'p_user': userId});
```

`lib/core/ui.dart` → mapa `friendlyDbError` (za `'match_past'`):

```dart
    'member_at_limit': 'Člen skupiny už má maximální počet rezervací.',
    'already_member': 'Už je ve tvé skupině.',
    'already_invited': 'Pozvánku už má — čeká se, až ji přijme.',
    'unknown_invite': 'Tahle pozvánka už neplatí.',
    'already_in_group': 'Už jsi v jiné skupině — nejdřív z ní odejdi.',
```

`lib/domain/schedule.dart`:

```dart
/// [forGroup]: the caller may book for a group mate (0044), whose own cap
/// the server checks — the caller's full cap then no longer closes the cell.
bool canBook({
  required SlotState state,
  required int myActiveCount,
  required ScheduleSettings settings,
  bool isAdmin = false,
  bool forGroup = false,
}) {
  if (state is! FreeSlot) return false;
  if (isAdmin) return true;
  return !state.inPast &&
      !state.beyondHorizon &&
      (forGroup || !atReservationLimit(myActiveCount, settings));
}

/// Own reservation — or a group mate's (0044) — whose block has not started
/// yet may be cancelled in-app; an admin may cancel ANY reservation.
/// Client-side mirror of the cancel RPC's rules — honest UI only, the RPC
/// remains the authority.
bool canCancel({
  required SlotState state,
  required String myPlayerId,
  bool isAdmin = false,
  Set<String> groupMateIds = const {},
}) {
  if (state is! ReservedSlot) return false;
  if (isAdmin) return true;
  final owner = state.reservation.playerId;
  return !state.inPast &&
      (owner == myPlayerId || groupMateIds.contains(owner));
}
```

- [ ] **Step 4: Ověřit**

Run: `flutter analyze && flutter test test/domain/ test/core/`
Expected: `No issues found!`, vše PASS.

- [ ] **Step 5: Falzifikace** — `groupMatesByPlayer` zahrnout i `invited` → test „invited is not in" padá; `canCancel` bez `!state.inPast` pro člena → test padá. Vrátit.

- [ ] **Step 6: Commit**

```bash
git add lib/domain/groups.dart lib/domain/schedule.dart lib/data/cache.dart lib/data/providers.dart lib/core/ui.dart test/
git commit -m "feat(skupiny): doména, provider členství, Api a pravidla rozvrhu

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 4: Karta „Moje skupina" v Můj profil

**Files:**
- Create: `lib/features/profile/widgets/my_group_card.dart`, `test/features/my_group_card_test.dart`
- Modify: `lib/features/profile/profile_screen.dart`, `test/features/profile_screen_test.dart` (harness)

**Interfaces — Consumes:** `myGroupProvider`, `playersProvider` (`PlayerName.id/displayName/nick/hasAccount`), `Api.group*`, `friendlyDbError`, `tryAction`, `confirmDialog`, `compareCzech` (`lib/domain/collation.dart`), `foldDiacritics`.
**Produces:** `MyGroupCard({required String meId, invite, accept, decline, leave, cancelInvite})`.

- [ ] **Step 1: Test** `test/features/my_group_card_test.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rezervator/data/providers.dart';
import 'package:rezervator/domain/groups.dart';
import 'package:rezervator/domain/models.dart';
import 'package:rezervator/features/profile/widgets/my_group_card.dart';

void main() {
  const roster = [
    PlayerName(id: 'me', displayName: 'Já Hráč'),
    PlayerName(id: 'jana', displayName: 'Jana Nová'),
    PlayerName(id: 'petr', displayName: 'Petr Starý'),
    PlayerName(id: 'deda', displayName: 'Děda', hasAccount: false),
  ];

  final calls = <String>[];

  Widget app(MyGroup group) => ProviderScope(
        overrides: [
          myGroupProvider.overrideWithValue(group),
          playersProvider.overrideWith((ref) async => roster),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: MyGroupCard(
                meId: 'me',
                invite: (id) async => calls.add('invite:$id'),
                accept: (g) async => calls.add('accept:$g'),
                decline: (g) async => calls.add('decline:$g'),
                leave: () async => calls.add('leave'),
                cancelInvite: (g, u) async => calls.add('cancel:$g:$u'),
              ),
            ),
          ),
        ),
      );

  setUp(calls.clear);

  testWidgets('without a group it explains itself and invites', (tester) async {
    await tester.pumpWidget(app(MyGroup.none));
    await tester.pumpAndSettle();

    expect(find.text('Moje skupina'), findsOneWidget);
    expect(
        find.text('Rezervujte a rušte tréninky za sebe navzájem — třeba '
            'rodina nebo dvojice.'),
        findsOneWidget);

    await tester.tap(find.text('Pozvat do skupiny…'));
    await tester.pumpAndSettle();
    // No me, no player without an account.
    expect(find.text('Já Hráč'), findsNothing);
    expect(find.text('Děda'), findsNothing);
    await tester.enterText(find.byType(TextField), 'jan');
    await tester.pumpAndSettle();
    expect(find.text('Petr Starý'), findsNothing);
    await tester.tap(find.text('Jana Nová'));
    await tester.pumpAndSettle();
    expect(calls, ['invite:jana']);
  });

  testWidgets('an invite for me is answered on the card', (tester) async {
    await tester.pumpWidget(app(const MyGroup(
      invitesForMe: [GroupInvite(groupId: 'g2', invitedBy: 'petr')],
    )));
    await tester.pumpAndSettle();

    expect(find.text('Petr Starý tě zve do skupiny'), findsOneWidget);
    await tester.tap(find.text('Přijmout'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Odmítnout'));
    await tester.pumpAndSettle();
    expect(calls, ['accept:g2', 'decline:g2']);
  });

  testWidgets('in a group: members, pending invites to withdraw, leave',
      (tester) async {
    await tester.pumpWidget(app(const MyGroup(
      groupId: 'g1',
      memberIds: ['me', 'jana'],
      invitedIds: ['petr'],
    )));
    await tester.pumpAndSettle();

    expect(find.text('Jana Nová'), findsOneWidget);
    expect(find.text('Petr Starý'), findsOneWidget);
    expect(find.text('pozván(a)'), findsOneWidget);

    await tester.tap(find.byTooltip('Stáhnout pozvánku'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Opustit skupinu'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Opustit'));
    await tester.pumpAndSettle();
    expect(calls, ['cancel:g1:petr', 'leave']);
  });

  testWidgets('a failed accept says why in Czech', (tester) async {
    await tester.pumpWidget(ProviderScope(
      overrides: [
        myGroupProvider.overrideWithValue(const MyGroup(
          invitesForMe: [GroupInvite(groupId: 'g2', invitedBy: 'petr')],
        )),
        playersProvider.overrideWith((ref) async => roster),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: MyGroupCard(
            meId: 'me',
            accept: (_) async => throw Exception('already_in_group'),
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Přijmout'));
    await tester.pumpAndSettle();
    expect(find.text('Už jsi v jiné skupině — nejdřív z ní odejdi.'),
        findsOneWidget);
  });
}
```

Run: `flutter test test/features/my_group_card_test.dart` → FAIL (kompilace).

- [ ] **Step 2: `lib/features/profile/widgets/my_group_card.dart`**

```dart
/// Můj profil → Moje skupina (0044). Always shown — that is how a player
/// learns groups exist at all: without one it explains itself in a line and
/// offers the invite; with an invite waiting, it asks; in a group, it lists
/// who is in, who is invited, and lets the player leave.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/ui.dart';
import '../../../data/providers.dart';
import '../../../domain/collation.dart';
import '../../../domain/groups.dart';
import '../../../domain/models.dart';

class MyGroupCard extends ConsumerWidget {
  const MyGroupCard({
    super.key,
    required this.meId,
    this.invite = Api.groupInvite,
    this.accept = Api.groupAccept,
    this.decline = Api.groupDecline,
    this.leave = Api.groupLeave,
    this.cancelInvite = Api.groupCancelInvite,
  });

  final String meId;

  /// Injectable for widget tests (the Api ones need a live Supabase client).
  final Future<void> Function(String userId) invite;
  final Future<void> Function(String groupId) accept;
  final Future<void> Function(String groupId) decline;
  final Future<void> Function() leave;
  final Future<void> Function(String groupId, String userId) cancelInvite;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final group = ref.watch(myGroupProvider);
    // Names only when there is someone to name — a player outside any
    // group never waits on the roster.
    final roster = group.isEmpty
        ? const <PlayerName>[]
        : ref.watch(playersProvider).value ?? const <PlayerName>[];
    String nameOf(String? id) =>
        roster.where((p) => p.id == id).firstOrNull?.displayName ?? '?';
    final theme = Theme.of(context);

    Future<void> run(Future<void> Function() action, {String? success}) =>
        tryAction(context, action, success: success, errorText: friendlyDbError);

    return Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ListTile(
            leading: const Icon(Icons.group_outlined),
            title: const Text('Moje skupina'),
            subtitle: group.groupId == null
                ? const Text('Rezervujte a rušte tréninky za sebe navzájem '
                    '— třeba rodina nebo dvojice.')
                : null,
          ),
          for (final inv in group.invitesForMe)
            ListTile(
              key: ValueKey('invite-for-me:${inv.groupId}'),
              title: Text('${nameOf(inv.invitedBy)} tě zve do skupiny'),
              subtitle: Wrap(
                spacing: 8,
                children: [
                  FilledButton(
                    onPressed: () => run(() => accept(inv.groupId),
                        success: 'Jsi ve skupině.'),
                    child: const Text('Přijmout'),
                  ),
                  OutlinedButton(
                    onPressed: () => run(() => decline(inv.groupId)),
                    child: const Text('Odmítnout'),
                  ),
                ],
              ),
            ),
          if (group.groupId != null) ...[
            for (final id in group.memberIds)
              if (id != meId)
                ListTile(
                  dense: true,
                  leading: const Icon(Icons.person_outline),
                  title: Text(nameOf(id)),
                ),
            for (final id in group.invitedIds)
              ListTile(
                dense: true,
                leading: const Icon(Icons.hourglass_empty),
                title: Text(nameOf(id)),
                subtitle: const Text('pozván(a)'),
                trailing: IconButton(
                  tooltip: 'Stáhnout pozvánku',
                  icon: const Icon(Icons.close),
                  onPressed: () =>
                      run(() => cancelInvite(group.groupId!, id)),
                ),
              ),
          ],
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: Wrap(
              spacing: 8,
              children: [
                FilledButton.tonal(
                  onPressed: () => _pickAndInvite(context, ref, group, run),
                  child: const Text('Pozvat do skupiny…'),
                ),
                if (group.groupId != null)
                  TextButton(
                    style: TextButton.styleFrom(
                        foregroundColor: theme.colorScheme.error),
                    onPressed: () async {
                      final ok = await confirmDialog(
                        context,
                        title: 'Opustit skupinu?',
                        message: 'Ostatní za tebe přestanou moct '
                            'rezervovat a rušit — a ty za ně.',
                        confirmLabel: 'Opustit',
                      );
                      if (ok && context.mounted) await run(leave);
                    },
                    child: const Text('Opustit skupinu'),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _pickAndInvite(
    BuildContext context,
    WidgetRef ref,
    MyGroup group,
    Future<void> Function(Future<void> Function(), {String? success}) run,
  ) async {
    // The card watches the roster only when it has names to show, so it may
    // not be loaded yet — wait for it.
    final roster = await ref.read(playersProvider.future);
    if (!context.mounted) return;
    final taken = {meId, ...group.memberIds, ...group.invitedIds};
    final candidates = [
      for (final p in roster)
        if (p.hasAccount && !taken.contains(p.id)) p,
    ]..sort((a, b) => compareCzech(a.displayName, b.displayName));
    final picked = await showDialog<String>(
      context: context,
      builder: (_) => _InvitePicker(candidates: candidates),
    );
    if (picked == null || !context.mounted) return;
    await run(() => invite(picked), success: 'Pozvánka odeslána.');
  }
}

class _InvitePicker extends StatefulWidget {
  const _InvitePicker({required this.candidates});
  final List<PlayerName> candidates;

  @override
  State<_InvitePicker> createState() => _InvitePickerState();
}

class _InvitePickerState extends State<_InvitePicker> {
  final _query = TextEditingController();

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  static String _fold(String s) => foldDiacritics(s).toLowerCase();

  @override
  Widget build(BuildContext context) {
    final q = _fold(_query.text.trim());
    final shown = [
      for (final p in widget.candidates)
        if (q.isEmpty || _fold(p.displayName).contains(q) || _fold(p.nick).contains(q))
          p,
    ];
    return AlertDialog(
      title: const Text('Pozvat do skupiny'),
      content: SizedBox(
        width: 360,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _query,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: 'Hledat hráče',
                prefixIcon: Icon(Icons.search),
              ),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 8),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: [
                  for (final p in shown)
                    ListTile(
                      title: Text(p.displayName),
                      subtitle: p.nick.isEmpty ? null : Text(p.nick),
                      onTap: () => Navigator.pop(context, p.id),
                    ),
                  if (shown.isEmpty)
                    const ListTile(title: Text('Nikdo neodpovídá hledání')),
                ],
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Zrušit'),
        ),
      ],
    );
  }
}
```

(`foldDiacritics` je v `lib/domain/collation.dart`, už importovaném.)

- [ ] **Step 3: Profil** — v `profile_screen.dart` za `MyTeamsCard(...)` + `const SizedBox(height: 16),` vložit:

```dart
                MyGroupCard(meId: profile.id),
                const SizedBox(height: 16),
```
(import `widgets/my_group_card.dart`). V `test/features/profile_screen_test.dart` do KAŽDÉHO `ProviderScope(overrides: [...])` (3×) přidat `myGroupProvider.overrideWithValue(MyGroup.none),` + import `package:rezervator/domain/groups.dart`.

- [ ] **Step 4: Ověřit**

Run: `flutter analyze && flutter test test/features/my_group_card_test.dart test/features/profile_screen_test.dart`
Expected: vše PASS. Kdyby `find.text('Jana Nová')` v testu „in a group" našlo 2 (jméno i v jiné části), upravit na `findsWidgets` jen tehdy, když je druhý výskyt legitimní a zdůvodnit v reportu.

- [ ] **Step 5: Falzifikace** — v `_pickAndInvite` vynechat `p.hasAccount` → „Děda" se objeví a test padá; vrátit.

- [ ] **Step 6: Commit**

```bash
git add lib/features/profile/ test/features/my_group_card_test.dart test/features/profile_screen_test.dart
git commit -m "feat(skupiny): karta Moje skupina v Můj profil

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 5: Rozvrh — „Pro koho" a rušení za člena

**Files:**
- Create: `lib/features/schedule/widgets/group_booking_dialog.dart`, `test/features/group_booking_dialog_test.dart`
- Modify: `lib/features/schedule/schedule_callbacks.dart`, `lib/features/schedule/schedule_actions.dart`, `lib/features/schedule/widgets/slot_tile.dart`, `lib/features/schedule/week_screen.dart`
- Modify (harness): `test/features/week_screen_test.dart` (2 scopes), `test/features/home_shell_test.dart` (1), `test/features/club_colors_render_test.dart` (2)

**Interfaces — Consumes:** `myGroupProvider`, `canBook(forGroup:)`, `canCancel(groupMateIds:)` (Task 3).
**Produces:** `SlotCallbacks.groupMateIds` (`Set<String>`, default `const {}`), `ScheduleActions(groupMateIds: …)`, `showGroupBookingDialog(context, {message, meId, mates})` → `Future<String?>`.

- [ ] **Step 1: Testy**

`test/features/group_booking_dialog_test.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rezervator/features/schedule/widgets/group_booking_dialog.dart';

void main() {
  Future<String?> open(WidgetTester tester, {String? pick}) async {
    String? result = 'unset';
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => TextButton(
          onPressed: () async => result = await showGroupBookingDialog(
            context,
            message: 'čtvrtek 24. 9. · 17:30 · Dráha 2',
            meId: 'me',
            mates: const [(id: 'jana', name: 'Jana Nová')],
          ),
          child: const Text('open'),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('Pro koho'), findsOneWidget);
    if (pick != null) {
      await tester.tap(find.text(pick));
      await tester.pumpAndSettle();
    }
    await tester.tap(find.text('Rezervovat'));
    await tester.pumpAndSettle();
    return result;
  }

  testWidgets('"Já" is the default', (tester) async {
    expect(await open(tester), 'me');
  });

  testWidgets('a mate can be chosen', (tester) async {
    expect(await open(tester, pick: 'Jana Nová'), 'jana');
  });

  testWidgets('Zrušit books nobody', (tester) async {
    String? result = 'unset';
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => TextButton(
          onPressed: () async => result = await showGroupBookingDialog(
            context,
            message: 'x',
            meId: 'me',
            mates: const [(id: 'jana', name: 'Jana Nová')],
          ),
          child: const Text('open'),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Zrušit'));
    await tester.pumpAndSettle();
    expect(result, isNull);
  });
}
```

V `test/features/week_screen_test.dart`: do `app()` parametr `MyGroup group = MyGroup.none` a override `myGroupProvider.overrideWithValue(group)`; do druhého `ProviderScope` (~ř. 1223) `myGroupProvider.overrideWithValue(MyGroup.none)`. Nové testy (portrait nebo wide surface podle vzoru existujících „Rezervovat termín?" testů, hráč `me`, spoluhráč `p2` z `players`):

```dart
  testWidgets('in a group a free cell asks for whom', (tester) async {
    // wideSurface/portraitSurface jako sousední booking testy
    await tester.pumpWidget(app(
      group: const MyGroup(groupId: 'g', memberIds: ['me', 'p2']),
    ));
    await tester.pumpAndSettle();
    // Klepnout na volnou buňku stejně jako v existujícím testu
    // „Rezervovat termín?" (zkopírovat jeho vyhledání buňky).
    expect(find.text('Pro koho'), findsOneWidget);
    expect(find.text('Petr Novák'), findsOneWidget);
  });

  testWidgets('without a group the plain confirm stays', (tester) async {
    // stejný tap bez group → 'Rezervovat termín?' a žádné 'Pro koho'
  });

  testWidgets("a group mate's reservation offers the cancel, naming them",
      (tester) async {
    // reservations: [res('r1', 'p2', tomorrow)], group memberIds ['me','p2']
    // tap na buňku s 'Péťa' → 'Zrušit rezervaci?' + text obsahuje
    // 'Petr Novák' a 'Dostane o tom zprávu.'
  });

  testWidgets("outside the group the same tap only names the player",
      (tester) async {
    // bez group → SnackBar 'Petr Novák' (existující chování _info)
  });
```

Implementer doplní těla podle sousedních testů v souboru (vyhledání buňky, surface) — přesné texty a assertions jsou výše.

V `home_shell_test.dart` a `club_colors_render_test.dart` do každého `ProviderScope` `myGroupProvider.overrideWithValue(MyGroup.none),` (+ import `domain/groups.dart`).

Run → FAIL.

- [ ] **Step 2: Dialog** `lib/features/schedule/widgets/group_booking_dialog.dart`:

```dart
/// „Rezervovat termín?" for a player in a group (0044): the same question,
/// plus whom it is for — "Já" by default, then each group mate. A group is
/// a handful of people, so a short choice, not the admin's roster search.
library;

import 'package:flutter/material.dart';

Future<String?> showGroupBookingDialog(
  BuildContext context, {
  required String message,
  required String meId,
  required List<({String id, String name})> mates,
}) =>
    showDialog<String>(
      context: context,
      builder: (_) =>
          _GroupBookingDialog(message: message, meId: meId, mates: mates),
    );

class _GroupBookingDialog extends StatefulWidget {
  const _GroupBookingDialog({
    required this.message,
    required this.meId,
    required this.mates,
  });

  final String message;
  final String meId;
  final List<({String id, String name})> mates;

  @override
  State<_GroupBookingDialog> createState() => _GroupBookingDialogState();
}

class _GroupBookingDialogState extends State<_GroupBookingDialog> {
  late String _for = widget.meId;

  @override
  Widget build(BuildContext context) {
    final options = [(id: widget.meId, name: 'Já'), ...widget.mates];
    return AlertDialog(
      title: const Text('Rezervovat termín?'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(widget.message),
          const SizedBox(height: 12),
          Text('Pro koho', style: Theme.of(context).textTheme.titleSmall),
          for (final o in options)
            RadioListTile<String>(
              contentPadding: EdgeInsets.zero,
              value: o.id,
              groupValue: _for,
              title: Text(o.name),
              onChanged: (v) => setState(() => _for = v ?? _for),
            ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Zrušit'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, _for),
          child: const Text('Rezervovat'),
        ),
      ],
    );
  }
}
```

(`RadioListTile.groupValue` používá codebase i jinde — `players_screen.dart`, `appearance_card.dart`; když `flutter analyze` hlásí deprecation, přejít na tentýž vzor, jaký použijí ta místa.)

- [ ] **Step 3: Zapojení**

`schedule_callbacks.dart` — do `SlotCallbacks` konstruktoru `this.groupMateIds = const {},` a pole:

```dart
  /// Group mates (0044) whose reservations the signed-in player may book
  /// and cancel as their own. Empty outside a group, for admins it does not
  /// matter (they may anything), the kiosk never sets it.
  final Set<String> groupMateIds;
```

`slot_tile.dart` v `ReservedSlot` větvi: `canCancel(state: state, myPlayerId: me.id, isAdmin: me.isAdmin, groupMateIds: slot.groupMateIds)`; ve `FreeSlot` větvi pro `bookable`: `canBook(..., isAdmin: isAdmin, forGroup: slot.groupMateIds.isNotEmpty)` (`normallyBookable` beze změny).

`schedule_actions.dart`:
- konstruktor `this.groupMateIds = const {},` + pole `final Set<String> groupMateIds;` (doc: viz SlotCallbacks);
- `slot` getter předá `groupMateIds: groupMateIds`;
- v `_book` nahradit `else` větev:

```dart
    } else if (groupMateIds.isNotEmpty) {
      final mates = [
        for (final id in groupMateIds) (id: id, name: _displayNameOf(id)),
      ]..sort((a, b) => compareCzech(a.name, b.name));
      playerId = await showGroupBookingDialog(
        context,
        message: message,
        meId: me.id,
        mates: mates,
      );
    } else {
      final confirmed = await confirmDialog(
        context,
        title: 'Rezervovat termín?',
        message: message,
        confirmLabel: 'Rezervovat',
      );
      playerId = confirmed ? me.id : null;
    }
```

- v `_cancel` hned za větev `if (ownFuture) { … return; }`:

```dart
    // A group mate's (0044): the tile only offers it before the start, as
    // for one's own; the mate hears about it from the server.
    if (!(me?.isAdmin ?? false)) {
      final ok = await confirmDialog(
        context,
        title: 'Zrušit rezervaci?',
        message: '${_displayNameOf(r.playerId)}\n'
            '${dayFull(date)} · ${block.label} · Dráha ${r.lane}\n'
            'Dostane o tom zprávu.',
        confirmLabel: 'Zrušit rezervaci',
        cancelLabel: 'Zpět',
      );
      if (!ok || !context.mounted) return;
      await tryAction(
        context,
        () => Api.cancelReservation(r.id),
        success: 'Rezervace zrušena.',
        errorText: friendlyDbError,
      );
      return;
    }
```
- import `widgets/group_booking_dialog.dart`.

`week_screen.dart`: `final group = ref.watch(myGroupProvider);` a do `ScheduleActions(...)` `groupMateIds: me == null ? const {} : group.matesOf(me.id),` (+ import `domain/groups.dart`).

- [ ] **Step 4: Ověřit**

Run: `flutter analyze && flutter test test/features/`
Expected: vše PASS (existující testy rozvrhu, home_shell a club_colors beze změny chování).

- [ ] **Step 5: Falzifikace** — v `slot_tile.dart` nepředat `groupMateIds` do `canCancel` → test „a group mate's reservation offers the cancel" padá; v `_book` vynechat větev skupiny → „asks for whom" padá. Vrátit.

- [ ] **Step 6: Commit**

```bash
git add lib/features/schedule/ test/features/
git commit -m "feat(skupiny): rozvrh — rezervace pro člena a rušení za člena

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 6: Správa → Hráči

**Files:**
- Modify: `lib/features/admin/players_screen.dart`, `test/features/players_screen_test.dart`

**Interfaces — Consumes:** `groupRowsProvider`, `groupMatesByPlayer`, `Api.groupRemoveMember`.

- [ ] **Step 1: Test** — v `test/features/players_screen_test.dart` do `app()` override `groupRowsProvider.overrideWith((ref) => Stream.value(rows))` s parametrem `List<GroupRow> groupRows = const []`, a `PlayersScreen(removeFromGroup: …)` s parametrem pro zachycení volání. Nový test: dva členové (`p1`, `p2` z fixtur souboru — použít existující profily) ve skupině → u `p1` text obsahuje `skupina: {displayName p2}`; menu (`PopupMenuButton` u řádku `p1`) nabízí `Odebrat ze skupiny` → potvrzení → zachycené volání `p1`. Hráč mimo skupinu tu položku nemá.

Run → FAIL.

- [ ] **Step 2: Implementace**
- `const PlayersScreen({super.key, this.removeFromGroup = Api.groupRemoveMember});` + `final Future<void> Function(String userId) removeFromGroup;` (doc: injectable for tests).
- v `build`: `final mates = groupMatesByPlayer(ref.watch(groupRowsProvider).value ?? const []);` a jména z `profiles` (už k dispozici v builderu).
- `_subtitle(Profile p)` → `_subtitle(Profile p, List<String> groupNames)`: do `marks` přidat `if (groupNames.isNotEmpty) 'skupina: ${groupNames.join(', ')}'`.
- `_memberMenu(Profile p, {required bool inGroup})`: `if (inGroup) const PopupMenuItem(value: 'remove_from_group', child: Text('Odebrat ze skupiny')),`.
- `onSelected` case `'remove_from_group'`: `confirmDialog(title: 'Odebrat ze skupiny?', message: '${p.displayName} přestane rezervovat za ostatní ve skupině a oni za něj.', confirmLabel: 'Odebrat')` → `tryAction(context, () => removeFromGroup(p.id), success: 'Odebráno ze skupiny.', errorText: friendlyDbError)`.

- [ ] **Step 3: Ověřit** — `flutter analyze && flutter test test/features/players_screen_test.dart` → PASS.
- [ ] **Step 4: Falzifikace** — vynechat `inGroup` podmínku (položka u všech) → test „mimo skupinu nemá" padá; vrátit.
- [ ] **Step 5: Commit**

```bash
git add lib/features/admin/players_screen.dart test/features/players_screen_test.dart
git commit -m "feat(skupiny): Správa → Hráči ukáže skupinu a umí z ní odebrat

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 7: Changelog a závěrečné ověření

- [ ] Do `lib/features/profile/changelog_data.dart`, horní dávka `Release(null, …)` (nebo nová s dnešním datem, pokud horní už má verzi): `'Skupiny: rodina nebo dvojice si může rezervovat a rušit tréninky '
        'navzájem — založíš ji v Můj profil.',`
- [ ] `flutter analyze` → `No issues found!`; `flutter test` → vše PASS.
- [ ] `supabase db reset && psql … -f supabase/tests/tenancy_rls.sql` → žádný FAIL, `ROLLBACK`; `tool/schema_snapshot.sh` + `git diff --exit-code supabase/schema.sql` čisté.
- [ ] `cd supabase/functions && deno check notify/index.ts && deno test _shared/`.
- [ ] Commit `docs(changelog): skupiny hráčů` (+ Co-Authored-By).
- [ ] Po merge (deploy-backend aplikuje 0044 a nasadí `notify`): na dvou účtech — pozvat, přijmout (notifikace), zarezervovat za člena (notifikace), zrušit za člena (notifikace), opustit.
