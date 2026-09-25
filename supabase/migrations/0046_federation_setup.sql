-- 0046 — průvodce nastavením ČKA (Správa → Oddíly): clubs remember the
-- venue club they are on vysledky.kuzelky.cz, and discovery links the
-- venue's clubs to ours or creates them, in one transaction. Spec:
-- docs/superpowers/specs/2026-09-25-federation-setup-wizard-design.md
-- 0045 is deployed: everything here is additive and safe to run twice.

-- ------------------------------------------------- clubs: ČKA identity
alter table clubs add column if not exists site_slug text;
alter table clubs add column if not exists site_name text;
comment on column clubs.site_slug is
  'The venue club on vysledky.kuzelky.cz (detail-klubu/<slug>) this club is linked to; null = not linked. Written by discovery only, so a rename in the app keeps the link.';
comment on column clubs.site_name is
  'The linked club''s name on vysledky.kuzelky.cz, refreshed by every discovery.';
create unique index if not exists clubs_tenant_site_slug_key
  on clubs (tenant_id, site_slug) where site_slug is not null;

-- ------------------------------------------------------- discovery
-- 0045's upsert_federation_teams, except that an existing team without a
-- club (discovered before its club existed, or whose club was deleted)
-- takes the one discovery matched. A club the admin chose is never
-- replaced, and a club id of another alley reads as none.
create or replace function upsert_federation_teams(p_tenant uuid, p_teams jsonb)
returns integer language plpgsql security definer set search_path = public as $$
declare
  t jsonb;
  v_name text;
  v_club uuid;
  v_new integer := 0;
begin
  for t in select * from jsonb_array_elements(p_teams) loop
    select id into v_club from clubs
     where id = (t->>'club_id')::uuid and tenant_id = p_tenant;
    update teams
       set site_team_id = (t->>'site_team_id')::integer, site_name = t->>'site_name',
           competition_slug = t->>'competition_slug',
           competition_name = t->>'competition_name',
           club_id = coalesce(club_id, v_club)
     where tenant_id = p_tenant and site_slug = t->>'site_slug';
    if found then
      continue;
    end if;
    v_name := left(t->>'name', 80);
    if exists (select 1 from teams where tenant_id = p_tenant and name = v_name) then
      v_name := left((t->>'name') || ' (' || (t->>'competition_name') || ')', 80);
    end if;
    if exists (select 1 from teams where tenant_id = p_tenant and name = v_name) then
      v_name := left((t->>'site_name') || ' (' || (t->>'site_slug') || ')', 80);
    end if;
    insert into teams (tenant_id, name, club_id, site_team_id, site_slug, site_name,
                       competition_slug, competition_name)
    values (p_tenant, v_name, v_club, (t->>'site_team_id')::integer,
            t->>'site_slug', t->>'site_name', t->>'competition_slug',
            t->>'competition_name');
    v_new := v_new + 1;
  end loop;
  -- A team rolled over to a new season leaves its old competition dead.
  perform federation_refresh_error(p_tenant);
  return v_new;
end;
$$;

