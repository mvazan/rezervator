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
