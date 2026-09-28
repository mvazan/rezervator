-- 0051 — Zprávy a nástěnka (messages and the notice board). The admin and
-- the player on canteen duty write to players (a block, a day, everyone);
-- a player writes to the admins or to today's duty. Recipients are
-- materialised at send time; reactions (👍/👎 + a short reply) are visible
-- to the author and to every recipient of that message. Not a chat: no
-- threads, no player-to-player messages. A notice (kind = 'notice',
-- audience = 'all') is the same machinery with an expiry and no reactions.
-- Spec: docs/superpowers/specs/2026-09-28-messages-design.md
-- Not deployed until merge, and every statement is safe to run twice.

-- ------------------------------------------------------------- messages
create table if not exists messages (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references tenants(id) on delete cascade,
  author_id uuid references profiles(id) on delete set null,
  -- Snapshot of the sender's role at send time: players cannot read other
  -- profiles, so this is what labels „Od správce“ / „Od služby“.
  author_role text not null,
  kind text not null,
  audience text not null,
  on_date date,
  block_id uuid references time_blocks(id) on delete set null,
  title text,
  body text not null,
  expires_at timestamptz,
  notify boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint messages_kind_check check (kind in ('notice', 'message')),
  constraint messages_author_role_check check (author_role in ('admin', 'player')),
  constraint messages_audience_check
    check (audience in ('all', 'day', 'block', 'admins', 'duty')),
  constraint messages_kind_audience_check check (
    (kind = 'notice' and audience = 'all') or
    (kind = 'message' and audience in ('day', 'block', 'admins', 'duty'))
  ),
  constraint messages_context_check check (
    (audience = 'all' and on_date is null and block_id is null) or
    (audience = 'day' and on_date is not null and block_id is null) or
    -- message_send requires the block; a block removed later sets it null
    -- and the message keeps its day (the chip shows the date alone).
    (audience = 'block' and on_date is not null) or
    (audience in ('admins', 'duty'))
  ),
  constraint messages_title_check check (
    (kind = 'notice' and char_length(trim(coalesce(title, ''))) between 1 and 80) or
    (kind = 'message' and title is null)
  ),
  constraint messages_body_check check (
    char_length(trim(body)) >= 1 and
    char_length(trim(body)) <= (case when kind = 'notice' then 2000 else 500 end)
  ),
  constraint messages_expires_check
    check (kind = 'notice' or expires_at is null)
);
create index if not exists messages_tenant_kind_created
  on messages (tenant_id, kind, created_at);
create index if not exists messages_tenant_on_date
  on messages (tenant_id, on_date);
comment on table messages is
  'A notice (kind=notice, audience=all, Klubovna -> Nástěnka) or a message (kind=message, to a day/block/admins/duty, Klubovna -> Zprávy), 0051. Written only through message_send/message_update/message_delete.';
comment on column messages.expires_at is
  'Notice only: when it stops showing as active; null = "do odvolání".';
comment on column messages.notify is
  'Whether sending this pinged its recipients (push/e-mail). Always true for a message; the admin''s choice for a notice.';

-- ---------------------------------------------------- message_recipients
create table if not exists message_recipients (
  message_id uuid not null references messages(id) on delete cascade,
  user_id uuid not null references profiles(id) on delete cascade,
  tenant_id uuid not null references tenants(id) on delete cascade,
  read_at timestamptz,
  reaction text,
  reply text,
  reacted_at timestamptz,
  primary key (message_id, user_id),
  constraint message_recipients_reaction_check check (reaction in ('up', 'down')),
  constraint message_recipients_reply_check check (char_length(reply) <= 200)
);
create index if not exists message_recipients_tenant_user
  on message_recipients (tenant_id, user_id, read_at);
comment on table message_recipients is
  'Who got a messages row (0051), materialised at send time from the reservations/roster/duty data then. tenant_id is the message''s, denormalised like duty_assignments. read_at/reaction/reply are the recipient''s own-row write.';

