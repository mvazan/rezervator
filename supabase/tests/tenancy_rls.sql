-- Tenancy isolation smoke-tests. Run against a LOCAL stack (supabase start)
-- or inside BEGIN…ROLLBACK on prod. Simulates two users in two tenants and
-- asserts zero cross-tenant visibility. Assumes migrations 0001–0005.
begin;

-- Fixtures: second tenant + one profile in each (auth.users stubs).
insert into tenants (id, name) values
  ('00000000-0000-0000-0000-000000000002', 'Kuželna B');

insert into auth.users (id, email) values
  ('10000000-0000-0000-0000-000000000001', 'a@example.com'),
  ('10000000-0000-0000-0000-000000000002', 'b@example.com'),
  ('10000000-0000-0000-0000-000000000003', 'c@example.com')
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
   'player', 'pending');

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

reset role;
rollback;
