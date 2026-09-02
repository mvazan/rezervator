


SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;


CREATE SCHEMA IF NOT EXISTS "public";


ALTER SCHEMA "public" OWNER TO "pg_database_owner";


COMMENT ON SCHEMA "public" IS 'standard public schema';



CREATE OR REPLACE FUNCTION "public"."admin_list_tenants"() RETURNS TABLE("id" "uuid", "name" "text", "status" "text", "founder_email" "text", "created_at" timestamp with time zone, "approved_at" timestamp with time zone, "member_count" bigint)
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
begin
  if not is_superadmin() then
    raise exception 'not_allowed';
  end if;
  return query
  select t.id, t.name, t.status, t.founder_email, t.created_at,
         t.approved_at, count(p.id)
  from tenants t
  left join profiles p on p.tenant_id = t.id
  group by t.id
  order by (t.status = 'pending') desc, t.created_at desc;
end;
$$;


ALTER FUNCTION "public"."admin_list_tenants"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."approve_player"("p_user_id" "uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
begin
  if not is_admin() then
    raise exception 'not_allowed';
  end if;

  update profiles
  set status = 'approved', approved_by = auth.uid(), approved_at = now()
  where id = p_user_id and status = 'pending'
    and tenant_id = current_tenant_id();
end;
$$;


ALTER FUNCTION "public"."approve_player"("p_user_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."approve_tenant"("p_tenant_id" "uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
begin
  if not is_superadmin() then
    raise exception 'not_allowed';
  end if;
  update tenants
  set status = 'approved', approved_at = now()
  where id = p_tenant_id;
  if not found then
    raise exception 'unknown_tenant';
  end if;
end;
$$;


ALTER FUNCTION "public"."approve_tenant"("p_tenant_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."block_day_status"("p_tenant" "uuid", "p_date" "date", "p_block_id" "uuid") RETURNS "text"
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  select case
    when b.id is null then 'unknown_block'
    when o.tenant_id is not null and o.closed then 'day_closed'
    when o.tenant_id is not null then
      case
        when o.block_ids is null then
          case when b.active then 'open' else 'invalid_block' end
        when p_block_id = any (o.block_ids) then 'open'
        else 'invalid_block'
      end
    when not (extract(isodow from p_date)::smallint
              = any (s.training_weekdays)) then 'day_closed'
    when b.active then 'open'
    else 'invalid_block'
  end
  from schedule_settings s
  left join time_blocks b
    on b.id = p_block_id and b.tenant_id = s.tenant_id
  left join day_overrides o
    on o.tenant_id = s.tenant_id and o.date = p_date
  where s.tenant_id = p_tenant;
$$;


ALTER FUNCTION "public"."block_day_status"("p_tenant" "uuid", "p_date" "date", "p_block_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."cancel_block_day_reservations"("p_date" "date", "p_block" "uuid", "p_note" "text" DEFAULT 'změna rozvrhu'::"text") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
begin
  if not is_admin() then
    raise exception 'not_allowed';
  end if;
  if not exists (
    select 1 from time_blocks
    where id = p_block and tenant_id = current_tenant_id()
  ) then
    raise exception 'unknown_block';
  end if;

  update reservations
  set cancelled_at = now(),
      cancelled_via = 'admin',
      cancel_note = coalesce(nullif(trim(p_note), ''), 'změna rozvrhu'),
      notify_player = true,
      notify_message = null
  where date = p_date
    and block_id = p_block
    and cancelled_at is null
    and tenant_id = current_tenant_id();
end;
$$;


ALTER FUNCTION "public"."cancel_block_day_reservations"("p_date" "date", "p_block" "uuid", "p_note" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."cancel_res_for_priority"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
begin
  perform cancel_res_for_priority_slot(new);
  return new;
end;
$$;


ALTER FUNCTION "public"."cancel_res_for_priority"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."current_tenant_id"() RETURNS "uuid"
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$ select tenant_id from profiles where id = auth.uid() $$;


ALTER FUNCTION "public"."current_tenant_id"() OWNER TO "postgres";

SET default_tablespace = '';

SET default_table_access_method = "heap";


CREATE TABLE IF NOT EXISTS "public"."priority_slots" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "date" "date" NOT NULL,
    "starts_at" time without time zone NOT NULL,
    "ends_at" time without time zone NOT NULL,
    "away_team" "text" DEFAULT ''::"text" NOT NULL,
    "description" "text" DEFAULT ''::"text" NOT NULL,
    "import_key" "text",
    "created_by" "uuid" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "home_team" "text" DEFAULT ''::"text" NOT NULL,
    "prep_minutes" smallint DEFAULT 0 NOT NULL,
    "type_id" "uuid" NOT NULL,
    "tenant_id" "uuid" DEFAULT "public"."current_tenant_id"() NOT NULL,
    "parent_id" "uuid",
    "is_away" boolean DEFAULT false NOT NULL,
    CONSTRAINT "matches_check" CHECK (("ends_at" > "starts_at")),
    CONSTRAINT "matches_prep_minutes_check" CHECK ((("prep_minutes" >= 0) AND ("prep_minutes" <= 240)))
);


ALTER TABLE "public"."priority_slots" OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."cancel_res_for_priority_slot"("p_slot" "public"."priority_slots") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_type priority_slot_types;
begin
  if coalesce(p_slot.is_away, false) then
    return;
  end if;
  select * into v_type from priority_slot_types where id = p_slot.type_id;
  update reservations r
  set cancelled_at = now(), cancelled_via = 'admin',
      cancel_note = case when v_type.is_match
                         then 'zápas: ' || p_slot.away_team
                         else v_type.name end,
      notify_player = true,
      notify_message = null
  from time_blocks b
  where r.block_id = b.id
    and r.tenant_id = p_slot.tenant_id
    and r.cancelled_at is null
    and r.date >= (now() at time zone 'Europe/Prague')::date
    and r.date = p_slot.date
    and (v_type.lanes is null or r.lane = any (v_type.lanes))
    and p_slot.starts_at < b.ends_at
    and p_slot.ends_at > b.starts_at;
end;
$$;


ALTER FUNCTION "public"."cancel_res_for_priority_slot"("p_slot" "public"."priority_slots") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."cancel_res_for_rental"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_row rentals;
  v_old_date date;
  v_today date := (now() at time zone 'Europe/Prague')::date;
begin
  if tg_op = 'DELETE' then
    if old.parent_id is null then
      return old;
    end if;
    v_row := old;
  else
    v_row := new;
    if tg_op = 'UPDATE' then
      v_old_date := old.date;
    end if;
  end if;

  update reservations r
  set cancelled_at = now(), cancelled_via = 'admin',
      cancel_note = 'pronájem: ' || x.renter_name,
      notify_player = true,
      notify_message = null
  from (
    select r2.id, o.renter_name
    from reservations r2
    join time_blocks b on b.id = r2.block_id
    cross join lateral rental_occurrences(v_row.tenant_id, r2.date) o
    where r2.tenant_id = v_row.tenant_id
      and r2.cancelled_at is null
      and r2.date >= v_today
      and (v_row.parent_id is null            -- series: every date from today on
           or r2.date = v_row.date             -- exception: its date
           or r2.date = v_old_date)            -- …and the date it left
      and o.rental_id = coalesce(v_row.parent_id, v_row.id)
      and r2.lane = any (o.lanes)
      and b.starts_at < o.ends_at and b.ends_at > o.starts_at
  ) x
  where r.id = x.id;

  return coalesce(new, old);
end;
$$;


ALTER FUNCTION "public"."cancel_res_for_rental"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."cancel_res_for_type_change"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_slot priority_slots;
begin
  for v_slot in
    select * from priority_slots
    where type_id = new.id
      and date >= (now() at time zone 'Europe/Prague')::date
  loop
    perform cancel_res_for_priority_slot(v_slot);
  end loop;
  return new;
end;
$$;


ALTER FUNCTION "public"."cancel_res_for_type_change"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."cancel_reservation"("p_id" "uuid", "p_note" "text" DEFAULT ''::"text", "p_notify" boolean DEFAULT true) RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
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
  elsif v_res.player_id = v_uid and v_caller.status = 'approved' then
    select * into v_block from time_blocks where id = v_res.block_id;
    v_starts := (v_res.date + v_block.starts_at) at time zone 'Europe/Prague';
    if v_now >= v_starts then
      raise exception 'too_late';
    end if;
    v_via := 'app';
  else
    raise exception 'not_allowed';
  end if;

  update reservations
  set cancelled_at = v_now, cancelled_via = v_via,
      cancel_note = trim(coalesce(p_note, '')),
      notify_player = coalesce(p_notify, true),
      notify_message = null
  where id = p_id;
end;
$$;


ALTER FUNCTION "public"."cancel_reservation"("p_id" "uuid", "p_note" "text", "p_notify" boolean) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."cancel_stranded_reservations"("p_tenant" "uuid", "p_note" "text" DEFAULT 'změna rozvrhu'::"text") RETURNS integer
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_today date := (now() at time zone 'Europe/Prague')::date;
  v_now time := (now() at time zone 'Europe/Prague')::time;
  v_count integer;
begin
  with stranded as (
    update reservations r
    set cancelled_at = now(), cancelled_via = 'admin',
        cancel_note = coalesce(nullif(trim(p_note), ''), 'změna rozvrhu'),
        notify_player = true, notify_message = null
    from time_blocks b, schedule_settings s
    where b.id = r.block_id
      and s.tenant_id = r.tenant_id
      and r.tenant_id = p_tenant
      and r.cancelled_at is null
      and (r.date > v_today or (r.date = v_today and b.starts_at > v_now))
      and (r.lane > s.lane_count
           or block_day_status(r.tenant_id, r.date, r.block_id) <> 'open')
    returning 1
  )
  select count(*) into v_count from stranded;
  return v_count;
end;
$$;


ALTER FUNCTION "public"."cancel_stranded_reservations"("p_tenant" "uuid", "p_note" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."cascade_schedule_change"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
begin
  -- to_jsonb: plpgsql resolves record fields per table, and only
  -- day_overrides has a reason column.
  perform cancel_stranded_reservations(
    coalesce(new.tenant_id, old.tenant_id),
    case when tg_table_name = 'day_overrides' and tg_op <> 'DELETE'
         then to_jsonb(new)->>'reason' else 'změna rozvrhu' end);
  return coalesce(new, old);
end;
$$;


ALTER FUNCTION "public"."cascade_schedule_change"() OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."reservations" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "player_id" "uuid" NOT NULL,
    "date" "date" NOT NULL,
    "block_id" "uuid" NOT NULL,
    "lane" smallint NOT NULL,
    "created_via" "text" NOT NULL,
    "created_by" "uuid" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "cancelled_at" timestamp with time zone,
    "cancelled_via" "text",
    "cancel_note" "text" DEFAULT ''::"text" NOT NULL,
    "tenant_id" "uuid" NOT NULL,
    "notify_player" boolean DEFAULT true NOT NULL,
    "notify_message" "text",
    CONSTRAINT "reservations_cancelled_via_check" CHECK (("cancelled_via" = ANY (ARRAY['app'::"text", 'one_click'::"text", 'admin'::"text"]))),
    CONSTRAINT "reservations_created_via_check" CHECK (("created_via" = ANY (ARRAY['app'::"text", 'kiosk'::"text", 'admin'::"text"]))),
    CONSTRAINT "reservations_lane_check" CHECK (("lane" >= 1))
);


ALTER TABLE "public"."reservations" OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."create_reservation"("p_player_id" "uuid", "p_date" "date", "p_block_id" "uuid", "p_lane" smallint) RETURNS "public"."reservations"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
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
      raise exception 'limit_reached';
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


ALTER FUNCTION "public"."create_reservation"("p_player_id" "uuid", "p_date" "date", "p_block_id" "uuid", "p_lane" smallint) OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."profiles" (
    "id" "uuid" NOT NULL,
    "display_name" "text" NOT NULL,
    "email" "text" DEFAULT ''::"text" NOT NULL,
    "role" "text" DEFAULT 'player'::"text" NOT NULL,
    "status" "text" DEFAULT 'pending'::"text" NOT NULL,
    "fcm_token" "text",
    "approved_by" "uuid",
    "approved_at" timestamp with time zone,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "nick" "text" DEFAULT ''::"text" NOT NULL,
    "club_id" "uuid",
    "tenant_id" "uuid" NOT NULL,
    "superadmin" boolean DEFAULT false NOT NULL,
    "home_tenant_id" "uuid",
    CONSTRAINT "profiles_nick_check" CHECK (("char_length"("nick") <= 14)),
    CONSTRAINT "profiles_role_check" CHECK (("role" = ANY (ARRAY['player'::"text", 'admin'::"text", 'kiosk'::"text"]))),
    CONSTRAINT "profiles_status_check" CHECK (("status" = ANY (ARRAY['pending'::"text", 'approved'::"text"])))
);


ALTER TABLE "public"."profiles" OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."create_tenant_and_register"("p_tenant_name" "text", "p_display_name" "text", "p_nick" "text" DEFAULT ''::"text") RETURNS "public"."profiles"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_uid uuid := auth.uid();
  v_profile profiles;
  v_tenant_id uuid;
begin
  if v_uid is null then
    raise exception 'not_authenticated';
  end if;

  -- An existing profile means the caller already belongs to an alley; bail
  -- out before creating a tenant nobody would live in.
  select * into v_profile from profiles where id = v_uid;
  if found then
    return v_profile;
  end if;

  if trim(p_tenant_name) = '' then
    raise exception 'empty_tenant_name';
  end if;

  begin
    insert into tenants (name, founder_email)
    values (trim(p_tenant_name), nullif(lower(coalesce(auth.email(), '')), ''))
    returning id into v_tenant_id;
  exception when unique_violation then
    raise exception 'tenant_exists';
  end;

  return register_profile(p_display_name, v_tenant_id, null, p_nick);
end;
$$;


ALTER FUNCTION "public"."create_tenant_and_register"("p_tenant_name" "text", "p_display_name" "text", "p_nick" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."delete_club"("p_id" "uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
begin
  if not is_admin() then raise exception 'not_allowed'; end if;
  delete from clubs
  where id = p_id and tenant_id = current_tenant_id();
end; $$;


ALTER FUNCTION "public"."delete_club"("p_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."is_admin"() RETURNS boolean
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  select exists (
    select 1 from profiles
    where id = auth.uid() and role = 'admin' and status = 'approved'
  );
$$;


ALTER FUNCTION "public"."is_admin"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."is_approved"() RETURNS boolean
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  select exists (
    select 1 from profiles where id = auth.uid() and status = 'approved'
  );
$$;


ALTER FUNCTION "public"."is_approved"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."is_approved_or_kiosk"() RETURNS boolean
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  select exists (
    select 1 from profiles
    where id = auth.uid() and (status = 'approved' or role = 'kiosk')
  );
$$;


ALTER FUNCTION "public"."is_approved_or_kiosk"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."is_kiosk"() RETURNS boolean
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  select exists (
    select 1 from profiles where id = auth.uid() and role = 'kiosk'
  );
$$;


ALTER FUNCTION "public"."is_kiosk"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."is_superadmin"() RETURNS boolean
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  select coalesce(
    (select superadmin from profiles where id = auth.uid()), false);
$$;


ALTER FUNCTION "public"."is_superadmin"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."monthly_attendance"("p_year" integer, "p_month" integer) RETURNS TABLE("player_id" "uuid", "display_name" "text", "club" "text", "attended" bigint)
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
begin
  if not is_admin() then
    raise exception 'not_allowed';
  end if;

  return query
  select p.id, p.display_name, coalesce(c.name, ''), count(r.id)
  from profiles p
  left join clubs c on c.id = p.club_id
  join reservations r on r.player_id = p.id
  where p.tenant_id = current_tenant_id()
    and not (p.superadmin
             and p.home_tenant_id is not null
             and p.tenant_id <> p.home_tenant_id)
    and r.cancelled_at is null
    and extract(year from r.date)::int = p_year
    and extract(month from r.date)::int = p_month
    and r.date <= (now() at time zone 'Europe/Prague')::date
  group by p.id, p.display_name, coalesce(c.name, '')
  order by count(r.id) desc, p.display_name;
end;
$$;


ALTER FUNCTION "public"."monthly_attendance"("p_year" integer, "p_month" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."move_day_reservations"("p_date" "date", "p_from_block" "uuid", "p_to_block" "uuid", "p_notify" boolean DEFAULT true, "p_message" "text" DEFAULT NULL::"text") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
begin
  if not is_admin() then
    raise exception 'not_allowed';
  end if;

  if not exists (
    select 1 from time_blocks
    where id = p_from_block and tenant_id = current_tenant_id()
  ) or not exists (
    select 1 from time_blocks
    where id = p_to_block and tenant_id = current_tenant_id()
  ) then
    raise exception 'unknown_block';
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


ALTER FUNCTION "public"."move_day_reservations"("p_date" "date", "p_from_block" "uuid", "p_to_block" "uuid", "p_notify" boolean, "p_message" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."move_reservation"("p_reservation" "uuid", "p_to_block" "uuid", "p_lane" integer, "p_notify" boolean DEFAULT true, "p_message" "text" DEFAULT NULL::"text") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_res reservations;
  v_block time_blocks;
  v_lanes int;
begin
  if not is_admin() then
    raise exception 'not_allowed';
  end if;

  select * into v_res from reservations
  where id = p_reservation and tenant_id = current_tenant_id();
  if not found or v_res.cancelled_at is not null then
    raise exception 'unknown_reservation';
  end if;

  select * into v_block from time_blocks
  where id = p_to_block and tenant_id = current_tenant_id();
  if not found then
    raise exception 'unknown_block';
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


ALTER FUNCTION "public"."move_reservation"("p_reservation" "uuid", "p_to_block" "uuid", "p_lane" integer, "p_notify" boolean, "p_message" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."notify_webhook"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_url text;
  v_secret text;
begin
  select c.url, c.secret into v_url, v_secret from notify_webhook_config() c;
  if v_url is null or v_secret is null then
    raise warning 'notify_webhook: vault secrets notify_url / webhook_secret missing, notification skipped';
    return coalesce(new, old);
  end if;
  perform net.http_post(
    url := v_url,
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'x-webhook-secret', v_secret
    ),
    body := jsonb_build_object(
      'type', tg_op,
      'table', tg_table_name,
      'schema', tg_table_schema,
      'record', case when tg_op = 'DELETE' then null else to_jsonb(new) end,
      'old_record', case when tg_op = 'INSERT' then null else to_jsonb(old) end
    )
  );
  return coalesce(new, old);
end;
$$;


ALTER FUNCTION "public"."notify_webhook"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."notify_webhook_config"() RETURNS TABLE("url" "text", "secret" "text")
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
  select
    (select decrypted_secret from vault.decrypted_secrets
      where name = 'notify_url'),
    (select decrypted_secret from vault.decrypted_secrets
      where name = 'webhook_secret');
$$;


ALTER FUNCTION "public"."notify_webhook_config"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."register_profile"("p_display_name" "text", "p_tenant_id" "uuid", "p_club_id" "uuid" DEFAULT NULL::"uuid", "p_nick" "text" DEFAULT ''::"text") RETURNS "public"."profiles"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_uid uuid := auth.uid();
  v_profile profiles;
  v_tenant tenants;
  v_first boolean;
begin
  if v_uid is null then
    raise exception 'not_authenticated';
  end if;

  select * into v_profile from profiles where id = v_uid;
  if found then
    return v_profile;
  end if;

  if trim(p_display_name) = '' then
    raise exception 'empty_display_name';
  end if;
  if char_length(trim(coalesce(p_nick, ''))) > 14 then
    raise exception 'nick_too_long';
  end if;

  select * into v_tenant from tenants where id = p_tenant_id;
  if not found then
    raise exception 'unknown_tenant';
  end if;

  if p_club_id is not null and not exists (
    select 1 from clubs where id = p_club_id and tenant_id = p_tenant_id
  ) then
    raise exception 'unknown_club';
  end if;

  -- Serialize concurrent registrations into the same tenant so exactly one
  -- founder can win the race.
  perform pg_advisory_xact_lock(
    hashtext('register_profile'), hashtext(p_tenant_id::text));

  select not exists (
    select 1 from profiles
    where tenant_id = p_tenant_id and status = 'approved'
  ) into v_first;
  if v_tenant.founder_email is not null then
    v_first := v_first
      and lower(coalesce(auth.email(), '')) = lower(v_tenant.founder_email);
  end if;

  insert into profiles
    (id, tenant_id, display_name, club_id, nick, email,
     role, status, approved_at)
  values (
    v_uid,
    p_tenant_id,
    trim(p_display_name),
    p_club_id,
    trim(coalesce(p_nick, '')),
    coalesce(auth.email(), ''),
    case when v_first then 'admin' else 'player' end,
    case when v_first then 'approved' else 'pending' end,
    case when v_first then now() end
  )
  returning * into v_profile;

  return v_profile;
end;
$$;


ALTER FUNCTION "public"."register_profile"("p_display_name" "text", "p_tenant_id" "uuid", "p_club_id" "uuid", "p_nick" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."registration_clubs"("p_tenant_id" "uuid") RETURNS TABLE("id" "uuid", "name" "text")
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  select c.id, c.name from clubs c
  where auth.uid() is not null and c.tenant_id = p_tenant_id
  order by c.name;
$$;


ALTER FUNCTION "public"."registration_clubs"("p_tenant_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."reject_tenant"("p_tenant_id" "uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_status text;
begin
  if not is_superadmin() then
    raise exception 'not_allowed';
  end if;
  if exists (
    select 1 from profiles where id = auth.uid() and tenant_id = p_tenant_id
  ) then
    raise exception 'switch_home_first';
  end if;
  select status into v_status from tenants where id = p_tenant_id;
  if not found then
    raise exception 'unknown_tenant';
  end if;
  if v_status <> 'pending' then
    raise exception 'not_pending';
  end if;

  delete from reservations where tenant_id = p_tenant_id;
  delete from priority_slots where tenant_id = p_tenant_id;
  delete from rentals where tenant_id = p_tenant_id;
  delete from day_overrides where tenant_id = p_tenant_id;
  delete from time_blocks where tenant_id = p_tenant_id;
  delete from priority_slot_types where tenant_id = p_tenant_id;
  delete from clubs where tenant_id = p_tenant_id;
  delete from profiles where tenant_id = p_tenant_id;
  delete from schedule_settings where tenant_id = p_tenant_id;
  delete from tenants where id = p_tenant_id;
end;
$$;


ALTER FUNCTION "public"."reject_tenant"("p_tenant_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."rental_exception_guard"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_parent rentals;
begin
  select * into v_parent from rentals where id = new.parent_id;
  if not found
     or new.parent_id = new.id
     or v_parent.tenant_id <> new.tenant_id
     or v_parent.parent_id is not null      -- no exception of an exception
     or v_parent.weekday is null            -- one-time rentals have no series
     or new.date is null
     or not rental_occurs(v_parent, new.date)
     or exists (select 1 from rentals where parent_id = new.id) then
    raise exception 'rental_exception_invalid';
  end if;
  new.renter_name := v_parent.renter_name;
  new.color := v_parent.color;
  return new;
end;
$$;


ALTER FUNCTION "public"."rental_exception_guard"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."rental_occurrences"("p_tenant" "uuid", "p_date" "date") RETURNS TABLE("rental_id" "uuid", "override_id" "uuid", "renter_name" "text", "lanes" smallint[], "starts_at" time without time zone, "ends_at" time without time zone)
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  select p.id, c.id, p.renter_name,
         coalesce(c.lanes, p.lanes),
         coalesce(c.starts_at, p.starts_at),
         coalesce(c.ends_at, p.ends_at)
  from rentals p
  left join rentals c
    on c.parent_id = p.id and c.tenant_id = p.tenant_id and c.date = p_date
  where p.tenant_id = p_tenant
    and p.parent_id is null
    and rental_occurs(p, p_date)
    and not coalesce(c.skipped, false);
$$;


ALTER FUNCTION "public"."rental_occurrences"("p_tenant" "uuid", "p_date" "date") OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."rentals" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "renter_name" "text" NOT NULL,
    "lanes" smallint[] NOT NULL,
    "date" "date",
    "weekday" smallint,
    "starts_at" time without time zone NOT NULL,
    "ends_at" time without time zone NOT NULL,
    "valid_from" "date",
    "valid_until" "date",
    "note" "text" DEFAULT ''::"text" NOT NULL,
    "created_by" "uuid" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "color" smallint DEFAULT '-2'::integer NOT NULL,
    "tenant_id" "uuid" DEFAULT "public"."current_tenant_id"() NOT NULL,
    "parent_id" "uuid",
    "skipped" boolean DEFAULT false NOT NULL,
    CONSTRAINT "rentals_check" CHECK (("ends_at" > "starts_at")),
    CONSTRAINT "rentals_check1" CHECK ((("date" IS NULL) <> ("weekday" IS NULL))),
    CONSTRAINT "rentals_color_check" CHECK ((("color" >= '-2'::integer) AND ("color" <= 11))),
    CONSTRAINT "rentals_exception_shape_check" CHECK ((("parent_id" IS NULL) OR (("date" IS NOT NULL) AND ("weekday" IS NULL) AND ("valid_from" IS NULL) AND ("valid_until" IS NULL)))),
    CONSTRAINT "rentals_lanes_check" CHECK (("cardinality"("lanes") > 0)),
    CONSTRAINT "rentals_skipped_check" CHECK (((NOT "skipped") OR ("parent_id" IS NOT NULL))),
    CONSTRAINT "rentals_weekday_check" CHECK ((("weekday" >= 1) AND ("weekday" <= 7)))
);


ALTER TABLE "public"."rentals" OWNER TO "postgres";


COMMENT ON COLUMN "public"."rentals"."parent_id" IS 'Exception row: overrides the series for `date`; skipped = the occurrence does not happen.';



CREATE OR REPLACE FUNCTION "public"."rental_occurs"("r" "public"."rentals", "p_date" "date") RETURNS boolean
    LANGUAGE "sql" IMMUTABLE
    AS $$
  select case
    when r.date is not null then r.date = p_date
    else r.weekday = extract(isodow from p_date)::smallint
         and (r.valid_from is null or p_date >= r.valid_from)
         and (r.valid_until is null or p_date <= r.valid_until)
  end;
$$;


ALTER FUNCTION "public"."rental_occurs"("r" "public"."rentals", "p_date" "date") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."rental_series_changed"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
begin
  if new.weekday is null then
    delete from rentals where parent_id = new.id;
  elsif old.weekday is distinct from new.weekday
     or old.valid_from is distinct from new.valid_from
     or old.valid_until is distinct from new.valid_until then
    delete from rentals c
    where c.parent_id = new.id and not rental_occurs(new, c.date);
  end if;
  if old.renter_name is distinct from new.renter_name
     or old.color is distinct from new.color then
    update rentals set renter_name = new.renter_name, color = new.color
    where parent_id = new.id;
  end if;
  return new;
end;
$$;


ALTER FUNCTION "public"."rental_series_changed"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."seed_demo_member"("p_email" "text") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_uid uuid;
begin
  select id into v_uid from auth.users where lower(email) = lower(p_email);
  if v_uid is null then
    raise exception 'No auth user for %. Create it in the dashboard first.', p_email;
  end if;
  insert into profiles (id, tenant_id, display_name, email, role, status)
  values (v_uid, '00000000-0000-0000-0000-0000000000de',
          'Recenze', p_email, 'admin', 'approved')
  on conflict (id) do update
    set tenant_id = excluded.tenant_id,
        role = 'admin',
        status = 'approved';
end;
$$;


ALTER FUNCTION "public"."seed_demo_member"("p_email" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."seed_tenant_defaults"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
begin
  insert into schedule_settings (tenant_id) values (new.id);
  insert into priority_slot_types (tenant_id, name, is_match, builtin)
  values (new.id, 'Zápas', true, true),
         (new.id, 'Úklid před zápasem', false, true);
  return new;
end;
$$;


ALTER FUNCTION "public"."seed_tenant_defaults"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."set_day_override"("p_date" "date", "p_closed" boolean, "p_reason" "text" DEFAULT ''::"text", "p_block_ids" "uuid"[] DEFAULT NULL::"uuid"[]) RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
begin
  if not is_admin() then
    raise exception 'not_allowed';
  end if;

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
  where r.date = p_date
    and r.tenant_id = current_tenant_id()
    and r.cancelled_at is null
    and (p_closed or (p_block_ids is not null and not (r.block_id = any (p_block_ids))));
end;
$$;


ALTER FUNCTION "public"."set_day_override"("p_date" "date", "p_closed" boolean, "p_reason" "text", "p_block_ids" "uuid"[]) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."set_nick"("p_user_id" "uuid", "p_nick" "text" DEFAULT ''::"text") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
begin
  if auth.uid() is null then
    raise exception 'not_authenticated';
  end if;
  if auth.uid() <> p_user_id and not is_admin() then
    raise exception 'not_allowed';
  end if;
  if char_length(trim(coalesce(p_nick, ''))) > 14 then
    raise exception 'nick_too_long';
  end if;
  update profiles set nick = trim(coalesce(p_nick, ''))
  where id = p_user_id
    and (id = auth.uid() or tenant_id = current_tenant_id());
end;
$$;


ALTER FUNCTION "public"."set_nick"("p_user_id" "uuid", "p_nick" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."set_player_club"("p_user_id" "uuid", "p_club_id" "uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
begin
  if not is_admin() then raise exception 'not_allowed'; end if;
  if p_club_id is not null and not exists (
    select 1 from clubs
    where id = p_club_id and tenant_id = current_tenant_id()
  ) then
    raise exception 'unknown_club';
  end if;
  update profiles set club_id = p_club_id
  where id = p_user_id and tenant_id = current_tenant_id();
end; $$;


ALTER FUNCTION "public"."set_player_club"("p_user_id" "uuid", "p_club_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."set_role"("p_user_id" "uuid", "p_role" "text") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
begin
  if not is_admin() then
    raise exception 'not_allowed';
  end if;
  if p_role not in ('player', 'admin', 'kiosk') then
    raise exception 'invalid_role';
  end if;
  if p_user_id = auth.uid() and p_role <> 'admin' then
    raise exception 'cannot_demote_self';
  end if;

  update profiles
  set role = p_role,
      status = case when p_role = 'kiosk' then 'approved' else status end
  where id = p_user_id and tenant_id = current_tenant_id();
end;
$$;


ALTER FUNCTION "public"."set_role"("p_user_id" "uuid", "p_role" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."switch_tenant"("p_tenant_id" "uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
begin
  if not is_superadmin() then
    raise exception 'not_allowed';
  end if;
  if not exists (select 1 from tenants where id = p_tenant_id) then
    raise exception 'unknown_tenant';
  end if;
  update profiles set tenant_id = p_tenant_id where id = auth.uid();
end;
$$;


ALTER FUNCTION "public"."switch_tenant"("p_tenant_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."sync_uklid_for_match"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_is_match boolean;
  v_uklid_type uuid;
  v_start time;
begin
  select is_match into v_is_match
  from priority_slot_types where id = new.type_id;
  if not coalesce(v_is_match, false) or new.parent_id is not null then
    return new;
  end if;

  if coalesce(new.is_away, false) or coalesce(new.prep_minutes, 0) <= 0 then
    delete from priority_slots where parent_id = new.id;
    return new;
  end if;

  select id into v_uklid_type from priority_slot_types
  where tenant_id = new.tenant_id and builtin and not is_match
    and name = 'Úklid před zápasem';
  if v_uklid_type is null then
    return new;
  end if;

  v_start := case
    when extract(epoch from new.starts_at) / 60 >= new.prep_minutes
      then new.starts_at - make_interval(mins => new.prep_minutes)
    else time '00:00'
  end;

  update priority_slots
  set date = new.date, starts_at = v_start, ends_at = new.starts_at
  where parent_id = new.id;
  if not found then
    insert into priority_slots
      (tenant_id, date, starts_at, ends_at, type_id, parent_id, created_by)
    values
      (new.tenant_id, new.date, v_start, new.starts_at, v_uklid_type,
       new.id, new.created_by);
  end if;
  return new;
end;
$$;


ALTER FUNCTION "public"."sync_uklid_for_match"() OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."clubs" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "name" "text" NOT NULL,
    "color" smallint DEFAULT '-1'::integer NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "tenant_id" "uuid" DEFAULT "public"."current_tenant_id"() NOT NULL,
    CONSTRAINT "clubs_color_check" CHECK ((("color" >= '-1'::integer) AND ("color" <= 11)))
);


ALTER TABLE "public"."clubs" OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."upsert_club"("p_id" "uuid", "p_name" "text", "p_color" smallint) RETURNS "public"."clubs"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare v clubs;
begin
  if not is_admin() then raise exception 'not_allowed'; end if;
  if trim(coalesce(p_name,'')) = '' then raise exception 'empty_name'; end if;
  if p_id is null then
    insert into clubs (tenant_id, name, color)
    values (current_tenant_id(), trim(p_name), p_color) returning * into v;
  else
    update clubs set name = trim(p_name), color = p_color
    where id = p_id and tenant_id = current_tenant_id() returning * into v;
  end if;
  return v;
end; $$;


ALTER FUNCTION "public"."upsert_club"("p_id" "uuid", "p_name" "text", "p_color" smallint) OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."day_overrides" (
    "date" "date" NOT NULL,
    "closed" boolean DEFAULT false NOT NULL,
    "reason" "text" DEFAULT ''::"text" NOT NULL,
    "block_ids" "uuid"[],
    "created_by" "uuid" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "tenant_id" "uuid" NOT NULL
);


ALTER TABLE "public"."day_overrides" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."players" AS
 SELECT "p"."id",
    "p"."display_name",
    "p"."nick",
    "p"."club_id",
    COALESCE(("c"."color")::integer, '-1'::integer) AS "club_color"
   FROM ("public"."profiles" "p"
     LEFT JOIN "public"."clubs" "c" ON (("c"."id" = "p"."club_id")))
  WHERE (("p"."status" = 'approved'::"text") AND ("p"."role" <> 'kiosk'::"text") AND ("p"."tenant_id" = "public"."current_tenant_id"()) AND (NOT ("p"."superadmin" AND ("p"."home_tenant_id" IS NOT NULL) AND ("p"."tenant_id" <> "p"."home_tenant_id"))));


ALTER VIEW "public"."players" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."priority_slot_types" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "name" "text" NOT NULL,
    "color" smallint DEFAULT '-1'::integer NOT NULL,
    "lanes" smallint[],
    "is_match" boolean DEFAULT false NOT NULL,
    "builtin" boolean DEFAULT false NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "tenant_id" "uuid" DEFAULT "public"."current_tenant_id"() NOT NULL,
    CONSTRAINT "priority_slot_types_color_check" CHECK ((("color" >= '-1'::integer) AND ("color" <= 11))),
    CONSTRAINT "priority_slot_types_lanes_check" CHECK ((("lanes" IS NULL) OR ("cardinality"("lanes") > 0)))
);


ALTER TABLE "public"."priority_slot_types" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."schedule_settings" (
    "lane_count" smallint DEFAULT 4 NOT NULL,
    "training_weekdays" smallint[] DEFAULT '{1,2,4}'::smallint[] NOT NULL,
    "booking_horizon_days" smallint DEFAULT 14 NOT NULL,
    "max_active_reservations" smallint DEFAULT 3 NOT NULL,
    "kiosk_dark" boolean DEFAULT true NOT NULL,
    "tenant_id" "uuid" NOT NULL,
    "kiosk_fit_day" boolean DEFAULT true NOT NULL,
    CONSTRAINT "schedule_settings_booking_horizon_days_check" CHECK ((("booking_horizon_days" >= 1) AND ("booking_horizon_days" <= 90))),
    CONSTRAINT "schedule_settings_lane_count_check" CHECK ((("lane_count" >= 1) AND ("lane_count" <= 12))),
    CONSTRAINT "schedule_settings_max_active_reservations_check" CHECK ((("max_active_reservations" >= 1) AND ("max_active_reservations" <= 50)))
);


ALTER TABLE "public"."schedule_settings" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."tenants" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "name" "text" NOT NULL,
    "founder_email" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "status" "text" DEFAULT 'pending'::"text" NOT NULL,
    "approved_at" timestamp with time zone,
    CONSTRAINT "tenants_status_check" CHECK (("status" = ANY (ARRAY['pending'::"text", 'approved'::"text"])))
);


ALTER TABLE "public"."tenants" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."time_blocks" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "starts_at" time without time zone NOT NULL,
    "ends_at" time without time zone NOT NULL,
    "position" smallint NOT NULL,
    "active" boolean DEFAULT true NOT NULL,
    "tenant_id" "uuid" DEFAULT "public"."current_tenant_id"() NOT NULL,
    CONSTRAINT "time_blocks_check" CHECK (("ends_at" > "starts_at"))
);


ALTER TABLE "public"."time_blocks" OWNER TO "postgres";


ALTER TABLE ONLY "public"."clubs"
    ADD CONSTRAINT "clubs_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."clubs"
    ADD CONSTRAINT "clubs_tenant_id_name_key" UNIQUE ("tenant_id", "name");



ALTER TABLE ONLY "public"."day_overrides"
    ADD CONSTRAINT "day_overrides_pkey" PRIMARY KEY ("tenant_id", "date");



ALTER TABLE ONLY "public"."priority_slots"
    ADD CONSTRAINT "matches_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."priority_slot_types"
    ADD CONSTRAINT "priority_slot_types_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."priority_slot_types"
    ADD CONSTRAINT "priority_slot_types_tenant_id_name_key" UNIQUE ("tenant_id", "name");



ALTER TABLE ONLY "public"."profiles"
    ADD CONSTRAINT "profiles_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."rentals"
    ADD CONSTRAINT "rentals_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."reservations"
    ADD CONSTRAINT "reservations_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."schedule_settings"
    ADD CONSTRAINT "schedule_settings_pkey" PRIMARY KEY ("tenant_id");



ALTER TABLE ONLY "public"."tenants"
    ADD CONSTRAINT "tenants_name_key" UNIQUE ("name");



ALTER TABLE ONLY "public"."tenants"
    ADD CONSTRAINT "tenants_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."time_blocks"
    ADD CONSTRAINT "time_blocks_pkey" PRIMARY KEY ("id");



CREATE INDEX "matches_date_idx" ON "public"."priority_slots" USING "btree" ("date");



CREATE UNIQUE INDEX "priority_slots_import_key_idx" ON "public"."priority_slots" USING "btree" ("tenant_id", "import_key");



CREATE INDEX "priority_slots_parent_idx" ON "public"."priority_slots" USING "btree" ("parent_id");



CREATE INDEX "profiles_tenant_idx" ON "public"."profiles" USING "btree" ("tenant_id");



CREATE UNIQUE INDEX "rentals_parent_date_idx" ON "public"."rentals" USING "btree" ("parent_id", "date") WHERE ("parent_id" IS NOT NULL);



CREATE INDEX "reservations_date_idx" ON "public"."reservations" USING "btree" ("date");



CREATE INDEX "reservations_player_idx" ON "public"."reservations" USING "btree" ("player_id", "date");



CREATE UNIQUE INDEX "reservations_slot_live_idx" ON "public"."reservations" USING "btree" ("date", "block_id", "lane") WHERE ("cancelled_at" IS NULL);



CREATE OR REPLACE TRIGGER "block_deactivated" AFTER UPDATE OF "active" ON "public"."time_blocks" FOR EACH ROW WHEN (("old"."active" AND (NOT "new"."active"))) EXECUTE FUNCTION "public"."cascade_schedule_change"();



CREATE OR REPLACE TRIGGER "match_uklid_sync" AFTER INSERT OR UPDATE ON "public"."priority_slots" FOR EACH ROW EXECUTE FUNCTION "public"."sync_uklid_for_match"();



CREATE OR REPLACE TRIGGER "notify_profiles" AFTER INSERT ON "public"."profiles" FOR EACH ROW EXECUTE FUNCTION "public"."notify_webhook"();



CREATE OR REPLACE TRIGGER "notify_reservations" AFTER INSERT OR UPDATE ON "public"."reservations" FOR EACH ROW EXECUTE FUNCTION "public"."notify_webhook"();



CREATE OR REPLACE TRIGGER "notify_tenants" AFTER INSERT ON "public"."tenants" FOR EACH ROW EXECUTE FUNCTION "public"."notify_webhook"();



CREATE OR REPLACE TRIGGER "override_changed" AFTER INSERT OR DELETE OR UPDATE ON "public"."day_overrides" FOR EACH ROW EXECUTE FUNCTION "public"."cascade_schedule_change"();



CREATE OR REPLACE TRIGGER "priority_conflicts" AFTER INSERT OR UPDATE ON "public"."priority_slots" FOR EACH ROW EXECUTE FUNCTION "public"."cancel_res_for_priority"();



CREATE OR REPLACE TRIGGER "rental_conflicts" AFTER INSERT OR DELETE OR UPDATE ON "public"."rentals" FOR EACH ROW EXECUTE FUNCTION "public"."cancel_res_for_rental"();



CREATE OR REPLACE TRIGGER "rental_exception_guard" BEFORE INSERT OR UPDATE ON "public"."rentals" FOR EACH ROW WHEN (("new"."parent_id" IS NOT NULL)) EXECUTE FUNCTION "public"."rental_exception_guard"();



CREATE OR REPLACE TRIGGER "rental_series_changed" AFTER UPDATE ON "public"."rentals" FOR EACH ROW WHEN (("old"."parent_id" IS NULL)) EXECUTE FUNCTION "public"."rental_series_changed"();



CREATE OR REPLACE TRIGGER "settings_shrink" AFTER UPDATE OF "lane_count", "training_weekdays" ON "public"."schedule_settings" FOR EACH ROW EXECUTE FUNCTION "public"."cascade_schedule_change"();



CREATE OR REPLACE TRIGGER "slot_type_conflicts" AFTER UPDATE ON "public"."priority_slot_types" FOR EACH ROW EXECUTE FUNCTION "public"."cancel_res_for_type_change"();



CREATE OR REPLACE TRIGGER "tenant_seed_defaults" AFTER INSERT ON "public"."tenants" FOR EACH ROW EXECUTE FUNCTION "public"."seed_tenant_defaults"();



ALTER TABLE ONLY "public"."clubs"
    ADD CONSTRAINT "clubs_tenant_id_fkey" FOREIGN KEY ("tenant_id") REFERENCES "public"."tenants"("id");



ALTER TABLE ONLY "public"."day_overrides"
    ADD CONSTRAINT "day_overrides_created_by_fkey" FOREIGN KEY ("created_by") REFERENCES "public"."profiles"("id");



ALTER TABLE ONLY "public"."day_overrides"
    ADD CONSTRAINT "day_overrides_tenant_id_fkey" FOREIGN KEY ("tenant_id") REFERENCES "public"."tenants"("id");



ALTER TABLE ONLY "public"."priority_slots"
    ADD CONSTRAINT "matches_created_by_fkey" FOREIGN KEY ("created_by") REFERENCES "public"."profiles"("id");



ALTER TABLE ONLY "public"."priority_slot_types"
    ADD CONSTRAINT "priority_slot_types_tenant_id_fkey" FOREIGN KEY ("tenant_id") REFERENCES "public"."tenants"("id");



ALTER TABLE ONLY "public"."priority_slots"
    ADD CONSTRAINT "priority_slots_parent_id_fkey" FOREIGN KEY ("parent_id") REFERENCES "public"."priority_slots"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."priority_slots"
    ADD CONSTRAINT "priority_slots_tenant_id_fkey" FOREIGN KEY ("tenant_id") REFERENCES "public"."tenants"("id");



ALTER TABLE ONLY "public"."priority_slots"
    ADD CONSTRAINT "priority_slots_type_id_fkey" FOREIGN KEY ("type_id") REFERENCES "public"."priority_slot_types"("id") ON DELETE RESTRICT;



ALTER TABLE ONLY "public"."profiles"
    ADD CONSTRAINT "profiles_approved_by_fkey" FOREIGN KEY ("approved_by") REFERENCES "public"."profiles"("id");



ALTER TABLE ONLY "public"."profiles"
    ADD CONSTRAINT "profiles_club_id_fkey" FOREIGN KEY ("club_id") REFERENCES "public"."clubs"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."profiles"
    ADD CONSTRAINT "profiles_home_tenant_id_fkey" FOREIGN KEY ("home_tenant_id") REFERENCES "public"."tenants"("id");



ALTER TABLE ONLY "public"."profiles"
    ADD CONSTRAINT "profiles_id_fkey" FOREIGN KEY ("id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."profiles"
    ADD CONSTRAINT "profiles_tenant_id_fkey" FOREIGN KEY ("tenant_id") REFERENCES "public"."tenants"("id");



ALTER TABLE ONLY "public"."rentals"
    ADD CONSTRAINT "rentals_created_by_fkey" FOREIGN KEY ("created_by") REFERENCES "public"."profiles"("id");



ALTER TABLE ONLY "public"."rentals"
    ADD CONSTRAINT "rentals_parent_id_fkey" FOREIGN KEY ("parent_id") REFERENCES "public"."rentals"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."rentals"
    ADD CONSTRAINT "rentals_tenant_id_fkey" FOREIGN KEY ("tenant_id") REFERENCES "public"."tenants"("id");



ALTER TABLE ONLY "public"."reservations"
    ADD CONSTRAINT "reservations_block_id_fkey" FOREIGN KEY ("block_id") REFERENCES "public"."time_blocks"("id") ON DELETE RESTRICT;



ALTER TABLE ONLY "public"."reservations"
    ADD CONSTRAINT "reservations_created_by_fkey" FOREIGN KEY ("created_by") REFERENCES "public"."profiles"("id");



ALTER TABLE ONLY "public"."reservations"
    ADD CONSTRAINT "reservations_player_id_fkey" FOREIGN KEY ("player_id") REFERENCES "public"."profiles"("id");



ALTER TABLE ONLY "public"."reservations"
    ADD CONSTRAINT "reservations_tenant_id_fkey" FOREIGN KEY ("tenant_id") REFERENCES "public"."tenants"("id");



ALTER TABLE ONLY "public"."schedule_settings"
    ADD CONSTRAINT "schedule_settings_tenant_id_fkey" FOREIGN KEY ("tenant_id") REFERENCES "public"."tenants"("id");



ALTER TABLE ONLY "public"."time_blocks"
    ADD CONSTRAINT "time_blocks_tenant_id_fkey" FOREIGN KEY ("tenant_id") REFERENCES "public"."tenants"("id");



CREATE POLICY "blocks_delete" ON "public"."time_blocks" FOR DELETE USING ((("tenant_id" = "public"."current_tenant_id"()) AND "public"."is_admin"()));



CREATE POLICY "blocks_insert" ON "public"."time_blocks" FOR INSERT WITH CHECK ((("tenant_id" = "public"."current_tenant_id"()) AND "public"."is_admin"()));



CREATE POLICY "blocks_select" ON "public"."time_blocks" FOR SELECT USING ((("tenant_id" = "public"."current_tenant_id"()) AND "public"."is_approved_or_kiosk"()));



CREATE POLICY "blocks_update" ON "public"."time_blocks" FOR UPDATE USING ((("tenant_id" = "public"."current_tenant_id"()) AND "public"."is_admin"())) WITH CHECK ((("tenant_id" = "public"."current_tenant_id"()) AND "public"."is_admin"()));



ALTER TABLE "public"."clubs" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "clubs_select" ON "public"."clubs" FOR SELECT USING ((("tenant_id" = "public"."current_tenant_id"()) AND "public"."is_approved_or_kiosk"()));



CREATE POLICY "clubs_write" ON "public"."clubs" USING ((("tenant_id" = "public"."current_tenant_id"()) AND "public"."is_admin"())) WITH CHECK ((("tenant_id" = "public"."current_tenant_id"()) AND "public"."is_admin"()));



ALTER TABLE "public"."day_overrides" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "overrides_delete" ON "public"."day_overrides" FOR DELETE USING ((("tenant_id" = "public"."current_tenant_id"()) AND "public"."is_admin"()));



CREATE POLICY "overrides_insert" ON "public"."day_overrides" FOR INSERT WITH CHECK ((("tenant_id" = "public"."current_tenant_id"()) AND "public"."is_admin"()));



CREATE POLICY "overrides_select" ON "public"."day_overrides" FOR SELECT USING ((("tenant_id" = "public"."current_tenant_id"()) AND "public"."is_approved_or_kiosk"()));



CREATE POLICY "overrides_update" ON "public"."day_overrides" FOR UPDATE USING ((("tenant_id" = "public"."current_tenant_id"()) AND "public"."is_admin"())) WITH CHECK ((("tenant_id" = "public"."current_tenant_id"()) AND "public"."is_admin"()));



CREATE POLICY "priority_delete" ON "public"."priority_slots" FOR DELETE USING ((("tenant_id" = "public"."current_tenant_id"()) AND "public"."is_admin"()));



CREATE POLICY "priority_insert" ON "public"."priority_slots" FOR INSERT WITH CHECK ((("tenant_id" = "public"."current_tenant_id"()) AND "public"."is_admin"()));



CREATE POLICY "priority_select" ON "public"."priority_slots" FOR SELECT USING ((("tenant_id" = "public"."current_tenant_id"()) AND "public"."is_approved_or_kiosk"()));



ALTER TABLE "public"."priority_slot_types" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."priority_slots" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "priority_update" ON "public"."priority_slots" FOR UPDATE USING ((("tenant_id" = "public"."current_tenant_id"()) AND "public"."is_admin"())) WITH CHECK ((("tenant_id" = "public"."current_tenant_id"()) AND "public"."is_admin"()));



ALTER TABLE "public"."profiles" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "profiles_select" ON "public"."profiles" FOR SELECT USING ((("id" = "auth"."uid"()) OR ("public"."is_admin"() AND ("tenant_id" = "public"."current_tenant_id"()))));



CREATE POLICY "profiles_update_own" ON "public"."profiles" FOR UPDATE USING (("id" = "auth"."uid"())) WITH CHECK (("id" = "auth"."uid"()));



ALTER TABLE "public"."rentals" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "rentals_delete" ON "public"."rentals" FOR DELETE USING ((("tenant_id" = "public"."current_tenant_id"()) AND "public"."is_admin"()));



CREATE POLICY "rentals_insert" ON "public"."rentals" FOR INSERT WITH CHECK ((("tenant_id" = "public"."current_tenant_id"()) AND "public"."is_admin"()));



CREATE POLICY "rentals_select" ON "public"."rentals" FOR SELECT USING ((("tenant_id" = "public"."current_tenant_id"()) AND "public"."is_approved_or_kiosk"()));



CREATE POLICY "rentals_update" ON "public"."rentals" FOR UPDATE USING ((("tenant_id" = "public"."current_tenant_id"()) AND "public"."is_admin"())) WITH CHECK ((("tenant_id" = "public"."current_tenant_id"()) AND "public"."is_admin"()));



ALTER TABLE "public"."reservations" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "reservations_select" ON "public"."reservations" FOR SELECT USING ((("tenant_id" = "public"."current_tenant_id"()) AND "public"."is_approved_or_kiosk"()));



ALTER TABLE "public"."schedule_settings" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "settings_select" ON "public"."schedule_settings" FOR SELECT USING ((("tenant_id" = "public"."current_tenant_id"()) AND "public"."is_approved_or_kiosk"()));



CREATE POLICY "settings_update" ON "public"."schedule_settings" FOR UPDATE USING ((("tenant_id" = "public"."current_tenant_id"()) AND "public"."is_admin"())) WITH CHECK ((("tenant_id" = "public"."current_tenant_id"()) AND "public"."is_admin"()));



CREATE POLICY "slot_types_delete" ON "public"."priority_slot_types" FOR DELETE USING ((("tenant_id" = "public"."current_tenant_id"()) AND "public"."is_admin"() AND (NOT "builtin")));



CREATE POLICY "slot_types_insert" ON "public"."priority_slot_types" FOR INSERT WITH CHECK ((("tenant_id" = "public"."current_tenant_id"()) AND "public"."is_admin"()));



CREATE POLICY "slot_types_select" ON "public"."priority_slot_types" FOR SELECT USING ((("tenant_id" = "public"."current_tenant_id"()) AND "public"."is_approved_or_kiosk"()));



CREATE POLICY "slot_types_update" ON "public"."priority_slot_types" FOR UPDATE USING ((("tenant_id" = "public"."current_tenant_id"()) AND "public"."is_admin"())) WITH CHECK ((("tenant_id" = "public"."current_tenant_id"()) AND "public"."is_admin"()));



ALTER TABLE "public"."tenants" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "tenants_select" ON "public"."tenants" FOR SELECT TO "authenticated" USING (true);



ALTER TABLE "public"."time_blocks" ENABLE ROW LEVEL SECURITY;


GRANT USAGE ON SCHEMA "public" TO "postgres";
GRANT USAGE ON SCHEMA "public" TO "anon";
GRANT USAGE ON SCHEMA "public" TO "authenticated";
GRANT USAGE ON SCHEMA "public" TO "service_role";



REVOKE ALL ON FUNCTION "public"."admin_list_tenants"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."admin_list_tenants"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."admin_list_tenants"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."approve_tenant"("p_tenant_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."approve_tenant"("p_tenant_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."approve_tenant"("p_tenant_id" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "public"."block_day_status"("p_tenant" "uuid", "p_date" "date", "p_block_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."block_day_status"("p_tenant" "uuid", "p_date" "date", "p_block_id" "uuid") TO "service_role";



GRANT ALL ON TABLE "public"."priority_slots" TO "authenticated";
GRANT ALL ON TABLE "public"."priority_slots" TO "service_role";



REVOKE ALL ON FUNCTION "public"."cancel_stranded_reservations"("p_tenant" "uuid", "p_note" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."cancel_stranded_reservations"("p_tenant" "uuid", "p_note" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."cascade_schedule_change"() TO "anon";
GRANT ALL ON FUNCTION "public"."cascade_schedule_change"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."cascade_schedule_change"() TO "service_role";



GRANT ALL ON TABLE "public"."reservations" TO "authenticated";
GRANT ALL ON TABLE "public"."reservations" TO "service_role";



GRANT SELECT,INSERT,REFERENCES,DELETE,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."profiles" TO "authenticated";
GRANT ALL ON TABLE "public"."profiles" TO "service_role";



GRANT UPDATE("display_name") ON TABLE "public"."profiles" TO "authenticated";



GRANT UPDATE("fcm_token") ON TABLE "public"."profiles" TO "authenticated";



REVOKE ALL ON FUNCTION "public"."notify_webhook_config"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."notify_webhook_config"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."reject_tenant"("p_tenant_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."reject_tenant"("p_tenant_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."reject_tenant"("p_tenant_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."rental_exception_guard"() TO "anon";
GRANT ALL ON FUNCTION "public"."rental_exception_guard"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."rental_exception_guard"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."rental_occurrences"("p_tenant" "uuid", "p_date" "date") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."rental_occurrences"("p_tenant" "uuid", "p_date" "date") TO "service_role";



GRANT ALL ON TABLE "public"."rentals" TO "authenticated";
GRANT ALL ON TABLE "public"."rentals" TO "service_role";



REVOKE ALL ON FUNCTION "public"."rental_occurs"("r" "public"."rentals", "p_date" "date") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."rental_occurs"("r" "public"."rentals", "p_date" "date") TO "service_role";



GRANT ALL ON FUNCTION "public"."rental_series_changed"() TO "anon";
GRANT ALL ON FUNCTION "public"."rental_series_changed"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."rental_series_changed"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."seed_demo_member"("p_email" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."seed_demo_member"("p_email" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."switch_tenant"("p_tenant_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."switch_tenant"("p_tenant_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."switch_tenant"("p_tenant_id" "uuid") TO "service_role";



GRANT ALL ON TABLE "public"."clubs" TO "authenticated";
GRANT ALL ON TABLE "public"."clubs" TO "service_role";



GRANT ALL ON TABLE "public"."day_overrides" TO "authenticated";
GRANT ALL ON TABLE "public"."day_overrides" TO "service_role";



GRANT SELECT ON TABLE "public"."players" TO "authenticated";
GRANT ALL ON TABLE "public"."players" TO "service_role";



GRANT SELECT,REFERENCES,DELETE,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."priority_slot_types" TO "authenticated";
GRANT ALL ON TABLE "public"."priority_slot_types" TO "service_role";



GRANT INSERT("name"),UPDATE("name") ON TABLE "public"."priority_slot_types" TO "authenticated";



GRANT INSERT("color"),UPDATE("color") ON TABLE "public"."priority_slot_types" TO "authenticated";



GRANT INSERT("lanes"),UPDATE("lanes") ON TABLE "public"."priority_slot_types" TO "authenticated";



GRANT ALL ON TABLE "public"."schedule_settings" TO "authenticated";
GRANT ALL ON TABLE "public"."schedule_settings" TO "service_role";



GRANT ALL ON TABLE "public"."tenants" TO "service_role";



GRANT SELECT("id") ON TABLE "public"."tenants" TO "authenticated";



GRANT SELECT("name") ON TABLE "public"."tenants" TO "authenticated";



GRANT SELECT("status") ON TABLE "public"."tenants" TO "authenticated";



GRANT ALL ON TABLE "public"."time_blocks" TO "authenticated";
GRANT ALL ON TABLE "public"."time_blocks" TO "service_role";



ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT UPDATE ON SEQUENCES TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT UPDATE ON SEQUENCES TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT UPDATE ON SEQUENCES TO "service_role";






ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "service_role";






ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT SELECT,INSERT,DELETE,UPDATE ON TABLES TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "service_role";







