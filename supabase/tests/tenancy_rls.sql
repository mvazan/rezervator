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
    'match_exceptions', 'player_group_members'
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
  perform mark_reminder_sent(v_uid, r.event_key, r.offset_minutes)
    from due_reminders() r where r.user_id = v_uid;
  if exists (select 1 from due_reminders() where user_id = v_uid) then
    raise exception 'FAIL: a reminder rang twice';
  end if;
  raise notice 'OK: a reminder is due at its lead time, once, for the player''s own trainings and matches (0040)';
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
          'mark_reminder_sent(uuid, text, integer)', 'execute') then
    raise exception 'FAIL: the client can drive the reminder machinery';
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
  if v_keys <> array['away_team', 'competition', 'date', 'description', 'ends_at',
                      'hand_edited', 'home_team', 'id', 'import_key', 'is_away',
                      'parent_id', 'prep_minutes', 'round', 'site_match_id',
                      'site_slug', 'starts_at', 'type_id', 'venue', 'venue_slug',
                      'video_url'] then
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
create function pg_temp.fed_match(
  p_id integer, p_ours boolean, p_days integer, p_start text, p_end text,
  p_round integer, p_legacy uuid default null)
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
    'video_url', null, 'legacy_id', p_legacy)
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

-- 6. A match detail: result, players, and the venue decides home/away.
do $$
declare
  v_a constant uuid := '00000000-0000-0000-0000-00000000000a';
  v_res constant jsonb := '{"status":"finished","match_type":"TEAMS_OF_6","discipline":"T120","video_url":null,"venue":{"slug":"jinde","name":"Kuželna Jinde"},"home_prep":30,"home":{"points":6,"total":3200,"fulls":2100,"spares":1100,"errors":10,"set_points":15},"away":{"points":2,"total":3100,"fulls":2050,"spares":1050,"errors":14,"set_points":9},"players":[{"side":"home","position":1,"player_name":"Jan Novák","player_site_id":7,"player_slug":"jan-novak","fulls":350,"spares":190,"errors":1,"total":540,"set_points":3,"team_points":1,"lanes":[{"lane":1,"fulls":90,"spares":45,"errors":0,"total":135,"setPoints":1}]}]}';
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
  raise notice 'OK: apply_federation_result upserts the result, replaces players, fixes home/away from the venue; false without a slot (0045)';
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
                           'public.enqueue_federation_venue(uuid, text, interval)'] loop
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
                           'public.upsert_federation_venue(uuid, jsonb)'] loop
    if not has_function_privilege('service_role', f, 'execute') then
      raise exception 'FAIL: the service cannot call %', f;
    end if;
  end loop;
  foreach f in array array['public.set_federation_sync(text, boolean)',
                           'public.request_federation_discovery()',
                           'public.request_federation_sync()',
                           'public.update_team(uuid, text, uuid, boolean)',
                           'public.refresh_match(uuid)'] loop
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
  if s.last_success_at is null or s.last_error is not null
     or s.last_report->'discover'->>'teams' <> '3'
     or s.last_report->'discover'->>'at' is null then
    raise exception 'FAIL: a successful run was not recorded: %', to_jsonb(s);
  end if;
  perform record_federation_run(v_b, 'krajsky-prebor-2026-2027', '{"inserted":1}', null);
  update federation_sync set last_success_at = now() - interval '1 hour' where tenant_id = v_b;
  perform record_federation_run(v_b, 'discover', '{"teams":0}', 'site down');
  select * into s from federation_sync where tenant_id = v_b;
  if s.last_error <> 'site down' or s.last_success_at <> now() - interval '1 hour'
     or s.last_report->'discover'->>'error' is distinct from 'site down'
     or s.last_report->'discover'->>'at' is null
     or s.last_report->'discover' ? 'teams'
     or s.last_report->'krajsky-prebor-2026-2027'->>'inserted' <> '1' then
    raise exception 'FAIL: a failed run is not recorded under its key: %', to_jsonb(s);
  end if;
  perform record_federation_run(v_b, 'discover', '{"teams":4}', null);
  select * into s from federation_sync where tenant_id = v_b;
  if s.last_error is not null or s.last_report->'discover'->>'teams' <> '4'
     or s.last_report->'discover' ? 'error'
     or s.last_report->'krajsky-prebor-2026-2027'->>'inserted' <> '1' then
    raise exception 'FAIL: a success did not replace the key''s error or clear last_error: %', to_jsonb(s);
  end if;
  raise notice 'OK: record_federation_run keeps a report or an error per key and the last error (0045)';
end $$;

-- 13b. A failed match or venue fetch retries by itself and records no
-- success: it stays under its key and never touches last_error.
do $$
declare
  v_b constant uuid := '00000000-0000-0000-0000-000000000002';
  s federation_sync;
begin
  perform record_federation_run(v_b, 'federation_match', null, 'federation_match: HTTP 503');
  perform record_federation_run(v_b, 'venue:jinde', null, 'federation_venue: HTTP 404');
  select * into s from federation_sync where tenant_id = v_b;
  if s.last_error is not null
     or s.last_report->'federation_match'->>'error' is distinct from 'federation_match: HTTP 503'
     or s.last_report->'venue:jinde'->>'error' is distinct from 'federation_venue: HTTP 404' then
    raise exception 'FAIL: a match or venue failure should stay under its key only: %', to_jsonb(s);
  end if;
  perform record_federation_run(v_b, 'competition:kp1', null, 'federation_competition: rounds missing');
  perform record_federation_run(v_b, 'federation_match', null, 'federation_match: HTTP 503');
  select * into s from federation_sync where tenant_id = v_b;
  if s.last_error is distinct from 'federation_competition: rounds missing' then
    raise exception 'FAIL: a match failure replaced a competition''s error: %', to_jsonb(s);
  end if;
  raise notice 'OK: match and venue failures stay under their key and leave last_error alone (0045)';
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

reset role;
rollback;
