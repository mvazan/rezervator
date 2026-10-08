-- Tenancy isolation smoke-tests. Run against a LOCAL stack (supabase start
-- + supabase db reset) or inside BEGIN…ROLLBACK on prod:
--   psql postgresql://postgres:postgres@127.0.0.1:54322/postgres \
--     -v ON_ERROR_STOP=1 -f supabase/tests/tenancy_rls.sql
-- CI runs it in the `backend` job. Simulates two tenants and a superadmin
-- and asserts zero cross-tenant visibility, the schedule/rental cascades,
-- the 0022 placeholder (hráč bez účtu) lifecycle and the 0023 Google
-- Calendar plumbing (nonces, server-only tables, job producers, cron).
begin;

-- Fixtures: both tenants + one profile in each (auth.users stubs). The
-- suite owns its tenants; it deliberately does not borrow the bootstrap
-- kuželna, whose id went to Demo in 0026 (and became random).
insert into tenants (id, name) values
  ('00000000-0000-0000-0000-00000000000a', 'Kuželna A'),
  ('00000000-0000-0000-0000-000000000002', 'Kuželna B');

insert into auth.users (id, email) values
  ('10000000-0000-0000-0000-000000000001', 'a@example.com'),
  ('10000000-0000-0000-0000-000000000002', 'b@example.com'),
  ('10000000-0000-0000-0000-000000000003', 'c@example.com'),
  ('10000000-0000-0000-0000-000000000004', 's@example.com')
on conflict do nothing;

insert into profiles (id, tenant_id, display_name, email, role, status)
values
  ('10000000-0000-0000-0000-000000000001',
   '00000000-0000-0000-0000-00000000000a', 'Hráč A', 'a@example.com',
   'admin', 'approved'),
  ('10000000-0000-0000-0000-000000000002',
   '00000000-0000-0000-0000-000000000002', 'Hráč B', 'b@example.com',
   'admin', 'approved'),
  -- pending player in tenant A: the cross-tenant approve target
  ('10000000-0000-0000-0000-000000000003',
   '00000000-0000-0000-0000-00000000000a', 'Čekající C', 'c@example.com',
   'player', 'pending'),
  -- superadmin at home in tenant A (0014/0015)
  ('10000000-0000-0000-0000-000000000004',
   '00000000-0000-0000-0000-00000000000a', 'Super S', 's@example.com',
   'admin', 'approved');
update profiles set superadmin = true,
  home_tenant_id = '00000000-0000-0000-0000-00000000000a'
where id = '10000000-0000-0000-0000-000000000004';
-- A new alley has no training day (0063); the suite's alleys train on
-- Monday, Tuesday and Thursday, as the alleys did before.
update schedule_settings set training_weekdays = '{1,2,4}'
 where tenant_id in ('00000000-0000-0000-0000-00000000000a',
                     '00000000-0000-0000-0000-000000000002');

-- Privileges as code (0017/0020): anon has nothing, the players view is
-- read-only, app tables carry plain DML for authenticated.
do $$
begin
  if has_table_privilege('anon', 'public.reservations', 'select') then
    raise exception 'FAIL: anon may read reservations';
  end if;
  if has_table_privilege('authenticated', 'public.players', 'insert')
     or has_table_privilege('authenticated', 'public.players', 'update') then
    raise exception 'FAIL: players view is writable for authenticated';
  end if;
  if not has_table_privilege('authenticated', 'public.time_blocks', 'insert') then
    raise exception 'FAIL: authenticated lacks DML on time_blocks';
  end if;
  raise notice 'OK: privileges match 0017/0020';
end $$;

-- 0046: nothing is granted by default, so every table grants itself — and
-- whatever a migration forgets shows up here, not first in production.
do $$
declare
  v_bad text;
begin
  if exists (
    select 1 from pg_default_acl d, aclexplode(d.defaclacl) a
     where d.defaclrole = 'postgres'::regrole
       and d.defaclnamespace = 'public'::regnamespace
       and d.defaclobjtype in ('r', 'S')
       and a.grantee in ('anon'::regrole, 'authenticated'::regrole,
                         'service_role'::regrole)) then
    raise exception 'FAIL: new public tables/sequences are granted by default again (0046)';
  end if;
  -- Edge functions run as service_role: every table and view is theirs.
  select string_agg(c.relname, ', ' order by c.relname) into v_bad
    from pg_class c
   where c.relnamespace = 'public'::regnamespace
     and c.relkind in ('r', 'p', 'v', 'm')
     and not (has_table_privilege('service_role', c.oid, 'select')
          and has_table_privilege('service_role', c.oid, 'insert')
          and has_table_privilege('service_role', c.oid, 'update')
          and has_table_privilege('service_role', c.oid, 'delete'));
  if v_bad is not null then
    raise exception 'FAIL: service_role lacks DML on %', v_bad;
  end if;
  select string_agg(c.relname, ', ' order by c.relname) into v_bad
    from pg_class c
   where c.relnamespace = 'public'::regnamespace
     and c.relkind in ('r', 'p', 'v', 'm')
     and has_table_privilege('anon', c.oid,
           'select,insert,update,delete,truncate,references,trigger');
  if v_bad is not null then
    raise exception 'FAIL: anon has a privilege on %', v_bad;
  end if;
  raise notice 'OK: no default table grants; service_role everywhere, anon nowhere (0046)';
end $$;

-- Tenant A creates a block; tenant B must not see it.
set local role authenticated;
set local request.jwt.claims =
  '{"sub":"10000000-0000-0000-0000-000000000001","role":"authenticated"}';
insert into time_blocks (starts_at, ends_at, position)
values ('16:00', '17:00', 0);

set local request.jwt.claims =
  '{"sub":"10000000-0000-0000-0000-000000000002","role":"authenticated"}';
do $$
begin
  if exists (select 1 from time_blocks) then
    raise exception 'FAIL: tenant B sees tenant A blocks';
  end if;
  -- tenant B's admin is himself a `players` row — only FOREIGN rows fail.
  if exists (select 1 from players
             where id <> '10000000-0000-0000-0000-000000000002') then
    raise exception 'FAIL: tenant B sees tenant A players';
  end if;
  if exists (select 1 from schedule_settings
             where tenant_id <> current_tenant_id()) then
    raise exception 'FAIL: tenant B reads foreign settings';
  end if;
  raise notice 'OK: cross-tenant reads are empty';
end $$;

-- Cross-tenant admin RPCs are no-ops: tenant B's admin tries to approve
-- tenant A's PENDING player — the row must stay pending.
do $$
begin
  perform approve_player('10000000-0000-0000-0000-000000000003');
  if exists (select 1 from profiles
             where id = '10000000-0000-0000-0000-000000000003'
               and status = 'approved') then
    raise exception 'FAIL: cross-tenant approve took effect';
  end if;
  raise notice 'OK: cross-tenant approve is a no-op';
end $$;

-- Superadmin switches into tenant B: invisible there (players view) and
-- scoped to B like any member.
set local request.jwt.claims =
  '{"sub":"10000000-0000-0000-0000-000000000004","role":"authenticated"}';
select switch_tenant('00000000-0000-0000-0000-000000000002');
do $$
begin
  if exists (select 1 from players
             where id = '10000000-0000-0000-0000-000000000004') then
    raise exception 'FAIL: visiting superadmin listed in players';
  end if;
  if exists (select 1 from time_blocks) then
    raise exception 'FAIL: visiting superadmin sees tenant A blocks from B';
  end if;
  raise notice 'OK: visiting superadmin is invisible and scoped to B';
end $$;

set local request.jwt.claims =
  '{"sub":"10000000-0000-0000-0000-000000000002","role":"authenticated"}';
do $$
begin
  if exists (select 1 from players
             where id = '10000000-0000-0000-0000-000000000004') then
    raise exception 'FAIL: tenant B admin sees the visiting superadmin';
  end if;
  raise notice 'OK: tenant B does not list the visitor';
end $$;

-- Grid shrink cancels stranded reservations server-side (0018): a lane-2
-- reservation dies when lane_count drops to 1, deactivating the block kills
-- the rest; both carry 'změna rozvrhu'.
set local request.jwt.claims =
  '{"sub":"10000000-0000-0000-0000-000000000001","role":"authenticated"}';
do $$
declare
  v_block uuid;
  v_far date := (now() at time zone 'Europe/Prague')::date + 7;
  v_weekdays smallint[];
begin
  select training_weekdays into v_weekdays from schedule_settings
  where tenant_id = current_tenant_id();
  while not (extract(isodow from v_far)::smallint = any (v_weekdays)) loop
    v_far := v_far + 1;
  end loop;
  select id into v_block from time_blocks limit 1;
  perform create_reservation('10000000-0000-0000-0000-000000000001',
                             v_far, v_block, 2::smallint);
  perform create_reservation('10000000-0000-0000-0000-000000000001',
                             v_far, v_block, 1::smallint);
  update schedule_settings set lane_count = 1
  where tenant_id = current_tenant_id();
  if exists (select 1 from reservations
             where lane = 2 and cancelled_at is null) then
    raise exception 'FAIL: lane-2 reservation survived lane_count = 1';
  end if;
  if not exists (select 1 from reservations
                 where lane = 1 and cancelled_at is null) then
    raise exception 'FAIL: lane-1 reservation was cancelled by mistake';
  end if;
  update time_blocks set active = false where id = v_block;
  if exists (select 1 from reservations where cancelled_at is null) then
    raise exception 'FAIL: reservation survived block deactivation';
  end if;
  if exists (select 1 from reservations
             where cancel_note <> 'změna rozvrhu') then
    raise exception 'FAIL: cascade note is not změna rozvrhu';
  end if;
  raise notice 'OK: stranded reservations are cancelled server-side';
end $$;

-- Rental exceptions (0021): a weekly series blocks its lanes; a child row for
-- one date shrinks, enlarges or skips that occurrence; deleting it re-applies
-- the series and cancels what was booked meanwhile. The 0018 block above left
-- lane_count = 1 and the only block inactive, so this one restores a grid.
do $$
declare
  v_uid constant uuid := '10000000-0000-0000-0000-000000000001';
  v_series constant uuid := '20000000-0000-0000-0000-000000000001';
  v_blk uuid;
  v_child uuid;
  v_once uuid;
  v_d1 date := (now() at time zone 'Europe/Prague')::date + 7;
  v_d2 date;
  v_weekdays smallint[];
  v_res1 uuid;
  v_res2 uuid;
  v_res3 uuid;
  v_name text;
  v_color smallint;
begin
  update schedule_settings set lane_count = 4
  where tenant_id = current_tenant_id();
  insert into time_blocks (starts_at, ends_at, position)
  values ('17:00', '18:00', 1) returning id into v_blk;
  select training_weekdays into v_weekdays from schedule_settings
  where tenant_id = current_tenant_id();
  while not (extract(isodow from v_d1)::smallint = any (v_weekdays)) loop
    v_d1 := v_d1 + 1;
  end loop;
  v_d2 := v_d1 + 7;
  if has_function_privilege('authenticated',
       'public.rental_occurrences(uuid, date)', 'execute') then
    raise exception 'FAIL: rental_occurrences is callable by app roles';
  end if;

  insert into rentals (id, renter_name, lanes, weekday, starts_at, ends_at,
                       created_by)
  values (v_series, 'Firma X', '{1,2}', extract(isodow from v_d1)::smallint,
          '17:00', '18:00', v_uid);
  -- 1) the series blocks lane 1; lane 3 is free
  begin
    perform create_reservation(v_uid, v_d1, v_blk, 1::smallint);
    raise exception 'FAIL: series rental did not block lane 1';
  exception when others then
    if sqlerrm <> 'blocked_by_rental' then raise; end if;
  end;
  select id into v_res3 from create_reservation(v_uid, v_d1, v_blk, 3::smallint);
  -- 2) exception: lane 1 only → lane 2 opens, lane 1 stays shut, next week
  --    untouched; name and colour come from the series
  insert into rentals (parent_id, date, lanes, starts_at, ends_at, created_by)
  values (v_series, v_d1, '{1}', '17:00', '18:00', v_uid)
  returning id into v_child;
  select renter_name, color into v_name, v_color from rentals where id = v_child;
  if v_name <> 'Firma X' or v_color <> -2 then
    raise exception 'FAIL: exception did not copy renter_name/color';
  end if;
  select id into v_res2 from create_reservation(v_uid, v_d1, v_blk, 2::smallint);
  begin
    perform create_reservation(v_uid, v_d1, v_blk, 1::smallint);
    raise exception 'FAIL: exception freed lane 1';
  exception when others then
    if sqlerrm <> 'blocked_by_rental' then raise; end if;
  end;
  begin
    perform create_reservation(v_uid, v_d2, v_blk, 2::smallint);
    raise exception 'FAIL: exception leaked to the next occurrence';
  exception when others then
    if sqlerrm <> 'blocked_by_rental' then raise; end if;
  end;
  -- 3) enlarging cancels + notifies like the series cascade
  update rentals set lanes = '{1,2,3}' where id = v_child;
  if (select count(*) from reservations
      where id in (v_res2, v_res3) and cancelled_via = 'admin'
        and cancel_note = 'pronájem: Firma X' and notify_player) <> 2 then
    raise exception 'FAIL: enlarged exception did not cancel lanes 2 and 3';
  end if;
  -- 4) skipped frees everything; a series row cannot be skipped
  update rentals set skipped = true where id = v_child;
  select id into v_res1 from create_reservation(v_uid, v_d1, v_blk, 1::smallint);
  begin
    update rentals set skipped = true where id = v_series;
    raise exception 'FAIL: series row accepted skipped';
  exception when check_violation then null;
  end;
  -- 5) deleting the exception re-applies the series for that date
  delete from rentals where id = v_child;
  if not exists (select 1 from reservations
                 where id = v_res1 and cancelled_via = 'admin'
                   and cancel_note = 'pronájem: Firma X' and notify_player) then
    raise exception 'FAIL: deleting the exception did not cancel the meanwhile booking';
  end if;
  begin
    perform create_reservation(v_uid, v_d1, v_blk, 1::smallint);
    raise exception 'FAIL: series not re-applied after the exception was deleted';
  exception when others then
    if sqlerrm <> 'blocked_by_rental' then raise; end if;
  end;
  raise notice 'OK: rental exceptions shrink, enlarge, skip and re-apply';

  -- 6) validation: off-series date, one-time parent
  begin
    insert into rentals (parent_id, date, lanes, starts_at, ends_at, created_by)
    values (v_series, v_d1 + 1, '{1}', '17:00', '18:00', v_uid);
    raise exception 'FAIL: off-series exception accepted';
  exception when others then
    if sqlerrm <> 'rental_exception_invalid' then raise; end if;
  end;
  insert into rentals (renter_name, lanes, date, starts_at, ends_at, created_by)
  values ('Jednorázový', '{4}', v_d1 + 1, '17:00', '18:00', v_uid)
  returning id into v_once;
  begin
    insert into rentals (parent_id, date, lanes, starts_at, ends_at, created_by)
    values (v_once, v_d1 + 1, '{4}', '17:00', '18:00', v_uid);
    raise exception 'FAIL: exception under a one-time rental accepted';
  exception when others then
    if sqlerrm <> 'rental_exception_invalid' then raise; end if;
  end;
  -- 7) series edits: a rename propagates, a moved weekday prunes the orphan
  insert into rentals (parent_id, date, lanes, starts_at, ends_at, created_by)
  values (v_series, v_d2, '{1}', '17:00', '18:00', v_uid)
  returning id into v_child;
  update rentals set renter_name = 'Firma Y' where id = v_series;
  if (select renter_name from rentals where id = v_child) <> 'Firma Y' then
    raise exception 'FAIL: rename did not propagate to the exception';
  end if;
  update rentals
  set weekday = (extract(isodow from v_d1)::int % 7 + 1)::smallint
  where id = v_series;
  if exists (select 1 from rentals where id = v_child) then
    raise exception 'FAIL: orphaned exception survived the weekday move';
  end if;
  perform create_reservation(v_uid, v_d2, v_blk, 1::smallint);
  raise notice 'OK: rental exceptions are validated and pruned';
end $$;

-- Tenant B sees neither the series nor its exceptions and cannot hang an
-- exception onto a foreign series.
set local request.jwt.claims =
  '{"sub":"10000000-0000-0000-0000-000000000002","role":"authenticated"}';
do $$
begin
  if exists (select 1 from rentals) then
    raise exception 'FAIL: tenant B sees tenant A rentals';
  end if;
  begin
    insert into rentals (parent_id, date, lanes, starts_at, ends_at, created_by)
    values ('20000000-0000-0000-0000-000000000001', current_date, '{1}',
            '17:00', '18:00', '10000000-0000-0000-0000-000000000002');
    raise exception 'FAIL: tenant B attached an exception to a tenant A series';
  exception when others then
    if sqlerrm <> 'rental_exception_invalid' then raise; end if;
  end;
  raise notice 'OK: tenant B sees no rentals and cannot attach an exception';
end $$;

-- reject_tenant refuses while the superadmin is inside the tenant (0018).
reset role;
insert into tenants (id, name, status) values
  ('00000000-0000-0000-0000-000000000003', 'Kuželna C', 'pending');
set local role authenticated;
set local request.jwt.claims =
  '{"sub":"10000000-0000-0000-0000-000000000004","role":"authenticated"}';
select switch_tenant('00000000-0000-0000-0000-000000000003');
do $$
begin
  begin
    perform reject_tenant('00000000-0000-0000-0000-000000000003');
    raise exception 'FAIL: reject_tenant ran while visiting';
  exception when others then
    if sqlerrm <> 'switch_home_first' then raise; end if;
  end;
  perform switch_tenant('00000000-0000-0000-0000-00000000000a');
  perform reject_tenant('00000000-0000-0000-0000-000000000003');
  if exists (select 1 from tenants
             where id = '00000000-0000-0000-0000-000000000003') then
    raise exception 'FAIL: reject_tenant did not delete the tenant';
  end if;
  raise notice 'OK: reject_tenant guards the visiting superadmin';
end $$;

-- Players without an account (0022): a hand-made profile is an approved,
-- bookable player that can hold no role, never founds a tenant and merges
-- into the account the person later registers.
set local request.jwt.claims =
  '{"sub":"10000000-0000-0000-0000-000000000001","role":"authenticated"}';
do $$
declare
  v_admin constant uuid := '10000000-0000-0000-0000-000000000001';
  v_c constant uuid := '10000000-0000-0000-0000-000000000003';
  v_ph profiles;
  v_tmp profiles;
  v_blk uuid;
  v_d date := (now() at time zone 'Europe/Prague')::date + 21;
  v_weekdays smallint[];
  v_res uuid;
begin
  select * into v_ph
  from save_placeholder_player(null, ' Důchodce D ', 'Důcha', null);
  if v_ph.tenant_id <> current_tenant_id() or not v_ph.placeholder
     or v_ph.status <> 'approved' or v_ph.role <> 'player'
     or v_ph.email <> '' or v_ph.display_name <> 'Důchodce D'
     or v_ph.approved_by is distinct from v_admin
     or v_ph.approved_at is null then
    raise exception 'FAIL: placeholder row has the wrong shape';
  end if;
  if not exists (select 1 from players where id = v_ph.id and placeholder) then
    raise exception 'FAIL: placeholder missing from players or flag not exposed';
  end if;
  perform set_config('rez.test_ph', v_ph.id::text, true);
  select * into v_ph
  from save_placeholder_player(v_ph.id, 'Důchodce D', 'Děda', null);
  if v_ph.nick <> 'Děda' then
    raise exception 'FAIL: placeholder edit did not stick';
  end if;
  begin
    perform save_placeholder_player(null, '  ', '', null);
    raise exception 'FAIL: empty display_name accepted';
  exception when others then
    if sqlerrm <> 'empty_display_name' then raise; end if;
  end;
  begin
    perform save_placeholder_player(v_c, 'X', '', null);
    raise exception 'FAIL: save_placeholder_player edited a real profile';
  exception when others then
    if sqlerrm <> 'unknown_player' then raise; end if;
  end;
  begin
    perform set_role(v_ph.id, 'admin');
    raise exception 'FAIL: placeholder became admin';
  exception when others then
    if sqlerrm <> 'placeholder_no_account' then raise; end if;
  end;
  -- bookable: the admin books for it (the kiosk goes through the same gate)
  select training_weekdays into v_weekdays from schedule_settings
  where tenant_id = current_tenant_id();
  while not (extract(isodow from v_d)::smallint = any (v_weekdays)) loop
    v_d := v_d + 1;
  end loop;
  select id into v_blk from time_blocks where active limit 1;
  select id into v_res from create_reservation(v_ph.id, v_d, v_blk, 3::smallint);
  perform set_config('rez.test_res', v_res::text, true);
  perform set_config('rez.test_d', v_d::text, true);
  perform set_config('rez.test_blk', v_blk::text, true);
  begin
    perform delete_placeholder_player(v_ph.id);
    raise exception 'FAIL: placeholder with history was deleted';
  exception when others then
    if sqlerrm <> 'player_has_history' then raise; end if;
  end;
  select * into v_tmp from save_placeholder_player(null, 'Omylem', '', null);
  perform delete_placeholder_player(v_tmp.id);
  if exists (select 1 from profiles where id = v_tmp.id) then
    raise exception 'FAIL: delete_placeholder_player left the row';
  end if;
  raise notice 'OK: placeholders are approved, bookable and roleless';
end $$;

-- Tenant B neither sees nor edits tenant A's placeholder.
set local request.jwt.claims =
  '{"sub":"10000000-0000-0000-0000-000000000002","role":"authenticated"}';
do $$
begin
  if exists (select 1 from players where placeholder) then
    raise exception 'FAIL: tenant B sees tenant A placeholders';
  end if;
  begin
    perform save_placeholder_player(current_setting('rez.test_ph')::uuid,
                                    'Únos', '', null);
    raise exception 'FAIL: tenant B edited a tenant A placeholder';
  exception when others then
    if sqlerrm <> 'unknown_player' then raise; end if;
  end;
  raise notice 'OK: placeholders are tenant-scoped';
end $$;

-- Merge: pending C takes the history and the chosen fields and is approved;
-- a real profile is never a source; an approved target works too.
set local request.jwt.claims =
  '{"sub":"10000000-0000-0000-0000-000000000001","role":"authenticated"}';
do $$
declare
  v_admin constant uuid := '10000000-0000-0000-0000-000000000001';
  v_c constant uuid := '10000000-0000-0000-0000-000000000003';
  v_ph uuid := current_setting('rez.test_ph')::uuid;
  v_res uuid := current_setting('rez.test_res')::uuid;
  v_d date := current_setting('rez.test_d')::date;
  v_blk uuid := current_setting('rez.test_blk')::uuid;
  v_tmp profiles;
begin
  begin
    perform merge_placeholder_player(v_c, v_admin, 'X', '', null);
    raise exception 'FAIL: merged a real profile as the source';
  exception when others then
    if sqlerrm <> 'invalid_merge' then raise; end if;
  end;
  perform merge_placeholder_player(v_ph, v_c, 'Cyril C', 'Děda', null);
  if exists (select 1 from profiles where id = v_ph) then
    raise exception 'FAIL: placeholder survived the merge';
  end if;
  if (select player_id from reservations where id = v_res) <> v_c then
    raise exception 'FAIL: reservation did not move to the account';
  end if;
  if not exists (select 1 from profiles
                 where id = v_c and status = 'approved'
                   and display_name = 'Cyril C' and nick = 'Děda'
                   and approved_by = v_admin and approved_at is not null) then
    raise exception 'FAIL: merge target not approved with the chosen fields';
  end if;
  if not exists (select 1 from players
                 where id = v_c and nick = 'Děda' and not placeholder) then
    raise exception 'FAIL: merged account missing from players';
  end if;
  select * into v_tmp
  from save_placeholder_player(null, 'Ještě jeden', '', null);
  perform create_reservation(v_tmp.id, v_d, v_blk, 4::smallint);
  perform merge_placeholder_player(v_tmp.id, v_c, 'Cyril C', 'Děda', null);
  if (select count(*) from reservations
      where player_id = v_c and date = v_d) <> 2 then
    raise exception 'FAIL: merge into an approved account did not move history';
  end if;
  if has_table_privilege('authenticated', 'public.players', 'insert') then
    raise exception 'FAIL: players view became writable after 0022';
  end if;
  raise notice 'OK: placeholders merge into pending and approved accounts';
end $$;

-- A placeholder never founds a tenant: the first real registrant into a
-- kuželna that only has hand-made rows is still its approved admin.
-- No auth.users stub is needed any more (profiles_id_fkey is gone).
reset role;
insert into tenants (id, name, status) values
  ('00000000-0000-0000-0000-000000000004', 'Kuželna D', 'approved');
insert into profiles (id, tenant_id, display_name, role, status, placeholder)
values (gen_random_uuid(), '00000000-0000-0000-0000-000000000004',
        'Důchodce bez účtu', 'player', 'approved', true);
set local role authenticated;
set local request.jwt.claims =
  '{"sub":"10000000-0000-0000-0000-000000000005","role":"authenticated"}';
do $$
declare
  v_p profiles;
begin
  select * into v_p from register_profile(
    'Zakladatel D', '00000000-0000-0000-0000-000000000004');
  if v_p.role <> 'admin' or v_p.status <> 'approved' then
    raise exception 'FAIL: a placeholder counted as the founding member';
  end if;
  raise notice 'OK: placeholders never found a tenant';
end $$;

-- Google Calendar (0023): the OAuth nonce is one-shot and short-lived, the
-- token/nonce/job tables are server-only, a linked player's booking, cancel
-- and a re-timed block each leave exactly one reconcile job, and the
-- service-role RPCs feed the edge functions.
reset role;
insert into profiles (id, tenant_id, display_name, email, role, status)
values ('10000000-0000-0000-0000-000000000006',
        '00000000-0000-0000-0000-00000000000a', 'Kiosk A', 'k@example.com',
        'kiosk', 'approved');
do $$
begin
  if has_table_privilege('authenticated', 'public.google_calendar_tokens', 'select')
     or has_table_privilege('authenticated', 'public.oauth_nonces', 'select')
     or has_table_privilege('authenticated', 'public.notification_jobs', 'select')
     or has_table_privilege('anon', 'public.google_calendar_links', 'select') then
    raise exception 'FAIL: a server-only calendar table is readable by an app role';
  end if;
  if not has_table_privilege('authenticated', 'public.google_calendar_links', 'select')
     or has_table_privilege('authenticated', 'public.google_calendar_links', 'insert')
     or has_table_privilege('authenticated', 'public.google_calendar_links', 'update')
     or has_table_privilege('authenticated', 'public.google_calendar_links', 'delete') then
    raise exception 'FAIL: google_calendar_links is not select-only for authenticated';
  end if;
  if not has_table_privilege('service_role', 'public.google_calendar_tokens', 'insert')
     or not has_table_privilege('service_role', 'public.notification_jobs', 'delete') then
    raise exception 'FAIL: service_role lacks a calendar table privilege';
  end if;
  if has_sequence_privilege('authenticated', 'public.notification_jobs_id_seq', 'update')
     or has_sequence_privilege('anon', 'public.notification_jobs_id_seq', 'usage') then
    raise exception 'FAIL: app roles may touch the notification_jobs id sequence';
  end if;
  if not has_function_privilege('authenticated',
       'public.start_calendar_link()', 'execute') then
    raise exception 'FAIL: start_calendar_link is not callable by the app';
  end if;
  if has_function_privilege('authenticated',
       'public.consume_calendar_nonce(text)', 'execute')
     or has_function_privilege('authenticated',
          'public.backfill_calendar_jobs(uuid)', 'execute')
     or has_function_privilege('authenticated',
          'public.set_calendar_reminders_for(uuid, int[], text)', 'execute')
     or has_function_privilege('authenticated',
          'public.my_future_reservations(uuid)', 'execute')
     or has_function_privilege('authenticated',
          'public.enqueue_notification(text, text, jsonb, interval)', 'execute')
     or has_function_privilege('authenticated',
          'public.enqueue_calendar_sync(uuid, uuid)', 'execute')
     or has_function_privilege('authenticated',
          'public.trigger_notification_jobs()', 'execute') then
    raise exception 'FAIL: a calendar helper is callable by app roles';
  end if;
  if not has_function_privilege('service_role',
       'public.consume_calendar_nonce(text)', 'execute')
     or not has_function_privilege('service_role',
          'public.backfill_calendar_jobs(uuid)', 'execute')
     or not has_function_privilege('service_role',
          'public.set_calendar_reminders_for(uuid, int[], text)', 'execute')
     or not has_function_privilege('service_role',
          'public.my_future_reservations(uuid)', 'execute') then
    raise exception 'FAIL: service_role lacks a calendar RPC';
  end if;
  raise notice 'OK: calendar tables and RPCs are server-only except the own links row';
end $$;

-- Nonce lifecycle, app side: 48 hex chars, a retry replaces the pending one.
set local role authenticated;
set local request.jwt.claims =
  '{"sub":"10000000-0000-0000-0000-000000000001","role":"authenticated"}';
do $$
declare
  v_first text;
  v_second text;
begin
  v_first := start_calendar_link();
  if v_first !~ '^[0-9a-f]{48}$' then
    raise exception 'FAIL: nonce is not 48 hex chars: %', v_first;
  end if;
  v_second := start_calendar_link();
  if v_second = v_first then
    raise exception 'FAIL: second start_calendar_link reused the nonce';
  end if;
  perform set_config('rez.test_nonce1', v_first, true);
  perform set_config('rez.test_nonce2', v_second, true);
  if exists (select 1 from google_calendar_links) then
    raise exception 'FAIL: unlinked player sees a links row';
  end if;
  raise notice 'OK: start_calendar_link issues a fresh 48-hex nonce';
end $$;

-- The kiosk is a shared device: no calendar.
set local request.jwt.claims =
  '{"sub":"10000000-0000-0000-0000-000000000006","role":"authenticated"}';
do $$
begin
  begin
    perform start_calendar_link();
    raise exception 'FAIL: the kiosk received a calendar nonce';
  exception when others then
    if sqlerrm <> 'not_allowed' then raise; end if;
  end;
  raise notice 'OK: the kiosk cannot start a calendar link';
end $$;

-- Nonce lifecycle, server side (what the callback function does), then the
-- rows it writes once Google answered: A's admin is linked.
reset role;
do $$
declare
  v_uid constant uuid := '10000000-0000-0000-0000-000000000001';
  v_first text := current_setting('rez.test_nonce1');
  v_second text := current_setting('rez.test_nonce2');
  v_stale text;
begin
  if exists (select 1 from oauth_nonces where nonce = v_first) then
    raise exception 'FAIL: the replaced nonce survived';
  end if;
  if (select count(*) from oauth_nonces
      where user_id = v_uid and consumed_at is null) <> 1 then
    raise exception 'FAIL: not exactly one unconsumed nonce per player';
  end if;
  if consume_calendar_nonce(v_second) is distinct from v_uid then
    raise exception 'FAIL: nonce did not resolve to its player';
  end if;
  if consume_calendar_nonce(v_second) is not null then
    raise exception 'FAIL: nonce consumed twice';
  end if;
  if consume_calendar_nonce('no-such-nonce') is not null then
    raise exception 'FAIL: unknown nonce accepted';
  end if;
  insert into oauth_nonces (user_id, created_at)
  values (v_uid, now() - interval '11 minutes') returning nonce into v_stale;
  if consume_calendar_nonce(v_stale) is not null then
    raise exception 'FAIL: 11-minute-old nonce accepted';
  end if;
  raise notice 'OK: calendar nonces are one-shot and expire after 10 minutes';
  insert into google_calendar_links (user_id, status, google_email)
  values (v_uid, 'linked', 'a@gmail.com');
  insert into google_calendar_tokens (user_id, refresh_token, google_calendar_id)
  values (v_uid, 'refresh-token', 'cal-id@group.calendar.google.com');
end $$;

-- A linked player (A's admin) and an unlinked one (C) book the same block on
-- a date ≥ today+28, clear of every earlier block's fixtures.
set local role authenticated;
set local request.jwt.claims =
  '{"sub":"10000000-0000-0000-0000-000000000001","role":"authenticated"}';
do $$
declare
  v_uid constant uuid := '10000000-0000-0000-0000-000000000001';
  v_c constant uuid := '10000000-0000-0000-0000-000000000003';
  v_blk uuid;
  v_d date := (now() at time zone 'Europe/Prague')::date + 28;
  v_weekdays smallint[];
  v_res uuid;
begin
  if not exists (select 1 from google_calendar_links
                 where user_id = v_uid and status = 'linked'
                   and google_email = 'a@gmail.com') then
    raise exception 'FAIL: linked player cannot read their own links row';
  end if;
  -- a block of its own: the 0021 series (lanes 1–2, 17:00) never touches it
  insert into time_blocks (starts_at, ends_at, position)
  values ('18:00', '19:00', 2) returning id into v_blk;
  select training_weekdays into v_weekdays from schedule_settings
  where tenant_id = current_tenant_id();
  while not (extract(isodow from v_d)::smallint = any (v_weekdays)) loop
    v_d := v_d + 1;
  end loop;
  select id into v_res from create_reservation(v_uid, v_d, v_blk, 1::smallint);
  perform create_reservation(v_c, v_d, v_blk, 2::smallint);
  perform set_config('rez.test_cal_blk', v_blk::text, true);
  perform set_config('rez.test_cal_d', v_d::text, true);
  perform set_config('rez.test_cal_res', v_res::text, true);
  raise notice 'OK: a linked player reads their own links row';
end $$;

reset role;
do $$
declare
  v_uid constant uuid := '10000000-0000-0000-0000-000000000001';
  v_res uuid := current_setting('rez.test_cal_res')::uuid;
  v_job notification_jobs;
begin
  if (select count(*) from notification_jobs where kind = 'calendar_sync') <> 1 then
    raise exception 'FAIL: expected exactly one calendar job, found %',
      (select count(*) from notification_jobs where kind = 'calendar_sync');
  end if;
  select * into v_job from notification_jobs where kind = 'calendar_sync';
  if v_job.kind <> 'calendar_sync'
     or v_job.dedupe_key <> 'calendar:' || v_uid || ':' || v_res
     or v_job.payload->>'user_id' <> v_uid::text
     or v_job.payload->>'reservation_id' <> v_res::text
     or v_job.attempts <> 0
     or v_job.run_at <> now() + interval '3 minutes' then
    raise exception 'FAIL: calendar job has the wrong shape: %', to_jsonb(v_job);
  end if;
  -- age it so the cancel below provably re-arms it
  update notification_jobs set run_at = now() - interval '1 hour' where kind = 'calendar_sync';
  raise notice 'OK: a linked player''s booking enqueues one calendar_sync job, an unlinked one none';
end $$;

set local role authenticated;
set local request.jwt.claims =
  '{"sub":"10000000-0000-0000-0000-000000000001","role":"authenticated"}';
select cancel_reservation(current_setting('rez.test_cal_res')::uuid);

reset role;
do $$
declare
  v_uid constant uuid := '10000000-0000-0000-0000-000000000001';
  v_res uuid := current_setting('rez.test_cal_res')::uuid;
begin
  if (select count(*) from notification_jobs where kind = 'calendar_sync') <> 1 then
    raise exception 'FAIL: the cancel added a job instead of re-arming the pending one';
  end if;
  if not exists (select 1 from notification_jobs
                 where dedupe_key = 'calendar:' || v_uid || ':' || v_res
                   and run_at = now() + interval '3 minutes') then
    raise exception 'FAIL: the cancel did not re-arm the pending job';
  end if;
  raise notice 'OK: book-then-cancel collapses into one re-armed job';
  delete from notification_jobs;
end $$;

-- A second live booking of the linked player; then the block is re-timed:
-- only live future reservations of linked players get a job — the cancelled
-- one and C's do not — and a save that keeps the times enqueues nothing.
set local role authenticated;
set local request.jwt.claims =
  '{"sub":"10000000-0000-0000-0000-000000000001","role":"authenticated"}';
do $$
declare
  v_res2 uuid;
begin
  select id into v_res2 from create_reservation(
    '10000000-0000-0000-0000-000000000001',
    current_setting('rez.test_cal_d')::date,
    current_setting('rez.test_cal_blk')::uuid, 3::smallint);
  perform set_config('rez.test_cal_res2', v_res2::text, true);
end $$;

reset role;
do $$
declare
  v_uid constant uuid := '10000000-0000-0000-0000-000000000001';
  v_blk uuid := current_setting('rez.test_cal_blk')::uuid;
  v_res2 uuid := current_setting('rez.test_cal_res2')::uuid;
begin
  delete from notification_jobs;
  update time_blocks set starts_at = starts_at + interval '5 minutes'
  where id = v_blk;
  if (select count(*) from notification_jobs where kind = 'calendar_sync') <> 1
     or not exists (select 1 from notification_jobs
                    where dedupe_key = 'calendar:' || v_uid || ':' || v_res2
                      and payload->>'reservation_id' = v_res2::text) then
    raise exception 'FAIL: re-timed block did not enqueue exactly the live linked reservation';
  end if;
  delete from notification_jobs;
  update time_blocks set starts_at = starts_at, ends_at = ends_at
  where id = v_blk;
  if exists (select 1 from notification_jobs where kind = 'calendar_sync') then
    raise exception 'FAIL: an unchanged block save enqueued a job';
  end if;
  raise notice 'OK: a re-timed block enqueues its live reservations of linked players';
end $$;

-- Service-role RPCs: backfill, reminders, the events'' raw material.
do $$
declare
  v_uid constant uuid := '10000000-0000-0000-0000-000000000001';
  v_b constant uuid := '10000000-0000-0000-0000-000000000002';
  v_res uuid := current_setting('rez.test_cal_res')::uuid;
  v_res2 uuid := current_setting('rez.test_cal_res2')::uuid;
  v_d date := current_setting('rez.test_cal_d')::date;
  v_live int;
  v_count int;
  v_minutes int[];
  v_row record;
begin
  select count(*) into v_live from reservations
  where player_id = v_uid and cancelled_at is null
    and date >= (now() at time zone 'Europe/Prague')::date;
  v_count := backfill_calendar_jobs(v_uid);
  if v_count < 1 or v_count <> v_live then
    raise exception 'FAIL: backfill returned % for % live reservations', v_count, v_live;
  end if;
  if (select count(*) from notification_jobs
      where kind = 'calendar_sync' and run_at <= now()
        and payload->>'user_id' = v_uid::text) <> v_live
     or not exists (select 1 from notification_jobs
                    where dedupe_key = 'calendar:' || v_uid || ':' || v_res2)
     or exists (select 1 from notification_jobs
                where dedupe_key = 'calendar:' || v_uid || ':' || v_res) then
    raise exception 'FAIL: backfill jobs are not the live set, due now';
  end if;
  raise notice 'OK: backfill_calendar_jobs enqueues every live future reservation, due now';

  v_minutes := set_calendar_reminders_for(v_uid, '{120,1440,120}');
  if v_minutes <> '{1440,120}'::int[]
     or (select reminder_minutes from google_calendar_links
         where user_id = v_uid) <> '{1440,120}'::int[] then
    raise exception 'FAIL: reminders not normalised to {1440,120}: %', v_minutes;
  end if;
  begin
    perform set_calendar_reminders_for(v_uid, '{1,2,3,4,5,6}');
    raise exception 'FAIL: six reminders accepted';
  exception when others then
    if sqlerrm <> 'bad_reminders' then raise; end if;
  end;
  begin
    perform set_calendar_reminders_for(v_uid, '{99999}');
    raise exception 'FAIL: a reminder beyond 4 weeks accepted';
  exception when others then
    if sqlerrm <> 'bad_reminders' then raise; end if;
  end;
  begin
    perform set_calendar_reminders_for(v_uid, '{-1}');
    raise exception 'FAIL: a negative reminder accepted';
  exception when others then
    if sqlerrm <> 'bad_reminders' then raise; end if;
  end;
  begin
    perform set_calendar_reminders_for(v_b, '{60}');
    raise exception 'FAIL: reminders stored for a player without a link';
  exception when others then
    if sqlerrm <> 'unknown_link' then raise; end if;
  end;
  if set_calendar_reminders_for(v_uid, null) <> '{}'::int[] then
    raise exception 'FAIL: null reminders are not the empty array';
  end if;
  raise notice 'OK: set_calendar_reminders_for normalises and validates';

  select * into v_row from my_future_reservations(v_uid)
  where reservation_id = v_res2;
  if not found
     or v_row.date <> v_d
     or v_row.starts_at <> '18:05'::time or v_row.ends_at <> '19:00'::time
     or v_row.lane <> 3 or v_row.alley_name <> 'Kuželna A' then
    raise exception 'FAIL: my_future_reservations row has the wrong shape: %',
      to_jsonb(v_row);
  end if;
  if (select count(*) from my_future_reservations(v_uid)) <> v_live
     or exists (select 1 from my_future_reservations(v_uid)
                where reservation_id = v_res) then
    raise exception 'FAIL: my_future_reservations is not the live set';
  end if;
  if (select array_agg(date order by date, starts_at)
      from my_future_reservations(v_uid))
     <> (select array_agg(date) from my_future_reservations(v_uid)) then
    raise exception 'FAIL: my_future_reservations is not ordered by date, starts_at';
  end if;
  raise notice 'OK: my_future_reservations lists the live set with block times and the alley name';
end $$;

-- Another player (tenant B's admin) sees no link at all.
set local role authenticated;
set local request.jwt.claims =
  '{"sub":"10000000-0000-0000-0000-000000000002","role":"authenticated"}';
do $$
begin
  if exists (select 1 from google_calendar_links) then
    raise exception 'FAIL: tenant B sees a foreign calendar link';
  end if;
  raise notice 'OK: calendar links are visible to their owner only';
end $$;

-- The dispatcher: jobs are due (backfill), the local Vault holds no
-- webhook secrets → the warning path, no error. And the minute tick exists.
reset role;
do $$
begin
  if not exists (select 1 from notification_jobs where run_at <= now()) then
    raise exception 'FAIL: no due job left for the dispatcher probe';
  end if;
  perform trigger_notification_jobs();
  if not exists (select 1 from cron.job
                 where jobname = 'notification-jobs'
                   and schedule = '* * * * *'
                   and command ~ 'trigger_notification_jobs') then
    raise exception 'FAIL: cron tick notification-jobs is not scheduled';
  end if;
  raise notice 'OK: trigger_notification_jobs tolerates an unset Vault and the minute tick is scheduled';
end $$;

-- Own colour (0024): a player edits only their own row, inside the palette.
set local role authenticated;
set local request.jwt.claims =
  '{"sub":"10000000-0000-0000-0000-000000000001","role":"authenticated"}';
do $$
begin
  update profiles set own_color = 4
  where id = '10000000-0000-0000-0000-000000000001';
  if (select own_color from profiles
      where id = '10000000-0000-0000-0000-000000000001') <> 4 then
    raise exception 'FAIL: own_color did not stick on the own row';
  end if;
  update profiles set own_color = 4
  where id = '10000000-0000-0000-0000-000000000003';
  if (select own_color from profiles
      where id = '10000000-0000-0000-0000-000000000003') <> -1 then
    raise exception 'FAIL: own_color changed on a foreign row';
  end if;
  begin
    update profiles set own_color = 12
    where id = '10000000-0000-0000-0000-000000000001';
    raise exception 'FAIL: own_color outside the palette accepted';
  exception when check_violation then null;
  end;
  -- 0042 switched the app's picker to store a packed RGB, but the check
  -- stays permissive on purpose: the 1.2.6 app in the field still writes a
  -- palette index 0-8, and clubTint still renders both. Guard that so the
  -- back-compat window is not tightened away by accident.
  update profiles set own_color = 0
  where id = '10000000-0000-0000-0000-000000000001';  -- legacy Modrá index
  if (select own_color from profiles
      where id = '10000000-0000-0000-0000-000000000001') <> 0 then
    raise exception 'FAIL: a legacy palette index is no longer accepted';
  end if;
  update profiles set own_color = 16777216 + 5985718  -- 0x5B4136, a packed RGB
  where id = '10000000-0000-0000-0000-000000000001';
  if (select own_color from profiles
      where id = '10000000-0000-0000-0000-000000000001') <> 16777216 + 5985718 then
    raise exception 'FAIL: a packed RGB own_color was rejected';
  end if;
  raise notice 'OK: own_color is own-row only; legacy index and packed RGB both accepted (0042)';
end $$;

-- app_config (0025): readable by every signed-in client, writable by nobody
-- in the app, invisible to anon.
set local role authenticated;
set local request.jwt.claims =
  '{"sub":"10000000-0000-0000-0000-000000000003","role":"authenticated"}';
do $$
begin
  if (select min_build from app_config) is null then
    raise exception 'FAIL: a signed-in player cannot read app_config';
  end if;
  begin
    update app_config set min_build = 99;
    raise exception 'FAIL: app_config is writable by a player';
  exception when insufficient_privilege then null;
  end;
  if has_table_privilege('anon', 'public.app_config', 'select') then
    raise exception 'FAIL: anon may read app_config';
  end if;
  raise notice 'OK: app_config is read-only for the app and hidden from anon';
end $$;


-- ---------------------------------------------------------------------------
-- Matches in the calendar (0027, team choice moved to calendar_teams/
-- set_calendar_teams_for by 0032+Task 3): the producers and the RPCs
-- ---------------------------------------------------------------------------
reset role;
do $$
begin
  if has_function_privilege('authenticated',
       'public.my_future_matches(uuid)', 'execute')
     or has_function_privilege('authenticated',
          'public.enqueue_match_calendar_sync(uuid, uuid)', 'execute')
     or has_function_privilege('authenticated',
          'public.match_calendar_followers(uuid, text, text)', 'execute') then
    raise exception 'FAIL: a 0027 calendar helper is callable by app roles';
  end if;
  if not has_function_privilege('service_role',
       'public.my_future_matches(uuid)', 'execute') then
    raise exception 'FAIL: service_role lacks a 0027 calendar RPC';
  end if;
  raise notice 'OK: 0027 calendar RPCs are server-only';
end $$;

-- 0033: the old RPC is gone, but match_teams stays as a mirror the shipped
-- app still reads — and set_calendar_teams_for has to keep it truthful.
do $$
declare
  v_uid constant uuid := '10000000-0000-0000-0000-000000000001';
begin
  if exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
             where n.nspname = 'public' and p.proname = 'set_calendar_match_teams_for') then
    raise exception 'FAIL: set_calendar_match_teams_for still exists';
  end if;
  if not exists (select 1 from information_schema.columns
                 where table_schema = 'public'
                   and table_name = 'google_calendar_links'
                   and column_name = 'match_teams') then
    raise exception 'FAIL: the match_teams mirror is gone while 1.2.1 still reads it';
  end if;

  perform set_calendar_teams_for(v_uid, '[
    {"team": "SKK Veverky Brno A", "calendar": "secondary", "color_id": 7},
    {"team": "KS Devítka Brno B", "calendar": "primary", "color_id": null}]'::jsonb);
  if (select match_teams from google_calendar_links where user_id = v_uid)
     <> array['KS Devítka Brno B', 'SKK Veverky Brno A'] then
    raise exception 'FAIL: the mirror does not carry what calendar_teams says';
  end if;

  perform set_calendar_teams_for(v_uid, '[
    {"team": "SKK Veverky Brno A", "calendar": "secondary", "color_id": 7}]'::jsonb);
  if (select match_teams from google_calendar_links where user_id = v_uid)
     <> array['SKK Veverky Brno A'] then
    raise exception 'FAIL: a dropped team stayed in the mirror';
  end if;
  raise notice 'OK: match_teams mirrors calendar_teams for the app that is out';
end $$;

-- A's admin (linked above) follows SKK Veverky Brno A; a home and an away
-- match of that team enqueue a job each, a match of another team none.
do $$
declare
  v_uid constant uuid := '10000000-0000-0000-0000-000000000001';
  v_tenant constant uuid := '00000000-0000-0000-0000-00000000000a';
  v_type uuid;
  v_home uuid;
  v_away uuid;
  v_other uuid;
  v_d date := (now() at time zone 'Europe/Prague')::date + 40;
  v_stored jsonb;
  v_jobs int;
begin
  -- set_calendar_teams_for (0032) only trims, it does not dedupe/sort/drop
  -- blanks itself — that is calendar-manage's job (validateTeamChoices) —
  -- so this seeds two already-distinct, pre-trimmed names, one with padding
  -- to check the trim.
  v_stored := set_calendar_teams_for(v_uid, jsonb_build_array(
    jsonb_build_object('team', ' SKK Veverky Brno A ', 'calendar', 'primary'),
    jsonb_build_object('team', 'KS Devítka Brno B', 'calendar', 'primary')));
  if (select array_agg(team order by team) from calendar_teams where user_id = v_uid)
     <> array['KS Devítka Brno B', 'SKK Veverky Brno A'] then
    raise exception 'FAIL: team names not trimmed: %',
      (select array_agg(team) from calendar_teams where user_id = v_uid);
  end if;

  select id into v_type from priority_slot_types
    where tenant_id = v_tenant and is_match and builtin;
  delete from notification_jobs where dedupe_key like 'calendar:%:match:%';

  insert into priority_slots
    (tenant_id, date, starts_at, ends_at, type_id, home_team, away_team,
     prep_minutes, description, is_away, created_by)
  values
    (v_tenant, v_d, '18:30', '21:30', v_type,
     'SKK Veverky Brno A', 'KK MS Brno D', 30, 'KP1 Sever', false, v_uid)
  returning id into v_home;
  insert into priority_slots
    (tenant_id, date, starts_at, ends_at, type_id, home_team, away_team,
     prep_minutes, description, is_away, created_by)
  values
    (v_tenant, v_d + 7, '17:00', '19:30', v_type,
     'KK Blansko B', 'SKK Veverky Brno A', 0, 'KP1 Sever · Blansko 1-6', true, v_uid)
  returning id into v_away;
  insert into priority_slots
    (tenant_id, date, starts_at, ends_at, type_id, home_team, away_team,
     prep_minutes, description, is_away, created_by)
  values
    (v_tenant, v_d, '16:30', '18:00', v_type,
     'TJ Sokol Husovice D', 'TJ Sokol Brno IV C', 0, 'KP2 Sever B', false, v_uid)
  returning id into v_other;

  if not exists (select 1 from notification_jobs
                 where dedupe_key = 'calendar:' || v_uid || ':match:' || v_home
                   and payload ->> 'match_id' = v_home::text
                   and payload ->> 'user_id' = v_uid::text) then
    raise exception 'FAIL: home match of a followed team enqueued no job';
  end if;
  if not exists (select 1 from notification_jobs
                 where dedupe_key = 'calendar:' || v_uid || ':match:' || v_away) then
    raise exception 'FAIL: away match of a followed team enqueued no job';
  end if;
  if exists (select 1 from notification_jobs
             where dedupe_key = 'calendar:' || v_uid || ':match:' || v_other) then
    raise exception 'FAIL: a match of other teams enqueued a job';
  end if;
  -- the úklid child the trigger made for the home match is not a match
  if exists (select 1 from notification_jobs j
             join priority_slots s on j.dedupe_key = 'calendar:' || v_uid || ':match:' || s.id
             where s.parent_id is not null) then
    raise exception 'FAIL: an úklid child enqueued a calendar job';
  end if;

  -- the raw material for the events: both followed matches, in date order
  if (select array_agg(match_id order by date) from my_future_matches(v_uid))
     <> array[v_home, v_away] then
    raise exception 'FAIL: my_future_matches does not list the followed matches';
  end if;
  if (select alley_name from my_future_matches(v_uid) where match_id = v_home)
     <> 'Kuželna A' then
    raise exception 'FAIL: my_future_matches lacks the alley name';
  end if;

  -- backfill re-arms every live reservation job and both match jobs, due now
  delete from notification_jobs where dedupe_key like 'calendar:' || v_uid || '%';
  v_jobs := backfill_calendar_jobs(v_uid);
  if v_jobs <> (select count(*) from reservations
                where player_id = v_uid and cancelled_at is null
                  and date >= (now() at time zone 'Europe/Prague')::date) + 2 then
    raise exception 'FAIL: backfill queued % jobs, expected the live reservations + 2 matches', v_jobs;
  end if;
  if (select count(*) from notification_jobs
      where dedupe_key like 'calendar:' || v_uid || ':match:%' and run_at <= now()) <> 2 then
    raise exception 'FAIL: backfill did not queue both match jobs due now';
  end if;

  -- re-timing the match re-arms its job; deleting it enqueues the removal
  delete from notification_jobs where dedupe_key like 'calendar:%:match:%';
  update priority_slots set starts_at = '19:00', ends_at = '22:00' where id = v_home;
  if not exists (select 1 from notification_jobs
                 where dedupe_key = 'calendar:' || v_uid || ':match:' || v_home) then
    raise exception 'FAIL: re-timed match enqueued no job';
  end if;
  delete from notification_jobs where dedupe_key like 'calendar:%:match:%';
  delete from priority_slots where id = v_away;
  if not exists (select 1 from notification_jobs
                 where dedupe_key = 'calendar:' || v_uid || ':match:' || v_away) then
    raise exception 'FAIL: deleted match enqueued no removal job';
  end if;

  -- dropping the team: no more jobs for its matches, my_future_matches empty
  perform set_calendar_teams_for(v_uid, '[]'::jsonb);
  delete from notification_jobs where dedupe_key like 'calendar:%:match:%';
  update priority_slots set description = 'KP1 Sever (přeloženo)' where id = v_home;
  if exists (select 1 from notification_jobs where dedupe_key like 'calendar:%:match:%') then
    raise exception 'FAIL: a match of an unfollowed team enqueued a job';
  end if;
  if exists (select 1 from my_future_matches(v_uid)) then
    raise exception 'FAIL: my_future_matches lists matches of unfollowed teams';
  end if;
  raise notice 'OK: matches of followed teams enqueue calendar jobs, others do not';
end $$;

-- hand_edited (0038): an imported match changed OUTSIDE an import run is
-- flagged so the next import leaves it alone. The import run itself
-- (import.run = on) never flags, a no-op update never flags, a manual match
-- (no import_key) never flags, and --force (an import-run update that sets
-- the column back) clears it. An import-style update / delete / insert on
-- priority_slots must also leave every user's team picks byte-identical —
-- the import writes matches, never who follows them.
reset role;
do $$
declare
  v_uid constant uuid := '10000000-0000-0000-0000-000000000001';
  v_tenant constant uuid := '00000000-0000-0000-0000-00000000000a';
  v_type uuid;
  v_imported uuid;
  v_manual uuid;
  v_d date := (now() at time zone 'Europe/Prague')::date + 50;
  v_before jsonb;
  v_after jsonb;
begin
  select id into v_type from priority_slot_types
    where tenant_id = v_tenant and is_match and builtin;

  insert into priority_slots
    (tenant_id, date, starts_at, ends_at, type_id, home_team, away_team,
     prep_minutes, description, is_away, created_by, import_key)
  values
    (v_tenant, v_d, '18:30', '21:00', v_type,
     'SKK Veverky Brno A', 'KK MS Brno D', 30, 'KP1 Sever · 3. kolo', false,
     v_uid, 'rozpis:KP1 Sever:3:SKK Veverky Brno A – KK MS Brno D')
  returning id into v_imported;
  insert into priority_slots
    (tenant_id, date, starts_at, ends_at, type_id, home_team, away_team,
     prep_minutes, description, is_away, created_by)
  values
    (v_tenant, v_d + 1, '18:00', '20:00', v_type,
     'Husky', 'přátelák', 0, '', false, v_uid)
  returning id into v_manual;

  -- A no-op update is not an edit.
  update priority_slots set starts_at = '18:30' where id = v_imported;
  if (select hand_edited from priority_slots where id = v_imported) then
    raise exception 'FAIL: a no-op update flagged the imported match';
  end if;

  -- The import's own update never flags.
  perform set_config('import.run', 'on', true);
  update priority_slots set starts_at = '18:00', ends_at = '20:30'
    where id = v_imported;
  perform set_config('import.run', '', true);
  if (select hand_edited from priority_slots where id = v_imported) then
    raise exception 'FAIL: the import run flagged its own update';
  end if;

  -- The admin in the app does.
  update priority_slots set starts_at = '19:00', ends_at = '21:30'
    where id = v_imported;
  if not (select hand_edited from priority_slots where id = v_imported) then
    raise exception 'FAIL: a hand edit of an imported match was not flagged';
  end if;

  -- A manual match never carries the flag — there is no import to protect
  -- it from.
  update priority_slots set starts_at = '19:00' where id = v_manual;
  if (select hand_edited from priority_slots where id = v_manual) then
    raise exception 'FAIL: a manual match got flagged';
  end if;

  -- --force: the import overwrites and clears the flag in one update.
  perform set_config('import.run', 'on', true);
  update priority_slots set starts_at = '18:00', ends_at = '20:30',
    hand_edited = false where id = v_imported;
  perform set_config('import.run', '', true);
  if (select hand_edited from priority_slots where id = v_imported) then
    raise exception 'FAIL: --force could not clear the flag';
  end if;

  -- Team picks survive an import run untouched: followed_teams, the
  -- calendar picks, their colours and the 1.2.1 mirror, before vs after an
  -- import-style rename + delete + insert.
  select jsonb_build_object(
    'followed', (select jsonb_agg(followed_teams order by id)
                   from profiles where tenant_id = v_tenant),
    'calendar', (select jsonb_agg(to_jsonb(t) order by t.user_id, t.team)
                   from calendar_teams t join profiles p on p.id = t.user_id
                   where p.tenant_id = v_tenant),
    'colors', (select jsonb_agg(to_jsonb(c) order by c.user_id, c.team)
                 from team_colors c join profiles p on p.id = c.user_id
                 where p.tenant_id = v_tenant),
    'mirror', (select jsonb_agg(l.match_teams order by l.user_id)
                 from google_calendar_links l join profiles p on p.id = l.user_id
                 where p.tenant_id = v_tenant))
  into v_before;
  if v_before->'calendar' is null or v_before->'colors' is null then
    raise exception 'FAIL: the fixture has no team picks to protect: %', v_before;
  end if;
  perform set_config('import.run', 'on', true);
  update priority_slots
    set date = v_d + 2, home_team = 'KK MS Brno F', away_team = 'SKK Veverky Brno A',
        is_away = true, description = 'KP1 Sever · 3. kolo · Brno MS',
        import_key = 'rozpis:KP1 Sever:3:KK MS Brno F – SKK Veverky Brno A'
    where id = v_imported;
  delete from priority_slots where id = v_imported;
  insert into priority_slots
    (tenant_id, date, starts_at, ends_at, type_id, home_team, away_team,
     prep_minutes, description, is_away, created_by, import_key)
  values
    (v_tenant, v_d + 3, '09:30', '11:00', v_type,
     'TJ Sokol Husovice', 'KK Blansko', 30, 'KP dorostu · 11. kolo', false,
     v_uid, 'rozpis:KP dorostu:11:TJ Sokol Husovice – KK Blansko');
  perform set_config('import.run', '', true);
  select jsonb_build_object(
    'followed', (select jsonb_agg(followed_teams order by id)
                   from profiles where tenant_id = v_tenant),
    'calendar', (select jsonb_agg(to_jsonb(t) order by t.user_id, t.team)
                   from calendar_teams t join profiles p on p.id = t.user_id
                   where p.tenant_id = v_tenant),
    'colors', (select jsonb_agg(to_jsonb(c) order by c.user_id, c.team)
                 from team_colors c join profiles p on p.id = c.user_id
                 where p.tenant_id = v_tenant),
    'mirror', (select jsonb_agg(l.match_teams order by l.user_id)
                 from google_calendar_links l join profiles p on p.id = l.user_id
                 where p.tenant_id = v_tenant))
  into v_after;
  if v_before is distinct from v_after then
    raise exception 'FAIL: an import run changed team picks: % -> %', v_before, v_after;
  end if;
  raise notice 'OK: hand_edited marks app edits of imported matches only, and an import run never touches team picks';
end $$;

-- Kiosk password (0028): only an admin of the kiosk's OWN alley gets the
-- go-ahead to set it a new one; everyone else is refused before the edge
-- function ever touches the Auth admin API.
set local role authenticated;
set local request.jwt.claims =
  '{"sub":"10000000-0000-0000-0000-000000000001","role":"authenticated"}';
do $$
declare
  v_target uuid;
begin
  v_target := kiosk_password_target('10000000-0000-0000-0000-000000000006');
  if v_target <> '10000000-0000-0000-0000-000000000006' then
    raise exception 'FAIL: kiosk_password_target returned %', v_target;
  end if;

  -- A profile of the same alley that is not a kiosk.
  begin
    perform kiosk_password_target('10000000-0000-0000-0000-000000000003');
    raise exception 'FAIL: a non-kiosk profile passed as a kiosk';
  exception when others then
    if sqlerrm <> 'unknown_kiosk' then raise; end if;
  end;
  raise notice 'OK: an admin may set a new password for their own kiosk only';
end $$;

-- Tenant B's admin must not reach tenant A's kiosk.
set local request.jwt.claims =
  '{"sub":"10000000-0000-0000-0000-000000000002","role":"authenticated"}';
do $$
begin
  perform kiosk_password_target('10000000-0000-0000-0000-000000000006');
  raise exception 'FAIL: a foreign admin reached another alley''s kiosk';
exception when others then
  if sqlerrm <> 'unknown_kiosk' then raise; end if;
  raise notice 'OK: a kiosk password stays inside its own kuželna';
end $$;

-- A plain player, admin of nothing.
set local request.jwt.claims =
  '{"sub":"10000000-0000-0000-0000-000000000003","role":"authenticated"}';
do $$
begin
  perform kiosk_password_target('10000000-0000-0000-0000-000000000006');
  raise exception 'FAIL: a non-admin set a kiosk password';
exception when others then
  if sqlerrm <> 'not_allowed' then raise; end if;
  raise notice 'OK: only an admin may set a kiosk password';
end $$;

-- Followed teams + launch view (0029): own row only, inside the checks.
set local role authenticated;
set local request.jwt.claims =
  '{"sub":"10000000-0000-0000-0000-000000000001","role":"authenticated"}';
do $$
begin
  update profiles
    set followed_teams = array['SKK Veverky Brno A'], default_view = 'trainings'
  where id = '10000000-0000-0000-0000-000000000001';
  if (select followed_teams from profiles
      where id = '10000000-0000-0000-0000-000000000001') <> array['SKK Veverky Brno A']
     or (select default_view from profiles
      where id = '10000000-0000-0000-0000-000000000001') <> 'trainings' then
    raise exception 'FAIL: followed_teams / default_view did not stick on the own row';
  end if;
  update profiles set default_view = 'trainings'
  where id = '10000000-0000-0000-0000-000000000003';
  if (select default_view from profiles
      where id = '10000000-0000-0000-0000-000000000003') <> 'calendar' then
    raise exception 'FAIL: default_view changed on a foreign row';
  end if;
  begin
    update profiles set default_view = 'week'
    where id = '10000000-0000-0000-0000-000000000001';
    raise exception 'FAIL: an unknown default_view accepted';
  exception when check_violation then null;
  end;
  begin
    update profiles
      set followed_teams = (select array_agg('T' || g) from generate_series(1, 21) g)
    where id = '10000000-0000-0000-0000-000000000001';
    raise exception 'FAIL: 21 followed teams accepted';
  exception when check_violation then null;
  end;
  if has_column_privilege('anon', 'public.profiles', 'followed_teams', 'update')
     or has_column_privilege('anon', 'public.profiles', 'default_view', 'update') then
    raise exception 'FAIL: anon may update the new profile columns';
  end if;
  raise notice 'OK: followed_teams and default_view are editable on the own row only, inside the checks';
end $$;

-- Hand-picked colours (0030): the palette range still holds, and a colour
-- packed as 0x1000000|rgb goes in everywhere a palette index used to.
set local role authenticated;
set local request.jwt.claims =
  '{"sub":"10000000-0000-0000-0000-000000000001","role":"authenticated"}';
do $$
declare
  v_club uuid;
begin
  update profiles set own_color = 16777216 + 12615680  -- 0xC0A000
  where id = '10000000-0000-0000-0000-000000000001';
  if (select own_color from profiles
      where id = '10000000-0000-0000-0000-000000000001') <> 29392896 then
    raise exception 'FAIL: a hand-picked own_color did not stick';
  end if;
  begin
    update profiles set own_color = 12
    where id = '10000000-0000-0000-0000-000000000001';
    raise exception 'FAIL: 12 accepted as a palette index';
  exception when check_violation then null;
  end;
  begin
    update profiles set own_color = 33554432  -- one past the packed range
    where id = '10000000-0000-0000-0000-000000000001';
    raise exception 'FAIL: a colour past the packed range accepted';
  exception when check_violation then null;
  end;

  -- The RPC widened with the column, so the admin can save one on a club.
  select id into v_club from upsert_club(null, 'Barevný oddíl', 29392896);
  if (select color from clubs where id = v_club) <> 29392896 then
    raise exception 'FAIL: upsert_club did not store a hand-picked colour';
  end if;
  if (select club_color from players
      where id = '10000000-0000-0000-0000-000000000001') is null then
    raise exception 'FAIL: the players view lost club_color';
  end if;

  update priority_slot_types set color = 29392896
  where tenant_id = current_tenant_id();
  update rentals set color = 29392896 where tenant_id = current_tenant_id();
  raise notice 'OK: hand-picked colours fit every colour column and upsert_club';
end $$;

-- ---------------------------------------------------------------------------
-- Second calendar and match colours (0032): a followed team is a row in
-- calendar_teams (which of the player's two Google calendars its matches go
-- to), not an entry in google_calendar_links.match_teams any more. match_teams
-- and set_calendar_match_teams_for are gone outright (0033, once
-- calendar-manage moved to set_calendar_teams_for in Task 3);
-- match_calendar_followers reads calendar_teams exclusively. calendar_teams
-- itself is select-only for the client (0035) — every write goes through
-- calendar-manage/set_calendar_teams_for, which also keeps the match_teams
-- mirror truthful; a direct client write would bypass both. The colour used
-- to live here too (color_id) but moved to its own table, team_colors, by
-- 0036 — see that section further down.
-- ---------------------------------------------------------------------------
reset role;
do $$
begin
  if not has_table_privilege('authenticated', 'public.calendar_teams', 'select') then
    raise exception 'FAIL: authenticated cannot read calendar_teams';
  end if;
  if has_table_privilege('authenticated', 'public.calendar_teams', 'insert')
     or has_table_privilege('authenticated', 'public.calendar_teams', 'update')
     or has_table_privilege('authenticated', 'public.calendar_teams', 'delete') then
    raise exception 'FAIL: calendar_teams is writable by authenticated directly';
  end if;
  if has_table_privilege('anon', 'public.calendar_teams', 'select') then
    raise exception 'FAIL: anon may read calendar_teams';
  end if;
  if has_function_privilege('authenticated',
       'public.set_calendar_teams_for(uuid, jsonb)', 'execute') then
    raise exception 'FAIL: set_calendar_teams_for is callable by the app';
  end if;
  if not has_function_privilege('service_role',
       'public.set_calendar_teams_for(uuid, jsonb)', 'execute') then
    raise exception 'FAIL: service_role lacks set_calendar_teams_for';
  end if;
  raise notice 'OK: calendar_teams is select-only for authenticated, its RPC server-only';
end $$;

-- A foreign row (tenant B's admin) to probe isolation against, and this
-- player's own fixture row — both inserted directly (server context): the
-- client can no longer write calendar_teams at all (0035), so seeding it
-- the way a real write happens now is set_calendar_teams_for's job below,
-- not a client insert. Colour (0036) is a separate table now, seeded here
-- for BOTH of this player's teams — including 'Cal Test Rival', which does
-- not become one of their calendar_teams rows until set_calendar_teams_for
-- runs below, since team_colors lives independently of that list — so the
-- my_future_matches derby check further down sees a real colour on the
-- home team that wins its tie-break, not a NULL that would let its
-- assertion pass no matter what my_future_matches actually returned.
insert into calendar_teams (user_id, team, calendar)
values
  ('10000000-0000-0000-0000-000000000002', 'Cizí tým', 'primary'),
  ('10000000-0000-0000-0000-000000000001', 'Cal Test Home', 'secondary');
insert into team_colors (user_id, team, color_id)
values
  ('10000000-0000-0000-0000-000000000002', 'Cizí tým', 2),
  ('10000000-0000-0000-0000-000000000001', 'Cal Test Home', 9),
  ('10000000-0000-0000-0000-000000000001', 'Cal Test Rival', 2);

-- A's admin: reads only their own row, and every write — own row or
-- foreign — is rejected outright (permission denied, not merely RLS-
-- filtered: the grant itself is gone).
set local role authenticated;
set local request.jwt.claims =
  '{"sub":"10000000-0000-0000-0000-000000000001","role":"authenticated"}';
do $$
declare
  v_uid constant uuid := '10000000-0000-0000-0000-000000000001';
  v_b constant uuid := '10000000-0000-0000-0000-000000000002';
begin
  if (select calendar from calendar_teams
      where user_id = v_uid and team = 'Cal Test Home') <> 'secondary' then
    raise exception 'FAIL: a player cannot read their own calendar_teams row';
  end if;
  if exists (select 1 from calendar_teams where user_id = v_b) then
    raise exception 'FAIL: a player sees another player''s calendar_teams row';
  end if;
  begin
    insert into calendar_teams (user_id, team) values (v_uid, 'Nový tým');
    raise exception 'FAIL: a player inserted their own calendar_teams row directly';
  exception when insufficient_privilege then null;
  end;
  begin
    update calendar_teams set calendar = 'primary' where user_id = v_uid;
    raise exception 'FAIL: a player updated their own calendar_teams row directly';
  exception when insufficient_privilege then null;
  end;
  begin
    delete from calendar_teams where user_id = v_b;
    raise exception 'FAIL: a player deleted a foreign calendar_teams row';
  exception when insufficient_privilege then null;
  end;
  raise notice 'OK: calendar_teams is readable (own rows only) and not writable by the client';
end $$;

-- The table's own CHECK constraints still hold for whoever DOES write it —
-- the service role, via set_calendar_teams_for — now that the client path
-- is gone (0035). (color_id's own CHECK moved to team_colors with the
-- column, 0036 — tested in that section further down.)
reset role;
do $$
declare
  v_uid constant uuid := '10000000-0000-0000-0000-000000000001';
begin
  begin
    insert into calendar_teams (user_id, team, calendar) values (v_uid, 'Bad Calendar', 'třetí');
    raise exception 'FAIL: an unknown calendar value accepted';
  exception when check_violation then null;
  end;
  raise notice 'OK: calendar_teams CHECK constraints still hold';
end $$;

-- set_calendar_teams_for: returns the previous state, stores the new one,
-- rejects more than 20 items, refuses a player without a link.
reset role;
do $$
declare
  v_uid constant uuid := '10000000-0000-0000-0000-000000000001';
  v_b constant uuid := '10000000-0000-0000-0000-000000000002';
  v_previous jsonb;
  v_stored jsonb;
  v_many jsonb;
begin
  v_previous := set_calendar_teams_for(v_uid, jsonb_build_array(
    jsonb_build_object('team', 'Cal Test Home', 'calendar', 'secondary'),
    jsonb_build_object('team', 'Cal Test Rival', 'calendar', 'primary')));
  if v_previous <> jsonb_build_array(
       jsonb_build_object('team', 'Cal Test Home', 'calendar', 'secondary')) then
    raise exception 'FAIL: set_calendar_teams_for did not return the previous state: %', v_previous;
  end if;

  select jsonb_agg(jsonb_build_object(
           'team', team, 'calendar', calendar) order by team)
    into v_stored
    from calendar_teams where user_id = v_uid;
  if v_stored <> jsonb_build_array(
       jsonb_build_object('team', 'Cal Test Home', 'calendar', 'secondary'),
       jsonb_build_object('team', 'Cal Test Rival', 'calendar', 'primary')) then
    raise exception 'FAIL: set_calendar_teams_for did not store the new rows: %', v_stored;
  end if;

  select jsonb_agg(jsonb_build_object('team', 'T' || g, 'calendar', 'primary'))
    into v_many from generate_series(1, 21) g;
  begin
    perform set_calendar_teams_for(v_uid, v_many);
    raise exception 'FAIL: 21 teams accepted';
  exception when others then
    if sqlerrm <> 'bad_teams' then raise; end if;
  end;

  begin
    perform set_calendar_teams_for(v_b, jsonb_build_array(
      jsonb_build_object('team', 'X', 'calendar', 'primary')));
    raise exception 'FAIL: teams stored for a player without a link';
  exception when others then
    if sqlerrm <> 'unknown_link' then raise; end if;
  end;
  raise notice 'OK: set_calendar_teams_for returns the previous state and stores the new one';
end $$;

-- set_calendar_reminders_for (0032): the third argument picks which
-- reminders it writes; omitted, it still means 'primary', so the pre-0032
-- 2-argument calls above are unaffected.
do $$
declare
  v_uid constant uuid := '10000000-0000-0000-0000-000000000001';
  v_before int[];
  v_returned int[];
  v_secondary int[];
begin
  select reminder_minutes into v_before from google_calendar_links where user_id = v_uid;
  -- assign-then-compare, not inline: Postgres does not guarantee this write
  -- (inside the OR) runs before a sibling read of the same row would see it.
  v_returned := set_calendar_reminders_for(v_uid, '{30,90}', 'secondary');
  select reminder_minutes_secondary into v_secondary from google_calendar_links where user_id = v_uid;
  if v_returned <> '{90,30}'::int[] or v_secondary <> '{90,30}'::int[] then
    raise exception 'FAIL: secondary reminders not normalised/stored';
  end if;
  if (select reminder_minutes from google_calendar_links where user_id = v_uid)
     is distinct from v_before then
    raise exception 'FAIL: writing secondary reminders touched the primary list';
  end if;
  begin
    perform set_calendar_reminders_for(v_uid, '{10}', 'tertiary');
    raise exception 'FAIL: an unknown calendar slot accepted';
  exception when others then
    if sqlerrm <> 'bad_calendar' then raise; end if;
  end;
  raise notice 'OK: set_calendar_reminders_for''s third argument targets the right reminders column';
end $$;

-- my_future_matches: each match carries the followed team's calendar
-- (calendar_teams) and colour (team_colors, 0036 — the same team the
-- calendar/derby resolution above already picked); when both teams are
-- followed (derby), the home team's row wins.
do $$
declare
  v_uid constant uuid := '10000000-0000-0000-0000-000000000001';
  v_tenant constant uuid := '00000000-0000-0000-0000-00000000000a';
  v_type uuid;
  v_solo uuid;
  v_derby uuid;
  v_d date := (now() at time zone 'Europe/Prague')::date + 60;
  v_row record;
begin
  select id into v_type from priority_slot_types
    where tenant_id = v_tenant and is_match and builtin;

  insert into priority_slots
    (tenant_id, date, starts_at, ends_at, type_id, home_team, away_team,
     prep_minutes, description, is_away, created_by)
  values
    (v_tenant, v_d, '18:00', '20:00', v_type,
     'Cal Test Home', 'Cal Test Solo', 0, 'Test 0032 solo', false, v_uid)
  returning id into v_solo;

  insert into priority_slots
    (tenant_id, date, starts_at, ends_at, type_id, home_team, away_team,
     prep_minutes, description, is_away, created_by)
  values
    (v_tenant, v_d + 1, '18:00', '20:00', v_type,
     'Cal Test Rival', 'Cal Test Home', 0, 'Test 0032 derby', false, v_uid)
  returning id into v_derby;

  select * into v_row from my_future_matches(v_uid) where match_id = v_solo;
  if not found or v_row.calendar <> 'secondary' or v_row.color_id is distinct from 9 then
    raise exception 'FAIL: my_future_matches lost the followed team''s calendar/colour: %',
      to_jsonb(v_row);
  end if;

  select * into v_row from my_future_matches(v_uid) where match_id = v_derby;
  if not found or v_row.calendar <> 'primary' or v_row.color_id is distinct from 2 then
    raise exception 'FAIL: my_future_matches did not let the home team win the derby: %',
      to_jsonb(v_row);
  end if;
  raise notice 'OK: my_future_matches carries each match''s calendar and colour, home team wins a derby';
end $$;

-- match_calendar_followers: finds the follower through calendar_teams (not
-- the dead match_teams column), once per player even on a derby.
do $$
declare
  v_uid constant uuid := '10000000-0000-0000-0000-000000000001';
  v_tenant constant uuid := '00000000-0000-0000-0000-00000000000a';
  v_found uuid[];
begin
  select array_agg(u) into v_found
    from match_calendar_followers(v_tenant, 'Cal Test Home', 'Cal Test Solo') u;
  if v_found <> array[v_uid] then
    raise exception 'FAIL: match_calendar_followers missed a follower via calendar_teams: %', v_found;
  end if;

  select array_agg(u) into v_found
    from match_calendar_followers(v_tenant, 'Cal Test Rival', 'Cal Test Home') u;
  if v_found <> array[v_uid] then
    raise exception 'FAIL: match_calendar_followers duplicated a player following both derby teams: %', v_found;
  end if;

  if exists (select 1 from match_calendar_followers(
      v_tenant, 'Cal Test Nobody1', 'Cal Test Nobody2')) then
    raise exception 'FAIL: match_calendar_followers found a follower of unfollowed teams';
  end if;
  raise notice 'OK: calendar_teams routes matches per team, inside the checks';
end $$;

-- Training colour (0034): server-only, and only Google's eleven.
reset role;
do $$
declare
  v_uid constant uuid := '10000000-0000-0000-0000-000000000001';
begin
  if has_function_privilege('authenticated',
       'public.set_training_color_for(uuid, smallint)', 'execute')
     or has_function_privilege('anon',
       'public.set_training_color_for(uuid, smallint)', 'execute') then
    raise exception 'FAIL: a player may call set_training_color_for directly';
  end if;
  perform set_training_color_for(v_uid, 7::smallint);
  if (select training_color_id from google_calendar_links where user_id = v_uid) <> 7 then
    raise exception 'FAIL: the training colour did not stick';
  end if;
  perform set_training_color_for(v_uid, null);
  if (select training_color_id from google_calendar_links where user_id = v_uid) is not null then
    raise exception 'FAIL: clearing the training colour did not stick';
  end if;
  begin
    perform set_training_color_for(v_uid, 12::smallint);
    raise exception 'FAIL: a colour outside Google''s eleven was accepted';
  exception when sqlstate 'P0001' then
    if sqlerrm <> 'bad_color' then raise; end if;
  end;
  raise notice 'OK: the training colour is server-only and inside Google''s eleven';
end $$;

-- ---------------------------------------------------------------------------
-- Every table the Flutter app streams (`.stream(...)` in
-- lib/data/providers.dart) must be in the supabase_realtime publication, or
-- Realtime silently delivers nothing — no error, no event, just a screen
-- that never updates until the app restarts. `supabase db dump` does not
-- emit publications, so neither the schema snapshot nor a migration review
-- catches a missing one on its own (calendar_teams shipped without it,
-- fixed by 0035). Whenever a new table gains a `.stream()` provider, add its
-- name below too.
-- ---------------------------------------------------------------------------
reset role;
do $$
declare
  v_streamed text[] := array[
    'profiles', 'schedule_settings', 'clubs', 'time_blocks', 'app_config',
    'google_calendar_links', 'calendar_teams', 'team_colors', 'reservations',
    'day_overrides', 'priority_slot_types', 'priority_slots', 'rentals',
    'match_exceptions', 'player_group_members', 'duty_periods',
    'duty_assignments', 'messages', 'message_recipients',
    'league_matches', 'league_player_results'
  ];
  v_missing text[];
begin
  select coalesce(array_agg(t), '{}')
    into v_missing
    from unnest(v_streamed) as t
    where not exists (
      select 1 from pg_publication_tables pt
        where pt.pubname = 'supabase_realtime'
          and pt.schemaname = 'public'
          and pt.tablename = t
    );
  if array_length(v_missing, 1) > 0 then
    raise exception 'FAIL: streamed table(s) missing from supabase_realtime: %', v_missing;
  end if;
  raise notice 'OK: every streamed table is in the supabase_realtime publication';
end $$;

-- ---------------------------------------------------------------------------
-- team_colors (0036 creates it, 0037 makes it select-only): the colour used
-- to live on calendar_teams, so only a player with a linked calendar had
-- one, and it hung off the wrong team list (the calendar's, not
-- followed_teams which draws Můj přehled). Now it is its own table, keyed
-- the same way (user_id, team) but tied to neither list — and, like
-- calendar_teams (0035), select-only for the client (0037): every write
-- goes through calendar-manage/set_team_colors_for, which needs to save a
-- colour AND immediately repaint the affected future Google Calendar events
-- in the same request, same shape as set_training_color_for (0034). It
-- still joins the Realtime publication (checked above) so the stream sees
-- a colour change.
-- ---------------------------------------------------------------------------
reset role;
do $$
begin
  if not has_table_privilege('authenticated', 'public.team_colors', 'select') then
    raise exception 'FAIL: authenticated cannot read team_colors';
  end if;
  if has_table_privilege('authenticated', 'public.team_colors', 'insert')
     or has_table_privilege('authenticated', 'public.team_colors', 'update')
     or has_table_privilege('authenticated', 'public.team_colors', 'delete') then
    raise exception 'FAIL: team_colors is writable by authenticated directly';
  end if;
  if has_table_privilege('anon', 'public.team_colors', 'select') then
    raise exception 'FAIL: anon may read team_colors';
  end if;
  raise notice 'OK: team_colors is select-only for authenticated, anon has nothing';
end $$;

-- A foreign row to probe isolation against, and this player's own fixture
-- row — both inserted directly (server context): the client can no longer
-- write team_colors at all (0037), so seeding it the way a real write
-- happens now is set_team_colors_for's job further down, not a client
-- insert.
insert into team_colors (user_id, team, color_id) values
  ('10000000-0000-0000-0000-000000000002', 'Cizí barva', 6),
  ('10000000-0000-0000-0000-000000000001', 'Barva Home', 5);

set local role authenticated;
set local request.jwt.claims =
  '{"sub":"10000000-0000-0000-0000-000000000001","role":"authenticated"}';
do $$
declare
  v_uid constant uuid := '10000000-0000-0000-0000-000000000001';
  v_b constant uuid := '10000000-0000-0000-0000-000000000002';
begin
  if (select color_id from team_colors
      where user_id = v_uid and team = 'Barva Home') is distinct from 5 then
    raise exception 'FAIL: a player cannot read their own team_colors row';
  end if;

  if exists (select 1 from team_colors where user_id = v_b) then
    raise exception 'FAIL: a player sees another player''s team_colors row';
  end if;

  begin
    insert into team_colors (user_id, team, color_id) values (v_uid, 'Nová barva', 3);
    raise exception 'FAIL: a player inserted their own team_colors row directly';
  exception when insufficient_privilege then null;
  end;

  begin
    update team_colors set color_id = 1 where user_id = v_uid;
    raise exception 'FAIL: a player updated their own team_colors row directly';
  exception when insufficient_privilege then null;
  end;

  begin
    delete from team_colors where user_id = v_b;
    raise exception 'FAIL: a player deleted a foreign team_colors row';
  exception when insufficient_privilege then null;
  end;

  raise notice 'OK: team_colors is readable (own rows only) and not writable by the client';
end $$;

-- The table's own CHECK constraint still holds for whoever DOES write it —
-- the service role, via set_team_colors_for — now that the client path is
-- gone (0037).
reset role;
do $$
declare
  v_uid constant uuid := '10000000-0000-0000-0000-000000000001';
begin
  begin
    insert into team_colors (user_id, team, color_id) values (v_uid, 'Bad Colour Big', 12);
    raise exception 'FAIL: color_id 12 accepted';
  exception when check_violation then null;
  end;
  begin
    insert into team_colors (user_id, team, color_id) values (v_uid, 'Bad Colour Zero', 0);
    raise exception 'FAIL: color_id 0 accepted';
  exception when check_violation then null;
  end;
  raise notice 'OK: team_colors CHECK constraints still hold';
end $$;

-- set_team_colors_for: server-only, returns the previous state of exactly
-- the teams named (not the player's whole set — this call is a partial
-- upsert/delete, unlike set_calendar_teams_for's full replace), and a null
-- colour deletes that team's row rather than merely blanking it. A
-- repeated team name in one payload is de-duped in the statement itself
-- (0037) rather than trusting the caller — first occurrence wins.
reset role;
do $$
declare
  v_uid constant uuid := '10000000-0000-0000-0000-000000000001';
  v_previous jsonb;
begin
  if has_function_privilege('authenticated',
       'public.set_team_colors_for(uuid, jsonb)', 'execute')
     or has_function_privilege('anon',
       'public.set_team_colors_for(uuid, jsonb)', 'execute') then
    raise exception 'FAIL: a player may call set_team_colors_for directly';
  end if;
  if not has_function_privilege('service_role',
       'public.set_team_colors_for(uuid, jsonb)', 'execute') then
    raise exception 'FAIL: service_role lacks set_team_colors_for';
  end if;

  -- 'Barva Home' already sits at 5 (seeded above); 'Barva New' has no row.
  v_previous := set_team_colors_for(v_uid, jsonb_build_array(
    jsonb_build_object('team', 'Barva Home', 'color_id', 8),
    jsonb_build_object('team', 'Barva New', 'color_id', 7)));
  if v_previous <> jsonb_build_array(
       jsonb_build_object('team', 'Barva Home', 'color_id', 5)) then
    raise exception 'FAIL: set_team_colors_for did not return the previous state: %', v_previous;
  end if;
  if (select color_id from team_colors where user_id = v_uid and team = 'Barva Home')
       is distinct from 8
     or (select color_id from team_colors where user_id = v_uid and team = 'Barva New')
       is distinct from 7 then
    raise exception 'FAIL: set_team_colors_for did not store the new colours';
  end if;

  -- A null colour deletes the row outright rather than storing a null.
  perform set_team_colors_for(v_uid, jsonb_build_array(
    jsonb_build_object('team', 'Barva Home', 'color_id', null)));
  if exists (select 1 from team_colors where user_id = v_uid and team = 'Barva Home') then
    raise exception 'FAIL: a null colour did not delete the row';
  end if;

  -- A repeated team name used to make the insert's own ON CONFLICT raise
  -- "cannot affect row a second time" — the statement now de-dupes itself
  -- (0037); first occurrence, by original array position, wins.
  perform set_team_colors_for(v_uid, jsonb_build_array(
    jsonb_build_object('team', 'Barva Repeat', 'color_id', 3),
    jsonb_build_object('team', 'Barva Repeat', 'color_id', 4)));
  if (select color_id from team_colors where user_id = v_uid and team = 'Barva Repeat')
       is distinct from 3 then
    raise exception 'FAIL: a repeated team name in one payload was not de-duped (first occurrence wins)';
  end if;

  declare
    v_many jsonb;
  begin
    select jsonb_agg(jsonb_build_object('team', 'T' || g, 'color_id', 1))
      into v_many from generate_series(1, 41) g;
    begin
      perform set_team_colors_for(v_uid, v_many);
      raise exception 'FAIL: 41 team colours accepted';
    exception when others then
      if sqlerrm <> 'bad_colors' then raise; end if;
    end;
  end;

  raise notice 'OK: set_team_colors_for is server-only, returns exactly the previous state and a null colour deletes the row';
end $$;

-- ---------------------------------------------------------------------------
-- match_exceptions (0039): "I am playing this one." A B-team player turns
-- out for the A team once — that single match is theirs, in Můj přehled and
-- in the main Google calendar, without following the team and collecting
-- the rest of its season.
-- ---------------------------------------------------------------------------
reset role;

-- A match of two teams this player follows in neither list, plus a colour
-- for OUR side of it (the home team, since is_away is false) — the colour
-- an exception has to find, by the same rule matchColorOf follows in the app.
do $$
declare
  v_uid constant uuid := '10000000-0000-0000-0000-000000000001';
  v_tenant constant uuid := '00000000-0000-0000-0000-00000000000a';
  v_type uuid;
begin
  select id into v_type from priority_slot_types
    where tenant_id = v_tenant and is_match and builtin;
  insert into priority_slots
    (tenant_id, date, starts_at, ends_at, type_id, home_team, away_team,
     prep_minutes, description, is_away, created_by)
  values
    (v_tenant, (now() at time zone 'Europe/Prague')::date + 62,
     '10:00', '13:00', v_type,
     'Cal Test Guest A', 'Cal Test Guest B', 0, 'Test 0039 guest', false,
     v_uid);
  insert into team_colors (user_id, team, color_id)
  values (v_uid, 'Cal Test Guest A', 11);
end $$;

do $$
begin
  if has_table_privilege('authenticated', 'public.match_exceptions', 'select')
     is not true then
    raise exception 'FAIL: authenticated cannot read match_exceptions';
  end if;
  if has_table_privilege('authenticated', 'public.match_exceptions', 'insert')
     or has_table_privilege('authenticated', 'public.match_exceptions', 'update')
     or has_table_privilege('authenticated', 'public.match_exceptions', 'delete') then
    raise exception 'FAIL: the client can write match_exceptions directly';
  end if;
  if has_table_privilege('anon', 'public.match_exceptions', 'select') then
    raise exception 'FAIL: anon can read match_exceptions';
  end if;
  -- The RPC is the way in, and the job helper it leans on is not.
  if not has_function_privilege('authenticated',
       'set_match_exception(uuid, boolean)', 'execute') then
    raise exception 'FAIL: the app cannot call set_match_exception';
  end if;
  if has_function_privilege('authenticated',
       'enqueue_match_calendar_sync(uuid, uuid)', 'execute') then
    raise exception 'FAIL: the client can enqueue calendar jobs by hand';
  end if;
  raise notice 'OK: match_exceptions is select-only for the client, own rows only; set_match_exception is the way in (0039)';
end $$;

-- The app's half: turning an exception on and off. (my_future_matches is
-- server-only — the edge function reads it — so the routing it produces is
-- checked from server context below, each time as the calendar sync would.)
set local role authenticated;
set local request.jwt.claims =
  '{"sub":"10000000-0000-0000-0000-000000000001","role":"authenticated"}';
do $$
declare
  v_uid constant uuid := '10000000-0000-0000-0000-000000000001';
  v_guest uuid;
begin
  select id into v_guest from priority_slots
    where home_team = 'Cal Test Guest A' and away_team = 'Cal Test Guest B';
  perform set_match_exception(v_guest, true);
  if (select count(*) from match_exceptions
        where user_id = v_uid and match_id = v_guest) <> 1 then
    raise exception 'FAIL: set_match_exception did not add the row';
  end if;
  -- Saying it twice is saying it once.
  perform set_match_exception(v_guest, true);
  if (select count(*) from match_exceptions
        where user_id = v_uid and match_id = v_guest) <> 1 then
    raise exception 'FAIL: a repeated exception duplicated the row';
  end if;
  if (select calendar from match_exceptions
        where user_id = v_uid and match_id = v_guest) <> 'primary' then
    raise exception 'FAIL: an exception did not default to the main calendar';
  end if;
end $$;

reset role;
do $$
declare
  v_uid constant uuid := '10000000-0000-0000-0000-000000000001';
  v_row record;
begin
  select * into v_row from my_future_matches(v_uid)
    where home_team = 'Cal Test Guest A';
  if not found then
    raise exception 'FAIL: my_future_matches does not carry the exception';
  end if;
  if v_row.calendar <> 'primary' then
    raise exception 'FAIL: an exception did not land in the main calendar: %',
      v_row.calendar;
  end if;
  -- Neither of its teams is in any of the player's lists, so the colour can
  -- only have come from OUR side of the match — the same rule the app uses.
  if v_row.color_id is distinct from 11 then
    raise exception 'FAIL: the exception lost our team''s colour: %',
      v_row.color_id;
  end if;
end $$;

-- An exception outranks the team's own routing: Cal Test Home goes to the
-- second calendar, and an added match lands in the MAIN one — which is also
-- what keeps it out of both at once, since the sync writes to the target
-- and sweeps the same (deterministic) event id from the other calendar.
set local role authenticated;
set local request.jwt.claims =
  '{"sub":"10000000-0000-0000-0000-000000000001","role":"authenticated"}';
do $$
begin
  perform set_match_exception(
    (select id from priority_slots
       where home_team = 'Cal Test Home' and away_team = 'Cal Test Solo'),
    true);
end $$;
reset role;
do $$
declare
  v_row record;
begin
  select * into v_row from my_future_matches('10000000-0000-0000-0000-000000000001')
    where home_team = 'Cal Test Home' and away_team = 'Cal Test Solo';
  if v_row.calendar <> 'primary' then
    raise exception 'FAIL: the exception did not outrank the team''s calendar: %',
      v_row.calendar;
  end if;
end $$;

-- Switched off, both of them: the team gets its own calendar back, and the
-- match nobody's team plays drops out of the future altogether.
set local role authenticated;
set local request.jwt.claims =
  '{"sub":"10000000-0000-0000-0000-000000000001","role":"authenticated"}';
do $$
declare
  v_uid constant uuid := '10000000-0000-0000-0000-000000000001';
  v_guest uuid;
begin
  select id into v_guest from priority_slots where home_team = 'Cal Test Guest A';
  perform set_match_exception(
    (select id from priority_slots
       where home_team = 'Cal Test Home' and away_team = 'Cal Test Solo'),
    null);
  perform set_match_exception(v_guest, null);
  if exists (select 1 from match_exceptions
               where user_id = v_uid and match_id = v_guest) then
    raise exception 'FAIL: the exception survived being switched off';
  end if;
end $$;
reset role;
do $$
declare
  v_uid constant uuid := '10000000-0000-0000-0000-000000000001';
  v_row record;
begin
  select * into v_row from my_future_matches(v_uid)
    where home_team = 'Cal Test Home' and away_team = 'Cal Test Solo';
  if v_row.calendar <> 'secondary' then
    raise exception 'FAIL: dropping the exception did not give the team its calendar back: %',
      v_row.calendar;
  end if;
  if exists (select 1 from my_future_matches(v_uid)
               where home_team = 'Cal Test Guest A') then
    raise exception 'FAIL: the match stayed in the future after the exception went';
  end if;
end $$;

-- The other direction: a match a team DOES give the player, taken away.
-- Away next weekend, not interested — out of the overview and out of
-- Google, which the sync does by finding no row at all.
set local role authenticated;
set local request.jwt.claims =
  '{"sub":"10000000-0000-0000-0000-000000000001","role":"authenticated"}';
do $$
declare
  v_uid constant uuid := '10000000-0000-0000-0000-000000000001';
  v_solo uuid;
begin
  select id into v_solo from priority_slots
    where home_team = 'Cal Test Home' and away_team = 'Cal Test Solo';
  perform set_match_exception(v_solo, false);
  if (select shown from match_exceptions
        where user_id = v_uid and match_id = v_solo) is not false then
    raise exception 'FAIL: hiding a match did not store it as hidden';
  end if;
end $$;
reset role;
do $$
declare
  v_uid constant uuid := '10000000-0000-0000-0000-000000000001';
begin
  if exists (select 1 from my_future_matches(v_uid)
               where home_team = 'Cal Test Home' and away_team = 'Cal Test Solo') then
    raise exception 'FAIL: a hidden match stayed in the player''s future';
  end if;
end $$;

-- And handed back to the teams: no row, no opinion — the team decides
-- again, in the calendar it always did.
set local role authenticated;
set local request.jwt.claims =
  '{"sub":"10000000-0000-0000-0000-000000000001","role":"authenticated"}';
do $$
declare
  v_uid constant uuid := '10000000-0000-0000-0000-000000000001';
  v_solo uuid;
begin
  select id into v_solo from priority_slots
    where home_team = 'Cal Test Home' and away_team = 'Cal Test Solo';
  perform set_match_exception(v_solo, null);
  if exists (select 1 from match_exceptions
               where user_id = v_uid and match_id = v_solo) then
    raise exception 'FAIL: clearing an exception left the row behind';
  end if;
end $$;
reset role;
do $$
declare
  v_row record;
begin
  select * into v_row from my_future_matches('10000000-0000-0000-0000-000000000001')
    where home_team = 'Cal Test Home' and away_team = 'Cal Test Solo';
  if not found or v_row.calendar <> 'secondary' then
    raise exception 'FAIL: the team did not get its match back: %', to_jsonb(v_row);
  end if;
  raise notice 'OK: an exception hides a team''s match too, and clearing it hands the match back to the team (0039)';
end $$;

-- A match that is not this alley's, not a match at all, or already over.
set local role authenticated;
set local request.jwt.claims =
  '{"sub":"10000000-0000-0000-0000-000000000001","role":"authenticated"}';
do $$
declare
  v_child uuid;
begin
  begin
    perform set_match_exception(gen_random_uuid(), true);
    raise exception 'FAIL: an unknown match was accepted';
  exception when others then
    if sqlerrm <> 'unknown_match' then raise; end if;
  end;
  begin
    perform set_match_exception(
      (select id from priority_slots
         where tenant_id = '00000000-0000-0000-0000-00000000000b' limit 1),
      true);
    raise exception 'FAIL: another alley''s match was accepted';
  exception when others then
    if sqlerrm <> 'unknown_match' then raise; end if;
  end;
  select id into v_child from priority_slots where parent_id is not null limit 1;
  if v_child is not null then
    begin
      perform set_match_exception(v_child, true);
      raise exception 'FAIL: an úklid child was accepted as a match';
    exception when others then
      if sqlerrm <> 'unknown_match' then raise; end if;
    end;
  end if;
  raise notice 'OK: set_match_exception adds a match of nobody''s team, routes it to the main calendar and outranks the team''s own (0039)';
end $$;

-- Yesterday's match is not something one is about to play.
reset role;
do $$
declare
  v_tenant constant uuid := '00000000-0000-0000-0000-00000000000a';
  v_type uuid;
begin
  select id into v_type from priority_slot_types
    where tenant_id = v_tenant and is_match and builtin;
  insert into priority_slots
    (tenant_id, date, starts_at, ends_at, type_id, home_team, away_team,
     prep_minutes, description, is_away, created_by)
  values
    (v_tenant, (now() at time zone 'Europe/Prague')::date - 1,
     '10:00', '13:00', v_type, 'Cal Test Past A', 'Cal Test Past B', 0,
     'Test 0039 past', false, '10000000-0000-0000-0000-000000000001');
end $$;
set local role authenticated;
set local request.jwt.claims =
  '{"sub":"10000000-0000-0000-0000-000000000001","role":"authenticated"}';
do $$
begin
  begin
    perform set_match_exception(
      (select id from priority_slots where home_team = 'Cal Test Past A'), true);
    raise exception 'FAIL: a match that is already over was accepted';
  exception when others then
    if sqlerrm <> 'match_past' then raise; end if;
  end;
  raise notice 'OK: an exception cannot be set on a match that is already over (0039)';
end $$;

-- The kiosk is the alley's tablet: it plays nothing.
set local request.jwt.claims =
  '{"sub":"10000000-0000-0000-0000-000000000006","role":"authenticated"}';
do $$
begin
  begin
    perform set_match_exception(
      (select id from priority_slots where home_team = 'Cal Test Guest A'), true);
    raise exception 'FAIL: the kiosk claimed a match';
  exception when others then
    if sqlerrm <> 'not_allowed' then raise; end if;
  end;
  raise notice 'OK: the kiosk cannot claim a match (0039)';
end $$;

-- An exception is a calendar change like any other: switched on, the match
-- re-timed under it, or gone with the match itself.
reset role;
delete from notification_jobs;
set local role authenticated;
set local request.jwt.claims =
  '{"sub":"10000000-0000-0000-0000-000000000001","role":"authenticated"}';
do $$
begin
  perform set_match_exception(
    (select id from priority_slots where home_team = 'Cal Test Guest A'), true);
end $$;

-- notification_jobs is the server's own table (0023), so the queue is read
-- from server context — which is also who reads it for real.
reset role;
do $$
declare
  v_uid constant uuid := '10000000-0000-0000-0000-000000000001';
  v_guest uuid;
begin
  select id into v_guest from priority_slots where home_team = 'Cal Test Guest A';
  if not exists (select 1 from notification_jobs
                   where dedupe_key = 'calendar:' || v_uid || ':match:' || v_guest) then
    raise exception 'FAIL: switching an exception on queued no calendar job';
  end if;

  -- The match moves: its teams have no followers at all, so only the
  -- exception can carry the news.
  delete from notification_jobs;
  update priority_slots set starts_at = '11:00' where id = v_guest;
  if not exists (select 1 from notification_jobs
                   where dedupe_key = 'calendar:' || v_uid || ':match:' || v_guest) then
    raise exception 'FAIL: a re-timed match did not reach the player playing it';
  end if;

  -- The match is called off: the row goes with it, and the job that tells
  -- Google to drop the event goes out.
  delete from notification_jobs;
  delete from priority_slots where id = v_guest;
  if exists (select 1 from match_exceptions where match_id = v_guest) then
    raise exception 'FAIL: the exception outlived its match';
  end if;
  if not exists (select 1 from notification_jobs
                   where dedupe_key = 'calendar:' || v_uid || ':match:' || v_guest) then
    raise exception 'FAIL: a deleted match left its event in the calendar';
  end if;
  raise notice 'OK: an exception rides the calendar jobs — on, re-timed, and gone with its match (0039)';
end $$;

-- ---------------------------------------------------------------------------
-- Připomínky před tréninkem a zápasem (0040): kdo má propojený Google, dostane
-- upozornění od něj — kdo ne, neměl dosud nic. Stejné předstihy, stejný kanál
-- jako u ostatních zpráv (push, kdo má appku; jinak e-mail).
-- ---------------------------------------------------------------------------
reset role;
do $$
declare
  v_uid constant uuid := '10000000-0000-0000-0000-000000000001';
  v_tenant constant uuid := '00000000-0000-0000-0000-00000000000a';
  v_block uuid;
  v_type uuid;
  -- Derived from the timestamps, never from "today plus a time": this suite
  -- runs in CI at any hour, and two hours from 23:30 is tomorrow.
  v_train timestamp := (now() at time zone 'Europe/Prague') + interval '2 hours';
  v_match timestamp := (now() at time zone 'Europe/Prague') + interval '3 hours';
  -- ...and they have to END on the day they start: both tables store a date
  -- plus two times and check ends_at > starts_at, so nothing here may cross
  -- midnight. Full length while the day has room, otherwise halfway to it —
  -- the suite cares when these start, never when they end.
  v_train_end timestamp := v_train + least(interval '1 hour',
    (date_trunc('day', v_train) + interval '1 day' - v_train) / 2);
  v_match_end timestamp := v_match + least(interval '3 hours',
    (date_trunc('day', v_match) + interval '1 day' - v_match) / 2);
begin
  -- The team whose matches count as this player's — Můj přehled reads
  -- followed_teams, and so do the reminders.
  update profiles set followed_teams = array['Rem Test Home'] where id = v_uid;

  -- A training that starts in two hours, and a match in three.
  select id into v_block from time_blocks
    where tenant_id = v_tenant and active limit 1;
  update time_blocks set starts_at = v_train::time,
         ends_at = v_train_end::time
   where id = v_block;
  insert into reservations
    (tenant_id, player_id, date, block_id, lane, created_via, created_by)
  values (v_tenant, v_uid, v_train::date, v_block, 3, 'app', v_uid);

  select id into v_type from priority_slot_types
    where tenant_id = v_tenant and is_match and builtin;
  insert into priority_slots
    (tenant_id, date, starts_at, ends_at, type_id, home_team, away_team,
     prep_minutes, description, is_away, created_by)
  values
    (v_tenant, v_match::date, v_match::time,
     v_match_end::time,
     v_type, 'Rem Test Home', 'Rem Test Away', 0, '', false, v_uid);
end $$;

-- Nothing is set up yet, so nothing is due — whatever the schedule says.
do $$
begin
  if exists (select 1 from due_reminders()
               where user_id = '10000000-0000-0000-0000-000000000001') then
    raise exception 'FAIL: a reminder was due for a player who asked for none';
  end if;
end $$;

-- The player's own row, written from the app like every other preference.
set local role authenticated;
set local request.jwt.claims =
  '{"sub":"10000000-0000-0000-0000-000000000001","role":"authenticated"}';
do $$
declare
  v_uid constant uuid := '10000000-0000-0000-0000-000000000001';
begin
  update profiles set notify_before_minutes = array[180, 60] where id = v_uid;
  if (select notify_before_minutes from profiles where id = v_uid)
     <> array[180, 60] then
    raise exception 'FAIL: the player could not set their own reminders';
  end if;
  -- Somebody else's row stays out of reach (profiles_update_own).
  update profiles set notify_before_minutes = array[10]
   where id = '10000000-0000-0000-0000-000000000002';
  if (select notify_before_minutes from profiles
        where id = '10000000-0000-0000-0000-000000000002') <> '{}' then
    raise exception 'FAIL: a player set somebody else''s reminders';
  end if;
  -- The bounds hold.
  begin
    update profiles set notify_before_minutes = array[50000] where id = v_uid;
    raise exception 'FAIL: a reminder further ahead than four weeks was taken';
  exception when check_violation then null;
  end;
  begin
    update profiles set notify_before_minutes = array[-1] where id = v_uid;
    raise exception 'FAIL: a negative lead time was taken';
  exception when check_violation then null;
  end;
  begin
    update profiles set notify_before_minutes = array[1, 2, 3, 4, 5, 6]
     where id = v_uid;
    raise exception 'FAIL: a sixth reminder was taken';
  exception when check_violation then null;
  end;
  raise notice 'OK: reminders are the player''s own preference, inside the checks (0040)';
end $$;

reset role;
do $$
declare
  v_uid constant uuid := '10000000-0000-0000-0000-000000000001';
  v_rows record;
  v_count int;
  v_before integer[];
begin
  -- 3 h before a training that starts in 2 h: due, and so is the match's
  -- 3 h reminder (it starts in 3 h). The 1 h ones are not — their moment
  -- has not come.
  select count(*) into v_count from due_reminders() where user_id = v_uid;
  if v_count <> 2 then
    raise exception 'FAIL: expected the two 3-hour reminders, got %', v_count;
  end if;
  if not exists (select 1 from due_reminders()
                   where user_id = v_uid and kind = 'training'
                     and offset_minutes = 180) then
    raise exception 'FAIL: the training reminder is not due';
  end if;
  if not exists (select 1 from due_reminders()
                   where user_id = v_uid and kind = 'match'
                     and offset_minutes = 180 and home_team = 'Rem Test Home') then
    raise exception 'FAIL: the match of a followed team is not due';
  end if;
  if exists (select 1 from due_reminders()
               where user_id = v_uid and offset_minutes = 60) then
    raise exception 'FAIL: an hour-before reminder rang three hours early';
  end if;

  -- Everyone is reachable: a player without the app has an e-mail, and the
  -- channel is notify's business, not this function's.
  select * into v_rows from due_reminders() where user_id = v_uid limit 1;
  if v_rows.email is null or v_rows.email = '' then
    raise exception 'FAIL: due_reminders dropped the e-mail fallback';
  end if;

  -- Sent once, never again.
  perform mark_reminder_sent(v_uid, r.event_key, r.offset_minutes, r.starts_at)
    from due_reminders() r where r.user_id = v_uid;
  if exists (select 1 from due_reminders() where user_id = v_uid) then
    raise exception 'FAIL: a reminder rang twice';
  end if;

  -- A longer lead time added after a closer one went out does not ring on
  -- its own afterwards: the event was already announced (0049).
  select notify_before_minutes into v_before from profiles where id = v_uid;
  update profiles set notify_before_minutes = v_before || 240 where id = v_uid;
  if exists (select 1 from due_reminders() where user_id = v_uid) then
    raise exception 'FAIL: a longer lead time added later rang after a closer one';
  end if;
  -- A closer one still rings after a longer one went out (the day-before
  -- reminder, then the two-hours-before one).
  delete from reminders_sent where user_id = v_uid;
  perform mark_reminder_sent(v_uid, r.event_key, 240, r.starts_at)
    from due_reminders() r where r.user_id = v_uid and r.offset_minutes = 240;
  if (select count(*) from due_reminders()
        where user_id = v_uid and offset_minutes = 180) <> 2
     or exists (select 1 from due_reminders()
                  where user_id = v_uid and offset_minutes = 240) then
    raise exception 'FAIL: a longer lead time sent first silenced the closer one, or rang again';
  end if;
  update profiles set notify_before_minutes = v_before where id = v_uid;
  perform mark_reminder_sent(v_uid, r.event_key, r.offset_minutes, r.starts_at)
    from due_reminders() r where r.user_id = v_uid;

  -- A receipt is for the start it was sent for (0049): it keeps that start…
  if exists (select 1 from reminders_sent s
               where s.user_id = v_uid and s.offset_minutes = 180
                 and s.starts_at is null) then
    raise exception 'FAIL: mark_reminder_sent dropped the start';
  end if;
  -- …so an event moved since rings again at its new time…
  update reminders_sent set starts_at = starts_at - interval '1 day'
   where user_id = v_uid;
  if (select count(*) from due_reminders()
        where user_id = v_uid and offset_minutes = 180) <> 2 then
    raise exception 'FAIL: a moved event did not ring again at its new time';
  end if;
  -- …and marking it again records the new start.
  perform mark_reminder_sent(v_uid, r.event_key, r.offset_minutes, r.starts_at)
    from due_reminders() r where r.user_id = v_uid;
  if exists (select 1 from due_reminders() where user_id = v_uid) then
    raise exception 'FAIL: a moved event rang twice at its new time';
  end if;
  -- A receipt from before 0049 has no start and still counts for any, so
  -- the deploy does not ring everything again; so does an old-style call.
  update reminders_sent set starts_at = null where user_id = v_uid;
  if exists (select 1 from due_reminders() where user_id = v_uid) then
    raise exception 'FAIL: a receipt without a start stopped counting';
  end if;
  perform mark_reminder_sent(p_user => v_uid, p_event_key => 'r:none',
                             p_offset => 60);
  raise notice 'OK: a reminder is due at its lead time, once, for the player''s own trainings and matches (0040); a closer one sent covers the longer ones, and a moved event rings again (0049)';
end $$;

-- A match nobody's team plays is nobody's reminder; an exception makes it
-- theirs, and hiding one takes it away (0039 all the way through).
do $$
declare
  v_uid constant uuid := '10000000-0000-0000-0000-000000000001';
  v_tenant constant uuid := '00000000-0000-0000-0000-00000000000a';
  v_type uuid;
  v_guest uuid;
  v_own uuid;
  v_match timestamp := (now() at time zone 'Europe/Prague') + interval '3 hours';
  -- Same day, same reason as the fixture above.
  v_match_end timestamp := v_match + least(interval '3 hours',
    (date_trunc('day', v_match) + interval '1 day' - v_match) / 2);
begin
  select id into v_type from priority_slot_types
    where tenant_id = v_tenant and is_match and builtin;
  insert into priority_slots
    (tenant_id, date, starts_at, ends_at, type_id, home_team, away_team,
     prep_minutes, description, is_away, created_by)
  values
    (v_tenant, v_match::date, v_match::time,
     v_match_end::time,
     v_type, 'Rem Guest A', 'Rem Guest B', 0, '', false, v_uid)
  returning id into v_guest;
  select id into v_own from priority_slots where home_team = 'Rem Test Home';

  if exists (select 1 from due_reminders()
               where user_id = v_uid and event_key = 'm:' || v_guest) then
    raise exception 'FAIL: a match of nobody''s team was reminded about';
  end if;

  insert into match_exceptions (user_id, match_id, shown)
  values (v_uid, v_guest, true);
  if not exists (select 1 from due_reminders()
                   where user_id = v_uid and event_key = 'm:' || v_guest) then
    raise exception 'FAIL: an added match is not worth a reminder';
  end if;

  insert into match_exceptions (user_id, match_id, shown)
  values (v_uid, v_own, false);
  if exists (select 1 from due_reminders()
               where user_id = v_uid and event_key = 'm:' || v_own
                 and offset_minutes = 60) then
    raise exception 'FAIL: a hidden match still rings';
  end if;
  raise notice 'OK: reminders follow Můj přehled — a team''s matches, plus what the player added, minus what they hid (0040)';
end $$;

-- The minutely tick knows about reminders: without them in its condition it
-- would stay silent, because the job queue is empty.
do $$
declare
  v_uid constant uuid := '10000000-0000-0000-0000-000000000001';
begin
  delete from notification_jobs;
  delete from reminders_sent;
  if not exists (select 1 from due_reminders()) then
    raise exception 'FAIL: the fixtures stopped being due';
  end if;
  -- The gate the tick reads, asked directly: with no Vault configured the
  -- post never happens, so calling the tick proves nothing either way.
  if not notifications_due() then
    raise exception 'FAIL: the tick would sleep through a due reminder';
  end if;
  -- And it still tolerates an unset Vault, as 0023 promised.
  perform trigger_notification_jobs();
  raise notice 'OK: the minutely tick fires for a due reminder, not only for a queued job (0040)';
end $$;

-- The ledger is the server's alone.
do $$
begin
  if has_table_privilege('authenticated', 'public.reminders_sent', 'select')
     or has_table_privilege('anon', 'public.reminders_sent', 'select') then
    raise exception 'FAIL: the client can read reminders_sent';
  end if;
  if has_function_privilege('authenticated', 'due_reminders()', 'execute')
     or has_function_privilege('authenticated',
          'mark_reminder_sent(uuid, text, integer, timestamptz)', 'execute') then
    raise exception 'FAIL: the client can drive the reminder machinery';
  end if;
  if to_regprocedure('public.mark_reminder_sent(uuid, text, integer)') is not null
     or not has_function_privilege('service_role',
          'mark_reminder_sent(uuid, text, integer, timestamptz)', 'execute') then
    raise exception 'FAIL: notify cannot mark a reminder, or the old signature is still there';
  end if;
  raise notice 'OK: the reminder ledger and its functions are server-only (0040)';
end $$;

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

  -- 4b) a hand-picked colour (0x1000000|rgb) fits the group column too — it is
  -- the same domain as rentals.color, which is where the group copies it and
  -- where rental_add_date copies it back from.
  update rental_groups set color = 29392896 where id = v_g;
  select color into v_color from rentals where id = v_r1;
  if v_color <> 29392896 then
    raise exception 'FAIL: a hand-picked group colour did not reach its dates';
  end if;
  update rental_groups set color = 7 where id = v_g;

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

-- The other tenant's rental is a stranger too: the RPC is security definer, so
-- its tenant filter is the only boundary there is.
do $$
declare
  v_uid constant uuid := '10000000-0000-0000-0000-000000000001';
  v_lone uuid;
begin
  insert into rentals (renter_name, lanes, date, starts_at, ends_at, created_by)
  values ('Firma X', '{1}', (now() at time zone 'Europe/Prague')::date + 200,
          '20:00', '21:00', v_uid)
  returning id into v_lone;
  perform set_config('probe.rental_a', v_lone::text, true);
end $$;
set local request.jwt.claims =
  '{"sub":"10000000-0000-0000-0000-000000000002","role":"authenticated"}';
do $$
begin
  begin
    perform rental_add_date(current_setting('probe.rental_a')::uuid,
      (now() at time zone 'Europe/Prague')::date + 203, '19:00', '20:00', '{2}');
    raise exception 'FAIL: admin B added a date to tenant A''s rental';
  exception when others then
    if sqlerrm <> 'unknown_rental' then raise; end if;
  end;
end $$;
set local request.jwt.claims =
  '{"sub":"10000000-0000-0000-0000-000000000001","role":"authenticated"}';
do $$
begin
  if (select count(*) from rentals where renter_name = 'Firma X') <> 1 then
    raise exception 'FAIL: the foreign call wrote a date into tenant A';
  end if;
  if exists (select 1 from rental_groups where renter_name = 'Firma X') then
    raise exception 'FAIL: the foreign call created a group in tenant A';
  end if;
  raise notice 'OK: rental_add_date refuses another tenant''s rental (0041)';
end $$;

-- The write policies themselves: rental_groups insert/update/delete all
-- carry is_admin(), and nothing so far has falsified that half — every
-- write above was an admin's. Player C of tenant A is the counter-example:
-- approved (the merge further up approved them), so the select policy
-- (is_approved_or_kiosk(), the same as rentals) lets them READ the groups —
-- which is the point: they are genuinely inside the tenant and genuinely
-- reach the table, so the three refusals below are the is_admin() checks
-- doing their job, not a session that was never authenticated.
do $$
declare
  v_g uuid;
begin
  insert into rental_groups (renter_name, color, created_by)
  values ('Firma P', 6, '10000000-0000-0000-0000-000000000001')
  returning id into v_g;
  perform set_config('probe.group_a', v_g::text, true);
end $$;
set local request.jwt.claims =
  '{"sub":"10000000-0000-0000-0000-000000000003","role":"authenticated"}';
do $$
declare
  v_g constant uuid := current_setting('probe.group_a')::uuid;
  v_rows integer;
begin
  if not exists (select 1 from rental_groups where id = v_g) then
    raise exception 'FAIL: an approved player of the tenant cannot read its groups';
  end if;
  if exists (select 1 from rental_groups
             where id = '30000000-0000-0000-0000-000000000001') then
    raise exception 'FAIL: a player reads the other tenant''s group';
  end if;
  begin
    insert into rental_groups (renter_name, created_by)
    values ('Firma Č', '10000000-0000-0000-0000-000000000003');
    raise exception 'FAIL: a non-admin created a rental group';
  exception when insufficient_privilege then null;
  end;
  -- update/delete do not raise under RLS: the rows simply are not there.
  update rental_groups set renter_name = 'Přejmenováno' where id = v_g;
  get diagnostics v_rows = row_count;
  if v_rows <> 0 then
    raise exception 'FAIL: a non-admin updated a rental group';
  end if;
  delete from rental_groups where id = v_g;
  get diagnostics v_rows = row_count;
  if v_rows <> 0 then
    raise exception 'FAIL: a non-admin deleted a rental group';
  end if;
end $$;
set local request.jwt.claims =
  '{"sub":"10000000-0000-0000-0000-000000000001","role":"authenticated"}';
do $$
begin
  -- And from the admin's side: the group is still there, still itself.
  if (select renter_name from rental_groups
      where id = current_setting('probe.group_a')::uuid)
     is distinct from 'Firma P' then
    raise exception 'FAIL: the non-admin write reached the group after all';
  end if;
  if exists (select 1 from rental_groups where renter_name = 'Firma Č') then
    raise exception 'FAIL: the non-admin insert landed in tenant A';
  end if;
  raise notice 'OK: rental_groups writes are admin-only — a non-admin who CAN read them changes nothing (0041)';
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
  if not has_function_privilege('authenticated',
       'rental_add_date(uuid, date, time, time, smallint[], text)', 'execute') then
    raise exception 'FAIL: the app cannot call rental_add_date';
  end if;
  if has_function_privilege('anon',
       'rental_add_date(uuid, date, time, time, smallint[], text)', 'execute') then
    raise exception 'FAIL: anon can call rental_add_date';
  end if;
  raise notice 'OK: rental_groups is full DML for the app, RLS decides, anon nothing (0041)';
end $$;

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
  -- A day_overrides row, so the public_week key-set guard below has a first
  -- element to check on the 'overrides' list too. Inserted BEFORE the
  -- reservations below: the insert cascades (override_changed ->
  -- cascade_schedule_change) and re-sweeps every future reservation of the
  -- WHOLE tenant, not just this override's own date — done here, before any
  -- reservation exists, it has nothing to cancel.
  insert into day_overrides (tenant_id, date, closed, reason, created_by)
  values (v_a, v_monday + 6, true, 'test override', v_uid);
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
  -- A weekly (weekday-based) rental, open-ended, so it always covers the
  -- test week — exercises public_week's OTHER rentals arm (weekday is not
  -- null) alongside the one-time rental above.
  insert into rentals
    (tenant_id, renter_name, note, lanes, weekday, starts_at, ends_at, created_by)
  values (v_a, 'Firma Série', 'series poznámka', '{2}', 3, '05:00', '05:30', v_uid);
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
    perform set_public_overview('a', false);
    raise exception 'FAIL: a 1-character slug was accepted';
  exception when others then
    if sqlerrm <> 'invalid_slug' then raise; end if;
  end;
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

-- Anon: an enabled slug on a not-yet-approved tenant is unknown_tenant too
-- (tenant B is still 'pending' — nobody approved it in this suite).
reset role;
set local role authenticated;
set local request.jwt.claims =
  '{"sub":"10000000-0000-0000-0000-000000000002","role":"authenticated"}';
select set_public_overview('kuzelna-b', true);
reset role;
set local role anon;
set local request.jwt.claims = '{"role":"anon"}';
do $$
begin
  begin
    perform public_week('kuzelna-b', current_date);
    raise exception 'FAIL: an enabled slug on a pending tenant answered';
  exception when others then
    if sqlerrm <> 'unknown_tenant' then raise; end if;
  end;
  raise notice 'OK: an enabled slug on a non-approved tenant also gives unknown_tenant (0043)';
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
  -- The weekly (weekday-based) rental appears too, masked the same way as
  -- the one-time one — public_week's OTHER rentals arm (weekday is not
  -- null). Matched on weekday/lanes/times rather than a bare count: tenant
  -- A already carries weekly rentals from earlier sections of this suite.
  if not v->'rentals' @> jsonb_build_array(jsonb_build_object(
       'weekday', 3, 'lanes', jsonb_build_array(2),
       'starts_at', '05:00:00', 'ends_at', '05:30:00',
       'renter_name', '', 'note', '')) then
    raise exception 'FAIL: the weekly rental is missing or not masked like the one-time one: %', v->'rentals';
  end if;
  if v::text like '%10000000-0000-0000-0000-000000000001%'
     or v::text like '%Hráč A%'
     or v::text like '%Firma Tajná%'
     or v::text like '%tajná poznámka%'
     or v::text like '%Firma Série%'
     or v::text like '%series poznámka%'
     or v::text like '%00000000-0000-0000-0000-00000000000a%'
     or v::text like '%Kuželna B%' then
    raise exception 'FAIL: public_week leaks a name, an id or another tenant: %', v;
  end if;
  raise notice 'OK: public_week shows occupancy in club colours and the matches, never a name (0043)';
end $$;

-- Key-set guard: public_week masks sensitive columns with
-- to_jsonb(row) - 'col1' - 'col2' ... — correct today, but with no tripwire
-- of its own. A new column added later to rentals, priority_slots,
-- overrides, blocks, priority_slot_types or schedule_settings would
-- silently reach anon (the Dart client ignores unknown JSON keys, and the
-- block above only greps for specific fixture strings, not the full key
-- set). Assert the EXACT keys of each list, so a schema change here fails
-- loudly instead of leaking quietly.
do $$
declare
  v_monday constant date := current_setting('probe.pub_monday')::date;
  v jsonb;
  v_keys text[];
begin
  v := public_week('kuzelna-a', v_monday);

  v_keys := array(select jsonb_object_keys(v->'settings') order by 1);
  if v_keys <> array['booking_horizon_days', 'kiosk_dark', 'kiosk_fit_day',
                      'lane_count', 'max_active_reservations', 'training_weekdays'] then
    raise exception 'FAIL: public_week''s settings keys changed — a new column may be reaching anon: %', v_keys;
  end if;

  v_keys := array(select jsonb_object_keys(v->'blocks'->0) order by 1);
  if v_keys <> array['active', 'ends_at', 'id', 'position', 'starts_at'] then
    raise exception 'FAIL: public_week''s blocks keys changed — a new column may be reaching anon: %', v_keys;
  end if;

  v_keys := array(select jsonb_object_keys(v->'slot_types'->0) order by 1);
  if v_keys <> array['builtin', 'color', 'id', 'is_match', 'lanes', 'name'] then
    raise exception 'FAIL: public_week''s slot_types keys changed — a new column may be reaching anon: %', v_keys;
  end if;

  v_keys := array(select jsonb_object_keys(v->'overrides'->0) order by 1);
  if v_keys <> array['block_ids', 'closed', 'date', 'reason'] then
    raise exception 'FAIL: public_week''s overrides keys changed — a new column may be reaching anon: %', v_keys;
  end if;

  v_keys := array(select jsonb_object_keys(v->'priority_slots'->0) order by 1);
  if v_keys <> array['away_team', 'away_team_slug', 'competition', 'date', 'description',
                      'ends_at', 'hand_edited', 'home_team', 'home_team_slug', 'id',
                      'import_key', 'is_away', 'parent_id', 'prep_minutes', 'round',
                      'site_match_id', 'site_slug', 'starts_at', 'type_id', 'venue',
                      'venue_slug', 'video_url'] then
    raise exception 'FAIL: public_week''s priority_slots keys changed — a new column may be reaching anon: %', v_keys;
  end if;

  v_keys := array(select jsonb_object_keys(v->'rentals'->0) order by 1);
  if v_keys <> array['color', 'date', 'ends_at', 'group_id', 'id', 'lanes', 'note',
                      'parent_id', 'renter_name', 'skipped', 'starts_at',
                      'valid_from', 'valid_until', 'weekday'] then
    raise exception 'FAIL: public_week''s rentals keys changed — a new column may be reaching anon: %', v_keys;
  end if;

  v_keys := array(select jsonb_object_keys(v->'occupied'->0) order by 1);
  if v_keys <> array['block_id', 'club_color', 'date', 'lane'] then
    raise exception 'FAIL: public_week''s occupied keys changed — a new column may be reaching anon: %', v_keys;
  end if;

  raise notice 'OK: public_week''s key sets are exactly what''s expected — a new column on any masked table would trip this (0043)';
end $$;

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

-- group_cancel_invite requires membership in THAT group: Jana (still in
-- Petr's group at this point) may not withdraw Karel's pending invite to
-- Lenka, even though she is in a group of her own.
reset role;
do $$
declare
  v_karel_group uuid;
begin
  select group_id into v_karel_group from player_group_members
   where user_id = '20000000-0000-0000-0000-000000000003' and status = 'member';
  perform set_config('probe.grp_karel', v_karel_group::text, true);
end $$;
set local role authenticated;
set local request.jwt.claims =
  '{"sub":"20000000-0000-0000-0000-000000000002","role":"authenticated"}';
do $$
begin
  begin
    perform group_cancel_invite(current_setting('probe.grp_karel')::uuid,
      '20000000-0000-0000-0000-000000000004');
    raise exception 'FAIL: an outsider withdrew another group''s invite';
  exception when others then
    if sqlerrm <> 'not_allowed' then raise; end if;
  end;
end $$;
reset role;
do $$
begin
  if not exists (select 1 from player_group_members
                 where group_id = current_setting('probe.grp_karel')::uuid
                   and user_id = '20000000-0000-0000-0000-000000000004'
                   and status = 'invited') then
    raise exception 'FAIL: the refused cancel still removed Karel''s invite to Lenka';
  end if;
  raise notice 'OK: group_cancel_invite refuses a non-member with not_allowed, invite untouched (0044)';
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

-- 0045 výsledkový servis ČKA ------------------------------------------------
reset role;
-- The nightly producer walks every enabled alley, so one already syncing in
-- this database (a dev DB, prod inside BEGIN…ROLLBACK) would add its jobs to
-- the counts below.
update federation_sync set enabled = false
 where tenant_id not in ('00000000-0000-0000-0000-00000000000a',
                         '00000000-0000-0000-0000-000000000002');
-- One match of the site's schedule as the edge function hands it over.
-- The team slugs are optional: most sections store matches without them.
create function pg_temp.fed_match(
  p_id integer, p_ours boolean, p_days integer, p_start text, p_end text,
  p_round integer, p_legacy uuid default null,
  p_home_slug text default null, p_away_slug text default null)
returns jsonb language sql as $$
  select jsonb_build_object(
    'site_match_id', p_id,
    'site_slug', 'jihomoravska-divize-2026-2027-kolo-' || p_round || '-x-y',
    'date', ((now() at time zone 'Europe/Prague')::date + p_days)::text,
    'starts_at', p_start, 'ends_at', p_end,
    'home', case when p_ours then 'TJ Sokol Brno IV' else 'KK Jiný' end,
    'away', case when p_ours then 'KK Jiný' else 'TJ Sokol Brno IV' end,
    'home_is_ours', p_ours, 'prep', 30,
    'competition', 'Jihomoravská divize', 'round', p_round,
    'video_url', null, 'legacy_id', p_legacy,
    'home_slug', p_home_slug, 'away_slug', p_away_slug)
$$;

-- 1. A new competition's matches arrive as priority_slots.
do $$
declare
  v_a constant uuid := '00000000-0000-0000-0000-00000000000a';
  r jsonb;
  s priority_slots;
begin
  insert into federation_sync (tenant_id, venue_slug, enabled)
  values (v_a, 'tj-sokol-brno-iv', true);
  r := apply_federation_matches(v_a, 'jihomoravska-divize-2026-2027', jsonb_build_array(
         pg_temp.fed_match(101, true, 10, '17:00', '20:00', 5),
         pg_temp.fed_match(102, false, 17, '10:00', '13:00', 6)));
  if (r->>'inserted')::int <> 2 or (r->>'updated')::int <> 0
     or (r->>'deleted')::int <> 0 or (r->>'rekeyed')::int <> 0 then
    raise exception 'FAIL: first apply_federation_matches report: %', r;
  end if;
  if (select count(*) from priority_slots
      where tenant_id = v_a and import_key in ('cka:101', 'cka:102')) <> 2 then
    raise exception 'FAIL: the two federation matches were not inserted';
  end if;
  select * into s from priority_slots where tenant_id = v_a and import_key = 'cka:101';
  if s.is_away or s.prep_minutes <> 30
     or s.description <> 'Jihomoravská divize · 5. kolo'
     or s.created_by <> '10000000-0000-0000-0000-000000000001'
     or s.home_team <> 'TJ Sokol Brno IV' or s.starts_at <> '17:00'
     or s.site_match_id <> 101 or s.round <> 5
     or s.competition <> 'Jihomoravská divize'
     or s.site_slug <> 'jihomoravska-divize-2026-2027-kolo-5-x-y'
     or s.hand_edited then
    raise exception 'FAIL: home match 101 stored wrong: %', to_jsonb(s);
  end if;
  if not exists (select 1 from priority_slots where parent_id = s.id) then
    raise exception 'FAIL: home match 101 got no Úklid před zápasem';
  end if;
  select * into s from priority_slots where tenant_id = v_a and import_key = 'cka:102';
  if not s.is_away or s.prep_minutes <> 0 then
    raise exception 'FAIL: away match 102 stored wrong: %', to_jsonb(s);
  end if;
  if exists (select 1 from priority_slots where parent_id = s.id) then
    raise exception 'FAIL: away match 102 got a Úklid';
  end if;
  perform set_config('import.run', '', true);
  raise notice 'OK: apply_federation_matches inserts home and away matches keyed cka:<id>, created by the alley''s admin (0045)';
end $$;

-- 2. Idempotent; a video link alone is not an "update".
do $$
declare
  v_a constant uuid := '00000000-0000-0000-0000-00000000000a';
  r jsonb;
  v_before tid[];
begin
  -- xmin cannot tell inside this one transaction; every UPDATE writes a
  -- new tuple version, so an untouched row keeps its ctid.
  v_before := array(select ctid from priority_slots
                     where tenant_id = v_a and import_key in ('cka:101', 'cka:102')
                     order by import_key);
  r := apply_federation_matches(v_a, 'jihomoravska-divize-2026-2027', jsonb_build_array(
         pg_temp.fed_match(101, true, 10, '17:00', '20:00', 5),
         pg_temp.fed_match(102, false, 17, '10:00', '13:00', 6)));
  if (r->>'inserted')::int <> 0 or (r->>'updated')::int <> 0
     or (r->>'deleted')::int <> 0 then
    raise exception 'FAIL: a repeated apply changed something: %', r;
  end if;
  if array(select ctid from priority_slots
            where tenant_id = v_a and import_key in ('cka:101', 'cka:102')
            order by import_key) <> v_before then
    raise exception 'FAIL: a repeated identical apply rewrote a row';
  end if;
  r := apply_federation_matches(v_a, 'jihomoravska-divize-2026-2027', jsonb_build_array(
         pg_temp.fed_match(101, true, 10, '17:00', '20:00', 5)
           || '{"video_url":"https://youtu.be/x"}',
         pg_temp.fed_match(102, false, 17, '10:00', '13:00', 6)));
  if (r->>'updated')::int <> 0 or (r->>'inserted')::int <> 0 then
    raise exception 'FAIL: a video link counted as a match update: %', r;
  end if;
  if (select video_url from priority_slots
      where tenant_id = v_a and import_key = 'cka:101') is distinct from 'https://youtu.be/x' then
    raise exception 'FAIL: video_url was not written';
  end if;
  perform set_config('import.run', '', true);
  raise notice 'OK: apply_federation_matches is idempotent and writes video_url without an update (0045)';
end $$;

-- 3. A row of the old xlsx importer is rekeyed, not duplicated.
do $$
declare
  v_a constant uuid := '00000000-0000-0000-0000-00000000000a';
  v_today constant date := (now() at time zone 'Europe/Prague')::date;
  v_legacy uuid;
  r jsonb;
  s priority_slots;
begin
  insert into priority_slots
    (tenant_id, date, starts_at, ends_at, type_id, home_team, away_team,
     prep_minutes, description, created_by, import_key)
  values
    (v_a, v_today + 20, '17:00', '20:00',
     (select id from priority_slot_types where tenant_id = v_a and is_match and builtin),
     'A', 'B', 30, 'JmD 6. kolo', '10000000-0000-0000-0000-000000000001',
     'rozpis:JmD:6:A – B')
  returning id into v_legacy;
  perform set_config('probe.fed_legacy', v_legacy::text, true);
  r := apply_federation_matches(v_a, 'jihomoravska-divize-2026-2027', jsonb_build_array(
         pg_temp.fed_match(101, true, 10, '17:00', '20:00', 5)
           || '{"video_url":"https://youtu.be/x"}',
         pg_temp.fed_match(102, false, 17, '10:00', '13:00', 6),
         pg_temp.fed_match(103, true, 20, '17:00', '20:00', 7, v_legacy)));
  if (r->>'rekeyed')::int <> 1 or (r->>'inserted')::int <> 0 then
    raise exception 'FAIL: the legacy row was not rekeyed: %', r;
  end if;
  select * into s from priority_slots where tenant_id = v_a and import_key = 'cka:103';
  if s.id is distinct from v_legacy or s.home_team <> 'TJ Sokol Brno IV'
     or s.site_match_id <> 103 or s.description <> 'Jihomoravská divize · 7. kolo' then
    raise exception 'FAIL: rekeyed row wrong: %', to_jsonb(s);
  end if;
  if exists (select 1 from priority_slots
             where tenant_id = v_a and import_key = 'rozpis:JmD:6:A – B') then
    raise exception 'FAIL: the rozpis: key survived the rekey';
  end if;
  perform set_config('import.run', '', true);
  raise notice 'OK: a rozpis: row is rekeyed to cka:<id> in place, same id (0045)';
end $$;

-- 4. A hand-edited match is reported, never overwritten.
do $$
declare
  v_a constant uuid := '00000000-0000-0000-0000-00000000000a';
  r jsonb;
  v_id uuid;
begin
  update priority_slots set hand_edited = true
   where tenant_id = v_a and import_key = 'cka:101'
  returning id into v_id;
  r := apply_federation_matches(v_a, 'jihomoravska-divize-2026-2027', jsonb_build_array(
         pg_temp.fed_match(101, true, 10, '18:00', '21:00', 5)
           || '{"video_url":"https://youtu.be/x"}',
         pg_temp.fed_match(102, false, 17, '10:00', '13:00', 6),
         pg_temp.fed_match(103, true, 20, '17:00', '20:00', 7)));
  if (select starts_at from priority_slots where id = v_id) <> '17:00' then
    raise exception 'FAIL: the sync overwrote a hand-edited match';
  end if;
  if jsonb_array_length(r->'skipped_hand_edited') <> 1
     or (r->'skipped_hand_edited'->0->>'id')::uuid <> v_id
     or (r->>'updated')::int <> 0 then
    raise exception 'FAIL: the hand-edited skip is not reported: %', r;
  end if;
  perform set_config('import.run', '', true);
  raise notice 'OK: a hand-edited match keeps its values and lands in skipped_hand_edited (0045)';
end $$;

-- 5. Only future matches the site dropped are deleted, with their match job.
do $$
declare
  v_a constant uuid := '00000000-0000-0000-0000-00000000000a';
  v_today constant date := (now() at time zone 'Europe/Prague')::date;
  v_type uuid;
  r jsonb;
begin
  select id into v_type from priority_slot_types
   where tenant_id = v_a and is_match and builtin;
  insert into priority_slots
    (tenant_id, date, starts_at, ends_at, type_id, home_team, away_team,
     created_by, import_key, site_slug, site_match_id, is_away)
  values
    (v_a, v_today - 3, '17:00', '20:00', v_type, 'TJ Sokol Brno IV', 'KK Jiný',
     '10000000-0000-0000-0000-000000000001', 'cka:104',
     'jihomoravska-divize-2026-2027-kolo-1-x-y', 104, true),
    (v_a, v_today + 5, '17:00', '20:00', v_type, 'KK Jiný', 'TJ Sokol Brno IV',
     '10000000-0000-0000-0000-000000000001', 'cka:105',
     'jihomoravsky-prebor-2026-2027-kolo-1-x-y', 105, true);
  insert into priority_slots
    (tenant_id, date, starts_at, ends_at, type_id, home_team, away_team,
     created_by, import_key, site_slug, site_match_id, is_away, hand_edited)
  values
    (v_a, v_today + 8, '17:00', '20:00', v_type, 'KK Jiný', 'TJ Sokol Brno IV',
     '10000000-0000-0000-0000-000000000001', 'cka:106',
     'jihomoravska-divize-2026-2027-kolo-3-x-y', 106, true, true);
  perform enqueue_federation_match(v_a, 101, 'jihomoravska-divize-2026-2027-kolo-5-x-y', now() + interval '1 day');
  perform enqueue_federation_match(v_a, 102, 'jihomoravska-divize-2026-2027-kolo-6-x-y', now() + interval '1 day');
  r := apply_federation_matches(v_a, 'jihomoravska-divize-2026-2027', jsonb_build_array(
         pg_temp.fed_match(101, true, 10, '18:00', '21:00', 5)
           || '{"video_url":"https://youtu.be/x"}',
         pg_temp.fed_match(103, true, 20, '17:00', '20:00', 7)));
  if (r->>'deleted')::int <> 1 then
    raise exception 'FAIL: expected exactly one deleted match: %', r;
  end if;
  if exists (select 1 from priority_slots where tenant_id = v_a and import_key = 'cka:102') then
    raise exception 'FAIL: the dropped future match 102 survived';
  end if;
  if (select array_agg(payload->>'site_match_id') from notification_jobs
      where kind = 'federation_match') is distinct from array['101'] then
    raise exception 'FAIL: the dropped match 102 should lose its federation_match job, 101 keep it';
  end if;
  delete from notification_jobs where kind = 'federation_match';
  if (select count(*) from priority_slots
      where tenant_id = v_a
        and import_key in ('cka:101', 'cka:103', 'cka:104', 'cka:105', 'cka:106')) <> 5 then
    raise exception 'FAIL: the sync deleted a played, hand-edited or other-competition match';
  end if;
  perform set_config('import.run', '', true);
  raise notice 'OK: a future match the site dropped is deleted with its match job; played, hand-edited and other competitions stay (0045)';
end $$;

-- 5b. An empty list (a failed fetch) deletes nothing; a match already
-- under way today is not "future".
do $$
declare
  v_a constant uuid := '00000000-0000-0000-0000-00000000000a';
  v_now constant timestamp := now() at time zone 'Europe/Prague';
  -- Near midnight these fall on yesterday / tomorrow: still started / not.
  v_started constant timestamp := v_now - interval '1 hour';
  v_later constant timestamp := v_now + interval '1 hour';
  v_type uuid;
  r jsonb;
begin
  r := apply_federation_matches(v_a, 'jihomoravska-divize-2026-2027', '[]');
  if (r->>'deleted')::int <> 0
     or (select count(*) from priority_slots
         where tenant_id = v_a
           and import_key in ('cka:101', 'cka:103', 'cka:104', 'cka:106')) <> 4 then
    raise exception 'FAIL: an empty list deleted matches: %', r;
  end if;
  select id into v_type from priority_slot_types
   where tenant_id = v_a and is_match and builtin;
  insert into priority_slots
    (tenant_id, date, starts_at, ends_at, type_id, home_team, away_team,
     created_by, import_key, site_slug, site_match_id, is_away)
  values
    (v_a, v_started::date, v_started::time, '23:59:59.999', v_type,
     'KK Jiný', 'TJ Sokol Brno IV', '10000000-0000-0000-0000-000000000001',
     'cka:108', 'jihomoravska-divize-2026-2027-kolo-8-x-y', 108, true),
    (v_a, v_later::date, v_later::time, '23:59:59.999', v_type,
     'KK Jiný', 'TJ Sokol Brno IV', '10000000-0000-0000-0000-000000000001',
     'cka:109', 'jihomoravska-divize-2026-2027-kolo-9-x-y', 109, true);
  r := apply_federation_matches(v_a, 'jihomoravska-divize-2026-2027', jsonb_build_array(
         pg_temp.fed_match(101, true, 10, '18:00', '21:00', 5)
           || '{"video_url":"https://youtu.be/x"}',
         pg_temp.fed_match(103, true, 20, '17:00', '20:00', 7)));
  if (r->>'deleted')::int <> 1
     or exists (select 1 from priority_slots where tenant_id = v_a and import_key = 'cka:109') then
    raise exception 'FAIL: expected exactly the later-today match 109 deleted: %', r;
  end if;
  if not exists (select 1 from priority_slots where tenant_id = v_a and import_key = 'cka:108') then
    raise exception 'FAIL: a match already under way was deleted';
  end if;
  perform set_config('import.run', '', true);
  raise notice 'OK: an empty list deletes nothing; a started match survives, a later one today does not (0045)';
end $$;

-- 5c. A match the edge function skipped (no time on the site yet) comes
-- as p_keep_ids: its stored future row is not "dropped by the site".
do $$
declare
  v_a constant uuid := '00000000-0000-0000-0000-00000000000a';
  v_today constant date := (now() at time zone 'Europe/Prague')::date;
  r jsonb;
begin
  insert into priority_slots
    (tenant_id, date, starts_at, ends_at, type_id, home_team, away_team,
     created_by, import_key, site_slug, site_match_id, is_away)
  values
    (v_a, v_today + 30, '17:00', '20:00',
     (select id from priority_slot_types where tenant_id = v_a and is_match and builtin),
     'KK Jiný', 'TJ Sokol Brno IV', '10000000-0000-0000-0000-000000000001',
     'cka:111', 'jihomoravska-divize-2026-2027-kolo-11-x-y', 111, true);
  r := apply_federation_matches(v_a, 'jihomoravska-divize-2026-2027', jsonb_build_array(
         pg_temp.fed_match(101, true, 10, '18:00', '21:00', 5)
           || '{"video_url":"https://youtu.be/x"}',
         pg_temp.fed_match(103, true, 20, '17:00', '20:00', 7)), array[111]);
  if (r->>'deleted')::int <> 0
     or not exists (select 1 from priority_slots where tenant_id = v_a and import_key = 'cka:111') then
    raise exception 'FAIL: a kept (time-less) match was deleted: %', r;
  end if;
  r := apply_federation_matches(v_a, 'jihomoravska-divize-2026-2027', jsonb_build_array(
         pg_temp.fed_match(101, true, 10, '18:00', '21:00', 5)
           || '{"video_url":"https://youtu.be/x"}',
         pg_temp.fed_match(103, true, 20, '17:00', '20:00', 7)));
  if (r->>'deleted')::int <> 1 then
    raise exception 'FAIL: without p_keep_ids the dropped match 111 should go: %', r;
  end if;
  perform set_config('import.run', '', true);
  raise notice 'OK: p_keep_ids protects matches the edge function skipped (0045)';
end $$;

-- 5d. Home/away of a stored match without a venue is not the site's guess:
-- a rekeyed legacy row keeps what the old import knew (away here, although
-- the guess says home); only an insert takes the guess.
do $$
declare
  v_a constant uuid := '00000000-0000-0000-0000-00000000000a';
  v_today constant date := (now() at time zone 'Europe/Prague')::date;
  v_legacy uuid;
  r jsonb;
  s priority_slots;
begin
  insert into priority_slots
    (tenant_id, date, starts_at, ends_at, type_id, home_team, away_team,
     prep_minutes, description, is_away, created_by, import_key)
  values
    (v_a, v_today + 35, '17:00', '20:00',
     (select id from priority_slot_types where tenant_id = v_a and is_match and builtin),
     'TJ Sokol Brno IV', 'KK Jiný', 0, 'JmD 12. kolo · Jinde', true,
     '10000000-0000-0000-0000-000000000001', 'rozpis:JmD:12:TJ Sokol Brno IV – KK Jiný')
  returning id into v_legacy;
  r := apply_federation_matches(v_a, 'jihomoravska-divize-2026-2027', jsonb_build_array(
         pg_temp.fed_match(101, true, 10, '18:00', '21:00', 5)
           || '{"video_url":"https://youtu.be/x"}',
         pg_temp.fed_match(103, true, 20, '17:00', '20:00', 7),
         pg_temp.fed_match(112, true, 35, '17:00', '20:00', 12, v_legacy),
         pg_temp.fed_match(113, false, 36, '17:00', '20:00', 13),
         pg_temp.fed_match(114, true, 37, '17:00', '20:00', 14)));
  if (r->>'rekeyed')::int <> 1 or (r->>'inserted')::int <> 2 then
    raise exception 'FAIL: 5d fixture report: %', r;
  end if;
  select * into s from priority_slots where id = v_legacy;
  if s.import_key <> 'cka:112' or not s.is_away or s.prep_minutes <> 0
     or s.description <> 'Jihomoravská divize · 12. kolo' then
    raise exception 'FAIL: the rekeyed away match took the home guess: %', to_jsonb(s);
  end if;
  if exists (select 1 from priority_slots where parent_id = v_legacy) then
    raise exception 'FAIL: the rekeyed away match got a Úklid';
  end if;
  select * into s from priority_slots where tenant_id = v_a and import_key = 'cka:113';
  if not s.is_away or s.prep_minutes <> 0 then
    raise exception 'FAIL: an inserted match ignored the away guess: %', to_jsonb(s);
  end if;
  select * into s from priority_slots where tenant_id = v_a and import_key = 'cka:114';
  if s.is_away or s.prep_minutes <> 30 then
    raise exception 'FAIL: an inserted match ignored the home guess: %', to_jsonb(s);
  end if;
  delete from priority_slots
   where tenant_id = v_a and import_key in ('cka:112', 'cka:113', 'cka:114');
  perform set_config('import.run', '', true);
  raise notice 'OK: without a venue a stored match keeps home/away; inserts take the guess (0045)';
end $$;

-- 5e. The site's team slugs, not the names, tell our teams in a stored
-- match (federation_match_switched_off, the match job), so every write
-- keeps them: an insert takes them, a rekeyed legacy row gets them, and a
-- stored match follows the site in place — a hand-edited one too, as with
-- the video link. Slugs alone are no match update.
do $$
declare
  v_a constant uuid := '00000000-0000-0000-0000-00000000000a';
  v_today constant date := (now() at time zone 'Europe/Prague')::date;
  v_legacy uuid;
  v_115 uuid;
  v_116 uuid;
  r jsonb;
  s priority_slots;
begin
  insert into priority_slots
    (tenant_id, date, starts_at, ends_at, type_id, home_team, away_team,
     prep_minutes, description, created_by, import_key)
  values
    (v_a, v_today + 42, '17:00', '20:00',
     (select id from priority_slot_types where tenant_id = v_a and is_match and builtin),
     'TJ Sokol Brno IV', 'KK Jiný', 30, 'JmD 17. kolo',
     '10000000-0000-0000-0000-000000000001', 'rozpis:JmD:17:TJ Sokol Brno IV – KK Jiný')
  returning id into v_legacy;
  r := apply_federation_matches(v_a, 'jihomoravska-divize-2026-2027', jsonb_build_array(
         pg_temp.fed_match(101, true, 10, '18:00', '21:00', 5)
           || '{"video_url":"https://youtu.be/x"}',
         pg_temp.fed_match(103, true, 20, '17:00', '20:00', 7),
         pg_temp.fed_match(115, true, 40, '17:00', '20:00', 15, null,
                           'tj-sokol-brno-iv-muzi', 'kk-jiny'),
         pg_temp.fed_match(116, false, 41, '10:00', '13:00', 16),
         pg_temp.fed_match(117, true, 42, '17:00', '20:00', 17, v_legacy,
                           'tj-sokol-brno-iv-muzi', 'kk-jiny')));
  if (r->>'inserted')::int <> 2 or (r->>'rekeyed')::int <> 1 then
    raise exception 'FAIL: 5e fixture report: %', r;
  end if;
  select * into s from priority_slots where tenant_id = v_a and import_key = 'cka:115';
  v_115 := s.id;
  if (s.home_team_slug, s.away_team_slug)
     is distinct from ('tj-sokol-brno-iv-muzi', 'kk-jiny') then
    raise exception 'FAIL: an inserted match did not store its team slugs: %', to_jsonb(s);
  end if;
  select * into s from priority_slots where id = v_legacy;
  if s.import_key <> 'cka:117'
     or (s.home_team_slug, s.away_team_slug)
        is distinct from ('tj-sokol-brno-iv-muzi', 'kk-jiny') then
    raise exception 'FAIL: a rekeyed legacy row did not get the team slugs: %', to_jsonb(s);
  end if;
  select * into s from priority_slots where tenant_id = v_a and import_key = 'cka:116';
  v_116 := s.id;
  if s.home_team_slug is not null or s.away_team_slug is not null then
    raise exception 'FAIL: fixture — 116 came without slugs: %', to_jsonb(s);
  end if;
  update priority_slots set hand_edited = true where id = v_116;

  -- The site re-slugs 115's guests, and 116, stored before the slugs came,
  -- gets them.
  r := apply_federation_matches(v_a, 'jihomoravska-divize-2026-2027', jsonb_build_array(
         pg_temp.fed_match(101, true, 10, '18:00', '21:00', 5)
           || '{"video_url":"https://youtu.be/x"}',
         pg_temp.fed_match(103, true, 20, '17:00', '20:00', 7),
         pg_temp.fed_match(115, true, 40, '17:00', '20:00', 15, null,
                           'tj-sokol-brno-iv-muzi', 'kk-jiny-a'),
         pg_temp.fed_match(116, false, 41, '10:00', '13:00', 16, null,
                           'kk-jiny', 'tj-sokol-brno-iv-muzi'),
         pg_temp.fed_match(117, true, 42, '17:00', '20:00', 17, null,
                           'tj-sokol-brno-iv-muzi', 'kk-jiny')));
  if (r->>'inserted')::int <> 0 or (r->>'updated')::int <> 0
     or (r->>'rekeyed')::int <> 0 or (r->>'deleted')::int <> 0 then
    raise exception 'FAIL: new slugs counted as a match change: %', r;
  end if;
  select * into s from priority_slots where tenant_id = v_a and import_key = 'cka:115';
  if s.id is distinct from v_115
     or (s.home_team_slug, s.away_team_slug)
        is distinct from ('tj-sokol-brno-iv-muzi', 'kk-jiny-a') then
    raise exception 'FAIL: a stored match did not take the site''s new slug in place: %', to_jsonb(s);
  end if;
  select * into s from priority_slots where id = v_116;
  if (s.home_team_slug, s.away_team_slug)
     is distinct from ('kk-jiny', 'tj-sokol-brno-iv-muzi') then
    raise exception 'FAIL: a hand-edited match stored without slugs did not get them: %', to_jsonb(s);
  end if;
  select * into s from priority_slots where id = v_legacy;
  if (s.home_team_slug, s.away_team_slug)
     is distinct from ('tj-sokol-brno-iv-muzi', 'kk-jiny') then
    raise exception 'FAIL: the rekeyed row lost its team slugs: %', to_jsonb(s);
  end if;
  delete from priority_slots
   where tenant_id = v_a and import_key in ('cka:115', 'cka:116', 'cka:117');
  perform set_config('import.run', '', true);
  raise notice 'OK: apply_federation_matches stores the site''s team slugs on insert, on a rekey and in place (0045)';
end $$;

-- 6. A match detail: result, players, and the venue decides home/away.
do $$
declare
  v_a constant uuid := '00000000-0000-0000-0000-00000000000a';
  v_res constant jsonb := '{"status":"finished","match_type":"TEAMS_OF_6","discipline":"T120","video_url":null,"venue":{"slug":"jinde","name":"Kuželna Jinde"},"home_prep":30,"home":{"points":6,"total":3200,"fulls":2100,"spares":1100,"errors":10,"set_points":15},"away":{"points":2,"total":3100,"fulls":2050,"spares":1050,"errors":14,"set_points":9},"players":[{"side":"home","position":1,"player_name":"Jan Novák","player_site_id":7,"player_slug":"jan-novak","fulls":350,"spares":190,"errors":1,"total":540,"set_points":3,"team_points":1,"sub_name":"Petr Nový","sub_site_id":9,"sub_slug":"petr-novy","sub_from_throw":41,"lanes":[{"lane":1,"fulls":90,"spares":45,"errors":0,"total":135,"setPoints":1}]}]}';
  s priority_slots;
  mr match_results;
begin
  if not apply_federation_result(v_a, 103, v_res) then
    raise exception 'FAIL: apply_federation_result should answer true for a stored match';
  end if;
  select * into s from priority_slots where tenant_id = v_a and import_key = 'cka:103';
  select * into mr from match_results where match_id = s.id;
  if mr.match_id is null or mr.home_points <> 6 or mr.status <> 'finished'
     or mr.away_total <> 3100 or mr.home_set_points <> 15 or mr.tenant_id <> v_a
     or mr.discipline <> 'T120' then
    raise exception 'FAIL: match_results row wrong: %', to_jsonb(mr);
  end if;
  if (select count(*) from match_player_results where match_id = s.id) <> 1
     or (select lanes->0->>'total' from match_player_results where match_id = s.id) <> '135' then
    raise exception 'FAIL: player row not stored';
  end if;
  if (select (sub_name, sub_site_id, sub_slug, sub_from_throw)::text
        from match_player_results where match_id = s.id)
     is distinct from '("Petr Nový",9,petr-novy,41)' then
    raise exception 'FAIL: the substitution was not stored on the starter''s row (0053)';
  end if;
  if not s.is_away or s.prep_minutes <> 0 or s.venue_slug <> 'jinde'
     or s.venue <> 'Kuželna Jinde' or s.description not like '%· Kuželna Jinde' then
    raise exception 'FAIL: the venue did not turn 103 into an away match: %', to_jsonb(s);
  end if;
  if exists (select 1 from priority_slots where parent_id = s.id) then
    raise exception 'FAIL: the now-away match 103 kept its Úklid';
  end if;
  perform apply_federation_result(v_a, 103, v_res);
  if (select count(*) from match_player_results where match_id = s.id) <> 1
     or (select count(*) from match_results where match_id = s.id) <> 1 then
    raise exception 'FAIL: a repeated result duplicated rows';
  end if;
  if apply_federation_result(v_a, 999, v_res) then
    raise exception 'FAIL: apply_federation_result should answer false for a match with no slot';
  end if;
  perform set_config('import.run', '', true);
  raise notice 'OK: apply_federation_result upserts the result, replaces players, fixes home/away from the venue; false without a slot (0045); a substitution rides on the starter''s row (0053)';
end $$;

-- 7. RLS: own alley reads, the other alley sees nothing, nobody writes.
insert into teams (tenant_id, name, site_slug)
values ('00000000-0000-0000-0000-00000000000a', 'RLS sonda', 'rls-sonda');
set local role authenticated;
set local request.jwt.claims =
  '{"sub":"10000000-0000-0000-0000-000000000001","role":"authenticated"}';
do $$
begin
  if (select count(*) from match_results) <> 1
     or (select count(*) from match_player_results) <> 1 then
    raise exception 'FAIL: the admin does not see the alley''s results';
  end if;
  if (select count(*) from teams) <> 1 then
    raise exception 'FAIL: the admin does not see the alley''s teams';
  end if;
  if (select count(*) from federation_sync) <> 1 then
    raise exception 'FAIL: the admin does not see the sync settings';
  end if;
  begin
    insert into match_results (match_id, tenant_id, status)
    values ((select id from priority_slots where import_key = 'cka:101'),
            '00000000-0000-0000-0000-00000000000a', 'scheduled');
    raise exception 'FAIL: the admin wrote match_results directly';
  exception when insufficient_privilege then null;
  end;
  begin
    update federation_sync set enabled = false;
    raise exception 'FAIL: the admin wrote federation_sync directly';
  exception when insufficient_privilege then null;
  end;
end $$;
reset role;
set local role authenticated;
set local request.jwt.claims =
  '{"sub":"20000000-0000-0000-0000-000000000001","role":"authenticated"}';
do $$
begin
  if (select count(*) from match_results) <> 1
     or (select count(*) from teams) <> 1 then
    raise exception 'FAIL: a player does not see the alley''s results or teams';
  end if;
  if exists (select 1 from federation_sync) then
    raise exception 'FAIL: a player sees the sync settings';
  end if;
end $$;
reset role;
set local role authenticated;
set local request.jwt.claims =
  '{"sub":"10000000-0000-0000-0000-000000000002","role":"authenticated"}';
do $$
begin
  if exists (select 1 from match_results) or exists (select 1 from match_player_results)
     or exists (select 1 from teams) or exists (select 1 from federation_sync) then
    raise exception 'FAIL: another alley sees our federation data';
  end if;
  raise notice 'OK: federation tables are read-only for the app, per alley; sync settings admin-only (0045)';
end $$;
reset role;
delete from teams where site_slug = 'rls-sonda';

-- 6b. A hand-edited match learns its venue but keeps home/away as edited.
do $$
declare
  v_a constant uuid := '00000000-0000-0000-0000-00000000000a';
  v_before priority_slots;
  s priority_slots;
begin
  select * into v_before from priority_slots where tenant_id = v_a and import_key = 'cka:101';
  perform apply_federation_result(v_a, 101,
    '{"status":"scheduled","venue":{"slug":"jinde","name":"Kuželna Jinde"},"home_prep":30,"home":null,"away":null,"players":[]}');
  select * into s from priority_slots where id = v_before.id;
  if s.venue is distinct from 'Kuželna Jinde' or s.venue_slug is distinct from 'jinde' then
    raise exception 'FAIL: the venue of a hand-edited match was not recorded: %', to_jsonb(s);
  end if;
  if (s.is_away, s.prep_minutes, s.description, s.hand_edited)
     is distinct from (v_before.is_away, v_before.prep_minutes, v_before.description, true) then
    raise exception 'FAIL: apply_federation_result overwrote a hand-edited match: %', to_jsonb(s);
  end if;
  perform set_config('import.run', '', true);
  raise notice 'OK: apply_federation_result records the venue of a hand-edited match without touching home/away (0045)';
end $$;

-- 8. Teams: discovery upserts, the admin renames and switches.
do $$
declare
  v_a constant uuid := '00000000-0000-0000-0000-00000000000a';
  v_team constant jsonb := '{"site_slug":"tj-sokol-brno-iv-muzi","site_team_id":1,"site_name":"TJ Sokol Brno IV","competition_slug":"jihomoravska-divize-2026-2027","competition_name":"Jihomoravská divize","name":"TJ Sokol Brno IV","club_id":null}';
  v_club uuid;
begin
  if upsert_federation_teams(v_a, jsonb_build_array(v_team)) <> 1 then
    raise exception 'FAIL: discovery did not insert the team';
  end if;
  if upsert_federation_teams(v_a, jsonb_build_array(v_team || '{"site_name":"X"}')) <> 0 then
    raise exception 'FAIL: rediscovery inserted the team again';
  end if;
  if not exists (select 1 from teams where tenant_id = v_a and site_slug = 'tj-sokol-brno-iv-muzi'
                 and name = 'TJ Sokol Brno IV' and site_name = 'X' and active) then
    raise exception 'FAIL: rediscovery lost the name or did not refresh site_name';
  end if;
  if upsert_federation_teams(v_a, jsonb_build_array(
       v_team || '{"site_slug":"tj-sokol-brno-iv-b","site_team_id":2,"name":"Brno IV B"}',
       v_team || '{"site_slug":"tj-sokol-brno-iv-prebor","site_team_id":3,"competition_slug":"jihomoravsky-prebor-2026-2027","competition_name":"Jihomoravský přebor"}')) <> 2 then
    raise exception 'FAIL: discovery of two more teams';
  end if;
  if not exists (select 1 from teams where tenant_id = v_a
                 and site_slug = 'tj-sokol-brno-iv-prebor'
                 and name = 'TJ Sokol Brno IV (Jihomoravský přebor)') then
    raise exception 'FAIL: a clashing discovered name was not disambiguated';
  end if;
  if upsert_federation_teams(v_a, jsonb_build_array(
       v_team || '{"site_slug":"tj-sokol-brno-iv-prebor-b","site_team_id":4,"site_name":"TJ Sokol Brno IV B","competition_slug":"jihomoravsky-prebor-2026-2027","competition_name":"Jihomoravský přebor"}',
       v_team || jsonb_build_object('site_slug', 'dlouhy', 'site_team_id', 5,
                                    'name', repeat('Dlouhý ', 20)))) <> 2 then
    raise exception 'FAIL: a double clash or a long name broke discovery';
  end if;
  if not exists (select 1 from teams where tenant_id = v_a
                 and site_slug = 'tj-sokol-brno-iv-prebor-b'
                 and name = 'TJ Sokol Brno IV B (tj-sokol-brno-iv-prebor-b)') then
    raise exception 'FAIL: a doubly clashing name did not fall back to site name + slug';
  end if;
  if (select length(name) from teams where tenant_id = v_a and site_slug = 'dlouhy') <> 80 then
    raise exception 'FAIL: a long discovered name was not cut to 80';
  end if;
  delete from teams where tenant_id = v_a and site_slug = 'dlouhy';
  update teams set active = false
   where tenant_id = v_a and site_slug = 'tj-sokol-brno-iv-prebor-b';
  perform set_config('probe.fed_team',
    (select id::text from teams where tenant_id = v_a and site_slug = 'tj-sokol-brno-iv-muzi'), true);
  perform set_config('probe.fed_team_prebor',
    (select id::text from teams where tenant_id = v_a and site_slug = 'tj-sokol-brno-iv-prebor'), true);
  insert into clubs (tenant_id, name)
  values ('00000000-0000-0000-0000-000000000002', 'Cizí oddíl')
  returning id into v_club;
  perform set_config('probe.fed_club_b', v_club::text, true);
end $$;
set local role authenticated;
set local request.jwt.claims =
  '{"sub":"10000000-0000-0000-0000-000000000002","role":"authenticated"}';
do $$
begin
  if exists (select 1 from teams) then
    raise exception 'FAIL: another alley sees our teams';
  end if;
  begin
    perform update_team(current_setting('probe.fed_team')::uuid, 'Hack', null, true);
    raise exception 'FAIL: another alley''s admin renamed our team';
  exception when others then
    if sqlerrm <> 'not_allowed' then raise; end if;
  end;
end $$;
reset role;
set local role authenticated;
set local request.jwt.claims =
  '{"sub":"10000000-0000-0000-0000-000000000001","role":"authenticated"}';
do $$
declare
  v_team constant uuid := current_setting('probe.fed_team')::uuid;
begin
  if (select count(*) from teams) <> 4 then
    raise exception 'FAIL: the admin does not see the alley''s teams';
  end if;
  perform update_team(v_team, '  Brno IV A ', null, false);
  if not exists (select 1 from teams where id = v_team and name = 'Brno IV A' and not active) then
    raise exception 'FAIL: update_team did not rename and switch off';
  end if;
  begin
    perform update_team(v_team, 'Brno IV B', null, true);
    raise exception 'FAIL: a duplicate team name was accepted';
  exception when others then
    if sqlerrm <> 'team_name_taken' then raise; end if;
  end;
  begin
    perform update_team(v_team, '', null, true);
    raise exception 'FAIL: an empty team name was accepted';
  exception when others then
    if sqlerrm <> 'empty_name' then raise; end if;
  end;
  begin
    perform update_team(v_team, 'Brno IV A', current_setting('probe.fed_club_b')::uuid, true);
    raise exception 'FAIL: a foreign club was assigned';
  exception when others then
    if sqlerrm <> 'unknown_club' then raise; end if;
  end;
  begin
    perform update_team(v_team, 'Brno IV A', gen_random_uuid(), true);
    raise exception 'FAIL: a deleted club was assigned';
  exception when others then
    if sqlerrm <> 'unknown_club' then raise; end if;
  end;
  perform update_team(v_team, 'Brno IV A', null, true);
  perform update_team(current_setting('probe.fed_team_prebor')::uuid,
                      'Brno IV přebor', null, false);
  if not exists (select 1 from teams where id = v_team and name = 'Brno IV A' and active) then
    raise exception 'FAIL: the team is not active again';
  end if;
end $$;
reset role;
set local role authenticated;
set local request.jwt.claims =
  '{"sub":"20000000-0000-0000-0000-000000000001","role":"authenticated"}';
do $$
begin
  begin
    perform update_team(current_setting('probe.fed_team')::uuid, 'Hráčův', null, true);
    raise exception 'FAIL: a player renamed a team';
  exception when others then
    if sqlerrm <> 'not_allowed' then raise; end if;
  end;
  raise notice 'OK: discovery keeps the admin''s name and switch; update_team is admin-only, per alley, unique, non-empty (0045)';
end $$;
reset role;

-- 9. Settings and on-demand jobs.
set local role authenticated;
set local request.jwt.claims =
  '{"sub":"10000000-0000-0000-0000-000000000001","role":"authenticated"}';
do $$
begin
  begin
    perform set_federation_sync('Bad Slug', true);
    raise exception 'FAIL: an invalid venue slug was accepted';
  exception when others then
    if sqlerrm <> 'invalid_venue_slug' then raise; end if;
  end;
  perform set_federation_sync(' TJ-Sokol-Brno-IV ', true);
  if not exists (select 1 from federation_sync
                 where venue_slug = 'tj-sokol-brno-iv' and enabled) then
    raise exception 'FAIL: set_federation_sync did not store the normalised slug';
  end if;
  perform request_federation_sync();
  perform request_federation_discovery();
end $$;
reset role;
set local role authenticated;
set local request.jwt.claims =
  '{"sub":"20000000-0000-0000-0000-000000000001","role":"authenticated"}';
do $$
begin
  begin
    perform set_federation_sync('tj-sokol-brno-iv', false);
    raise exception 'FAIL: a player changed the sync settings';
  exception when others then
    if sqlerrm <> 'not_allowed' then raise; end if;
  end;
  begin
    perform request_federation_sync();
    raise exception 'FAIL: a player requested a sync';
  exception when others then
    if sqlerrm <> 'not_allowed' then raise; end if;
  end;
  begin
    perform request_federation_discovery();
    raise exception 'FAIL: a player requested discovery';
  exception when others then
    if sqlerrm <> 'not_allowed' then raise; end if;
  end;
end $$;
reset role;
set local role authenticated;
set local request.jwt.claims =
  '{"sub":"10000000-0000-0000-0000-000000000002","role":"authenticated"}';
do $$
begin
  begin
    perform request_federation_discovery();
    raise exception 'FAIL: discovery without a venue slug';
  exception when others then
    if sqlerrm <> 'federation_not_configured' then raise; end if;
  end;
  begin
    perform request_federation_sync();
    raise exception 'FAIL: a sync with the federation off';
  exception when others then
    if sqlerrm <> 'federation_disabled' then raise; end if;
  end;
end $$;
reset role;
do $$
begin
  if (select count(*) from notification_jobs where kind = 'federation_competition') <> 1
     or not exists (select 1 from notification_jobs
                    where kind = 'federation_competition'
                      and payload->>'competition_slug' = 'jihomoravska-divize-2026-2027'
                      and payload->>'tenant_id' = '00000000-0000-0000-0000-00000000000a') then
    raise exception 'FAIL: request_federation_sync should enqueue exactly the active competition';
  end if;
  if not exists (select 1 from notification_jobs
                 where kind = 'federation_discover'
                   and dedupe_key = 'federation_discover:00000000-0000-0000-0000-00000000000a') then
    raise exception 'FAIL: request_federation_discovery enqueued nothing';
  end if;
  raise notice 'OK: sync settings validate the slug; sync and discovery requests are admin-only and enqueue jobs (0045)';
end $$;

-- 10. refresh_match: only a live match, at most every 5 minutes.
do $$
declare
  v_local constant timestamp := (now() at time zone 'Europe/Prague') - interval '30 minutes';
begin
  if current_setting('import.run', true) = 'on' then
    raise exception 'FAIL: import.run outlived the federation calls, silencing the 0038 trigger';
  end if;
  -- Moving the match to now is fixture setup, not an admin's hand edit.
  perform set_config('import.run', 'on', true);
  update priority_slots
     set date = v_local::date, starts_at = v_local::time, ends_at = '23:59:59.999'
   where tenant_id = '00000000-0000-0000-0000-00000000000a' and import_key = 'cka:103';
  perform set_config('import.run', '', true);
  update match_results set status = 'in_progress', fetched_at = now() - interval '10 minutes'
   where match_id = (select id from priority_slots where import_key = 'cka:103');
end $$;
set local role authenticated;
set local request.jwt.claims =
  '{"sub":"10000000-0000-0000-0000-000000000002","role":"authenticated"}';
do $$
begin
  if refresh_match((select id from priority_slots where import_key = 'cka:103'
                    and tenant_id = '00000000-0000-0000-0000-00000000000a')) <> 'not_live' then
    raise exception 'FAIL: another alley refreshed our match';
  end if;
end $$;
reset role;
do $$
begin
  perform set_config('probe.fed_101', (select id::text from priority_slots
    where import_key = 'cka:101' and tenant_id = '00000000-0000-0000-0000-00000000000a'), true);
  perform set_config('probe.fed_103', (select id::text from priority_slots
    where import_key = 'cka:103' and tenant_id = '00000000-0000-0000-0000-00000000000a'), true);
  if exists (select 1 from notification_jobs where kind = 'federation_match') then
    raise exception 'FAIL: a federation_match job before any refresh';
  end if;
  -- Only the switched-off Brno IV přebor plays 103 for now.
  update priority_slots
     set home_team_slug = 'tj-sokol-brno-iv-prebor', away_team_slug = 'kk-jiny'
   where id = current_setting('probe.fed_103')::uuid;
end $$;
set local role authenticated;
set local request.jwt.claims =
  '{"sub":"10000000-0000-0000-0000-000000000001","role":"authenticated"}';
do $$
begin
  if refresh_match(current_setting('probe.fed_103')::uuid) <> 'not_live' then
    raise exception 'FAIL: a match only switched-off teams of ours play was not refused';
  end if;
end $$;
reset role;
-- Its job would fetch the page and stop unwritten, leaving neither a fresh
-- fetched_at nor a pending requested_at: every later request would fetch
-- again. So no job at all.
do $$
begin
  if exists (select 1 from notification_jobs where kind = 'federation_match') then
    raise exception 'FAIL: refresh_match queued a fetch for a switched-off team''s match';
  end if;
  -- The active Brno IV A on the other side makes it live again.
  update priority_slots set away_team_slug = 'tj-sokol-brno-iv-muzi'
   where id = current_setting('probe.fed_103')::uuid;
end $$;
set local role authenticated;
set local request.jwt.claims =
  '{"sub":"10000000-0000-0000-0000-000000000001","role":"authenticated"}';
do $$
begin
  if refresh_match(current_setting('probe.fed_101')::uuid) <> 'not_live' then
    raise exception 'FAIL: a match 10 days out is live';
  end if;
  if refresh_match(current_setting('probe.fed_103')::uuid) <> 'queued' then
    raise exception 'FAIL: a running match with a stale result was not queued';
  end if;
end $$;
reset role;
-- The fetch is pending and backing off: requested 2 minutes ago, next try
-- in a minute.
do $$
begin
  if not exists (select 1 from notification_jobs
                 where kind = 'federation_match'
                   and dedupe_key = 'federation_match:00000000-0000-0000-0000-00000000000a:103'
                   and payload->>'site_match_id' = '103'
                   and payload->>'slug' = 'jihomoravska-divize-2026-2027-kolo-7-x-y'
                   and (payload->>'requested_at')::timestamptz = now()
                   and run_at = now()) then
    raise exception 'FAIL: refresh_match enqueued no stamped federation_match job for 103';
  end if;
  update notification_jobs
     set run_at = now() + interval '1 minute',
         payload = payload || jsonb_build_object('requested_at', now() - interval '2 minutes')
   where dedupe_key = 'federation_match:00000000-0000-0000-0000-00000000000a:103';
end $$;
set local role authenticated;
set local request.jwt.claims =
  '{"sub":"10000000-0000-0000-0000-000000000001","role":"authenticated"}';
do $$
begin
  if refresh_match(current_setting('probe.fed_103')::uuid) <> 'queued' then
    raise exception 'FAIL: a repeated refresh of a pending fetch was not answered queued';
  end if;
end $$;
reset role;
do $$
begin
  if not exists (select 1 from notification_jobs
                 where dedupe_key = 'federation_match:00000000-0000-0000-0000-00000000000a:103'
                   and run_at = now() + interval '1 minute'
                   and (payload->>'requested_at')::timestamptz = now() - interval '2 minutes') then
    raise exception 'FAIL: a refresh within 5 minutes of the last request re-armed the job';
  end if;
  update notification_jobs
     set payload = payload || jsonb_build_object('requested_at', now() - interval '10 minutes')
   where dedupe_key = 'federation_match:00000000-0000-0000-0000-00000000000a:103';
end $$;
set local role authenticated;
set local request.jwt.claims =
  '{"sub":"10000000-0000-0000-0000-000000000001","role":"authenticated"}';
do $$
begin
  if refresh_match(current_setting('probe.fed_103')::uuid) <> 'queued' then
    raise exception 'FAIL: a refresh after 5 minutes was not queued';
  end if;
end $$;
reset role;
do $$
declare
  v_local constant timestamp := (now() at time zone 'Europe/Prague') + interval '30 minutes';
begin
  if not exists (select 1 from notification_jobs
                 where dedupe_key = 'federation_match:00000000-0000-0000-0000-00000000000a:103'
                   and run_at = now()
                   and (payload->>'requested_at')::timestamptz = now()) then
    raise exception 'FAIL: a refresh after 5 minutes did not re-arm and re-stamp the job';
  end if;
  perform enqueue_federation_match('00000000-0000-0000-0000-00000000000a', 103,
    'jihomoravska-divize-2026-2027-kolo-7-x-y', now() + interval '1 day');
  if not exists (select 1 from notification_jobs
                 where dedupe_key = 'federation_match:00000000-0000-0000-0000-00000000000a:103'
                   and run_at = now()
                   and (payload->>'requested_at')::timestamptz = now()) then
    raise exception 'FAIL: a later checkpoint pushed back the job or dropped requested_at';
  end if;
  update match_results set fetched_at = now()
   where match_id = current_setting('probe.fed_103')::uuid;
  -- A scheduled match starting in 30 minutes, nothing fetched yet.
  insert into priority_slots
    (tenant_id, date, starts_at, ends_at, type_id, home_team, away_team,
     created_by, import_key, site_slug, site_match_id, is_away)
  values
    ('00000000-0000-0000-0000-00000000000a', v_local::date, v_local::time, '23:59:59.999',
     (select id from priority_slot_types
       where tenant_id = '00000000-0000-0000-0000-00000000000a' and is_match and builtin),
     'KK Jiný', 'TJ Sokol Brno IV', '10000000-0000-0000-0000-000000000001',
     'cka:107', 'jihomoravska-divize-2026-2027-kolo-10-x-y', 107, true);
  perform set_config('probe.fed_107', (select id::text from priority_slots
    where import_key = 'cka:107' and tenant_id = '00000000-0000-0000-0000-00000000000a'), true);
end $$;
set local role authenticated;
set local request.jwt.claims =
  '{"sub":"10000000-0000-0000-0000-000000000001","role":"authenticated"}';
do $$
begin
  if refresh_match(current_setting('probe.fed_103')::uuid) <> 'fresh' then
    raise exception 'FAIL: a result fetched just now was not fresh';
  end if;
  if refresh_match(current_setting('probe.fed_107')::uuid) <> 'queued' then
    raise exception 'FAIL: a scheduled match about to start was not queued';
  end if;
end $$;
reset role;
-- 0054: the refresh button (p_force) looks again even inside the 5 minutes;
-- the background poke still answers fresh; a double tap is held off.
do $$
begin
  update match_results set fetched_at = now() - interval '1 minute'
   where match_id = current_setting('probe.fed_103')::uuid;
  update notification_jobs
     set run_at = now() + interval '1 hour',
         payload = payload || jsonb_build_object('requested_at', now() - interval '1 minute')
   where dedupe_key = 'federation_match:00000000-0000-0000-0000-00000000000a:103';
end $$;
set local role authenticated;
set local request.jwt.claims =
  '{"sub":"10000000-0000-0000-0000-000000000001","role":"authenticated"}';
do $$
begin
  if refresh_match(current_setting('probe.fed_103')::uuid) <> 'fresh' then
    raise exception 'FAIL: the background poke did not stay fresh inside 5 minutes';
  end if;
  if refresh_match(current_setting('probe.fed_103')::uuid, true) <> 'queued' then
    raise exception 'FAIL: a forced refresh inside 5 minutes was not queued (0054)';
  end if;
end $$;
reset role;
do $$
begin
  if not exists (select 1 from notification_jobs
                 where dedupe_key = 'federation_match:00000000-0000-0000-0000-00000000000a:103'
                   and run_at = now()
                   and (payload->>'requested_at')::timestamptz = now()) then
    raise exception 'FAIL: a forced refresh did not re-arm the job (0054)';
  end if;
  update match_results set fetched_at = now() - interval '5 seconds'
   where match_id = current_setting('probe.fed_103')::uuid;
end $$;
set local role authenticated;
set local request.jwt.claims =
  '{"sub":"10000000-0000-0000-0000-000000000001","role":"authenticated"}';
do $$
begin
  if refresh_match(current_setting('probe.fed_103')::uuid, true) <> 'fresh' then
    raise exception 'FAIL: a forced double tap was not held off by the 15 s floor (0054)';
  end if;
  raise notice 'OK: a forced refresh looks at the site again inside 5 minutes, a double tap is held off (0054)';
end $$;
reset role;
do $$
begin
  if not exists (select 1 from notification_jobs
                 where dedupe_key = 'federation_match:00000000-0000-0000-0000-00000000000a:107'
                   and payload->>'requested_at' is not null) then
    raise exception 'FAIL: no federation_match job for the scheduled match 107';
  end if;
  update match_results set status = 'finished', fetched_at = now() - interval '1 hour'
   where match_id = current_setting('probe.fed_103')::uuid;
end $$;
set local role authenticated;
set local request.jwt.claims =
  '{"sub":"10000000-0000-0000-0000-000000000001","role":"authenticated"}';
do $$
begin
  if refresh_match(current_setting('probe.fed_103')::uuid) <> 'not_live' then
    raise exception 'FAIL: a finished match was refreshed';
  end if;
  raise notice 'OK: refresh_match queues only a live match, at most one request per 5 minutes even while a fetch is pending (0045)';
end $$;
reset role;

-- 0062: the ⟳ button (force) asks again for a finished match — a correction
-- on the site — within 14 days of its start; opening it (no force) does not.
reset role;
do $$
begin
  delete from notification_jobs
   where dedupe_key = 'federation_match:00000000-0000-0000-0000-00000000000a:103';
end $$;
set local role authenticated;
set local request.jwt.claims =
  '{"sub":"10000000-0000-0000-0000-000000000001","role":"authenticated"}';
do $$
begin
  if refresh_match(current_setting('probe.fed_103')::uuid, true) <> 'queued' then
    raise exception 'FAIL: the button could not ask again for a finished match';
  end if;
end $$;
reset role;
do $$
begin
  if not exists (select 1 from notification_jobs
                 where dedupe_key = 'federation_match:00000000-0000-0000-0000-00000000000a:103') then
    raise exception 'FAIL: a forced refresh of a finished match queued no fetch';
  end if;
  delete from notification_jobs
   where dedupe_key = 'federation_match:00000000-0000-0000-0000-00000000000a:103';
  perform set_config('probe.fed_103_date',
    (select date::text from priority_slots where id = current_setting('probe.fed_103')::uuid), true);
  update priority_slots set date = date - 20
   where id = current_setting('probe.fed_103')::uuid;
end $$;
set local role authenticated;
set local request.jwt.claims =
  '{"sub":"10000000-0000-0000-0000-000000000001","role":"authenticated"}';
do $$
begin
  if refresh_match(current_setting('probe.fed_103')::uuid, true) <> 'not_live' then
    raise exception 'FAIL: a match finished three weeks ago was asked for again';
  end if;
end $$;
reset role;
do $$
begin
  update priority_slots set date = current_setting('probe.fed_103_date')::date
   where id = current_setting('probe.fed_103')::uuid;
  raise notice 'OK: the button asks again for a finished match within 14 days, opening it does not (0062)';
end $$;

-- 10b. The site shows PREPARATION days before some matches: until an hour
-- before the start it is not live, like SCHEDULED.
do $$
declare
  v_a constant uuid := '00000000-0000-0000-0000-00000000000a';
  v_far constant timestamp := (now() at time zone 'Europe/Prague') + interval '14 days';
  v_soon constant timestamp := (now() at time zone 'Europe/Prague') + interval '30 minutes';
begin
  insert into priority_slots
    (tenant_id, date, starts_at, ends_at, type_id, home_team, away_team,
     created_by, import_key, site_slug, site_match_id, is_away)
  select v_a, v.at::date, v.at::time, '23:59:59.999',
         (select id from priority_slot_types where tenant_id = v_a and is_match and builtin),
         'KK Jiný', 'TJ Sokol Brno IV', '10000000-0000-0000-0000-000000000001',
         'cka:' || v.id, 'jihomoravska-divize-2026-2027-kolo-12-x-' || v.id, v.id, true
    from (values (120, v_far), (121, v_soon)) as v(id, at);
  insert into match_results (match_id, tenant_id, status, fetched_at)
  select id, v_a, 'preparation', now() - interval '10 minutes'
    from priority_slots where tenant_id = v_a and import_key in ('cka:120', 'cka:121');
  perform set_config('probe.fed_120', (select id::text from priority_slots
    where import_key = 'cka:120' and tenant_id = v_a), true);
  perform set_config('probe.fed_121', (select id::text from priority_slots
    where import_key = 'cka:121' and tenant_id = v_a), true);
end $$;
set local role authenticated;
set local request.jwt.claims =
  '{"sub":"10000000-0000-0000-0000-000000000001","role":"authenticated"}';
do $$
begin
  if refresh_match(current_setting('probe.fed_120')::uuid) <> 'not_live' then
    raise exception 'FAIL: a match in preparation two weeks out is live';
  end if;
  if refresh_match(current_setting('probe.fed_121')::uuid) <> 'queued' then
    raise exception 'FAIL: a match in preparation starting in 30 minutes was not queued';
  end if;
end $$;
reset role;
do $$
begin
  if exists (select 1 from notification_jobs
             where dedupe_key = 'federation_match:00000000-0000-0000-0000-00000000000a:120')
     or not exists (select 1 from notification_jobs
                    where dedupe_key = 'federation_match:00000000-0000-0000-0000-00000000000a:121'
                      and payload->>'requested_at' is not null) then
    raise exception 'FAIL: refresh_match queued the wrong preparation match';
  end if;
  raise notice 'OK: a match in preparation is live only from an hour before its start (0045)';
end $$;

-- 11. The nightly producer: one job per active competition of enabled alleys.
do $$
declare
  v_b constant uuid := '00000000-0000-0000-0000-000000000002';
begin
  if not exists (select 1 from cron.job
                 where jobname = 'federation-nightly' and schedule = '0 1 * * *') then
    raise exception 'FAIL: no federation-nightly cron job';
  end if;
  insert into federation_sync (tenant_id, venue_slug, enabled) values (v_b, 'kuzelna-b', true);
  perform upsert_federation_teams(v_b, '[{"site_slug":"kuzelna-b-a","site_team_id":9,"site_name":"Kuželna B","competition_slug":"krajsky-prebor-2026-2027","competition_name":"Krajský přebor","name":"Kuželna B","club_id":null}]');
  delete from notification_jobs where kind = 'federation_competition';
  perform enqueue_federation_jobs();
  if (select count(*) from notification_jobs where kind = 'federation_competition') <> 2
     or (select count(distinct run_at) from notification_jobs
         where kind = 'federation_competition') <> 2
     or not exists (select 1 from notification_jobs where kind = 'federation_competition'
                    and payload->>'competition_slug' = 'krajsky-prebor-2026-2027')
     or exists (select 1 from notification_jobs where kind = 'federation_competition'
                and payload->>'competition_slug' = 'jihomoravsky-prebor-2026-2027') then
    raise exception 'FAIL: enqueue_federation_jobs should give one spaced job per active competition';
  end if;
  update federation_sync set enabled = false where tenant_id = v_b;
  delete from notification_jobs where kind = 'federation_competition';
  perform enqueue_federation_jobs();
  if (select count(*) from notification_jobs where kind = 'federation_competition') <> 1 then
    raise exception 'FAIL: a disabled alley got a nightly job';
  end if;
  raise notice 'OK: federation-nightly enqueues one job per active competition of enabled alleys (0045)';
end $$;

-- 12. Privileges: server functions are the service's, tables read-only.
do $$
declare
  t text;
  f text;
begin
  foreach t in array array['public.teams', 'public.federation_sync',
                           'public.match_results', 'public.match_player_results',
                           'public.venues'] loop
    if has_table_privilege('anon', t, 'select')
       or not has_table_privilege('authenticated', t, 'select')
       or has_table_privilege('authenticated', t, 'insert')
       or has_table_privilege('authenticated', t, 'update')
       or has_table_privilege('authenticated', t, 'delete') then
      raise exception 'FAIL: % must be select-only for the app, nothing for anon', t;
    end if;
    if not exists (select 1 from pg_publication_tables
                   where pubname = 'supabase_realtime' and schemaname || '.' || tablename = t) then
      raise exception 'FAIL: % is not in supabase_realtime', t;
    end if;
  end loop;
  foreach f in array array['public.apply_federation_matches(uuid, text, jsonb, integer[])',
                           'public.apply_federation_result(uuid, integer, jsonb)',
                           'public.upsert_federation_teams(uuid, jsonb)',
                           'public.record_federation_run(uuid, text, jsonb, text)',
                           'public.enqueue_federation_match(uuid, integer, text, timestamptz)',
                           'public.enqueue_federation_jobs()',
                           'public.federation_description(text, integer, boolean, text)',
                           'public.upsert_federation_venue(uuid, jsonb)',
                           'public.enqueue_federation_venue(uuid, text, interval)',
                           'public.federation_live_report(uuid, jsonb)',
                           'public.federation_last_error(uuid, jsonb)',
                           'public.federation_refresh_error(uuid)',
                           'public.federation_match_switched_off(uuid, text, text)',
                           'public.league_competition_is_ours(uuid, text)',
                           'public.league_drop_orphan_jobs(uuid)',
                           'public.apply_league_matches(uuid, text, jsonb)',
                           'public.apply_league_result(uuid, integer, jsonb)'] loop
    if has_function_privilege('authenticated', f, 'execute')
       or has_function_privilege('anon', f, 'execute') then
      raise exception 'FAIL: % is callable from the app', f;
    end if;
  end loop;
  foreach f in array array['public.apply_federation_matches(uuid, text, jsonb, integer[])',
                           'public.apply_federation_result(uuid, integer, jsonb)',
                           'public.upsert_federation_teams(uuid, jsonb)',
                           'public.record_federation_run(uuid, text, jsonb, text)',
                           'public.enqueue_federation_match(uuid, integer, text, timestamptz)',
                           'public.upsert_federation_venue(uuid, jsonb)',
                           'public.federation_last_error(uuid, jsonb)'] loop
    if not has_function_privilege('service_role', f, 'execute') then
      raise exception 'FAIL: the service cannot call %', f;
    end if;
  end loop;
  foreach f in array array['public.set_federation_sync(text, boolean)',
                           'public.request_federation_discovery()',
                           'public.request_federation_sync()',
                           'public.update_team(uuid, text, uuid, boolean)',
                           'public.refresh_match(uuid, boolean)'] loop
    if has_function_privilege('anon', f, 'execute')
       or not has_function_privilege('authenticated', f, 'execute') then
      raise exception 'FAIL: % must be callable by the app only', f;
    end if;
  end loop;
  raise notice 'OK: federation writes are server-only; the app reads and calls five RPCs, anon nothing (0045)';
end $$;

-- 12b. The app streams one match's lines filtered by match_id, and every
-- fetch deletes and re-inserts them. Realtime matches a DELETE against the
-- replica identity only, so it has to carry match_id.
do $$
begin
  if (select relreplident from pg_class
      where oid = 'public.match_player_results'::regclass) <> 'f' then
    raise exception 'FAIL: match_player_results needs replica identity full, or a stream filtered by match_id never sees its deletes';
  end if;
  raise notice 'OK: match_player_results deletes reach a stream filtered by match_id (0045)';
end $$;

-- 13. record_federation_run keeps the last good report per key.
do $$
declare
  v_b constant uuid := '00000000-0000-0000-0000-000000000002';
  s federation_sync;
begin
  delete from federation_sync where tenant_id = v_b;
  perform record_federation_run(v_b, 'discover', '{"teams":3}', null);
  select * into s from federation_sync where tenant_id = v_b;
  -- 0047: a discovery keeps its report but is no sync run.
  if s.last_run_at is not null or s.last_success_at is not null or s.last_error is not null
     or s.last_report->'discover'->>'teams' <> '3'
     or s.last_report->'discover'->>'at' is null then
    raise exception 'FAIL: a discovery should keep its report without stamping a run: %', to_jsonb(s);
  end if;
  perform record_federation_run(v_b, 'competition:krajsky-prebor-2026-2027', '{"inserted":1}', null);
  update federation_sync
     set last_run_at = now() - interval '1 hour', last_success_at = now() - interval '1 hour'
   where tenant_id = v_b;
  perform record_federation_run(v_b, 'discover', '{"teams":0}', 'site down');
  select * into s from federation_sync where tenant_id = v_b;
  if s.last_error <> 'site down' or s.last_success_at <> now() - interval '1 hour'
     or s.last_run_at <> now() - interval '1 hour'
     or s.last_report->'discover'->>'error' is distinct from 'site down'
     or s.last_report->'discover'->>'at' is null
     or s.last_report->'discover' ? 'teams'
     or s.last_report->'competition:krajsky-prebor-2026-2027'->>'inserted' is distinct from '1' then
    raise exception 'FAIL: a failed run is not recorded under its key: %', to_jsonb(s);
  end if;
  perform record_federation_run(v_b, 'discover', '{"teams":4}', null);
  select * into s from federation_sync where tenant_id = v_b;
  if s.last_error is not null or s.last_report->'discover'->>'teams' <> '4'
     or s.last_report->'discover' ? 'error'
     or s.last_report->'competition:krajsky-prebor-2026-2027'->>'inserted' is distinct from '1' then
    raise exception 'FAIL: a success did not replace the key''s error or clear last_error: %', to_jsonb(s);
  end if;
  raise notice 'OK: record_federation_run keeps a report or an error per key and the last error (0045)';
end $$;

-- Fixtures for 13b–13d. B's active Kuželna B (kuzelna-b-a, krajsky-prebor,
-- from 11) plays away at 921 and 922; the switched-off Kuželna B rezerva
-- (kuzelna-b-b, okresni-prebor) alone plays 923; 924 names no team of B's
-- at all; 926 is a derby of the two where Kuželna B still carries a name
-- it no longer has; 927 is Kuželna B's match in okresni-prebor, a
-- competition no active team of B's plays any more (a past season); 928
-- names no team of B's, only A's switched-off Cizí tým; 929 is a derby of
-- two switched-off teams of B's, Kuželna B D and E, in krajsky-prebor,
-- which the active Kuželna B still plays: only the switch kills it. Our
-- teams are told apart by the site's team slugs, as runMatch does, never
-- by the names. A has an active team with the rezerva's slug in
-- okresni-prebor and a match 925, and an active team with D's slug, so a
-- liveness check that forgot the tenant would keep B's dead keys — or,
-- through Cizí tým, kill B's live 928.
do $$
declare
  v_a constant uuid := '00000000-0000-0000-0000-00000000000a';
  v_b constant uuid := '00000000-0000-0000-0000-000000000002';
begin
  insert into teams (tenant_id, name, site_slug, competition_slug, active)
  values (v_b, 'Kuželna B rezerva', 'kuzelna-b-b', 'okresni-prebor-2026-2027', false),
         (v_a, 'Kuželna B rezerva', 'kuzelna-b-b', 'okresni-prebor-2026-2027', true),
         (v_a, 'Cizí tým', 'cizi-tym', 'cizi-soutez-2026-2027', false),
         (v_b, 'Kuželna B D', 'kuzelna-b-d', 'krajsky-prebor-2026-2027', false),
         (v_b, 'Kuželna B E', 'kuzelna-b-e', 'krajsky-prebor-2026-2027', false),
         (v_a, 'Kuželna B D', 'kuzelna-b-d', 'krajsky-prebor-2026-2027', true);
  insert into priority_slots
    (tenant_id, date, starts_at, ends_at, type_id, home_team, away_team,
     home_team_slug, away_team_slug, site_slug,
     prep_minutes, description, is_away, created_by, import_key, site_match_id, venue_slug)
  select x.tenant_id, current_date + 60 + x.n - 921, '10:00', '13:00',
         (select id from priority_slot_types
           where tenant_id = x.tenant_id and is_match and builtin),
         x.home, x.away, x.home_slug, x.away_slug,
         x.comp || '-kolo-' || (x.n - 920) || '-' || x.home_slug || '-' || x.away_slug,
         0, 'Fixture 13b', true,
         (select id from profiles where tenant_id = x.tenant_id and role = 'admin'
           order by created_at, id limit 1),
         'cka:' || x.n, x.n, 'hoste-' || x.n
    from (values
      (v_b, 921, 'krajsky-prebor-2026-2027', 'KK Hosté', 'kk-hoste', 'Kuželna B', 'kuzelna-b-a'),
      (v_b, 922, 'krajsky-prebor-2026-2027', 'KK Hosté', 'kk-hoste', 'Kuželna B', 'kuzelna-b-a'),
      (v_b, 923, 'okresni-prebor-2026-2027', 'KK Hosté', 'kk-hoste',
       'Kuželna B rezerva', 'kuzelna-b-b'),
      (v_b, 924, 'krajsky-prebor-2026-2027', 'KK Hosté', 'kk-hoste', 'KK Jiní', 'kk-jini'),
      (v_a, 925, 'okresni-prebor-2026-2027', 'KK Hosté', 'kk-hoste',
       'Kuželna B rezerva', 'kuzelna-b-b'),
      (v_b, 926, 'krajsky-prebor-2026-2027', 'Kuželna B stará', 'kuzelna-b-a',
       'Kuželna B rezerva', 'kuzelna-b-b'),
      (v_b, 927, 'okresni-prebor-2026-2027', 'KK Hosté', 'kk-hoste', 'Kuželna B', 'kuzelna-b-a'),
      (v_b, 928, 'krajsky-prebor-2026-2027', 'KK Hosté', 'kk-hoste', 'Cizí tým', 'cizi-tym'),
      (v_b, 929, 'krajsky-prebor-2026-2027', 'Kuželna B D', 'kuzelna-b-d',
       'Kuželna B E', 'kuzelna-b-e'))
      x(tenant_id, n, comp, home, home_slug, away, away_slug);
  perform set_config('probe.fed_a_sync',
    (select to_jsonb(f)::text from federation_sync f where tenant_id = v_a), true);
end $$;

-- 13b. Only competition runs are the sync's runs (discovery was one too
-- until 0047): they stamp last_run_at and last_success_at. A match or
-- venue job reports only trouble, under its own key (match:<site_match_id>,
-- venue:<slug>): a failure is written there, a success removes just that
-- entry, and a success with nothing to remove writes nothing — no row, no
-- update, so no Realtime event for every fetched match.
do $$
declare
  v_b constant uuid := '00000000-0000-0000-0000-000000000002';
  v_hour_ago constant timestamptz := now() - interval '1 hour';
  v_comp constant text := 'competition:krajsky-prebor-2026-2027';
  s federation_sync;
  v_ctid tid;
begin
  delete from federation_sync where tenant_id = v_b;
  perform record_federation_run(v_b, 'match:921', null, null);
  perform record_federation_run(v_b, 'venue:kuzelna-b', null, null);
  if exists (select 1 from federation_sync where tenant_id = v_b) then
    raise exception 'FAIL: a match or venue success with nothing to remove wrote a row';
  end if;

  insert into federation_sync (tenant_id, venue_slug, last_run_at, last_success_at)
  values (v_b, 'kuzelna-b', v_hour_ago, v_hour_ago);
  perform record_federation_run(v_b, 'match:921', null, 'federation_match kolo-1-b: HTTP 503');
  perform record_federation_run(v_b, 'match:922', null, 'federation_match kolo-2-b: HTTP 503');
  perform record_federation_run(v_b, 'venue:kuzelna-b', null, 'federation_venue: HTTP 404');
  select * into s from federation_sync where tenant_id = v_b;
  if s.last_run_at <> v_hour_ago or s.last_success_at <> v_hour_ago then
    raise exception 'FAIL: a match or venue failure stamped the run timestamps: %', to_jsonb(s);
  end if;
  if s.last_report->'match:921'->>'error' is distinct from 'federation_match kolo-1-b: HTTP 503'
     or s.last_report->'match:921'->>'at' is null
     or s.last_report->'match:922'->>'error' is distinct from 'federation_match kolo-2-b: HTTP 503'
     or s.last_report->'venue:kuzelna-b'->>'error' is distinct from 'federation_venue: HTTP 404' then
    raise exception 'FAIL: a match or venue failure is not under its own key: %', to_jsonb(s);
  end if;

  perform record_federation_run(v_b, 'match:921', null, null);
  select * into s from federation_sync where tenant_id = v_b;
  if s.last_report ? 'match:921' or not s.last_report ? 'match:922'
     or not s.last_report ? 'venue:kuzelna-b' then
    raise exception 'FAIL: a match success did not remove just its own key: %', to_jsonb(s);
  end if;
  perform record_federation_run(v_b, 'venue:kuzelna-b', null, null);
  select * into s from federation_sync where tenant_id = v_b;
  if s.last_report ? 'venue:kuzelna-b' or not s.last_report ? 'match:922' then
    raise exception 'FAIL: a venue success did not remove just its own key: %', to_jsonb(s);
  end if;
  if s.last_run_at <> v_hour_ago or s.last_success_at <> v_hour_ago then
    raise exception 'FAIL: a match or venue success stamped the run timestamps: %', to_jsonb(s);
  end if;

  select ctid into v_ctid from federation_sync where tenant_id = v_b;
  perform record_federation_run(v_b, 'match:921', null, null);
  perform record_federation_run(v_b, 'venue:kuzelna-b', null, null);
  if (select ctid from federation_sync where tenant_id = v_b) <> v_ctid then
    raise exception 'FAIL: a match or venue success with nothing to remove updated the row';
  end if;

  perform record_federation_run(v_b, v_comp, null, 'federation_competition: HTTP 500');
  select * into s from federation_sync where tenant_id = v_b;
  if s.last_run_at <> now() or s.last_success_at <> v_hour_ago then
    raise exception 'FAIL: a competition failure should stamp last_run_at alone: %', to_jsonb(s);
  end if;
  update federation_sync set last_run_at = v_hour_ago where tenant_id = v_b;
  perform record_federation_run(v_b, v_comp, '{"inserted":2}', null);
  select * into s from federation_sync where tenant_id = v_b;
  if s.last_run_at <> now() or s.last_success_at <> now()
     or s.last_report->v_comp->>'inserted' is distinct from '2'
     or s.last_report->v_comp->>'at' is null or s.last_report->v_comp ? 'error' then
    raise exception 'FAIL: a competition success should stamp both and keep its report: %', to_jsonb(s);
  end if;
  raise notice 'OK: only competitions stamp a run; a match or venue success removes its own key or writes nothing (0045, 0047)';
end $$;

-- 13c. last_error is the newest error among the keys that can still run,
-- and every write drops the dead ones: a competition no active team of the
-- alley plays, a venue neither the alley's nor any of its matches', a
-- match whose slot is gone, whose teams of ours are all switched off, or
-- whose competition no active team of the alley plays (a past season:
-- the competition run that retries a failed match never runs for it).
do $$
declare
  v_a constant uuid := '00000000-0000-0000-0000-00000000000a';
  v_b constant uuid := '00000000-0000-0000-0000-000000000002';
  v_dead constant jsonb := jsonb_build_object(
    'competition:okresni-prebor-2026-2027',
      jsonb_build_object('error', 'okresní', 'at', now() - interval '3 hours'),
    'venue:tj-sokol-brno-iv',
      jsonb_build_object('error', 'kuželna A', 'at', now() - interval '2 hours'),
    'match:923', jsonb_build_object('error', 'jen rezerva', 'at', now() - interval '1 hour'),
    'match:925', jsonb_build_object('error', 'zápas A', 'at', now() - interval '4 hours'),
    'match:927', jsonb_build_object('error', 'loňská soutěž', 'at', now() - interval '30 minutes'),
    -- Its competition is live for B; only the switch (B's, not A's) kills it.
    'match:929', jsonb_build_object('error', 'vypnuté derby', 'at', now() - interval '10 minutes'),
    'discover', jsonb_build_object('at', now()));
  s federation_sync;
begin
  -- For B every error above is dead; the same report is live for A, whose
  -- newest live one is its own venue's (923 is not A's match either).
  if federation_last_error(v_b, v_dead) is not null then
    raise exception 'FAIL: a dead key''s error counted for B: %', federation_last_error(v_b, v_dead);
  end if;
  if federation_last_error(v_a, v_dead) is distinct from 'kuželna A' then
    raise exception 'FAIL: A''s newest live error should be its venue''s: %',
      federation_last_error(v_a, v_dead);
  end if;
  -- 926's names match only the switched-off rezerva, but its slugs say the
  -- active Kuželna B plays it: its job still runs, so its error counts.
  if federation_last_error(v_b, jsonb_build_object('match:926',
       jsonb_build_object('error', 'derby', 'at', now()))) is distinct from 'derby' then
    raise exception 'FAIL: a match an active team of ours plays under an old name was dead';
  end if;
  -- 928 is played by no team of B's: A's switched-off team of that slug is
  -- not B's, so the match is not "switched off" for B and its error counts.
  if federation_last_error(v_b, jsonb_build_object('match:928',
       jsonb_build_object('error', 'cizí tým', 'at', now()))) is distinct from 'cizí tým' then
    raise exception 'FAIL: another alley''s switched-off team killed B''s match';
  end if;

  -- Errors written while their keys were live: the next write drops them.
  perform record_federation_run(v_b, 'match:922', null, null);
  update federation_sync set last_report = last_report || v_dead where tenant_id = v_b;
  perform record_federation_run(v_b, 'discover', '{"teams":2}', null);
  select * into s from federation_sync where tenant_id = v_b;
  if s.last_error is not null
     or s.last_report ?| array['competition:okresni-prebor-2026-2027', 'venue:tj-sokol-brno-iv',
                               'match:923', 'match:925', 'match:927', 'match:929']
     or not s.last_report ?& array['discover', 'competition:krajsky-prebor-2026-2027'] then
    raise exception 'FAIL: a write did not drop exactly the dead keys: %', to_jsonb(s);
  end if;

  -- Four live errors; the newest wins, whichever key it is.
  perform record_federation_run(v_b, 'competition:krajsky-prebor-2026-2027', null, 'přebor');
  perform record_federation_run(v_b, 'match:924', null, 'zápas bez týmu');
  perform record_federation_run(v_b, 'venue:hoste-924', null, 'kuželna hostů');
  perform record_federation_run(v_b, 'match:922', null, 'zápas 922');
  update federation_sync
     set last_report = jsonb_set(jsonb_set(jsonb_set(jsonb_set(last_report,
           '{competition:krajsky-prebor-2026-2027,at}', to_jsonb(now() - interval '4 hours')),
           '{match:924,at}', to_jsonb(now() - interval '3 hours')),
           '{venue:hoste-924,at}', to_jsonb(now() - interval '2 hours')),
           '{match:922,at}', to_jsonb(now() - interval '1 hour'))
   where tenant_id = v_b;
  perform record_federation_run(v_b, 'discover', '{"teams":2}', null);
  if (select last_error from federation_sync where tenant_id = v_b) is distinct from 'zápas 922' then
    raise exception 'FAIL: the newest live error did not win: %',
      (select to_jsonb(f) from federation_sync f where tenant_id = v_b);
  end if;
  -- A newer error of a dead key is dropped and never shows.
  perform record_federation_run(v_b, 'match:923', null, 'jen rezerva');
  select * into s from federation_sync where tenant_id = v_b;
  if s.last_error is distinct from 'zápas 922' or s.last_report ? 'match:923' then
    raise exception 'FAIL: a dead key''s newer error showed or stayed: %', to_jsonb(s);
  end if;
  -- The admin deletes match 922 by hand: its stale key goes with the next write.
  delete from priority_slots where tenant_id = v_b and import_key = 'cka:922';
  perform record_federation_run(v_b, 'discover', '{"teams":2}', null);
  select * into s from federation_sync where tenant_id = v_b;
  if s.last_error is distinct from 'kuželna hostů' or s.last_report ? 'match:922' then
    raise exception 'FAIL: a deleted match''s key was not pruned: %', to_jsonb(s);
  end if;
  perform record_federation_run(v_b, 'venue:hoste-924', null, null);
  if (select last_error from federation_sync where tenant_id = v_b) is distinct from 'zápas bez týmu' then
    raise exception 'FAIL: a match that names no team of ours should still count';
  end if;
  perform record_federation_run(v_b, 'match:924', null, null);
  if (select last_error from federation_sync where tenant_id = v_b) is distinct from 'přebor' then
    raise exception 'FAIL: the competition''s older error should show once the rest cleared';
  end if;
  perform record_federation_run(v_b, 'competition:krajsky-prebor-2026-2027', '{"inserted":0}', null);
  if (select last_error from federation_sync where tenant_id = v_b) is not null then
    raise exception 'FAIL: last_error outlived every error';
  end if;

  -- Competitions run one per tick: a second live competition's success,
  -- and the discovery after it, leave the first one's error standing.
  insert into teams (tenant_id, name, site_slug, competition_slug, active)
  values (v_b, 'Kuželna B dorost', 'kuzelna-b-c', 'krajsky-prebor-dorost-2026-2027', true);
  perform record_federation_run(v_b, 'competition:krajsky-prebor-2026-2027', null, 'přebor');
  perform record_federation_run(v_b, 'competition:krajsky-prebor-dorost-2026-2027',
                                '{"inserted":0}', null);
  perform record_federation_run(v_b, 'discover', '{"teams":3}', null);
  select * into s from federation_sync where tenant_id = v_b;
  if s.last_error is distinct from 'přebor'
     or not s.last_report ?& array['competition:krajsky-prebor-2026-2027',
                                   'competition:krajsky-prebor-dorost-2026-2027'] then
    raise exception 'FAIL: another competition''s success cleared a competition''s error: %',
      to_jsonb(s);
  end if;
  perform record_federation_run(v_b, 'competition:krajsky-prebor-2026-2027', '{"inserted":0}', null);
  delete from teams where tenant_id = v_b and site_slug = 'kuzelna-b-c';

  if (select to_jsonb(f) from federation_sync f where tenant_id = v_a)
     is distinct from current_setting('probe.fed_a_sync')::jsonb then
    raise exception 'FAIL: B''s runs changed A''s sync row';
  end if;
  raise notice 'OK: last_error is the newest error of a live key; dead keys never count and every write drops them, per alley (0045)';
end $$;

-- 13d. A configuration change that kills keys recomputes last_error at
-- once: switching off a competition's only team (update_team — renamed in
-- the same save, which its slots do not follow until the next sync),
-- moving the alley's kuželna (set_federation_sync), a discovery that rolls
-- a team over to the next season (upsert_federation_teams). Only that
-- alley's row.
do $$
declare
  v_a constant uuid := '00000000-0000-0000-0000-00000000000a';
  v_b constant uuid := '00000000-0000-0000-0000-000000000002';
begin
  perform record_federation_run(v_a, 'competition:okresni-prebor-2026-2027', null, 'A: okresní');
  perform record_federation_run(v_b, 'match:921', null, 'B: zápas');
  perform record_federation_run(v_b, 'competition:krajsky-prebor-2026-2027', null, 'B: přebor');
  update federation_sync
     set last_report = jsonb_set(last_report, '{match:921,at}', to_jsonb(now() - interval '1 hour'))
   where tenant_id = v_b;
  perform federation_refresh_error(v_b);
  if (select last_error from federation_sync where tenant_id = v_b) is distinct from 'B: přebor'
     or (select last_error from federation_sync where tenant_id = v_a) is distinct from 'A: okresní' then
    raise exception 'FAIL: fixture — B should show its competition''s error, A its own';
  end if;
  perform set_config('probe.fed_a_sync',
    (select to_jsonb(f)::text from federation_sync f where tenant_id = v_a), true);
  perform set_config('probe.fed_team_b',
    (select id::text from teams where tenant_id = v_b and site_slug = 'kuzelna-b-a'), true);
  perform set_config('probe.fed_team_a_rezerva',
    (select id::text from teams where tenant_id = v_a and site_slug = 'kuzelna-b-b'), true);
end $$;
set local role authenticated;
set local request.jwt.claims =
  '{"sub":"10000000-0000-0000-0000-000000000002","role":"authenticated"}';
do $$
begin
  perform update_team(current_setting('probe.fed_team_b')::uuid, 'Kuželna B muži', null, false);
end $$;
reset role;
do $$
declare
  v_a constant uuid := '00000000-0000-0000-0000-00000000000a';
  v_b constant uuid := '00000000-0000-0000-0000-000000000002';
  s federation_sync;
begin
  select * into s from federation_sync where tenant_id = v_b;
  if s.last_error is not null
     or s.last_report ?| array['competition:krajsky-prebor-2026-2027', 'match:921'] then
    raise exception 'FAIL: switching off the only team left its competition''s or match''s error: %', to_jsonb(s);
  end if;
  perform record_federation_run(v_b, 'venue:kuzelna-b', null, 'B: kuželna');
end $$;
set local role authenticated;
set local request.jwt.claims =
  '{"sub":"10000000-0000-0000-0000-000000000002","role":"authenticated"}';
do $$
begin
  perform update_team(current_setting('probe.fed_team_b')::uuid, 'Kuželna B', null, true);
  perform set_federation_sync('kuzelna-b-nova', false);
end $$;
reset role;
do $$
declare
  v_a constant uuid := '00000000-0000-0000-0000-00000000000a';
  v_b constant uuid := '00000000-0000-0000-0000-000000000002';
  v_team constant jsonb := '{"site_slug":"kuzelna-b-a","site_team_id":9,"site_name":"Kuželna B","competition_slug":"krajsky-prebor-2027-2028","competition_name":"Krajský přebor","name":"Kuželna B","club_id":null}';
  s federation_sync;
begin
  select * into s from federation_sync where tenant_id = v_b;
  if s.last_error is not null or s.last_report ? 'venue:kuzelna-b' then
    raise exception 'FAIL: moving the alley''s kuželna left the old one''s error: %', to_jsonb(s);
  end if;
  perform record_federation_run(v_b, 'match:921', null, 'B: zápas');
  perform record_federation_run(v_b, 'competition:krajsky-prebor-2026-2027', null, 'B: přebor');
  select * into s from federation_sync where tenant_id = v_b;
  if s.last_error is distinct from 'B: přebor' or not s.last_report ? 'match:921' then
    raise exception 'FAIL: fixture — the team is active again, its competition''s and match''s errors should be live';
  end if;
  -- Kuželna B plays the next season: last season's competition and its
  -- matches will never be synced again, the team still active or not.
  perform upsert_federation_teams(v_b, jsonb_build_array(v_team));
  select * into s from federation_sync where tenant_id = v_b;
  if s.last_error is not null
     or s.last_report ?| array['competition:krajsky-prebor-2026-2027', 'match:921'] then
    raise exception 'FAIL: a discovery rollover left the past season''s errors: %', to_jsonb(s);
  end if;
  if (select to_jsonb(f) from federation_sync f where tenant_id = v_a)
     is distinct from current_setting('probe.fed_a_sync')::jsonb then
    raise exception 'FAIL: B''s configuration changes touched A''s sync row';
  end if;
  perform record_federation_run(v_b, 'competition:krajsky-prebor-2027-2028', null, 'B: nová sezóna');
  perform set_config('probe.fed_b_sync',
    (select to_jsonb(f)::text from federation_sync f where tenant_id = v_b), true);
end $$;
set local role authenticated;
set local request.jwt.claims =
  '{"sub":"10000000-0000-0000-0000-000000000001","role":"authenticated"}';
do $$
begin
  perform update_team(current_setting('probe.fed_team_a_rezerva')::uuid,
                      'Kuželna B rezerva', null, false);
end $$;
reset role;
do $$
declare
  v_a constant uuid := '00000000-0000-0000-0000-00000000000a';
  v_b constant uuid := '00000000-0000-0000-0000-000000000002';
begin
  if (select last_error from federation_sync where tenant_id = v_a) is not null then
    raise exception 'FAIL: switching off A''s only okresni-prebor team left its error';
  end if;
  if (select to_jsonb(f) from federation_sync f where tenant_id = v_b)
     is distinct from current_setting('probe.fed_b_sync')::jsonb then
    raise exception 'FAIL: A''s team switch touched B''s sync row';
  end if;
  raise notice 'OK: switching a team off, moving the kuželna and a season rollover clear the dead keys'' errors at once, per alley (0045)';

  -- Back to the fixtures the later sections expect.
  perform record_federation_run(v_b, 'competition:krajsky-prebor-2027-2028', '{"inserted":0}', null);
  delete from priority_slots
   where import_key in ('cka:921', 'cka:923', 'cka:924', 'cka:925', 'cka:926', 'cka:927',
                        'cka:928', 'cka:929')
     and tenant_id in (v_a, v_b);
  delete from teams
   where (tenant_id, site_slug) in ((v_b, 'kuzelna-b-b'), (v_a, 'kuzelna-b-b'), (v_a, 'cizi-tym'),
                                    (v_b, 'kuzelna-b-d'), (v_b, 'kuzelna-b-e'),
                                    (v_a, 'kuzelna-b-d'));
  update teams set competition_slug = 'krajsky-prebor-2026-2027'
   where tenant_id = v_b and site_slug = 'kuzelna-b-a';
  update federation_sync set venue_slug = 'kuzelna-b' where tenant_id = v_b;
end $$;

-- 14. A sync-only column change (video link, venue, site ids, import key)
-- leaves followers' calendars alone: the calendar handler deletes events of
-- past matches, so a needless job would wipe them. An event column still
-- enqueues. A's admin is linked (0023 section) and follows the team here.
do $$
declare
  v_a constant uuid := '00000000-0000-0000-0000-00000000000a';
  v_uid constant uuid := '10000000-0000-0000-0000-000000000001';
  v_id uuid;
begin
  if not exists (select 1 from google_calendar_links
                 where user_id = v_uid and status = 'linked') then
    raise exception 'FAIL: fixture — A''s admin should have a linked calendar';
  end if;
  perform set_calendar_teams_for(v_uid, jsonb_build_array(
    jsonb_build_object('team', 'TJ Sokol Kalendář', 'calendar', 'primary')));
  insert into priority_slots
    (tenant_id, date, starts_at, ends_at, type_id, home_team, away_team,
     prep_minutes, description, is_away, created_by, import_key)
  values
    (v_a, (now() at time zone 'Europe/Prague')::date + 45, '17:00', '20:00',
     (select id from priority_slot_types where tenant_id = v_a and is_match and builtin),
     'KK Jiný', 'TJ Sokol Kalendář', 0, 'Jihomoravská divize · 1. kolo', true, v_uid,
     'rozpis:JmD:1:KK Jiný – TJ Sokol Kalendář')
  returning id into v_id;
  delete from notification_jobs where dedupe_key like 'calendar:%:match:%';

  perform set_config('import.run', 'on', true);
  update priority_slots
     set video_url = 'https://youtu.be/v', venue = 'Kuželna Jinde', venue_slug = 'jinde',
         competition = 'Jihomoravská divize', round = 1, site_match_id = 910,
         site_slug = 'jihomoravska-divize-2026-2027-kolo-1-x-y', import_key = 'cka:910'
   where id = v_id;
  if exists (select 1 from notification_jobs where dedupe_key like 'calendar:%:match:%') then
    raise exception 'FAIL: a sync-only update enqueued a calendar job';
  end if;

  update priority_slots set starts_at = '17:30' where id = v_id;
  perform set_config('import.run', '', true);
  if not exists (select 1 from notification_jobs
                 where dedupe_key = 'calendar:' || v_uid || ':match:' || v_id) then
    raise exception 'FAIL: a re-timed match enqueued no calendar job';
  end if;

  perform set_calendar_teams_for(v_uid, '[]'::jsonb);
  delete from priority_slots where id = v_id;
  delete from notification_jobs where dedupe_key like 'calendar:%:match:%';
  raise notice 'OK: only a change of what the event shows enqueues a calendar job (0045)';
end $$;

-- 14b. A played match's event can only be deleted by the calendar handler:
-- an UPDATE that keeps it in the past (the first run rewriting an old away
-- row's description) enqueues nothing; the same change of a future match does.
do $$
declare
  v_a constant uuid := '00000000-0000-0000-0000-00000000000a';
  v_uid constant uuid := '10000000-0000-0000-0000-000000000001';
  v_today constant date := (now() at time zone 'Europe/Prague')::date;
  v_type uuid;
  v_past uuid;
  v_future uuid;
begin
  perform set_calendar_teams_for(v_uid, jsonb_build_array(
    jsonb_build_object('team', 'TJ Sokol Kalendář', 'calendar', 'primary')));
  select id into v_type from priority_slot_types
   where tenant_id = v_a and is_match and builtin;
  insert into priority_slots
    (tenant_id, date, starts_at, ends_at, type_id, home_team, away_team,
     prep_minutes, description, is_away, created_by, import_key)
  values
    (v_a, v_today - 3, '17:00', '20:00', v_type, 'KK Jiný', 'TJ Sokol Kalendář', 0,
     'JmD 1. kolo · Jinde', true, v_uid, 'rozpis:JmD:1:KK Jiný – TJ Sokol Kalendář')
  returning id into v_past;
  insert into priority_slots
    (tenant_id, date, starts_at, ends_at, type_id, home_team, away_team,
     prep_minutes, description, is_away, created_by, import_key)
  values
    (v_a, v_today + 3, '17:00', '20:00', v_type, 'KK Jiný', 'TJ Sokol Kalendář', 0,
     'JmD 2. kolo · Jinde', true, v_uid, 'rozpis:JmD:2:KK Jiný – TJ Sokol Kalendář')
  returning id into v_future;
  delete from notification_jobs where dedupe_key like 'calendar:%:match:%';

  perform set_config('import.run', 'on', true);
  update priority_slots set description = 'Jihomoravská divize · 1. kolo', import_key = 'cka:920'
   where id = v_past;
  if exists (select 1 from notification_jobs where dedupe_key like 'calendar:%:match:%') then
    raise exception 'FAIL: an update of a played match enqueued a calendar job';
  end if;
  update priority_slots set description = 'Jihomoravská divize · 2. kolo', import_key = 'cka:921'
   where id = v_future;
  perform set_config('import.run', '', true);
  if not exists (select 1 from notification_jobs
                 where dedupe_key = 'calendar:' || v_uid || ':match:' || v_future) then
    raise exception 'FAIL: a future match''s new description enqueued no calendar job';
  end if;

  perform set_calendar_teams_for(v_uid, '[]'::jsonb);
  delete from priority_slots where id in (v_past, v_future);
  delete from notification_jobs where dedupe_key like 'calendar:%:match:%';
  raise notice 'OK: an update that keeps a match in the past enqueues no calendar job (0045)';
end $$;

-- 15. Venues: the server upserts one row per alley and slug; a match
-- detail with an unknown venue, the nightly pass (missing or a week old)
-- and a sync request (the home alley) enqueue its fetch.
do $$
declare
  v_a constant uuid := '00000000-0000-0000-0000-00000000000a';
  v_b constant uuid := '00000000-0000-0000-0000-000000000002';
  v_venue constant jsonb := '{"slug":"jinde","name":"Kuželna Jinde","address":"Jinde 1, Brno","phone":"736435492","email":null,"lat":49.2,"lng":16.6,"sections":[{"title":"Kontakty","items":[{"label":"Správce","value":"Jan"}]}],"clubs":["TJ Jinde"]}';
  v_res constant jsonb := '{"status":"finished","venue":{"slug":"nova-kuzelna","name":"Nová kuželna"},"home_prep":30,"home":null,"away":null,"players":[]}';
  v venues;
begin
  perform upsert_federation_venue(v_a, v_venue);
  update venues set fetched_at = now() - interval '1 day' where tenant_id = v_a;
  perform upsert_federation_venue(v_a, v_venue || '{"name":"Kuželna Jinde 2","phone":null}');
  if (select count(*) from venues where tenant_id = v_a and slug = 'jinde') <> 1 then
    raise exception 'FAIL: upsert_federation_venue duplicated the venue';
  end if;
  select * into v from venues where tenant_id = v_a and slug = 'jinde';
  if v.name <> 'Kuželna Jinde 2' or v.phone is not null or v.address <> 'Jinde 1, Brno'
     or v.lat <> 49.2 or v.lng <> 16.6 or v.email is not null
     or v.sections->0->'items'->0->>'value' <> 'Jan' or v.clubs <> array['TJ Jinde']
     or v.fetched_at <> now() then
    raise exception 'FAIL: upsert_federation_venue stored the venue wrong: %', to_jsonb(v);
  end if;
  perform upsert_federation_venue(v_b, '{"slug":"kuzelna-b","name":"Kuželna B"}');
  select * into v from venues where tenant_id = v_b;
  if v.sections <> '[]'::jsonb or v.clubs <> '{}'::text[] or v.address is not null then
    raise exception 'FAIL: a bare venue did not take the defaults: %', to_jsonb(v);
  end if;

  delete from notification_jobs where kind = 'federation_venue';
  perform apply_federation_result(v_a, 103, v_res);
  if (select count(*) from notification_jobs where kind = 'federation_venue') <> 1
     or not exists (select 1 from notification_jobs
                    where dedupe_key = 'federation_venue:' || v_a || ':nova-kuzelna'
                      and payload = jsonb_build_object('tenant_id', v_a, 'slug', 'nova-kuzelna')
                      and run_at <= now()) then
    raise exception 'FAIL: a match at an unknown venue should enqueue its fetch once';
  end if;
  delete from notification_jobs where kind = 'federation_venue';
  perform apply_federation_result(v_a, 103, v_res || '{"venue":{"slug":"jinde","name":"Kuželna Jinde"}}');
  if exists (select 1 from notification_jobs where kind = 'federation_venue') then
    raise exception 'FAIL: a match at a known venue enqueued a venue fetch';
  end if;
  perform set_config('import.run', '', true);
  raise notice 'OK: upsert_federation_venue inserts then updates; an unknown match venue is fetched once (0045)';
end $$;

-- 15b. A live match refreshed every few minutes must not re-arm a venue
-- fetch that is backing off, nor recreate one that failed within a day.
do $$
declare
  v_a constant uuid := '00000000-0000-0000-0000-00000000000a';
  v_res constant jsonb := '{"status":"finished","venue":{"slug":"chybna","name":"Chybná"},"home_prep":30,"home":null,"away":null,"players":[]}';
  v_later constant timestamptz := now() + interval '10 minutes';
begin
  delete from notification_jobs where kind = 'federation_venue';
  perform apply_federation_result(v_a, 103, v_res);
  update notification_jobs set run_at = v_later, attempts = 2
   where dedupe_key = 'federation_venue:' || v_a || ':chybna';
  perform apply_federation_result(v_a, 103, v_res);
  if (select run_at from notification_jobs
       where dedupe_key = 'federation_venue:' || v_a || ':chybna') is distinct from v_later then
    raise exception 'FAIL: a match refresh re-armed a pending venue job';
  end if;

  delete from notification_jobs where kind = 'federation_venue';
  perform record_federation_run(v_a, 'venue:chybna', null, 'federation_venue: HTTP 404');
  perform apply_federation_result(v_a, 103, v_res);
  if exists (select 1 from notification_jobs where kind = 'federation_venue') then
    raise exception 'FAIL: a venue that failed within a day was enqueued again';
  end if;

  update federation_sync
     set last_report = jsonb_set(last_report, '{venue:chybna,at}',
                                 to_jsonb(now() - interval '25 hours'))
   where tenant_id = v_a;
  perform apply_federation_result(v_a, 103, v_res);
  if not exists (select 1 from notification_jobs
                 where dedupe_key = 'federation_venue:' || v_a || ':chybna') then
    raise exception 'FAIL: a venue whose error is over a day old was not enqueued';
  end if;

  perform apply_federation_result(v_a, 103, v_res || '{"venue":{"slug":"jinde","name":"Kuželna Jinde"}}');
  update federation_sync set last_report = last_report - 'venue:chybna' where tenant_id = v_a;
  delete from notification_jobs where kind = 'federation_venue';
  perform set_config('import.run', '', true);
  raise notice 'OK: a match refresh leaves a pending or recently failed venue fetch alone (0045)';
end $$;

do $$
declare
  v_a constant uuid := '00000000-0000-0000-0000-00000000000a';
  v_b constant uuid := '00000000-0000-0000-0000-000000000002';
begin
  -- A's matches are at jinde (fresh) and nova-kuzelna (missing); its home
  -- alley's row is a week and a day old. B is not enabled.
  insert into priority_slots (tenant_id, date, starts_at, ends_at, type_id, home_team,
                              away_team, created_by, is_away, venue_slug)
  values (v_a, current_date + 30, '10:00', '13:00',
          (select id from priority_slot_types where tenant_id = v_a and is_match and builtin),
          'Host', 'TJ Sokol Brno IV', '10000000-0000-0000-0000-000000000001', true,
          'nova-kuzelna');
  perform upsert_federation_venue(v_a, '{"slug":"tj-sokol-brno-iv","name":"TJ Sokol Brno IV"}');
  update venues set fetched_at = now() - interval '8 days'
   where tenant_id = v_a and slug = 'tj-sokol-brno-iv';
  insert into priority_slots (tenant_id, date, starts_at, ends_at, type_id, home_team,
                              away_team, created_by, venue_slug)
  values (v_b, current_date + 30, '10:00', '13:00',
          (select id from priority_slot_types where tenant_id = v_b and is_match and builtin),
          'Kuželna B', 'Host', '10000000-0000-0000-0000-000000000002', 'cizi-b');
  delete from notification_jobs where kind in ('federation_venue', 'federation_competition');
  perform enqueue_federation_jobs();
  if (select array_agg(payload->>'slug' order by payload->>'slug')
        from notification_jobs where kind = 'federation_venue')
     is distinct from array['nova-kuzelna', 'tj-sokol-brno-iv'] then
    raise exception 'FAIL: the nightly pass should fetch exactly the missing and the stale venue: %',
      (select array_agg(dedupe_key) from notification_jobs where kind = 'federation_venue');
  end if;
  if (select count(distinct run_at) from notification_jobs where kind = 'federation_venue') <> 2
     or (select min(run_at) from notification_jobs where kind = 'federation_venue')
        <= (select max(run_at) from notification_jobs where kind = 'federation_competition') then
    raise exception 'FAIL: venue jobs should come a minute apart after the competition jobs';
  end if;
  if exists (select 1 from notification_jobs where kind = 'federation_venue'
             and payload->>'tenant_id' <> v_a::text) then
    raise exception 'FAIL: a disabled alley got a venue job';
  end if;
  raise notice 'OK: the nightly pass enqueues missing and week-old venues after the competitions (0045)';
end $$;

delete from venues where tenant_id = '00000000-0000-0000-0000-00000000000a'
                     and slug = 'tj-sokol-brno-iv';
delete from notification_jobs where kind = 'federation_venue';
set local role authenticated;
set local request.jwt.claims =
  '{"sub":"10000000-0000-0000-0000-000000000001","role":"authenticated"}';
do $$
begin
  perform request_federation_sync();
  if (select array_agg(slug order by slug) from venues)
     is distinct from array['jinde'] then
    raise exception 'FAIL: the admin should see exactly the alley''s venues';
  end if;
  begin
    insert into venues (tenant_id, slug, name)
    values ('00000000-0000-0000-0000-00000000000a', 'x', 'X');
    raise exception 'FAIL: the admin wrote venues directly';
  exception when insufficient_privilege then null;
  end;
end $$;
reset role;
do $$
begin
  if (select array_agg(dedupe_key) from notification_jobs where kind = 'federation_venue')
     is distinct from array['federation_venue:00000000-0000-0000-0000-00000000000a:tj-sokol-brno-iv'] then
    raise exception 'FAIL: request_federation_sync should enqueue the missing home venue';
  end if;
  delete from notification_jobs where kind = 'federation_venue';
  perform upsert_federation_venue('00000000-0000-0000-0000-00000000000a',
    '{"slug":"tj-sokol-brno-iv","name":"TJ Sokol Brno IV"}');
end $$;
set local role authenticated;
set local request.jwt.claims =
  '{"sub":"10000000-0000-0000-0000-000000000001","role":"authenticated"}';
do $$ begin perform request_federation_sync(); end $$;
reset role;
set local role authenticated;
set local request.jwt.claims =
  '{"sub":"10000000-0000-0000-0000-000000000002","role":"authenticated"}';
do $$
begin
  if (select array_agg(slug) from venues) is distinct from array['kuzelna-b'] then
    raise exception 'FAIL: another alley''s admin should see exactly their own venues';
  end if;
end $$;
reset role;
do $$
begin
  if exists (select 1 from notification_jobs where kind = 'federation_venue') then
    raise exception 'FAIL: request_federation_sync enqueued a home venue it already has';
  end if;
  raise notice 'OK: venues are read-only per alley; a sync request fetches a missing home venue (0045)';
end $$;

-- 7b. With both alleys configured, each admin sees only their own settings.
do $$
begin
  if (select count(distinct tenant_id) from federation_sync
      where tenant_id in ('00000000-0000-0000-0000-00000000000a',
                          '00000000-0000-0000-0000-000000000002')) <> 2 then
    raise exception 'FAIL: fixture — both alleys should have a federation_sync row';
  end if;
end $$;
set local role authenticated;
set local request.jwt.claims =
  '{"sub":"10000000-0000-0000-0000-000000000002","role":"authenticated"}';
do $$
begin
  if (select array_agg(tenant_id) from federation_sync)
     is distinct from array['00000000-0000-0000-0000-000000000002'::uuid] then
    raise exception 'FAIL: another alley''s admin sees our sync settings';
  end if;
end $$;
reset role;
set local role authenticated;
set local request.jwt.claims =
  '{"sub":"10000000-0000-0000-0000-000000000001","role":"authenticated"}';
do $$
begin
  if (select array_agg(tenant_id) from federation_sync)
     is distinct from array['00000000-0000-0000-0000-00000000000a'::uuid] then
    raise exception 'FAIL: the admin sees another alley''s sync settings';
  end if;
  raise notice 'OK: with both alleys configured, each admin sees only their own sync settings (0045)';
end $$;

-- 0047 průvodce nastavením ČKA -----------------------------------------------
reset role;

-- 16. apply_federation_discovery matches every venue club to a club of
-- ours — by site_slug, else by the edge function's name match, which it
-- links — or creates it, and hands the teams their clubs. Its report lists
-- the teams it created (teams_created), so a second run lists none. An
-- alley of its own keeps the colour counts exact.
insert into tenants (id, name)
values ('00000000-0000-0000-0000-00000000000c', 'Kuželna C (0047)');
do $$
declare
  v_c constant uuid := '00000000-0000-0000-0000-00000000000c';
  v_teams constant jsonb := '[
    {"site_slug":"tj-sokol-brno-iv-muzi","site_team_id":1,"site_name":"TJ Sokol Brno IV",
     "competition_slug":"jihomoravska-divize-2026-2027","competition_name":"Jihomoravská divize",
     "name":"TJ Sokol Brno IV A","club_slug":"tj-sokol-brno-iv"},
    {"site_slug":"ks-devitka-brno-b-muzi","site_team_id":2,"site_name":"KS Devítka Brno B",
     "competition_slug":"krajsky-prebor-2026-2027","competition_name":"Krajský přebor",
     "name":"KS Devítka Brno B","club_slug":"ks-devitka-brno"}]';
  v_sokol uuid;
  v_veverky uuid;
  v_devitka uuid;
  v_clubs jsonb;
  r jsonb;
begin
  insert into clubs (tenant_id, name, color) values (v_c, 'Sokol Brno IV', 0)
  returning id into v_sokol;
  insert into clubs (tenant_id, name, color) values (v_c, 'Veverky', 1)
  returning id into v_veverky;
  v_clubs := jsonb_build_array(
    jsonb_build_object('slug', 'tj-sokol-brno-iv', 'name', 'TJ Sokol Brno IV',
                       'match_id', v_sokol),
    jsonb_build_object('slug', 'ks-devitka-brno', 'name', 'KS Devítka Brno',
                       'match_id', null));

  r := apply_federation_discovery(v_c, v_clubs, v_teams);
  if r is distinct from
     '{"created":2,"teams_created":["KS Devítka Brno B","TJ Sokol Brno IV A"],
       "clubs_created":["KS Devítka Brno"],"clubs_linked":["Sokol Brno IV"]}'::jsonb then
    raise exception 'FAIL: the first discovery reported %', r;
  end if;
  if not exists (select 1 from clubs
                  where id = v_sokol and name = 'Sokol Brno IV' and color = 0
                    and site_slug = 'tj-sokol-brno-iv' and site_name = 'TJ Sokol Brno IV') then
    raise exception 'FAIL: the club matched by name was not linked, or lost its name or colour';
  end if;
  select id into v_devitka from clubs
   where tenant_id = v_c and site_slug = 'ks-devitka-brno' and name = 'KS Devítka Brno'
     and site_name = 'KS Devítka Brno' and color = 2;
  if v_devitka is null then
    raise exception 'FAIL: the missing club was not created, linked, in the first free colour: %',
      (select jsonb_agg(to_jsonb(k)) from clubs k where k.tenant_id = v_c);
  end if;
  if (select club_id from teams where tenant_id = v_c and site_slug = 'tj-sokol-brno-iv-muzi')
       is distinct from v_sokol
     or (select club_id from teams where tenant_id = v_c and site_slug = 'ks-devitka-brno-b-muzi')
       is distinct from v_devitka then
    raise exception 'FAIL: the new teams did not get their clubs';
  end if;

  r := apply_federation_discovery(v_c, v_clubs, v_teams);
  if r is distinct from
     '{"created":0,"teams_created":[],"clubs_created":[],
       "clubs_linked":["Sokol Brno IV","KS Devítka Brno"]}'::jsonb
     or (select count(*) from clubs where tenant_id = v_c) <> 3 then
    raise exception 'FAIL: a second discovery was not idempotent: %', r;
  end if;

  -- Renamed and recoloured in the app (upsert_club writes those two only).
  update clubs set name = 'Devítka', color = 5 where id = v_devitka;
  r := apply_federation_discovery(v_c, v_clubs, v_teams);
  if r is distinct from
     '{"created":0,"teams_created":[],"clubs_created":[],
       "clubs_linked":["Sokol Brno IV","Devítka"]}'::jsonb
     or not exists (select 1 from clubs
                     where id = v_devitka and name = 'Devítka' and color = 5
                       and site_slug = 'ks-devitka-brno') then
    raise exception 'FAIL: a renamed club no longer matched its venue club: %', r;
  end if;

  -- The admin's club stands; a team left without one gets its venue club's.
  update teams set club_id = v_veverky
   where tenant_id = v_c and site_slug = 'ks-devitka-brno-b-muzi';
  update teams set club_id = null
   where tenant_id = v_c and site_slug = 'tj-sokol-brno-iv-muzi';
  perform apply_federation_discovery(v_c, v_clubs, v_teams);
  if (select club_id from teams where tenant_id = v_c and site_slug = 'ks-devitka-brno-b-muzi')
       is distinct from v_veverky
     or (select club_id from teams where tenant_id = v_c and site_slug = 'tj-sokol-brno-iv-muzi')
       is distinct from v_sokol then
    raise exception 'FAIL: discovery replaced the admin''s club or left a team without its club';
  end if;

  -- A linked club deleted in the app comes back with the next discovery.
  delete from clubs where id = v_devitka;
  r := apply_federation_discovery(v_c, v_clubs, v_teams);
  if r->'clubs_created' is distinct from '["KS Devítka Brno"]'::jsonb
     or not exists (select 1 from clubs
                     where tenant_id = v_c and site_slug = 'ks-devitka-brno'
                       and name = 'KS Devítka Brno') then
    raise exception 'FAIL: a deleted linked club was not created again: %', r;
  end if;
  raise notice 'OK: discovery links clubs by site_slug, else by name, else creates them once; renames and the admin''s clubs hold (0047)';
end $$;

-- 16b. A created club takes the first palette colour (0–8) no club of the
-- alley uses, else the least used one; a name another club has creates
-- nothing.
do $$
declare
  v_c constant uuid := '00000000-0000-0000-0000-00000000000c';
  r jsonb;
begin
  delete from teams where tenant_id = v_c;
  delete from clubs where tenant_id = v_c;
  insert into clubs (tenant_id, name, color)
  select v_c, 'Barva ' || i, i from generate_series(0, 8) i;
  insert into clubs (tenant_id, name, color)
  values (v_c, 'Barva 0 znovu', 0), (v_c, 'Bez barvy', -1), (v_c, 'Vlastní', 16777216);
  perform apply_federation_discovery(v_c,
    '[{"slug":"kk-novy","name":"KK Nový","match_id":null}]', '[]');
  if (select color from clubs where tenant_id = v_c and site_slug = 'kk-novy')
     is distinct from 1 then
    raise exception 'FAIL: with the palette used up the new club should take the least used colour, 1';
  end if;
  r := apply_federation_discovery(v_c,
    '[{"slug":"kk-barva","name":"Barva 3","match_id":null}]', '[]');
  if r is distinct from
     '{"created":0,"teams_created":[],"clubs_created":[],"clubs_linked":[]}'::jsonb
     or exists (select 1 from clubs where tenant_id = v_c and site_slug = 'kk-barva') then
    raise exception 'FAIL: a venue club whose name another club has was created or linked: %', r;
  end if;
  raise notice 'OK: a created club takes the first free palette colour, else the least used; a taken name creates nothing (0047)';
end $$;

-- 16c. Renaming or recolouring a club in the app keeps its ČKA identity.
insert into clubs (tenant_id, name, color, site_slug, site_name)
values ('00000000-0000-0000-0000-00000000000a', 'Propojený oddíl', 3,
        'kk-propojeny', 'KK Propojený');
set local role authenticated;
set local request.jwt.claims =
  '{"sub":"10000000-0000-0000-0000-000000000001","role":"authenticated"}';
do $$
declare
  v uuid;
begin
  select id into v from clubs where site_slug = 'kk-propojeny';
  perform upsert_club(v, 'Přejmenovaný oddíl', 4);
  if not exists (select 1 from clubs
                  where id = v and name = 'Přejmenovaný oddíl' and color = 4
                    and site_slug = 'kk-propojeny' and site_name = 'KK Propojený') then
    raise exception 'FAIL: upsert_club touched the club''s ČKA identity';
  end if;
  raise notice 'OK: renaming or recolouring a club keeps its site_slug and site_name (0047)';
end $$;
reset role;

-- 16d. Discovery's function is the service's alone.
do $$
declare
  f constant text := 'public.apply_federation_discovery(uuid, jsonb, jsonb)';
begin
  if has_function_privilege('authenticated', f, 'execute')
     or has_function_privilege('anon', f, 'execute')
     or not has_function_privilege('service_role', f, 'execute') then
    raise exception 'FAIL: apply_federation_discovery must be callable by the service only';
  end if;
  raise notice 'OK: apply_federation_discovery is callable by the service only (0047)';
end $$;

-- 16e. The report's teams_created (the card's „Poslední načtení týmů“):
-- the teams this discovery created, by the names the alley has them under
-- (a clash's suffixed one), sorted. A team that was there already is not
-- one, refreshed or not, and a second discovery creates none.
do $$
declare
  v_c constant uuid := '00000000-0000-0000-0000-00000000000c';
  v_clubs constant jsonb := '[{"slug":"kk-blansko","name":"KK Blansko","match_id":null}]';
  v_teams constant jsonb := '[
    {"site_slug":"kk-blansko-c-muzi","site_team_id":5,"site_name":"KK Blansko C",
     "competition_slug":"okresni-prebor-2026-2027","competition_name":"Okresní přebor",
     "name":"KK Blansko C","club_slug":"kk-blansko"},
    {"site_slug":"kk-blansko-b-muzi","site_team_id":4,"site_name":"KK Blansko B",
     "competition_slug":"krajsky-prebor-2026-2027","competition_name":"Krajský přebor",
     "name":"KK Blansko B","club_slug":"kk-blansko"},
    {"site_slug":"kk-blansko-a-muzi","site_team_id":3,"site_name":"KK Blansko A",
     "competition_slug":"krajsky-prebor-2026-2027","competition_name":"Krajský přebor",
     "name":"KK Blansko A","club_slug":"kk-blansko"}]';
  r jsonb;
begin
  delete from teams where tenant_id = v_c;
  -- Last season's C team holds the name this season's comes with.
  insert into teams (tenant_id, name, site_slug)
  values (v_c, 'KK Blansko C', 'kk-blansko-c-muzi-2025');
  -- Discovered before and renamed by the admin: refreshed, not created.
  insert into teams (tenant_id, name, site_slug)
  values (v_c, 'Blansko béčko', 'kk-blansko-b-muzi');

  r := apply_federation_discovery(v_c, v_clubs, v_teams);
  if r->'created' is distinct from '2'::jsonb
     or r->'teams_created' is distinct from
        '["KK Blansko A","KK Blansko C (Okresní přebor)"]'::jsonb then
    raise exception 'FAIL: the first discovery''s teams_created: %', r;
  end if;

  r := apply_federation_discovery(v_c, v_clubs, v_teams);
  if r->'created' is distinct from '0'::jsonb
     or r->'teams_created' is distinct from '[]'::jsonb then
    raise exception 'FAIL: a second discovery listed teams it did not create: %', r;
  end if;
  raise notice 'OK: teams_created lists the teams a discovery created, by their names here, and a second one none (0047)';
end $$;

-- 17. federation_sync_progress: the caller's federation jobs due now or
-- leased, per kind — never a future checkpoint, never another alley's —
-- and for admins only.
do $$
declare
  v_a constant text := '00000000-0000-0000-0000-00000000000a';
  v_b constant text := '00000000-0000-0000-0000-000000000002';
begin
  delete from notification_jobs
   where kind in ('federation_discover', 'federation_competition',
                  'federation_match', 'federation_venue');
  insert into notification_jobs (kind, dedupe_key, payload, run_at, attempts) values
    -- due
    ('federation_discover', 'federation_discover:' || v_a, '{}', now() - interval '1 minute', 0),
    ('federation_competition', 'federation_competition:' || v_a || ':okresni-prebor', '{}', now(), 0),
    ('federation_venue', 'federation_venue:' || v_a || ':kuzelna-a', '{}', now(), 0),
    -- leased: the lease pushed run_at ahead and counted an attempt
    ('federation_match', 'federation_match:' || v_a || ':1', '{}', now() + interval '9 minutes', 1),
    -- not yet due, never leased: a spaced nightly job, a match's checkpoint
    ('federation_competition', 'federation_competition:' || v_a || ':krajsky-prebor', '{}',
     now() + interval '1 minute', 0),
    ('federation_match', 'federation_match:' || v_a || ':2', '{}', now() + interval '1 day', 0),
    -- a retry backing off past the lease window
    ('federation_match', 'federation_match:' || v_a || ':3', '{}', now() + interval '32 minutes', 5),
    -- another alley's, and a job that is no federation job
    ('federation_match', 'federation_match:' || v_b || ':9', '{}', now(), 0),
    ('calendar_sync', 'calendar:' || v_a || ':progress-probe', '{}', now(), 0);
end $$;
set local role authenticated;
set local request.jwt.claims =
  '{"sub":"10000000-0000-0000-0000-000000000001","role":"authenticated"}';
do $$
declare
  v constant jsonb := federation_sync_progress();
begin
  if v is distinct from '{"discover":1,"competitions":1,"matches":1,"venues":1}'::jsonb then
    raise exception 'FAIL: progress should count the alley''s due and leased jobs only: %', v;
  end if;
end $$;
reset role;
set local role authenticated;
set local request.jwt.claims =
  '{"sub":"10000000-0000-0000-0000-000000000002","role":"authenticated"}';
do $$
declare
  v constant jsonb := federation_sync_progress();
begin
  if v is distinct from '{"discover":0,"competitions":0,"matches":1,"venues":0}'::jsonb then
    raise exception 'FAIL: another alley''s admin got our progress: %', v;
  end if;
end $$;
reset role;
set local role authenticated;
set local request.jwt.claims =
  '{"sub":"20000000-0000-0000-0000-000000000001","role":"authenticated"}';
do $$
begin
  begin
    perform federation_sync_progress();
    raise exception 'FAIL: a player read the sync progress';
  exception when others then
    if sqlerrm <> 'not_allowed' then raise; end if;
  end;
end $$;
reset role;
do $$
begin
  if has_function_privilege('anon', 'public.federation_sync_progress()', 'execute')
     or not has_function_privilege('authenticated', 'public.federation_sync_progress()', 'execute') then
    raise exception 'FAIL: federation_sync_progress must be callable by the app only';
  end if;
  raise notice 'OK: federation_sync_progress counts the alley''s due and leased jobs, for admins only (0047)';
end $$;

-- 18. A moved kuželna drops the last discovery's report: it was the old
-- kuželna's, and the setup wizard reads a successful report as "this
-- kuželna's teams are loaded". Saving the same kuželna keeps it. B is not
-- enabled; its kuželna goes back at the end.
do $$
begin
  perform record_federation_run('00000000-0000-0000-0000-000000000002', 'discover',
                                '{"teams":2}', null);
end $$;
set local role authenticated;
set local request.jwt.claims =
  '{"sub":"10000000-0000-0000-0000-000000000002","role":"authenticated"}';
do $$
declare
  v_slug constant text := (select venue_slug from federation_sync);
begin
  perform set_federation_sync(v_slug, false);
  if not (select last_report ? 'discover' from federation_sync) then
    raise exception 'FAIL: saving the same kuželna dropped its discovery report';
  end if;
  perform set_federation_sync('kuzelna-b-jinde', false);
  if (select last_report ? 'discover' from federation_sync) then
    raise exception 'FAIL: a moved kuželna kept the old one''s discovery report';
  end if;
  perform set_federation_sync(v_slug, false);
  raise notice 'OK: a moved kuželna drops the last discovery''s report; the same one keeps it (0047)';
end $$;
reset role;

-- 18b. A moved kuželna drops the old one's discovery job too. A failed one
-- backing off (HTTP 404 for a mistyped address) counts in
-- federation_sync_progress for up to a quarter of an hour: the card would
-- spin over a discovery nobody asked for, then run it for the new kuželna.
-- Saving the same kuželna keeps the job; another alley's job stays.
do $$
declare
  v_a constant text := '00000000-0000-0000-0000-00000000000a';
  v_b constant text := '00000000-0000-0000-0000-000000000002';
begin
  delete from notification_jobs where kind = 'federation_discover';
  -- Both failed twice and back off 4 minutes: attempts > 0, inside the lease.
  insert into notification_jobs (kind, dedupe_key, payload, run_at, attempts) values
    ('federation_discover', 'federation_discover:' || v_a,
     jsonb_build_object('tenant_id', v_a), now() + interval '4 minutes', 2),
    ('federation_discover', 'federation_discover:' || v_b,
     jsonb_build_object('tenant_id', v_b), now() + interval '4 minutes', 2);
end $$;
set local role authenticated;
set local request.jwt.claims =
  '{"sub":"10000000-0000-0000-0000-000000000002","role":"authenticated"}';
do $$
declare
  v_slug constant text := (select venue_slug from federation_sync);
begin
  perform set_federation_sync(v_slug, false);
  if (federation_sync_progress()->>'discover')::integer <> 1 then
    raise exception 'FAIL: saving the same kuželna dropped its discovery job';
  end if;
  perform set_federation_sync('kuzelna-b-jinde', false);
  if (federation_sync_progress()->>'discover')::integer <> 0 then
    raise exception 'FAIL: a moved kuželna kept the old one''s retrying discovery job';
  end if;
  perform set_federation_sync(v_slug, false);
end $$;
reset role;
do $$
begin
  if not exists (select 1 from notification_jobs
                  where dedupe_key = 'federation_discover:00000000-0000-0000-0000-00000000000a') then
    raise exception 'FAIL: moving one alley''s kuželna dropped another alley''s discovery job';
  end if;
  raise notice 'OK: a moved kuželna drops the old one''s discovery job; the same one and other alleys keep theirs (0047)';
end $$;

-- 0048 Klubovna → Kontakty ---------------------------------------------------
reset role;

-- 19. contacts(): the alley's registered players — approved, not the kiosk,
-- not a placeholder, not a visiting superadmin — each with the e-mail and
-- phone they chose to show. Alleys of its own (E, and F next door) keep
-- the lists exact.
insert into tenants (id, name, status) values
  ('00000000-0000-0000-0000-00000000000e', 'Kuželna E (0048)', 'approved'),
  ('00000000-0000-0000-0000-00000000000f', 'Kuželna F (0048)', 'approved');
insert into clubs (id, tenant_id, name, color) values
  ('40000000-0000-0000-0000-0000000000c1', '00000000-0000-0000-0000-00000000000e',
   'Oddíl E', 3);
insert into profiles (id, tenant_id, display_name, nick, email, phone, club_id,
                      role, status, show_email, show_phone, placeholder)
values
  ('40000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-00000000000e',
   'Adam Admin', 'Áďa', 'adam@example.com', '+420777000001',
   '40000000-0000-0000-0000-0000000000c1', 'admin', 'approved', true, true, false),
  ('40000000-0000-0000-0000-000000000002', '00000000-0000-0000-0000-00000000000e',
   'Běla Skrytá', '', 'bela@example.com', '+420777000002',
   null, 'player', 'approved', false, true, false),
  ('40000000-0000-0000-0000-000000000003', '00000000-0000-0000-0000-00000000000e',
   'Cyril Tichý', '', 'cyril@example.com', '+420777000003',
   null, 'player', 'approved', true, false, false),
  ('40000000-0000-0000-0000-000000000004', '00000000-0000-0000-0000-00000000000e',
   'Dana Čekající', '', 'dana@example.com', null,
   null, 'player', 'pending', true, true, false),
  ('40000000-0000-0000-0000-000000000005', '00000000-0000-0000-0000-00000000000e',
   'Kiosk E', '', 'kiosk-e@example.com', null,
   null, 'kiosk', 'approved', true, true, false),
  ('40000000-0000-0000-0000-000000000006', '00000000-0000-0000-0000-00000000000e',
   'Bez účtu E', '', '', null,
   null, 'player', 'approved', true, true, true),
  ('40000000-0000-0000-0000-000000000008', '00000000-0000-0000-0000-00000000000e',
   'Eva Bez Mailu', '', '', null,
   null, 'player', 'approved', true, true, false),
  ('40000000-0000-0000-0000-000000000011', '00000000-0000-0000-0000-00000000000f',
   'Filip Cizí', '', 'filip@example.com', '+420777000011',
   null, 'player', 'approved', true, true, false);
-- A superadmin at home in A, visiting E.
insert into profiles (id, tenant_id, display_name, email, role, status,
                      superadmin, home_tenant_id)
values ('40000000-0000-0000-0000-000000000007', '00000000-0000-0000-0000-00000000000e',
        'Super Návštěva', 'super-e@example.com', 'admin', 'approved',
        true, '00000000-0000-0000-0000-00000000000a');

set local role authenticated;
set local request.jwt.claims =
  '{"sub":"40000000-0000-0000-0000-000000000001","role":"authenticated"}';
do $$
declare
  v_names text[];
  v jsonb;
begin
  select array_agg(t.display_name order by t.o) into v_names
    from contacts() with ordinality
         as t(id, display_name, nick, club_id, club_name, club_color, email, phone, o);
  if v_names is distinct from
     array['Adam Admin', 'Běla Skrytá', 'Cyril Tichý', 'Eva Bez Mailu'] then
    raise exception 'FAIL: contacts should list the alley''s registered players by name, nobody else: %',
      v_names;
  end if;
  select jsonb_object_agg(c.display_name, jsonb_build_object(
           'nick', c.nick, 'club_id', c.club_id, 'club', c.club_name,
           'color', c.club_color, 'email', c.email, 'phone', c.phone))
    into v from contacts() c;
  if v is distinct from '{
       "Adam Admin": {"nick": "Áďa", "club_id": "40000000-0000-0000-0000-0000000000c1",
                      "club": "Oddíl E", "color": 3,
                      "email": "adam@example.com", "phone": "+420777000001"},
       "Běla Skrytá": {"nick": "", "club_id": null, "club": null, "color": -1,
                       "email": null, "phone": "+420777000002"},
       "Cyril Tichý": {"nick": "", "club_id": null, "club": null, "color": -1,
                       "email": "cyril@example.com", "phone": null},
       "Eva Bez Mailu": {"nick": "", "club_id": null, "club": null, "color": -1,
                         "email": null, "phone": null}}'::jsonb then
    raise exception 'FAIL: contacts returned the wrong fields, or a hidden e-mail or phone: %', v;
  end if;
  raise notice 'OK: contacts lists the alley''s registered players; a hidden e-mail or phone is null, the other still shows (0048)';
end $$;
reset role;

-- 19b. A visiting superadmin reads the alley they are in (and is not in
-- it); a player of another alley sees only their own.
set local role authenticated;
set local request.jwt.claims =
  '{"sub":"40000000-0000-0000-0000-000000000007","role":"authenticated"}';
do $$
begin
  if (select array_agg(display_name order by display_name) from contacts())
     is distinct from array['Adam Admin', 'Běla Skrytá', 'Cyril Tichý', 'Eva Bez Mailu'] then
    raise exception 'FAIL: a visiting superadmin should read the visited alley''s contacts';
  end if;
end $$;
set local request.jwt.claims =
  '{"sub":"40000000-0000-0000-0000-000000000011","role":"authenticated"}';
do $$
begin
  if (select array_agg(display_name) from contacts()) is distinct from array['Filip Cizí'] then
    raise exception 'FAIL: another alley''s player saw foreign contacts: %',
      (select array_agg(display_name) from contacts());
  end if;
  raise notice 'OK: a visiting superadmin reads the visited alley; another alley is invisible (0048)';
end $$;
reset role;

-- 19c. The pending player and the kiosk are refused; anon cannot call it.
set local role authenticated;
set local request.jwt.claims =
  '{"sub":"40000000-0000-0000-0000-000000000004","role":"authenticated"}';
do $$
begin
  perform contacts();
  raise exception 'FAIL: a pending player read the contacts';
exception when others then
  if sqlerrm <> 'not_allowed' then raise; end if;
end $$;
set local request.jwt.claims =
  '{"sub":"40000000-0000-0000-0000-000000000005","role":"authenticated"}';
do $$
begin
  perform contacts();
  raise exception 'FAIL: the kiosk read the contacts';
exception when others then
  if sqlerrm <> 'not_allowed' then raise; end if;
end $$;
reset role;
set local role anon;
set local request.jwt.claims = '{"role":"anon"}';
do $$
begin
  perform contacts();
  raise exception 'FAIL: anon read the contacts';
exception when insufficient_privilege then null;
end $$;
reset role;
do $$
begin
  if has_function_privilege('anon', 'public.contacts()', 'execute')
     or not has_function_privilege('authenticated', 'public.contacts()', 'execute') then
    raise exception 'FAIL: contacts must be callable by signed-in users only';
  end if;
  raise notice 'OK: the pending player and the kiosk get not_allowed; anon cannot call contacts (0048)';
end $$;

-- 19d. A player writes their own phone and switches — nobody else's, not
-- even the alley's admin — and the phone must be E.164.
set local role authenticated;
set local request.jwt.claims =
  '{"sub":"40000000-0000-0000-0000-000000000002","role":"authenticated"}';
do $$
declare
  n integer;
begin
  update profiles set phone = '+420777999002', show_email = true, show_phone = false
   where id = auth.uid();
  if not exists (select 1 from profiles
                  where id = auth.uid() and phone = '+420777999002'
                    and show_email and not show_phone) then
    raise exception 'FAIL: a player could not update their own phone and switches';
  end if;
  update profiles set phone = '+420777999001', show_email = false
   where id = '40000000-0000-0000-0000-000000000001';
  get diagnostics n = row_count;
  if n <> 0 then
    raise exception 'FAIL: a player updated another player''s contact';
  end if;
  begin
    update profiles set phone = '777123456' where id = auth.uid();
    raise exception 'FAIL: a phone without the country code was stored';
  exception when check_violation then null;
  end;
  begin
    update profiles set phone = '+0777123456' where id = auth.uid();
    raise exception 'FAIL: a phone starting +0 was stored';
  exception when check_violation then null;
  end;
  begin
    update profiles set phone = '+4207771234567890' where id = auth.uid();
    raise exception 'FAIL: a 16-digit phone was stored';
  exception when check_violation then null;
  end;
  begin
    update profiles set phone = '+1234567' where id = auth.uid();
    raise exception 'FAIL: a 7-digit phone was stored';
  exception when check_violation then null;
  end;
  -- The bounds the app's e164Pattern (lib/domain/phone.dart) also keeps.
  update profiles set phone = '+12345678' where id = auth.uid();
  update profiles set phone = '+123456789012345' where id = auth.uid();
  update profiles set phone = '+420777999002' where id = auth.uid();
end $$;
set local request.jwt.claims =
  '{"sub":"40000000-0000-0000-0000-000000000001","role":"authenticated"}';
do $$
declare
  n integer;
begin
  update profiles set phone = null, show_phone = true
   where id = '40000000-0000-0000-0000-000000000002';
  get diagnostics n = row_count;
  if n <> 0 or not exists (select 1 from profiles
                            where id = '40000000-0000-0000-0000-000000000002'
                              and phone = '+420777999002' and not show_phone) then
    raise exception 'FAIL: the admin changed a player''s phone or switch';
  end if;
  raise notice 'OK: a player updates only their own phone and switches; the phone must be E.164 (0048)';
end $$;
reset role;

-- 19e. register_profile takes the phone (E.164 or blank) and refuses any
-- other; an old-style call without p_phone still resolves. So does
-- create_tenant_and_register, which also takes the founder's phone and,
-- when it is bad, creates no tenant.
set local role authenticated;
set local request.jwt.claims =
  '{"sub":"40000000-0000-0000-0000-000000000021","role":"authenticated"}';
do $$
declare
  v_p profiles;
begin
  v_p := register_profile('Nováček s telefonem', '00000000-0000-0000-0000-00000000000e',
                          null, '', '+420777000021');
  if v_p.phone is distinct from '+420777000021' or v_p.status <> 'pending'
     or not v_p.show_email or not v_p.show_phone then
    raise exception 'FAIL: register_profile did not store the phone: %', to_jsonb(v_p);
  end if;
end $$;
set local request.jwt.claims =
  '{"sub":"40000000-0000-0000-0000-000000000022","role":"authenticated"}';
do $$
begin
  begin
    perform register_profile('Špatné číslo', '00000000-0000-0000-0000-00000000000e',
                             null, '', '777000022');
    raise exception 'FAIL: register_profile stored a phone without the country code';
  exception when others then
    if sqlerrm <> 'invalid_phone' then raise; end if;
  end;
  if exists (select 1 from profiles where id = auth.uid()) then
    raise exception 'FAIL: a refused registration left a profile behind';
  end if;
end $$;
set local request.jwt.claims =
  '{"sub":"40000000-0000-0000-0000-000000000023","role":"authenticated"}';
do $$
declare
  v_p profiles;
begin
  v_p := register_profile(p_display_name => 'Starý klient',
                          p_tenant_id => '00000000-0000-0000-0000-00000000000e',
                          p_club_id => null, p_nick => 'Starý');
  if v_p.id is null or v_p.phone is not null then
    raise exception 'FAIL: a call without p_phone did not register: %', to_jsonb(v_p);
  end if;
end $$;
set local request.jwt.claims =
  '{"sub":"40000000-0000-0000-0000-000000000024","role":"authenticated"}';
do $$
declare
  v_p profiles;
begin
  v_p := register_profile('Prázdný telefon', '00000000-0000-0000-0000-00000000000e',
                          null, '', '   ');
  if v_p.phone is not null then
    raise exception 'FAIL: a blank phone was stored as %', v_p.phone;
  end if;
end $$;
set local request.jwt.claims =
  '{"sub":"40000000-0000-0000-0000-000000000025","role":"authenticated"}';
do $$
declare
  v_p profiles;
begin
  -- Named, exactly as the 1.2.x app sends it through PostgREST.
  v_p := create_tenant_and_register(p_tenant_name => 'Kuželna G (0048)',
                                    p_display_name => 'Zakladatel G',
                                    p_nick => '');
  if v_p.role <> 'admin' or v_p.status <> 'approved' or v_p.phone is not null then
    raise exception 'FAIL: create_tenant_and_register broke with the new register_profile: %',
      to_jsonb(v_p);
  end if;
end $$;
set local request.jwt.claims =
  '{"sub":"40000000-0000-0000-0000-000000000026","role":"authenticated"}';
do $$
declare
  v_p profiles;
begin
  v_p := create_tenant_and_register('Kuželna H (0048)', 'Zakladatel H', 'Zak',
                                    '+420777000026');
  if v_p.role <> 'admin' or v_p.status <> 'approved'
     or v_p.phone is distinct from '+420777000026' or v_p.nick <> 'Zak' then
    raise exception 'FAIL: create_tenant_and_register did not store the founder''s phone: %',
      to_jsonb(v_p);
  end if;
end $$;
set local request.jwt.claims =
  '{"sub":"40000000-0000-0000-0000-000000000027","role":"authenticated"}';
do $$
begin
  begin
    perform create_tenant_and_register('Kuželna I (0048)', 'Zakladatel I', '',
                                       '777000027');
    raise exception 'FAIL: create_tenant_and_register took a phone without the country code';
  exception when others then
    if sqlerrm <> 'invalid_phone' then raise; end if;
  end;
  if exists (select 1 from profiles where id = auth.uid()) then
    raise exception 'FAIL: a refused founding left a profile behind';
  end if;
end $$;
reset role;
do $$
begin
  if exists (select 1 from tenants where name = 'Kuželna I (0048)') then
    raise exception 'FAIL: a refused founding left its tenant behind';
  end if;
  if to_regprocedure('public.create_tenant_and_register(text, text, text)') is not null then
    raise exception 'FAIL: the three-argument create_tenant_and_register is still there';
  end if;
  if not has_function_privilege('authenticated',
       'public.create_tenant_and_register(text, text, text, text)', 'execute') then
    raise exception 'FAIL: the app lost create_tenant_and_register';
  end if;
  raise notice 'OK: create_tenant_and_register stores the founder''s phone in the same transaction; a bad one founds nothing (0048)';
end $$;
do $$
begin
  if to_regprocedure('public.register_profile(text, uuid, uuid, text)') is not null then
    raise exception 'FAIL: the four-argument register_profile is still there';
  end if;
  if not has_function_privilege('authenticated',
       'public.register_profile(text, uuid, uuid, text, text)', 'execute')
     or not has_column_privilege('authenticated', 'public.profiles', 'phone', 'update')
     or not has_column_privilege('authenticated', 'public.profiles', 'show_email', 'update')
     or not has_column_privilege('authenticated', 'public.profiles', 'show_phone', 'update') then
    raise exception 'FAIL: the app lost register_profile or the contact columns';
  end if;
  raise notice 'OK: register_profile stores a phone and refuses a bad one; calls without p_phone still work (0048)';
end $$;

-- 0050 služby na kantýně — data a správa -------------------------------------
reset role;

-- 20. Fixtures in tenant A, next to the 0044 players (Petr, Jana, Karel) and
-- the kiosk: a pending player, a placeholder and the account it later
-- merges into. Every date hangs off Prague today + 100, clear of the other
-- sections; the section deletes its duty rows at the end.
do $$
declare
  v_a constant uuid := '00000000-0000-0000-0000-00000000000a';
begin
  insert into profiles (id, tenant_id, display_name, email, role, status)
  values
    ('50000000-0000-0000-0000-000000000001', v_a, 'Pavla Čekající',
     'duty-pending@example.com', 'player', 'pending'),
    ('50000000-0000-0000-0000-000000000003', v_a, 'Dušan Účet',
     'duty-dusan@example.com', 'player', 'approved');
  insert into profiles (id, tenant_id, display_name, role, status, placeholder)
  values ('50000000-0000-0000-0000-000000000002', v_a, 'Dušan bez účtu',
          'player', 'approved', true);
  perform set_config('probe.duty_d0',
    ((now() at time zone 'Europe/Prague')::date + 100)::text, true);
end $$;

-- 20a. Shape and privileges: three tables the app may only read (RLS on,
-- select for authenticated, nothing for anon), the admin's seven RPCs
-- callable by the app and not by anon, the overlap guard, the reminder
-- settings off with a one-day lead by default (the column defaults and the
-- suite's own alleys, never a real alley's row).
do $$
declare
  v_t text;
  v_f text;
begin
  foreach v_t in array array['duty_periods', 'duty_assignments', 'duty_seasons'] loop
    if not (select relrowsecurity from pg_class
             where oid = ('public.' || v_t)::regclass) then
      raise exception 'FAIL: RLS is off on %', v_t;
    end if;
    if not has_table_privilege('authenticated', 'public.' || v_t, 'select')
       or has_table_privilege('authenticated', 'public.' || v_t, 'insert')
       or has_table_privilege('authenticated', 'public.' || v_t, 'update')
       or has_table_privilege('authenticated', 'public.' || v_t, 'delete')
       or has_table_privilege('anon', 'public.' || v_t, 'select') then
      raise exception 'FAIL: % must be select-only for the app and closed to anon', v_t;
    end if;
  end loop;
  foreach v_f in array array[
      'duty_generate(date, smallint, date)',
      'duty_period_save(uuid, date, date, text)',
      'duty_period_delete(uuid)',
      'duty_periods_delete_unassigned(date)',
      'duty_set_assignees(uuid, uuid[])',
      'duty_season_start(date, text)',
      'duty_season_delete(date)'] loop
    if has_function_privilege('anon', 'public.' || v_f, 'execute') then
      raise exception 'FAIL: anon may execute %', v_f;
    end if;
    if not has_function_privilege('authenticated', 'public.' || v_f, 'execute') then
      raise exception 'FAIL: the app cannot call %', v_f;
    end if;
    if not (select prosecdef from pg_proc
             where oid = ('public.' || v_f)::regprocedure) then
      raise exception 'FAIL: % is not security definer', v_f;
    end if;
  end loop;
  if not exists (select 1 from pg_constraint
                 where conname = 'duty_periods_no_overlap' and contype = 'x') then
    raise exception 'FAIL: duty_periods has no exclusion constraint against overlaps';
  end if;
  -- A real alley (on dev, or on prod inside BEGIN…ROLLBACK) may well have
  -- switched its reminder on.
  if (select array_agg(column_name || '=' || column_default order by column_name)
        from information_schema.columns
       where table_schema = 'public' and table_name = 'schedule_settings'
         and column_name in ('duty_reminder_enabled', 'duty_reminder_days'))
     is distinct from array['duty_reminder_days=1', 'duty_reminder_enabled=false']
     or (select count(*) from schedule_settings
          where tenant_id in ('00000000-0000-0000-0000-00000000000a',
                              '00000000-0000-0000-0000-000000000002')
            and not duty_reminder_enabled and duty_reminder_days = 1) <> 2 then
    raise exception 'FAIL: the duty reminder must start off, with a one-day lead';
  end if;
  raise notice 'OK: duty tables are read-only for the app, the admin RPCs are the app''s and not anon''s (0050)';
end $$;

-- 20b. The generator: periods [s, s + days − 1] from p_from on, the last
-- one clipped to p_until; a period overlapping an existing one is skipped
-- whole, so running it again creates nothing.
set local role authenticated;
set local request.jwt.claims =
  '{"sub":"10000000-0000-0000-0000-000000000001","role":"authenticated"}';
do $$
declare
  v_d0 constant date := current_setting('probe.duty_d0')::date;
  v jsonb;
  v_got text;
  v_id uuid;
begin
  v := duty_generate(v_d0, 7::smallint, v_d0 + 19);
  if v is distinct from '{"created": 3, "skipped": 0}'::jsonb then
    raise exception 'FAIL: three weeks of 7-day duties should create 3: %', v;
  end if;
  select string_agg(format('%s..%s', starts_on - v_d0, ends_on - v_d0), ' '
                    order by starts_on)
    into v_got from duty_periods;
  if v_got is distinct from '0..6 7..13 14..19' then
    raise exception 'FAIL: the generated periods are wrong (the last one clipped to p_until): %', v_got;
  end if;
  if exists (select 1 from duty_periods
             where tenant_id <> current_tenant_id()
                or created_by is distinct from auth.uid() or note <> '') then
    raise exception 'FAIL: a generated period has the wrong tenant, author or note';
  end if;
  v := duty_generate(v_d0, 7::smallint, v_d0 + 19);
  if v is distinct from '{"created": 0, "skipped": 3}'::jsonb then
    raise exception 'FAIL: generating the same range again should skip all 3: %', v;
  end if;
  v := duty_generate(v_d0 + 14, 7::smallint, v_d0 + 30);
  if v is distinct from '{"created": 2, "skipped": 1}'::jsonb then
    raise exception 'FAIL: a partly overlapping period should be skipped, the rest created: %', v;
  end if;
  select string_agg(format('%s..%s', starts_on - v_d0, ends_on - v_d0), ' '
                    order by starts_on)
    into v_got from duty_periods;
  if v_got is distinct from '0..6 7..13 14..19 21..27 28..30' then
    raise exception 'FAIL: the periods after the second run are wrong: %', v_got;
  end if;

  begin
    perform duty_generate(v_d0, 0::smallint, v_d0 + 7);
    raise exception 'FAIL: a 0-day rhythm was accepted';
  exception when others then
    if sqlerrm <> 'invalid_days' then raise; end if;
  end;
  begin
    perform duty_generate(v_d0, 32::smallint, v_d0 + 70);
    raise exception 'FAIL: a 32-day rhythm was accepted';
  exception when others then
    if sqlerrm <> 'invalid_days' then raise; end if;
  end;
  begin
    perform duty_generate(v_d0, null, v_d0 + 7);
    raise exception 'FAIL: a rhythm without a length was accepted';
  exception when others then
    if sqlerrm <> 'invalid_days' then raise; end if;
  end;
  begin
    perform duty_generate(v_d0 + 7, 7::smallint, v_d0 + 6);
    raise exception 'FAIL: an end before the start was accepted';
  exception when others then
    if sqlerrm <> 'invalid_range' then raise; end if;
  end;
  begin
    perform duty_generate(v_d0 + 3000, 31::smallint, v_d0 + 3400);
    raise exception 'FAIL: a range of 401 days was accepted';
  exception when others then
    if sqlerrm <> 'invalid_range' then raise; end if;
  end;
  -- 400 days, both ends counted, is the most.
  v := duty_generate(v_d0 + 3000, 31::smallint, v_d0 + 3399);
  if v is distinct from '{"created": 13, "skipped": 0}'::jsonb
     or (select max(ends_on) from duty_periods) <> v_d0 + 3399 then
    raise exception 'FAIL: a 400-day range should give 13 periods ending on p_until: %', v;
  end if;
  if duty_periods_delete_unassigned(v_d0 + 3000) <> 13 then
    raise exception 'FAIL: the 13 unassigned far periods were not deleted';
  end if;

  select id into strict v_id from duty_periods where starts_on = v_d0;
  perform set_config('probe.duty_p1', v_id::text, true);
  select id into strict v_id from duty_periods where starts_on = v_d0 + 7;
  perform set_config('probe.duty_p2', v_id::text, true);
  raise notice 'OK: the generator creates, clips the last period and skips overlaps; days 1–31, at most 400 days (0050)';
end $$;

-- 20c. One period by hand: insert, edit, the overlap guard (touching is
-- fine), at most 62 days, the order of the dates, a note of 80 characters
-- at most, an unknown id; delete.
do $$
declare
  v_d0 constant date := current_setting('probe.duty_d0')::date;
  v_id uuid;
  v_other uuid;
begin
  v_id := duty_period_save(null, v_d0 + 40, v_d0 + 46, '  Pouť  ');
  if not exists (select 1 from duty_periods
                 where id = v_id and starts_on = v_d0 + 40 and ends_on = v_d0 + 46
                   and note = 'Pouť' and created_by = auth.uid()
                   and tenant_id = current_tenant_id()) then
    raise exception 'FAIL: duty_period_save did not insert the period as given';
  end if;
  -- Two statements: one would read the table as it was before the call.
  v_other := duty_period_save(v_id, v_d0 + 41, v_d0 + 47, null);
  if v_other <> v_id
     or not exists (select 1 from duty_periods
                    where id = v_id and starts_on = v_d0 + 41
                      and ends_on = v_d0 + 47 and note = '') then
    raise exception 'FAIL: duty_period_save did not edit the period in place';
  end if;
  begin
    perform duty_period_save(null, v_d0 + 5, v_d0 + 8, '');
    raise exception 'FAIL: an overlapping period was inserted';
  exception when others then
    if sqlerrm <> 'duty_overlap' then raise; end if;
  end;
  begin
    perform duty_period_save(v_id, v_d0 + 28, v_d0 + 35, '');
    raise exception 'FAIL: a period was moved onto another';
  exception when others then
    if sqlerrm <> 'duty_overlap' then raise; end if;
  end;
  -- Between 28..30 and 41..47, touching both: no overlap.
  v_other := duty_period_save(null, v_d0 + 31, v_d0 + 40, '');
  perform duty_period_delete(v_other);
  if exists (select 1 from duty_periods where id = v_other) then
    raise exception 'FAIL: duty_period_delete left the period';
  end if;
  begin
    perform duty_period_delete(v_other);
    raise exception 'FAIL: a deleted period was deleted again';
  exception when others then
    if sqlerrm <> 'unknown_period' then raise; end if;
  end;
  begin
    perform duty_period_save(null, v_d0 + 100, v_d0 + 169, '');
    raise exception 'FAIL: a 70-day duty was accepted';
  exception when others then
    if sqlerrm <> 'duty_too_long' then raise; end if;
  end;
  begin
    perform duty_period_save(null, v_d0 + 100, v_d0 + 162, '');
    raise exception 'FAIL: a 63-day duty was accepted';
  exception when others then
    if sqlerrm <> 'duty_too_long' then raise; end if;
  end;
  v_other := duty_period_save(null, v_d0 + 100, v_d0 + 161, '');  -- 62 days
  perform duty_period_delete(v_other);
  begin
    perform duty_period_save(null, v_d0 + 50, v_d0 + 49, '');
    raise exception 'FAIL: a duty ending before it starts was accepted';
  exception when others then
    if sqlerrm <> 'invalid_range' then raise; end if;
  end;
  begin
    perform duty_period_save(null, null, v_d0 + 49, '');
    raise exception 'FAIL: a duty without a start was accepted';
  exception when others then
    if sqlerrm <> 'invalid_range' then raise; end if;
  end;
  begin
    perform duty_period_save(gen_random_uuid(), v_d0 + 50, v_d0 + 51, '');
    raise exception 'FAIL: an unknown period was edited';
  exception when others then
    if sqlerrm <> 'unknown_period' then raise; end if;
  end;
  begin
    perform duty_period_save(null, v_d0 + 50, v_d0 + 51, repeat('x', 81));
    raise exception 'FAIL: an 81-character note was accepted';
  exception when check_violation then null;
  end;
  v_other := duty_period_save(null, v_d0 + 50, v_d0 + 51, repeat('x', 80));
  perform duty_period_delete(v_other);
  -- Not even the admin writes the tables directly.
  begin
    insert into duty_periods (tenant_id, starts_on, ends_on)
      values (current_tenant_id(), v_d0 + 60, v_d0 + 61);
    raise exception 'FAIL: the admin inserted a period past the RPCs';
  exception when insufficient_privilege then null;
  end;
  raise notice 'OK: duty_period_save inserts and edits; overlap, length, order and unknown id refused; delete works (0050)';
end $$;

-- 20d. Tenant B plans the very same week — overlaps are per alley — and
-- reaches none of tenant A's periods or players.
set local request.jwt.claims =
  '{"sub":"10000000-0000-0000-0000-000000000002","role":"authenticated"}';
do $$
declare
  v_d0 constant date := current_setting('probe.duty_d0')::date;
  v_p1 constant uuid := current_setting('probe.duty_p1')::uuid;
  v_b uuid;
begin
  v_b := duty_period_save(null, v_d0, v_d0 + 6, 'B');
  perform duty_set_assignees(v_b, array['20000000-0000-0000-0000-0000000000b1']::uuid[]);
  if (select count(*) from duty_periods) <> 1
     or (select count(*) from duty_assignments) <> 1 then
    raise exception 'FAIL: tenant B should see its own duty only';
  end if;
  begin
    perform duty_set_assignees(v_b, array['20000000-0000-0000-0000-000000000001']::uuid[]);
    raise exception 'FAIL: tenant B assigned a player of tenant A';
  exception when others then
    if sqlerrm <> 'unknown_player' then raise; end if;
  end;
  begin
    perform duty_set_assignees(v_p1, array['20000000-0000-0000-0000-0000000000b1']::uuid[]);
    raise exception 'FAIL: tenant B assigned to a period of tenant A';
  exception when others then
    if sqlerrm <> 'unknown_period' then raise; end if;
  end;
  begin
    perform duty_period_save(v_p1, v_d0, v_d0 + 5, 'únos');
    raise exception 'FAIL: tenant B edited a period of tenant A';
  exception when others then
    if sqlerrm <> 'unknown_period' then raise; end if;
  end;
  begin
    perform duty_period_delete(v_p1);
    raise exception 'FAIL: tenant B deleted a period of tenant A';
  exception when others then
    if sqlerrm <> 'unknown_period' then raise; end if;
  end;
  if duty_periods_delete_unassigned(v_d0 - 1000) <> 0 then
    raise exception 'FAIL: tenant B''s bulk delete reached tenant A';
  end if;
  raise notice 'OK: another alley may plan the same dates and reaches nothing of ours (0050)';
end $$;

-- 20e. Assignees: a player and a placeholder together, the set replaced
-- whole; the kiosk, a pending player, another alley's player and nobody at
-- all refused without touching the set; unassigned periods from a date on
-- deleted in one step, a deleted period taking its assignees with it.
set local request.jwt.claims =
  '{"sub":"10000000-0000-0000-0000-000000000001","role":"authenticated"}';
do $$
declare
  v_d0 constant date := current_setting('probe.duty_d0')::date;
  v_p1 constant uuid := current_setting('probe.duty_p1')::uuid;
  v_p2 constant uuid := current_setting('probe.duty_p2')::uuid;
  v_petr constant uuid := '20000000-0000-0000-0000-000000000001';
  v_jana constant uuid := '20000000-0000-0000-0000-000000000002';
  v_karel constant uuid := '20000000-0000-0000-0000-000000000003';
  v_ph constant uuid := '50000000-0000-0000-0000-000000000002';
  v_dusan constant uuid := '50000000-0000-0000-0000-000000000003';
  v_bad uuid;
  v_p3 uuid;
  v_got text;
begin
  perform duty_set_assignees(v_p1, array[v_petr, v_ph, v_petr]);
  if (select array_agg(user_id order by user_id) from duty_assignments
       where period_id = v_p1) is distinct from array[v_petr, v_ph] then
    raise exception 'FAIL: a player and a placeholder should both be assigned, once each';
  end if;
  if exists (select 1 from duty_assignments
             where period_id = v_p1
               and (tenant_id <> current_tenant_id()
                    or assigned_by is distinct from auth.uid())) then
    raise exception 'FAIL: an assignment has the wrong tenant or author';
  end if;
  perform duty_set_assignees(v_p2, array[v_jana, v_karel]);
  perform duty_set_assignees(v_p2, array[v_karel, v_dusan]);
  if (select array_agg(user_id order by user_id) from duty_assignments
       where period_id = v_p2) is distinct from array[v_karel, v_dusan] then
    raise exception 'FAIL: duty_set_assignees did not replace the set';
  end if;
  foreach v_bad in array array[
      '10000000-0000-0000-0000-000000000006',   -- the kiosk
      '50000000-0000-0000-0000-000000000001',   -- pending
      '20000000-0000-0000-0000-0000000000b1',   -- tenant B
      gen_random_uuid()]::uuid[] loop
    begin
      perform duty_set_assignees(v_p1, array[v_jana, v_bad]);
      raise exception 'FAIL: % was assigned', v_bad;
    exception when others then
      if sqlerrm <> 'unknown_player' then raise; end if;
    end;
  end loop;
  begin
    perform duty_set_assignees(v_p1, array[v_jana, null]);
    raise exception 'FAIL: a null player was assigned';
  exception when others then
    if sqlerrm <> 'unknown_player' then raise; end if;
  end;
  if (select array_agg(user_id order by user_id) from duty_assignments
       where period_id = v_p1) is distinct from array[v_petr, v_ph] then
    raise exception 'FAIL: a refused duty_set_assignees changed the set';
  end if;
  begin
    perform duty_set_assignees(gen_random_uuid(), array[v_jana]);
    raise exception 'FAIL: assigned to an unknown period';
  exception when others then
    if sqlerrm <> 'unknown_period' then raise; end if;
  end;

  -- 14..19 is the only unassigned period before d0 + 20; everything
  -- unassigned from d0 + 20 on (21..27, 28..30, 41..47) goes.
  if duty_periods_delete_unassigned(v_d0 + 20) <> 3 then
    raise exception 'FAIL: duty_periods_delete_unassigned should delete 3';
  end if;
  select string_agg(format('%s..%s', starts_on - v_d0, ends_on - v_d0), ' '
                    order by starts_on)
    into v_got from duty_periods;
  if v_got is distinct from '0..6 7..13 14..19' then
    raise exception 'FAIL: the wrong periods survived the bulk delete: %', v_got;
  end if;
  select id into v_p3 from duty_periods where starts_on = v_d0 + 14;
  perform duty_set_assignees(v_p3, array[v_jana]);
  if duty_periods_delete_unassigned(v_d0) <> 0 then
    raise exception 'FAIL: the bulk delete took an assigned period';
  end if;
  perform duty_set_assignees(v_p3, '{}');
  if exists (select 1 from duty_assignments where period_id = v_p3) then
    raise exception 'FAIL: an empty list did not clear the period';
  end if;
  perform duty_set_assignees(v_p3, array[v_jana]);
  perform duty_period_delete(v_p3);
  if exists (select 1 from duty_assignments where period_id = v_p3) then
    raise exception 'FAIL: deleting a period left its assignees';
  end if;
  raise notice 'OK: assignees are replaced whole; kiosk, pending, foreign and unknown players refused; unassigned periods deleted in bulk (0050)';
end $$;

-- 20f. Seasons: a boundary per start, each after the newest; only the
-- newest can be taken back.
do $$
declare
  v_today constant date := (now() at time zone 'Europe/Prague')::date;
begin
  perform duty_season_start(v_today - 30, '  2026/27 ');
  if not exists (select 1 from duty_seasons
                 where tenant_id = current_tenant_id() and started_on = v_today - 30
                   and name = '2026/27' and created_by = auth.uid()) then
    raise exception 'FAIL: duty_season_start did not store the boundary';
  end if;
  begin
    perform duty_season_start(v_today, '   ');
    raise exception 'FAIL: a season without a name was started';
  exception when others then
    if sqlerrm <> 'empty_name' then raise; end if;
  end;
  begin
    perform duty_season_start(v_today, null);
    raise exception 'FAIL: a season with a null name was started';
  exception when others then
    if sqlerrm <> 'empty_name' then raise; end if;
  end;
  begin
    perform duty_season_start(v_today, repeat('x', 41));
    raise exception 'FAIL: a 41-character season name was accepted';
  exception when check_violation then null;
  end;
  begin
    perform duty_season_start(v_today - 30, 'Znovu');
    raise exception 'FAIL: a second season on the same day was started';
  exception when others then
    if sqlerrm <> 'season_order' then raise; end if;
  end;
  begin
    perform duty_season_start(v_today - 31, 'Dřív');
    raise exception 'FAIL: a season before the newest one was started';
  exception when others then
    if sqlerrm <> 'season_order' then raise; end if;
  end;
  perform duty_season_start(v_today + 10, '2027/28');
  begin
    perform duty_season_delete(v_today - 30);
    raise exception 'FAIL: an older season was deleted';
  exception when others then
    if sqlerrm <> 'not_newest' then raise; end if;
  end;
  begin
    perform duty_season_delete(v_today + 11);
    raise exception 'FAIL: a date that is no boundary was deleted';
  exception when others then
    if sqlerrm <> 'not_newest' then raise; end if;
  end;
  perform duty_season_delete(v_today + 10);
  perform duty_season_delete(v_today - 30);
  if exists (select 1 from duty_seasons) then
    raise exception 'FAIL: undoing both seasons left a boundary';
  end if;
  begin
    perform duty_season_delete(v_today - 30);
    raise exception 'FAIL: a season was deleted from an empty history';
  exception when others then
    if sqlerrm <> 'not_newest' then raise; end if;
  end;
  perform duty_season_start(v_today - 30, '2026/27');
  raise notice 'OK: seasons start in order and only the newest can be undone (0050)';
end $$;

-- 20g. The reminder settings: the admin writes both columns through the
-- existing settings_update policy; the lead is 1–14 days.
do $$
declare
  n integer;
begin
  update schedule_settings set duty_reminder_enabled = true, duty_reminder_days = 3
   where tenant_id = current_tenant_id();
  get diagnostics n = row_count;
  if n <> 1 then
    raise exception 'FAIL: the admin could not switch the duty reminder on';
  end if;
  begin
    update schedule_settings set duty_reminder_days = 0
     where tenant_id = current_tenant_id();
    raise exception 'FAIL: a 0-day lead was accepted';
  exception when check_violation then null;
  end;
  begin
    update schedule_settings set duty_reminder_days = 15
     where tenant_id = current_tenant_id();
    raise exception 'FAIL: a 15-day lead was accepted';
  exception when check_violation then null;
  end;
  update schedule_settings set duty_reminder_days = 14
   where tenant_id = current_tenant_id();
  update schedule_settings set duty_reminder_enabled = false
   where tenant_id = current_tenant_id();
  if not exists (select 1 from schedule_settings
                 where tenant_id = current_tenant_id()
                   and not duty_reminder_enabled and duty_reminder_days = 14) then
    raise exception 'FAIL: switching the reminder off should keep the lead';
  end if;
  raise notice 'OK: the admin sets the duty reminder, 1–14 days ahead (0050)';
end $$;

-- 20h. The placeholder's duties are history: no delete while it has one;
-- a merge hands them to the account and drops a period both were on twice.
do $$
declare
  v_p1 constant uuid := current_setting('probe.duty_p1')::uuid;
  v_p2 constant uuid := current_setting('probe.duty_p2')::uuid;
  v_petr constant uuid := '20000000-0000-0000-0000-000000000001';
  v_karel constant uuid := '20000000-0000-0000-0000-000000000003';
  v_ph constant uuid := '50000000-0000-0000-0000-000000000002';
  v_dusan constant uuid := '50000000-0000-0000-0000-000000000003';
begin
  perform duty_set_assignees(v_p1, array[v_petr, v_ph, v_dusan]);
  perform duty_set_assignees(v_p2, array[v_karel, v_ph]);
  begin
    perform delete_placeholder_player(v_ph);
    raise exception 'FAIL: a placeholder with duties was deleted';
  exception when others then
    if sqlerrm <> 'player_has_history' then raise; end if;
  end;
  perform merge_placeholder_player(v_ph, v_dusan, 'Dušan Účet', '', null);
  if exists (select 1 from profiles where id = v_ph)
     or exists (select 1 from duty_assignments where user_id = v_ph) then
    raise exception 'FAIL: the placeholder or its duties survived the merge';
  end if;
  if (select array_agg(user_id order by user_id) from duty_assignments
       where period_id = v_p1) is distinct from array[v_petr, v_dusan]
     or (select array_agg(user_id order by user_id) from duty_assignments
          where period_id = v_p2) is distinct from array[v_karel, v_dusan] then
    raise exception 'FAIL: the merge did not move the duties to the account';
  end if;
  raise notice 'OK: a placeholder''s duties block its delete and move with the merge (0050)';
end $$;

-- 20i. A player of the alley reads its periods, assignees and seasons —
-- not tenant B's — writes none of them and calls none of the admin RPCs.
set local request.jwt.claims =
  '{"sub":"20000000-0000-0000-0000-000000000001","role":"authenticated"}';
do $$
declare
  v_d0 constant date := current_setting('probe.duty_d0')::date;
  v_p1 constant uuid := current_setting('probe.duty_p1')::uuid;
  v_today constant date := (now() at time zone 'Europe/Prague')::date;
begin
  if (select count(*) from duty_periods) <> 2
     or (select count(*) from duty_assignments) <> 4
     or (select count(*) from duty_seasons) <> 1
     or exists (select 1 from duty_periods where tenant_id <> current_tenant_id())
     or exists (select 1 from duty_assignments where tenant_id <> current_tenant_id())
     or exists (select 1 from duty_seasons where tenant_id <> current_tenant_id()) then
    raise exception 'FAIL: a player should read the alley''s duties, and only those';
  end if;
  begin
    perform duty_generate(v_d0 + 200, 7::smallint, v_d0 + 210);
    raise exception 'FAIL: a player generated duties';
  exception when others then
    if sqlerrm <> 'not_allowed' then raise; end if;
  end;
  begin
    perform duty_period_save(null, v_d0 + 200, v_d0 + 201, '');
    raise exception 'FAIL: a player saved a duty';
  exception when others then
    if sqlerrm <> 'not_allowed' then raise; end if;
  end;
  begin
    perform duty_period_delete(v_p1);
    raise exception 'FAIL: a player deleted a duty';
  exception when others then
    if sqlerrm <> 'not_allowed' then raise; end if;
  end;
  begin
    perform duty_periods_delete_unassigned(v_d0);
    raise exception 'FAIL: a player bulk-deleted duties';
  exception when others then
    if sqlerrm <> 'not_allowed' then raise; end if;
  end;
  begin
    perform duty_set_assignees(v_p1, array[auth.uid()]);
    raise exception 'FAIL: a player assigned a duty';
  exception when others then
    if sqlerrm <> 'not_allowed' then raise; end if;
  end;
  begin
    perform duty_season_start(v_today + 20, 'Moje');
    raise exception 'FAIL: a player started a season';
  exception when others then
    if sqlerrm <> 'not_allowed' then raise; end if;
  end;
  begin
    perform duty_season_delete(v_today - 30);
    raise exception 'FAIL: a player undid a season';
  exception when others then
    if sqlerrm <> 'not_allowed' then raise; end if;
  end;
  begin
    insert into duty_periods (tenant_id, starts_on, ends_on)
      values (current_tenant_id(), v_d0 + 200, v_d0 + 201);
    raise exception 'FAIL: a player inserted a period';
  exception when insufficient_privilege then null;
  end;
  begin
    update duty_periods set note = 'moje';
    raise exception 'FAIL: a player updated a period';
  exception when insufficient_privilege then null;
  end;
  begin
    delete from duty_periods;
    raise exception 'FAIL: a player deleted a period';
  exception when insufficient_privilege then null;
  end;
  begin
    insert into duty_assignments (period_id, user_id, tenant_id)
      values (v_p1, auth.uid(), current_tenant_id());
    raise exception 'FAIL: a player assigned themselves';
  exception when insufficient_privilege then null;
  end;
  begin
    update duty_assignments set user_id = auth.uid();
    raise exception 'FAIL: a player rewrote an assignment';
  exception when insufficient_privilege then null;
  end;
  begin
    delete from duty_assignments;
    raise exception 'FAIL: a player deleted an assignment';
  exception when insufficient_privilege then null;
  end;
  begin
    insert into duty_seasons (tenant_id, started_on, name)
      values (current_tenant_id(), v_today + 20, 'Moje');
    raise exception 'FAIL: a player inserted a season';
  exception when insufficient_privilege then null;
  end;
  begin
    delete from duty_seasons;
    raise exception 'FAIL: a player deleted a season';
  exception when insufficient_privilege then null;
  end;
  if exists (select 1 from schedule_settings where duty_reminder_enabled) then
    raise exception 'FAIL: the reminder should be off here';
  end if;
  update schedule_settings set duty_reminder_enabled = true;
  if exists (select 1 from schedule_settings where duty_reminder_enabled) then
    raise exception 'FAIL: a player switched the duty reminder on';
  end if;
  raise notice 'OK: a player reads the alley''s duties and seasons, writes nothing and calls no admin RPC (0050)';
end $$;

-- 20j. The kiosk reads the roster too; a pending player reads nothing and,
-- like the kiosk, calls nothing.
set local request.jwt.claims =
  '{"sub":"10000000-0000-0000-0000-000000000006","role":"authenticated"}';
do $$
begin
  if (select count(*) from duty_periods) <> 2
     or (select count(*) from duty_assignments) <> 4 then
    raise exception 'FAIL: the kiosk should read the alley''s duties';
  end if;
  begin
    perform duty_generate(current_setting('probe.duty_d0')::date + 200,
                          7::smallint, current_setting('probe.duty_d0')::date + 210);
    raise exception 'FAIL: the kiosk generated duties';
  exception when others then
    if sqlerrm <> 'not_allowed' then raise; end if;
  end;
end $$;
set local request.jwt.claims =
  '{"sub":"50000000-0000-0000-0000-000000000001","role":"authenticated"}';
do $$
begin
  if exists (select 1 from duty_periods) or exists (select 1 from duty_assignments)
     or exists (select 1 from duty_seasons) then
    raise exception 'FAIL: a pending player reads the duties';
  end if;
  begin
    perform duty_set_assignees(current_setting('probe.duty_p1')::uuid,
                               array[auth.uid()]);
    raise exception 'FAIL: a pending player assigned a duty';
  exception when others then
    if sqlerrm <> 'not_allowed' then raise; end if;
  end;
  raise notice 'OK: the kiosk reads the roster; a pending player reads nothing; neither plans (0050)';
end $$;

-- 20k. anon: no table, no RPC.
reset role;
set local role anon;
set local request.jwt.claims = '{"role":"anon"}';
do $$
begin
  begin
    perform duty_generate(current_date, 7::smallint, current_date + 6);
    raise exception 'FAIL: anon generated duties';
  exception when insufficient_privilege then null;
  end;
  begin
    perform 1 from duty_periods;
    raise exception 'FAIL: anon read the duties';
  exception when insufficient_privilege then null;
  end;
  raise notice 'OK: anon reaches no duty table or RPC (0050)';
end $$;

-- The next sections start without duties.
reset role;
delete from duty_periods
 where tenant_id in ('00000000-0000-0000-0000-00000000000a',
                     '00000000-0000-0000-0000-000000000002');
delete from duty_seasons
 where tenant_id in ('00000000-0000-0000-0000-00000000000a',
                     '00000000-0000-0000-0000-000000000002');
update schedule_settings set duty_reminder_enabled = false, duty_reminder_days = 1
 where tenant_id = '00000000-0000-0000-0000-00000000000a';

-- 0050 — práva služby ---------------------------------------------------------
-- The player on duty (an approved player assigned to a period that covers
-- Prague today) books and cancels for the alley's players under THEIR
-- rules, from today on; the days of their OWN periods — on duty today or
-- not, never the past — they also edit (blocks, closing, the template),
-- through the RPCs only. The weekly template, matches, rentals and
-- settings stay the admin's.
reset role;

-- 21. Fixtures in an alley of its own, S: tenant A carries matches placed
-- relative to now() (0040, 0045) and a Saturday 05:00 one (0043), which
-- would block a fixed block time on some runs. Pavel serves from yesterday
-- to today + 5, with Vilém (a placeholder) and Alena (S's admin); Quido's
-- duty ended ten days ago; Tereza serves in ten days and is the player
-- Pavel books for; Urban is at his cap of 2; Wanda joins Pavel's group
-- (21c). Blocks at 05:00 and 05:30,
-- and one at midnight that has always started today. Every day is a
-- training day, 4 lanes.
insert into tenants (id, name, status) values
  ('00000000-0000-0000-0000-000000000050', 'Kuželna S (0050)', 'approved');
do $$
declare
  v_s constant uuid := '00000000-0000-0000-0000-000000000050';
  v_today constant date := (now() at time zone 'Europe/Prague')::date;
  v_horizon integer;
  v_now uuid;
  v_past uuid;
  v_next uuid;
  v_b1 uuid;
  v_b2 uuid;
  v_b0 uuid;
begin
  insert into profiles (id, tenant_id, display_name, email, role, status)
  values
    ('50000000-0000-0000-0000-000000000010', v_s, 'Alena Správcová',
     'duty-alena@example.com', 'admin', 'approved'),
    ('50000000-0000-0000-0000-000000000011', v_s, 'Pavel Kantýnský',
     'duty-pavel@example.com', 'player', 'approved'),
    ('50000000-0000-0000-0000-000000000012', v_s, 'Quido Po Službě',
     'duty-quido@example.com', 'player', 'approved'),
    ('50000000-0000-0000-0000-000000000013', v_s, 'Tereza Hostová',
     'duty-tereza@example.com', 'player', 'approved'),
    ('50000000-0000-0000-0000-000000000014', v_s, 'Urban Plný',
     'duty-urban@example.com', 'player', 'approved'),
    ('50000000-0000-0000-0000-000000000016', v_s, 'Wanda Skupinová',
     'duty-wanda@example.com', 'player', 'approved');
  insert into profiles (id, tenant_id, display_name, role, status, placeholder)
  values ('50000000-0000-0000-0000-000000000015', v_s, 'Vilém bez účtu',
          'player', 'approved', true);
  update schedule_settings
     set training_weekdays = '{1,2,3,4,5,6,7}', max_active_reservations = 2,
         lane_count = 4
   where tenant_id = v_s
  returning booking_horizon_days into v_horizon;
  if v_horizon is null then
    raise exception 'FAIL: the new alley got no settings row';
  end if;
  insert into time_blocks (tenant_id, starts_at, ends_at, position)
    values (v_s, '05:00', '05:30', 95) returning id into v_b1;
  insert into time_blocks (tenant_id, starts_at, ends_at, position)
    values (v_s, '05:30', '06:00', 96) returning id into v_b2;
  insert into time_blocks (tenant_id, starts_at, ends_at, position)
    values (v_s, '00:00', '00:30', 94) returning id into v_b0;

  insert into duty_periods (tenant_id, starts_on, ends_on)
    values (v_s, v_today - 1, v_today + 5) returning id into v_now;
  insert into duty_periods (tenant_id, starts_on, ends_on)
    values (v_s, v_today - 20, v_today - 10) returning id into v_past;
  insert into duty_periods (tenant_id, starts_on, ends_on)
    values (v_s, v_today + 10, v_today + 16) returning id into v_next;
  insert into duty_assignments (period_id, user_id, tenant_id) values
    (v_now, '50000000-0000-0000-0000-000000000010', v_s),
    (v_now, '50000000-0000-0000-0000-000000000011', v_s),
    (v_now, '50000000-0000-0000-0000-000000000015', v_s),
    (v_past, '50000000-0000-0000-0000-000000000012', v_s),
    (v_next, '50000000-0000-0000-0000-000000000013', v_s);

  insert into reservations (tenant_id, player_id, date, block_id, lane,
                            created_via, created_by)
  values
    (v_s, '50000000-0000-0000-0000-000000000014', v_today + 2, v_b1, 1,
     'app', '50000000-0000-0000-0000-000000000014'),
    (v_s, '50000000-0000-0000-0000-000000000014', v_today + 3, v_b1, 1,
     'app', '50000000-0000-0000-0000-000000000014');

  perform set_config('probe.duty_b1', v_b1::text, true);
  perform set_config('probe.duty_b2', v_b2::text, true);
  perform set_config('probe.duty_b0', v_b0::text, true);
  perform set_config('probe.duty_horizon', v_horizon::text, true);
end $$;

-- 21a. is_on_duty(), duty_gate() and duty_edit_gate() are internal: only
-- security-definer bodies call them. The two new day RPCs are the app's and not anon's; the
-- replaced RPCs keep their callers; is_admin() stays PUBLIC-executable
-- (policies call it). Both via CHECKs know 'duty' and hold for every row.
do $$
declare
  v_f text;
begin
  foreach v_f in array array[
      'is_on_duty()', 'duty_gate(date)', 'duty_edit_gate(date)'] loop
    if has_function_privilege('authenticated', 'public.' || v_f, 'execute')
       or has_function_privilege('anon', 'public.' || v_f, 'execute') then
      raise exception 'FAIL: % is callable from the app', v_f;
    end if;
    if not (select prosecdef from pg_proc
             where oid = ('public.' || v_f)::regprocedure) then
      raise exception 'FAIL: % is not security definer', v_f;
    end if;
  end loop;
  foreach v_f in array array[
      'add_special_block(time, time)', 'delete_day_override(date)'] loop
    if has_function_privilege('anon', 'public.' || v_f, 'execute') then
      raise exception 'FAIL: anon may execute %', v_f;
    end if;
    if not has_function_privilege('authenticated', 'public.' || v_f, 'execute') then
      raise exception 'FAIL: the app cannot call %', v_f;
    end if;
    if not (select prosecdef from pg_proc
             where oid = ('public.' || v_f)::regprocedure) then
      raise exception 'FAIL: % is not security definer', v_f;
    end if;
  end loop;
  foreach v_f in array array[
      'create_reservation(uuid, date, uuid, smallint)',
      'cancel_reservation(uuid, text, boolean)',
      'set_day_override(date, boolean, text, uuid[])',
      'cancel_block_day_reservations(date, uuid, text)',
      'move_day_reservations(date, uuid, uuid, boolean, text)',
      'move_reservation(uuid, uuid, integer, boolean, text)'] loop
    if not has_function_privilege('authenticated', 'public.' || v_f, 'execute') then
      raise exception 'FAIL: the app can no longer call %', v_f;
    end if;
  end loop;
  if not has_function_privilege('anon', 'public.is_admin()', 'execute') then
    raise exception 'FAIL: is_admin() must stay PUBLIC-executable, policies call it';
  end if;
  if (select count(*) from pg_constraint
       where conrelid = 'public.reservations'::regclass
         and conname in ('reservations_created_via_check',
                         'reservations_cancelled_via_check')
         and convalidated
         and pg_get_constraintdef(oid) like '%''duty''%') <> 2 then
    raise exception 'FAIL: both via CHECKs must allow ''duty'' and be validated';
  end if;
  raise notice 'OK: the duty helpers are internal, the new day RPCs the app''s and not anon''s, ''duty'' a valid via (0050)';
end $$;

-- 21b. is_on_duty(): Pavel inside his period — not Quido after his, not
-- Tereza before hers, not the placeholder or the admin on Pavel's (the
-- admin has the admin path), not Pavel demoted to pending, not Pavel as a
-- superadmin visiting tenant B.
do $$
declare
  v_pavel constant uuid := '50000000-0000-0000-0000-000000000011';
begin
  perform set_config('request.jwt.claims',
    '{"sub":"50000000-0000-0000-0000-000000000011","role":"authenticated"}', true);
  if not is_on_duty() then
    raise exception 'FAIL: Pavel is not on duty inside his period';
  end if;
  perform set_config('request.jwt.claims',
    '{"sub":"50000000-0000-0000-0000-000000000012","role":"authenticated"}', true);
  if is_on_duty() then
    raise exception 'FAIL: Quido is still on duty after his period ended';
  end if;
  perform set_config('request.jwt.claims',
    '{"sub":"50000000-0000-0000-0000-000000000013","role":"authenticated"}', true);
  if is_on_duty() then
    raise exception 'FAIL: Tereza is on duty before her period starts';
  end if;
  perform set_config('request.jwt.claims',
    '{"sub":"50000000-0000-0000-0000-000000000015","role":"authenticated"}', true);
  if is_on_duty() then
    raise exception 'FAIL: a placeholder got the duty''s rights';
  end if;
  perform set_config('request.jwt.claims',
    '{"sub":"50000000-0000-0000-0000-000000000010","role":"authenticated"}', true);
  if is_on_duty() then
    raise exception 'FAIL: an admin on the period took the duty path, not the admin''s';
  end if;

  perform set_config('request.jwt.claims',
    '{"sub":"50000000-0000-0000-0000-000000000011","role":"authenticated"}', true);
  update profiles set status = 'pending' where id = v_pavel;
  if is_on_duty() then
    raise exception 'FAIL: a player demoted to pending kept the duty''s rights';
  end if;
  update profiles set status = 'approved' where id = v_pavel;
  if not is_on_duty() then
    raise exception 'FAIL: Pavel did not get his rights back once approved again';
  end if;
  update profiles
     set superadmin = true, home_tenant_id = '00000000-0000-0000-0000-000000000050'
   where id = v_pavel;
end $$;
set local role authenticated;
set local request.jwt.claims =
  '{"sub":"50000000-0000-0000-0000-000000000011","role":"authenticated"}';
select switch_tenant('00000000-0000-0000-0000-000000000002');
do $$
begin
  begin
    perform set_day_override((now() at time zone 'Europe/Prague')::date, true,
                             'návštěva');
    raise exception 'FAIL: a visiting superadmin edited the other alley''s day as its duty';
  exception when others then
    if sqlerrm <> 'not_allowed' then raise; end if;
  end;
end $$;
reset role;
do $$
begin
  if is_on_duty() then
    raise exception 'FAIL: Pavel kept his duty while visiting another alley';
  end if;
end $$;
set local role authenticated;
select switch_tenant('00000000-0000-0000-0000-000000000050');
reset role;
update profiles set superadmin = false, home_tenant_id = null
 where id = '50000000-0000-0000-0000-000000000011';
do $$
begin
  if not is_on_duty() then
    raise exception 'FAIL: back home, Pavel is not on duty';
  end if;
  raise notice 'OK: on duty = an approved account player of the alley inside the period, nobody else (0050)';
end $$;

-- 21c. Pavel books for Tereza as the duty, under her rules: her cap
-- (Urban's refused with player_at_limit), no past day, no started block,
-- the horizon. His own booking stays 'app'; a player of another alley is
-- not his to book; the placeholder is bookable like any member.
set local role authenticated;
set local request.jwt.claims =
  '{"sub":"50000000-0000-0000-0000-000000000011","role":"authenticated"}';
do $$
declare
  v_today constant date := (now() at time zone 'Europe/Prague')::date;
  v_b1 constant uuid := current_setting('probe.duty_b1')::uuid;
  v_b2 constant uuid := current_setting('probe.duty_b2')::uuid;
  v_b0 constant uuid := current_setting('probe.duty_b0')::uuid;
  v_horizon constant integer := current_setting('probe.duty_horizon')::integer;
  v_res reservations;
begin
  select * into v_res from create_reservation(
    '50000000-0000-0000-0000-000000000013', v_today + 1, v_b1, 1::smallint);
  if v_res.created_via <> 'duty'
     or v_res.created_by <> '50000000-0000-0000-0000-000000000011' then
    raise exception 'FAIL: a booking by the duty is not marked as one: %', v_res;
  end if;
  perform set_config('probe.duty_res_t', v_res.id::text, true);
  begin
    perform create_reservation(
      '50000000-0000-0000-0000-000000000014', v_today + 1, v_b1, 2::smallint);
    raise exception 'FAIL: the duty booked past Urban''s cap';
  exception when others then
    if sqlerrm <> 'player_at_limit' then raise; end if;
  end;
  begin
    perform create_reservation(
      '50000000-0000-0000-0000-000000000013', v_today - 1, v_b1, 2::smallint);
    raise exception 'FAIL: the duty booked yesterday';
  exception when others then
    if sqlerrm <> 'date_past' then raise; end if;
  end;
  begin
    perform create_reservation(
      '50000000-0000-0000-0000-000000000013', v_today, v_b0, 1::smallint);
    raise exception 'FAIL: the duty booked a block that has started';
  exception when others then
    if sqlerrm <> 'date_past' then raise; end if;
  end;
  begin
    perform create_reservation(
      '50000000-0000-0000-0000-000000000013', v_today + v_horizon + 1, v_b1,
      1::smallint);
    raise exception 'FAIL: the duty booked beyond the horizon';
  exception when others then
    if sqlerrm <> 'beyond_horizon' then raise; end if;
  end;
  begin
    perform create_reservation(
      '20000000-0000-0000-0000-0000000000b1', v_today + 1, v_b1, 2::smallint);
    raise exception 'FAIL: the duty booked a player of another alley';
  exception when others then
    if sqlerrm <> 'player_not_approved' then raise; end if;
  end;
  select * into v_res from create_reservation(
    '50000000-0000-0000-0000-000000000011', v_today + 1, v_b1, 3::smallint);
  if v_res.created_via <> 'app' then
    raise exception 'FAIL: the duty''s own booking is not ''app'': %', v_res;
  end if;
  select * into v_res from create_reservation(
    '50000000-0000-0000-0000-000000000015', v_today + 1, v_b2, 1::smallint);
  if v_res.created_via <> 'duty' then
    raise exception 'FAIL: a booking by the duty for a placeholder is not ''duty'': %', v_res;
  end if;
  raise notice 'OK: the duty books for others as ''duty'' under their cap, horizon and start, for himself as ''app'' (0050)';
end $$;

-- The group branch comes before the duty's: Pavel booking Wanda, his group
-- mate, books as 'group'.
select group_invite('50000000-0000-0000-0000-000000000016');
set local request.jwt.claims =
  '{"sub":"50000000-0000-0000-0000-000000000016","role":"authenticated"}';
select group_accept((select group_id from player_group_members
                     where user_id = '50000000-0000-0000-0000-000000000016'));
set local request.jwt.claims =
  '{"sub":"50000000-0000-0000-0000-000000000011","role":"authenticated"}';
do $$
declare
  v_res reservations;
begin
  select * into v_res from create_reservation(
    '50000000-0000-0000-0000-000000000016',
    (now() at time zone 'Europe/Prague')::date + 1,
    current_setting('probe.duty_b2')::uuid, 2::smallint);
  if v_res.created_via <> 'group' then
    raise exception 'FAIL: the duty booking a group mate should book as ''group'': %', v_res;
  end if;
  perform group_leave();
  raise notice 'OK: a group mate booked by the duty is a group booking (0050)';
end $$;

-- 21d. Pavel cancels as the duty: Tereza's future training (his note and
-- notify choice kept; the default notifies), not her started one, not
-- another alley's.
reset role;
do $$
declare
  v_s constant uuid := '00000000-0000-0000-0000-000000000050';
  v_b constant uuid := '00000000-0000-0000-0000-000000000002';
  v_today constant date := (now() at time zone 'Europe/Prague')::date;
  v_id uuid;
  v_block uuid;
begin
  insert into reservations (tenant_id, player_id, date, block_id, lane,
                            created_via, created_by)
  values (v_s, '50000000-0000-0000-0000-000000000013', v_today - 1,
          current_setting('probe.duty_b1')::uuid, 2, 'app',
          '50000000-0000-0000-0000-000000000013')
  returning id into v_id;
  perform set_config('probe.duty_res_past', v_id::text, true);
  insert into time_blocks (tenant_id, starts_at, ends_at, position)
    values (v_b, '05:00', '05:30', 95) returning id into v_block;
  insert into reservations (tenant_id, player_id, date, block_id, lane,
                            created_via, created_by)
  values (v_b, '20000000-0000-0000-0000-0000000000b1', v_today + 1, v_block, 1,
          'app', '20000000-0000-0000-0000-0000000000b1')
  returning id into v_id;
  perform set_config('probe.duty_res_foreign', v_id::text, true);
end $$;
set local role authenticated;
set local request.jwt.claims =
  '{"sub":"50000000-0000-0000-0000-000000000011","role":"authenticated"}';
do $$
declare
  v_today constant date := (now() at time zone 'Europe/Prague')::date;
  v_res reservations;
begin
  perform cancel_reservation(current_setting('probe.duty_res_t')::uuid,
                             '  odešla domů  ', false);
  select * into v_res from reservations
   where id = current_setting('probe.duty_res_t')::uuid;
  if v_res.cancelled_at is null or v_res.cancelled_via is distinct from 'duty'
     or v_res.cancelled_by is distinct from '50000000-0000-0000-0000-000000000011'
     or v_res.cancel_note <> 'odešla domů' or v_res.notify_player then
    raise exception 'FAIL: a cancel by the duty is not marked as one: %', v_res;
  end if;
  perform cancel_reservation((select id from reservations
    where player_id = '50000000-0000-0000-0000-000000000014'
      and date = v_today + 3 and cancelled_at is null), '', null);
  select * into v_res from reservations
   where player_id = '50000000-0000-0000-0000-000000000014' and date = v_today + 3;
  if v_res.cancelled_via is distinct from 'duty' or not v_res.notify_player then
    raise exception 'FAIL: a cancel by the duty without a choice should notify: %', v_res;
  end if;
  begin
    perform cancel_reservation(current_setting('probe.duty_res_past')::uuid);
    raise exception 'FAIL: the duty cancelled a started training';
  exception when others then
    if sqlerrm <> 'too_late' then raise; end if;
  end;
  begin
    perform cancel_reservation(current_setting('probe.duty_res_foreign')::uuid);
    raise exception 'FAIL: the duty cancelled another alley''s training';
  exception when others then
    if sqlerrm <> 'not_allowed' then raise; end if;
  end;
  raise notice 'OK: the duty cancels others'' trainings until they start, as ''duty'', in his alley only (0050)';
end $$;

-- 21e. Pavel edits days from today on: moves one reservation and a whole
-- block of today, cancels a block of today, closes today, sets and deletes
-- overrides for today and tomorrow, adds a day-only block; yesterday is
-- date_past for every one of them. A started block is the players' own
-- rule too: the duty moves nothing out of it or into it (`too_late`), and
-- a day or block cancel spares its trainings, as the override cascade does
-- — they are played, and attendance is the admin's. Today's "not started"
-- blocks sit in the day's last seconds (now() is the suite's transaction
-- start, so they hold unless the suite starts right before midnight); the
-- 00:00 block has always started today.
reset role;
do $$
declare
  v_s constant uuid := '00000000-0000-0000-0000-000000000050';
  v_today constant date := (now() at time zone 'Europe/Prague')::date;
  v_l1 uuid;
  v_l2 uuid;
  v_id uuid;
begin
  insert into time_blocks (tenant_id, starts_at, ends_at, position)
    values (v_s, '23:59:57', '23:59:58', 97) returning id into v_l1;
  insert into time_blocks (tenant_id, starts_at, ends_at, position)
    values (v_s, '23:59:58', '23:59:59', 98) returning id into v_l2;
  perform set_config('probe.duty_l1', v_l1::text, true);
  perform set_config('probe.duty_l2', v_l2::text, true);
  insert into reservations (tenant_id, player_id, date, block_id, lane,
                            created_via, created_by)
  values (v_s, '50000000-0000-0000-0000-000000000013', v_today, v_l1, 1,
          'app', '50000000-0000-0000-0000-000000000013')
  returning id into v_id;
  perform set_config('probe.duty_res_today1', v_id::text, true);
  insert into reservations (tenant_id, player_id, date, block_id, lane,
                            created_via, created_by)
  values (v_s, '50000000-0000-0000-0000-000000000013', v_today, v_l2, 1,
          'app', '50000000-0000-0000-0000-000000000013')
  returning id into v_id;
  perform set_config('probe.duty_res_today2', v_id::text, true);
  insert into reservations (tenant_id, player_id, date, block_id, lane,
                            created_via, created_by)
  values (v_s, '50000000-0000-0000-0000-000000000013', v_today,
          current_setting('probe.duty_b0')::uuid, 1, 'app',
          '50000000-0000-0000-0000-000000000013')
  returning id into v_id;
  perform set_config('probe.duty_res_played', v_id::text, true);
end $$;
set local role authenticated;
set local request.jwt.claims =
  '{"sub":"50000000-0000-0000-0000-000000000011","role":"authenticated"}';
do $$
declare
  v_today constant date := (now() at time zone 'Europe/Prague')::date;
  v_b0 constant uuid := current_setting('probe.duty_b0')::uuid;
  v_b1 constant uuid := current_setting('probe.duty_b1')::uuid;
  v_b2 constant uuid := current_setting('probe.duty_b2')::uuid;
  v_l1 constant uuid := current_setting('probe.duty_l1')::uuid;
  v_l2 constant uuid := current_setting('probe.duty_l2')::uuid;
  v_r1 constant uuid := current_setting('probe.duty_res_today1')::uuid;
  v_r2 constant uuid := current_setting('probe.duty_res_today2')::uuid;
  v_r0 constant uuid := current_setting('probe.duty_res_played')::uuid;
  v_tomorrow uuid;
  v_id uuid;
  v_res reservations;
  v_o day_overrides;
  v_blk time_blocks;
begin
  -- One reservation: today, between blocks that have not started.
  perform move_reservation(v_r1, v_l2, 2);
  if not exists (select 1 from reservations
                 where id = v_r1 and block_id = v_l2 and lane = 2) then
    raise exception 'FAIL: the duty could not move a reservation of today';
  end if;
  begin
    perform move_reservation(v_r0, v_l1, 2);
    raise exception 'FAIL: the duty moved a training out of a started block';
  exception when others then
    if sqlerrm <> 'too_late' then raise; end if;
  end;
  begin
    perform move_reservation(v_r1, v_b0, 2);
    raise exception 'FAIL: the duty moved a training into a started block';
  exception when others then
    if sqlerrm <> 'too_late' then raise; end if;
  end;
  begin
    perform move_reservation(current_setting('probe.duty_res_past')::uuid, v_b2, 3);
    raise exception 'FAIL: the duty moved a reservation of yesterday';
  exception when others then
    if sqlerrm <> 'date_past' then raise; end if;
  end;
  -- The 00:00 block of tomorrow has not started: that move is the duty's.
  select id into v_tomorrow from reservations
   where player_id = '50000000-0000-0000-0000-000000000015'
     and date = v_today + 1 and cancelled_at is null;
  perform move_reservation(v_tomorrow, v_b0, 1);
  if not exists (select 1 from reservations
                 where id = v_tomorrow and block_id = v_b0 and lane = 1) then
    raise exception 'FAIL: the duty could not move tomorrow''s training to 00:00';
  end if;

  -- A whole block: today between blocks that have not started, not out of
  -- or into a started one; tomorrow's 00:00 is fine.
  perform move_day_reservations(v_today, v_l2, v_l1);
  if (select count(*) from reservations
       where id in (v_r1, v_r2) and block_id = v_l1) <> 2 then
    raise exception 'FAIL: the duty could not move today''s block';
  end if;
  begin
    perform move_day_reservations(v_today, v_b0, v_l2);
    raise exception 'FAIL: the duty moved a started block';
  exception when others then
    if sqlerrm <> 'too_late' then raise; end if;
  end;
  begin
    perform move_day_reservations(v_today, v_l1, v_b0);
    raise exception 'FAIL: the duty moved a block into a started one';
  exception when others then
    if sqlerrm <> 'too_late' then raise; end if;
  end;
  begin
    perform move_day_reservations(v_today - 1, v_b1, v_b2);
    raise exception 'FAIL: the duty moved yesterday''s block';
  exception when others then
    if sqlerrm <> 'date_past' then raise; end if;
  end;
  perform move_day_reservations(v_today + 1, v_b0, v_b2);
  if not exists (select 1 from reservations
                 where id = v_tomorrow and block_id = v_b2 and lane = 1) then
    raise exception 'FAIL: the duty could not move tomorrow''s 00:00 block';
  end if;
  if not exists (select 1 from reservations
                 where id = v_r0 and block_id = v_b0 and lane = 1
                   and cancelled_at is null)
     or (select count(*) from reservations
          where id in (v_r1, v_r2) and block_id = v_l1) <> 2 then
    raise exception 'FAIL: a refused move by the duty moved something';
  end if;

  -- Cancelling a block of today: what has not started goes, a started
  -- block's trainings stay.
  perform cancel_block_day_reservations(v_today, v_l1, 'blok zrušen');
  if exists (select 1 from reservations
             where id in (v_r1, v_r2) and cancelled_at is null) then
    raise exception 'FAIL: the duty could not cancel today''s block';
  end if;
  perform cancel_block_day_reservations(v_today, v_b0, 'blok zrušen');
  if not exists (select 1 from reservations
                 where id = v_r0 and cancelled_at is null) then
    raise exception 'FAIL: the duty cancelled a started block''s training';
  end if;
  begin
    perform cancel_block_day_reservations(v_today - 1, v_b1, 'blok zrušen');
    raise exception 'FAIL: the duty cancelled yesterday''s block';
  exception when others then
    if sqlerrm <> 'date_past' then raise; end if;
  end;

  -- Closing today: the rest of the day goes, the training under way stays.
  select * into v_res from create_reservation(
    '50000000-0000-0000-0000-000000000015', v_today, v_l2, 3::smallint);
  if v_res.created_via <> 'duty' then
    raise exception 'FAIL: the duty could not book later today: %', v_res;
  end if;
  perform set_day_override(v_today, true, 'Zavřeno');
  if not exists (select 1 from day_overrides where date = v_today and closed)
     or not exists (select 1 from reservations
                    where id = v_res.id and cancelled_at is not null)
     or not exists (select 1 from reservations
                    where id = v_r0 and cancelled_at is null) then
    raise exception 'FAIL: closing today by the duty should cancel the rest of the day and spare the started training';
  end if;

  perform set_day_override(v_today, false, '', array[v_b1, v_b2]);
  select * into v_o from day_overrides where date = v_today;
  if v_o.block_ids is distinct from array[v_b1, v_b2] or v_o.closed
     or v_o.created_by is distinct from '50000000-0000-0000-0000-000000000011' then
    raise exception 'FAIL: the duty could not set today''s blocks: %', v_o;
  end if;
  if not exists (select 1 from reservations
                 where id = v_r0 and cancelled_at is null) then
    raise exception 'FAIL: the duty''s block list for today cancelled a started training';
  end if;
  perform set_day_override(v_today + 1, true, 'Zavřeno kvůli akci');
  if not exists (select 1 from day_overrides
                 where date = v_today + 1 and closed
                   and reason = 'Zavřeno kvůli akci') then
    raise exception 'FAIL: the duty could not close tomorrow';
  end if;
  begin
    perform set_day_override(v_today - 1, true, 'pozdě');
    raise exception 'FAIL: the duty closed yesterday';
  exception when others then
    if sqlerrm <> 'date_past' then raise; end if;
  end;

  perform delete_day_override(v_today + 1);
  if exists (select 1 from day_overrides where date = v_today + 1) then
    raise exception 'FAIL: the duty could not return tomorrow to the template';
  end if;
  begin
    perform delete_day_override(v_today - 1);
    raise exception 'FAIL: the duty deleted yesterday''s override';
  exception when others then
    if sqlerrm <> 'date_past' then raise; end if;
  end;

  v_id := add_special_block('05:40', '05:50');
  select * into v_blk from time_blocks where id = v_id;
  if v_blk.id is null or v_blk.position <> -1 or v_blk.active
     or v_blk.tenant_id <> current_tenant_id()
     or v_blk.starts_at <> '05:40' or v_blk.ends_at <> '05:50' then
    raise exception 'FAIL: add_special_block did not add an inactive day-only block: %', v_blk;
  end if;
  perform set_config('probe.duty_special', v_id::text, true);
  raise notice 'OK: the duty edits days from today on, never yesterday (0050)';
  raise notice 'OK: the duty leaves a started block alone: no move out or in (too_late), a day or block cancel spares it (0050)';
end $$;

-- 21f. Quido, whose duty is over, is a plain player again: every one of
-- these is not_allowed — for an unknown reservation too, before a word
-- about it — and none of them changed anything. His own booking works.
reset role;
do $$
declare
  v_s constant uuid := '00000000-0000-0000-0000-000000000050';
  v_today constant date := (now() at time zone 'Europe/Prague')::date;
  v_id uuid;
begin
  insert into reservations (tenant_id, player_id, date, block_id, lane,
                            created_via, created_by)
  values (v_s, '50000000-0000-0000-0000-000000000013', v_today + 2,
          current_setting('probe.duty_b2')::uuid, 1, 'app',
          '50000000-0000-0000-0000-000000000013')
  returning id into v_id;
  perform set_config('probe.duty_res_future', v_id::text, true);
  insert into reservations (tenant_id, player_id, date, block_id, lane,
                            created_via, created_by)
  values (v_s, '50000000-0000-0000-0000-000000000013', v_today,
          current_setting('probe.duty_b2')::uuid, 3, 'app',
          '50000000-0000-0000-0000-000000000013')
  returning id into v_id;
  perform set_config('probe.duty_res_today3', v_id::text, true);
end $$;
set local role authenticated;
set local request.jwt.claims =
  '{"sub":"50000000-0000-0000-0000-000000000012","role":"authenticated"}';
do $$
declare
  v_today constant date := (now() at time zone 'Europe/Prague')::date;
  v_b1 constant uuid := current_setting('probe.duty_b1')::uuid;
  v_b2 constant uuid := current_setting('probe.duty_b2')::uuid;
  v_res reservations;
begin
  begin
    perform create_reservation(
      '50000000-0000-0000-0000-000000000013', v_today + 2, v_b1, 3::smallint);
    raise exception 'FAIL: a player off duty booked for another';
  exception when others then
    if sqlerrm <> 'not_allowed' then raise; end if;
  end;
  begin
    perform cancel_reservation(current_setting('probe.duty_res_future')::uuid);
    raise exception 'FAIL: a player off duty cancelled another''s training';
  exception when others then
    if sqlerrm <> 'not_allowed' then raise; end if;
  end;
  begin
    perform set_day_override(v_today + 2, true, 'po službě');
    raise exception 'FAIL: a player off duty closed a day';
  exception when others then
    if sqlerrm <> 'not_allowed' then raise; end if;
  end;
  begin
    perform delete_day_override(v_today);
    raise exception 'FAIL: a player off duty deleted an override';
  exception when others then
    if sqlerrm <> 'not_allowed' then raise; end if;
  end;
  begin
    perform add_special_block('05:40', '05:50');
    raise exception 'FAIL: a player off duty added a block';
  exception when others then
    if sqlerrm <> 'not_allowed' then raise; end if;
  end;
  begin
    perform cancel_block_day_reservations(v_today, v_b2);
    raise exception 'FAIL: a player off duty cancelled a block';
  exception when others then
    if sqlerrm <> 'not_allowed' then raise; end if;
  end;
  begin
    perform move_day_reservations(v_today, v_b2, v_b1);
    raise exception 'FAIL: a player off duty moved a block';
  exception when others then
    if sqlerrm <> 'not_allowed' then raise; end if;
  end;
  begin
    perform move_reservation(current_setting('probe.duty_res_today3')::uuid,
                             v_b1, 3);
    raise exception 'FAIL: a player off duty moved a reservation';
  exception when others then
    if sqlerrm <> 'not_allowed' then raise; end if;
  end;
  begin
    perform move_reservation(gen_random_uuid(), v_b1, 3);
    raise exception 'FAIL: a player off duty moved an unknown reservation';
  exception when others then
    if sqlerrm <> 'not_allowed' then raise; end if;
  end;
  select * into v_res from create_reservation(
    '50000000-0000-0000-0000-000000000012', v_today + 4, v_b2, 2::smallint);
  if v_res.created_via <> 'app' then
    raise exception 'FAIL: a player off duty lost his own booking: %', v_res;
  end if;
end $$;
reset role;
do $$
declare
  v_today constant date := (now() at time zone 'Europe/Prague')::date;
  v_b1 constant uuid := current_setting('probe.duty_b1')::uuid;
  v_b2 constant uuid := current_setting('probe.duty_b2')::uuid;
begin
  if exists (select 1 from reservations
             where id = current_setting('probe.duty_res_future')::uuid
               and cancelled_at is not null)
     or not exists (select 1 from reservations
                    where id = current_setting('probe.duty_res_today3')::uuid
                      and block_id = v_b2 and lane = 3 and cancelled_at is null)
     or exists (select 1 from day_overrides
                where tenant_id = '00000000-0000-0000-0000-000000000050'
                  and date = v_today + 2)
     or (select block_ids from day_overrides
          where tenant_id = '00000000-0000-0000-0000-000000000050'
            and date = v_today) is distinct from array[v_b1, v_b2]
     or (select count(*) from time_blocks
          where tenant_id = '00000000-0000-0000-0000-000000000050'
            and position = -1 and starts_at = '05:40') <> 1 then
    raise exception 'FAIL: a refused call by a player off duty changed something';
  end if;
  raise notice 'OK: off duty, a player books, cancels and edits nothing of others (0050)';
end $$;

-- 21g. On duty, Pavel still writes no table directly: the weekly template,
-- matches, rentals, settings and overrides stay behind the admin's
-- policies (an INSERT is refused with 42501, an UPDATE or DELETE finds no
-- row — RLS hides it — and changes nothing).
set local role authenticated;
set local request.jwt.claims =
  '{"sub":"50000000-0000-0000-0000-000000000011","role":"authenticated"}';
do $$
declare
  v_today constant date := (now() at time zone 'Europe/Prague')::date;
  v_b1 constant uuid := current_setting('probe.duty_b1')::uuid;
  v_type uuid;
  v_rows integer;
begin
  begin
    insert into time_blocks (starts_at, ends_at, position, active)
      values ('05:40', '05:50', -1, false);
    raise exception 'FAIL: the duty inserted a block directly';
  exception when insufficient_privilege then null;
  end;
  select id into v_type from priority_slot_types limit 1;
  begin
    insert into priority_slots (date, starts_at, ends_at, type_id, created_by)
      values (v_today + 1, '05:00', '05:30', v_type, auth.uid());
    raise exception 'FAIL: the duty inserted a match or priority slot';
  exception when insufficient_privilege then null;
  end;
  begin
    insert into rentals (tenant_id, renter_name, lanes, date, starts_at, ends_at,
                         created_by)
      values (current_tenant_id(), 'Firma Služba', '{1}', v_today + 1,
              '05:00', '05:30', auth.uid());
    raise exception 'FAIL: the duty inserted a rental';
  exception when insufficient_privilege then null;
  end;
  update time_blocks set starts_at = '04:30' where id = v_b1;
  get diagnostics v_rows = row_count;
  if v_rows <> 0 then
    raise exception 'FAIL: the duty changed the weekly template';
  end if;
  delete from time_blocks where id = v_b1;
  get diagnostics v_rows = row_count;
  if v_rows <> 0 then
    raise exception 'FAIL: the duty deleted a template block';
  end if;
  update schedule_settings set max_active_reservations = 9;
  get diagnostics v_rows = row_count;
  if v_rows <> 0 then
    raise exception 'FAIL: the duty changed the alley''s settings';
  end if;
  begin
    insert into day_overrides (tenant_id, date, closed, created_by)
      values (current_tenant_id(), v_today + 3, true, auth.uid());
    raise exception 'FAIL: the duty inserted an override directly';
  exception when insufficient_privilege then null;
  end;
  delete from day_overrides where date = v_today;
  get diagnostics v_rows = row_count;
  if v_rows <> 0 then
    raise exception 'FAIL: the duty deleted an override directly';
  end if;
  if not exists (select 1 from time_blocks
                 where id = v_b1 and starts_at = '05:00') then
    raise exception 'FAIL: the template block is not what it was';
  end if;
  raise notice 'OK: on duty, the template, matches, rentals, settings and overrides stay behind the admin''s policies (0050)';
end $$;

-- 21h. Alena, S's admin, goes past the duty's rules through the same RPCs:
-- yesterday is hers to move, cancel, close and return to the template
-- (Správa → Výjimky deletes past overrides through delete_day_override),
-- and so is a started block today — out of it, into it, cancelled with the
-- day's block list or on its own. Her day-only block is added like the
-- duty's. (She is on Pavel's period too, but an admin is never on duty:
-- without the admin path every one of these would be not_allowed.)
reset role;
do $$
declare
  v_s constant uuid := '00000000-0000-0000-0000-000000000050';
  v_today constant date := (now() at time zone 'Europe/Prague')::date;
  v_id uuid;
begin
  insert into reservations (tenant_id, player_id, date, block_id, lane,
                            created_via, created_by)
  values (v_s, '50000000-0000-0000-0000-000000000013', v_today - 1,
          current_setting('probe.duty_b1')::uuid, 1, 'app',
          '50000000-0000-0000-0000-000000000013')
  returning id into v_id;
  perform set_config('probe.duty_res_past2', v_id::text, true);
  insert into reservations (tenant_id, player_id, date, block_id, lane,
                            created_via, created_by)
  values (v_s, '50000000-0000-0000-0000-000000000015', v_today - 1,
          current_setting('probe.duty_b0')::uuid, 1, 'app',
          '50000000-0000-0000-0000-000000000015')
  returning id into v_id;
  perform set_config('probe.duty_res_past3', v_id::text, true);
  insert into reservations (tenant_id, player_id, date, block_id, lane,
                            created_via, created_by)
  values (v_s, '50000000-0000-0000-0000-000000000015', v_today,
          current_setting('probe.duty_b0')::uuid, 3, 'app',
          '50000000-0000-0000-0000-000000000015')
  returning id into v_id;
  perform set_config('probe.duty_res_played2', v_id::text, true);
end $$;
set local role authenticated;
set local request.jwt.claims =
  '{"sub":"50000000-0000-0000-0000-000000000010","role":"authenticated"}';
do $$
declare
  v_today constant date := (now() at time zone 'Europe/Prague')::date;
  v_b0 constant uuid := current_setting('probe.duty_b0')::uuid;
  v_b1 constant uuid := current_setting('probe.duty_b1')::uuid;
  v_b2 constant uuid := current_setting('probe.duty_b2')::uuid;
  v_y1 constant uuid := current_setting('probe.duty_res_past')::uuid;
  v_y2 constant uuid := current_setting('probe.duty_res_past2')::uuid;
  v_y3 constant uuid := current_setting('probe.duty_res_past3')::uuid;
  v_t0 constant uuid := current_setting('probe.duty_res_played')::uuid;
  v_t1 constant uuid := current_setting('probe.duty_res_played2')::uuid;
  v_o day_overrides;
  v_id uuid;
  v_blk time_blocks;
begin
  -- Yesterday.
  perform move_reservation(v_y1, v_b2, 3);
  if not exists (select 1 from reservations
                 where id = v_y1 and block_id = v_b2 and lane = 3
                   and cancelled_at is null) then
    raise exception 'FAIL: the admin could not move a reservation of yesterday';
  end if;
  perform move_day_reservations(v_today - 1, v_b1, v_b2);
  if not exists (select 1 from reservations
                 where id = v_y2 and block_id = v_b2 and lane = 1
                   and cancelled_at is null) then
    raise exception 'FAIL: the admin could not move yesterday''s block';
  end if;
  perform cancel_block_day_reservations(v_today - 1, v_b2, 'blok zrušen');
  if (select count(*) from reservations
       where id in (v_y1, v_y2) and cancelled_at is not null
         and cancelled_via = 'admin' and cancel_note = 'blok zrušen') <> 2
     or not exists (select 1 from reservations
                    where id = v_y3 and cancelled_at is null) then
    raise exception 'FAIL: the admin could not cancel yesterday''s block alone';
  end if;
  perform set_day_override(v_today - 1, true, 'x');
  select * into v_o from day_overrides where date = v_today - 1;
  if v_o.date is null or not v_o.closed or v_o.reason <> 'x'
     or v_o.created_by is distinct from '50000000-0000-0000-0000-000000000010'
     or not exists (select 1 from reservations
                    where id = v_y3 and cancelled_at is not null
                      and cancelled_via = 'admin' and cancel_note = 'x') then
    raise exception 'FAIL: the admin could not close yesterday: %', v_o;
  end if;
  perform delete_day_override(v_today - 1);
  if exists (select 1 from day_overrides where date = v_today - 1) then
    raise exception 'FAIL: the admin could not delete yesterday''s override';
  end if;

  -- A started block today: out, in, cancelled by the block list, cancelled
  -- as a block.
  perform move_reservation(v_t0, v_b0, 2);
  if not exists (select 1 from reservations
                 where id = v_t0 and block_id = v_b0 and lane = 2) then
    raise exception 'FAIL: the admin could not move a started training';
  end if;
  perform move_day_reservations(v_today, v_b0, v_b1);
  if (select count(*) from reservations
       where id in (v_t0, v_t1) and block_id = v_b1
         and cancelled_at is null) <> 2 then
    raise exception 'FAIL: the admin could not move a started block';
  end if;
  perform move_reservation(v_t1, v_b0, 3);
  if not exists (select 1 from reservations
                 where id = v_t1 and block_id = v_b0 and lane = 3) then
    raise exception 'FAIL: the admin could not move a training into a started block';
  end if;
  perform set_day_override(v_today, false, 'x', array[v_b1, v_b2]);
  if not exists (select 1 from reservations
                 where id = v_t1 and cancelled_at is not null
                   and cancelled_via = 'admin' and cancel_note = 'x')
     or not exists (select 1 from reservations
                    where id = v_t0 and cancelled_at is null) then
    raise exception 'FAIL: the admin''s block list for today should cancel the started training outside it';
  end if;
  perform move_day_reservations(v_today, v_b1, v_b0);
  if not exists (select 1 from reservations
                 where id = v_t0 and block_id = v_b0 and lane = 2) then
    raise exception 'FAIL: the admin could not move a block into a started one';
  end if;
  perform cancel_block_day_reservations(v_today, v_b0, 'blok zrušen');
  if not exists (select 1 from reservations
                 where id = v_t0 and cancelled_at is not null
                   and cancelled_via = 'admin') then
    raise exception 'FAIL: the admin could not cancel a started block';
  end if;

  v_id := add_special_block('06:10', '06:20');
  select * into v_blk from time_blocks where id = v_id;
  if v_blk.id is null or v_blk.position <> -1 or v_blk.active
     or v_blk.tenant_id <> '00000000-0000-0000-0000-000000000050'
     or v_blk.starts_at <> '06:10' or v_blk.ends_at <> '06:20' then
    raise exception 'FAIL: the admin could not add a day-only block: %', v_blk;
  end if;
  raise notice 'OK: the admin edits any day, yesterday and started blocks too, through the duty''s RPCs (0050)';
end $$;

-- 21i. Block edits belong to a duty's OWN periods (duty_edit_gate):
-- set_day_override, delete_day_override, cancel_block_day_reservations and
-- move_day_reservations on the days of a period of theirs — on duty today or
-- not — never in the past, and add_special_block while a period of theirs
-- has not ended. Someone else's days and days nobody serves are refused
-- (not_allowed), a past day inside an own period is date_past. Booking,
-- cancelling and re-seating for others is the other right: held only WHILE
-- on duty (a period covering today), on any future day, the other duties'
-- days included. Pavel serves today and owns [today − 1, today + 5] and,
-- right behind it, [today + 6, today + 9]; Tereza's [today + 10, today + 16]
-- lies ahead; Quido's ended long ago; days beyond are nobody's.
reset role;
-- Runs the four day RPCs on p_date as whoever is signed in and demands the
-- same outcome of each: p_want is the code they raise, 'ok' = through.
create function pg_temp.expect_day_rpcs(
  p_date date, p_b1 uuid, p_b2 uuid, p_want text)
returns void language plpgsql as $$
declare
  v_call text;
  v_got text;
begin
  foreach v_call in array array[
      'set_day_override', 'cancel_block_day_reservations',
      'move_day_reservations', 'delete_day_override'] loop
    begin
      case v_call
        when 'set_day_override' then
          perform set_day_override(p_date, true, 'probe');
        when 'cancel_block_day_reservations' then
          perform cancel_block_day_reservations(p_date, p_b1, 'probe');
        when 'move_day_reservations' then
          perform move_day_reservations(p_date, p_b1, p_b2);
        else
          perform delete_day_override(p_date);
      end case;
      v_got := 'ok';
    exception when others then
      v_got := sqlerrm;
    end;
    if v_got <> p_want then
      raise exception 'FAIL: % on % gave %, expected %',
        v_call, p_date, v_got, p_want;
    end if;
  end loop;
end $$;
do $$
declare
  v_s constant uuid := '00000000-0000-0000-0000-000000000050';
  v_today constant date := (now() at time zone 'Europe/Prague')::date;
  v_second uuid;
  v_id uuid;
begin
  insert into duty_periods (tenant_id, starts_on, ends_on)
    values (v_s, v_today + 6, v_today + 9) returning id into v_second;
  insert into duty_assignments (period_id, user_id, tenant_id)
    values (v_second, '50000000-0000-0000-0000-000000000011', v_s);
  -- What this section books for Wanda is not about her cap.
  update schedule_settings set max_active_reservations = 50
   where tenant_id = v_s;
  -- One override on a day of Tereza's and one on a day nobody serves: what
  -- Pavel must still find there after his refused edits. And a training of
  -- Wanda's on another of Tereza's days, for her refused cancel below.
  insert into day_overrides (tenant_id, date, closed, reason, created_by)
    values (v_s, v_today + 11, false, 'Terezin den',
            '50000000-0000-0000-0000-000000000010'),
           (v_s, v_today + 20, true, 'nikoho den',
            '50000000-0000-0000-0000-000000000010');
  insert into reservations (tenant_id, player_id, date, block_id, lane,
                            created_via, created_by)
  values (v_s, '50000000-0000-0000-0000-000000000016', v_today + 12,
          current_setting('probe.duty_b1')::uuid, 2, 'app',
          '50000000-0000-0000-0000-000000000016')
  returning id into v_id;
  perform set_config('probe.duty_res_wanda', v_id::text, true);
  -- ... and one in the 00:00 block of today, which has started.
  insert into reservations (tenant_id, player_id, date, block_id, lane,
                            created_via, created_by)
  values (v_s, '50000000-0000-0000-0000-000000000016', v_today,
          current_setting('probe.duty_b0')::uuid, 4, 'app',
          '50000000-0000-0000-0000-000000000016')
  returning id into v_id;
  perform set_config('probe.duty_res_started', v_id::text, true);
end $$;
set local role authenticated;
set local request.jwt.claims =
  '{"sub":"50000000-0000-0000-0000-000000000011","role":"authenticated"}';
do $$
declare
  v_today constant date := (now() at time zone 'Europe/Prague')::date;
  v_b1 constant uuid := current_setting('probe.duty_b1')::uuid;
  v_b2 constant uuid := current_setting('probe.duty_b2')::uuid;
  v_wanda constant uuid := '50000000-0000-0000-0000-000000000016';
  v_res reservations;
  v_d date;
begin
  -- Tereza's day: booked, re-seated and cancelled for another player, as
  -- on any future day.
  select * into v_res from create_reservation(
    v_wanda, v_today + 11, v_b1, 1::smallint);
  if v_res.created_via <> 'duty' then
    raise exception 'FAIL: the duty could not book on another duty''s day: %', v_res;
  end if;
  perform move_reservation(v_res.id, v_b2, 2);
  if not exists (select 1 from reservations
                 where id = v_res.id and block_id = v_b2 and lane = 2
                   and cancelled_at is null) then
    raise exception 'FAIL: the duty could not re-seat a training on another duty''s day';
  end if;
  perform move_reservation(v_res.id, v_b1, 1);

  -- No block edit there: on Tereza's days (the day right behind his own
  -- included), nor on a day nobody serves.
  foreach v_d in array array[v_today + 10, v_today + 11, v_today + 16,
                             v_today + 20] loop
    perform pg_temp.expect_day_rpcs(v_d, v_b1, v_b2, 'not_allowed');
  end loop;
  if not exists (select 1 from reservations
                 where id = v_res.id and block_id = v_b1 and lane = 1
                   and cancelled_at is null)
     or (select reason from day_overrides where date = v_today + 11)
        is distinct from 'Terezin den'
     or not exists (select 1 from day_overrides
                    where date = v_today + 20 and closed
                      and reason = 'nikoho den')
     or exists (select 1 from day_overrides
                where date in (v_today + 10, v_today + 16)) then
    raise exception 'FAIL: a refused block edit outside the duty''s own periods changed something';
  end if;

  perform cancel_reservation(v_res.id, 'jiný den', false);
  if not exists (select 1 from reservations
                 where id = v_res.id and cancelled_via = 'duty'
                   and cancelled_at is not null) then
    raise exception 'FAIL: the duty could not cancel a training on another duty''s day';
  end if;
  -- The booked player's rules hold there as anywhere: no cancel once the
  -- block has started.
  begin
    perform cancel_reservation(current_setting('probe.duty_res_started')::uuid);
    raise exception 'FAIL: the duty cancelled a training of a block that has started today';
  exception when others then
    if sqlerrm <> 'too_late' then raise; end if;
  end;
  if not exists (select 1 from reservations
                 where id = current_setting('probe.duty_res_started')::uuid
                   and cancelled_at is null) then
    raise exception 'FAIL: a refused cancel by the duty cancelled the training';
  end if;
  raise notice 'OK: the duty books, re-seats and cancels on another duty''s day, but edits no block there or on a day nobody serves (0050)';
end $$;

do $$
declare
  v_today constant date := (now() at time zone 'Europe/Prague')::date;
  v_b1 constant uuid := current_setting('probe.duty_b1')::uuid;
  v_b2 constant uuid := current_setting('probe.duty_b2')::uuid;
  v_wanda constant uuid := '50000000-0000-0000-0000-000000000016';
  v_res reservations;
  v_d date;
begin
  -- His own days, the edges of both consecutive periods included: the last
  -- day of the first, the first and the last of the second.
  foreach v_d in array array[v_today + 5, v_today + 6, v_today + 9] loop
    perform pg_temp.expect_day_rpcs(v_d, v_b1, v_b2, 'ok');
    if exists (select 1 from day_overrides where date = v_d) then
      raise exception 'FAIL: the duty''s edit of % left an override', v_d;
    end if;
  end loop;
  -- ... and the edits do their work there: a block's trainings move to
  -- another block, then that block is cancelled for the day.
  select * into v_res from create_reservation(
    v_wanda, v_today + 6, v_b1, 1::smallint);
  perform move_day_reservations(v_today + 6, v_b1, v_b2);
  if not exists (select 1 from reservations
                 where id = v_res.id and block_id = v_b2
                   and cancelled_at is null) then
    raise exception 'FAIL: the duty could not move a block on the day her second period starts';
  end if;
  perform cancel_block_day_reservations(v_today + 6, v_b2, 'blok zrušen');
  if not exists (select 1 from reservations
                 where id = v_res.id and cancelled_at is not null
                   and cancelled_via = 'admin' and cancel_note = 'blok zrušen') then
    raise exception 'FAIL: the duty could not cancel a block on the day her second period starts';
  end if;

  -- The past: inside his own period it is date_past; outside, the day is
  -- not his own to begin with, and that is asked first.
  perform pg_temp.expect_day_rpcs(v_today - 1, v_b1, v_b2, 'date_past');
  perform pg_temp.expect_day_rpcs(v_today - 3, v_b1, v_b2, 'not_allowed');
  raise notice 'OK: the duty edits blocks on the days of both her own periods, edges included; a past day is date_past, or not_allowed outside her periods (0050)';
end $$;

-- Tereza's own period starts in ten days: not on duty today, she still
-- edits exactly her own days, and adds a block for them.
set local request.jwt.claims =
  '{"sub":"50000000-0000-0000-0000-000000000013","role":"authenticated"}';
do $$
declare
  v_today constant date := (now() at time zone 'Europe/Prague')::date;
  v_b1 constant uuid := current_setting('probe.duty_b1')::uuid;
  v_b2 constant uuid := current_setting('probe.duty_b2')::uuid;
  v_wanda constant uuid := '50000000-0000-0000-0000-000000000016';
  v_res constant uuid := current_setting('probe.duty_res_wanda')::uuid;
  v_id uuid;
  v_d date;
begin
  foreach v_d in array array[v_today + 10, v_today + 13, v_today + 16] loop
    perform pg_temp.expect_day_rpcs(v_d, v_b1, v_b2, 'ok');
    if exists (select 1 from day_overrides where date = v_d) then
      raise exception 'FAIL: the edit of % by a duty still ahead left an override', v_d;
    end if;
  end loop;
  v_id := add_special_block('07:00', '07:10');
  if not exists (select 1 from time_blocks
                 where id = v_id and position = -1 and not active
                   and tenant_id = '00000000-0000-0000-0000-000000000050') then
    raise exception 'FAIL: a duty still ahead could not add a day-only block';
  end if;
  -- Nothing outside her days: today, a day of Pavel's, the last day of his
  -- second period right before hers, the day after hers, and yesterday.
  foreach v_d in array array[v_today, v_today + 2, v_today + 9, v_today + 17,
                             v_today - 1] loop
    perform pg_temp.expect_day_rpcs(v_d, v_b1, v_b2, 'not_allowed');
  end loop;

  -- The other right is held only while on duty: today she books and
  -- cancels for nobody, her own days included.
  begin
    perform create_reservation(v_wanda, v_today + 11, v_b1, 3::smallint);
    raise exception 'FAIL: a duty still ahead booked for another';
  exception when others then
    if sqlerrm <> 'not_allowed' then raise; end if;
  end;
  begin
    perform cancel_reservation(v_res);
    raise exception 'FAIL: a duty still ahead cancelled another''s training';
  exception when others then
    if sqlerrm <> 'not_allowed' then raise; end if;
  end;
  -- Re-seating is both: it is how the players of a block she removes get
  -- new seats, so it follows the day — hers, not the booking's clock.
  -- Not on a day that is not hers, even her own booking there ...
  begin
    perform move_reservation(current_setting('probe.duty_res_future')::uuid,
                             v_b1, 3);
    raise exception 'FAIL: a duty still ahead re-seated a training on a day that is not hers';
  exception when others then
    if sqlerrm <> 'not_allowed' then raise; end if;
  end;
  if not exists (select 1 from reservations
                 where id = v_res and block_id = v_b1 and lane = 2
                   and cancelled_at is null)
     or not exists (select 1 from reservations
                    where id = current_setting('probe.duty_res_future')::uuid
                      and block_id = v_b2 and lane = 1
                      and cancelled_at is null) then
    raise exception 'FAIL: a refused call by a duty still ahead changed a reservation';
  end if;
  -- ... on the days of her own period.
  perform move_reservation(v_res, v_b2, 3);
  if not exists (select 1 from reservations
                 where id = v_res and block_id = v_b2 and lane = 3
                   and cancelled_at is null) then
    raise exception 'FAIL: a duty still ahead could not re-seat a training on her own day';
  end if;
  raise notice 'OK: a duty starting later edits blocks and re-seats players on her own days only and books and cancels for no one until it starts (0050)';
end $$;

-- Who is no duty at all, on a day inside a period they are assigned to
-- (t+2 is Pavel's, t+7 his second period's): Pavel demoted to pending, the
-- placeholder Vilém, Wanda as a kiosk account assigned by hand (the
-- roster's RPC never does), Pavel as a superadmin visiting the other alley.
reset role;
update profiles set status = 'pending'
 where id = '50000000-0000-0000-0000-000000000011';
update profiles set role = 'kiosk'
 where id = '50000000-0000-0000-0000-000000000016';
insert into duty_assignments (period_id, user_id, tenant_id)
  select id, '50000000-0000-0000-0000-000000000016', tenant_id
    from duty_periods
   where tenant_id = '00000000-0000-0000-0000-000000000050'
     and starts_on = (now() at time zone 'Europe/Prague')::date + 6;
set local role authenticated;
do $$
declare
  v_today constant date := (now() at time zone 'Europe/Prague')::date;
  v_b1 constant uuid := current_setting('probe.duty_b1')::uuid;
  v_b2 constant uuid := current_setting('probe.duty_b2')::uuid;
  v_who text;
begin
  foreach v_who in array array[
      '50000000-0000-0000-0000-000000000011',   -- Pavel, pending
      '50000000-0000-0000-0000-000000000015',   -- Vilém, placeholder
      '50000000-0000-0000-0000-000000000016']   -- Wanda, kiosk
  loop
    perform set_config('request.jwt.claims',
      '{"sub":"' || v_who || '","role":"authenticated"}', true);
    perform pg_temp.expect_day_rpcs(v_today + 2, v_b1, v_b2, 'not_allowed');
    perform pg_temp.expect_day_rpcs(v_today + 7, v_b1, v_b2, 'not_allowed');
    begin
      perform add_special_block('07:20', '07:30');
      raise exception 'FAIL: % added a block', v_who;
    exception when others then
      if sqlerrm <> 'not_allowed' then raise; end if;
    end;
  end loop;
  raise notice 'OK: a pending player, a placeholder and a kiosk account assigned to a period still edit no block (0050)';
end $$;
reset role;
update profiles set status = 'approved'
 where id = '50000000-0000-0000-0000-000000000011';
update profiles set role = 'player'
 where id = '50000000-0000-0000-0000-000000000016';
delete from duty_assignments
 where user_id = '50000000-0000-0000-0000-000000000016';
update profiles
   set superadmin = true, home_tenant_id = '00000000-0000-0000-0000-000000000050'
 where id = '50000000-0000-0000-0000-000000000011';
set local role authenticated;
set local request.jwt.claims =
  '{"sub":"50000000-0000-0000-0000-000000000011","role":"authenticated"}';
select switch_tenant('00000000-0000-0000-0000-000000000002');
do $$
declare
  v_today constant date := (now() at time zone 'Europe/Prague')::date;
begin
  perform pg_temp.expect_day_rpcs(v_today + 2,
    current_setting('probe.duty_b1')::uuid,
    current_setting('probe.duty_b2')::uuid, 'not_allowed');
  begin
    perform add_special_block('07:20', '07:30');
    raise exception 'FAIL: a visiting superadmin added a block as the other alley''s duty';
  exception when others then
    if sqlerrm <> 'not_allowed' then raise; end if;
  end;
  raise notice 'OK: a visiting superadmin edits no block as the duty of his own alley (0050)';
end $$;
select switch_tenant('00000000-0000-0000-0000-000000000050');
reset role;
update profiles set superadmin = false, home_tenant_id = null
 where id = '50000000-0000-0000-0000-000000000011';

-- The end of a duty, to the day: Pavel's second period goes and the first
-- one is moved to [today − 8, today − 1] — over since yesterday: no block,
-- no day, not even yesterday's own (a past day is date_past inside a period,
-- but today is not covered at all). Then to [today − 8, today]: it ends
-- today, and today is still his (the blocks of the last seconds, which have
-- not started: the same ones 21e uses).
reset role;
delete from duty_periods
 where tenant_id = '00000000-0000-0000-0000-000000000050'
   and starts_on = (now() at time zone 'Europe/Prague')::date + 6;
update duty_periods
   set starts_on = (now() at time zone 'Europe/Prague')::date - 8,
       ends_on = (now() at time zone 'Europe/Prague')::date - 1
 where tenant_id = '00000000-0000-0000-0000-000000000050'
   and starts_on = (now() at time zone 'Europe/Prague')::date - 1;
set local role authenticated;
set local request.jwt.claims =
  '{"sub":"50000000-0000-0000-0000-000000000011","role":"authenticated"}';
do $$
declare
  v_today constant date := (now() at time zone 'Europe/Prague')::date;
  v_b1 constant uuid := current_setting('probe.duty_b1')::uuid;
  v_b2 constant uuid := current_setting('probe.duty_b2')::uuid;
begin
  begin
    perform add_special_block('07:20', '07:30');
    raise exception 'FAIL: a duty that ended yesterday added a block';
  exception when others then
    if sqlerrm <> 'not_allowed' then raise; end if;
  end;
  perform pg_temp.expect_day_rpcs(v_today + 2, v_b1, v_b2, 'not_allowed');
  perform pg_temp.expect_day_rpcs(v_today, v_b1, v_b2, 'not_allowed');
  perform pg_temp.expect_day_rpcs(v_today - 5, v_b1, v_b2, 'date_past');
  begin
    perform move_reservation(gen_random_uuid(), v_b1, 1);
    raise exception 'FAIL: a duty that ended yesterday re-seated a training';
  exception when others then
    if sqlerrm <> 'not_allowed' then raise; end if;
  end;
  raise notice 'OK: a duty that ended yesterday adds no block, edits no future day and re-seats no one (0050)';
end $$;
reset role;
update duty_periods
   set ends_on = (now() at time zone 'Europe/Prague')::date
 where tenant_id = '00000000-0000-0000-0000-000000000050'
   and starts_on = (now() at time zone 'Europe/Prague')::date - 8;
set local role authenticated;
do $$
declare
  v_today constant date := (now() at time zone 'Europe/Prague')::date;
  v_b1 constant uuid := current_setting('probe.duty_b1')::uuid;
  v_b2 constant uuid := current_setting('probe.duty_b2')::uuid;
  v_id uuid;
begin
  v_id := add_special_block('07:20', '07:30');
  perform pg_temp.expect_day_rpcs(v_today,
    current_setting('probe.duty_l1')::uuid,
    current_setting('probe.duty_l2')::uuid, 'ok');
  perform pg_temp.expect_day_rpcs(v_today + 1, v_b1, v_b2, 'not_allowed');
  raise notice 'OK: a duty ending today still edits today, no day after it (0050)';
end $$;

-- The admin needs no period at all: the duties' days and the days nobody
-- serves are hers, and what Pavel left on them goes with her edits.
set local request.jwt.claims =
  '{"sub":"50000000-0000-0000-0000-000000000010","role":"authenticated"}';
do $$
declare
  v_today constant date := (now() at time zone 'Europe/Prague')::date;
  v_b1 constant uuid := current_setting('probe.duty_b1')::uuid;
  v_b2 constant uuid := current_setting('probe.duty_b2')::uuid;
  v_d date;
begin
  foreach v_d in array array[v_today + 10, v_today + 11, v_today + 20,
                             v_today + 40] loop
    perform pg_temp.expect_day_rpcs(v_d, v_b1, v_b2, 'ok');
    if exists (select 1 from day_overrides where date = v_d) then
      raise exception 'FAIL: the admin''s edit of % left an override', v_d;
    end if;
  end loop;
  raise notice 'OK: the admin edits blocks on any day, a duty''s and nobody''s alike (0050)';
end $$;
-- 21i2. No day named is no day to edit: the four day RPCs refuse a null
-- date with date_past, the admin's too, before anything is read or written
-- (a null would pass `p_date < today` and read as „any day“). The one
-- date-less edit, add_special_block, asks its own gate instead
-- (duty_edit_days_gate: a period of theirs that has not ended).
do $$
declare
  v_b1 constant uuid := current_setting('probe.duty_b1')::uuid;
  v_b2 constant uuid := current_setting('probe.duty_b2')::uuid;
begin
  perform pg_temp.expect_day_rpcs(null, v_b1, v_b2, 'date_past');
  raise notice 'OK: the admin''s day RPCs refuse a null date (0050)';
end $$;
set local request.jwt.claims =
  '{"sub":"50000000-0000-0000-0000-000000000011","role":"authenticated"}';
do $$
declare
  v_b1 constant uuid := current_setting('probe.duty_b1')::uuid;
  v_b2 constant uuid := current_setting('probe.duty_b2')::uuid;
begin
  perform pg_temp.expect_day_rpcs(null, v_b1, v_b2, 'date_past');
  perform add_special_block('21:00', '22:00');
  raise notice 'OK: the duty''s day RPCs refuse a null date, add_special_block still works (0050)';
end $$;

-- 21i3. The gate reads Prague's today, not the session's: under a zone
-- ahead of Prague (Pacific/Kiritimati, +12 h) and one behind it
-- (Etc/GMT+12, −14 h), Pavel's today is still his to edit and his yesterday
-- still past. CI's session is UTC, where current_date and Prague's date
-- nearly always agree, so without this a current_date in the gate would
-- pass unseen. Each zone differs from Prague for part of the day; together
-- they cover every hour. The probe calls delete_day_override and rolls its
-- own subtransaction back, so it writes nothing either way.
create function pg_temp.edit_gate_says(p_date date) returns text
language plpgsql as $$
begin
  begin
    perform delete_day_override(p_date);
    raise exception 'probe_ok';
  exception when others then
    return sqlerrm;
  end;
end $$;
do $$
declare
  v_today constant date := (now() at time zone 'Europe/Prague')::date;
  v_zone text;
begin
  foreach v_zone in array array['Pacific/Kiritimati', 'Etc/GMT+12', 'UTC'] loop
    perform set_config('timezone', v_zone, true);
    if pg_temp.edit_gate_says(v_today) <> 'probe_ok' then
      raise exception 'FAIL: under % the duty could not edit Prague''s today: %',
        v_zone, pg_temp.edit_gate_says(v_today);
    end if;
    if pg_temp.edit_gate_says(v_today - 1) <> 'date_past' then
      raise exception 'FAIL: under % Prague''s yesterday was not past: %',
        v_zone, pg_temp.edit_gate_says(v_today - 1);
    end if;
  end loop;
  raise notice 'OK: the edit gate follows Prague''s date in any session zone (0050)';
end $$;
reset timezone;

reset role;
update schedule_settings set max_active_reservations = 2
 where tenant_id = '00000000-0000-0000-0000-000000000050';

-- The next sections start without duties.
reset role;
delete from duty_periods
 where tenant_id in ('00000000-0000-0000-0000-00000000000a',
                     '00000000-0000-0000-0000-000000000002',
                     '00000000-0000-0000-0000-000000000050');

-- 0050 — připomínka služby ------------------------------------------------------
-- The reminder before a canteen duty: due_duty_reminders() answers every
-- minute, like due_reminders(), which duty is worth a reminder right now
-- (the alley switched it on, 18:00 Prague on the lead day has passed, the
-- duty has not started, no receipt for this start). Accounts only.

-- 22. Fixtures in S (21's alley and players), a four-day lead:
--   p0  today               Quido               started today: never
--   p1  today + 1           Pavel, Alena (the admin), Vilém (placeholder)
--                           lead day today − 3: due
--   p2  today + 2           Tereza, Petra (pending), the kiosk
--                           lead day today − 2: due, for Tereza only
--   p3  today + 4           Urban               lead day today: due from 18:00
--   p4  today + 5 … + 8     Wanda               lead day tomorrow: not yet
-- today + 3 stays free for moving p1 (22e). The pending player and the
-- kiosk are assigned directly: duty_set_assignees refuses both, and the
-- reminder must hold that line on its own. The tick's gate is asked
-- directly, so everything else that could wake it is cleared first (the
-- job queue, every player's own reminders, every other alley's duty
-- reminder); the transaction's rollback puts it all back.
-- And a control in tenant B, off, with a two-day lead of its own:
--   b1  today + 1           Cizí                lead day yesterday: due once B is on
--   b3  today + 3           Cizí                lead day tomorrow: not yet
--                                               (S's four days would ring it)
-- Each alley answers with its own switch (22c) and its own lead (22g).
reset role;
do $$
declare
  v_s constant uuid := '00000000-0000-0000-0000-000000000050';
  v_b constant uuid := '00000000-0000-0000-0000-000000000002';
  v_today constant date := (now() at time zone 'Europe/Prague')::date;
  v_id uuid;
begin
  insert into profiles (id, tenant_id, display_name, email, role, status)
  values
    ('50000000-0000-0000-0000-000000000017', v_s, 'Petra Čekající',
     'duty-petra@example.com', 'player', 'pending'),
    ('50000000-0000-0000-0000-000000000018', v_s, 'Kiosk S',
     'duty-kiosk@example.com', 'kiosk', 'approved');
  update profiles set fcm_token = 'tok-pavel'
   where id = '50000000-0000-0000-0000-000000000011';

  insert into duty_periods (tenant_id, starts_on, ends_on)
    values (v_s, v_today, v_today) returning id into v_id;
  insert into duty_assignments (period_id, user_id, tenant_id) values
    (v_id, '50000000-0000-0000-0000-000000000012', v_s);
  insert into duty_periods (tenant_id, starts_on, ends_on)
    values (v_s, v_today + 1, v_today + 1) returning id into v_id;
  insert into duty_assignments (period_id, user_id, tenant_id) values
    (v_id, '50000000-0000-0000-0000-000000000011', v_s),
    (v_id, '50000000-0000-0000-0000-000000000010', v_s),
    (v_id, '50000000-0000-0000-0000-000000000015', v_s);
  perform set_config('probe.rem_p1', v_id::text, true);
  insert into duty_periods (tenant_id, starts_on, ends_on)
    values (v_s, v_today + 2, v_today + 2) returning id into v_id;
  insert into duty_assignments (period_id, user_id, tenant_id) values
    (v_id, '50000000-0000-0000-0000-000000000013', v_s),
    (v_id, '50000000-0000-0000-0000-000000000017', v_s),
    (v_id, '50000000-0000-0000-0000-000000000018', v_s);
  perform set_config('probe.rem_p2', v_id::text, true);
  insert into duty_periods (tenant_id, starts_on, ends_on)
    values (v_s, v_today + 4, v_today + 4) returning id into v_id;
  insert into duty_assignments (period_id, user_id, tenant_id) values
    (v_id, '50000000-0000-0000-0000-000000000014', v_s);
  perform set_config('probe.rem_p3', v_id::text, true);
  insert into duty_periods (tenant_id, starts_on, ends_on)
    values (v_s, v_today + 5, v_today + 8) returning id into v_id;
  insert into duty_assignments (period_id, user_id, tenant_id) values
    (v_id, '50000000-0000-0000-0000-000000000016', v_s);
  perform set_config('probe.rem_p4', v_id::text, true);

  insert into duty_periods (tenant_id, starts_on, ends_on)
    values (v_b, v_today + 1, v_today + 1) returning id into v_id;
  insert into duty_assignments (period_id, user_id, tenant_id) values
    (v_id, '20000000-0000-0000-0000-0000000000b1', v_b);
  perform set_config('probe.rem_b1', v_id::text, true);
  insert into duty_periods (tenant_id, starts_on, ends_on)
    values (v_b, v_today + 3, v_today + 3) returning id into v_id;
  insert into duty_assignments (period_id, user_id, tenant_id) values
    (v_id, '20000000-0000-0000-0000-0000000000b1', v_b);
  perform set_config('probe.rem_b3', v_id::text, true);

  update schedule_settings
     set duty_reminder_enabled = false, duty_reminder_days = 4
   where tenant_id = v_s;
  update schedule_settings
     set duty_reminder_enabled = false, duty_reminder_days = 2
   where tenant_id = v_b;
  delete from notification_jobs;
  update profiles set notify_before_minutes = '{}'
   where notify_before_minutes <> '{}';
  update schedule_settings set duty_reminder_enabled = false
   where duty_reminder_enabled;
end $$;

-- 22a. The machinery is the server's: only the service may ask what is
-- due, and the tick's gate stays the service's too.
do $$
begin
  if has_function_privilege('authenticated', 'public.due_duty_reminders()', 'execute')
     or has_function_privilege('anon', 'public.due_duty_reminders()', 'execute') then
    raise exception 'FAIL: the app can ask for the due duty reminders';
  end if;
  if not has_function_privilege('service_role', 'public.due_duty_reminders()', 'execute') then
    raise exception 'FAIL: notify cannot ask for the due duty reminders';
  end if;
  if not (select prosecdef and provolatile = 's' from pg_proc
           where oid = 'public.due_duty_reminders()'::regprocedure) then
    raise exception 'FAIL: due_duty_reminders must be security definer and stable';
  end if;
  if has_function_privilege('authenticated', 'public.notifications_due()', 'execute')
     or has_function_privilege('anon', 'public.notifications_due()', 'execute')
     or not has_function_privilege('service_role', 'public.notifications_due()', 'execute') then
    raise exception 'FAIL: notifications_due() is no longer the service''s alone';
  end if;
  raise notice 'OK: only the service asks which duty reminders are due (0050)';
end $$;

-- 22b. Off (the default), nothing is due, and the tick sleeps.
do $$
begin
  if exists (select 1 from due_duty_reminders()) then
    raise exception 'FAIL: a duty reminder is due with the reminder off';
  end if;
  if exists (select 1 from due_reminders())
     or exists (select 1 from notification_jobs) then
    raise exception 'FAIL: the fixtures left something else due';
  end if;
  if notifications_due() then
    raise exception 'FAIL: the tick would wake with nothing due';
  end if;
  raise notice 'OK: with the duty reminder off nothing is due (0050)';
end $$;

-- 22c. On: one row per account and period whose lead day's 18:00 has
-- passed and which has not started — never a placeholder, a pending
-- player or the kiosk. Today's 18:00 is the one boundary a run can land on
-- either side of: p3 is due exactly when the Prague clock is past it.
-- S's switch is S's alone: B, still off, reminds nobody, though at S's
-- four days both of B's duties would be due.
do $$
declare
  v_today constant date := (now() at time zone 'Europe/Prague')::date;
  v_p1 constant uuid := current_setting('probe.rem_p1')::uuid;
  v_p2 constant uuid := current_setting('probe.rem_p2')::uuid;
  v_p3 constant uuid := current_setting('probe.rem_p3')::uuid;
  v_evening constant boolean :=
    (now() at time zone 'Europe/Prague')::time >= time '18:00';
  v_row record;
  v_got text;
  v_want text;
begin
  update schedule_settings set duty_reminder_enabled = true
   where tenant_id = '00000000-0000-0000-0000-000000000050';

  if exists (select 1 from due_duty_reminders()
              where period_id in (current_setting('probe.rem_b1')::uuid,
                                  current_setting('probe.rem_b3')::uuid)
                 or user_id = '20000000-0000-0000-0000-0000000000b1') then
    raise exception 'FAIL: alley B reminds its duty with its own reminder off, because S has it on';
  end if;

  select string_agg(g, ' ' order by g) into v_got
    from (select d.period_id::text || '/' || d.user_id::text as g
            from due_duty_reminders() d) x;
  select string_agg(w, ' ' order by w) into v_want
    from unnest(array[
      v_p1::text || '/50000000-0000-0000-0000-000000000010',
      v_p1::text || '/50000000-0000-0000-0000-000000000011',
      v_p2::text || '/50000000-0000-0000-0000-000000000013']
      || case when v_evening
              then array[v_p3::text || '/50000000-0000-0000-0000-000000000014']
              else '{}'::text[] end) w;
  if v_got is distinct from v_want then
    raise exception 'FAIL: due duty reminders % (evening %), expected %',
      v_got, v_evening, v_want;
  end if;

  select * into v_row from due_duty_reminders()
   where user_id = '50000000-0000-0000-0000-000000000011';
  if v_row.email <> 'duty-pavel@example.com'
     or v_row.fcm_token is distinct from 'tok-pavel'
     or v_row.starts_on <> v_today + 1 or v_row.ends_on <> v_today + 1
     or v_row.days <> 4
     or v_row.co_assignees <> array['Alena Správcová', 'Vilém bez účtu'] then
    raise exception 'FAIL: Pavel''s reminder row is wrong: %', v_row;
  end if;
  -- The placeholder is named among the others: they serve too.
  select * into v_row from due_duty_reminders()
   where user_id = '50000000-0000-0000-0000-000000000010';
  if v_row.co_assignees <> array['Pavel Kantýnský', 'Vilém bez účtu'] then
    raise exception 'FAIL: the admin''s co-assignees are wrong: %', v_row.co_assignees;
  end if;

  if not notifications_due() then
    raise exception 'FAIL: the tick would sleep through a due duty reminder';
  end if;
  raise notice 'OK: a duty reminder is due from 18:00 on the lead day until the duty starts, for its accounts only (0050)';
end $$;

-- 22d. The account's standing decides, as it does for the rights: a
-- player demoted to pending is not reminded, and is again once approved.
do $$
begin
  update profiles set status = 'pending'
   where id = '50000000-0000-0000-0000-000000000011';
  if exists (select 1 from due_duty_reminders()
              where user_id = '50000000-0000-0000-0000-000000000011') then
    raise exception 'FAIL: a pending player is reminded of a duty';
  end if;
  update profiles set status = 'approved'
   where id = '50000000-0000-0000-0000-000000000011';
  if not exists (select 1 from due_duty_reminders()
                  where user_id = '50000000-0000-0000-0000-000000000011') then
    raise exception 'FAIL: the re-approved player lost the reminder';
  end if;
  raise notice 'OK: a pending player gets no duty reminder until approved again (0050)';
end $$;

-- 22e. The ledger, with 0049's meaning: the receipt notify writes
-- ('d:<period>', the lead in minutes, Prague midnight of the first day)
-- silences that duty for that player; a receipt at a closer lead covers a
-- longer one; a period moved to another date rings again, and is silenced
-- again by a receipt for its new start.
do $$
declare
  v_today constant date := (now() at time zone 'Europe/Prague')::date;
  v_p1 constant uuid := current_setting('probe.rem_p1')::uuid;
  v_pavel constant uuid := '50000000-0000-0000-0000-000000000011';
  v_alena constant uuid := '50000000-0000-0000-0000-000000000010';
begin
  perform mark_reminder_sent(v_pavel, 'd:' || v_p1, 4 * 1440,
    (v_today + 1)::timestamp at time zone 'Europe/Prague');
  if exists (select 1 from due_duty_reminders() where user_id = v_pavel) then
    raise exception 'FAIL: a marked duty reminder is still due';
  end if;
  if not exists (select 1 from due_duty_reminders() where user_id = v_alena)
     or not exists (select 1 from due_duty_reminders()
                     where user_id = '50000000-0000-0000-0000-000000000013') then
    raise exception 'FAIL: one player''s receipt silenced the others';
  end if;

  perform mark_reminder_sent(v_alena, 'd:' || v_p1, 1440,
    (v_today + 1)::timestamp at time zone 'Europe/Prague');
  if exists (select 1 from due_duty_reminders() where user_id = v_alena) then
    raise exception 'FAIL: a receipt at a closer lead did not cover the longer one';
  end if;

  update duty_periods set starts_on = v_today + 3, ends_on = v_today + 3
   where id = v_p1;
  if (select count(*) from due_duty_reminders()
       where period_id = v_p1 and starts_on = v_today + 3
         and user_id in (v_pavel, v_alena)) <> 2 then
    raise exception 'FAIL: a moved duty did not ring again';
  end if;
  perform mark_reminder_sent(v_pavel, 'd:' || v_p1, 4 * 1440,
    (v_today + 3)::timestamp at time zone 'Europe/Prague');
  if exists (select 1 from due_duty_reminders() where user_id = v_pavel)
     or (select count(*) from reminders_sent
          where user_id = v_pavel and event_key = 'd:' || v_p1) <> 1 then
    raise exception 'FAIL: the receipt did not move to the new start';
  end if;
  raise notice 'OK: a receipt silences the duty for its start; a moved duty rings again (0050)';
end $$;

-- 22f. Switched off, nothing is due and the tick sleeps; the lead stays.
do $$
begin
  update schedule_settings set duty_reminder_enabled = false
   where tenant_id = '00000000-0000-0000-0000-000000000050';
  if exists (select 1 from due_duty_reminders()) then
    raise exception 'FAIL: switching the reminder off left one due';
  end if;
  if notifications_due() then
    raise exception 'FAIL: the tick wakes for a reminder that is off';
  end if;
  if (select duty_reminder_days from schedule_settings
       where tenant_id = '00000000-0000-0000-0000-000000000050') <> 4 then
    raise exception 'FAIL: switching off lost the lead';
  end if;
  raise notice 'OK: switched off, no duty reminder is due (0050)';
end $$;

-- 22g. The other way round, each alley with its own switch and lead: B on
-- at two days and S off remind B's duty tomorrow alone, told as two days
-- ahead; B's duty in three days waits for tomorrow's 18:00, and S's
-- duties stay silent.
do $$
declare
  v_b1 constant uuid := current_setting('probe.rem_b1')::uuid;
  v_got text;
  v_want text;
begin
  update schedule_settings set duty_reminder_enabled = true
   where tenant_id = '00000000-0000-0000-0000-000000000002';

  select string_agg(d.period_id::text || '/' || d.user_id::text || '/' || d.days,
                    ' ' order by d.period_id::text, d.user_id::text)
    into v_got
    from due_duty_reminders() d;
  v_want := v_b1::text || '/20000000-0000-0000-0000-0000000000b1/2';
  if v_got is distinct from v_want then
    raise exception 'FAIL: with B on at two days and S off, due %, expected %',
      v_got, v_want;
  end if;
  if not notifications_due() then
    raise exception 'FAIL: the tick would sleep through B''s due duty reminder';
  end if;
  raise notice 'OK: each alley''s duty reminder follows its own switch and its own lead (0050)';
end $$;

-- ---------------------------------------------------------------------------
-- 0051: Zprávy a nástěnka. The admin and the player on duty write to a
-- block, a day or everyone; any account player writes to the admins or to
-- today's duty. Recipients are materialised by message_send; reactions are
-- each recipient's own-row write, seen by every participant.
reset role;

-- 23. Fixtures for 0051 in an alley of its own, T: Adam the admin, Bára on
-- duty from today for a week (with Emil, a placeholder, on the same
-- period), the kiosk, and Filip, an account still pending (the admin has
-- not approved him, or took the approval back). Today block 16:00 holds
-- Cyril, Dana, Emil and Adam live and Bára cancelled; Dana and Filip are
-- in block 19:00 today. Tomorrow block 16:00 holds Dana, Bára and Filip.
-- So every day/block/duty recipient set has a placeholder, an author, a
-- cancelled booking, a double booking and a pending account to leave out.
-- Block 17:00 has nobody; block 18:00 is a day-only block (inactive, 21's
-- shape). Every day is a training day, 4 lanes.
insert into tenants (id, name, status) values
  ('00000000-0000-0000-0000-000000000051', 'Kuželna T (0051)', 'approved');
do $$
declare
  v_t constant uuid := '00000000-0000-0000-0000-000000000051';
  v_today constant date := (now() at time zone 'Europe/Prague')::date;
  v_b1 uuid;
  v_b2 uuid;
  v_b3 uuid;
  v_off uuid;
  v_period uuid;
begin
  insert into profiles (id, tenant_id, display_name, email, role, status)
  values
    ('51000000-0000-0000-0000-000000000010', v_t, 'Adam Správce',
     'msg-adam@example.com', 'admin', 'approved'),
    ('51000000-0000-0000-0000-000000000011', v_t, 'Bára Kantýnská',
     'msg-bara@example.com', 'player', 'approved'),
    ('51000000-0000-0000-0000-000000000012', v_t, 'Cyril Hráč',
     'msg-cyril@example.com', 'player', 'approved'),
    ('51000000-0000-0000-0000-000000000013', v_t, 'Dana Hráčka',
     'msg-dana@example.com', 'player', 'approved'),
    ('51000000-0000-0000-0000-000000000016', v_t, 'Filip Čekatel',
     'msg-filip@example.com', 'player', 'pending');
  insert into profiles (id, tenant_id, display_name, role, status, placeholder)
  values ('51000000-0000-0000-0000-000000000014', v_t, 'Emil bez účtu',
          'player', 'approved', true);
  insert into profiles (id, tenant_id, display_name, email, role, status)
  values ('51000000-0000-0000-0000-000000000015', v_t, 'Kiosek',
          'msg-kiosk@example.com', 'kiosk', 'approved');
  update schedule_settings
     set training_weekdays = '{1,2,3,4,5,6,7}', lane_count = 4
   where tenant_id = v_t;
  insert into time_blocks (tenant_id, starts_at, ends_at, position)
    values (v_t, '16:00', '17:00', 0) returning id into v_b1;
  insert into time_blocks (tenant_id, starts_at, ends_at, position)
    values (v_t, '17:00', '18:00', 1) returning id into v_b2;
  insert into time_blocks (tenant_id, starts_at, ends_at, position, active)
    values (v_t, '18:00', '19:00', -1, false) returning id into v_off;
  insert into time_blocks (tenant_id, starts_at, ends_at, position)
    values (v_t, '19:00', '20:00', 2) returning id into v_b3;
  insert into duty_periods (tenant_id, starts_on, ends_on)
    values (v_t, v_today, v_today + 6) returning id into v_period;
  insert into duty_assignments (period_id, user_id, tenant_id)
  values (v_period, '51000000-0000-0000-0000-000000000011', v_t),
         (v_period, '51000000-0000-0000-0000-000000000014', v_t);
  insert into reservations (tenant_id, player_id, date, block_id, lane,
                            created_via, created_by)
  values
    (v_t, '51000000-0000-0000-0000-000000000012', v_today, v_b1, 1,
     'app', '51000000-0000-0000-0000-000000000012'),
    (v_t, '51000000-0000-0000-0000-000000000013', v_today, v_b1, 2,
     'app', '51000000-0000-0000-0000-000000000013'),
    (v_t, '51000000-0000-0000-0000-000000000014', v_today, v_b1, 3,
     'admin', '51000000-0000-0000-0000-000000000010'),
    (v_t, '51000000-0000-0000-0000-000000000010', v_today, v_b1, 4,
     'app', '51000000-0000-0000-0000-000000000010'),
    (v_t, '51000000-0000-0000-0000-000000000013', v_today, v_b3, 1,
     'app', '51000000-0000-0000-0000-000000000013'),
    (v_t, '51000000-0000-0000-0000-000000000013', v_today + 1, v_b1, 1,
     'app', '51000000-0000-0000-0000-000000000013'),
    (v_t, '51000000-0000-0000-0000-000000000011', v_today + 1, v_b1, 2,
     'app', '51000000-0000-0000-0000-000000000011'),
    (v_t, '51000000-0000-0000-0000-000000000016', v_today, v_b3, 2,
     'admin', '51000000-0000-0000-0000-000000000010'),
    (v_t, '51000000-0000-0000-0000-000000000016', v_today + 1, v_b1, 3,
     'admin', '51000000-0000-0000-0000-000000000010');
  insert into reservations (tenant_id, player_id, date, block_id, lane,
                            created_via, created_by, cancelled_at, cancelled_via)
  values (v_t, '51000000-0000-0000-0000-000000000011', v_today, v_b1, 1,
          'app', '51000000-0000-0000-0000-000000000011', now(), 'app');
  perform set_config('probe.msg_b1', v_b1::text, true);
  perform set_config('probe.msg_b2', v_b2::text, true);
  perform set_config('probe.msg_off', v_off::text, true);
  perform set_config('probe.msg_period', v_period::text, true);
end $$;

-- 23a. The tables exist, RLS is on, grants match 0046 (select only for
-- authenticated + the three own-row UPDATE columns on message_recipients).
do $$
declare
  v_bad text;
begin
  -- Schema-qualified: Supabase has a realtime.messages of its own.
  if not exists (select 1 from pg_tables
                  where schemaname = 'public' and tablename = 'messages') then
    raise exception 'FAIL: messages table missing';
  end if;
  if not exists (select 1 from pg_tables
                  where schemaname = 'public' and tablename = 'message_recipients') then
    raise exception 'FAIL: message_recipients table missing';
  end if;
  if exists (select 1 from pg_class
              where oid in ('public.messages'::regclass,
                            'public.message_recipients'::regclass)
                and not relrowsecurity) then
    raise exception 'FAIL: RLS is off on messages or message_recipients';
  end if;
  select string_agg(table_name || '.' || privilege_type, ', ')
    into v_bad
    from information_schema.table_privileges
   where table_schema = 'public' and grantee = 'anon'
     and table_name in ('messages', 'message_recipients');
  if v_bad is not null then
    raise exception 'FAIL: anon has %', v_bad;
  end if;
  select string_agg(table_name || '.' || privilege_type, ', ')
    into v_bad
    from information_schema.table_privileges
   where table_schema = 'public' and grantee = 'authenticated'
     and table_name in ('messages', 'message_recipients')
     and privilege_type <> 'SELECT';
  if v_bad is not null then
    raise exception 'FAIL: authenticated has non-select %', v_bad;
  end if;
  if not (has_column_privilege('authenticated', 'message_recipients', 'read_at', 'update')
      and has_column_privilege('authenticated', 'message_recipients', 'reaction', 'update')
      and has_column_privilege('authenticated', 'message_recipients', 'reply', 'update')) then
    raise exception 'FAIL: authenticated missing the own-row update columns';
  end if;
  if has_column_privilege('authenticated', 'message_recipients', 'user_id', 'update') then
    raise exception 'FAIL: authenticated can update user_id — that would let a player steal a recipient row';
  end if;
  -- Column by column (a column grant is not in table_privileges): exactly
  -- read_at, reaction and reply are the app's to update; nothing of
  -- messages, and no column of either table is the app's to insert.
  select string_agg(attname, ',' order by attname) into v_bad
    from pg_attribute
   where attrelid = 'public.message_recipients'::regclass and attnum > 0
     and not attisdropped
     and has_column_privilege('authenticated', attrelid, attnum, 'update');
  if v_bad is distinct from 'reaction,read_at,reply' then
    raise exception 'FAIL: authenticated may update message_recipients columns %, not exactly reaction,read_at,reply', v_bad;
  end if;
  select string_agg(attrelid::regclass || '.' || attname || ':' || p.priv, ', ') into v_bad
    from pg_attribute, unnest(array['update', 'insert']) as p(priv)
   where attrelid in ('public.messages'::regclass, 'public.message_recipients'::regclass)
     and attnum > 0 and not attisdropped
     and (p.priv = 'insert' or attrelid = 'public.messages'::regclass)
     and has_column_privilege('authenticated', attrelid, attnum, p.priv);
  if v_bad is not null then
    raise exception 'FAIL: authenticated may write %', v_bad;
  end if;
  raise notice 'OK: messages/message_recipients exist with the 0046 grant shape (0051)';
end $$;

-- 23b. message_send as the admin: a notice reaches every account player
-- of the alley but the author (the placeholder, the kiosk and Filip, still
-- pending, are out), and remembers who sent it as an admin.
set local role authenticated;
set local request.jwt.claims =
  '{"sub":"51000000-0000-0000-0000-000000000010","role":"authenticated"}'; -- Adam, admin
do $$
declare
  v_id uuid;
  v_got text;
begin
  v_id := message_send('notice', 'all', null, null, 'Nové dráhy', 'Od pondělí nové dráhy.',
                        null, true);
  select string_agg(user_id::text, ',' order by user_id) into v_got
    from message_recipients where message_id = v_id;
  if v_got is distinct from (
       select string_agg(id::text, ',' order by id) from profiles
        where tenant_id = '00000000-0000-0000-0000-000000000051'
          and status = 'approved' and role <> 'kiosk' and not placeholder
          and id <> '51000000-0000-0000-0000-000000000010') then
    raise exception 'FAIL: notice recipients wrong (placeholder/kiosk/pending/author must be out): %', v_got;
  end if;
  if (select author_role from messages where id = v_id) <> 'admin' then
    raise exception 'FAIL: notice author_role should be admin';
  end if;
  perform set_config('probe.msg_notice', v_id::text, true);
  raise notice 'OK: a notice reaches every account player but the author (0051)';
end $$;

-- 23b2. The board is not recipient-based: in an alley whose admin is the
-- only account so far (a new alley; U has Uršula and the kiosk), a notice
-- still goes up — with no recipient rows — and she reads it; a message
-- there has nobody to go to (no_recipients).
reset role;
insert into tenants (id, name, status) values
  ('00000000-0000-0000-0000-000000000052', 'Kuželna U (0051)', 'approved');
insert into profiles (id, tenant_id, display_name, email, role, status)
values
  ('52000000-0000-0000-0000-000000000010', '00000000-0000-0000-0000-000000000052',
   'Uršula Sama', 'msg-ursula@example.com', 'admin', 'approved'),
  ('52000000-0000-0000-0000-000000000015', '00000000-0000-0000-0000-000000000052',
   'Kiosek U', 'msg-kiosk-u@example.com', 'kiosk', 'approved');
set local role authenticated;
set local request.jwt.claims =
  '{"sub":"52000000-0000-0000-0000-000000000010","role":"authenticated"}'; -- Uršula, U
do $$
declare
  v_id uuid;
begin
  v_id := message_send('notice', 'all', null, null, 'Klíč', 'Náhradní klíč je u baru.',
                        null, true);
  if (select count(*) from message_recipients where message_id = v_id) <> 0 then
    raise exception 'FAIL: a notice in an alley of one got recipient rows';
  end if;
  if (select count(*) from messages where id = v_id) <> 1 then
    raise exception 'FAIL: the lone admin does not read her own notice';
  end if;
  begin
    perform message_send('message', 'admins', null, null, null, 'Haló?', null, true);
    raise exception 'FAIL: a message in an alley of one went out';
  exception when others then
    if sqlerrm <> 'no_recipients' then raise; end if;
  end;
  raise notice 'OK: a notice goes up with no one else in the alley, a message says no_recipients (0051)';
end $$;
set local request.jwt.claims =
  '{"sub":"51000000-0000-0000-0000-000000000010","role":"authenticated"}'; -- Adam, admin

-- 23c. day: everyone with a live reservation that date, any block, once
-- (Dana is booked twice) — not Emil the placeholder, not Adam the author,
-- not Bára whose booking is cancelled, not Filip whose account is pending
-- (the `players` view's rule, as for `all`).
do $$
declare
  v_id uuid;
  v_got text;
begin
  v_id := message_send('message', 'day', (now() at time zone 'Europe/Prague')::date, null,
                        null, 'Přijďte dřív.', null, true);
  select string_agg(user_id::text, ',' order by user_id) into v_got
    from message_recipients where message_id = v_id;
  if v_got is distinct from
     '51000000-0000-0000-0000-000000000012,51000000-0000-0000-0000-000000000013' then
    raise exception 'FAIL: day recipients wrong: %', v_got;
  end if;
  if (select on_date from messages where id = v_id)
       <> (now() at time zone 'Europe/Prague')::date then
    raise exception 'FAIL: day message keeps its on_date';
  end if;
  perform set_config('probe.msg_day', v_id::text, true);
  raise notice 'OK: a day message reaches the players booked that day (0051)';
end $$;

-- 23d. block: the same, that block only (the placeholder, the author and
-- the cancelled booking are all in it); a block nobody booked has no one
-- to tell (no_recipients).
do $$
declare
  v_id uuid;
  v_got text;
begin
  v_id := message_send('message', 'block', (now() at time zone 'Europe/Prague')::date,
                        current_setting('probe.msg_b1')::uuid, null, 'Dráha 3 nejede.',
                        null, true);
  select string_agg(user_id::text, ',' order by user_id) into v_got
    from message_recipients where message_id = v_id;
  if v_got is distinct from
     '51000000-0000-0000-0000-000000000012,51000000-0000-0000-0000-000000000013' then
    raise exception 'FAIL: block recipients wrong: %', v_got;
  end if;
  if (select block_id from messages where id = v_id)
       <> current_setting('probe.msg_b1')::uuid then
    raise exception 'FAIL: block message lost its block';
  end if;
  raise notice 'OK: a block message reaches the players booked in that block (0051)';
end $$;
do $$
begin
  perform message_send('message', 'block', (now() at time zone 'Europe/Prague')::date,
                        current_setting('probe.msg_b2')::uuid, null, 'Nikdo?', null, true);
  raise exception 'FAIL: a block nobody booked took a message';
exception when others then
  if sqlerrm <> 'no_recipients' then raise; end if;
  raise notice 'OK: a block nobody booked says no_recipients (0051)';
end $$;


-- 23e. What the admin sends is checked: a notice only to everyone, only
-- the two kinds, a day or a block needs its date, a notice its title of
-- at most 80 characters, counted as char_length counts them (code points:
-- 41 × 👍🏽 is 41 on screen but 82 here — title_too_long, never the raw
-- messages_title_check), every body is non-blank and short enough (500 /
-- 2000).
do $$
declare
  v_today constant date := (now() at time zone 'Europe/Prague')::date;
  v_case record;
begin
  for v_case in
    select * from (values
      ('notice', 'day', null::date, 'Nadpis', 'Text', 'invalid_audience'),
      ('notice', null, null::date, 'Nadpis', 'Text', 'invalid_audience'),
      ('chat', 'day', v_today, null, 'Text', 'invalid_kind'),
      ('message', 'everyone', v_today, null, 'Text', 'invalid_audience'),
      ('message', 'day', null::date, null, 'Text', 'date_past'),
      ('notice', 'all', null::date, '   ', 'Text', 'title_required'),
      -- Blank is any whitespace, not only spaces: newlines, tabs.
      ('notice', 'all', null::date, E'\n\t', E'\n\n', 'title_required'),
      ('notice', 'all', null::date, repeat('a', 81), 'Text', 'title_too_long'),
      ('notice', 'all', null::date, repeat('👍🏽', 41), 'Text', 'title_too_long'),
      ('notice', 'all', null::date, 'Nadpis', E'\n\n', 'body_required'),
      ('message', 'day', v_today, null, E' \t\r\n ', 'body_required'),
      ('message', 'day', v_today, null, '  ', 'body_required'),
      ('notice', 'all', null::date, 'Nadpis', null, 'body_required'),
      ('message', 'day', v_today, null, repeat('a', 501), 'body_too_long'),
      ('notice', 'all', null::date, 'Nadpis', repeat('a', 2001), 'body_too_long')
    ) as c(kind, audience, on_date, title, body, code)
  loop
    begin
      perform message_send(v_case.kind, v_case.audience, v_case.on_date, null,
                           v_case.title, v_case.body, null, true);
      raise exception 'FAIL: % / % went through, expected %',
        v_case.kind, v_case.audience, v_case.code;
    exception when others then
      if sqlerrm <> v_case.code then raise; end if;
    end;
  end loop;
  raise notice 'OK: kind, audience, date, title and body are checked with their own codes (0051)';
end $$;

-- 23f. The limits themselves are allowed: a 500-character message and a
-- 2000-character notice; the body and title are stored trimmed of any
-- whitespace (newlines and tabs too), and the limits count what is stored.
do $$
declare
  v_id uuid;
begin
  v_id := message_send('message', 'day', (now() at time zone 'Europe/Prague')::date, null,
                        null, E'\n ' || repeat('a', 500) || E'\t\n', null, true);
  if (select body from messages where id = v_id) is distinct from repeat('a', 500) then
    raise exception 'FAIL: the message body was not stored trimmed of newlines and tabs';
  end if;
  v_id := message_send('notice', 'all', null, null, E'\n  Dlouhá \t',
                        E'\r\n' || repeat('b', 2000) || E'\n', null, false);
  if (select title from messages where id = v_id) is distinct from 'Dlouhá'
     or (select body from messages where id = v_id) is distinct from repeat('b', 2000)
     or (select notify from messages where id = v_id) then
    raise exception 'FAIL: the notice lost its trimmed title/body or its notify = false';
  end if;
  -- 80 characters once trimmed is still a title.
  v_id := message_send('notice', 'all', null, null, E' \n' || repeat('c', 80) || E'\t ',
                        'Text.', null, false);
  if (select title from messages where id = v_id) is distinct from repeat('c', 80) then
    raise exception 'FAIL: an 80-character title (trimmed) did not land';
  end if;
  raise notice 'OK: 500 / 2000 / 80 characters are still fine, title and body trimmed of any whitespace, notify kept (0051)';
end $$;

-- 23g. The block has to be this alley's and bookable that day: another
-- alley's block and an inactive one are unknown_block; the day-only block
-- counts once a day override of that date lists it, and on that date only.
do $$
declare
  v_today constant date := (now() at time zone 'Europe/Prague')::date;
begin
  begin
    perform message_send('message', 'block', v_today,
                         current_setting('probe.duty_b1')::uuid, null, 'Cizí.', null, true);
    raise exception 'FAIL: another alley''s block took a message';
  exception when others then
    if sqlerrm <> 'unknown_block' then raise; end if;
  end;
  begin
    perform message_send('message', 'block', v_today + 3,
                         current_setting('probe.msg_off')::uuid, null, 'Mimo.', null, true);
    raise exception 'FAIL: an inactive block no override names took a message';
  exception when others then
    if sqlerrm <> 'unknown_block' then raise; end if;
  end;
  raise notice 'OK: a foreign or an inactive block is unknown_block (0051)';
end $$;
reset role;
insert into day_overrides (tenant_id, date, block_ids, created_by)
values ('00000000-0000-0000-0000-000000000051',
        (now() at time zone 'Europe/Prague')::date + 3,
        array[current_setting('probe.msg_b1')::uuid, current_setting('probe.msg_off')::uuid],
        '51000000-0000-0000-0000-000000000010');
insert into reservations (tenant_id, player_id, date, block_id, lane, created_via, created_by)
values ('00000000-0000-0000-0000-000000000051', '51000000-0000-0000-0000-000000000012',
        (now() at time zone 'Europe/Prague')::date + 3,
        current_setting('probe.msg_off')::uuid, 1,
        'app', '51000000-0000-0000-0000-000000000012');
set local role authenticated;
do $$
declare
  v_id uuid;
begin
  v_id := message_send('message', 'block', (now() at time zone 'Europe/Prague')::date + 3,
                        current_setting('probe.msg_off')::uuid, null, 'Speciál.', null, true);
  if (select array_agg(user_id) from message_recipients where message_id = v_id)
       <> array['51000000-0000-0000-0000-000000000012'::uuid] then
    raise exception 'FAIL: the day-only block''s message reached the wrong players';
  end if;
  begin
    perform message_send('message', 'block', (now() at time zone 'Europe/Prague')::date + 4,
                         current_setting('probe.msg_off')::uuid, null, 'Den poté.', null,
                         true);
    raise exception 'FAIL: the day-only block took a message the day after its override';
  exception when others then
    if sqlerrm <> 'unknown_block' then raise; end if;
  end;
  raise notice 'OK: a day-only block counts on the day its override names it, not the next (0051)';
end $$;


-- 23h. The admin writes to today's duty as an admin: Bára, not Emil the
-- placeholder on the same period; to the admins he has nobody to write to
-- but himself, so no_recipients.
do $$
declare
  v_id uuid;
begin
  v_id := message_send('message', 'duty', null, null, null, 'Dnes přijde revize.',
                        null, true);
  if (select array_agg(user_id) from message_recipients where message_id = v_id)
       <> array['51000000-0000-0000-0000-000000000011'::uuid]
     or (select author_role from messages where id = v_id) <> 'admin' then
    raise exception 'FAIL: the admin''s duty message went wrong';
  end if;
  raise notice 'OK: the admin writes to today''s duty (0051)';
end $$;
do $$
begin
  perform message_send('message', 'admins', null, null, null, 'Sám sobě.', null, true);
  raise exception 'FAIL: the only admin wrote to the admins';
exception when others then
  if sqlerrm <> 'no_recipients' then raise; end if;
  raise notice 'OK: the only admin has no admins to write to (0051)';
end $$;

-- 23h2. The admin writes to any date, a past one too (the matrix's third
-- column; the duty gets date_past for yesterday in 23i2): yesterday's day
-- and block reach Cyril, booked in block 16:00 yesterday, and only him.
reset role;
insert into reservations (tenant_id, player_id, date, block_id, lane, created_via, created_by)
values ('00000000-0000-0000-0000-000000000051', '51000000-0000-0000-0000-000000000012',
        (now() at time zone 'Europe/Prague')::date - 1,
        current_setting('probe.msg_b1')::uuid, 1,
        'app', '51000000-0000-0000-0000-000000000012');
set local role authenticated;
do $$
declare
  v_yesterday constant date := (now() at time zone 'Europe/Prague')::date - 1;
  v_id uuid;
begin
  v_id := message_send('message', 'day', v_yesterday, null, null, 'Včera jste nechali světla.',
                        null, true);
  if (select array_agg(user_id) from message_recipients where message_id = v_id)
       is distinct from array['51000000-0000-0000-0000-000000000012'::uuid] then
    raise exception 'FAIL: the admin''s day message for yesterday went wrong';
  end if;
  v_id := message_send('message', 'block', v_yesterday, current_setting('probe.msg_b1')::uuid,
                        null, 'Včera na dráze 1 zůstala koule.', null, true);
  if (select array_agg(user_id) from message_recipients where message_id = v_id)
       is distinct from array['51000000-0000-0000-0000-000000000012'::uuid] then
    raise exception 'FAIL: the admin''s block message for yesterday went wrong';
  end if;
  raise notice 'OK: the admin writes to a past day and a past block (0051)';
end $$;

-- 23i. Bára on duty writes to a day or a block on the days of her own
-- period (today for a week: the block edits' rule, duty_edit_gate), as a
-- player: today that reaches Adam (booked, and not the author now), Cyril
-- and Dana; tomorrow, where she is booked herself, only Dana (Filip, booked
-- in the same block, is pending). Yesterday, before her period, and the day
-- after it are not hers: not_allowed (23i2 has the past inside a period);
-- to the duty every assignee is excluded (Emil a placeholder,
-- Bára the author), so nobody_on_duty; to the admins she reaches Adam.
set local request.jwt.claims =
  '{"sub":"51000000-0000-0000-0000-000000000011","role":"authenticated"}'; -- Bára, duty
do $$
declare
  v_id uuid;
begin
  v_id := message_send('message', 'day', (now() at time zone 'Europe/Prague')::date, null,
                        null, 'Kantýna dnes zavřená.', null, true);
  if (select author_role from messages where id = v_id) <> 'player'
     or (select string_agg(user_id::text, ',' order by user_id)
           from message_recipients where message_id = v_id)
        is distinct from '51000000-0000-0000-0000-000000000010,'
                         '51000000-0000-0000-0000-000000000012,'
                         '51000000-0000-0000-0000-000000000013' then
    raise exception 'FAIL: the duty''s day message went wrong';
  end if;
  perform set_config('probe.msg_bara_day', v_id::text, true);
  raise notice 'OK: the duty writes to today, labelled as a player (0051)';
end $$;
do $$
declare
  v_id uuid;
begin
  v_id := message_send('message', 'block', (now() at time zone 'Europe/Prague')::date + 1,
                        current_setting('probe.msg_b1')::uuid, null, 'Zítra dřív.',
                        null, true);
  if (select array_agg(user_id) from message_recipients where message_id = v_id)
       <> array['51000000-0000-0000-0000-000000000013'::uuid] then
    raise exception 'FAIL: the duty''s block message for tomorrow reached the wrong players';
  end if;
  v_id := message_send('message', 'day', (now() at time zone 'Europe/Prague')::date + 1,
                        null, null, 'Zítra kantýna od šesti.', null, true);
  if (select array_agg(user_id) from message_recipients where message_id = v_id)
       <> array['51000000-0000-0000-0000-000000000013'::uuid] then
    raise exception 'FAIL: the duty''s day message for tomorrow reached the wrong players';
  end if;
  raise notice 'OK: the duty writes to a block and a day after today, not to herself (0051)';
end $$;
do $$
declare
  v_today constant date := (now() at time zone 'Europe/Prague')::date;
begin
  begin
    perform message_send('message', 'day', v_today - 1,
                         null, null, 'Včera.', null, true);
    raise exception 'FAIL: the duty wrote to yesterday, before her period';
  exception when others then
    if sqlerrm <> 'not_allowed' then raise; end if;
  end;
  begin
    perform message_send('message', 'block', v_today + 7,
                         current_setting('probe.msg_b1')::uuid, null, 'Za týden.', null, true);
    raise exception 'FAIL: the duty wrote to a block after her period';
  exception when others then
    if sqlerrm <> 'not_allowed' then raise; end if;
  end;
  begin
    perform message_send('message', 'day', v_today + 7,
                         null, null, 'Za týden.', null, true);
    raise exception 'FAIL: the duty wrote to a day after her period';
  exception when others then
    if sqlerrm <> 'not_allowed' then raise; end if;
  end;
  begin
    perform message_send('message', 'duty', null, null, null, 'Já sama.', null, true);
    raise exception 'FAIL: the duty wrote to herself and a placeholder';
  exception when others then
    if sqlerrm <> 'nobody_on_duty' then raise; end if;
  end;
  raise notice 'OK: the duty: days outside her period are not_allowed, herself and a placeholder nobody_on_duty (0051)';
end $$;
do $$
declare
  v_id uuid;
begin
  v_id := message_send('message', 'admins', null, null, null, 'Došly párky.', null, true);
  if (select array_agg(user_id) from message_recipients where message_id = v_id)
       <> array['51000000-0000-0000-0000-000000000010'::uuid] then
    raise exception 'FAIL: the duty''s admins message reached the wrong players';
  end if;
  raise notice 'OK: the duty writes to the admins (0051)';
end $$;

-- 23i2. The past inside her own period is date_past, not not_allowed: her
-- period began three days ago, so yesterday is hers but gone (day and
-- block); a day before it is still not hers. The admin (23h2) is not held.
reset role;
update duty_periods
   set starts_on = (now() at time zone 'Europe/Prague')::date - 3
 where id = current_setting('probe.msg_period')::uuid;
set local role authenticated;
do $$
declare
  v_today constant date := (now() at time zone 'Europe/Prague')::date;
begin
  begin
    perform message_send('message', 'day', v_today - 1, null, null, 'Včera.', null, true);
    raise exception 'FAIL: the duty wrote to yesterday inside her period';
  exception when others then
    if sqlerrm <> 'date_past' then raise; end if;
  end;
  begin
    perform message_send('message', 'block', v_today - 1,
                         current_setting('probe.msg_b1')::uuid, null, 'Včera.', null, true);
    raise exception 'FAIL: the duty wrote to yesterday''s block inside her period';
  exception when others then
    if sqlerrm <> 'date_past' then raise; end if;
  end;
  begin
    perform message_send('message', 'day', v_today - 4, null, null, 'Předevčírem.', null, true);
    raise exception 'FAIL: the duty wrote to a day before her period';
  exception when others then
    if sqlerrm <> 'not_allowed' then raise; end if;
  end;
  raise notice 'OK: the past inside her period is date_past, before it not_allowed (0051)';
end $$;
reset role;
update duty_periods
   set starts_on = (now() at time zone 'Europe/Prague')::date
 where id = current_setting('probe.msg_period')::uuid;
set local role authenticated;


-- 23j. Cyril, a plain player: no day, no block, no notice (not_allowed);
-- to the admins and to the duty yes, with the training he writes about
-- kept on the row; another alley's block as that context is unknown_block.
set local request.jwt.claims =
  '{"sub":"51000000-0000-0000-0000-000000000012","role":"authenticated"}'; -- Cyril, player
do $$
declare
  v_today constant date := (now() at time zone 'Europe/Prague')::date;
  v_b1 constant uuid := current_setting('probe.msg_b1')::uuid;
begin
  begin
    perform message_send('message', 'day', v_today, null, null, 'Ahoj.', null, true);
    raise exception 'FAIL: a plain player wrote to a day';
  exception when others then
    if sqlerrm <> 'not_allowed' then raise; end if;
  end;
  begin
    perform message_send('message', 'block', v_today, v_b1, null, 'Ahoj.', null, true);
    raise exception 'FAIL: a plain player wrote to a block';
  exception when others then
    if sqlerrm <> 'not_allowed' then raise; end if;
  end;
  begin
    perform message_send('notice', 'all', null, null, 'Nadpis', 'Ahoj.', null, true);
    raise exception 'FAIL: a plain player posted a notice';
  exception when others then
    if sqlerrm <> 'not_allowed' then raise; end if;
  end;
  begin
    perform message_send('message', 'admins', v_today,
                         current_setting('probe.duty_b1')::uuid, null, 'Cizí.', null, true);
    raise exception 'FAIL: another alley''s block went along as context';
  exception when others then
    if sqlerrm <> 'unknown_block' then raise; end if;
  end;
  raise notice 'OK: a plain player writes no day, block or notice, no foreign context (0051)';
end $$;
do $$
declare
  v_id uuid;
  v_row messages;
begin
  v_id := message_send('message', 'admins', (now() at time zone 'Europe/Prague')::date,
                        current_setting('probe.msg_b1')::uuid, null, 'Nepřijdu.', null, true);
  select * into v_row from messages where id = v_id;
  if v_row.on_date <> (now() at time zone 'Europe/Prague')::date
     or v_row.block_id <> current_setting('probe.msg_b1')::uuid
     or v_row.author_role <> 'player'
     or (select array_agg(user_id) from message_recipients where message_id = v_id)
          <> array['51000000-0000-0000-0000-000000000010'::uuid] then
    raise exception 'FAIL: the player''s admins message went wrong: %', v_row;
  end if;
  perform set_config('probe.msg_cyril_admins', v_id::text, true);
  raise notice 'OK: a plain player writes to the admins, context kept (0051)';
end $$;
do $$
declare
  v_id uuid;
begin
  v_id := message_send('message', 'duty', null, null, null, 'Je otevřeno?', null, true);
  if (select array_agg(user_id) from message_recipients where message_id = v_id)
       <> array['51000000-0000-0000-0000-000000000011'::uuid] then
    raise exception 'FAIL: the player''s duty message reached the wrong players';
  end if;
  raise notice 'OK: a plain player writes to today''s duty (0051)';
end $$;

-- 23k. No period covers today: nobody_on_duty.
reset role;
update duty_periods
   set starts_on = (now() at time zone 'Europe/Prague')::date + 1
 where id = current_setting('probe.msg_period')::uuid;
set local role authenticated;
do $$
begin
  perform message_send('message', 'duty', null, null, null, 'Haló?', null, true);
  raise exception 'FAIL: a duty message went out with no period today';
exception when others then
  if sqlerrm <> 'nobody_on_duty' then raise; end if;
  raise notice 'OK: no period today is nobody_on_duty (0051)';
end $$;
reset role;
update duty_periods
   set starts_on = (now() at time zone 'Europe/Prague')::date
 where id = current_setting('probe.msg_period')::uuid;
set local role authenticated;

-- 23k1. A duty whose period starts TOMORROW is not on duty today, yet writes
-- to the days of that period already now (the block edits' rule,
-- duty_edit_gate: prepare the days that will be hers) — and to no other day,
-- today included. Bára's period is moved a day ahead for it: tomorrow's day
-- and block reach Dana only (Bára herself is booked, Filip is pending).
reset role;
update duty_periods
   set starts_on = (now() at time zone 'Europe/Prague')::date + 1
 where id = current_setting('probe.msg_period')::uuid;
set local role authenticated;
set local request.jwt.claims =
  '{"sub":"51000000-0000-0000-0000-000000000011","role":"authenticated"}'; -- Bára, from tomorrow
do $$
declare
  v_today constant date := (now() at time zone 'Europe/Prague')::date;
  v_id uuid;
begin
  v_id := message_send('message', 'day', v_today + 1, null, null,
                       'Zítra otevřeno déle.', null, true);
  if (select array_agg(user_id) from message_recipients where message_id = v_id)
       <> array['51000000-0000-0000-0000-000000000013'::uuid] then
    raise exception 'FAIL: the coming duty''s day message reached the wrong players';
  end if;
  v_id := message_send('message', 'block', v_today + 1,
                       current_setting('probe.msg_b1')::uuid, null, 'Zítra dřív.', null, true);
  if (select array_agg(user_id) from message_recipients where message_id = v_id)
       <> array['51000000-0000-0000-0000-000000000013'::uuid] then
    raise exception 'FAIL: the coming duty''s block message reached the wrong players';
  end if;
  begin
    perform message_send('message', 'day', v_today, null, null, 'Dnes.', null, true);
    raise exception 'FAIL: a duty starting tomorrow wrote to today';
  exception when others then
    if sqlerrm <> 'not_allowed' then raise; end if;
  end;
  begin
    perform message_send('message', 'block', v_today,
                         current_setting('probe.msg_b1')::uuid, null, 'Dnes.', null, true);
    raise exception 'FAIL: a duty starting tomorrow wrote to today''s block';
  exception when others then
    if sqlerrm <> 'not_allowed' then raise; end if;
  end;
  raise notice 'OK: a duty from tomorrow writes to tomorrow already, not to today (0051)';
end $$;
reset role;
update duty_periods
   set starts_on = (now() at time zone 'Europe/Prague')::date
 where id = current_setting('probe.msg_period')::uuid;
set local role authenticated;
set local request.jwt.claims =
  '{"sub":"51000000-0000-0000-0000-000000000012","role":"authenticated"}'; -- Cyril, player

-- 23k2. Bára, the only assignee with an account, loses her approval: she
-- is off duty then (is_on_duty and due_duty_reminders skip her, 0050), so
-- Cyril's message to the duty has nobody to go to — the `players` view's
-- rule, as for `all`/`admins`, not a success delivered to her.
reset role;
update profiles set status = 'pending'
 where id = '51000000-0000-0000-0000-000000000011';
set local role authenticated;
do $$
begin
  perform message_send('message', 'duty', null, null, null, 'Je otevřeno?', null, true);
  raise exception 'FAIL: a duty message went to a pending assignee';
exception when others then
  if sqlerrm <> 'nobody_on_duty' then raise; end if;
  raise notice 'OK: a pending assignee is off duty, so nobody_on_duty (0051)';
end $$;
reset role;
update profiles set status = 'approved'
 where id = '51000000-0000-0000-0000-000000000011';
set local role authenticated;


-- 23l. The kiosk, a placeholder and Filip, whose account is pending,
-- send nothing, not even to the admins or the duty.
do $$
declare
  v_who text;
begin
  foreach v_who in array array['51000000-0000-0000-0000-000000000015',
                               '51000000-0000-0000-0000-000000000014',
                               '51000000-0000-0000-0000-000000000016'] loop
    perform set_config('request.jwt.claims',
      '{"sub":"' || v_who || '","role":"authenticated"}', true);
    begin
      perform message_send('message', 'admins', null, null, null, 'Ahoj.', null, true);
      raise exception 'FAIL: % wrote to the admins', v_who;
    exception when others then
      if sqlerrm <> 'not_allowed' then raise; end if;
    end;
    begin
      perform message_send('message', 'duty', null, null, null, 'Ahoj.', null, true);
      raise exception 'FAIL: % wrote to the duty', v_who;
    exception when others then
      if sqlerrm <> 'not_allowed' then raise; end if;
    end;
    begin
      perform message_send('message', 'day', (now() at time zone 'Europe/Prague')::date,
                           null, null, 'Ahoj.', null, true);
      raise exception 'FAIL: % wrote to a day', v_who;
    exception when others then
      if sqlerrm <> 'not_allowed' then raise; end if;
    end;
  end loop;
  raise notice 'OK: the kiosk, a placeholder and a pending account send nothing (0051)';
end $$;

-- 23m. A player of another alley (Pavel, S) writes to his own admins only
-- — never T's — and T's blocks are unknown to him.
set local request.jwt.claims =
  '{"sub":"50000000-0000-0000-0000-000000000011","role":"authenticated"}'; -- Pavel, S
do $$
declare
  v_id uuid;
begin
  v_id := message_send('message', 'admins', null, null, null, 'Z vedlejší kuželny.',
                        null, true);
  if (select array_agg(user_id) from message_recipients where message_id = v_id)
       <> array['50000000-0000-0000-0000-000000000010'::uuid]
     or (select tenant_id from messages where id = v_id)
       <> '00000000-0000-0000-0000-000000000050' then
    raise exception 'FAIL: another alley''s admins message crossed alleys';
  end if;
  raise notice 'OK: a player of another alley writes to his own admins only (0051)';
end $$;
do $$
begin
  perform message_send('message', 'duty', null, current_setting('probe.msg_b1')::uuid,
                       null, 'Cizí blok.', null, true);
  raise exception 'FAIL: another alley''s player named T''s block';
exception when others then
  if sqlerrm <> 'unknown_block' then raise; end if;
  raise notice 'OK: T''s blocks are unknown to another alley (0051)';
end $$;

-- 23n. A visiting superadmin (Alena, S's admin, in T for a while) is no
-- home member of T: neither an admins nor an all recipient there.
reset role;
update profiles
   set superadmin = true, home_tenant_id = '00000000-0000-0000-0000-000000000050',
       tenant_id = '00000000-0000-0000-0000-000000000051'
 where id = '50000000-0000-0000-0000-000000000010';
set local role authenticated;
set local request.jwt.claims =
  '{"sub":"51000000-0000-0000-0000-000000000012","role":"authenticated"}'; -- Cyril
do $$
declare
  v_id uuid;
begin
  v_id := message_send('message', 'admins', null, null, null, 'Kdo je tu správce?',
                        null, true);
  if (select array_agg(user_id) from message_recipients where message_id = v_id)
       <> array['51000000-0000-0000-0000-000000000010'::uuid] then
    raise exception 'FAIL: a visiting superadmin got T''s admins message';
  end if;
  raise notice 'OK: a visiting superadmin is not an admins recipient (0051)';
end $$;
set local request.jwt.claims =
  '{"sub":"51000000-0000-0000-0000-000000000010","role":"authenticated"}'; -- Adam
do $$
declare
  v_id uuid;
begin
  v_id := message_send('notice', 'all', null, null, 'Pro domácí', 'Jen pro nás.', null, true);
  if exists (select 1 from message_recipients where message_id = v_id
                and user_id = '50000000-0000-0000-0000-000000000010') then
    raise exception 'FAIL: a visiting superadmin got T''s notice';
  end if;
  raise notice 'OK: a visiting superadmin is not a notice recipient (0051)';
end $$;
reset role;
update profiles
   set superadmin = false, home_tenant_id = null,
       tenant_id = '00000000-0000-0000-0000-000000000050'
 where id = '50000000-0000-0000-0000-000000000010';
set local role authenticated;


-- 23o. can_read_message: a message to its author and its recipients (who
-- see every recipient row, reactions included), not to a bystander of the
-- same alley; a notice to every account player of the alley, not to the
-- kiosk or a pending account; nothing to another alley. RLS filters, no
-- error.
do $$
declare
  v_day constant uuid := current_setting('probe.msg_day')::uuid;
  v_notice constant uuid := current_setting('probe.msg_notice')::uuid;
  v_who text;
begin
  -- Adam, the author (not a recipient).
  perform set_config('request.jwt.claims',
    '{"sub":"51000000-0000-0000-0000-000000000010","role":"authenticated"}', true);
  if (select count(*) from messages where id = v_day) <> 1
     or (select count(*) from message_recipients where message_id = v_day) <> 2 then
    raise exception 'FAIL: the author cannot read his message and its recipients';
  end if;
  -- Cyril, a recipient: the message and both recipient rows.
  perform set_config('request.jwt.claims',
    '{"sub":"51000000-0000-0000-0000-000000000012","role":"authenticated"}', true);
  if (select count(*) from messages where id = v_day) <> 1
     or (select count(*) from message_recipients where message_id = v_day) <> 2 then
    raise exception 'FAIL: a recipient cannot read the message or its other recipients';
  end if;
  -- Bára, her booking today cancelled: a bystander.
  perform set_config('request.jwt.claims',
    '{"sub":"51000000-0000-0000-0000-000000000011","role":"authenticated"}', true);
  if (select count(*) from messages where id = v_day) <> 0
     or (select count(*) from message_recipients where message_id = v_day) <> 0 then
    raise exception 'FAIL: a bystander of the alley reads a message not to her';
  end if;
  foreach v_who in array array['51000000-0000-0000-0000-000000000010',
                               '51000000-0000-0000-0000-000000000011',
                               '51000000-0000-0000-0000-000000000012',
                               '51000000-0000-0000-0000-000000000013'] loop
    perform set_config('request.jwt.claims',
      '{"sub":"' || v_who || '","role":"authenticated"}', true);
    if (select count(*) from messages where id = v_notice) <> 1 then
      raise exception 'FAIL: % cannot read the notice', v_who;
    end if;
  end loop;
  perform set_config('request.jwt.claims',
    '{"sub":"51000000-0000-0000-0000-000000000015","role":"authenticated"}', true);
  -- The kiosk reads the alley's notices (0064), never a message.
  if (select count(*) from messages
       where tenant_id = '00000000-0000-0000-0000-000000000051'
         and kind = 'message') <> 0
     or (select count(*) from messages where id = v_notice) <> 1 then
    raise exception 'FAIL: the kiosk reads messages, or not the notice';
  end if;
  if (select count(*) from message_recipients
       where tenant_id = '00000000-0000-0000-0000-000000000051') <> 0 then
    raise exception 'FAIL: the kiosk reads recipient rows';
  end if;
  -- Filip, pending: an unvetted self-registration of this alley, so not
  -- the notice (it may say where the spare key is), nor any recipient row.
  perform set_config('request.jwt.claims',
    '{"sub":"51000000-0000-0000-0000-000000000016","role":"authenticated"}', true);
  if (select count(*) from messages where id = v_notice) <> 0
     or (select count(*) from messages
          where tenant_id = '00000000-0000-0000-0000-000000000051') <> 0
     or (select count(*) from message_recipients
          where tenant_id = '00000000-0000-0000-0000-000000000051') <> 0 then
    raise exception 'FAIL: a pending account reads T''s notices or messages';
  end if;
  perform set_config('request.jwt.claims',
    '{"sub":"50000000-0000-0000-0000-000000000011","role":"authenticated"}', true);
  if (select count(*) from messages where tenant_id = '00000000-0000-0000-0000-000000000051') <> 0
     or (select count(*) from message_recipients
          where tenant_id = '00000000-0000-0000-0000-000000000051') <> 0 then
    raise exception 'FAIL: another alley reads T''s messages';
  end if;
  raise notice 'OK: can_read_message: author, recipients, notice to the alley; not a bystander, the kiosk, a pending account or another alley (0051)';
end $$;

-- 23o2. Recipient rows are not can_read_message's. On a notice a player
-- sees her own row only (who else has seen it is the admin's „Kdo si to
-- zobrazil“), the admin every row; on a message its author and every
-- recipient see every row (the reactions), a bystander none — the admin
-- included, when the message is not hers; another alley nothing.
do $$
declare
  v_notice constant uuid := current_setting('probe.msg_notice')::uuid;
  v_bara_day constant uuid := current_setting('probe.msg_bara_day')::uuid;
  v_day constant uuid := current_setting('probe.msg_day')::uuid;
  v_adam constant text := '51000000-0000-0000-0000-000000000010';
  v_bara constant text := '51000000-0000-0000-0000-000000000011';
  v_cyril constant text := '51000000-0000-0000-0000-000000000012';
  v_dana constant text := '51000000-0000-0000-0000-000000000013';
  v_case record;
  v_got text;
  v_duty_msg uuid;
begin
  for v_case in
    select * from (values
      (v_cyril, v_notice, v_cyril, 'a plain member on a notice'),
      (v_bara, v_notice, v_bara, 'the duty (a player) on a notice'),
      (v_dana, v_notice, v_dana, 'another plain member on a notice'),
      (v_adam, v_notice, v_bara || ',' || v_cyril || ',' || v_dana, 'the admin on a notice'),
      (v_cyril, v_bara_day, v_adam || ',' || v_cyril || ',' || v_dana, 'a recipient'),
      (v_dana, v_bara_day, v_adam || ',' || v_cyril || ',' || v_dana, 'another recipient'),
      (v_adam, v_bara_day, v_adam || ',' || v_cyril || ',' || v_dana, 'the admin, a recipient'),
      (v_bara, v_bara_day, v_adam || ',' || v_cyril || ',' || v_dana, 'the author, a player'),
      (v_adam, v_day, v_cyril || ',' || v_dana, 'the author, an admin'),
      (v_bara, v_day, null, 'a bystander'),
      ('50000000-0000-0000-0000-000000000011', v_notice, null, 'another alley''s player on a notice'),
      ('50000000-0000-0000-0000-000000000010', v_notice, null, 'another alley''s admin on a notice'),
      ('50000000-0000-0000-0000-000000000011', v_bara_day, null, 'another alley on a message')
    ) as c(who, msg, expected, label)
  loop
    perform set_config('request.jwt.claims',
      '{"sub":"' || v_case.who || '","role":"authenticated"}', true);
    select string_agg(user_id::text, ',' order by user_id) into v_got
      from message_recipients where message_id = v_case.msg;
    if v_got is distinct from v_case.expected then
      raise exception 'FAIL: % sees recipient rows % (expected %)',
        v_case.label, v_got, v_case.expected;
    end if;
  end loop;
  -- Cyril's message to the duty (Bára): the admin is no participant.
  perform set_config('request.jwt.claims',
    '{"sub":"' || v_cyril || '","role":"authenticated"}', true);
  select id into strict v_duty_msg from messages
   where author_id = auth.uid() and audience = 'duty';
  perform set_config('request.jwt.claims',
    '{"sub":"' || v_adam || '","role":"authenticated"}', true);
  if (select count(*) from messages where id = v_duty_msg) <> 0
     or (select count(*) from message_recipients where message_id = v_duty_msg) <> 0 then
    raise exception 'FAIL: the admin reads a message between a player and the duty';
  end if;
  raise notice 'OK: recipient rows: a notice''s to its owner and the admin, a message''s to its author and recipients (0051)';
end $$;

-- 23o2, continued. The admin's view of a notice's rows is the role's, not
-- the authorship's: Cyril, made an admin, sees every row of Adam's notice.
reset role;
update profiles set role = 'admin' where id = '51000000-0000-0000-0000-000000000012';
set local role authenticated;
set local request.jwt.claims =
  '{"sub":"51000000-0000-0000-0000-000000000012","role":"authenticated"}'; -- Cyril, admin
do $$
begin
  if (select string_agg(user_id::text, ',' order by user_id) from message_recipients
       where message_id = current_setting('probe.msg_notice')::uuid)
     is distinct from '51000000-0000-0000-0000-000000000011,'
                      '51000000-0000-0000-0000-000000000012,'
                      '51000000-0000-0000-0000-000000000013' then
    raise exception 'FAIL: an admin who did not post the notice does not see who got it';
  end if;
  raise notice 'OK: any admin of the alley sees every row of a notice (0051)';
end $$;
reset role;
update profiles set role = 'player' where id = '51000000-0000-0000-0000-000000000012';
set local role authenticated;

-- 23o, continued. The board is not recipient-based: Filip, approved only
-- after the notice went out, has no recipient row on it and still reads
-- it — the notice branch alone answers for him. Back to pending after.
reset role;
update profiles set status = 'approved'
 where id = '51000000-0000-0000-0000-000000000016';
set local role authenticated;
set local request.jwt.claims =
  '{"sub":"51000000-0000-0000-0000-000000000016","role":"authenticated"}'; -- Filip
do $$
declare
  v_notice constant uuid := current_setting('probe.msg_notice')::uuid;
begin
  if (select count(*) from message_recipients
       where message_id = v_notice and user_id = auth.uid()) <> 0 then
    raise exception 'FAIL: expected Filip to have no recipient row on the notice';
  end if;
  if (select count(*) from messages where id = v_notice) <> 1 then
    raise exception 'FAIL: a player approved after the notice went out cannot read it';
  end if;
  raise notice 'OK: every approved player reads a notice, recipient row or not (0051)';
end $$;
reset role;
update profiles set status = 'pending'
 where id = '51000000-0000-0000-0000-000000000016';
set local role authenticated;

-- 23o, continued. The kiosk reads no message or recipient row (only notices,
-- 0064), not even what it once got as a player: Adam sets Dana — a recipient of the day message and of the
-- notice — as the kiosk („Nastavit jako kiosk“). She then sees no message
-- and no recipient row, and her own rows take no reply. Back to a player.
do $$
declare
  v_dana constant uuid := '51000000-0000-0000-0000-000000000013';
  v_day constant uuid := current_setting('probe.msg_day')::uuid;
  v_notice constant uuid := current_setting('probe.msg_notice')::uuid;
  v_n integer;
begin
  perform set_config('request.jwt.claims',
    '{"sub":"51000000-0000-0000-0000-000000000013","role":"authenticated"}', true);
  if (select count(*) from message_recipients
       where message_id in (v_day, v_notice) and user_id = auth.uid()) <> 2 then
    raise exception 'FAIL: expected Dana to be a recipient of the day message and the notice';
  end if;
  perform set_config('request.jwt.claims',
    '{"sub":"51000000-0000-0000-0000-000000000010","role":"authenticated"}', true);
  perform set_role(v_dana, 'kiosk');
  perform set_config('request.jwt.claims',
    '{"sub":"51000000-0000-0000-0000-000000000013","role":"authenticated"}', true);
  if not is_kiosk() then
    raise exception 'FAIL: expected Dana to be the kiosk now';
  end if;
  if (select count(*) from messages
       where tenant_id = '00000000-0000-0000-0000-000000000051'
         and kind = 'message') <> 0
     or (select count(*) from message_recipients
          where tenant_id = '00000000-0000-0000-0000-000000000051') <> 0 then
    raise exception 'FAIL: a recipient set as the kiosk still reads her messages';
  end if;
  update message_recipients set reply = 'z kiosku';
  get diagnostics v_n = row_count;
  if v_n <> 0 then
    raise exception 'FAIL: a recipient set as the kiosk replied on % rows', v_n;
  end if;
  perform set_config('request.jwt.claims',
    '{"sub":"51000000-0000-0000-0000-000000000010","role":"authenticated"}', true);
  perform set_role(v_dana, 'player');
  raise notice 'OK: a recipient set as the kiosk reads and replies to nothing (0051)';
end $$;

-- 23o, continued. The same for an account set back to pending: Dana, a
-- recipient, reads nothing and replies to nothing. Approved again after.
reset role;
update profiles set status = 'pending'
 where id = '51000000-0000-0000-0000-000000000013';
set local role authenticated;
set local request.jwt.claims =
  '{"sub":"51000000-0000-0000-0000-000000000013","role":"authenticated"}'; -- Dana
do $$
declare
  v_n integer;
begin
  if (select count(*) from messages
       where tenant_id = '00000000-0000-0000-0000-000000000051') <> 0
     or (select count(*) from message_recipients
          where tenant_id = '00000000-0000-0000-0000-000000000051') <> 0 then
    raise exception 'FAIL: a recipient set back to pending still reads her messages';
  end if;
  update message_recipients set reply = 'čekám';
  get diagnostics v_n = row_count;
  if v_n <> 0 then
    raise exception 'FAIL: a recipient set back to pending replied on % rows', v_n;
  end if;
  raise notice 'OK: a recipient set back to pending reads and replies to nothing (0051)';
end $$;
reset role;
update profiles set status = 'approved'
 where id = '51000000-0000-0000-0000-000000000013';
set local role authenticated;

-- 23o, continued. Both select policies lead with the alley, as every other
-- policy does, so a player's unfiltered stream is an index scan of her own
-- alley and not a helper call per row of the whole platform. The recipient
-- rows' policy is set-based: one visible_recipient_message_ids() per
-- query, not a can_read_message call per row (~400 ms at 40 members × 100
-- notices).
do $$
declare
  v_bad text;
begin
  select string_agg(tablename || '.' || policyname || ': ' || qual, '; ')
    into v_bad
    from pg_policies
   where schemaname = 'public'
     and (tablename, policyname) in (('messages', 'messages_select'),
                                     ('message_recipients', 'message_recipients_select'))
     and qual !~ '^\(\(tenant_id = (\( SELECT )?current_tenant_id\(\)';
  if v_bad is not null
     or (select count(*) from pg_policies where schemaname = 'public'
          and policyname in ('messages_select', 'message_recipients_select')) <> 2 then
    raise exception 'FAIL: a 0051 select policy does not lead with the alley: %', v_bad;
  end if;
  select qual into v_bad from pg_policies
   where schemaname = 'public' and tablename = 'message_recipients'
     and policyname = 'message_recipients_select';
  if v_bad not like '%visible_recipient_message_ids()%'
     or v_bad like '%can_read_message%' then
    raise exception 'FAIL: message_recipients_select is not set-based: %', v_bad;
  end if;
  raise notice 'OK: the 0051 select policies lead with the alley, the recipients'' is set-based (0051)';
end $$;

-- 23o, continued. messages_select is set-based too (one visible_message_ids()
-- per query, ~13 ms → ~0.4 ms for a player's stream at 150 messages), and
-- that set is exactly what can_read_message admits, for every account of
-- every alley this file made (T's admin, duty, players, the kiosk, a
-- placeholder, a pending account; S; the rest) and for no account at all.
reset role;
do $$
declare
  v_who uuid;
  v_qual text;
begin
  select qual into v_qual from pg_policies
   where schemaname = 'public' and tablename = 'messages' and policyname = 'messages_select';
  if v_qual not like '%visible_message_ids()%' or v_qual like '%can_read_message%' then
    raise exception 'FAIL: messages_select is not set-based: %', v_qual;
  end if;
  for v_who in select id from profiles
               union all select '51000000-0000-0000-0000-0000000000ff'::uuid loop
    perform set_config('request.jwt.claims',
      '{"sub":"' || v_who || '","role":"authenticated"}', true);
    if (select array_agg(id order by id) from messages where can_read_message(id))
       is distinct from (select array_agg(v order by v) from visible_message_ids() v) then
      raise exception 'FAIL: visible_message_ids and can_read_message disagree for %', v_who;
    end if;
  end loop;
  raise notice 'OK: messages_select is set-based and admits exactly what can_read_message does (0051)';
end $$;
set local role authenticated;


-- 23p. A recipient reacts on her own row only: 👍 stamps reacted_at and
-- the other participants see it; someone else's row updates nothing
-- (RLS); a read alone stamps nothing; reply alone counts as a reaction;
-- both cleared clears reacted_at.
set local request.jwt.claims =
  '{"sub":"51000000-0000-0000-0000-000000000012","role":"authenticated"}'; -- Cyril
do $$
declare
  v_day constant uuid := current_setting('probe.msg_day')::uuid;
  v_n integer;
  v_row message_recipients;
begin
  update message_recipients set reaction = 'up'
   where message_id = v_day and user_id = auth.uid();
  get diagnostics v_n = row_count;
  select * into v_row from message_recipients
   where message_id = v_day and user_id = auth.uid();
  if v_n <> 1 or v_row.reaction is distinct from 'up' or v_row.reacted_at is null then
    raise exception 'FAIL: a recipient''s own 👍 did not land or stamp: % %', v_n, v_row;
  end if;
  update message_recipients set reaction = 'down'
   where message_id = v_day and user_id = '51000000-0000-0000-0000-000000000013';
  get diagnostics v_n = row_count;
  if v_n <> 0 then
    raise exception 'FAIL: Cyril reacted on Dana''s row';
  end if;
  perform set_config('request.jwt.claims',
    '{"sub":"51000000-0000-0000-0000-000000000013","role":"authenticated"}', true);
  if (select reaction from message_recipients
       where message_id = v_day and user_id = '51000000-0000-0000-0000-000000000012')
     is distinct from 'up' then
    raise exception 'FAIL: another recipient does not see Cyril''s 👍';
  end if;
  if (select reaction from message_recipients
       where message_id = v_day and user_id = '51000000-0000-0000-0000-000000000013')
     is not null then
    raise exception 'FAIL: Dana''s row changed under Cyril''s update';
  end if;
  raise notice 'OK: a recipient reacts on her own row, the others see it (0051)';
end $$;
set local request.jwt.claims =
  '{"sub":"51000000-0000-0000-0000-000000000012","role":"authenticated"}'; -- Cyril
do $$
declare
  v_day constant uuid := current_setting('probe.msg_day')::uuid;
  v_row message_recipients;
begin
  if (select reaction from message_recipients
       where message_id = v_day and user_id = auth.uid()) is distinct from 'up' then
    raise exception 'FAIL: expected Cyril''s 👍 from 23p to clear';
  end if;
  update message_recipients set reaction = null, reply = null
   where message_id = v_day and user_id = auth.uid();
  select * into v_row from message_recipients
   where message_id = v_day and user_id = auth.uid();
  if v_row.reacted_at is not null then
    raise exception 'FAIL: clearing both left reacted_at: %', v_row;
  end if;
  update message_recipients set read_at = now()
   where message_id = v_day and user_id = auth.uid();
  select * into v_row from message_recipients
   where message_id = v_day and user_id = auth.uid();
  if v_row.read_at is null or v_row.reacted_at is not null then
    raise exception 'FAIL: a read stamped a reaction: %', v_row;
  end if;
  update message_recipients set reply = 'Budu tam v pět.'
   where message_id = v_day and user_id = auth.uid();
  select * into v_row from message_recipients
   where message_id = v_day and user_id = auth.uid();
  if v_row.reacted_at is null then
    raise exception 'FAIL: a reply alone did not stamp reacted_at';
  end if;
  raise notice 'OK: reacted_at follows reaction/reply, cleared with both, not by a read (0051)';
end $$;
-- 23p, continued. A notice has no reactions: a 👍/👎 or a reply on a
-- notice's row is not_allowed (the trigger, whatever the client); marking
-- it read is fine.
do $$
declare
  v_notice constant uuid := current_setting('probe.msg_notice')::uuid;
  v_sql text;
  v_n integer;
begin
  foreach v_sql in array array[
      format('update message_recipients set reaction = %L
               where message_id = %L and user_id = auth.uid()', 'up', v_notice),
      format('update message_recipients set reply = %L
               where message_id = %L and user_id = auth.uid()', 'Díky.', v_notice),
      format('update message_recipients set read_at = now(), reaction = %L, reply = %L
               where message_id = %L and user_id = auth.uid()', 'down', 'Ne.', v_notice)] loop
    begin
      execute v_sql;
      raise exception 'FAIL: a notice took a reaction or a reply: %', v_sql;
    exception when others then
      if sqlerrm <> 'not_allowed' then raise; end if;
    end;
  end loop;
  update message_recipients set read_at = now()
   where message_id = v_notice and user_id = auth.uid();
  get diagnostics v_n = row_count;
  if v_n <> 1 or (select read_at from message_recipients
                   where message_id = v_notice and user_id = auth.uid()) is null then
    raise exception 'FAIL: reading a notice did not land';
  end if;
  raise notice 'OK: a notice takes no reaction or reply, only a read (0051)';
end $$;


-- 23q. Nothing else is writable: inserting or deleting on either table,
-- or updating any other column (the body; a recipient row's user_id or
-- reacted_at), is a privilege error for the app — for Bára, who got none
-- of today's day messages, and for Cyril on his own row alike.
do $$
declare
  v_day constant uuid := current_setting('probe.msg_day')::uuid;
  v_who text;
  v_sql text;
begin
  foreach v_who in array array['51000000-0000-0000-0000-000000000011',
                               '51000000-0000-0000-0000-000000000012'] loop
    perform set_config('request.jwt.claims',
      '{"sub":"' || v_who || '","role":"authenticated"}', true);
    foreach v_sql in array array[
        format($q$insert into messages (tenant_id, author_role, kind, audience, body)
                  values ('00000000-0000-0000-0000-000000000051', 'player', 'message',
                          'admins', 'Mimo RPC.')$q$),
        format('insert into message_recipients (message_id, user_id, tenant_id)
                  values (%L, %L, %L)', v_day, v_who,
               '00000000-0000-0000-0000-000000000051'),
        format('delete from message_recipients where message_id = %L', v_day),
        format('delete from messages where id = %L', v_day),
        format('update messages set body = %L where id = %L', 'Přepsáno.', v_day),
        format('update message_recipients set user_id = %L where message_id = %L',
               v_who, v_day),
        format('update message_recipients set reacted_at = now() where message_id = %L',
               v_day)] loop
      begin
        execute v_sql;
        raise exception 'FAIL: % could run: %', v_who, v_sql;
      exception when insufficient_privilege then
        null;
      end;
    end loop;
  end loop;
  raise notice 'OK: the app writes neither table but its own read/reaction/reply (0051)';
end $$;

-- 23r. The RPCs are the app's and not anon's; prune_messages is the
-- server's alone; can_read_message, visible_message_ids and
-- visible_recipient_message_ids are the policies' (authenticated); the reacted_at trigger's function is
-- nobody's to call.
reset role;
do $$
declare
  v_f text;
begin
  foreach v_f in array array[
      'message_send(text, text, date, uuid, text, text, timestamptz, boolean)',
      'message_update(uuid, text, text, timestamptz)',
      'message_delete(uuid)',
      'can_read_message(uuid)',
      'visible_message_ids()',
      'visible_recipient_message_ids()'] loop
    if has_function_privilege('anon', 'public.' || v_f, 'execute') then
      raise exception 'FAIL: anon may execute %', v_f;
    end if;
    if not has_function_privilege('authenticated', 'public.' || v_f, 'execute') then
      raise exception 'FAIL: the app cannot call %', v_f;
    end if;
    if not (select prosecdef from pg_proc
             where oid = ('public.' || v_f)::regprocedure) then
      raise exception 'FAIL: % is not security definer', v_f;
    end if;
  end loop;
  if has_function_privilege('anon', 'public.prune_messages()', 'execute')
     or has_function_privilege('authenticated', 'public.prune_messages()', 'execute')
     or not has_function_privilege('service_role', 'public.prune_messages()', 'execute') then
    raise exception 'FAIL: prune_messages must be the service''s alone';
  end if;
  foreach v_f in array array['is_on_duty()', 'duty_gate(date)',
                              'message_recipients_stamp_reacted()'] loop
    if has_function_privilege('authenticated', 'public.' || v_f, 'execute')
       or has_function_privilege('anon', 'public.' || v_f, 'execute') then
      raise exception 'FAIL: 0051 opened % to the app', v_f;
    end if;
  end loop;
  raise notice 'OK: the message RPCs are the app''s, prune the server''s, the duty helpers still internal (0051)';
end $$;
set local role authenticated;


-- 23s. message_update: notices only (a message is unknown_message), the
-- alley's admin only (a player is not_allowed, another alley's admin finds
-- nothing); a valid edit writes title/body/expiry and bumps updated_at;
-- "Sejmout" is an expiry of now, "Do odvolání" an expiry of null.
do $$
declare
  v_day constant uuid := current_setting('probe.msg_day')::uuid;
  v_notice constant uuid := current_setting('probe.msg_notice')::uuid;
begin
  perform set_config('request.jwt.claims',
    '{"sub":"51000000-0000-0000-0000-000000000012","role":"authenticated"}', true);
  begin
    perform message_update(v_notice, 'Moje', 'Přepsáno.', null);
    raise exception 'FAIL: a player edited a notice';
  exception when others then
    if sqlerrm <> 'not_allowed' then raise; end if;
  end;
  perform set_config('request.jwt.claims',
    '{"sub":"50000000-0000-0000-0000-000000000010","role":"authenticated"}', true);
  begin
    perform message_update(v_notice, 'Cizí', 'Přepsáno.', null);
    raise exception 'FAIL: another alley''s admin edited T''s notice';
  exception when others then
    if sqlerrm <> 'unknown_message' then raise; end if;
  end;
  perform set_config('request.jwt.claims',
    '{"sub":"51000000-0000-0000-0000-000000000010","role":"authenticated"}', true);
  begin
    perform message_update(v_day, 'Nadpis', 'Přepsáno.', null);
    raise exception 'FAIL: message_update edited a message, not a notice';
  exception when others then
    if sqlerrm <> 'unknown_message' then raise; end if;
  end;
  begin
    perform message_update(v_notice, '  ', 'Text.', null);
    raise exception 'FAIL: a notice lost its title';
  exception when others then
    if sqlerrm <> 'title_required' then raise; end if;
  end;
  begin
    perform message_update(v_notice, E'\n\t', 'Text.', null);
    raise exception 'FAIL: a notice took a title of newlines and tabs';
  exception when others then
    if sqlerrm <> 'title_required' then raise; end if;
  end;
  begin
    perform message_update(v_notice, repeat('a', 81), 'Text.', null);
    raise exception 'FAIL: a notice took an 81-character title';
  exception when others then
    if sqlerrm <> 'title_too_long' then raise; end if;
  end;
  begin
    perform message_update(v_notice, repeat('👍🏽', 41), 'Text.', null);
    raise exception 'FAIL: a notice took a title of 82 code points';
  exception when others then
    if sqlerrm <> 'title_too_long' then raise; end if;
  end;
  begin
    perform message_update(v_notice, 'Nadpis', E'\n\n\t', null);
    raise exception 'FAIL: a notice took a body of newlines and tabs';
  exception when others then
    if sqlerrm <> 'body_required' then raise; end if;
  end;
  begin
    perform message_update(v_notice, 'Nadpis', repeat('a', 2001), null);
    raise exception 'FAIL: a notice went over 2000 characters';
  exception when others then
    if sqlerrm <> 'body_too_long' then raise; end if;
  end;
  raise notice 'OK: message_update is the alley admin''s, for notices, checked (0051)';
end $$;
reset role;
update messages set updated_at = now() - interval '1 day'
 where id = current_setting('probe.msg_notice')::uuid;
set local role authenticated;
set local request.jwt.claims =
  '{"sub":"51000000-0000-0000-0000-000000000010","role":"authenticated"}'; -- Adam
do $$
declare
  v_notice constant uuid := current_setting('probe.msg_notice')::uuid;
  v_row messages;
begin
  perform message_update(v_notice, E' Nové dráhy od úterý\n', E'\n\t Posun o den. \r\n',
                         now() + interval '7 days');
  select * into v_row from messages where id = v_notice;
  if v_row.title <> 'Nové dráhy od úterý' or v_row.body <> 'Posun o den.'
     or v_row.expires_at <> now() + interval '7 days' or v_row.updated_at <> now() then
    raise exception 'FAIL: the notice edit did not land: %', v_row;
  end if;
  raise notice 'OK: an edit writes title, body and expiry and bumps updated_at (0051)';
end $$;
do $$
declare
  v_notice constant uuid := current_setting('probe.msg_notice')::uuid;
begin
  perform message_update(v_notice, 'Nové dráhy od úterý', 'Posun o den.', now());
  if (select expires_at from messages where id = v_notice) <> now() then
    raise exception 'FAIL: Sejmout did not expire the notice now';
  end if;
  raise notice 'OK: Sejmout expires the notice now (0051)';
end $$;
do $$
declare
  v_notice constant uuid := current_setting('probe.msg_notice')::uuid;
begin
  perform message_update(v_notice, 'Nové dráhy od úterý', 'Posun o den.', null);
  if (select expires_at from messages where id = v_notice) is not null then
    raise exception 'FAIL: a null expiry did not mean do odvolání';
  end if;
  raise notice 'OK: a null expiry is do odvolání again (0051)';
end $$;


-- 23t. message_delete: not by another player (unknown_message) nor by
-- another alley's admin; by the author, with the recipients cascading;
-- by the admin on someone else's message.
do $$
declare
  v_notice constant uuid := current_setting('probe.msg_notice')::uuid;
begin
  perform set_config('request.jwt.claims',
    '{"sub":"51000000-0000-0000-0000-000000000013","role":"authenticated"}', true);
  begin
    perform message_delete(v_notice);
    raise exception 'FAIL: Dana deleted Adam''s notice';
  exception when others then
    if sqlerrm <> 'unknown_message' then raise; end if;
  end;
  perform set_config('request.jwt.claims',
    '{"sub":"50000000-0000-0000-0000-000000000010","role":"authenticated"}', true);
  begin
    perform message_delete(v_notice);
    raise exception 'FAIL: another alley''s admin deleted T''s notice';
  exception when others then
    if sqlerrm <> 'unknown_message' then raise; end if;
  end;
  raise notice 'OK: nobody but the author or the alley''s admin deletes (0051)';
end $$;
-- 23t, continued. The author's right needs the account still approved and
-- not the kiosk, like every other right here: Cyril, back to pending or
-- set as the kiosk, cannot delete his own message to the admins.
reset role;
update profiles set status = 'pending' where id = '51000000-0000-0000-0000-000000000012';
set local role authenticated;
set local request.jwt.claims =
  '{"sub":"51000000-0000-0000-0000-000000000012","role":"authenticated"}'; -- Cyril, pending
do $$
begin
  perform message_delete(current_setting('probe.msg_cyril_admins')::uuid);
  raise exception 'FAIL: an author back to pending deleted his message';
exception when others then
  if sqlerrm <> 'not_allowed' then raise; end if;
end $$;
reset role;
update profiles set status = 'approved', role = 'kiosk'
 where id = '51000000-0000-0000-0000-000000000012';
set local role authenticated;
do $$
begin
  begin
    perform message_delete(current_setting('probe.msg_cyril_admins')::uuid);
    raise exception 'FAIL: an author set as the kiosk deleted his message';
  exception when others then
    if sqlerrm <> 'not_allowed' then raise; end if;
  end;
  raise notice 'OK: an author back to pending or set as the kiosk deletes nothing (0051)';
end $$;
reset role;
update profiles set role = 'player' where id = '51000000-0000-0000-0000-000000000012';
set local role authenticated;
set local request.jwt.claims =
  '{"sub":"51000000-0000-0000-0000-000000000012","role":"authenticated"}'; -- Cyril
select message_delete(current_setting('probe.msg_cyril_admins')::uuid);
set local request.jwt.claims =
  '{"sub":"51000000-0000-0000-0000-000000000010","role":"authenticated"}'; -- Adam
select message_delete(current_setting('probe.msg_bara_day')::uuid);
reset role;
do $$
begin
  if exists (select 1 from messages
              where id in (current_setting('probe.msg_cyril_admins')::uuid,
                           current_setting('probe.msg_bara_day')::uuid))
     or exists (select 1 from message_recipients
                 where message_id in (current_setting('probe.msg_cyril_admins')::uuid,
                                      current_setting('probe.msg_bara_day')::uuid)) then
    raise exception 'FAIL: a deleted message or its recipients stayed';
  end if;
  raise notice 'OK: the author and the admin delete, the recipients go with it (0051)';
end $$;

-- 23u. prune_messages: messages whose key day (on_date, else created_at in
-- Prague) is over 90 days old go; a notice that old and a message of 89
-- days stay.
do $$
declare
  v_t constant uuid := '00000000-0000-0000-0000-000000000051';
  v_today constant date := (now() at time zone 'Europe/Prague')::date;
  v_old_day uuid;
  v_old_admins uuid;
  v_old_notice uuid;
  v_recent uuid;
begin
  insert into messages (tenant_id, author_role, kind, audience, on_date, body)
    values (v_t, 'admin', 'message', 'day', v_today - 91, 'Staré.')
    returning id into v_old_day;
  insert into messages (tenant_id, author_role, kind, audience, body, created_at)
    values (v_t, 'player', 'message', 'admins', 'Staré bez dne.', now() - interval '91 days')
    returning id into v_old_admins;
  insert into messages (tenant_id, author_role, kind, audience, title, body, created_at)
    values (v_t, 'admin', 'notice', 'all', 'Stará', 'Nástěnka.', now() - interval '91 days')
    returning id into v_old_notice;
  insert into messages (tenant_id, author_role, kind, audience, on_date, body)
    values (v_t, 'admin', 'message', 'day', v_today - 89, 'Nedávné.')
    returning id into v_recent;
  if prune_messages() < 2 then
    raise exception 'FAIL: prune_messages removed fewer than the two old messages';
  end if;
  if exists (select 1 from messages where id in (v_old_day, v_old_admins)) then
    raise exception 'FAIL: an old message survived the prune';
  end if;
  if (select count(*) from messages where id in (v_old_notice, v_recent)) <> 2 then
    raise exception 'FAIL: the prune took a notice or a recent message';
  end if;
  raise notice 'OK: prune_messages drops messages over 90 days, keeps notices and recent ones (0051)';
end $$;

-- 23v. The machinery: both notify triggers, the prune cron job, and a
-- block that goes away leaves its messages on their day (block_id null).
do $$
declare
  v_t constant uuid := '00000000-0000-0000-0000-000000000051';
  v_blk uuid;
  v_id uuid;
begin
  if (select count(*) from pg_trigger
       where tgname in ('notify_messages', 'notify_message_reactions')
         and not tgisinternal) <> 2 then
    raise exception 'FAIL: a notify trigger is missing';
  end if;
  -- And their shape: a read (read_at alone) is no UPDATE OF reaction,
  -- reply, so it posts nothing; a write that leaves both as they were (a
  -- no-op PATCH, the same 👍 clicked twice in the e-mail) fails the WHEN
  -- and never reaches pg_net either. A flip (👍 → 👎 → 👍) still notifies
  -- every time — accepted, the spec wants every reaction told.
  if pg_get_triggerdef((select oid from pg_trigger where tgname = 'notify_messages'))
     not like 'CREATE TRIGGER notify_messages AFTER INSERT ON public.messages '
              'FOR EACH ROW EXECUTE FUNCTION %notify_webhook()' then
    raise exception 'FAIL: notify_messages is not after insert on messages: %',
      pg_get_triggerdef((select oid from pg_trigger where tgname = 'notify_messages'));
  end if;
  if pg_get_triggerdef((select oid from pg_trigger where tgname = 'notify_message_reactions'))
     not like 'CREATE TRIGGER notify_message_reactions AFTER UPDATE OF reaction, reply '
              'ON public.message_recipients FOR EACH ROW '
              'WHEN (((old.reaction IS DISTINCT FROM new.reaction) '
              'OR (old.reply IS DISTINCT FROM new.reply))) '
              'EXECUTE FUNCTION %notify_webhook()' then
    raise exception 'FAIL: notify_message_reactions is not after update of reaction, reply when either changed: %',
      pg_get_triggerdef((select oid from pg_trigger where tgname = 'notify_message_reactions'));
  end if;
  if (select count(*) from cron.job where jobname = 'messages-prune') <> 1 then
    raise exception 'FAIL: the messages-prune cron job is missing';
  end if;
  insert into time_blocks (tenant_id, starts_at, ends_at, position)
    values (v_t, '20:00', '21:00', 5) returning id into v_blk;
  insert into messages (tenant_id, author_role, kind, audience, on_date, block_id, body)
    values (v_t, 'admin', 'message', 'block', (now() at time zone 'Europe/Prague')::date,
            v_blk, 'Na zrušený blok.')
    returning id into v_id;
  delete from time_blocks where id = v_blk;
  if (select block_id from messages where id = v_id) is not null
     or (select on_date from messages where id = v_id) is null then
    raise exception 'FAIL: a removed block took its message along or kept a dangling id';
  end if;
  raise notice 'OK: notify triggers in place and shaped (a read or a no-op posts nothing), prune cron in place; a removed block leaves the message on its day (0051)';
end $$;

reset role;
delete from duty_periods
 where tenant_id in ('00000000-0000-0000-0000-000000000050',
                     '00000000-0000-0000-0000-000000000002',
                     '00000000-0000-0000-0000-000000000051');
delete from messages
 where tenant_id in ('00000000-0000-0000-0000-000000000050',
                     '00000000-0000-0000-0000-000000000051');

-- 23w. Running 0051 a second time leaves every privilege as the first run
-- left it, down to the order of the ACL entries. pg_dump writes a table's
-- GRANTs in ACL order, and CI diffs a dump of a database built once from
-- the migrations against supabase/schema.sql, which comes from a local
-- database that has seen the migration more than once. A revoke followed by
-- a grant back moves that grantee to the end of the ACL, so a grant block
-- that adds another grantee after it on the first run orders the two one
-- way on a fresh build and the other way from the second run on.
create temp view acl_0051 as
  select c.relname::text as obj, c.relacl::text as acl
    from pg_class c
   where c.oid in ('public.messages'::regclass, 'public.message_recipients'::regclass)
  union all
  select a.attrelid::regclass || '.' || a.attname, a.attacl::text
    from pg_attribute a
   where a.attrelid in ('public.messages'::regclass, 'public.message_recipients'::regclass)
     and a.attnum > 0 and not a.attisdropped
  union all
  select p.oid::regprocedure::text, p.proacl::text
    from pg_proc p
   where p.pronamespace = 'public'::regnamespace
     and p.proname in ('message_recipients_stamp_reacted', 'can_read_message',
                       'visible_message_ids', 'visible_recipient_message_ids',
                       'message_send', 'message_update', 'message_delete',
                       'prune_messages');
create temp table acl_0051_before as select * from acl_0051;
set client_min_messages = warning;
\ir ../migrations/0051_messages.sql
reset client_min_messages;
do $$
declare
  v_bad text;
begin
  select string_agg(coalesce(b.obj, a.obj) || ': ' || coalesce(b.acl, '(default)')
                    || ' -> ' || coalesce(a.acl, '(default)'), '; ' order by coalesce(b.obj, a.obj))
    into v_bad
    from acl_0051_before b
    full join acl_0051 a on a.obj = b.obj
   where a.obj is null or b.obj is null or a.acl is distinct from b.acl;
  if v_bad is not null then
    raise exception 'FAIL: running 0051 again changed privileges (the schema snapshot would differ from a fresh build): %', v_bad;
  end if;
  raise notice 'OK: running 0051 again leaves every privilege and its ACL order as it was (0051)';
end $$;

-- Running 0051 again put back its two read-rule functions: bring back the
-- kiosk's notices (0064), which later checks rely on.
\ir ../migrations/0064_kiosk_reads_notices.sql

-- 0052 One device token, one profile ----------------------------------------
-- 20. notify pushes to every profile holding a token, so a token the last
-- account on a device kept (signed out offline, session expired, an older
-- app) carried its notifications to the next person there. Whoever
-- registers a token now takes it from everyone else — across alleys too,
-- it is the same phone — and sign-out hands back only this device's token.
reset role;
update profiles set fcm_token = 'tok-0052-other-phone'
where id = '10000000-0000-0000-0000-000000000004';
set local role authenticated;
set local request.jwt.claims =
  '{"sub":"10000000-0000-0000-0000-000000000001","role":"authenticated"}';
update profiles set fcm_token = 'tok-0052-device' where id = auth.uid();
-- Player 2 (another alley) signs in on the same phone.
set local request.jwt.claims =
  '{"sub":"10000000-0000-0000-0000-000000000002","role":"authenticated"}';
update profiles set fcm_token = 'tok-0052-device' where id = auth.uid();
reset role;
do $$
begin
  if (select fcm_token from profiles
      where id = '10000000-0000-0000-0000-000000000001') is not null then
    raise exception 'FAIL: the previous account kept the device token';
  end if;
  if (select fcm_token from profiles
      where id = '10000000-0000-0000-0000-000000000002')
     is distinct from 'tok-0052-device' then
    raise exception 'FAIL: the new account did not get the device token';
  end if;
  if (select fcm_token from profiles
      where id = '10000000-0000-0000-0000-000000000004')
     is distinct from 'tok-0052-other-phone' then
    raise exception 'FAIL: claiming a token touched another device''s token';
  end if;
  raise notice 'OK: registering a device token takes it from the previous account, across alleys (0052)';
end $$;

-- 20b. Sign-out (Api.signOut) clears the token only while it is still this
-- device's: player 2's other phone registered since, and signing out here
-- must not cut that phone off.
update profiles set fcm_token = 'tok-0052-phone-b'
where id = '10000000-0000-0000-0000-000000000002';
set local role authenticated;
set local request.jwt.claims =
  '{"sub":"10000000-0000-0000-0000-000000000002","role":"authenticated"}';
update profiles set fcm_token = null
where id = auth.uid() and fcm_token = 'tok-0052-device';
do $$
begin
  if (select fcm_token from profiles where id = auth.uid())
     is distinct from 'tok-0052-phone-b' then
    raise exception 'FAIL: signing out on one phone cleared the other phone''s token';
  end if;
end $$;
update profiles set fcm_token = null
where id = auth.uid() and fcm_token = 'tok-0052-phone-b';
reset role;
do $$
begin
  if (select fcm_token from profiles
      where id = '10000000-0000-0000-0000-000000000002') is not null then
    raise exception 'FAIL: a player could not hand back their own device token';
  end if;
  raise notice 'OK: sign-out clears the token only while it is still this device''s (0052)';
end $$;

-- 21. League matches (0055): the matches of a competition one of our active
-- teams plays that none of our active teams plays — in their own tables,
-- never in priority_slots.
do $$
declare
  v_a constant uuid := '00000000-0000-0000-0000-00000000000a';
  v_slots integer;
  v_teams integer;
  v_clubs integer;
  v_res jsonb;
  v_c1 tid;
  v_c2 tid;
  v_list constant jsonb := '[
    {"site_match_id":9001,"site_slug":"liga-x-2026-kolo-3-a-b","date":"2026-10-10","starts_at":"10:00",
     "home_team":"KK A","away_team":"KK B","home_team_slug":"kk-a-muzi","away_team_slug":"kk-b-muzi",
     "competition":"Liga X","round":3,"status":"finished","match_type":"TEAMS_OF_6","discipline":"T120",
     "home":{"points":6,"total":3200,"fulls":2100,"spares":1100,"errors":10,"set_points":15},
     "away":{"points":2,"total":3100,"fulls":2050,"spares":1050,"errors":14,"set_points":9}},
    {"site_match_id":9002,"site_slug":"liga-x-2026-kolo-4-c-d","date":"2026-10-17","starts_at":"",
     "home_team":"KK C","away_team":"KK D","home_team_slug":"kk-c-muzi","away_team_slug":"kk-d-muzi",
     "competition":"Liga X","round":4,"status":"scheduled","home":{},"away":{}},
    {"site_match_id":9003,"site_slug":"liga-x-2026-kolo-3-e-f","date":"2026-10-10","starts_at":"10:00",
     "home_team":"KK E","away_team":"KK F","competition":"Liga X","round":3,"status":"scheduled"}]';
begin
  insert into teams (tenant_id, name, site_slug, competition_slug, active)
  values (v_a, 'Liga tým 0055', 'liga-tym-0055-muzi', 'liga-x-2026', true);
  -- 9003 is one of OUR matches already (a cka: slot): it must be skipped.
  perform set_config('import.run', 'on', true);
  insert into priority_slots
    (tenant_id, date, starts_at, ends_at, type_id, home_team, away_team,
     created_by, import_key, site_slug, site_match_id, is_away)
  values
    (v_a, '2026-10-10', '10:00', '13:00',
     (select id from priority_slot_types where tenant_id = v_a and is_match and builtin),
     'KK E', 'KK F', '10000000-0000-0000-0000-000000000001',
     'cka:9003', 'liga-x-2026-kolo-3-e-f', 9003, true);
  perform set_config('import.run', '', true);
  select count(*) into v_slots from priority_slots;
  select count(*) into v_teams from teams;
  select count(*) into v_clubs from clubs;

  -- 9002's time is an empty string, as the site can send it: no time, no error.
  v_res := apply_league_matches(v_a, 'liga-x-2026', v_list);
  if (v_res->>'league_inserted')::int <> 2 or (v_res->>'league_detail_jobs')::int <> 1 then
    raise exception 'FAIL: apply_league_matches answered %', v_res;
  end if;
  if (select count(*) from league_matches where tenant_id = v_a) <> 2
     or exists (select 1 from league_matches where site_match_id = 9003) then
    raise exception 'FAIL: league matches wrong (our own 9003 must be skipped)';
  end if;
  if (select count(*) from priority_slots) <> v_slots or (select count(*) from teams) <> v_teams
     or (select count(*) from clubs) <> v_clubs then
    raise exception 'FAIL: a league match leaked into priority_slots, teams or clubs';
  end if;
  if (select count(*) from notification_jobs
       where kind = 'federation_league_match' and payload->>'tenant_id' = v_a::text) <> 1
     or exists (select 1 from notification_jobs
                 where kind not like 'federation%' and payload::text like '%liga-x-2026%') then
    raise exception 'FAIL: league matches queued the wrong jobs';
  end if;
  if (select home_points || '/' || home_total || '/' || discipline from league_matches
       where site_match_id = 9001) <> '6/3200/T120'
     or not (select starts_at is null from league_matches where site_match_id = 9002) then
    raise exception 'FAIL: a league match lost its totals, its format or its missing time';
  end if;
  if not exists (select 1 from pg_class where relname = 'league_matches' and relreplident = 'f')
     or not exists (select 1 from pg_class where relname = 'league_player_results' and relreplident = 'f') then
    raise exception 'FAIL: the league tables must have replica identity full';
  end if;

  -- Nothing changed: nothing written (the row stays where it is), nothing re-queued.
  select ctid into v_c1 from league_matches where site_match_id = 9001;
  v_res := apply_league_matches(v_a, 'liga-x-2026', v_list);
  select ctid into v_c2 from league_matches where site_match_id = 9001;
  if (v_res->>'league_updated')::int <> 0 or (v_res->>'league_detail_jobs')::int <> 0
     or v_c1 is distinct from v_c2 then
    raise exception 'FAIL: an unchanged league list wrote or re-queued: %', v_res;
  end if;
  -- A change of the format alone is a change.
  v_res := apply_league_matches(v_a, 'liga-x-2026',
    jsonb_set(v_list, '{0,discipline}', '"T100"'));
  if (v_res->>'league_updated')::int <> 1
     or (select discipline from league_matches where site_match_id = 9001) <> 'T100' then
    raise exception 'FAIL: a changed format was not written: %', v_res;
  end if;
  -- An empty list deletes nothing; a shorter one drops what the site forgot
  -- together with its detail job.
  perform apply_league_matches(v_a, 'liga-x-2026', '[]'::jsonb);
  if (select count(*) from league_matches where tenant_id = v_a) <> 2 then
    raise exception 'FAIL: an empty list deleted league matches';
  end if;
  perform apply_league_matches(v_a, 'liga-x-2026', jsonb_build_array(v_list->1));
  if (select count(*) from league_matches where tenant_id = v_a) <> 1
     or exists (select 1 from notification_jobs where kind = 'federation_league_match'
                 and payload->>'tenant_id' = v_a::text) then
    raise exception 'FAIL: a match the site no longer lists stayed, or left its detail job behind';
  end if;
  perform apply_league_matches(v_a, 'liga-x-2026', v_list);
  raise notice 'OK: apply_league_matches keeps foreign matches out of slots/teams/clubs, skips ours, tolerates an empty time, writes only changes (format too), deletes only from a non-empty list and with the job (0055)';
end $$;

-- The final status stands: the detail may lag, and the round page and the
-- detail may disagree on finished / forfeit — neither flips it every night.
do $$
declare
  v_a constant uuid := '00000000-0000-0000-0000-00000000000a';
  v_list jsonb;
  v_res jsonb;
  v_pay constant jsonb := '{"status":"finished","match_type":"TEAMS_OF_6","discipline":"T120",
    "video_url":null,"venue":{"slug":"cizi-kuzelna","name":"Cizí kuželna"},"home_prep":30,
    "home":{"points":6,"total":3201,"fulls":2101,"spares":1100,"errors":10,"set_points":15},
    "away":{"points":2,"total":3100,"fulls":2050,"spares":1050,"errors":14,"set_points":9},
    "players":[{"side":"home","position":1,"player_name":"Jan Cizí","player_site_id":7,
      "player_slug":"jan-cizi","fulls":350,"spares":190,"errors":1,"total":540,"set_points":3,
      "team_points":1,"sub_name":"Petr Nový","sub_site_id":9,"sub_slug":"petr-novy","sub_from_throw":41,
      "lanes":[{"lane":1,"fulls":90,"spares":45,"errors":0,"total":135,"setPoints":1}]}]}';
begin
  if not apply_league_result(v_a, 9001, v_pay) then
    raise exception 'FAIL: apply_league_result refused a league match';
  end if;
  if (select (venue_slug, detail_status, home_total, discipline)::text from league_matches where site_match_id = 9001)
     is distinct from '(cizi-kuzelna,finished,3201,T120)'
     or (select count(*) from league_player_results
          where match_id = (select id from league_matches where site_match_id = 9001)
            and sub_name = 'Petr Nový' and lanes->0->>'total' = '135') <> 1 then
    raise exception 'FAIL: apply_league_result did not store the result and the lines';
  end if;
  if exists (select 1 from notification_jobs where kind = 'federation_venue' and dedupe_key like '%cizi-kuzelna%') then
    raise exception 'FAIL: a foreign venue was queued for a fetch';
  end if;
  perform apply_league_result(v_a, 9001, v_pay);
  if (select count(*) from league_player_results where tenant_id = v_a) <> 1 then
    raise exception 'FAIL: a repeated detail duplicated the lines';
  end if;
  if apply_league_result(v_a, 424242, v_pay) then
    raise exception 'FAIL: apply_league_result answered true for an unknown match';
  end if;

  -- A lagging detail (still in progress, partial totals) does not take a
  -- final status back, and does not overwrite the totals.
  perform apply_league_result(v_a, 9001,
    '{"status":"in_progress","home":{"points":null,"total":900},"away":{"points":null,"total":800},"players":[]}');
  if (select status || '/' || home_total from league_matches where site_match_id = 9001) <> 'finished/3201' then
    raise exception 'FAIL: a lagging detail took a final status back';
  end if;
  -- The detail says forfeit where the round page says finished: the detail's
  -- word stands, and the round page — saying the same as last night — neither
  -- flips it back nor re-queues the lines.
  perform apply_league_result(v_a, 9001, jsonb_set(v_pay, '{status}', '"forfeit"'));
  v_list := '[{"site_match_id":9001,"site_slug":"liga-x-2026-kolo-3-a-b","date":"2026-10-10","starts_at":"10:00",
     "home_team":"KK A","away_team":"KK B","home_team_slug":"kk-a-muzi","away_team_slug":"kk-b-muzi",
     "competition":"Liga X","round":3,"status":"finished","match_type":"TEAMS_OF_6","discipline":"T120",
     "home":{"points":6,"total":3200,"fulls":2100,"spares":1100,"errors":10,"set_points":15},
     "away":{"points":2,"total":3100,"fulls":2050,"spares":1050,"errors":14,"set_points":9}}]';
  v_res := apply_league_matches(v_a, 'liga-x-2026', v_list);
  if (select status from league_matches where site_match_id = 9001) <> 'forfeit'
     or (v_res->>'league_updated')::int <> 0 or (v_res->>'league_detail_jobs')::int <> 0 then
    raise exception 'FAIL: the round page flipped a status the detail settled, or re-queued: %', v_res;
  end if;
  -- The detail's totals differ from the round page's (3201 against 3200):
  -- that is no change of the round page, so nothing is re-fetched every night.
  if (select home_total from league_matches where site_match_id = 9001) <> 3201 then
    raise exception 'FAIL: the round page overwrote the totals the detail wrote';
  end if;
  -- A late correction of the totals sends the lines to be fetched again (the
  -- job of the first fetch has long run: it is gone).
  delete from notification_jobs where kind = 'federation_league_match'
     and payload->>'tenant_id' = v_a::text;
  v_res := apply_league_matches(v_a, 'liga-x-2026',
    jsonb_set(v_list, '{0,home,total}', '3300'));
  if (v_res->>'league_updated')::int <> 1 or (v_res->>'league_detail_jobs')::int <> 1
     or (select detail_status from league_matches where site_match_id = 9001) is not null
     or (select status || '/' || home_total from league_matches where site_match_id = 9001) <> 'finished/3300' then
    raise exception 'FAIL: a corrected result did not queue its lines again: %', v_res;
  end if;
  -- A correction of the STATUS alone (finished -> forfeit, same totals) is
  -- picked up after the detail settled too.
  perform apply_league_result(v_a, 9001, jsonb_set(v_pay, '{home,total}', '3300'));
  delete from notification_jobs where kind = 'federation_league_match'
     and payload->>'tenant_id' = v_a::text;
  v_res := apply_league_matches(v_a, 'liga-x-2026',
    jsonb_set(jsonb_set(v_list, '{0,home,total}', '3300'), '{0,status}', '"forfeit"'));
  if (v_res->>'league_updated')::int <> 1 or (v_res->>'league_detail_jobs')::int <> 1
     or (select status from league_matches where site_match_id = 9001) <> 'forfeit' then
    raise exception 'FAIL: a status-only correction was not picked up: %', v_res;
  end if;
  -- A detail page that keeps saying „in progress“ is given up a week after
  -- the match: not re-queued every night for the rest of the season.
  update league_matches set detail_status = 'in_progress', status = 'finished',
         date = ((now() at time zone 'Europe/Prague') - interval '10 days')::date
   where site_match_id = 9001;
  delete from notification_jobs where kind = 'federation_league_match'
     and payload->>'tenant_id' = v_a::text;
  v_res := apply_league_matches(v_a, 'liga-x-2026', jsonb_build_array(
    jsonb_set(jsonb_set(jsonb_set(v_list, '{0,home,total}', '3300'), '{0,status}', '"forfeit"'),
              '{0,date}', to_jsonb(((now() at time zone 'Europe/Prague') - interval '10 days')::date::text))->0));
  if (v_res->>'league_detail_jobs')::int <> 0 then
    raise exception 'FAIL: a lagging detail of an old match was queued again: %', v_res;
  end if;
  update league_matches set date = ((now() at time zone 'Europe/Prague') - interval '2 days')::date
   where site_match_id = 9001;
  v_res := apply_league_matches(v_a, 'liga-x-2026', jsonb_build_array(
    jsonb_set(jsonb_set(jsonb_set(v_list, '{0,home,total}', '3300'), '{0,status}', '"forfeit"'),
              '{0,date}', to_jsonb(((now() at time zone 'Europe/Prague') - interval '2 days')::date::text))->0));
  if (v_res->>'league_detail_jobs')::int <> 1 then
    raise exception 'FAIL: a lagging detail of a recent match was not queued again: %', v_res;
  end if;
  -- (the lists above named only 9001: 9002 was dropped as forgotten — bring it back)
  perform apply_league_matches(v_a, 'liga-x-2026', jsonb_build_array(
    jsonb_set(v_list, '{0,home,total}', '3300')->0,
    '{"site_match_id":9002,"site_slug":"liga-x-2026-kolo-4-c-d","date":"2026-10-17","starts_at":"",
      "home_team":"KK C","away_team":"KK D","home_team_slug":"kk-c-muzi","away_team_slug":"kk-d-muzi",
      "competition":"Liga X","round":4,"status":"scheduled","home":{},"away":{}}'::jsonb));
  raise notice 'OK: apply_league_result stores the result, the lines and the venue (display only); a lagging detail does not take a final status back; a settled status does not flip and the detail''s totals are not fought over; a corrected total or status re-queues the lines; a detail stuck below final is given up after a week (0055)';
end $$;

-- The match of a switched-off team of ours that already has its slot: its slot
-- is stale for good, so the match is kept in league_matches (with its lines)
-- and our own match_results are never written from the round page; a match of
-- an ACTIVE team has its own job and is left alone; the moment the team is
-- switched on again the league row goes (counted as deleted) and the match is
-- fetched as ours. Also: the detail is queued for at most 3 nights in a row,
-- and a never-fetched old match is still queued (the first deploy's backfill).
do $$
declare
  v_a constant uuid := '00000000-0000-0000-0000-00000000000a';
  v_base jsonb;
  v_list jsonb;
  v_res jsonb;
  v_off jsonb;
  v_act jsonb;
  v_old jsonb;
  v_c1 tid;
  v_c2 tid;
  v_job_off constant text := 'federation_league_match:00000000-0000-0000-0000-00000000000a:9020';
  v_job_old constant text := 'federation_league_match:00000000-0000-0000-0000-00000000000a:9021';
begin
  insert into teams (tenant_id, name, site_slug, competition_slug, active)
  values (v_a, 'Vypnutý 0055', 'liga-vypnuty-muzi', 'liga-x-2026', false);
  perform set_config('import.run', 'on', true);
  insert into priority_slots
    (tenant_id, date, starts_at, ends_at, type_id, home_team, away_team,
     created_by, import_key, site_slug, site_match_id, is_away, home_team_slug, away_team_slug)
  values
    (v_a, '2026-10-24', '10:00', '13:00',
     (select id from priority_slot_types where tenant_id = v_a and is_match and builtin),
     'Vypnutý 0055', 'KK Z', '10000000-0000-0000-0000-000000000001',
     'cka:9020', 'liga-x-2026-kolo-5-off-z', 9020, true, 'liga-vypnuty-muzi', 'kk-z-muzi');
  -- 9003 becomes the match of an ACTIVE team of ours (the control).
  update priority_slots set home_team_slug = 'liga-tym-0055-muzi', away_team_slug = 'kk-f-muzi'
   where tenant_id = v_a and import_key = 'cka:9003';
  perform set_config('import.run', '', true);

  -- The rows already stored (9001, 9002), as the round page would list them.
  v_base := (select jsonb_agg(jsonb_build_object(
      'site_match_id', site_match_id, 'site_slug', site_slug, 'date', date,
      'starts_at', to_char(starts_at, 'HH24:MI'), 'home_team', home_team,
      'away_team', away_team, 'home_team_slug', home_team_slug,
      'away_team_slug', away_team_slug, 'competition', competition, 'round', round,
      'status', status, 'match_type', match_type, 'discipline', discipline,
      'home', jsonb_build_object('points', home_points, 'total', home_total, 'fulls', home_fulls,
        'spares', home_spares, 'errors', home_errors, 'set_points', home_set_points),
      'away', jsonb_build_object('points', away_points, 'total', away_total, 'fulls', away_fulls,
        'spares', away_spares, 'errors', away_errors, 'set_points', away_set_points))
      order by site_match_id)
    from league_matches where tenant_id = v_a and site_match_id in (9001, 9002));
  v_off := '{"site_match_id":9020,"site_slug":"liga-x-2026-kolo-5-off-z","date":"2026-10-24","starts_at":"10:00",
    "home_team":"Vypnutý","away_team":"KK Z","home_team_slug":"liga-vypnuty-muzi","away_team_slug":"kk-z-muzi",
    "competition":"Liga X","round":5,"status":"finished","match_type":"TEAMS_OF_6","discipline":"T120",
    "home":{"points":5,"total":3000,"fulls":2000,"spares":1000,"errors":9,"set_points":12},
    "away":{"points":3,"total":2900,"fulls":1950,"spares":950,"errors":11,"set_points":12}}';
  v_act := '{"site_match_id":9003,"site_slug":"liga-x-2026-kolo-3-e-f","date":"2026-10-10","starts_at":"10:00",
    "home_team":"Liga tým","away_team":"KK F","home_team_slug":"liga-tym-0055-muzi","away_team_slug":"kk-f-muzi",
    "competition":"Liga X","round":3,"status":"finished","match_type":"TEAMS_OF_6","discipline":"T120",
    "home":{"points":4,"total":3100,"fulls":2000,"spares":1100,"errors":8,"set_points":10},
    "away":{"points":4,"total":3100,"fulls":2000,"spares":1100,"errors":8,"set_points":10}}';
  -- A final match a month old, its lines never fetched: still queued.
  v_old := jsonb_build_object('site_match_id', 9021, 'site_slug', 'liga-x-2026-kolo-1-old-z',
    'date', ((now() at time zone 'Europe/Prague') - interval '30 days')::date::text,
    'starts_at', '10:00', 'home_team', 'KK Old', 'away_team', 'KK Z',
    'home_team_slug', 'kk-old-muzi', 'away_team_slug', 'kk-z-muzi', 'competition', 'Liga X',
    'round', 1, 'status', 'finished', 'match_type', 'TEAMS_OF_6', 'discipline', 'T120',
    'home', '{"points":4,"total":3000}'::jsonb, 'away', '{"points":4,"total":3000}'::jsonb);
  v_list := v_base || jsonb_build_array(v_off, v_act, v_old);
  delete from notification_jobs where kind = 'federation_league_match'
     and payload->>'tenant_id' = v_a::text;

  v_res := apply_league_matches(v_a, 'liga-x-2026', v_list);
  if not exists (select 1 from league_matches
                  where tenant_id = v_a and site_match_id = 9020
                    and status = 'finished' and home_total = 3000 and away_points = 3)
     or exists (select 1 from league_matches where tenant_id = v_a and site_match_id = 9003) then
    raise exception 'FAIL: a switched-off team''s match is not kept as a league row, or an active team''s is: %', v_res;
  end if;
  if exists (select 1 from match_results
              where match_id in (select id from priority_slots
                                  where tenant_id = v_a and import_key in ('cka:9020', 'cka:9003'))) then
    raise exception 'FAIL: the round page wrote a match_results row of ours';
  end if;
  if (select is_away from priority_slots where tenant_id = v_a and import_key = 'cka:9020') is distinct from true then
    raise exception 'FAIL: the switched-off team''s slot was touched';
  end if;
  if not exists (select 1 from notification_jobs where dedupe_key = v_job_off)
     or not exists (select 1 from notification_jobs where dedupe_key = v_job_old) then
    raise exception 'FAIL: the lines of a switched-off team''s match or of a never-fetched old one are not queued: %', v_res;
  end if;

  -- The same page again: nothing written.
  select ctid into v_c1 from league_matches where tenant_id = v_a and site_match_id = 9020;
  v_res := apply_league_matches(v_a, 'liga-x-2026', v_list);
  select ctid into v_c2 from league_matches where tenant_id = v_a and site_match_id = 9020;
  if (v_res->>'league_inserted')::int <> 0 or v_c1 is distinct from v_c2 then
    raise exception 'FAIL: an unchanged round page rewrote a switched-off team''s league row: %', v_res;
  end if;

  -- Nights 2 and 3 queue the lines again; the 4th does not (a page that cannot
  -- be read must not cost six fetches every night).
  for i in 2..3 loop
    delete from notification_jobs where dedupe_key = v_job_off;
    perform apply_league_matches(v_a, 'liga-x-2026', v_list);
    if not exists (select 1 from notification_jobs where dedupe_key = v_job_off) then
      raise exception 'FAIL: night % did not queue the lines', i;
    end if;
  end loop;
  delete from notification_jobs where dedupe_key = v_job_off;
  perform apply_league_matches(v_a, 'liga-x-2026', v_list);
  if exists (select 1 from notification_jobs where dedupe_key = v_job_off) then
    raise exception 'FAIL: the lines of a match that never applies were queued a 4th night';
  end if;
  -- A change of the round page starts over.
  perform apply_league_matches(v_a, 'liga-x-2026',
    v_base || jsonb_build_array(jsonb_set(v_off, '{home,total}', '3001'), v_act, v_old));
  if not exists (select 1 from notification_jobs where dedupe_key = v_job_off) then
    raise exception 'FAIL: a corrected result did not start the fetching over';
  end if;

  -- The team is switched on again: the league row goes (counted), its job with
  -- it — the match is fetched as ours from now on.
  update teams set active = true where tenant_id = v_a and site_slug = 'liga-vypnuty-muzi';
  v_res := apply_league_matches(v_a, 'liga-x-2026', v_list);
  if (v_res->>'league_deleted')::int <> 1
     or exists (select 1 from league_matches where tenant_id = v_a and site_match_id = 9020)
     or exists (select 1 from notification_jobs where dedupe_key = v_job_off) then
    raise exception 'FAIL: a match of a team switched on again stayed a league row: %', v_res;
  end if;
  -- Back to the fixture the later blocks expect.
  update teams set active = false where tenant_id = v_a and site_slug = 'liga-vypnuty-muzi';
  delete from league_matches where tenant_id = v_a and site_match_id = 9021;
  perform league_drop_orphan_jobs(v_a);
  raise notice 'OK: a switched-off team''s match is kept as a league row (our match_results and slot untouched, an active team''s match left alone), unchanged pages write nothing, the lines are queued at most 3 nights, an old never-fetched match is still queued, switching the team on drops the row (counted) and its job (0055)';
end $$;

-- A failure of the league call shows on the admin card (last_error) although
-- our own matches synced; an ordinary error still wins when it is newer.
do $$
declare
  v_a constant uuid := '00000000-0000-0000-0000-00000000000a';
begin
  if federation_last_error(v_a,
       '{"competition:liga-x-2026":{"at":"2026-10-01T10:00:00Z","league_error":"boom"}}')
     is distinct from 'Zápasy ostatních družstev: boom'
     or federation_last_error(v_a,
       '{"competition:liga-x-2026":{"at":"2026-10-01T10:00:00Z","inserted":3}}') is not null
     or federation_last_error(v_a,
       '{"competition:liga-x-2026":{"at":"2026-10-01T10:00:00Z","league_error":"boom"},
         "discover":{"at":"2026-10-02T10:00:00Z","error":"site down"}}')
     is distinct from 'site down' then
    raise exception 'FAIL: federation_last_error does not report a league failure (or misorders it)';
  end if;
  raise notice 'OK: a league failure is the admin card''s last error (0055)';
end $$;

-- RLS: our alley reads, another alley sees nothing, nobody writes.
set local role authenticated;
set local request.jwt.claims =
  '{"sub":"10000000-0000-0000-0000-000000000001","role":"authenticated"}';
do $$
begin
  if (select count(*) from league_matches) <> 2 or (select count(*) from league_player_results) <> 1 then
    raise exception 'FAIL: a member of the alley cannot read its league matches';
  end if;
  begin
    insert into league_matches (tenant_id, site_match_id, site_slug, competition_slug, date, home_team, away_team)
    values ('00000000-0000-0000-0000-00000000000a', 1, 'x', 'liga-x-2026', now()::date, 'A', 'B');
    raise exception 'FAIL: a member wrote a league match';
  exception when insufficient_privilege then null;
  end;
end $$;
reset role;

-- refresh_match on a league id. The ids are captured as the superuser: under
-- another alley's RLS a subselect would be NULL and prove nothing.
do $$
declare
  v_a constant uuid := '00000000-0000-0000-0000-00000000000a';
begin
  perform set_config('probe.lg_9001', (select id::text from league_matches where site_match_id = 9001), true);
  perform set_config('probe.lg_9002', (select id::text from league_matches where site_match_id = 9002), true);
  -- 9001: a final match with its lines: nothing to fetch. 9002: no time.
  update league_matches set status = 'finished', detail_status = 'finished',
         detail_fetched_at = now() - interval '1 hour'
   where site_match_id = 9001;
  delete from notification_jobs where kind = 'federation_league_match'
     and payload->>'tenant_id' = v_a::text;
end $$;
set local role authenticated;
set local request.jwt.claims =
  '{"sub":"10000000-0000-0000-0000-000000000001","role":"authenticated"}';
do $$
begin
  if refresh_match(current_setting('probe.lg_9002')::uuid) <> 'not_live'
     or refresh_match(current_setting('probe.lg_9001')::uuid) <> 'not_live' then
    raise exception 'FAIL: refresh_match fetched a league match that has nothing to fetch';
  end if;
end $$;
reset role;
do $$
begin
  if exists (select 1 from notification_jobs where kind = 'federation_league_match') then
    raise exception 'FAIL: a refused league refresh queued a job';
  end if;
end $$;
-- 0062: the button asks again for a final league match with its lines (a
-- correction on the site), within 14 days of its date.
set local role authenticated;
set local request.jwt.claims =
  '{"sub":"10000000-0000-0000-0000-000000000001","role":"authenticated"}';
do $$
begin
  if refresh_match(current_setting('probe.lg_9001')::uuid, true) <> 'queued' then
    raise exception 'FAIL: the button could not ask again for a final league match';
  end if;
end $$;
reset role;
do $$
begin
  delete from notification_jobs where kind = 'federation_league_match';
  update league_matches set date = date - 30 where site_match_id = 9001;
end $$;
set local role authenticated;
set local request.jwt.claims =
  '{"sub":"10000000-0000-0000-0000-000000000001","role":"authenticated"}';
do $$
begin
  if refresh_match(current_setting('probe.lg_9001')::uuid, true) <> 'not_live' then
    raise exception 'FAIL: a league match a month old was asked for again';
  end if;
end $$;
reset role;
do $$
begin
  update league_matches set date = date + 30 where site_match_id = 9001;
  if exists (select 1 from notification_jobs where kind = 'federation_league_match') then
    raise exception 'FAIL: a refused league refresh queued a job';
  end if;
  -- The lines of a finished match are missing: opening it queues one fetch.
  update league_matches set detail_status = null where site_match_id = 9001;
end $$;
set local role authenticated;
set local request.jwt.claims =
  '{"sub":"10000000-0000-0000-0000-000000000001","role":"authenticated"}';
do $$
begin
  if refresh_match(current_setting('probe.lg_9001')::uuid) <> 'queued' then
    raise exception 'FAIL: opening a final league match without its lines was not queued';
  end if;
end $$;
reset role;
do $$
declare
  v_at text;
begin
  select payload->>'requested_at' into v_at from notification_jobs
   where kind = 'federation_league_match'
     and dedupe_key like '%:' || (select site_match_id from league_matches where site_match_id = 9001);
  if v_at is null then
    raise exception 'FAIL: a league refresh wrote no job (or no requested_at)';
  end if;
  -- A repeat inside the (15 s) gate is answered queued and leaves the job
  -- alone: the request 10 seconds ago stays the request.
  update notification_jobs
     set payload = payload || jsonb_build_object('requested_at', now() - interval '10 seconds')
   where kind = 'federation_league_match';
  perform set_config('probe.req', (select payload->>'requested_at' from notification_jobs
    where kind = 'federation_league_match' limit 1), true);
end $$;
set local role authenticated;
set local request.jwt.claims =
  '{"sub":"10000000-0000-0000-0000-000000000001","role":"authenticated"}';
do $$
begin
  if refresh_match(current_setting('probe.lg_9001')::uuid, true) <> 'queued' then
    raise exception 'FAIL: a repeated league refresh was not answered queued';
  end if;
end $$;
reset role;
do $$
begin
  if (select payload->>'requested_at' from notification_jobs
       where kind = 'federation_league_match' limit 1) is distinct from current_setting('probe.req') then
    raise exception 'FAIL: a repeat inside the gate re-stamped the league job';
  end if;
  -- ... while one outside it does (the request 30 seconds ago).
  update notification_jobs
     set payload = payload || jsonb_build_object('requested_at', now() - interval '30 seconds')
   where kind = 'federation_league_match';
end $$;
set local role authenticated;
set local request.jwt.claims =
  '{"sub":"10000000-0000-0000-0000-000000000001","role":"authenticated"}';
do $$
begin
  perform refresh_match(current_setting('probe.lg_9001')::uuid, true);
end $$;
reset role;
do $$
begin
  if (select payload->>'requested_at' from notification_jobs
       where kind = 'federation_league_match' limit 1) = current_setting('probe.req') then
    raise exception 'FAIL: a repeat outside the gate did not re-stamp the league job';
  end if;
end $$;
do $$
declare
  v_a constant uuid := '00000000-0000-0000-0000-00000000000a';
begin
  -- Not final yet: asked for from an hour before the start until 30 hours
  -- after it, whatever the stale status says; then not any more.
  update league_matches set status = 'scheduled', detail_status = null, detail_fetched_at = null,
         date = ((now() at time zone 'Europe/Prague') - interval '8 hours')::date,
         starts_at = ((now() at time zone 'Europe/Prague') - interval '8 hours')::time
   where site_match_id = 9001;
  delete from notification_jobs where kind = 'federation_league_match'
     and payload->>'tenant_id' = v_a::text;
end $$;
set local role authenticated;
set local request.jwt.claims =
  '{"sub":"10000000-0000-0000-0000-000000000001","role":"authenticated"}';
do $$
begin
  if refresh_match(current_setting('probe.lg_9001')::uuid) <> 'queued' then
    raise exception 'FAIL: a stale scheduled league match 8 hours after its start was not refreshable';
  end if;
end $$;
reset role;
do $$
declare
  v_a constant uuid := '00000000-0000-0000-0000-00000000000a';
begin
  update league_matches set date = ((now() at time zone 'Europe/Prague') - interval '2 days')::date
   where site_match_id = 9001;
  delete from notification_jobs where kind = 'federation_league_match'
     and payload->>'tenant_id' = v_a::text;
end $$;
set local role authenticated;
set local request.jwt.claims =
  '{"sub":"10000000-0000-0000-0000-000000000001","role":"authenticated"}';
do $$
begin
  if refresh_match(current_setting('probe.lg_9001')::uuid) <> 'not_live' then
    raise exception 'FAIL: a league match two days after its start was still refreshable';
  end if;
end $$;
reset role;

-- Another alley sees none of it and cannot refresh it (the real ids, not a
-- subselect that RLS would turn into NULL). 9001 is made refreshable first —
-- final, lines missing — and our own alley's call is the positive control.
do $$
declare
  v_a constant uuid := '00000000-0000-0000-0000-00000000000a';
begin
  update league_matches set status = 'finished', detail_status = null, detail_fetched_at = null
   where site_match_id = 9001;
  delete from notification_jobs where kind = 'federation_league_match'
     and payload->>'tenant_id' = v_a::text;
end $$;
set local role authenticated;
set local request.jwt.claims =
  '{"sub":"10000000-0000-0000-0000-000000000001","role":"authenticated"}';
do $$
begin
  if refresh_match(current_setting('probe.lg_9001')::uuid, true) <> 'queued' then
    raise exception 'FAIL: the control failed: our own alley could not refresh its league match';
  end if;
end $$;
reset role;
do $$
declare
  v_a constant uuid := '00000000-0000-0000-0000-00000000000a';
begin
  -- A request sorts before the backfill jobs (the runner takes the oldest
  -- run_at first): someone is waiting for it.
  if not exists (select 1 from notification_jobs where kind = 'federation_league_match'
                    and payload->>'tenant_id' = v_a::text and run_at = 'epoch'::timestamptz) then
    raise exception 'FAIL: a requested league refresh does not sort before the backfill jobs';
  end if;
  delete from notification_jobs where kind = 'federation_league_match'
     and payload->>'tenant_id' = v_a::text;
end $$;
set local role authenticated;
set local request.jwt.claims =
  '{"sub":"10000000-0000-0000-0000-000000000002","role":"authenticated"}';
do $$
begin
  if exists (select 1 from league_matches) or exists (select 1 from league_player_results) then
    raise exception 'FAIL: another alley sees our league matches';
  end if;
  if refresh_match(current_setting('probe.lg_9001')::uuid, true) <> 'not_live'
     or refresh_match(current_setting('probe.lg_9002')::uuid, true) <> 'not_live' then
    raise exception 'FAIL: another alley refreshed our league match';
  end if;
end $$;
reset role;
do $$
declare
  v_a constant uuid := '00000000-0000-0000-0000-00000000000a';
begin
  if exists (select 1 from notification_jobs where kind = 'federation_league_match'
              and payload->>'tenant_id' = v_a::text) then
    raise exception 'FAIL: another alley''s refresh queued our league fetch';
  end if;
  if has_table_privilege('authenticated', 'league_matches', 'insert')
     or has_table_privilege('anon', 'league_matches', 'select')
     or not has_table_privilege('authenticated', 'league_player_results', 'select')
     or has_function_privilege('authenticated', 'public.apply_league_matches(uuid, text, jsonb)', 'execute')
     or has_function_privilege('authenticated', 'public.apply_league_result(uuid, integer, jsonb)', 'execute')
     or has_function_privilege('authenticated', 'public.league_drop_orphan_jobs(uuid)', 'execute')
     or not has_function_privilege('service_role', 'public.apply_league_result(uuid, integer, jsonb)', 'execute') then
    raise exception 'FAIL: league privileges are wrong';
  end if;

  -- A stale competition job after the team was switched off: nothing is kept
  -- (no rows, no detail jobs), and the detail is refused.
  update teams set active = false where tenant_id = v_a and site_slug = 'liga-tym-0055-muzi';
  if apply_league_result(v_a, 9001, '{"status":"finished"}'::jsonb) then
    raise exception 'FAIL: a competition none of our teams plays was still written';
  end if;
  perform apply_league_matches(v_a, 'liga-x-2026', '[{"site_match_id":9010,"site_slug":"liga-x-2026-kolo-1-a-b","date":"2026-10-10","starts_at":"10:00","home_team":"A","away_team":"B","competition":"Liga X","round":1,"status":"finished","home":{},"away":{}}]');
  if exists (select 1 from league_matches where tenant_id = v_a)
     or exists (select 1 from notification_jobs where kind = 'federation_league_match'
                 and payload->>'tenant_id' = v_a::text) then
    raise exception 'FAIL: a competition nobody plays kept league matches or their jobs';
  end if;

  -- The nightly cleanup: a live competition keeps its matches and jobs; the
  -- matches of a dead one go with their lines and their detail jobs.
  update teams set active = true where tenant_id = v_a and site_slug = 'liga-tym-0055-muzi';
  perform apply_league_matches(v_a, 'liga-x-2026', '[{"site_match_id":9001,"site_slug":"liga-x-2026-kolo-3-a-b","date":"2026-10-10","starts_at":"10:00","home_team":"KK A","away_team":"KK B","competition":"Liga X","round":3,"status":"finished","home":{},"away":{}}]');
  perform apply_league_result(v_a, 9001, '{"status":"finished","players":[{"side":"home","position":1,"player_name":"X"}]}');
  perform enqueue_federation_jobs();
  if not exists (select 1 from league_matches where tenant_id = v_a and site_match_id = 9001)
     or not exists (select 1 from league_player_results where tenant_id = v_a)
     or not exists (select 1 from notification_jobs where kind = 'federation_league_match'
                     and payload->>'tenant_id' = v_a::text) then
    raise exception 'FAIL: the nightly cleanup dropped the matches, lines or jobs of a live competition';
  end if;
  update teams set active = false where tenant_id = v_a and site_slug in ('liga-tym-0055-muzi');
  perform enqueue_federation_jobs();
  if exists (select 1 from league_matches where tenant_id = v_a)
     or exists (select 1 from league_player_results where tenant_id = v_a)
     or exists (select 1 from notification_jobs where kind = 'federation_league_match'
                 and payload->>'tenant_id' = v_a::text) then
    raise exception 'FAIL: the nightly cleanup left league matches, lines or jobs of a dead competition';
  end if;
  raise notice 'OK: league matches — RLS, refresh_match on a league id (windows, gates, the job write, other alleys), privileges, dead competitions and orphan jobs (0055)';
end $$;

-- 22. Registration numbers (0057): the lookup cache is the function's alone,
-- a number is not the app's to write, and a malformed one is refused.
reset role;
do $$
declare
  v_a constant uuid := '00000000-0000-0000-0000-00000000000a';
  v_id uuid;
begin
  if has_table_privilege('authenticated', 'public.site_player_regnums', 'select')
     or has_table_privilege('anon', 'public.site_player_regnums', 'select')
     or has_table_privilege('authenticated', 'public.site_player_regnums', 'insert') then
    raise exception 'FAIL: the app can reach site_player_regnums';
  end if;
  if not has_table_privilege('service_role', 'public.site_player_regnums', 'insert') then
    raise exception 'FAIL: the function cannot write site_player_regnums';
  end if;
  begin
    insert into site_player_regnums (slug, regnum, status) values ('../x', '1', 'found');
    raise exception 'FAIL: a slug that is no slug went into site_player_regnums';
  exception when check_violation then null;
  end;
  begin
    insert into site_player_regnums (slug, regnum, status) values ('jan-novak', null, 'found');
    raise exception 'FAIL: a found row without a number went into site_player_regnums';
  exception when check_violation then null;
  end;
  insert into site_player_regnums (slug, regnum, status) values ('jan-novak', '5', 'found');
  if has_column_privilege('authenticated', 'public.profiles', 'regnum', 'update')
     or has_column_privilege('anon', 'public.profiles', 'regnum', 'update')
     or has_column_privilege('authenticated', 'public.profiles', 'regnum_checked_at', 'update') then
    raise exception 'FAIL: the app can write profiles.regnum or regnum_checked_at';
  end if;
  if pg_get_function_result('public.contacts()'::regprocedure) not like '%regnum text%' then
    raise exception 'FAIL: contacts() does not return regnum';
  end if;

  select id into v_id from profiles where tenant_id = v_a limit 1;
  update profiles set regnum = '787' where id = v_id;
  -- One number, one player of the alley (0059).
  begin
    update profiles set regnum = '787'
     where id = (select id from profiles where tenant_id = (select tenant_id from profiles where id = v_id)
                   and id <> v_id limit 1);
    raise exception 'FAIL: two players of one alley got the same registration number';
  exception when unique_violation then null;
  end;
  begin
    update profiles set regnum = 'abc' where id = v_id;
    raise exception 'FAIL: a malformed profiles.regnum was accepted';
  exception when check_violation then null;
  end;
  raise notice 'OK: registration numbers — the match-player cache is service-role only, profiles.regnum / regnum_checked_at are not the app''s to write, regnum is checked and unique per alley (0057, 0059)';
end $$;

-- 24. „Hlídat uvolněná místa“ (0058): who hears about a freed spot, and who
-- does not. An alley of its own, W; a block 17:00–18:00, a cap of two.
reset role;
do $$
declare
  w constant uuid := '00000000-0000-0000-0000-0000000000f1';
  u1 constant uuid := '71000000-0000-0000-0000-000000000001'; -- cancels
  u2 constant uuid := '71000000-0000-0000-0000-000000000002'; -- watcher
  u3 constant uuid := '71000000-0000-0000-0000-000000000003'; -- watcher at the cap
  u4 constant uuid := '71000000-0000-0000-0000-000000000004'; -- watcher, booked this block
  u5 constant uuid := '71000000-0000-0000-0000-000000000005'; -- admin watcher
  u6 constant uuid := '71000000-0000-0000-0000-000000000006'; -- watcher, other day
  u7 constant uuid := '71000000-0000-0000-0000-000000000007'; -- pending watcher
  u8 constant uuid := '71000000-0000-0000-0000-000000000008'; -- watches the 18:00 block only
  u9 constant uuid := '71000000-0000-0000-0000-000000000009'; -- watches the 17:00 block only
  v_today date := (now() at time zone 'Europe/Prague')::date;
  v_blk uuid;
  v_blk2 uuid;
  v_weekdays smallint[];
  d date;
  v_res uuid;
  v_ids uuid[];
  v_pruned integer;
begin
  insert into tenants (id, name) values (w, 'Kuželna W (0058)');
  update schedule_settings set lane_count = 4, max_active_reservations = 2,
         booking_horizon_days = 30, training_weekdays = '{1,2,4}'
   where tenant_id = w;
  insert into time_blocks (tenant_id, starts_at, ends_at, position)
  values (w, '17:00', '18:00', 0) returning id into v_blk;
  insert into time_blocks (tenant_id, starts_at, ends_at, position)
  values (w, '18:00', '19:00', 1) returning id into v_blk2;
  select training_weekdays into v_weekdays from schedule_settings where tenant_id = w;
  d := v_today + 2;
  while not (extract(isodow from d)::smallint = any (v_weekdays)) loop
    d := d + 1;
  end loop;

  insert into auth.users (id, email) values
    (u1, 'w1@example.com'), (u2, 'w2@example.com'), (u3, 'w3@example.com'),
    (u4, 'w4@example.com'), (u5, 'w5@example.com'), (u6, 'w6@example.com'),
    (u7, 'w7@example.com'), (u8, 'w8@example.com'), (u9, 'w9@example.com')
  on conflict do nothing;
  insert into profiles (id, tenant_id, display_name, email, role, status) values
    (u1, w, 'W1', 'w1@example.com', 'player', 'approved'),
    (u2, w, 'W2', 'w2@example.com', 'player', 'approved'),
    (u3, w, 'W3', 'w3@example.com', 'player', 'approved'),
    (u4, w, 'W4', 'w4@example.com', 'player', 'approved'),
    (u5, w, 'W5', 'w5@example.com', 'admin', 'approved'),
    (u6, w, 'W6', 'w6@example.com', 'player', 'approved'),
    (u7, w, 'W7', 'w7@example.com', 'player', 'pending'),
    (u8, w, 'W8', 'w8@example.com', 'player', 'approved'),
    (u9, w, 'W9', 'w9@example.com', 'player', 'approved');

  -- u1 holds lane 1, u4 holds lane 3 of the same block; u3 is at the cap on
  -- two other days.
  insert into reservations (tenant_id, player_id, date, block_id, lane, created_via, created_by)
  values (w, u1, d, v_blk, 1, 'app', u1),
         (w, u4, d, v_blk, 3, 'app', u4),
         (w, u3, d + 7, v_blk, 1, 'app', u3),
         (w, u3, d + 14, v_blk, 1, 'app', u3);
  insert into slot_watches (user_id, tenant_id, date, block_ids) values
    (u1, w, d, null), (u2, w, d, null), (u3, w, d, null), (u4, w, d, null), (u5, w, d, null),
    (u6, w, d + 1, null), (u7, w, d, null), (u8, w, d, array[v_blk2]), (u9, w, d, array[v_blk]);

  -- u1 cancels lane 1: only u2 (can book it), u5 (admin, no cap) and u9 (watches
  -- exactly this block) hear; u8 watches the other block.
  update reservations set cancelled_at = now(), cancelled_via = 'app', cancelled_by = u1
   where player_id = u1 and date = d returning id into v_res;
  select array_agg(c.user_id order by c.user_id) into v_ids from claim_freed_spot_watchers(v_res) c;
  if v_ids is distinct from array[u2, u5, u9] then
    raise exception 'FAIL: freed-spot watchers were % (expected u2, u5, u9)', v_ids;
  end if;
  -- The throttle: the same watchers are not claimed again within ten minutes.
  if exists (select 1 from claim_freed_spot_watchers(v_res)) then
    raise exception 'FAIL: a watcher was claimed twice inside the throttle window';
  end if;
  -- Ten minutes later they are again.
  update slot_watches set last_notified_at = now() - interval '11 minutes' where date = d;
  select array_agg(c.user_id order by c.user_id) into v_ids from claim_freed_spot_watchers(v_res) c;
  if v_ids is distinct from array[u2, u5, u9] then
    raise exception 'FAIL: the throttle did not lift after ten minutes (%)', v_ids;
  end if;

  -- Booked by somebody else already: nothing is free.
  update slot_watches set last_notified_at = null;
  insert into reservations (tenant_id, player_id, date, block_id, lane, created_via, created_by)
  values (w, u6, d, v_blk, 1, 'app', u6);
  if exists (select 1 from claim_freed_spot_watchers(v_res)) then
    raise exception 'FAIL: a retaken lane told the watchers it was free';
  end if;
  delete from reservations where player_id = u6 and date = d;
  delete from slot_watches where user_id = u6 and date = d;   -- u6's own booking ended it

  -- A still-live reservation claims nothing.
  if exists (select 1 from claim_freed_spot_watchers(
       (select id from reservations where player_id = u4 and date = d))) then
    raise exception 'FAIL: a live reservation counted as a freed spot';
  end if;

  -- A closed day frees nothing (closing it cancels the day's reservations).
  insert into day_overrides (tenant_id, date, closed, reason, created_by) values (w, d, true, 'test', u5);
  update slot_watches set last_notified_at = null;
  if exists (select 1 from claim_freed_spot_watchers(v_res)) then
    raise exception 'FAIL: a closed day told the watchers a spot was free';
  end if;
  delete from day_overrides where tenant_id = w and date = d;

  -- Booking ends the day's watch (u2 books lane 2).
  insert into reservations (tenant_id, player_id, date, block_id, lane, created_via, created_by)
  values (w, u2, d, v_blk, 2, 'app', u2);
  if exists (select 1 from slot_watches where user_id = u2 and date = d) then
    raise exception 'FAIL: a booking left the watch of its day on';
  end if;
  if not exists (select 1 from slot_watches where user_id = u5 and date = d) then
    raise exception 'FAIL: one player''s booking ended another''s watch';
  end if;

  -- A watch of one block ends only with a booking in that block.
  insert into reservations (tenant_id, player_id, date, block_id, lane, created_via, created_by)
  values (w, u9, d, v_blk2, 1, 'app', u9);
  if not exists (select 1 from slot_watches where user_id = u9 and date = d) then
    raise exception 'FAIL: booking another block ended a one-block watch';
  end if;
  insert into reservations (tenant_id, player_id, date, block_id, lane, created_via, created_by)
  values (w, u9, d, v_blk, 4, 'app', u9);
  if exists (select 1 from slot_watches where user_id = u9 and date = d) then
    raise exception 'FAIL: booking the watched block left its watch on';
  end if;

  -- The app's side: watch_day / unwatch_day and the own-row read.
  perform set_config('request.jwt.claims',
    '{"sub":"71000000-0000-0000-0000-000000000006","role":"authenticated"}', true);
  set local role authenticated;
  perform watch_day(d + 2);
  perform watch_day(d + 2);   -- idempotent
  perform watch_day(d + 2, array[v_blk]);   -- a pick replaces the whole-day watch
  if (select block_ids from slot_watches where user_id = u6 and date = d + 2) is distinct from array[v_blk] then
    raise exception 'FAIL: watch_day did not store the picked blocks';
  end if;
  perform watch_day(d + 2, '{}');   -- an empty pick is the whole day again
  if (select block_ids from slot_watches where user_id = u6 and date = d + 2) is not null then
    raise exception 'FAIL: an empty pick did not mean the whole day';
  end if;
  if (select count(*) from slot_watches) <> 2 then   -- d + 1 and d + 2, nobody else's
    raise exception 'FAIL: a player reads % watch rows (expected their own 2)',
      (select count(*) from slot_watches);
  end if;
  begin
    perform watch_day(v_today - 1);
    raise exception 'FAIL: a watch on a past day was accepted';
  exception when others then
    if sqlerrm <> 'date_past' then raise; end if;
  end;
  begin
    perform watch_day(v_today + 31);
    raise exception 'FAIL: a watch beyond the horizon was accepted';
  exception when others then
    if sqlerrm <> 'beyond_horizon' then raise; end if;
  end;
  begin
    perform watch_day(d + 2, array[gen_random_uuid()]);
    raise exception 'FAIL: a watch of an unknown block was accepted';
  exception when others then
    if sqlerrm <> 'unknown_block' then raise; end if;
  end;
  begin
    insert into slot_watches (user_id, tenant_id, date) values (u6, w, d + 3);
    raise exception 'FAIL: a player wrote slot_watches directly';
  exception when insufficient_privilege then null;
  end;
  begin
    perform claim_freed_spot_watchers(v_res);
    raise exception 'FAIL: a player called claim_freed_spot_watchers';
  exception when insufficient_privilege then null;
  end;
  perform unwatch_day(d + 2);
  if exists (select 1 from slot_watches where date = d + 2) then
    raise exception 'FAIL: unwatch_day left the watch';
  end if;
  -- A pending account cannot watch.
  perform set_config('request.jwt.claims',
    '{"sub":"71000000-0000-0000-0000-000000000007","role":"authenticated"}', true);
  begin
    perform watch_day(d);
    raise exception 'FAIL: a pending player watched a day';
  exception when others then
    if sqlerrm <> 'not_allowed' then raise; end if;
  end;
  reset role;

  -- The nightly prune drops the days that are over and keeps the rest.
  insert into slot_watches (user_id, tenant_id, date) values (u2, w, v_today - 3);
  v_pruned := prune_slot_watches();
  if v_pruned < 1 or exists (select 1 from slot_watches where date < v_today) then
    raise exception 'FAIL: prune_slot_watches kept a past day';
  end if;
  raise notice 'OK: slot watches — who hears about a freed spot (cap, own booking, closed day, retaken lane, throttle), the end on booking, the RPCs, privileges and the prune (0058)';
end $$;

-- 25. An admin edits a player's name (0060): only an admin, only his own
-- alley, trimmed and never empty; a renamed player is looked for in the
-- register again.
reset role;
do $$
declare
  c constant uuid := '10000000-0000-0000-0000-000000000003';  -- A, pending
  v_name text;
  v_checked timestamptz;
begin
  update profiles set regnum_checked_at = now() where id = c;
  set local role authenticated;
  perform set_config('request.jwt.claims',
    '{"sub":"10000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
  perform set_display_name(c, '   Čeněk   Nový ');
  reset role;
  select display_name, regnum_checked_at into v_name, v_checked from profiles where id = c;
  if v_name <> 'Čeněk Nový' then
    raise exception 'FAIL: the name was stored as "%"', v_name;
  end if;
  if v_checked is not null then
    raise exception 'FAIL: a rename left the registration lookup state as it was';
  end if;

  -- The same name again keeps the lookup state.
  update profiles set regnum_checked_at = now() where id = c;
  set local role authenticated;
  perform set_config('request.jwt.claims',
    '{"sub":"10000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
  perform set_display_name(c, 'Čeněk Nový');
  reset role;
  if (select regnum_checked_at from profiles where id = c) is null then
    raise exception 'FAIL: saving the same name re-armed the registration lookup';
  end if;

  set local role authenticated;
  perform set_config('request.jwt.claims',
    '{"sub":"10000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
  begin
    perform set_display_name(c, '   ');
    raise exception 'FAIL: an empty name was accepted';
  exception when others then
    if sqlerrm <> 'empty_display_name' then raise; end if;
  end;
  begin
    perform set_display_name(c, repeat('x', 61));
    raise exception 'FAIL: a 61-character name was accepted';
  exception when others then
    if sqlerrm <> 'display_name_too_long' then raise; end if;
  end;
  -- Another alley's player is nobody of this admin's.
  begin
    perform set_display_name('10000000-0000-0000-0000-000000000002', 'Cizí');
    raise exception 'FAIL: an admin renamed a player of another alley';
  exception when others then
    if sqlerrm <> 'unknown_player' then raise; end if;
  end;
  -- Not an admin: the other alley's admin cannot rename this alley's player,
  -- and a plain account cannot rename anybody.
  perform set_config('request.jwt.claims',
    '{"sub":"10000000-0000-0000-0000-000000000003","role":"authenticated"}', true);
  begin
    perform set_display_name(c, 'Já sám');
    raise exception 'FAIL: a non-admin renamed a player';
  exception when others then
    if sqlerrm <> 'not_allowed' then raise; end if;
  end;
  reset role;
  if has_function_privilege('anon', 'public.set_display_name(uuid, text)', 'execute') then
    raise exception 'FAIL: anon can call set_display_name';
  end if;
  raise notice 'OK: set_display_name — admin only, own alley only, trimmed, never empty, a rename re-arms the registration lookup (0060)';
end $$;

-- 26. An admin sets a player's registration number by hand (0061): admin
-- only, own alley only, digits only, unique per alley; empty clears it.
reset role;
do $$
declare
  c constant uuid := '10000000-0000-0000-0000-000000000003';  -- A, pending
  a constant uuid := '10000000-0000-0000-0000-000000000001';  -- A, admin
begin
  update profiles set regnum = null, regnum_checked_at = null where id in (a, c);
  set local role authenticated;
  perform set_config('request.jwt.claims',
    '{"sub":"10000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
  perform set_regnum(c, ' 12345 ');
  reset role;
  if (select regnum from profiles where id = c) is distinct from '12345' then
    raise exception 'FAIL: the number was not stored';
  end if;
  if (select regnum_checked_at from profiles where id = c) is null then
    raise exception 'FAIL: a typed number is not marked settled';
  end if;

  set local role authenticated;
  perform set_config('request.jwt.claims',
    '{"sub":"10000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
  begin
    perform set_regnum(a, '12345');
    raise exception 'FAIL: a number of another player was accepted';
  exception when others then
    if sqlerrm <> 'regnum_taken' then raise; end if;
  end;
  begin
    perform set_regnum(c, '12a');
    raise exception 'FAIL: a number with a letter was accepted';
  exception when others then
    if sqlerrm <> 'invalid_regnum' then raise; end if;
  end;
  begin
    perform set_regnum('10000000-0000-0000-0000-000000000002', '777');
    raise exception 'FAIL: an admin set a number of another alley''s player';
  exception when others then
    if sqlerrm <> 'unknown_player' then raise; end if;
  end;
  perform set_config('request.jwt.claims',
    '{"sub":"10000000-0000-0000-0000-000000000003","role":"authenticated"}', true);
  begin
    perform set_regnum(c, '999');
    raise exception 'FAIL: a non-admin set a number';
  exception when others then
    if sqlerrm <> 'not_allowed' then raise; end if;
  end;
  perform set_config('request.jwt.claims',
    '{"sub":"10000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
  perform set_regnum(c, '  ');
  reset role;
  if (select regnum from profiles where id = c) is not null
     or (select regnum_checked_at from profiles where id = c) is not null then
    raise exception 'FAIL: an empty value did not clear the number';
  end if;
  if has_function_privilege('anon', 'public.set_regnum(uuid, text)', 'execute') then
    raise exception 'FAIL: anon can call set_regnum';
  end if;
  raise notice 'OK: set_regnum — admin only, own alley only, digits only, unique, empty clears (0061)';
end $$;


-- 0063: a new kuželna starts with no training day.
reset role;
do $$
declare
  v_t uuid;
begin
  insert into tenants (name) values ('Nová kuželna 0063') returning id into v_t;
  if (select training_weekdays from schedule_settings where tenant_id = v_t) <> '{}'::smallint[] then
    raise exception 'FAIL: a new kuželna started with training days %',
      (select training_weekdays from schedule_settings where tenant_id = v_t);
  end if;
  raise notice 'OK: a new kuželna starts with no training day (0063)';
end $$;

-- 0065: a notice is hidden from, or shown on, the kiosk by its alley's admin
-- only; the kiosk still READS it (the app does the hiding, see the
-- migration), and the public overview hands out none of the new settings.
reset role;
do $$
declare
  v_id uuid;
begin
  insert into messages (tenant_id, author_role, kind, audience, title, body)
    values ('00000000-0000-0000-0000-000000000051', 'admin', 'notice', 'all', 'Pro kiosek', 'Text.')
    returning id into v_id;
  perform set_config('probe.kiosk_notice', v_id::text, true);
end $$;
set local role authenticated;
do $$
declare
  v_notice constant uuid := current_setting('probe.kiosk_notice')::uuid;
  v_who text;
begin
  perform set_config('request.jwt.claims',
    '{"sub":"51000000-0000-0000-0000-000000000010","role":"authenticated"}', true);
  perform message_set_kiosk(v_notice, false);
  if (select show_on_kiosk from messages where id = v_notice) then
    raise exception 'FAIL: the admin could not hide the notice from the kiosk';
  end if;

  perform set_config('request.jwt.claims',
    '{"sub":"51000000-0000-0000-0000-000000000015","role":"authenticated"}', true);
  if (select show_on_kiosk from messages where id = v_notice) is distinct from false then
    raise exception 'FAIL: the kiosk cannot read the notice and its flag';
  end if;

  for v_who in select unnest(array[
      '51000000-0000-0000-0000-000000000015',   -- the kiosk
      '51000000-0000-0000-0000-000000000013',   -- a player
      '51000000-0000-0000-0000-000000000016'])  -- a pending account
  loop
    perform set_config('request.jwt.claims',
      '{"sub":"' || v_who || '","role":"authenticated"}', true);
    begin
      perform message_set_kiosk(v_notice, true);
      raise exception 'FAIL: % toggled a notice on the kiosk', v_who;
    exception when others then
      if sqlerrm <> 'not_allowed' then raise; end if;
    end;
  end loop;

  perform set_config('request.jwt.claims',
    '{"sub":"52000000-0000-0000-0000-000000000010","role":"authenticated"}', true);
  begin
    perform message_set_kiosk(v_notice, true);
    raise exception 'FAIL: another alley''s admin toggled the notice';
  exception when others then
    if sqlerrm <> 'unknown_message' then raise; end if;
  end;

  perform set_config('request.jwt.claims',
    '{"sub":"51000000-0000-0000-0000-000000000010","role":"authenticated"}', true);
  perform message_set_kiosk(v_notice, true);
  if not (select show_on_kiosk from messages where id = v_notice) then
    raise exception 'FAIL: the admin could not show the notice again';
  end if;
  raise notice 'OK: only the alley''s admin hides or shows a notice on the kiosk (0065)';
end $$;
reset role;
do $$
begin
  if has_function_privilege('anon', 'public.message_set_kiosk(uuid, boolean)', 'execute') then
    raise exception 'FAIL: anon can call message_set_kiosk';
  end if;
  if exists (select 1 from jsonb_object_keys(public_week('kuzelna-a', current_date)->'settings') k
              where k like 'kiosk\_%' and k not in ('kiosk_dark', 'kiosk_fit_day')) then
    raise exception 'FAIL: the public overview hands out a kiosk panel setting';
  end if;
  raise notice 'OK: anon cannot toggle, and the public overview hides the kiosk panel settings (0065)';
end $$;

rollback;
