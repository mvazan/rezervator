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

-- service_role is revoked too, so every run rebuilds the ACL in the same
-- order (authenticated, then service_role). Revoking only anon and
-- authenticated would move authenticated behind service_role on a second
-- run, and the schema snapshot would then differ from a fresh database.
revoke all on duty_periods, duty_assignments, duty_seasons
  from anon, authenticated, service_role;
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

-- =================================================== the rights of the duty
-- The player on duty books and cancels trainings for the alley's players
-- and edits single days (add or cancel a block, close a day) from today on.
-- Only the security-definer RPCs below grant it: no table policy gets
-- wider, so the weekly template, matches, rentals, slot types, clubs and
-- settings stay the admin's. The duty keeps the booked player's rules (their
-- cap, the horizon, no past day, no started block); only the admin goes
-- past them. Branch order in the booking RPCs: admin → kiosk → self → group
-- → duty, so a duty booking a group mate books as 'group'.

-- ------------------------------------------------------ reservations: via
-- 'duty' instead of 'admin': the booked player learns who it was and the
-- audit trail stays honest. Dropped and re-added NOT VALID, then validated.
alter table reservations drop constraint if exists reservations_created_via_check;
alter table reservations add constraint reservations_created_via_check
  check (created_via in ('app', 'kiosk', 'admin', 'group', 'duty')) not valid;
alter table reservations validate constraint reservations_created_via_check;
alter table reservations drop constraint if exists reservations_cancelled_via_check;
alter table reservations add constraint reservations_cancelled_via_check
  check (cancelled_via in ('app', 'one_click', 'admin', 'group', 'duty')) not valid;
alter table reservations validate constraint reservations_cancelled_via_check;

-- ----------------------------------------------------------- the helpers
-- On duty = an approved account player (no placeholder; the kiosk and the
-- admin never — the admin has the admin path) assigned to a period of the
-- alley they are in that covers Prague today. The tenant match keeps a
-- visiting superadmin out; a pending or demoted player loses it at once;
-- at midnight every call is judged again. Internal like same_group: only
-- security-definer bodies call it. (Unlike is_admin(), which policies call
-- and which therefore stays PUBLIC-executable.)
create or replace function is_on_duty() returns boolean language sql stable
security definer set search_path = public as $$
  select exists (select 1 from duty_assignments a
    join duty_periods d on d.id = a.period_id
    join profiles me on me.id = auth.uid()
   where a.user_id = me.id and d.tenant_id = me.tenant_id
     and me.status = 'approved' and me.role = 'player' and not me.placeholder
     and (now() at time zone 'Europe/Prague')::date between d.starts_on and d.ends_on) $$;

-- The gate of the day RPCs: the admin passes on any date; anyone else must
-- be on duty (`not_allowed`) and touch only Prague today or later
-- (`date_past`). Internal, like is_on_duty().
create or replace function duty_gate(p_date date) returns void
language plpgsql stable security definer set search_path = public
as $$
begin
  if is_admin() then
    return;
  end if;
  if not is_on_duty() then
    raise exception 'not_allowed';
  end if;
  if p_date < (now() at time zone 'Europe/Prague')::date then
    raise exception 'date_past';
  end if;
end;
$$;

revoke all on function is_on_duty() from public, anon, authenticated;
revoke all on function duty_gate(date) from public, anon, authenticated;

-- --------------------------------------------------- two new day RPCs
-- The app wrote these two straight into the tables (Api.addSpecialBlock,
-- Api.deleteDayOverride), which only the admin's policies allow. Behind
-- RPCs the duty gets them without a wider policy.

-- An INACTIVE day-only block of the caller's alley: position -1 is the
-- SPECIAL sentinel the Rozvrh list hides, active = false keeps it out of
-- the weekly template; a day override then points at it. Returns its id.
-- The admin, or the duty: there is no date, so the gate checks Prague
-- today, which a running duty always covers.
create or replace function add_special_block(p_starts_at time, p_ends_at time)
returns uuid
language plpgsql security definer set search_path = public
as $$
declare
  v_id uuid;
begin
  perform duty_gate((now() at time zone 'Europe/Prague')::date);
  insert into time_blocks (tenant_id, starts_at, ends_at, position, active)
    values (current_tenant_id(), p_starts_at, p_ends_at, -1, false)
    returning id into v_id;
  return v_id;
end;
$$;

