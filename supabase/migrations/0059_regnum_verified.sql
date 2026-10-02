-- 0059 — registration numbers: who is who (follow-up to 0057).
--
-- 0057 matched a player to the ČKA register by name, and by club only when
-- the name had several owners. Parents and children of one name in one club,
-- and a new member who shares a name with someone in another club, made that
-- unsafe. Now:
--
-- * a MATCH's player is resolved through his page on the results service
--   (club and age) against the register — cached per player, by the service's
--   slug: site_player_regnums;
-- * a PROFILE is filled by itself only when the club leaves one person of that
--   name and no other profile of the alley bears it; otherwise the player picks himself from the candidates in Můj profil
--   (the regnum-lookup function, modes profile_candidates / profile_confirm).
--
-- What 0057 stored was derived by the looser rule, so it is dropped and
-- derived again: the name-keyed cache (player_regnums, replaced by
-- profiles.regnum_checked_at), and the numbers it put on profiles.

create table if not exists site_player_regnums (
  slug text primary key check (slug ~ '^[a-z0-9][a-z0-9-]{0,99}$'),
  regnum text check (regnum is null or regnum ~ '^[0-9]{1,8}$'),
  status text not null check (status in ('found', 'none', 'ambiguous')),
  looked_up_at timestamptz not null default now(),
  check ((status = 'found') = (regnum is not null))
);

alter table site_player_regnums enable row level security;
-- service_role first: pg_dump writes GRANTs in ACL order (see 0051).
revoke all on site_player_regnums from anon, authenticated;
grant all on site_player_regnums to service_role;

-- A PROFILE's own state replaces the name-keyed cache: when the function last
-- looked for the number of THIS profile and found nobody it could settle, so a
-- renamed or duplicate-named profile never inherits another's answer.
drop table if exists player_regnums;
alter table profiles add column if not exists regnum_checked_at timestamptz;
comment on column profiles.regnum_checked_at is
  'When regnum-lookup last looked for this profile''s registration number without settling it (0059); asked again after a week. Not updatable by the app.';
update profiles set regnum = null where regnum is not null;

-- One number, one player of an alley: a profile that picked (or was filled
-- with) the number another player of the alley holds is refused, so a parent's
-- number cannot end up on a child's profile as well.
create unique index if not exists profiles_regnum_tenant_idx
  on profiles (tenant_id, regnum) where regnum is not null;

comment on table site_player_regnums is
  'regnum-lookup cache of MATCH players, by results-service player slug (0059): resolved by the service page''s club and age against the register. Service role only.';
