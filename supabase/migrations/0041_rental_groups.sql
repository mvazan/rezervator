-- 0041 — nepravidelné pronájmy: jeden nájemce, víc termínů.
--
-- Nájemce, který si dráhy bere opakovaně, ale nepravidelně, dosud znamenal
-- tolik pronájmů, kolik má termínů. rental_groups drží jeho identitu (jméno,
-- barvu); každý termín zůstává obyčejný jednorázový řádek rentals s vlastním
-- datem, časem a drahami — a s group_id.
--
-- Proto se tu NEMĚNÍ nic v kolizní logice: rental_occurs, rental_occurrences,
-- rental_conflicts ani kaskáda 0018. Termín ve skupině JE jednorázový
-- pronájem; že ho někdo drží za ruku, resolver nezajímá. Alternativa
-- (hlavička přes parent_id) by znamenala zvolnit tři omezení rentals a přepsat
-- rental_occurrences tak, aby děti hlavičky platily samy o sobě — dnes dítě
-- sérii jen upravuje (0021). Za čistší diagram to nestojí.
--
-- Týdenní série do skupiny nesmí (rentals_group_shape_check): série je
-- pravidlo bez konce, skupina je konečný seznam. Jsou to dvě různé věci.
--
-- color je integer se stejnou doménou jako rentals.color (0030/0031): ručně
-- vybraná barva se ukládá jako 0x1000000 | rgb, tedy 16777216–33554431, a do
-- smallintu se nevejde. Skupina svou barvu kopíruje na řádky rentals a
-- rental_add_date naopak barvu řádku kopíruje do nové skupiny — kdyby byl
-- sloupec užší než zdroj, první ručně vybraná barva by skončila na
-- "smallint out of range" (22003).

create table rental_groups (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null default current_tenant_id()
    references tenants (id) on delete cascade,
  renter_name text not null,
  color integer not null default -2,
  created_by uuid not null references profiles (id),
  created_at timestamptz not null default now(),
  constraint rental_groups_color_check check (
    color between -2 and 8 or color between 16777216 and 33554431)
);
comment on table rental_groups is
  'One renter with several one-time rental dates (0041): the identity (name, colour) its rentals rows carry a copy of. A lone one-time rental has no group; rental_add_date creates one when a second date arrives, rental_group_prune removes it with the last date.';
comment on column rental_groups.color is
  'Group colour, the same domain as rentals.color: -2 = the rental default, 0-8 a palette entry, 0x1000000|rgb a hand-picked colour.';

alter table rental_groups enable row level security;
create policy rental_groups_select on rental_groups for select
  using (tenant_id = current_tenant_id() and is_approved_or_kiosk());
create policy rental_groups_insert on rental_groups for insert
  with check (tenant_id = current_tenant_id() and is_admin());
create policy rental_groups_update on rental_groups for update
  using (tenant_id = current_tenant_id() and is_admin())
  with check (tenant_id = current_tenant_id() and is_admin());
create policy rental_groups_delete on rental_groups for delete
  using (tenant_id = current_tenant_id() and is_admin());
-- Stejný tvar jako rentals (0017): plné DML pro přihlášené, řádky řeší RLS.
grant select, insert, update, delete on rental_groups to authenticated;
revoke all on rental_groups from anon;
-- Do supabase_realtime tahle tabulka NEPATŘÍ: appka skupiny odvozuje
-- z řádků rentals, které už streamuje (rentalGroupsOf), a přejmenování se
-- ke klientu dostane přes rental_group_changed, který jméno i barvu na ty
-- řádky přepíše. Publikovat tabulku, kterou nikdo neodebírá, by znamenalo
-- posílat změny do prázdna — a pojistka v tenancy_rls.sql by hlídala mrtvou
-- konfiguraci.

-- ---------------------------------------------------------------------------
-- Vazba: do skupiny smí jen jednorázový řádek, který není výjimkou.
-- ---------------------------------------------------------------------------
alter table rentals
  add column group_id uuid references rental_groups (id) on delete cascade,
  add constraint rentals_group_shape_check check (
    group_id is null or (date is not null and parent_id is null));
create index rentals_group_idx on rentals (group_id) where group_id is not null;
comment on column rentals.group_id is
  'The rental_groups row this one-time date belongs to (0041); null for a lone one-time rental, a weekly series or an exception row.';

-- Při vložení/úpravě termínu ve skupině: skupina musí být z téhož tenantu a
-- jméno s barvou se berou z ní — vzor rental_exception_guard (0021).
create or replace function rental_group_guard()
returns trigger
language plpgsql security definer set search_path = public
as $$
declare
  v_group rental_groups;
