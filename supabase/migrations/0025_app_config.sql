-- 0025 — app_config.min_build: the force-update lever for breaking releases.
--
-- Until now an old build kept running against a newer backend for as long
-- as the player did not update — silently misreading new rows (0022
-- placeholders, 0024 colours) and, once an RPC changed shape, raising
-- errors into Sentry. The single-row app_config carries the minimum build
-- the backend still supports; the app streams it over Realtime (so a bump
-- reaches a RUNNING app within seconds, not on the next cold start),
-- re-reads it on resume and every five minutes, and blocks on an update
-- screen while its build number is older. A release that needs the new
-- backend raises it with a migration: update app_config set min_build = N;
-- N = the number after '+' in pubspec.yaml.

create table app_config (
  id boolean primary key default true check (id),
  min_build int not null default 1 check (min_build >= 1),
  updated_at timestamptz not null default now()
);

comment on table app_config is
  'Single row. min_build = the oldest app build the backend still supports; older builds block on the update screen.';

insert into app_config (min_build) values (1);

alter table app_config enable row level security;
-- Every signed-in client may read it (the gate checks after sign-in);
-- writes are migrations / the SQL editor only.
create policy app_config_select on app_config for select using (true);
revoke all on app_config from anon, authenticated;
grant select on app_config to authenticated;
grant all on app_config to service_role;

alter publication supabase_realtime add table app_config;
