-- 0052 — a device's push token belongs to one profile at a time.
--
-- notify pushes to every profile whose fcm_token is set. The token is the
-- DEVICE's, not the account's, and nothing ever took it off the profile at
-- sign-out: after player A signed out on a phone, the phone kept receiving
-- A's reservations, reminders and cancellations, and once player B signed
-- in there B's profile got the very same token — both accounts' pushes
-- landed on B's phone.
--
-- The app now hands the token back on sign-out and deletes it at FCM
-- (Api.signOut, Push). That cannot reach every case: a sign-out offline, a
-- session that expired (no JWT left to write the profile with), an account
-- switched without signing out, and every phone still on an older app,
-- which saves its token with a plain own-row update. So the database keeps
-- the rule itself: whoever registers a token takes it from every other
-- profile — across alleys too, it is the same phone. A trigger rather than
-- an RPC because the older apps never call an RPC; they keep writing the
-- column (profiles_update_own + the fcm_token column grant), and the
-- trigger sees those writes too. A player still writes only their own row;
-- the trigger (security definer) is what reaches the other one.
--
-- 0049 is deployed: the function and trigger are replaced, the clean-up is
-- a no-op the second time.

create or replace function fcm_token_claim()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  -- Setting it to null does not fire this trigger again (see WHEN below).
  update profiles set fcm_token = null
  where fcm_token = new.fcm_token and id <> new.id;
  return null;
end;
$$;

-- UPDATE OF fires on every write of the column, the same value included:
-- a profile re-saving a token it already shares (from before 0052) still
-- takes it back from the other one.
-- A trigger function is nobody's to call: no default grant to anon or the
-- app (0046 stopped the table defaults; functions still get PUBLIC's).
revoke all on function fcm_token_claim() from public, anon, authenticated;

drop trigger if exists fcm_token_claim on profiles;
create trigger fcm_token_claim
  after insert or update of fcm_token on profiles
  for each row when (new.fcm_token is not null)
  execute function fcm_token_claim();

-- Tokens more than one profile holds right now. Nobody can tell which
-- holder is really signed in on that phone, so all of them let go; the one
-- who is takes it back the next time the app starts (Push.init saves the
-- token on every start) and until then gets their notifications by e-mail.
update profiles set fcm_token = null
where fcm_token in (
  select fcm_token from profiles
  where fcm_token is not null
  group by fcm_token
  having count(*) > 1);