begin
  select * into v_group from rental_groups where id = new.group_id;
  if not found or v_group.tenant_id <> new.tenant_id then
    raise exception 'rental_group_invalid';
  end if;
  new.renter_name := v_group.renter_name;
  new.color := v_group.color;
  return new;
end;
$$;
create trigger rental_group_guard
  before insert or update on rentals
  for each row when (new.group_id is not null)
  execute function rental_group_guard();

-- Úprava skupiny propíše jméno a barvu na její termíny — vzor
-- rental_series_changed (0021). Kopie na řádku musí zůstat: rental_occurrences
-- vrací renter_name tabuli i kiosku a nesmí kvůli tomu joinovat dál.
create or replace function rental_group_changed()
returns trigger
language plpgsql security definer set search_path = public
as $$
begin
  if old.renter_name is distinct from new.renter_name
     or old.color is distinct from new.color then
    update rentals set renter_name = new.renter_name, color = new.color
    where group_id = new.id;
  end if;
  return new;
end;
$$;
create trigger rental_group_changed
  after update on rental_groups
  for each row
  execute function rental_group_changed();

-- Skupina bez termínů nemá co držet: s posledním smazaným termínem zaniká.
-- Při mazání celé skupiny (kaskáda) je řádek skupiny už pryč a delete níže
-- nezasáhne nic — to je v pořádku.
create or replace function rental_group_prune()
returns trigger
language plpgsql security definer set search_path = public
as $$
begin
  if not exists (select 1 from rentals where group_id = old.group_id) then
    delete from rental_groups where id = old.group_id;
  end if;
  return null;
end;
$$;
create trigger rental_group_prune
  after delete on rentals
  for each row when (old.group_id is not null)
  execute function rental_group_prune();

-- ---------------------------------------------------------------------------
-- rental_add_date: jediný zápis, který sahá na víc řádků najednou.
-- ---------------------------------------------------------------------------
-- Přidání termínu k pronájmu, který skupinu ještě nemá: skupina vznikne z jeho
-- jména a barvy, řádek si ji osvojí a nový termín se zapíše k ní — v jedné
-- transakci. Ostatní zápisy (úprava termínu, skupiny, mazání) jdou přímo přes
-- RLS; tohle RPC je tu kvůli atomicitě, ne kvůli oprávněním.
-- Chyby ve stylu set_match_exception (0039).
create or replace function rental_add_date(
  p_rental uuid, p_date date, p_starts_at time, p_ends_at time,
  p_lanes smallint[], p_note text default '')
returns uuid
language plpgsql security definer set search_path = public
as $$
declare
  v_src rentals;
  v_group uuid;
  v_new uuid;
begin
  if auth.uid() is null then
    raise exception 'not_authenticated';
  end if;
  if not is_admin() then
    raise exception 'not_allowed';
  end if;
  -- for update: dva správci, kteří přidávají termín ke stejnému pronájmu bez
  -- skupiny ve stejnou chvíli, by jinak oba viděli group_id = null, oba
  -- založili skupinu a pronájem by se rozpadl na dva. Zámek na zdrojovém
  -- řádku je drží za sebou — druhý uvidí už osvojený řádek.
  select * into v_src from rentals
   where id = p_rental and tenant_id = current_tenant_id()
   for update;
  -- Týdenní série termíny nepřidává — má výjimky (0021).
  if not found or v_src.parent_id is not null or v_src.weekday is not null then
    raise exception 'unknown_rental';
  end if;

  v_group := v_src.group_id;
  if v_group is null then
    insert into rental_groups (tenant_id, renter_name, color, created_by)
    values (v_src.tenant_id, v_src.renter_name, v_src.color, auth.uid())
    returning id into v_group;
    update rentals set group_id = v_group where id = v_src.id;
  end if;

  insert into rentals (tenant_id, group_id, renter_name, color, date, lanes,
                       starts_at, ends_at, note, created_by)
  values (v_src.tenant_id, v_group, v_src.renter_name, v_src.color, p_date,
          p_lanes, p_starts_at, p_ends_at, coalesce(p_note, ''), auth.uid())
  returning id into v_new;
  return v_new;
end;
$$;
revoke all on function rental_add_date(uuid, date, time, time, smallint[], text)
  from public, anon;
grant execute on function rental_add_date(uuid, date, time, time, smallint[], text)
  to authenticated, service_role;
