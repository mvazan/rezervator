-- 0060 — the admin edits a player's name.
--
-- profiles_update_own lets a player change only their own display_name and
-- nothing of anyone else's, and a hand-made player has its own editor, so an
-- ACCOUNT's name (a typo from the registration, a married name, a nickname
-- typed into the name field) had no way to be corrected. Admin only, the
-- caller's own alley only; the name is trimmed and may not be empty.
--
-- The registration number is looked up by name (0057, 0059): a renamed player
-- is looked for again at the next opportunity (`regnum_checked_at` cleared),
-- while a number the player already has stays.

create or replace function set_display_name(p_user_id uuid, p_name text)
returns void
language plpgsql security definer set search_path = public
as $$
declare
  v_name text := regexp_replace(trim(coalesce(p_name, '')), '\s+', ' ', 'g');
begin
  if auth.uid() is null then
    raise exception 'not_authenticated';
  end if;
  if not is_admin() then
    raise exception 'not_allowed';
  end if;
  if v_name = '' then
    raise exception 'empty_display_name';
  end if;
  if char_length(v_name) > 60 then
    raise exception 'display_name_too_long';
  end if;
  update profiles
     set display_name = v_name,
         regnum_checked_at = case when display_name is distinct from v_name
                                  then null else regnum_checked_at end
   where id = p_user_id and tenant_id = current_tenant_id();
  if not found then
    raise exception 'unknown_player';
  end if;
end;
$$;

revoke all on function set_display_name(uuid, text) from public, anon;
grant execute on function set_display_name(uuid, text) to authenticated;