-- Discovery in one transaction. p_clubs: every venue club, in the venue
-- page's order, as [{slug, name, match_id}] — match_id is the club of ours
-- the edge function matched (by slug, else by name among the unlinked
-- ones), or null. p_teams: upsert_federation_teams' rows, each with
-- club_slug, the venue club the team plays for, in place of club_id.
-- A venue club becomes, in this order:
--   1. the club linked to its slug — whatever the admin renamed it to; its
--      site_name follows the site;
--   2. the club match_id names, when it is not linked yet: it gets linked;
--   3. a new club: the site's name, cut to 80 like teams.name (clubs.name
--      has no bound of its own), linked, in the first palette colour no
--      club of the alley uses, else the least used one. A name another club
--      already has creates nothing: its teams stay without a club.
-- Returns {created: new teams, clubs_created: [names], clubs_linked: [our
-- names of the clubs found in 1 or 2]}, both in p_clubs order.
create or replace function apply_federation_discovery(
  p_tenant uuid, p_clubs jsonb, p_teams jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  c jsonb;
  v_club uuid;
  v_name text;
  v_ids jsonb := '{}'::jsonb;
  v_created text[] := '{}';
  v_linked text[] := '{}';
  v_teams jsonb;
begin
  for c in select * from jsonb_array_elements(coalesce(p_clubs, '[]'::jsonb)) loop
    select id, name into v_club, v_name from clubs
     where tenant_id = p_tenant and site_slug = c->>'slug';
    if v_club is not null then
      update clubs set site_name = c->>'name'
       where id = v_club and site_name is distinct from c->>'name';
    else
      update clubs set site_slug = c->>'slug', site_name = c->>'name'
       where tenant_id = p_tenant and id = (c->>'match_id')::uuid and site_slug is null
      returning id, name into v_club, v_name;
    end if;
    if v_club is not null then
      v_linked := v_linked || v_name;
    else
      v_name := rtrim(left(coalesce(nullif(trim(c->>'name'), ''), c->>'slug'), 80));
      -- Palette entries are 0–8 (clubs_color_check since 0031, ClubColors
      -- in lib/domain/palette.dart); -1 and hand-picked colours use none.
      insert into clubs (tenant_id, name, color, site_slug, site_name)
      values (p_tenant, v_name,
              (select i from generate_series(0, 8) i
                order by (select count(*) from clubs k
                           where k.tenant_id = p_tenant and k.color = i), i
                limit 1),
              c->>'slug', c->>'name')
      on conflict do nothing
      returning id into v_club;
      if v_club is not null then
        v_created := v_created || v_name;
      end if;
    end if;
    if v_club is not null then
      v_ids := v_ids || jsonb_build_object(c->>'slug', v_club);
    end if;
  end loop;
  select coalesce(jsonb_agg(x || jsonb_build_object('club_id', v_ids->(x->>'club_slug'))
                            order by o), '[]'::jsonb)
    into v_teams
    from jsonb_array_elements(coalesce(p_teams, '[]'::jsonb)) with ordinality e(x, o);
  return jsonb_build_object(
    'created', upsert_federation_teams(p_tenant, v_teams),
    'clubs_created', to_jsonb(v_created),
    'clubs_linked', to_jsonb(v_linked));
end;
$$;

revoke all on function apply_federation_discovery(uuid, jsonb, jsonb)
  from public, anon, authenticated;
grant execute on function apply_federation_discovery(uuid, jsonb, jsonb) to service_role;

-- ------------------------------------------------ discovery is no run
-- 0045's record_federation_run, except that only competition:<slug> runs
-- are the sync's runs and stamp last_run_at / last_success_at. discover
-- still keeps its report + at, or {error, at}, under its key. The setup
-- wizard reads "never synced" as last_run_at is null, and its own
-- discovery (step 2) must not end it.
create or replace function record_federation_run(
  p_tenant uuid, p_key text, p_report jsonb, p_error text)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_run constant boolean := p_key like 'competition:%';
  v_keep constant boolean := v_run or p_key = 'discover';
  v_report jsonb;
begin
  select last_report into v_report from federation_sync
   where tenant_id = p_tenant for update;
  if p_error is null and not v_keep and not coalesce(v_report ? p_key, false) then
    return;
  end if;
  if v_report is null then
    insert into federation_sync (tenant_id) values (p_tenant) on conflict do nothing;
    select last_report into v_report from federation_sync
     where tenant_id = p_tenant for update;
  end if;
  v_report := case
    when p_error is not null then v_report || jsonb_build_object(p_key,
      jsonb_build_object('error', p_error, 'at', now()))
    when v_keep then v_report || jsonb_build_object(p_key,
      coalesce(p_report, '{}'::jsonb) || jsonb_build_object('at', now()))
    else v_report - p_key end;
  v_report := federation_live_report(p_tenant, v_report);
  update federation_sync
     set last_run_at = case when v_run then now() else last_run_at end,
         last_success_at = case when v_run and p_error is null then now()
                                else last_success_at end,
         last_report = v_report,
         last_error = federation_last_error(p_tenant, v_report)
   where tenant_id = p_tenant;
end;
$$;

-- ----------------------------------------------------- sync progress
-- The admin card's „Synchronizuje se… zbývá …“: the caller's federation
-- jobs due now or leased, per kind. The notify tick's lease counts an
-- attempt and pushes run_at up to 10 minutes ahead (LEASE_MS in
-- federation_jobs.ts), so attempts > 0 with run_at inside that window is a
-- job in flight (or retrying within it). A run that finishes deletes its
-- job or re-arms it with attempts 0, so a match's future checkpoint
-- (T−24 h, T+24 h …) never counts. The tenant is the dedupe key's second
-- part: federation_discover:<tenant>, federation_competition:<tenant>:<slug>,
-- federation_match:<tenant>:<id>, federation_venue:<tenant>:<slug>.
create or replace function federation_sync_progress()
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  v_tenant constant uuid := current_tenant_id();
  v jsonb;
begin
  if not is_admin() then
    raise exception 'not_allowed';
  end if;
  select jsonb_build_object(
           'discover', count(*) filter (where kind = 'federation_discover'),
           'competitions', count(*) filter (where kind = 'federation_competition'),
           'matches', count(*) filter (where kind = 'federation_match'),
           'venues', count(*) filter (where kind = 'federation_venue'))
    into v
    from notification_jobs
   where kind in ('federation_discover', 'federation_competition',
                  'federation_match', 'federation_venue')
     and split_part(dedupe_key, ':', 2) = v_tenant::text
     and (run_at <= now()
          or (attempts > 0 and run_at <= now() + interval '10 minutes'));
  return v;
end;
$$;

revoke all on function federation_sync_progress() from public, anon;
grant execute on function federation_sync_progress() to authenticated;

-- ------------------------------------------ a moved kuželna's discovery
-- 0045's set_federation_sync, except that moving the alley to another
-- kuželna also drops the last discovery's report (last_report.discover)
-- and its job: both were the old kuželna's. The setup wizard opens step 3
-- only on a successful report, so the old kuželna's teams never get it
-- there. A failed discovery's job backing off to retry (+1, +2, +4, +8 min)
-- counts in federation_sync_progress, so the card would spin over it with
-- no request of the admin's, then run it for the new kuželna. Saving the
-- same slug (the switch, step 3) keeps both. create or replace keeps
-- 0045's grants.
create or replace function set_federation_sync(p_venue_slug text, p_enabled boolean)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_tenant constant uuid := current_tenant_id();
  v_slug text := lower(trim(coalesce(p_venue_slug, '')));
  v_old text;
begin
  if not is_admin() then
    raise exception 'not_allowed';
  end if;
  if v_slug !~ '^[a-z0-9]+(-[a-z0-9]+)*$' then
    raise exception 'invalid_venue_slug';
  end if;
  select venue_slug into v_old from federation_sync
   where tenant_id = v_tenant for update;
  insert into federation_sync (tenant_id, venue_slug, enabled)
  values (v_tenant, v_slug, p_enabled)
  on conflict (tenant_id) do update
    set venue_slug = excluded.venue_slug, enabled = excluded.enabled,
        last_report = case
          when federation_sync.venue_slug = excluded.venue_slug
            then federation_sync.last_report
          else federation_sync.last_report - 'discover' end;
  if v_old is distinct from v_slug then
    delete from notification_jobs
     where dedupe_key = 'federation_discover:' || v_tenant;
  end if;
  -- A moved kuželna leaves the old one's venue key dead, and its
  -- discovery's error with the report.
  perform federation_refresh_error(v_tenant);
end;
$$;