-- Returns p_date to the weekly template: deletes its override (the
-- override_changed cascade cancels what no longer fits). The admin on any
-- date, the duty from today on. No override is no error.
create or replace function delete_day_override(p_date date)
returns void
language plpgsql security definer set search_path = public
as $$
begin
  perform duty_gate(p_date);
  delete from day_overrides
   where tenant_id = current_tenant_id() and date = p_date;
end;
$$;

revoke all on function add_special_block(time, time) from public, anon;
revoke all on function delete_day_override(date) from public, anon;
grant execute on function add_special_block(time, time) to authenticated;
grant execute on function delete_day_override(date) to authenticated;

-- ------------------------------------------ the day RPCs: admin or duty
-- The current bodies (0011, move_reservation 0021; copied from
-- supabase/schema.sql): the is_admin() gate became duty_gate(date)
-- (move_reservation gates twice, see there), and a started block of today
-- is the duty's limit, as it is every player's: a cancel spares its
-- trainings (like cancel_stranded_reservations — they are played, and
-- attendance is the admin's), a move neither leaves nor enters it
-- (`too_late`). The admin's path is unchanged. Signatures, defaults and
-- grants stay (create or replace).

-- Upsert the day's override and cancel the reservations it displaces
-- (the duty's: not those under way today).
create or replace function set_day_override(
  p_date date, p_closed boolean, p_reason text default '',
  p_block_ids uuid[] default null)
returns void
language plpgsql security definer set search_path = public
as $$
declare
  v_admin boolean := is_admin();
  v_today date := (now() at time zone 'Europe/Prague')::date;
  v_now time := (now() at time zone 'Europe/Prague')::time;
begin
  perform duty_gate(p_date);

  insert into day_overrides (tenant_id, date, closed, reason, block_ids, created_by)
  values (current_tenant_id(), p_date, p_closed, trim(coalesce(p_reason, '')),
          p_block_ids, auth.uid())
  on conflict (tenant_id, date) do update
    set closed = excluded.closed,
        reason = excluded.reason,
        block_ids = excluded.block_ids,
        created_by = excluded.created_by,
        created_at = now();

  update reservations r
  set cancelled_at = now(),
      cancelled_via = 'admin',
      cancel_note = coalesce(nullif(trim(p_reason), ''), 'změna rozvrhu'),
      notify_player = true,
      notify_message = null
  from time_blocks b
  where b.id = r.block_id
    and r.date = p_date
    and r.tenant_id = current_tenant_id()
    and r.cancelled_at is null
    and (p_closed or (p_block_ids is not null and not (r.block_id = any (p_block_ids))))
    and (v_admin or not (r.date = v_today and b.starts_at <= v_now));
end;
$$;

-- Bulk cancel before hiding a template block for one day (the duty's:
-- nothing once the block has started today).
create or replace function cancel_block_day_reservations(
  p_date date, p_block uuid, p_note text default 'změna rozvrhu')
returns void
language plpgsql security definer set search_path = public
as $$
declare
  v_admin boolean := is_admin();
  v_today date := (now() at time zone 'Europe/Prague')::date;
  v_now time := (now() at time zone 'Europe/Prague')::time;
begin
  perform duty_gate(p_date);
  if not exists (
    select 1 from time_blocks
    where id = p_block and tenant_id = current_tenant_id()
  ) then
    raise exception 'unknown_block';
  end if;

  update reservations r
  set cancelled_at = now(),
      cancelled_via = 'admin',
      cancel_note = coalesce(nullif(trim(p_note), ''), 'změna rozvrhu'),
      notify_player = true,
      notify_message = null
  from time_blocks b
  where b.id = r.block_id
    and r.date = p_date
    and r.block_id = p_block
    and r.cancelled_at is null
    and r.tenant_id = current_tenant_id()
    and (v_admin or not (r.date = v_today and b.starts_at <= v_now));
end;
$$;

-- Re-seat all reservations of a day's block into another block (the
-- duty's: neither block started today, else `too_late`).
create or replace function move_day_reservations(
  p_date date, p_from_block uuid, p_to_block uuid,
  p_notify boolean default true, p_message text default null)
returns void
language plpgsql security definer set search_path = public
as $$
begin
  perform duty_gate(p_date);

  if not exists (
    select 1 from time_blocks
    where id = p_from_block and tenant_id = current_tenant_id()
  ) or not exists (
    select 1 from time_blocks
    where id = p_to_block and tenant_id = current_tenant_id()
  ) then
    raise exception 'unknown_block';
  end if;

  if not is_admin()
     and p_date = (now() at time zone 'Europe/Prague')::date
     and exists (
       select 1 from time_blocks
       where id in (p_from_block, p_to_block)
         and starts_at <= (now() at time zone 'Europe/Prague')::time) then
    raise exception 'too_late';
  end if;

  update reservations
  set block_id = p_to_block,
      notify_player = coalesce(p_notify, true),
      notify_message = nullif(trim(coalesce(p_message, '')), '')
  where date = p_date
    and block_id = p_from_block
    and cancelled_at is null
    and tenant_id = current_tenant_id();
exception when unique_violation then
  raise exception 'slot_taken';
end;
$$;

-- Re-seat one reservation. A move keeps its date, so the source and the
-- target date are one: the duty is refused before a word about the
-- reservation (Prague today), then held to the reservation's date, and on
-- today neither its block nor the target may have started (`too_late`).
create or replace function move_reservation(
  p_reservation uuid, p_to_block uuid, p_lane integer,
  p_notify boolean default true, p_message text default null)
returns void
language plpgsql security definer set search_path = public
as $$
declare
  v_res reservations;
  v_block time_blocks;
  v_lanes int;
begin
  perform duty_gate((now() at time zone 'Europe/Prague')::date);

  select * into v_res from reservations
  where id = p_reservation and tenant_id = current_tenant_id();
  if not found or v_res.cancelled_at is not null then
    raise exception 'unknown_reservation';
  end if;
  perform duty_gate(v_res.date);

  select * into v_block from time_blocks
  where id = p_to_block and tenant_id = current_tenant_id();
  if not found then
    raise exception 'unknown_block';
  end if;

  if not is_admin()
     and v_res.date = (now() at time zone 'Europe/Prague')::date
     and (v_block.starts_at <= (now() at time zone 'Europe/Prague')::time
          or (select starts_at from time_blocks where id = v_res.block_id)
             <= (now() at time zone 'Europe/Prague')::time) then
    raise exception 'too_late';
  end if;

  select lane_count into v_lanes from schedule_settings
  where tenant_id = current_tenant_id();
  if p_lane < 1 or p_lane > v_lanes then
    raise exception 'invalid_lane';
  end if;

  if exists (
    select 1 from priority_slots s
    join priority_slot_types t on t.id = s.type_id
    where s.date = v_res.date
      and s.tenant_id = current_tenant_id()
      and not s.is_away
      and (t.lanes is null or p_lane = any (t.lanes))
      and s.starts_at < v_block.ends_at
      and s.ends_at > v_block.starts_at
  ) then
    raise exception 'blocked_by_priority';
  end if;

  if exists (
    select 1 from rental_occurrences(current_tenant_id(), v_res.date) o
    where p_lane = any (o.lanes)
      and o.starts_at < v_block.ends_at and o.ends_at > v_block.starts_at
  ) then
    raise exception 'blocked_by_rental';
  end if;

  update reservations
  set block_id = p_to_block, lane = p_lane,
      notify_player = coalesce(p_notify, true),
      notify_message = nullif(trim(coalesce(p_message, '')), '')
  where id = p_reservation;
exception when unique_violation then
  raise exception 'slot_taken';
end;
$$;

-- ------------------------------------------- booking and cancelling: duty
-- create_reservation (0044's body): a duty branch after the group branch.
-- A duty booking follows the booked player's rules and cap, like a group
-- one, and says so when that cap is hit: `player_at_limit`.
create or replace function create_reservation(
  p_player_id uuid, p_date date, p_block_id uuid, p_lane smallint)
returns reservations
language plpgsql security definer set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_caller profiles;
  v_settings schedule_settings;
  v_block time_blocks;
  v_status text;
  v_via text;
  v_today date := (now() at time zone 'Europe/Prague')::date;
  v_now time := (now() at time zone 'Europe/Prague')::time;
  v_active_count int;
  v_res reservations;
begin
  if v_uid is null then
    raise exception 'not_authenticated';
  end if;
  select * into v_caller from profiles where id = v_uid;
  if not found then
    raise exception 'no_profile';
  end if;

  if v_caller.role = 'admin' and v_caller.status = 'approved' then
    v_via := case when p_player_id = v_uid then 'app' else 'admin' end;
  elsif v_caller.role = 'kiosk' then
    v_via := 'kiosk';
  elsif v_caller.status = 'approved' and p_player_id = v_uid then
    v_via := 'app';
  elsif v_caller.status = 'approved' and v_caller.role = 'player'
        and same_group(v_uid, p_player_id) then
    v_via := 'group';
  elsif v_caller.status = 'approved' and v_caller.role = 'player'
        and p_player_id <> v_uid and is_on_duty() then
    v_via := 'duty';
  else
    raise exception 'not_allowed';
  end if;

  if not exists (
    select 1 from profiles
    where id = p_player_id and status = 'approved' and role <> 'kiosk'
      and tenant_id = v_caller.tenant_id
  ) then
    raise exception 'player_not_approved';
  end if;

  select * into v_settings from schedule_settings
  where tenant_id = v_caller.tenant_id;
  select * into v_block from time_blocks
  where id = p_block_id and tenant_id = v_caller.tenant_id;
  if not found then
    raise exception 'unknown_block';
  end if;
  if p_lane < 1 or p_lane > v_settings.lane_count then
    raise exception 'invalid_lane';
  end if;

  v_status := block_day_status(v_caller.tenant_id, p_date, p_block_id);
  if v_status is distinct from 'open' then
    raise exception '%', coalesce(v_status, 'unknown_block');
  end if;

  if v_caller.role <> 'admin' then
    if p_date < v_today then
      raise exception 'date_past';
    end if;
    if p_date = v_today and v_block.starts_at <= v_now then
      raise exception 'date_past';
    end if;
    if p_date > v_today + v_settings.booking_horizon_days then
      raise exception 'beyond_horizon';
    end if;
    select count(*) into v_active_count
    from reservations
    where player_id = p_player_id and cancelled_at is null and date >= v_today;
    if v_active_count >= v_settings.max_active_reservations then
      -- "Máš už…" would be a lie about a member's cap.
      raise exception '%',
        case when v_via = 'group' then 'member_at_limit'
             when v_via = 'duty' then 'player_at_limit'
             else 'limit_reached' end;
    end if;
  end if;

  if exists (
    select 1 from priority_slots s
    join priority_slot_types t on t.id = s.type_id
    where s.date = p_date
      and s.tenant_id = v_caller.tenant_id
      and not s.is_away
      and (t.lanes is null or p_lane = any (t.lanes))
      and s.starts_at < v_block.ends_at
      and s.ends_at > v_block.starts_at
  ) then
    raise exception 'blocked_by_priority';
  end if;

  if exists (
    select 1 from rental_occurrences(v_caller.tenant_id, p_date) o
    where p_lane = any (o.lanes)
      and o.starts_at < v_block.ends_at and o.ends_at > v_block.starts_at
  ) then
    raise exception 'blocked_by_rental';
  end if;

  begin
    insert into reservations
      (tenant_id, player_id, date, block_id, lane, created_via, created_by)
    values
      (v_caller.tenant_id, p_player_id, p_date, p_block_id, p_lane, v_via, v_uid)
    returning * into v_res;
  exception when unique_violation then
    raise exception 'slot_taken';
  end;

  return v_res;
end;
$$;

-- cancel_reservation (0044's body): a duty branch after the owner/group
-- branch — another player's training of the duty's alley, until its block
-- starts (`too_late`). The note and the notify choice are the duty's, as
-- for everyone.
create or replace function cancel_reservation(
  p_id uuid, p_note text default '', p_notify boolean default true)
returns void
language plpgsql security definer set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_caller profiles;
  v_res reservations;
  v_block time_blocks;
  v_via text;
  v_now timestamptz := now();
  v_starts timestamptz;
begin
  if v_uid is null then
    raise exception 'not_authenticated';
  end if;
  select * into v_caller from profiles where id = v_uid;
  if not found then
    raise exception 'no_profile';
  end if;

  select * into v_res from reservations where id = p_id;
  if not found then
    raise exception 'not_found';
  end if;
  if v_res.cancelled_at is not null then
    return;  -- already cancelled, idempotent
  end if;

  if v_caller.role = 'admin' and v_caller.status = 'approved'
     and v_res.tenant_id = v_caller.tenant_id then
    v_via := 'admin';
  elsif v_caller.status = 'approved'
        and (v_res.player_id = v_uid
             or (v_caller.role = 'player' and same_group(v_uid, v_res.player_id))) then
    select * into v_block from time_blocks where id = v_res.block_id;
    v_starts := (v_res.date + v_block.starts_at) at time zone 'Europe/Prague';
    if v_now >= v_starts then
      raise exception 'too_late';
    end if;
    v_via := case when v_res.player_id = v_uid then 'app' else 'group' end;
  elsif v_caller.status = 'approved' and v_caller.role = 'player'
        and v_res.tenant_id = v_caller.tenant_id and is_on_duty() then
    select * into v_block from time_blocks where id = v_res.block_id;
    v_starts := (v_res.date + v_block.starts_at) at time zone 'Europe/Prague';
    if v_now >= v_starts then
      raise exception 'too_late';
    end if;
    v_via := 'duty';
  else
    raise exception 'not_allowed';
  end if;

  update reservations
  set cancelled_at = v_now, cancelled_via = v_via, cancelled_by = v_uid,
      cancel_note = trim(coalesce(p_note, '')),
      notify_player = coalesce(p_notify, true),
      notify_message = null
  where id = p_id;
end;
$$;

-- ============================================== the reminder before a duty
-- The alley's admin switches it on and picks the lead (schedule_settings,
-- above). Nothing is scheduled, as for 0040's reminders: every minute the
-- tick asks what is due now, from the data as it stands, so a moved or
-- deleted period, a changed roster or a changed lead simply answers
-- differently. A separate function: due_reminders() and its tests stay as
-- they are.

-- One row per (account, period) worth a reminder right now:
--   * the period's alley has the reminder on;
--   * 18:00 Prague on (starts_on − lead) has passed — a period planned or
--     a player assigned inside the lead is reminded at once, late;
--   * the duty has not started (starts_on after Prague today): nothing
--     reminds of a duty already under way;
--   * an account: approved, no placeholder (no login, nowhere to send),
--     never the kiosk. The admin on a duty serves too. No tenant match,
--     unlike is_on_duty(): a superadmin visiting another alley still
--     serves in their own;
--   * no receipt in reminders_sent under 'd:<period id>' at this lead or a
--     closer one, for this start (Prague midnight of starts_on) — 0049's
--     ledger: a period moved to other dates rings again.
-- co_assignees: the others on the roster, placeholders included (they
-- serve too); notify sorts them Czech-alphabetically for the text.
create or replace function due_duty_reminders()
returns table (
  user_id uuid, email text, fcm_token text, period_id uuid,
  starts_on date, ends_on date, days smallint, co_assignees text[])
language sql stable security definer set search_path = public
as $$
  select p.id, p.email, p.fcm_token, d.id, d.starts_on, d.ends_on,
         s.duty_reminder_days,
         array(select o.display_name
                 from duty_assignments oa
                 join profiles o on o.id = oa.user_id
                where oa.period_id = d.id and oa.user_id <> p.id
                order by o.display_name)
    from duty_periods d
    join schedule_settings s on s.tenant_id = d.tenant_id
    join duty_assignments a on a.period_id = d.id
    join profiles p on p.id = a.user_id
   where s.duty_reminder_enabled
     and p.status = 'approved' and not p.placeholder and p.role <> 'kiosk'
     and d.starts_on > (now() at time zone 'Europe/Prague')::date
     and ((d.starts_on - s.duty_reminder_days) + time '18:00')
           at time zone 'Europe/Prague' <= now()
     and not exists (
       select 1 from reminders_sent r
        where r.user_id = p.id
          and r.event_key = 'd:' || d.id
          and r.offset_minutes <= s.duty_reminder_days * 1440
          and (r.starts_at is null
               or r.starts_at = d.starts_on::timestamp at time zone 'Europe/Prague'))
   order by d.starts_on, p.id;
$$;
revoke all on function due_duty_reminders() from public, anon, authenticated;
grant execute on function due_duty_reminders() to service_role;

-- The tick's gate (0040) wakes for a due duty reminder too; otherwise the
-- same body. notify's CRON branch sends them after the other reminders.
create or replace function notifications_due()
returns boolean
language sql stable security definer set search_path = public
as $$
  select exists (select 1 from notification_jobs where run_at <= now())
      or exists (select 1 from due_reminders())
      or exists (select 1 from due_duty_reminders());
$$;
revoke all on function notifications_due() from public, anon, authenticated;
grant execute on function notifications_due() to service_role;
