-- 0078 — „Hráči týdne“ on the kiosk: the previous week's best results of
-- the alley's own players, by 100 / 120 throws and men / women.
--
-- Gender comes from the ČKA member register (evidence.kuzelky.cz), which
-- already gives the registration numbers: regnum-lookup reads the
-- register's gender together with the number and keeps it per
-- results-service slug in site_player_regnums. gender is 'm' or 'f', and
-- null means unknown. gender_checked_at says when the function last asked
-- for it (null = never), so a player the register does not settle is asked
-- again only after a week (GENDER_RETRY_DAYS in _shared/regnum.ts). Like
-- the rest of the table, both columns are for the service role only (0059).
--
-- kiosk_week_players(monday) gives the kiosk the week's lines of ours. It is
-- computed on demand, because a late fetch, a correction within 14 days and
-- a gender found later all change a past week. It returns one row per line
-- of our side in a finished or forfeited federation match from that Monday
-- to Sunday. Our side is the side whose team slug is one of the alley's
-- teams.site_slug, the rule the sync itself uses (0045); names are never
-- used. A substitute's line and a line without a total stay out. The
-- function is security definer so it can read the gender, which the app
-- cannot. It is limited to the caller's alley, to approved members and to
-- the kiosk.
--
-- Re-runnable on purpose, like 0064 and 0065.

alter table site_player_regnums
  add column if not exists gender text
    constraint site_player_regnums_gender_check check (gender in ('m', 'f')),
  add column if not exists gender_checked_at timestamptz;

comment on table site_player_regnums is
  'regnum-lookup cache of MATCH players, by results-service player slug (0059): resolved by the service page''s club and age against the register. Since 0078 it also keeps the register''s gender (m / f, null = unknown) and when that was last asked for. Service role only.';
comment on column site_player_regnums.gender is
  'The ČKA register''s gender of the player (0078): m or f, null = unknown. regnum-lookup writes it with the number, or alone for a player found earlier; kiosk_week_players joins it.';
comment on column site_player_regnums.gender_checked_at is
  'When regnum-lookup last asked the register for this player''s gender (0078), null = never. While gender is null it is asked again after a week.';

create or replace function kiosk_week_players(p_monday date default null)
returns table (
  match_id uuid, date date, player_name text, player_slug text,
  total int, errors int, throws int, is_away boolean, competition text,
  team_name text, opponent text, club_id uuid, club_name text,
  club_color int, gender text)
language plpgsql stable security definer set search_path = public as $$
declare
  -- Any day of a week stands for its Monday. Without a day it is the
  -- previous week in Prague, since the database runs in UTC. The app always
  -- passes one, so its title and its gender look-ups name the same week.
  v_monday constant date := coalesce(
    date_trunc('week', p_monday)::date,
    date_trunc('week', now() at time zone 'Europe/Prague')::date - 7);
begin
  if not is_approved_or_kiosk() then
    raise exception 'not_allowed';
  end if;
  -- Every column is qualified: the output columns are variables here.
  return query
  select p.id, p.date, l.player_name, l.player_slug, l.total, l.errors,
         case
           when r.discipline = 'T120' then 120
           when r.discipline = 'T100' then 100
           -- No discipline stored: the lanes tell (4 × 30 or 2 × 50 throws).
           when jsonb_typeof(l.lanes) <> 'array' then null
           when jsonb_array_length(l.lanes) = 4 then 120
           when jsonb_array_length(l.lanes) = 2 then 100
         end,
         -- The alley's home or away, as on the board, not the line's side:
         -- in a derby at our alley both sides are at home.
         p.is_away, p.competition, t.name,
         case l.side when 'home' then p.away_team else p.home_team end,
         c.id, c.name, coalesce(c.color, -1), g.gender
    from priority_slots p
    join match_results r on r.match_id = p.id
    join match_player_results l on l.match_id = p.id
    join teams t
      on t.tenant_id = p.tenant_id
     and t.site_slug = case l.side when 'home' then p.home_team_slug
                                   else p.away_team_slug end
    left join clubs c on c.id = t.club_id
    left join site_player_regnums g on g.slug = l.player_slug
   where p.tenant_id = current_tenant_id()
     and p.import_key like 'cka:%'
     and p.parent_id is null
     and p.date between v_monday and v_monday + 6
     and r.status in ('finished', 'forfeit')
     and l.sub_name is null
     and l.total is not null
   order by p.date, p.starts_at, p.id, l.side, l.position;
end;
$$;

-- As refresh_match (0062): the app's members and its kiosk, never anon.
revoke all on function kiosk_week_players(date) from public, anon;
grant execute on function kiosk_week_players(date) to authenticated;
