-- 0040 — připomínka N hodin/dní před tréninkem nebo zápasem.
--
-- Kdo má propojený Google kalendář, dostane upozornění od Googlu — nastaví
-- si je u kalendáře (0032, reminder_minutes). Kdo Google nechce, neměl
-- dosud nic: appka hlásí jen to, co se STALO (zrušený trénink, rezervace z
-- kiosku), ne to, co se BLÍŽÍ. Tohle je ta druhá půlka a nastavuje se
-- stejně: pár předstihů, „2 h předem", „1 den předem".
--
-- Kanál se nevolí: jde tou samou cestou jako zrušený trénink — push, kdo
-- má appku v telefonu, e-mail všem ostatním (notifyRecipient). Proto tu
-- není žádná podmínka na fcm_token; funkce vrací e-mail i token a rozhodne
-- se až v notify, na jednom místě pro všechny zprávy.
--
-- Nezávisle na Googlu: kdo chce obojí, má obojí. Appka o Googlových
-- připomínkách nic nepředpokládá — ony jsou jeho, tyhle naše.
--
-- ---------------------------------------------------------------------------
-- Proč tu nejsou naplánované joby
-- ---------------------------------------------------------------------------
-- Plánovat řádek do notification_jobs na (začátek − předstih) by znamenalo
-- přeplánovat ho pokaždé, když se cokoli pohne: rezervace zrušena, blok
-- přečasován, zápas přeložen, tým odebrán, výjimka zapnuta, předstihy
-- změněny. Šest triggerů, které musí souhlasit, a jeden zapomenutý znamená
-- připomínku na trénink, který už není.
--
-- Místo toho se nic neplánuje: due_push_reminders() se každou minutu zeptá,
-- co je PRÁVĚ TEĎ splatné, podle dat, jak vypadají teď. Zrušená rezervace v
-- odpovědi prostě není; změněný předstih platí od příštího tiku. Jediný
-- stav, který si to nese, je push_reminders_sent — aby se totéž neposlalo
-- dvakrát, když tik doběhne dvakrát nebo se odeslání opakuje.

alter table profiles
  add column notify_before_minutes integer[] not null default '{}'
    -- Same bounds and the same shape as google_calendar_links (0023): a
    -- CHECK cannot hold a subquery, so the range is an ALL over the array.
    check (coalesce(array_length(notify_before_minutes, 1), 0) <= 5
           and 0 <= all (notify_before_minutes)
           and 40320 >= all (notify_before_minutes));
comment on column profiles.notify_before_minutes is
  'Minutes before a training or a match to send the player a reminder (0040) — up to five, each 0 to 40320 (four weeks), the same bounds google_calendar_links.reminder_minutes uses (deliberately a different name: that one tells GOOGLE when to ring, this one tells us). Empty = no reminders. The channel is the app''s usual one — push where there is a device, e-mail otherwise.';

-- Own row only (profiles_update_own), joining the other preference columns.
grant update (notify_before_minutes) on profiles to authenticated;

-- ---------------------------------------------------------------------------
-- Co už bylo odesláno
-- ---------------------------------------------------------------------------
-- event_key je 'r:<uuid>' pro rezervaci a 'm:<uuid>' pro zápas — jeden
-- sloupec místo dvou nullable cizích klíčů a checku, který by je hlídal.
-- Řádek nemá cizí klíč na akci, a proto ani kaskádu: sběrný úklid v tiku
-- maže cokoli staršího 30 dnů, což je po vší práci zadarmo.
create table reminders_sent (
  user_id        uuid not null references profiles(id) on delete cascade,
  event_key      text not null,
  offset_minutes integer not null,
  sent_at        timestamptz not null default now(),
  primary key (user_id, event_key, offset_minutes)
);
comment on table reminders_sent is
  'Which reminders have already gone out (0040), so a repeated tick or a retried send does not ring twice. Server-only; pruned after 30 days by the tick itself.';

alter table reminders_sent enable row level security;
-- No policy at all: nobody but service_role reads or writes this.
revoke all on reminders_sent from anon, authenticated;

-- ---------------------------------------------------------------------------
-- my_upcoming_matches: zápasy, které hráč vidí v Můj přehled
-- ---------------------------------------------------------------------------
-- Serverový protějšek toho, co upcomingTimeline počítá v appce: sledované
-- týmy plus přidané výjimky, minus skryté (0039). Není to my_future_matches
-- — ta je o Google kalendáři, čte calendar_teams a bez propojeného
-- kalendáře nevrátí nic. Tahle je o přehledu, a ten má i ten, kdo Google
-- nemá.
create or replace function my_upcoming_matches(p_user uuid)
returns table (
  match_id uuid, date date, starts_at time, ends_at time,
  home_team text, away_team text, is_away boolean, description text)
language sql stable security definer set search_path = public
as $$
  select s.id, s.date, s.starts_at, s.ends_at,
         s.home_team, s.away_team, s.is_away, s.description
    from priority_slots s
    join priority_slot_types y on y.id = s.type_id and y.is_match
    join profiles p on p.id = p_user and p.tenant_id = s.tenant_id
    left join match_exceptions e on e.user_id = p_user and e.match_id = s.id
    where s.parent_id is null
      and s.date >= (now() at time zone 'Europe/Prague')::date
      and coalesce(
            e.shown,
            p.followed_teams && array[s.home_team, s.away_team])
    order by s.date, s.starts_at;
$$;
revoke all on function my_upcoming_matches(uuid) from public, anon, authenticated;
grant execute on function my_upcoming_matches(uuid) to service_role;

