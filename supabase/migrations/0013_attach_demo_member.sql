-- 0013 — attach the (dashboard-created) Play-review demo user to the Demo
-- tenant as an approved admin. Guarded so it's a no-op on a fresh DB where
-- the auth user doesn't exist yet (avoids seed_demo_member's hard error);
-- idempotent on prod where it does. See 0012_demo_seed.sql / PLAY.md.
do $$
begin
  if exists (
    select 1 from auth.users
    where lower(email) = 'playreview@vvrky.cz'
  ) then
    perform seed_demo_member('playreview@vvrky.cz');
  end if;
end $$;
