-- Tenancy isolation smoke-tests. Run against a LOCAL stack (supabase start
-- + supabase db reset) or inside BEGIN…ROLLBACK on prod:
--   psql postgresql://postgres:postgres@127.0.0.1:54322/postgres \
--     -v ON_ERROR_STOP=1 -f supabase/tests/tenancy_rls.sql
-- CI runs it in the `backend` job. Simulates two tenants and a superadmin
-- and asserts zero cross-tenant visibility, the schedule/rental cascades,
-- the 0022 placeholder (hráč bez účtu) lifecycle and the 0023 Google
-- Calendar plumbing (nonces, server-only tables, job producers, cron).
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
        '00000000-0000-0000-0000-000000000001', 'Kiosk A', 'k@example.com',
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
          'public.set_calendar_reminders_for(uuid, int[])', 'execute')
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
          'public.set_calendar_reminders_for(uuid, int[])', 'execute')
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
  if (select count(*) from notification_jobs) <> 1 then
    raise exception 'FAIL: expected exactly one calendar job, found %',
      (select count(*) from notification_jobs);
  end if;
  select * into v_job from notification_jobs;
  if v_job.kind <> 'calendar_sync'
     or v_job.dedupe_key <> 'calendar:' || v_uid || ':' || v_res
     or v_job.payload->>'user_id' <> v_uid::text
     or v_job.payload->>'reservation_id' <> v_res::text
     or v_job.attempts <> 0
     or v_job.run_at <> now() + interval '3 minutes' then
    raise exception 'FAIL: calendar job has the wrong shape: %', to_jsonb(v_job);
  end if;
  -- age it so the cancel below provably re-arms it
  update notification_jobs set run_at = now() - interval '1 hour';
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
  if (select count(*) from notification_jobs) <> 1 then
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
  if (select count(*) from notification_jobs) <> 1
     or not exists (select 1 from notification_jobs
                    where dedupe_key = 'calendar:' || v_uid || ':' || v_res2
                      and payload->>'reservation_id' = v_res2::text) then
    raise exception 'FAIL: re-timed block did not enqueue exactly the live linked reservation';
  end if;
  delete from notification_jobs;
  update time_blocks set starts_at = starts_at, ends_at = ends_at
  where id = v_blk;
  if exists (select 1 from notification_jobs) then
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
     or v_row.lane <> 3 or v_row.alley_name <> 'Kuželna č. 1' then
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
  raise notice 'OK: own_color is editable on the own row only, inside the palette';
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

reset role;
rollback;