-- reacted_at follows reaction/reply: stamped when either changes, cleared
-- when both are back to null. A read (read_at alone) leaves it be. A
-- notice has no reactions: a reaction or a reply on a notice's row is
-- not_allowed, whoever writes it (the column grant alone would let it
-- through). Security definer to read the message's kind past RLS; nobody
-- calls it directly (a trigger needs no EXECUTE to fire).
create or replace function message_recipients_stamp_reacted()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if (new.reaction is not null or new.reply is not null)
     and (select kind from messages where id = new.message_id) = 'notice' then
    raise exception 'not_allowed';
  end if;
  if new.reaction is distinct from old.reaction or new.reply is distinct from old.reply then
    if new.reaction is null and new.reply is null then
      new.reacted_at := null;
    else
      new.reacted_at := now();
    end if;
  end if;
  return new;
end;
$$;
revoke all on function message_recipients_stamp_reacted() from public, anon, authenticated;
drop trigger if exists message_recipients_reacted_at on message_recipients;
create trigger message_recipients_reacted_at
  before update on message_recipients
  for each row execute function message_recipients_stamp_reacted();

-- ------------------------------------------------------- RLS and grants
alter table messages enable row level security;
alter table message_recipients enable row level security;

-- Whether the caller may read [p_id]: nothing at all unless the caller is
-- an approved non-kiosk member of the message's alley (the spec's „the
-- kiosk reads nothing here“ — so an account later set as the kiosk or
-- back to pending loses what it once got as a player); then a notice to
-- every such member, any message to its author or a recipient. The
-- messages policy uses the same rule as a set (visible_message_ids); this
-- per-id form stays for callers that ask about one message.
create or replace function can_read_message(p_id uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from messages m
     where m.id = p_id and m.tenant_id = current_tenant_id()
       and is_approved() and not is_kiosk()
       and (
         m.kind = 'notice'
         or m.author_id = auth.uid()
         or exists (select 1 from message_recipients r
                     where r.message_id = m.id and r.user_id = auth.uid())
       )
  )
$$;
revoke all on function can_read_message(uuid) from public, anon;
grant execute on function can_read_message(uuid) to authenticated;

-- The same rule as a set, for messages_select: the ids of the alley's
-- messages the caller reads, exactly those can_read_message admits. One
-- call per query, not one per row (~13 ms → ~0.4 ms for a player's
-- stream at 150 messages).
create or replace function visible_message_ids() returns setof uuid
language sql stable security definer set search_path = public as $$
  select m.id from messages m
   where m.tenant_id = (select current_tenant_id())
     and (select is_approved()) and not (select is_kiosk())
     and (m.kind = 'notice'
          or m.author_id = (select auth.uid())
          or exists (select 1 from message_recipients r
                      where r.message_id = m.id
                        and r.user_id = (select auth.uid())))
$$;
revoke all on function visible_message_ids() from public, anon;
grant execute on function visible_message_ids() to authenticated;

