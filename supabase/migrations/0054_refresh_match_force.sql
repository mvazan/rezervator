-- Manual refresh: a tap on the refresh button always looks at the site again,
-- even when the result is under 5 minutes old (p_force). The background
-- pokes (opening a match, the list) keep the 5-minute gate; a forced call
-- keeps only a 15-second floor against a double tap. Same answers as 0045.
drop function if exists refresh_match(uuid);
create or replace function refresh_match(p_match_id uuid, p_force boolean default false)
returns text language plpgsql security definer set search_path = public as $$
declare
  v_slot priority_slots;
  v_status text;
  v_fetched timestamptz;
  v_start timestamptz;
  v_job bigint;
  -- A tap on the refresh button always looks at the site again; the floor
  -- only stops a double tap from queueing the same fetch twice.
  v_gap interval := case when p_force then interval '15 seconds' else interval '5 minutes' end;
begin
  if not is_approved_or_kiosk() then
    raise exception 'not_allowed';
  end if;
  select * into v_slot from priority_slots
   where id = p_match_id and tenant_id = current_tenant_id();
  if not found or v_slot.site_match_id is null then
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
  if not ((v_status = 'in_progress' and now() < v_start + interval '12 hours')
          or (v_status = 'preparation'
              and now() between v_start - interval '1 hour' and v_start + interval '12 hours')
          or (v_status = 'scheduled'
              and now() between v_start - interval '1 hour' and v_start + interval '6 hours')) then
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
