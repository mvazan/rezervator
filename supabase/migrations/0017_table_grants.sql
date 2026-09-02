-- 0017 — table privileges as code.
--
-- Hosted Supabase hands app roles their table privileges through
-- `alter default privileges for role postgres` (ALL on every new table to
-- anon / authenticated / service_role). The local stack does not, and no
-- migration ever spelled a DML grant out — a database built from git alone
-- had NO select/insert/update/delete for the app and
-- supabase/tests/tenancy_rls.sql died on 'permission denied for table
-- time_blocks'. RLS stays the real gate; this file just makes the plain
-- privileges explicit and pins the defaults so future tables match on every
-- backend.
--
-- Two deliberate tightenings against prod's inherited defaults:
--   * anon gets nothing on app tables (no policy ever yielded anon a row),
--   * the players view is read-only for authenticated.

-- App tables: full DML for signed-in users; policies decide the rows.
grant select, insert, update, delete on
  clubs, day_overrides, priority_slots, rentals, reservations,
  schedule_settings, time_blocks
  to authenticated;

-- profiles: whole-row update stays revoked (0001 keeps the column grants
-- display_name / club / fcm_token — re-granting them is a no-op).
grant select, insert, delete on profiles to authenticated;

-- priority_slot_types: is_match / builtin stay server-only (0004 column
-- grants cover name / color / lanes).
grant select, delete on priority_slot_types to authenticated;

-- players view: SELECT only (0001) — drop whatever a default grant added.
revoke insert, update, delete, truncate, references, trigger, maintain
  on players from authenticated;

-- Edge functions run as service_role and keep everything.
grant all on all tables in schema public to service_role;

-- anon: no app table at all.
revoke all on all tables in schema public from anon;

-- Future tables get the same shape on hosted and local backends.
alter default privileges for role postgres in schema public
  grant select, insert, update, delete on tables to authenticated;
alter default privileges for role postgres in schema public
  grant all on tables to service_role;
alter default privileges for role postgres in schema public
  revoke all on tables from anon;

-- Functions: same story. Postgres grants EXECUTE to PUBLIC on every new
-- function, so most RPCs worked everywhere — but the superadmin RPCs (0014)
-- and the two service-only helpers revoke PUBLIC and relied on the hosted
-- default grant for the app roles (locally: 'permission denied for function
-- switch_tenant').
grant execute on function
  admin_list_tenants(), approve_tenant(uuid), reject_tenant(uuid),
  switch_tenant(uuid)
  to authenticated, service_role;
grant execute on function notify_webhook_config(), seed_demo_member(text)
  to service_role;
alter default privileges for role postgres in schema public
  grant execute on functions to anon, authenticated, service_role;