-- The message ids whose recipient rows — beyond the caller's own — the
-- caller sees: every notice of the alley to its admins („Kdo si to
-- zobrazil“; a player sees her own row of a notice only), a message to its
-- author and its recipients (the reactions), nothing to the kiosk or a
-- pending account. Security definer so the message_recipients policy
-- reads its own table without recursing into its RLS; a set, so the
-- policy asks once per query instead of once per row (~400 ms for a
-- player's stream at 40 members × 100 notices with a per-row helper).
create or replace function visible_recipient_message_ids() returns setof uuid
language sql stable security definer set search_path = public as $$
  select m.id from messages m
   where m.tenant_id = (select current_tenant_id())
     and (select is_approved()) and not (select is_kiosk())
     and ((m.kind = 'notice' and (select is_admin()))
          or (m.kind = 'message'
              and (m.author_id = (select auth.uid())
                   or exists (select 1 from message_recipients r
                               where r.message_id = m.id
                                 and r.user_id = (select auth.uid())))))
$$;
revoke all on function visible_recipient_message_ids() from public, anon;
grant execute on function visible_recipient_message_ids() to authenticated;

-- Both select policies lead with the alley, as every other policy does:
-- the planner then index-scans the caller's own alley instead of calling
-- a helper on every row of the platform (a player's stream is
-- unfiltered, and each Realtime change is checked through the same policy).
drop policy if exists messages_select on messages;
create policy messages_select on messages
  for select using (tenant_id = (select current_tenant_id())
                    and id in (select visible_message_ids()));
-- A recipient row: my own (while an approved non-kiosk member), or any row
-- of a message whose rows I see (visible_recipient_message_ids).
drop policy if exists message_recipients_select on message_recipients;
create policy message_recipients_select on message_recipients
  for select using (
    tenant_id = (select current_tenant_id())
    and ((user_id = (select auth.uid()) and (select is_approved()) and not (select is_kiosk()))
         or message_id in (select visible_recipient_message_ids())));
-- Own row, and only while an approved non-kiosk member (can_read_message's
-- rule): an account set as the kiosk or back to pending reacts to nothing.
drop policy if exists message_recipients_update_own on message_recipients;
create policy message_recipients_update_own on message_recipients
  for update
  using (user_id = auth.uid() and is_approved() and not is_kiosk())
  with check (user_id = auth.uid() and is_approved() and not is_kiosk());

revoke all on messages, message_recipients from anon, authenticated;
grant select on messages, message_recipients to authenticated;
grant update (read_at, reaction, reply) on message_recipients to authenticated;
grant all on messages, message_recipients to service_role;

-- ------------------------------------------------------------- Realtime
do $$
begin
  if not exists (select 1 from pg_publication_tables
                 where pubname = 'supabase_realtime' and schemaname = 'public'
                   and tablename = 'messages') then
    alter publication supabase_realtime add table messages;
  end if;
  if not exists (select 1 from pg_publication_tables
                 where pubname = 'supabase_realtime' and schemaname = 'public'
                   and tablename = 'message_recipients') then
    alter publication supabase_realtime add table message_recipients;
  end if;
end $$;

-- ------------------------------------------------------------ message_send
-- Sends a notice or a message and materialises its recipients from the
-- alley's data right now. Every audience draws from the same members: the
-- `players` view's rule (approved, not the kiosk, not a placeholder, not a
-- visiting superadmin) minus the author — so `all`/`admins`/`duty` follow
-- that rule, and a pending account is no `day`/`block` recipient either,
-- live booking or not (the app's preview names recipients from that same
-- roster). A pending assignee is off duty (is_on_duty, 0050), so she gets
-- no `duty` message. `no_recipients` on an empty set except `duty`, which
-- says `nobody_on_duty` whenever the computed duty set is empty (no
-- period covers today, or every assignee is excluded).
create or replace function message_send(
  p_kind text, p_audience text, p_on_date date, p_block_id uuid,
  p_title text, p_body text, p_expires_at timestamptz, p_notify boolean)
returns uuid
language plpgsql security definer set search_path = public
as $$
declare
  v_tenant constant uuid := current_tenant_id();
  v_me constant uuid := auth.uid();
  -- Trimmed of any whitespace, not only spaces (trim() alone would take
  -- a body of newlines and tabs as written); what is stored and measured.
  v_title constant text :=
    nullif(regexp_replace(coalesce(p_title, ''), '^\s+|\s+$', '', 'g'), '');
  v_body constant text := regexp_replace(coalesce(p_body, ''), '^\s+|\s+$', '', 'g');
  v_id uuid;
  v_members uuid[];
  v_recipients uuid[];
  v_role text;
