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
