-- 0039 — match_exceptions: „tenhle zápas hraju".
--
-- Hráč nižšího týmu občas nastoupí za vyšší — dorost za muže, béčko za
-- áčko. Ten JEDEN zápas je jeho, i když tým jinak nesleduje: má ho vidět v
-- Můj přehled a má mu přijít do hlavního Google kalendáře. Dosud to šlo jen
-- přes celý tým, což znamená i všechny ostatní jeho zápasy.
--
-- Výjimka je proto (hráč, zápas), ne (hráč, tým). Sloupec calendar je dnes
-- vždy 'primary' — kdo hraje, chce to v hlavním kalendáři, ne v tom na
-- koukání — ale stojí tu proto, že volba mezi kalendáři už v appce existuje
-- (calendar_teams) a až ji tu někdo bude chtít, bude kam ji uložit.
--
-- Zápis jde přes set_match_exception: tabulka je pro klienta jen ke čtení,
-- stejně jako calendar_teams (0035) a team_colors (0037), protože zápis
-- rozjíždí práci v Googlu. Ta se ale — na rozdíl od výběru týmů — nedělá
-- hned v requestu: výjimka je jeden zápas, jede přes stejné joby jako
-- přeložený zápas v rozpisu (0027) a dorazí do pár minut.

create table match_exceptions (
  user_id  uuid not null references profiles(id) on delete cascade,
  match_id uuid not null references priority_slots(id) on delete cascade,
  calendar text not null default 'primary'
    check (calendar in ('primary', 'secondary')),
  primary key (user_id, match_id)
);
comment on table match_exceptions is
  'One row per player+match the player plays as a guest (0039): the match counts as theirs even though neither of its teams is in their lists — it shows in Můj přehled and goes to the calendar named here. Read-only to the client; every write goes through set_match_exception, whose trigger queues the calendar job.';
comment on column match_exceptions.calendar is
  'Which Google calendar the match goes to, overriding whatever calendar_teams would say. Always ''primary'' today (the app offers no choice): a match you are playing belongs in the calendar you live by.';

alter table match_exceptions enable row level security;
create policy match_exceptions_own on match_exceptions
  for select using (user_id = auth.uid());
-- 0017's default privileges hand out DML to authenticated; this table is
-- server-written like calendar_teams (0035) and team_colors (0037).
revoke insert, update, delete on match_exceptions from authenticated;

alter publication supabase_realtime add table match_exceptions;

-- ---------------------------------------------------------------------------
-- set_match_exception: the one way in, called straight from the app.
-- ---------------------------------------------------------------------------
-- Client-callable (unlike the calendar RPCs, which only calendar-manage may
-- call): it writes nothing but the player's own row, and the app needs the
-- answer at once — the Google side follows through the job queue.
create or replace function set_match_exception(p_match uuid, p_on boolean)
returns void
language plpgsql security definer set search_path = public
as $$
declare
  v_slot priority_slots%rowtype;
begin
  if auth.uid() is null then
    raise exception 'not_authenticated';
  end if;
  -- The kiosk is the alley's tablet, not a player; a pending profile has no
  -- business in anyone's calendar yet.
  if not is_approved() or is_kiosk() then
    raise exception 'not_allowed';
  end if;

  select * into v_slot from priority_slots
   where id = p_match and tenant_id = current_tenant_id();
  if not found
     or v_slot.parent_id is not null
     or not exists (select 1 from priority_slot_types
                    where id = v_slot.type_id and is_match) then
    raise exception 'unknown_match';
  end if;
  if v_slot.date < (now() at time zone 'Europe/Prague')::date then
    raise exception 'match_past';
  end if;

  if p_on then
    insert into match_exceptions (user_id, match_id)
    values (auth.uid(), p_match)
    on conflict (user_id, match_id) do nothing;
  else
    delete from match_exceptions
     where user_id = auth.uid() and match_id = p_match;
  end if;
end;
$$;
revoke all on function set_match_exception(uuid, boolean) from public, anon;
grant execute on function set_match_exception(uuid, boolean)
  to authenticated, service_role;