begin
  select role into v_role from profiles
    where id = v_me and tenant_id = v_tenant and status = 'approved'
      and not placeholder and role <> 'kiosk';
  if v_role is null then
    raise exception 'not_allowed';
  end if;

  if p_kind = 'notice' then
    if not is_admin() then
      raise exception 'not_allowed';
    end if;
    if p_audience is distinct from 'all' then
      raise exception 'invalid_audience';
    end if;
    if v_title is null then
      raise exception 'title_required';
    end if;
  elsif p_kind = 'message' then
    if p_audience in ('day', 'block') then
      if p_on_date is null then
        raise exception 'date_past';
      end if;
      perform duty_gate(p_on_date);
      if p_audience = 'block' then
        -- An active block of this alley, or a day-only block that belongs
        -- to this date through day_overrides (add_special_block leaves
        -- those with active = false).
        if not exists (select 1 from time_blocks b
                        where b.id = p_block_id and b.tenant_id = v_tenant
                          and (b.active or exists (
                            select 1 from day_overrides o
                             where o.tenant_id = v_tenant and o.date = p_on_date
                               and b.id = any (o.block_ids)))) then
          raise exception 'unknown_block';
        end if;
      end if;
    elsif p_audience in ('admins', 'duty') then
      -- Any approved home account, admins included (v_role is already
      -- checked above). on_date/block_id are optional context here —
      -- the block, if given, has to be this alley's.
      if p_block_id is not null and not exists (
          select 1 from time_blocks
           where id = p_block_id and tenant_id = v_tenant) then
        raise exception 'unknown_block';
      end if;
    else
      raise exception 'invalid_audience';
    end if;
  else
    raise exception 'invalid_kind';
  end if;

  if v_body = '' then
    raise exception 'body_required';
  end if;
  if char_length(v_body) > (case when p_kind = 'notice' then 2000 else 500 end) then
    raise exception 'body_too_long';
  end if;

  -- The `players` view's rule, minus the author: whoever may receive.
  v_members := array(select id from profiles
                      where tenant_id = v_tenant and status = 'approved' and role <> 'kiosk'
                        and not placeholder and id <> v_me
                        and not (superadmin and home_tenant_id is not null
                                 and tenant_id <> home_tenant_id));

  v_recipients := case p_audience
    when 'all' then v_members
    when 'day' then
      array(select distinct player_id from reservations
             where tenant_id = v_tenant and date = p_on_date and cancelled_at is null
               and player_id = any (v_members))
    when 'block' then
      array(select distinct player_id from reservations
             where tenant_id = v_tenant and date = p_on_date and block_id = p_block_id
               and cancelled_at is null and player_id = any (v_members))
    when 'admins' then
      array(select id from profiles
             where id = any (v_members) and role = 'admin')
    when 'duty' then
      array(select a.user_id from duty_assignments a
             join duty_periods d on d.id = a.period_id
             where d.tenant_id = v_tenant
               and (now() at time zone 'Europe/Prague')::date
                   between d.starts_on and d.ends_on
               and a.user_id = any (v_members))
  end;

  if array_length(v_recipients, 1) is null then
    if p_audience = 'duty' then
      raise exception 'nobody_on_duty';
    end if;
    raise exception 'no_recipients';
  end if;

  -- A notice keeps no context; a day message no block; only a notice has a
  -- title, an expiry and a choice about pinging (a message always pings).
  insert into messages (tenant_id, author_id, author_role, kind, audience, on_date, block_id,
                        title, body, expires_at, notify)
    values (v_tenant, v_me, v_role, p_kind, p_audience,
            case when p_kind = 'notice' then null else p_on_date end,
            case when p_kind = 'notice' or p_audience = 'day' then null
                 else p_block_id end,
            case when p_kind = 'notice' then v_title end,
            v_body, case when p_kind = 'notice' then p_expires_at end,
            case when p_kind = 'notice' then coalesce(p_notify, true) else true end)
    returning id into v_id;

  insert into message_recipients (message_id, user_id, tenant_id)
    select v_id, u, v_tenant from unnest(v_recipients) u;

  return v_id;
end;
$$;

