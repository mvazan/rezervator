-- 0064 — the kiosk reads the alley's notices.
--
-- 0051 kept the kiosk away from the whole messages feature. The notice
-- board (Klubovna → Nástěnka) is public to the alley by nature — the same
-- text a club pins on a wall — so the shared tablet now shows the active
-- notices. Only kind = 'notice': messages (day, block, admins, duty) stay
-- with their author and recipients, and the kiosk still reads no
-- message_recipients row (who saw what) and still writes nothing.
--
-- can_read_message and visible_message_ids stay the same rule, one per id
-- and one as a set (the tenancy_rls.sql suite checks they agree).

create or replace function can_read_message(p_id uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from messages m
     where m.id = p_id and m.tenant_id = current_tenant_id()
       and (
         (is_approved() and not is_kiosk()
          and (m.kind = 'notice'
               or m.author_id = auth.uid()
               or exists (select 1 from message_recipients r
                           where r.message_id = m.id and r.user_id = auth.uid())))
         or (is_kiosk() and m.kind = 'notice')
       )
  )
$$;

create or replace function visible_message_ids() returns setof uuid
language sql stable security definer set search_path = public as $$
  select m.id from messages m
   where m.tenant_id = (select current_tenant_id())
     and ((select is_approved()) and not (select is_kiosk())
          and (m.kind = 'notice'
               or m.author_id = (select auth.uid())
               or exists (select 1 from message_recipients r
                           where r.message_id = m.id
                             and r.user_id = (select auth.uid())))
          or (select is_kiosk()) and m.kind = 'notice')
$$;