-- ---------------------------------------------------------------------------
-- due_push_reminders: co je právě teď na řadě
-- ---------------------------------------------------------------------------
-- Jeden řádek = jedna push, kterou má notify odeslat. Text si složí sama
-- (má na to _shared/format.ts); tahle funkce vrací fakta.
--
-- „Splatné" je (začátek − předstih) <= teď, a zároveň akce ještě
-- nezačala: po výpadku má smysl doručit připomínku pozdě („za 20 minut"),
-- ne připomínat trénink, který už běží.
create or replace function due_reminders()
returns table (
  user_id uuid, email text, fcm_token text, event_key text,
  offset_minutes integer, kind text, starts_at timestamptz, ends_at time,
  lane smallint, alley_name text, home_team text, away_team text,
  is_away boolean)
language sql stable security definer set search_path = public
as $$
  with people as (
    -- No fcm_token condition: a player without the app is reachable by
    -- e-mail, and notify picks the channel for every message the same way.
    select p.id, p.email, p.fcm_token, p.notify_before_minutes
      from profiles p
      where p.status = 'approved'
        and not p.placeholder  -- hráč bez účtu se nikam nepřihlašuje
        and coalesce(array_length(p.notify_before_minutes, 1), 0) > 0
  ),
  events as (
    select pe.id as user_id, pe.email, pe.fcm_token, pe.notify_before_minutes,
           'training' as kind,
           'r:' || r.reservation_id as event_key,
           ((r.date + r.starts_at) at time zone 'Europe/Prague') as starts_ts,
           r.ends_at, r.lane, r.alley_name,
           null::text as home_team, null::text as away_team,
           null::boolean as is_away
      from people pe
      cross join lateral my_future_reservations(pe.id) r
    union all
    select pe.id, pe.email, pe.fcm_token, pe.notify_before_minutes,
           'match',
           'm:' || m.match_id,
           ((m.date + m.starts_at) at time zone 'Europe/Prague'),
           m.ends_at, null::smallint, null::text,
           m.home_team, m.away_team, m.is_away
      from people pe
      cross join lateral my_upcoming_matches(pe.id) m
  )
  select e.user_id, e.email, e.fcm_token, e.event_key, o.offset_minutes::integer,
         e.kind, e.starts_ts, e.ends_at, e.lane, e.alley_name,
         e.home_team, e.away_team, e.is_away
    from events e
    cross join lateral unnest(e.notify_before_minutes) as o(offset_minutes)
    where e.starts_ts > now()
      and e.starts_ts - make_interval(mins => o.offset_minutes) <= now()
      and not exists (
        select 1 from reminders_sent s
        where s.user_id = e.user_id
          and s.event_key = e.event_key
          and s.offset_minutes = o.offset_minutes
      )
    order by e.starts_ts;
$$;
revoke all on function due_reminders() from public, anon, authenticated;
grant execute on function due_reminders() to service_role;

-- ---------------------------------------------------------------------------
-- Tik: posílá se i kvůli připomínkám
-- ---------------------------------------------------------------------------
-- Stejné tělo jako 0023, jen podmínka „je co dělat" zná i připomínky —
-- notify si v CRON větvi vezme obojí. Bez toho by minutový tik mlčel,
-- protože ve frontě jobů nic není.
--
-- Podmínka je vlastní funkce, aby šla ověřit: bez nastaveného Vaultu se
-- tik k odeslání nedostane, takže na samotném volání nejde poznat, jestli
-- bránu prošel, nebo se otočil na prahu.
create or replace function notifications_due()
returns boolean
language sql stable security definer set search_path = public
as $$
  select exists (select 1 from notification_jobs where run_at <= now())
      or exists (select 1 from due_reminders());
$$;
revoke all on function notifications_due() from public, anon, authenticated;
grant execute on function notifications_due() to service_role;

create or replace function trigger_notification_jobs()
returns void
language plpgsql security definer set search_path = public
as $$
declare
  v_url text;
  v_secret text;
begin
  if not notifications_due() then
    return;
  end if;
  select c.url, c.secret into v_url, v_secret from notify_webhook_config() c;
  if v_url is null or v_secret is null then
    raise warning 'trigger_notification_jobs: vault secrets notify_url / webhook_secret missing, due jobs not dispatched';
    return;
  end if;
  perform net.http_post(
    url := v_url,
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'x-webhook-secret', v_secret
    ),
    body := '{"type":"CRON","table":"notification_jobs","record":null,"old_record":null}'::jsonb
  );
end;
$$;

-- ---------------------------------------------------------------------------
-- Zápis do účtenky + úklid
-- ---------------------------------------------------------------------------
-- notify volá tohle po ÚSPĚŠNÉM odeslání. Úklid je tu schválně: účtenka
-- nemá cizí klíč na akci (viz komentář u tabulky), takže starý řádek nemá
-- kdo smazat.
create or replace function mark_reminder_sent(
  p_user uuid, p_event_key text, p_offset integer)
returns void
language plpgsql security definer set search_path = public
as $$
begin
  insert into reminders_sent (user_id, event_key, offset_minutes)
  values (p_user, p_event_key, p_offset)
  on conflict (user_id, event_key, offset_minutes) do nothing;
  delete from reminders_sent where sent_at < now() - interval '30 days';
end;
$$;
revoke all on function mark_reminder_sent(uuid, text, integer)
  from public, anon, authenticated;
grant execute on function mark_reminder_sent(uuid, text, integer)
  to service_role;