-- Notices only, admin. There is no "leave unchanged" sentinel: the caller
-- always sends its full current state, so p_expires_at = null always
-- means "do odvolání". "Sejmout" is this same RPC with p_expires_at =
-- now() and the title/body left as they were.
create or replace function message_update(
  p_id uuid, p_title text, p_body text, p_expires_at timestamptz)
returns void
language plpgsql security definer set search_path = public
as $$
declare
  -- Trimmed of any whitespace, as in message_send.
  v_title constant text :=
    nullif(regexp_replace(coalesce(p_title, ''), '^\s+|\s+$', '', 'g'), '');
  v_body constant text := regexp_replace(coalesce(p_body, ''), '^\s+|\s+$', '', 'g');
begin
  if not is_admin() then
    raise exception 'not_allowed';
  end if;
  if v_title is null then
    raise exception 'title_required';
  end if;
  if v_body = '' then
    raise exception 'body_required';
  end if;
  if char_length(v_body) > 2000 then
    raise exception 'body_too_long';
  end if;
  update messages
     set title = v_title, body = v_body, expires_at = p_expires_at, updated_at = now()
   where id = p_id and tenant_id = current_tenant_id() and kind = 'notice';
  if not found then
    raise exception 'unknown_message';
  end if;
end;
$$;

-- The author or an admin; recipients cascade. Either while an approved
-- non-kiosk member, like every other right here: an author set back to
-- pending or as the kiosk deletes nothing (is_admin() already needs both).
create or replace function message_delete(p_id uuid) returns void
language plpgsql security definer set search_path = public
as $$
begin
  if not is_approved() or is_kiosk() then
    raise exception 'not_allowed';
  end if;
  delete from messages
   where id = p_id and tenant_id = current_tenant_id()
     and (author_id = auth.uid() or is_admin());
  if not found then
    raise exception 'unknown_message';
  end if;
end;
$$;

-- Daily prune (pg_cron): messages (not notices) whose key day is more
-- than 90 days old. on_date when the message has one, else created_at in
-- Prague.
create or replace function prune_messages() returns integer
language plpgsql security definer set search_path = public
as $$
declare
  v_count integer;
begin
  delete from messages
   where kind = 'message'
     and coalesce(on_date, (created_at at time zone 'Europe/Prague')::date)
         < (now() at time zone 'Europe/Prague')::date - 90;
  get diagnostics v_count = row_count;
  return v_count;
end;
$$;

revoke all on function message_send(text, text, date, uuid, text, text, timestamptz, boolean)
  from public, anon;
revoke all on function message_update(uuid, text, text, timestamptz) from public, anon;
revoke all on function message_delete(uuid) from public, anon;
revoke all on function prune_messages() from public, anon, authenticated;
grant execute on function message_send(text, text, date, uuid, text, text, timestamptz, boolean)
  to authenticated;
grant execute on function message_update(uuid, text, text, timestamptz) to authenticated;
grant execute on function message_delete(uuid) to authenticated;
grant execute on function prune_messages() to service_role;

-- Same shape as 0023/0045: unschedule then schedule, so a changed schedule
-- re-applies on a rerun instead of being skipped.
do $$
begin
  if exists (select 1 from cron.job where jobname = 'messages-prune') then
    perform cron.unschedule('messages-prune');
  end if;
  perform cron.schedule('messages-prune', '20 3 * * *', 'select public.prune_messages()');
end $$;

-- ---------------------------------------------------------------- notify
-- The row webhook (existing notify_webhook(), table-generic) fans out a
-- new message and a reaction on it exactly like every other row today.
-- Until notify knows these two tables, it answers 200 and queues nothing
-- (its switch has no default branch).
drop trigger if exists notify_messages on messages;
create trigger notify_messages
  after insert on messages
  for each row execute function notify_webhook();
drop trigger if exists notify_message_reactions on message_recipients;
create trigger notify_message_reactions
  after update of reaction, reply on message_recipients
  for each row execute function notify_webhook();
