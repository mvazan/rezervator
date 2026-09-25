-- 0046 — no table is granted by default any more: a migration that creates
-- a table grants it explicitly.
--
-- Supabase stops granting new public tables to anon / authenticated /
-- service_role on 2026-10-30 for existing projects
-- (github.com/orgs/supabase/discussions/45329). Tables that already exist
-- keep their grants. The announcement does not say how existing projects
-- are switched: if the platform rewrites the postgres/public default ACL,
-- it drops what 0017/0020 pinned for authenticated and service_role — on
-- prod only, while a database built from git keeps them. The next new table
-- would pass CI and die in production with 'permission denied', for the app
-- and for the edge functions alike (service_role skips RLS, not grants).
-- Taking the new behaviour now, as code, keeps local, CI and prod equal
-- whatever the platform does.
--
-- From here on, next to every `create table`:
--   grant select, insert, update, delete on <t> to authenticated; -- or less
--   grant all on <t> to service_role;                             -- edge fns
-- and nothing for anon (0017). A `drop … create` of a view now comes back
-- with no grants at all and must re-grant. A serial / standalone sequence
-- needs its own `grant usage` for a role that inserts; an identity column
-- does not.
--
-- Functions are untouched: 0017's EXECUTE defaults stay (Postgres grants
-- EXECUTE to PUBLIC anyway, and every internal helper revokes it itself).

alter default privileges for role postgres in schema public
  revoke all on tables from anon, authenticated, service_role;
alter default privileges for role postgres in schema public
  revoke all on sequences from anon, authenticated, service_role;
