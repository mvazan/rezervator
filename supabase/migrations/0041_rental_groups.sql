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

create table rental_groups (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null default current_tenant_id()
    references tenants (id) on delete cascade,
  renter_name text not null,
  color smallint not null default -2,
  created_by uuid not null references profiles (id),
  created_at timestamptz not null default now()
);
comment on table rental_groups is
  'One renter with several one-time rental dates (0041): the identity (name, colour) its rentals rows carry a copy of. A lone one-time rental has no group; rental_add_date creates one when a second date arrives, rental_group_prune removes it with the last date.';

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
alter publication supabase_realtime add table rental_groups;

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
