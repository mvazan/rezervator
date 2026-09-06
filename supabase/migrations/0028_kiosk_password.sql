-- Guard pro nastavení nového hesla kioskovému účtu (edge funkce
-- kiosk-password).
--
-- Heslo nejde přečíst — Supabase drží jen hash — takže jediná cesta, jak
-- správci dostat přihlašovací údaje k tabletu, je nastavit nové. Samotné
-- nastavení umí jen service role klíč v edge funkci; tahle funkce je to,
-- co ve funkci rozhoduje, JESTLI smí: volá se JMÉNEM VOLAJÍCÍHO, takže
-- is_admin() i current_tenant_id() vidí jeho, ne service role.
--
-- Vrací id cíle, aby funkce nemohla omylem sáhnout na jiný účet, než
-- který prošel kontrolou.
create or replace function kiosk_password_target(p_user_id uuid)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_id uuid;
begin
  if not is_admin() then
    raise exception 'not_allowed';
  end if;
  select id into v_id
  from profiles
  where id = p_user_id
    and tenant_id = current_tenant_id()
    and role = 'kiosk';
  if v_id is null then
    raise exception 'unknown_kiosk';
  end if;
  return v_id;
end;
$$;

comment on function kiosk_password_target(uuid) is
  'Kiosk účtu p_user_id smí správce téže kuželny nastavit nové heslo — vrací jeho id, jinak not_allowed/unknown_kiosk. Volá edge funkce kiosk-password jménem volajícího.';
