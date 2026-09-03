-- Tenancy isolation smoke-tests. Run against a LOCAL stack (supabase start
-- + supabase db reset) or inside BEGIN…ROLLBACK on prod:
--   psql postgresql://postgres:postgres@127.0.0.1:54322/postgres \
--     -v ON_ERROR_STOP=1 -f supabase/tests/tenancy_rls.sql
-- CI runs it in the `backend` job. Simulates two tenants and a superadmin
-- and asserts zero cross-tenant visibility.
begin;

-- Fixtures: second tenant + one profile in each (auth.users stubs).
insert into tenants (id, name) values
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
   '00000000-0000-0000-0000-000000000001', 'Hráč A', 'a@example.com',
   'admin', 'approved'),
  ('10000000-0000-0000-0000-000000000002',
   '00000000-0000-0000-0000-000000000002', 'Hráč B', 'b@example.com',
   'admin', 'approved'),
  -- pending player in tenant A: the cross-tenant approve target
  ('10000000-0000-0000-0000-000000000003',
   '00000000-0000-0000-0000-000000000001', 'Čekající C', 'c@example.com',
   'player', 'pending'),
  -- superadmin at home in tenant A (0014/0015)
  ('10000000-0000-0000-0000-000000000004',
   '00000000-0000-0000-0000-000000000001', 'Super S', 's@example.com',
   'admin', 'approved');
update profiles set superadmin = true,
  home_tenant_id = '00000000-0000-0000-0000-000000000001'
where id = '10000000-0000-0000-0000-000000000004';

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
  perform switch_tenant('00000000-0000-0000-0000-000000000001');
  perform reject_tenant('00000000-0000-0000-0000-000000000003');
  if exists (select 1 from tenants
             where id = '00000000-0000-0000-0000-000000000003') then
    raise exception 'FAIL: reject_tenant did not delete the tenant';
  end if;
  raise notice 'OK: reject_tenant guards the visiting superadmin';
end $$;

reset role;
rollback;
