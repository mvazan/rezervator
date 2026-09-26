-- 0050 — Služby na kantýně (canteen duty). Each week one or more players
-- work the canteen; the admin plans who and when (duty_periods +
-- duty_assignments) and keeps season boundaries for the counts
-- (duty_seasons). Later parts of this file give the player on duty a few
-- day-level rights through the RPCs and send a reminder before a duty.
-- Spec: docs/superpowers/specs/2026-09-26-canteen-duty-design.md
-- Not deployed until merge, and every statement is safe to run twice.

-- ------------------------------------------------------------ btree_gist
-- The overlap guard below needs a gist opclass for `tenant_id with =`.
-- Into `extensions`, next to the platform's own: in `public` its few
-- hundred functions would land in supabase/schema.sql.
create extension if not exists btree_gist with schema extensions;

-- ---------------------------------------------------------- duty_periods
create table if not exists duty_periods (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references tenants(id) on delete cascade,
  starts_on date not null,
  ends_on date not null,
  note text not null default '',
  created_by uuid references profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  constraint duty_periods_order_check check (ends_on >= starts_on),
  constraint duty_periods_length_check check (ends_on - starts_on < 62),
  constraint duty_periods_note_check check (char_length(note) <= 80),
  constraint duty_periods_no_overlap exclude using gist
    (tenant_id with =, daterange(starts_on, ends_on, '[]') with &&)
);
create index if not exists duty_periods_tenant_starts_on
  on duty_periods (tenant_id, starts_on);
comment on table duty_periods is
  'A canteen duty (0050): the days [starts_on, ends_on], both included, at most 62 of them, that the players in duty_assignments work the canteen. Periods of one alley never overlap (duty_periods_no_overlap). Written only through the admin''s duty_* RPCs.';
