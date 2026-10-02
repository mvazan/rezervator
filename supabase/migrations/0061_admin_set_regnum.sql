-- 0061 — the admin sets a player's registration number by hand.
--
-- The number is normally looked up in the ČKA register by name and club
-- (0057, 0059); a player the lookup cannot settle (a namesake, a name spelled
-- differently there, a club the register names otherwise) has none. Admin
-- only, the caller's own alley only; an empty value clears the number. A
-- number typed by hand counts as settled: it is never looked up again, and
-- the lookup never overwrites it (it fills only an empty regnum).
--
-- Digits only, as the column's check says; a number another player of the
-- alley already has is refused as `regnum_taken` (profiles_regnum_tenant_idx).

create or replace function set_regnum(p_user_id uuid, p_regnum text)
returns void
language plpgsql security definer set search_path = public
as $$
declare
  v_regnum text := nullif(trim(coalesce(p_regnum, '')), '');
begin
  if auth.uid() is null then
    raise exception 'not_authenticated';
  end if;
  if not is_admin() then
    raise exception 'not_allowed';
  end if;
  if v_regnum is not null and v_regnum !~ '^[0-9]{1,8}$' then
    raise exception 'invalid_regnum';
  end if;
  begin
    update profiles
       set regnum = v_regnum,
           regnum_checked_at = case when v_regnum is null then null else now() end
     where id = p_user_id and tenant_id = current_tenant_id();
  exception when unique_violation then
    raise exception 'regnum_taken';
  end;
  if not found then
    raise exception 'unknown_player';
  end if;
end;
$$;

revoke all on function set_regnum(uuid, text) from public, anon;
grant execute on function set_regnum(uuid, text) to authenticated;
