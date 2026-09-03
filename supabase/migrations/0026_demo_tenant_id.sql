-- Demo (kuželna pro recenzi Google Play) přebírá pamatovatelné id
-- 00000000-0000-0000-0000-000000000001. Dosud ho držela první kuželna,
-- která ho dostala jen proto, že vznikla ještě před multitenancí (0005);
-- ta teď dostane náhodné uuid jako každá jiná.
--
-- Proč: id Demo je jediné, na které se dívá klient — AppConfig.demoTenantId
-- podle něj schovává Demo ve výběru kuželny při registraci. Chceme ho tedy
-- poznat na první pohled, ne ho hledat mezi náhodnými uuid.
--
-- Přečíslování primárního klíče: session_replication_role = replica vypne
-- triggery i kontroly cizích klíčů, potomci se přepíšou dynamicky podle
-- cizích klíčů na tenants, takže na žádnou tabulku nejde zapomenout.
-- Idempotentní: na produkci je přečíslováno ručně (mazání starých dat),
-- takže tam migrace jen projde.
--
-- POZOR pro starší nasazené buildy: schovávají Demo podle starého id, takže
-- se jim Demo ve výběru kuželny objeví, dokud nedostanou build ≥ 1.2.0.
set session_replication_role = replica;

do $$
declare
  v_demo constant uuid := '00000000-0000-0000-0000-0000000000de';
  v_target constant uuid := '00000000-0000-0000-0000-000000000001';
  m record;
  r record;
begin
  if not exists (select 1 from tenants where id = v_demo) then
    raise notice '0026: Demo cílové id už má (nebo neexistuje) — nic k přečíslování';
    return;
  end if;

  -- Nejdřív uvolnit cílové id, pak ho dát Demu.
  for m in
    select * from (
      select 1 as ord, v_target as old_id, gen_random_uuid() as new_id
      where exists (select 1 from tenants where id = v_target)
      union all
      select 2, v_demo, v_target
    ) moves
    order by ord
  loop
    update tenants set id = m.new_id where id = m.old_id;
    for r in
      select c.relname as tbl, a.attname as col
      from pg_constraint k
      join pg_class c on c.oid = k.conrelid
      join pg_attribute a on a.attrelid = k.conrelid and a.attnum = any (k.conkey)
      join pg_class f on f.oid = k.confrelid
      where k.contype = 'f'
        and f.relname = 'tenants'
        and f.relnamespace = 'public'::regnamespace
        and c.relnamespace = 'public'::regnamespace
      order by 1, 2
    loop
      execute format('update public.%I set %I = $1 where %I = $2',
                     r.tbl, r.col, r.col) using m.new_id, m.old_id;
    end loop;
    raise notice '0026: kuželna % -> %', m.old_id, m.new_id;
  end loop;
end $$;

set session_replication_role = default;

-- Pojistka: žádný potomek nesmí ukazovat na neexistující kuželnu.
do $$
declare
  r record;
  v_orphans bigint;
begin
  for r in
    select c.relname as tbl, a.attname as col
    from pg_constraint k
    join pg_class c on c.oid = k.conrelid
    join pg_attribute a on a.attrelid = k.conrelid and a.attnum = any (k.conkey)
    join pg_class f on f.oid = k.confrelid
    where k.contype = 'f'
      and f.relname = 'tenants'
      and f.relnamespace = 'public'::regnamespace
      and c.relnamespace = 'public'::regnamespace
  loop
    execute format(
      'select count(*) from public.%I x where x.%I is not null'
      ' and not exists (select 1 from tenants t where t.id = x.%I)',
      r.tbl, r.col, r.col) into v_orphans;
    if v_orphans > 0 then
      raise exception '0026 FAIL: %.% má % osiřelých řádků', r.tbl, r.col, v_orphans;
    end if;
  end loop;
end $$;
