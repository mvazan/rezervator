-- 0034 — barvu tréninků má kdo uložit.
--
-- 0032 sloupec training_color_id přidalo, ale zapisovat ho neuměl nikdo:
-- google_calendar_links si hráč čte, psát do něj smí jen server, a žádná
-- akce calendar-manage ho neobsluhovala. RPC ve stejném tvaru jako
-- set_calendar_reminders_for (0023/0032) to spravuje — validace tady,
-- edge funkce ji jen volá za hráče a pak srovná budoucí události.

create function set_training_color_for(p_user uuid, p_color smallint)
returns smallint
language plpgsql security definer set search_path = public
as $$
declare v_color smallint := p_color;
begin
  -- null = bez barvy (událost vezme barvu kalendáře); jinak jen Googlem
  -- povolených jedenáct, viz calendar_teams.color_id.
  if v_color is not null and (v_color < 1 or v_color > 11) then
    raise exception 'bad_color';
  end if;
  if not exists (select 1 from google_calendar_links where user_id = p_user) then
    raise exception 'unknown_link';
  end if;

  update google_calendar_links
     set training_color_id = v_color, updated_at = now()
   where user_id = p_user;
  return v_color;
end;
$$;

revoke all on function set_training_color_for(uuid, smallint)
  from public, anon, authenticated;
grant execute on function set_training_color_for(uuid, smallint) to service_role;