-- ---------------------------------------------------------------------------
-- Jobs: an exception is a calendar change like any other.
-- ---------------------------------------------------------------------------
-- Switched on, switched off, or gone with its match (the cascade above
-- fires this on DELETE too) — either way the handler re-reads
-- my_future_matches and writes or deletes the event. The dedupe key is
-- (player, match), so toggling twice before the queue runs is one job.
create or replace function match_exceptions_enqueue_calendar()
returns trigger
language plpgsql security definer set search_path = public
as $$
begin
  perform enqueue_match_calendar_sync(
    coalesce(new.user_id, old.user_id),
    coalesce(new.match_id, old.match_id));
  return coalesce(new, old);
end;
$$;
create trigger match_exceptions_enqueue_calendar
  after insert or update or delete on match_exceptions
  for each row execute function match_exceptions_enqueue_calendar();

-- The match itself moving (re-timed, renamed, deleted) must reach the
-- exception holder as well — match_calendar_followers only knows
-- calendar_teams, and the whole point of an exception is a player who
-- follows neither team. Same body as 0027 otherwise.
create or replace function priority_slots_enqueue_calendar()
returns trigger
language plpgsql security definer set search_path = public
as $$
begin
  if tg_op in ('UPDATE', 'DELETE') and old.parent_id is null
     and exists (select 1 from priority_slot_types
                 where id = old.type_id and is_match) then
    perform enqueue_match_calendar_sync(u, old.id)
      from match_calendar_followers(
        old.tenant_id, old.home_team, old.away_team) u;
  end if;
  if tg_op in ('INSERT', 'UPDATE') and new.parent_id is null
     and exists (select 1 from priority_slot_types
                 where id = new.type_id and is_match) then
    perform enqueue_match_calendar_sync(u, new.id)
      from match_calendar_followers(
        new.tenant_id, new.home_team, new.away_team) u;
  end if;
  -- Whoever holds an exception on this match, followed teams or not. On
  -- DELETE the cascade has usually emptied this already (and the trigger
  -- above has queued the job) — then this finds nothing, which is the
  -- right answer either way.
  perform enqueue_match_calendar_sync(e.user_id, coalesce(new.id, old.id))
    from match_exceptions e where e.match_id = coalesce(new.id, old.id);
  return coalesce(new, old);
end;
$$;

-- ---------------------------------------------------------------------------
-- my_future_matches: an exception is a match of one's own.
-- ---------------------------------------------------------------------------
-- The lateral join over calendar_teams stops being the filter (it becomes a
-- LEFT join) — a match now qualifies through a followed team OR an
-- exception, and the exception also decides the calendar, overriding what
-- the team would have said. Colour: a followed team's own, otherwise the
-- colour the player gave OUR team of that match (is_away says which side is
-- ours), the same rule lib/domain/upcoming.dart's matchColorOf follows.
-- Return shape unchanged, so create or replace keeps the grants.
create or replace function my_future_matches(p_user uuid)
returns table (
  match_id uuid, date date, starts_at time, ends_at time,
  home_team text, away_team text, is_away boolean, description text,
  alley_name text, calendar text, color_id smallint)
language sql stable security definer set search_path = public
as $$
  select s.id, s.date, s.starts_at, s.ends_at,
         s.home_team, s.away_team, s.is_away, s.description, t.name,
         coalesce(e.calendar, c.calendar), tc.color_id
    from priority_slots s
    join priority_slot_types y on y.id = s.type_id and y.is_match
    join tenants t on t.id = s.tenant_id
    join profiles p on p.id = p_user and p.tenant_id = s.tenant_id
    join google_calendar_links l on l.user_id = p_user
    left join lateral (
      select ct.team, ct.calendar
        from calendar_teams ct
        where ct.user_id = p_user and ct.team in (s.home_team, s.away_team)
        order by (ct.team = s.home_team) desc
        limit 1
    ) c on true
    left join match_exceptions e
      on e.user_id = p_user and e.match_id = s.id
    left join team_colors tc
      on tc.user_id = p_user
     and tc.team = coalesce(
           c.team,
           case when s.is_away then s.away_team else s.home_team end)
    where s.parent_id is null
      and s.date >= (now() at time zone 'Europe/Prague')::date
      and (c.team is not null or e.match_id is not null)
    order by s.date, s.starts_at;
$$;
revoke all on function my_future_matches(uuid) from public, anon, authenticated;
grant execute on function my_future_matches(uuid) to service_role;
