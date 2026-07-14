-- 0012 — Google Play review demo: a self-contained "Demo" tenant with an
-- open schedule the review team can log into (via the demo bypass in the
-- app: config.dart / login_screen.dart) and actually use.
--
-- This migration seeds only DATA (tenant, settings, training blocks). The
-- demo AUTH USER (playreview@vvrky.cz) is created once in the Supabase
-- dashboard with the password that also lives in the DEMO_PASSWORD secret —
-- SQL can't mint an auth user with a hashed password portably. After creating
-- it, run `select seed_demo_member('playreview@vvrky.cz');` (defined below) to
-- attach an approved admin profile to the Demo tenant. See PLAY.md.

-- ---------------------------------------------------------------------------
-- 1) The Demo tenant. Inserting it fires seed_tenant_defaults (settings row +
--    builtin priority types). Fixed id so re-runs are idempotent.
-- ---------------------------------------------------------------------------
insert into tenants (id, name, founder_email)
values ('00000000-0000-0000-0000-0000000000de', 'Demo', 'playreview@vvrky.cz')
on conflict (id) do nothing;

-- Open every weekday and give it 4 lanes, so a reviewer sees a bookable
-- schedule whatever day the review lands on.
update schedule_settings
set training_weekdays = '{1,2,3,4,5,6,7}',
    lane_count = 4,
    booking_horizon_days = 14,
    max_active_reservations = 3
where tenant_id = '00000000-0000-0000-0000-0000000000de';

-- A handful of training blocks (only if none exist yet for the tenant).
insert into time_blocks (tenant_id, starts_at, ends_at, position, active)
select '00000000-0000-0000-0000-0000000000de', s, e, p, true
from (values
  (time '15:30', time '16:30', 0),
  (time '16:30', time '17:30', 1),
  (time '17:30', time '18:30', 2),
  (time '18:30', time '19:30', 3)
) as blk(s, e, p)
where not exists (
  select 1 from time_blocks
  where tenant_id = '00000000-0000-0000-0000-0000000000de'
);

-- ---------------------------------------------------------------------------
-- 2) Attach the demo auth user to the Demo tenant as an approved admin.
--    Run once after creating the dashboard user. Idempotent. NOT granted to
--    application roles — only the SQL editor (postgres) may call it.
-- ---------------------------------------------------------------------------
create or replace function seed_demo_member(p_email text)
returns void
language plpgsql security definer set search_path = public
as $$
declare
  v_uid uuid;
begin
  select id into v_uid from auth.users where lower(email) = lower(p_email);
  if v_uid is null then
    raise exception 'No auth user for %. Create it in the dashboard first.', p_email;
  end if;
  insert into profiles (id, tenant_id, display_name, email, role, status)
  values (v_uid, '00000000-0000-0000-0000-0000000000de',
          'Recenze', p_email, 'admin', 'approved')
  on conflict (id) do update
    set tenant_id = excluded.tenant_id,
        role = 'admin',
        status = 'approved';
end;
$$;

revoke all on function seed_demo_member(text) from public, anon, authenticated;
