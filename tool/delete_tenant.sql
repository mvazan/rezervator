-- Smaže kuželnu podle názvu i se vším, co k ní patří (testovací kuželna).
--
-- Použití: změň název v řádku `v_name` a spusť v Supabase SQL editoru, nebo
--   supabase db query --linked -f tool/delete_tenant.sql
-- Před ostrým spuštěním udělej zálohu (viz CICD.md). Nevratné.
--
-- Proč ne prostě `delete from tenants`: deset tabulek má cizí klíč na
-- kuželnu bez kaskády (profiles, reservations, time_blocks, clubs,
-- priority_slots, priority_slot_types, rentals, day_overrides,
-- schedule_settings, rental_groups přes profily), a i prázdná kuželna má
-- hned při založení typy zápasů a nastavení. Zbytek (zprávy, týmy, služby,
-- zápasy a výsledky ze svazu, skupiny, zvonečky, …) se smaže kaskádou.
--
-- Běží v jedné transakci (DO blok): když cokoli selže, nesmaže se nic.
-- Ověřeno na kopii produkce: smazalo se všechno z kuželny a ani jeden řádek
-- jiných kuželen se nezměnil. Zůstane přihlašovací účet (`auth.users`)
-- zakladatele: smaž ho v Supabase → Authentication → Users, jde-li o
-- testovací e-mail.
do $$
declare
  v_name constant text := 'Test';   -- <-- název kuželny ke smazání
  t uuid;
  n int;
begin
  select count(*), min(id::text)::uuid into n, t from tenants where name = v_name;
  if n <> 1 then
    raise exception 'Čekal jsem právě jednu kuželnu „%“, našel jsem %', v_name, n;
  end if;

  -- Superadmin, který je do kuželny právě „přepnutý“ (nebo v ní má domov),
  -- by smazáním přišel o vlastní profil: nejdřív se přepni domů.
  if exists (select 1 from profiles where superadmin
                and (tenant_id = t or home_tenant_id = t)) then
    raise exception 'V kuželně je superadmin (přepnutý nebo s domovem tady). Přepni se nejdřív domů.';
  end if;

  -- Pořadí je dané cizími klíči bez kaskády: nejdřív to, co na ostatní
  -- ukazuje (rezervace → bloky, zápasy → typy zápasů, vše → profily).
  delete from reservations         where tenant_id = t;
  delete from priority_slots       where tenant_id = t;
  delete from rentals              where tenant_id = t;
  delete from rental_groups        where tenant_id = t;
  delete from day_overrides        where tenant_id = t;
  delete from time_blocks          where tenant_id = t;
  delete from priority_slot_types  where tenant_id = t;
  delete from profiles             where tenant_id = t;
  delete from clubs                where tenant_id = t;
  delete from schedule_settings    where tenant_id = t;
  -- Fronta úloh (stahování zápasů, připomínky) nemá cizí klíč na kuželnu,
  -- takže kaskáda její úlohy nesmaže: zůstaly by čekat na neexistující kuželnu.
  delete from notification_jobs    where payload->>'tenant_id' = t::text;
  delete from tenants              where id = t;
end $$;