comment on column duty_periods.note is
  'The admin''s note shown next to the dates, trimmed, at most 80 characters; '''' = none.';

-- ------------------------------------------------------ duty_assignments
create table if not exists duty_assignments (
  period_id uuid not null references duty_periods(id) on delete cascade,
  user_id uuid not null references profiles(id) on delete cascade,
  tenant_id uuid not null references tenants(id) on delete cascade,
  assigned_by uuid references profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  primary key (period_id, user_id)
);
create index if not exists duty_assignments_tenant_user
  on duty_assignments (tenant_id, user_id);
comment on table duty_assignments is
  'Who works a duty_periods row (0050): approved players of the alley, placeholders included (they count, but never get the duty''s rights); never the kiosk. tenant_id is the period''s, denormalised like player_group_members. Written only through duty_set_assignees; a merge moves a placeholder''s rows to the account.';

-- ---------------------------------------------------------- duty_seasons
create table if not exists duty_seasons (
  tenant_id uuid not null references tenants(id) on delete cascade,
  started_on date not null,
  name text not null,
  created_by uuid references profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  primary key (tenant_id, started_on),
  constraint duty_seasons_name_check check (char_length(name) between 1 and 40)
);
comment on table duty_seasons is
  'Season boundaries for the duty counts (0050). A period belongs to the season with the greatest started_on <= its starts_on; the periods before the first boundary form the implicit first season. Starting a season inserts a row and moves nothing; undoing it deletes the newest row (duty_season_start / duty_season_delete).';

-- ------------------------------------------------------- RLS and grants
-- The whole alley reads the roster (Klubovna → Služby, the Kalendář week
-- header, the kiosk); nobody writes it but the security-definer RPCs.
alter table duty_periods enable row level security;
alter table duty_assignments enable row level security;
alter table duty_seasons enable row level security;

drop policy if exists duty_periods_select on duty_periods;
create policy duty_periods_select on duty_periods
  for select using (tenant_id = current_tenant_id() and is_approved_or_kiosk());
drop policy if exists duty_assignments_select on duty_assignments;
create policy duty_assignments_select on duty_assignments
  for select using (tenant_id = current_tenant_id() and is_approved_or_kiosk());
drop policy if exists duty_seasons_select on duty_seasons;
create policy duty_seasons_select on duty_seasons
  for select using (tenant_id = current_tenant_id() and is_approved_or_kiosk());

revoke all on duty_periods, duty_assignments, duty_seasons from anon, authenticated;
grant select on duty_periods, duty_assignments, duty_seasons to authenticated;
grant all on duty_periods, duty_assignments, duty_seasons to service_role;

-- ------------------------------------------------------------- Realtime
-- The app streams periods and assignees; seasons are a future it
-- invalidates after a change, so they stay out.
do $$
begin
  if not exists (select 1 from pg_publication_tables
                 where pubname = 'supabase_realtime' and schemaname = 'public'
                   and tablename = 'duty_periods') then
    alter publication supabase_realtime add table duty_periods;
  end if;
  if not exists (select 1 from pg_publication_tables
                 where pubname = 'supabase_realtime' and schemaname = 'public'
                   and tablename = 'duty_assignments') then
    alter publication supabase_realtime add table duty_assignments;
  end if;
end $$;

-- ------------------------------------------- schedule_settings: reminder
-- The admin writes both columns straight through the existing
-- settings_update policy: 0017 grants UPDATE on the whole table to
-- authenticated, so new columns need no grant of their own.
alter table schedule_settings
  add column if not exists duty_reminder_enabled boolean not null default false;
alter table schedule_settings
  add column if not exists duty_reminder_days smallint not null default 1;
alter table schedule_settings
  drop constraint if exists schedule_settings_duty_reminder_days_check;
alter table schedule_settings
  add constraint schedule_settings_duty_reminder_days_check
  check (duty_reminder_days between 1 and 14);
comment on column schedule_settings.duty_reminder_enabled is
  'Whether the players on a canteen duty get a reminder before it (0050). Off by default; switching it off keeps duty_reminder_days.';
comment on column schedule_settings.duty_reminder_days is
  'How many days before a canteen duty the reminder goes out, at 18:00 Prague (0050), 1–14.';

-- ------------------------------------------------------------ public_week
-- 0043's public_week hands out the settings row minus tenant_id, and its
-- key-set test forbids a new column reaching anon unnoticed. The reminder
-- setting is the alley's own business: masked, the public week stays
-- exactly what it was. Otherwise 0043's body, unchanged (create or
-- replace keeps its grants).
create or replace function public_week(p_slug text, p_monday date)
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
declare
  v_tenant constant uuid := public_tenant_id(p_slug);
  v_monday constant date :=
    date_trunc('week', coalesce(p_monday, current_date))::date;
  v_from constant date := v_monday - 1;
  v_to constant date := v_monday + 7;
begin
  return jsonb_build_object(
    'tenant_name', (select name from tenants where id = v_tenant),
    'settings', (select to_jsonb(s) - 'tenant_id'
                          - 'duty_reminder_enabled' - 'duty_reminder_days'
                   from schedule_settings s where s.tenant_id = v_tenant),
    'blocks', coalesce((
      select jsonb_agg(to_jsonb(b) - 'tenant_id')
        from time_blocks b where b.tenant_id = v_tenant), '[]'),
    'slot_types', coalesce((
      select jsonb_agg(to_jsonb(t) - 'tenant_id' - 'created_at')
        from priority_slot_types t where t.tenant_id = v_tenant), '[]'),
    'overrides', coalesce((
      select jsonb_agg(to_jsonb(o) - 'tenant_id' - 'created_by' - 'created_at')
        from day_overrides o
       where o.tenant_id = v_tenant and o.date between v_from and v_to), '[]'),
    'priority_slots', coalesce((
      select jsonb_agg(to_jsonb(p) - 'tenant_id' - 'created_by' - 'created_at')
        from priority_slots p
       where p.tenant_id = v_tenant and p.date between v_from and v_to), '[]'),
    -- Names and notes never leave: the board says "Obsazeno" instead.
    'rentals', coalesce((
      select jsonb_agg((to_jsonb(r) - 'tenant_id' - 'created_by' - 'created_at')
                       || jsonb_build_object('renter_name', '', 'note', ''))
        from rentals r
       where r.tenant_id = v_tenant
         and (r.date between v_from and v_to
              or (r.weekday is not null
                  and (r.valid_from is null or r.valid_from <= v_to)
                  and (r.valid_until is null or r.valid_until >= v_from)))),
      '[]'),
    -- Who holds a lane is exactly what the public board must not say: a
    -- live reservation is its cell and the player's club colour, nothing more.
    'occupied', coalesce((
      select jsonb_agg(jsonb_build_object(
               'block_id', x.block_id, 'date', x.date, 'lane', x.lane,
               'club_color', coalesce(c.color, -1))
             order by x.date, x.block_id, x.lane)
        from reservations x
        join profiles pr on pr.id = x.player_id
        left join clubs c on c.id = pr.club_id
       where x.tenant_id = v_tenant
         and x.cancelled_at is null
         and x.date between v_monday and v_monday + 6), '[]')
  );
end;
$$;

-- ------------------------------------------------------- the admin's RPCs
-- Správa → Služby. Admin only (`not_allowed` otherwise), always the
-- caller's own alley: a period or player of another one is `unknown_*`.

-- Periods [s, least(s + p_days − 1, p_until)] for s = p_from, p_from +
-- p_days, … up to p_until: the last one is clipped. A period overlapping an
-- existing one is skipped whole, so a second run over the same range
-- creates nothing. „Týdně, mění se v út“ is 7 days from a Tuesday. p_days
-- 1–31 (`invalid_days`); the range at most 400 days, both ends counted
-- (`invalid_range`, also for p_until before p_from). The app's preview
-- (planDutyPeriods) mirrors this.
create or replace function duty_generate(p_from date, p_days smallint, p_until date)
returns jsonb
language plpgsql security definer set search_path = public
as $$
declare
  v_tenant constant uuid := current_tenant_id();
  v_start date := p_from;
  v_end date;
  v_created integer := 0;
  v_skipped integer := 0;
begin
  if not is_admin() then
    raise exception 'not_allowed';
  end if;
  if p_days is null or p_days < 1 or p_days > 31 then
    raise exception 'invalid_days';
  end if;
  if p_from is null or p_until is null or p_until < p_from
     or p_until - p_from + 1 > 400 then
    raise exception 'invalid_range';
  end if;

  while v_start <= p_until loop
    v_end := least(v_start + p_days - 1, p_until);
    if exists (select 1 from duty_periods
                where tenant_id = v_tenant
                  and daterange(starts_on, ends_on, '[]')
                      && daterange(v_start, v_end, '[]')) then
      v_skipped := v_skipped + 1;
    else
      -- Another admin's period may land between the check and the insert.
      begin
        insert into duty_periods (tenant_id, starts_on, ends_on, created_by)
          values (v_tenant, v_start, v_end, auth.uid());
        v_created := v_created + 1;
      exception when exclusion_violation then
        v_skipped := v_skipped + 1;
      end;
    end if;
    v_start := v_start + p_days;
  end loop;

  return jsonb_build_object('created', v_created, 'skipped', v_skipped);
end;
$$;

-- One period by hand: p_id null inserts, otherwise edits that period. The
-- note is trimmed (at most 80 characters, duty_periods_note_check).
-- `invalid_range` (a date missing or the end before the start),
-- `duty_too_long` (more than 62 days), `duty_overlap`, `unknown_period`.
create or replace function duty_period_save(
  p_id uuid, p_starts_on date, p_ends_on date, p_note text)
returns uuid
language plpgsql security definer set search_path = public
as $$
declare
  v_tenant constant uuid := current_tenant_id();
  v_note constant text := trim(coalesce(p_note, ''));
  v_id uuid;
begin
  if not is_admin() then
    raise exception 'not_allowed';
  end if;
  if p_starts_on is null or p_ends_on is null or p_ends_on < p_starts_on then
    raise exception 'invalid_range';
  end if;
  if p_ends_on - p_starts_on >= 62 then
    raise exception 'duty_too_long';
  end if;

  begin
    if p_id is null then
      insert into duty_periods (tenant_id, starts_on, ends_on, note, created_by)
        values (v_tenant, p_starts_on, p_ends_on, v_note, auth.uid())
        returning id into v_id;
    else
      update duty_periods
         set starts_on = p_starts_on, ends_on = p_ends_on, note = v_note
       where id = p_id and tenant_id = v_tenant
       returning id into v_id;
      if v_id is null then
        raise exception 'unknown_period';
      end if;
    end if;
  exception when exclusion_violation then
    raise exception 'duty_overlap';
  end;
  return v_id;
end;
$$;

-- Deletes one period; its assignees go with it (cascade). `unknown_period`.
create or replace function duty_period_delete(p_id uuid)
returns void
language plpgsql security definer set search_path = public
as $$
begin
  if not is_admin() then
    raise exception 'not_allowed';
  end if;
  delete from duty_periods where id = p_id and tenant_id = current_tenant_id();
  if not found then
    raise exception 'unknown_period';
  end if;
end;
$$;

-- „Smazat neobsazené budoucí…“: every period starting on p_from or later
-- that nobody is assigned to — what a change of rhythm leaves behind.
-- Returns how many went. `invalid_range` without a date.
create or replace function duty_periods_delete_unassigned(p_from date)
returns integer
language plpgsql security definer set search_path = public
as $$
declare
  v_count integer;
begin
  if not is_admin() then
    raise exception 'not_allowed';
  end if;
  if p_from is null then
    raise exception 'invalid_range';
  end if;
  delete from duty_periods d
   where d.tenant_id = current_tenant_id()
     and d.starts_on >= p_from
     and not exists (select 1 from duty_assignments a where a.period_id = d.id);
  get diagnostics v_count = row_count;
  return v_count;
end;
$$;

-- Replaces the period's assignees with p_users (duplicates collapse, an
-- empty list clears it). Each must be an approved non-kiosk member of the
-- alley — the `players` view's rule, so a visiting superadmin is out and a
-- placeholder is in — or the call changes nothing: `unknown_player`.
-- `unknown_period`.
create or replace function duty_set_assignees(p_period uuid, p_users uuid[])
returns void
language plpgsql security definer set search_path = public
as $$
declare
  v_tenant constant uuid := current_tenant_id();
  v_users constant uuid[] :=
    array(select distinct u from unnest(coalesce(p_users, '{}')) u);
begin
  if not is_admin() then
    raise exception 'not_allowed';
  end if;
  -- Two admins saving the same period end with one of their sets, not a mix.
  perform 1 from duty_periods
   where id = p_period and tenant_id = v_tenant
     for update;
  if not found then
    raise exception 'unknown_period';
  end if;
  if exists (
    select 1 from unnest(v_users) u
     where u is null or not exists (
       select 1 from profiles p
        where p.id = u and p.tenant_id = v_tenant
          and p.status = 'approved' and p.role <> 'kiosk'
          and not (p.superadmin and p.home_tenant_id is not null
                   and p.tenant_id <> p.home_tenant_id))
  ) then
    raise exception 'unknown_player';
  end if;

  delete from duty_assignments
   where period_id = p_period and user_id <> all (v_users);
  insert into duty_assignments (period_id, user_id, tenant_id, assigned_by)
  select p_period, u, v_tenant, auth.uid() from unnest(v_users) u
  on conflict (period_id, user_id) do nothing;
end;
$$;

-- „Nová sezóna…“: a boundary from p_started_on on, which must come after
-- the newest one (`season_order`). The name is trimmed: `empty_name` when
-- nothing is left, duty_seasons_name_check past 40 characters.
create or replace function duty_season_start(p_started_on date, p_name text)
returns void
language plpgsql security definer set search_path = public
as $$
declare
  v_tenant constant uuid := current_tenant_id();
  v_name constant text := trim(coalesce(p_name, ''));
begin
  if not is_admin() then
    raise exception 'not_allowed';
  end if;
  if v_name = '' then
    raise exception 'empty_name';
  end if;
  -- One season change at a time per alley, so "after the newest" holds.
  perform pg_advisory_xact_lock(hashtext('duty_season'), hashtext(v_tenant::text));
  if exists (select 1 from duty_seasons
              where tenant_id = v_tenant and started_on >= p_started_on) then
    raise exception 'season_order';
  end if;
  insert into duty_seasons (tenant_id, started_on, name, created_by)
    values (v_tenant, p_started_on, v_name, auth.uid());
end;
$$;

-- „Vrátit poslední sezónu“: deletes the boundary p_started_on, which must
-- be the newest (`not_newest` otherwise, and when there is none).
create or replace function duty_season_delete(p_started_on date)
returns void
language plpgsql security definer set search_path = public
as $$
declare
  v_tenant constant uuid := current_tenant_id();
  v_newest date;
begin
  if not is_admin() then
    raise exception 'not_allowed';
  end if;
  perform pg_advisory_xact_lock(hashtext('duty_season'), hashtext(v_tenant::text));
  select max(started_on) into v_newest from duty_seasons where tenant_id = v_tenant;
  if v_newest is null or p_started_on is distinct from v_newest then
    raise exception 'not_newest';
  end if;
  delete from duty_seasons where tenant_id = v_tenant and started_on = v_newest;
end;
$$;

revoke all on function duty_generate(date, smallint, date) from public, anon;
revoke all on function duty_period_save(uuid, date, date, text) from public, anon;
revoke all on function duty_period_delete(uuid) from public, anon;
revoke all on function duty_periods_delete_unassigned(date) from public, anon;
revoke all on function duty_set_assignees(uuid, uuid[]) from public, anon;
revoke all on function duty_season_start(date, text) from public, anon;
revoke all on function duty_season_delete(date) from public, anon;
grant execute on function duty_generate(date, smallint, date) to authenticated;
grant execute on function duty_period_save(uuid, date, date, text) to authenticated;
grant execute on function duty_period_delete(uuid) to authenticated;
grant execute on function duty_periods_delete_unassigned(date) to authenticated;
grant execute on function duty_set_assignees(uuid, uuid[]) to authenticated;
grant execute on function duty_season_start(date, text) to authenticated;
grant execute on function duty_season_delete(date) to authenticated;

-- ------------------------------------------------- placeholder lifecycle
-- A placeholder's duties are history like its reservations: they block a
-- delete and move with a merge. duty_assignments.user_id cascades, so
-- without this a delete or merge would drop them silently. Both are
-- 0022's bodies otherwise (create or replace keeps their grants).

-- A placeholder with reservations or duties is history (Docházka,
-- Služby): merge it into an account instead of deleting it.
create or replace function delete_placeholder_player(p_id uuid)
returns void
language plpgsql security definer set search_path = public
as $$
begin
  if not is_admin() then
    raise exception 'not_allowed';
  end if;
  if not exists (
    select 1 from profiles
    where id = p_id and tenant_id = current_tenant_id() and placeholder
  ) then
    raise exception 'unknown_player';
  end if;
  if exists (select 1 from reservations where player_id = p_id)
     or exists (select 1 from duty_assignments where user_id = p_id) then
    raise exception 'player_has_history';
  end if;
  delete from profiles where id = p_id;
end;
$$;

-- The person behind a placeholder registered: p_target_id is their account
-- (pending or already approved). The placeholder's reservations and duties
-- move to the account, the account takes the fields the admin chose in the
-- merge dialog and is approved, the placeholder row goes.
create or replace function merge_placeholder_player(
  p_placeholder_id uuid, p_target_id uuid,
  p_display_name text, p_nick text, p_club_id uuid)
returns void
language plpgsql security definer set search_path = public
as $$
declare
  v_tenant uuid := current_tenant_id();
begin
  if not is_admin() then
    raise exception 'not_allowed';
  end if;
  -- Lock both rows: a concurrent create_reservation for the placeholder
  -- waits here instead of slipping in between the repoint and the delete.
  perform 1 from profiles
  where id = p_placeholder_id and tenant_id = v_tenant and placeholder
  for update;
  if not found then
    raise exception 'invalid_merge';
  end if;
  perform 1 from profiles
  where id = p_target_id and tenant_id = v_tenant
    and not placeholder and role <> 'kiosk'
  for update;
  if not found then
    raise exception 'invalid_merge';
  end if;
  if trim(coalesce(p_display_name, '')) = '' then
    raise exception 'empty_display_name';
  end if;
  if char_length(trim(coalesce(p_nick, ''))) > 14 then
    raise exception 'nick_too_long';
  end if;
  if p_club_id is not null and not exists (
    select 1 from clubs where id = p_club_id and tenant_id = v_tenant
  ) then
    raise exception 'unknown_club';
  end if;

  -- History moves to the account. player_id is the only column that can
  -- reference a placeholder: created_by / approved_by are written from
  -- auth.uid(), which a placeholder never is (profiles_placeholder_check
  -- keeps it a plain player). Anything else pointing at the row makes the
  -- NO ACTION FKs abort the delete below.
  update reservations set player_id = p_target_id
  where player_id = p_placeholder_id;

  -- Duties too (0050), except where the account is on the same period
  -- already: that row is the one kept. What stays on the placeholder goes
  -- with it (the FK cascades).
  update duty_assignments a set user_id = p_target_id
  where a.user_id = p_placeholder_id
    and not exists (select 1 from duty_assignments b
                    where b.period_id = a.period_id and b.user_id = p_target_id);

  update profiles
  set display_name = trim(p_display_name),
      nick = trim(coalesce(p_nick, '')),
      club_id = p_club_id,
      status = 'approved',
      approved_by = coalesce(approved_by, auth.uid()),
      approved_at = coalesce(approved_at, now())
  where id = p_target_id;

  delete from profiles where id = p_placeholder_id;
end;
$$;
