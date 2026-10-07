-- 0062 — the ⟳ button asks again for a FINISHED match.
--
-- A match of ours is polled while it is live and fetched once more when it
-- finishes; after that nothing looks at its page again (the nightly pass
-- arms a fetch only for a match not yet stored as finished), and a league
-- match's detail is fetched once. A correction on the site after the end —
-- a result fixed, a missing lane or player line filled in — therefore never
-- reached the app. refresh_match now lets the button (p_force) ask for a
-- finished match within 14 days of its start; opening the match (no force)
-- asks nothing, as before. The 15 s floor of a forced request still stops a
-- double tap from fetching twice.

create or replace function refresh_match(p_match_id uuid, p_force boolean default false)
returns text language plpgsql security definer set search_path = public as $$
declare
  v_slot priority_slots;
  v_league league_matches;
  v_status text;
  v_fetched timestamptz;
  v_start timestamptz;
  v_job bigint;
  v_gap interval := case when p_force then interval '15 seconds' else interval '5 minutes' end;
  -- How long after its start a finished match may still be corrected on the
  -- site — and asked for again by the ⟳ button (0062).
  v_corrections interval := interval '14 days';
begin
  if not is_approved_or_kiosk() then
    raise exception 'not_allowed';
  end if;
  select * into v_slot from priority_slots
   where id = p_match_id and tenant_id = current_tenant_id();
  if not found then
    -- Not one of ours: maybe a match of one of our competitions.
    select * into v_league from league_matches
     where id = p_match_id and tenant_id = current_tenant_id();
    if not found or not league_competition_is_ours(v_league.tenant_id, v_league.competition_slug) then
      return 'not_live';
    end if;
    v_fetched := v_league.detail_fetched_at;
    if v_league.status in ('finished', 'forfeit') then
      -- Final: a missing detail is worth a fetch; a fetched one only when
      -- somebody taps ⟳ (a correction on the site) within v_corrections.
      if v_league.detail_status in ('finished', 'forfeit') and not (
           p_force
           and now() < (v_league.date + coalesce(v_league.starts_at, time '00:00'))
                         at time zone 'Europe/Prague' + v_corrections) then
        return 'not_live';
      end if;
    else
      if v_league.starts_at is null then
        return 'not_live';
      end if;
      v_start := (v_league.date + v_league.starts_at) at time zone 'Europe/Prague';
      if not (now() between v_start - interval '1 hour' and v_start + interval '30 hours') then
        return 'not_live';
      end if;
    end if;
    if v_fetched is not null and v_fetched > now() - v_gap then
      return 'fresh';
    end if;
    insert into notification_jobs (kind, dedupe_key, payload, run_at)
    values ('federation_league_match',
            'federation_league_match:' || v_league.tenant_id || ':' || v_league.site_match_id,
            jsonb_build_object('tenant_id', v_league.tenant_id,
                               'site_match_id', v_league.site_match_id,
                               'slug', v_league.site_slug, 'requested_at', now()),
            -- a request sorts before the backfill jobs (the runner takes the
            -- oldest run_at first): someone is waiting for this one
            'epoch'::timestamptz)
    on conflict (dedupe_key) do update
      set run_at = least(notification_jobs.run_at, excluded.run_at),
          payload = notification_jobs.payload || jsonb_build_object('requested_at', now())
      where coalesce((notification_jobs.payload->>'requested_at')::timestamptz, '-infinity')
            < now() - v_gap
    returning id into v_job;
    -- One dispatch for a burst (opening Výsledky pokes every refreshable
    -- match): each would start a whole notify run. The button (force) always
    -- dispatches.
    if v_job is not null and (p_force or not exists (
         select 1 from notification_jobs o
          where o.kind = 'federation_league_match' and o.id <> v_job
            and (o.payload->>'requested_at')::timestamptz > now() - interval '10 seconds')) then
      perform trigger_notification_jobs();
    end if;
    return 'queued';
  end if;

  if v_slot.site_match_id is null then
    return 'not_live';
  end if;
  -- Only switched-off teams of ours play it: its job would fetch the page
  -- and stop unwritten, leaving neither a fresh fetched_at nor a pending
  -- requested_at to gate the next request — so no job at all.
  if federation_match_switched_off(v_slot.tenant_id, v_slot.home_team_slug,
                                   v_slot.away_team_slug) then
    return 'not_live';
  end if;
  select status, fetched_at into v_status, v_fetched
    from match_results where match_id = p_match_id;
  v_status := coalesce(v_status, 'scheduled');
  v_start := (v_slot.date + v_slot.starts_at) at time zone 'Europe/Prague';
  -- The site shows 'preparation' days before some matches: like
  -- 'scheduled', it is live only from an hour before the start.
  -- A finished match is never polled again, so a correction on the site
  -- (a result, a missing lane) reaches us only when somebody taps ⟳ — within
  -- v_corrections of the start (0062). Opening it alone asks nothing.
  if not ((v_status = 'in_progress' and now() < v_start + interval '12 hours')
          or (v_status = 'preparation'
              and now() between v_start - interval '1 hour' and v_start + interval '12 hours')
          or (v_status = 'scheduled'
              and now() between v_start - interval '1 hour' and v_start + interval '6 hours')
          or (p_force and v_status in ('finished', 'forfeit')
              and now() < v_start + v_corrections)) then
    return 'not_live';
  end if;
  if v_fetched is not null and v_fetched > now() - v_gap then
    return 'fresh';
  end if;
  -- fetched_at alone does not gate a fetch that is pending, running or
  -- backing off: the job's requested_at does.
  insert into notification_jobs (kind, dedupe_key, payload, run_at)
  values ('federation_match',
          'federation_match:' || v_slot.tenant_id || ':' || v_slot.site_match_id,
          jsonb_build_object('tenant_id', v_slot.tenant_id,
                             'site_match_id', v_slot.site_match_id,
                             'slug', v_slot.site_slug, 'requested_at', now()),
          now())
  on conflict (dedupe_key) do update
    set run_at = least(notification_jobs.run_at, excluded.run_at),
        payload = notification_jobs.payload || jsonb_build_object('requested_at', now())
    where coalesce((notification_jobs.payload->>'requested_at')::timestamptz, '-infinity')
          < now() - v_gap
  returning id into v_job;
  if v_job is not null then
    perform trigger_notification_jobs();
  end if;
  return 'queued';
end;
$$;


revoke all on function refresh_match(uuid, boolean) from public, anon;
grant execute on function refresh_match(uuid, boolean) to authenticated;
