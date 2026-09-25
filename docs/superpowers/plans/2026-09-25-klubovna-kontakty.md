# Klubovna Kontakty Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Klubovna gets a Kontakty screen: the alley's registered players with the e-mail and phone each of them chose to show, to write, call or WhatsApp from the row. The phone becomes an optional registration field, and Můj profil → Kontakt edits it and holds both privacy switches.

**Architecture:** One additive migration `0048_contacts.sql` gives `profiles` a `phone` (E.164 check) and the `show_email` / `show_phone` switches (own-row column grants), gives `register_profile` an optional `p_phone`, and adds the security-definer RPC `contacts()`, which nulls a hidden e-mail or phone on the server. The app parses phones in a pure `lib/domain/phone.dart`, reads contacts through `Api.contacts()` / `contactsProvider`, and writes the player's own fields optimistically through `Api.updateMyContact`. On screen: `ContactsScreen` behind a new Klubovna hub entry, a phone field on `RegisterScreen`, and a `ContactCard` on `ProfileScreen`.

**Tech Stack:** Supabase (Postgres 15, PL/pgSQL, RLS, column grants), Flutter 3.38 + flutter_riverpod 3, url_launcher through `launchEmail` / `launchPhone` / `launchWeb` in `lib/core/ui.dart`, `flutter_test`.

**Spec:** `docs/superpowers/specs/2026-09-25-klubovna-kontakty-design.md` (approved by the user on 2026-09-25).

## Global Constraints

- Repo `/Users/mvazan/Home/rezervator`, branch `klubovna-kontakty`; run every command from the repo root.
- One commit per task; never `git push`, never deploy.
- Every commit message ends with the trailer line `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.
- UI copy is Czech and verbatim as listed here; code and comments are English.
- Colours come from `Theme.of(context).colorScheme`. The one exception is the club's own palette colour on the contact's dot, drawn by the existing `ColorDot`, which falls back to the neutral `colorScheme.surfaceContainerHighest` without a club. No hard-coded colours.
- Lists are Czech-alphabetical (`compareCzech`) or chronological. Contacts sort by `compareCzech` on the name.
- `supabase/migrations/0048_contacts.sql` is new, additive and idempotent (`add column if not exists`, `drop constraint if exists` + `add constraint`, `drop function if exists` + `create or replace function`, re-runnable grants). Running the whole file twice must succeed. Never edit 0001–0047: they are deployed.
- The local DB holds seed data only. After changing SQL, regenerate `supabase/schema.sql` with `tool/schema_snapshot.sh` (it runs `supabase db reset`, which is fine here) and update `docs/SCHEMA.md`.
- `profiles.phone text null`, stored in international form `+<digits>` (for example `+420777123456`) and checked by `phone is null or phone ~ '^\+[1-9][0-9]{7,14}$'` (E.164).
- `profiles.show_email boolean not null default true` and `profiles.show_phone boolean not null default true`. Both default to **on**, for existing players as well (the user's decision).
- `grant update (phone, show_email, show_phone) on profiles to authenticated`. The existing policy `profiles_update_own` limits the update to the player's own row.
- `register_profile` gets `p_phone text default null`: `drop function` of the old signature, then `create` with the extra parameter. Keep the grants. It validates the phone with the same pattern and raises `invalid_phone`.
- `contacts()` returns `id`, `display_name`, `nick`, `club_id`, `club_name`, `club_color`, `email` (null unless `show_email`) and `phone` (null unless `show_phone`).
  - It is `security definer`, `stable`, `set search_path = public`.
  - The caller must be approved and not a kiosk, otherwise it raises `not_allowed`. A superadmin visiting the alley passes.
  - It lists `current_tenant_id()`'s players who are approved, not a kiosk, not a placeholder and not a visiting superadmin, ordered by `display_name`.
  - Grants: `revoke all … from public, anon; grant execute … to authenticated`.
- Admin screens stay as they are; the contacts switches do not apply there.
- `lib/domain/phone.dart`:
  - `normalizePhone(String input) → String?` strips spaces, dashes, dots and brackets, turns a leading `00` into `+`, gives a bare 9-digit number `+420`, and must match E.164. An empty input returns null (the caller treats it as "no phone").
  - `formatPhone(String e164) → String` groups `+420` as `+420 777 123 456`; any other number is shown as stored.
  - `whatsappUri(String e164) → Uri` returns `https://wa.me/<digits without +>`.
- `invalid_phone` reads „Telefon nemá správný tvar — třeba +420 777 123 456.“. The registration field and the profile dialog use the same text inline. `not_allowed` maps as today: „Na tohle nemáš oprávnění.“
- Klubovna hub: a new entry „Kontakty“ with `Icons.contacts_outlined` and subtitle „Hráči kuželny — e-mail a telefon“. The Kuželny subtitle becomes „Adresy a vybavení kuželen“.
- `ContactsScreen` (`lib/features/clubhouse/contacts_screen.dart`):
  - AppBar „Kontakty“.
  - A quiet info line at the top: „Svůj e-mail a telefon můžeš v Kontaktech skrýt v Můj profil → Kontakt.“ The words „Můj profil“ are a link that opens `ProfileScreen`, the way the shell's profile icon does.
  - Search placeholder „Hledat jméno, přezdívku nebo oddíl“; diacritics- and case-insensitive through `foldDiacritics`, like `upcomingMatches` / `venuesMatching`.
  - One row per contact in Czech order:
    - a leading dot in the club colour (neutral without a club);
    - the name as title;
    - the subtitle `„nick“ · club name`, leaving out missing parts;
    - trailing `Icons.mail_outline` „Napsat e-mail“ (email shown), plus `Icons.phone_outlined` „Zavolat“ and `Icons.chat_outlined` „WhatsApp“ (phone shown). No new icon package.
  - A player with neither shown gets the muted trailing text „kontakt skrytý“. The player's own row is listed like any other.
  - States: empty „Zatím tu nikdo není.“; no search hits „Nikdo takový tu není.“; load error = the `friendlyDbError` text with „Zkusit znovu“. Pull-to-refresh re-fetches.
  - The actions call `launchEmail`, `launchPhone` and `launchWeb` (the wa.me link), injectable like `VenueDetailScreen`'s.
- Registration: an optional field „Telefon (nepovinné)“ with a phone keyboard. An invalid value is refused inline; a valid one is normalised and passed to `register_profile`.
- Můj profil card „Kontakt“:
  - „Telefon“ shows the formatted number or „nenastaven“; „Upravit“ opens a dialog with a field, validation, Zrušit / Uložit. An empty value removes the phone.
  - Switch „Ukázat e-mail v Kontaktech“, subtitle „Ostatní hráči kuželny ti můžou napsat.“
  - Switch „Ukázat telefon v Kontaktech“, subtitle „Zavolat nebo napsat přes WhatsApp.“ It works without a phone too.
  - Both switches save at once through the optimistic write pattern (`optimisticWrite` + `patchRow` on `cacheKeyProfile`), as the other profile settings do.
- Changelog: the web batch at the top of `changelog_data.dart` gets „Klubovna → Kontakty: e-mail a telefon hráčů kuželny. Svůj e-mail i telefon můžeš skrýt v Můj profil → Kontakt.“ No `store:` summary: the batch stays at 459 characters, under 500.
- Gates:
  - `flutter analyze` → `No issues found!`
  - `TZ=Europe/Prague flutter test` → `All tests passed!`
  - `deno test --allow-read supabase/functions`
  - `psql "$DB_URL" -X -v ON_ERROR_STOP=1 -f supabase/tests/tenancy_rls.sql`, with `DB_URL` from `supabase status -o env`. Every shell here is fresh, so the commands below inline it as `"$(supabase status -o env | sed -n 's/^DB_URL="\(.*\)"/\1/p')"`.
  - The schema snapshot diff: `tool/schema_snapshot.sh && git diff --exit-code supabase/schema.sql`.

## Plan decisions (where the spec is silent)

1. **A hidden field is null, and so is an empty e-mail.** `contacts()` returns `nullif(email, '')`: a player whose account has no e-mail gets no button rather than a `mailto:` with no address.
2. **anon is refused by the grant, not by the body.** Without EXECUTE, anon gets `permission denied for function contacts` (`insufficient_privilege`) before `not_allowed` could be raised. Section 19c pins both the missing privilege and the failed call.
3. **The server checks the phone and does not reformat it.** `register_profile` stores `p_phone` as given when it is E.164; a blank one means none. The app normalises first (`normalizePhone`), so the server never guesses a country.
4. **`register_profile`'s grants.** The old function had the default ACL (EXECUTE for PUBLIC). The new one gets Postgres' default plus 0017's function defaults, which gives the same callers. The migration also grants `authenticated` and `service_role` explicitly. `create_tenant_and_register` calls `register_profile` with four positional arguments. PL/pgSQL records no dependency, so the drop does not cascade and the call resolves through the default. Section 19e tests that path.
5. **`Api.updateMyContact(phone: '')` removes the phone.** In the spec's signature, `phone: null` means "leave it alone". `contactFields` maps `''` to a database null.
6. **`friendlyDbError` also maps `profiles_phone_check`** to the `invalid_phone` copy. The profile writes the phone by a plain table update, so a bad value would surface as the constraint's name, not as `invalid_phone`.
7. **`contactsProvider` is `FutureProvider.autoDispose`,** so every opening of Kontakty fetches afresh. It is still invalidated in `resetTenantScopedProviders`. Coming back from Můj profil through the note's link invalidates it too, so a switch just flipped shows at once.
8. **A founder's phone.** `create_tenant_and_register` takes no phone, and the spec keeps it as it is. When someone founds a new alley, the register screen saves the typed phone through `updateMyContact(phone: …)` right after the alley is founded. The phone is not dropped.
9. **The Kontakt card sits between Google kalendář and Vzhled.** Settings about the player come first and Vzhled, which is about the app, stays last (its own comment says so). This also keeps the existing profile tests' fixed viewports valid. Near the top, the card pushed the Tabule card out of the default 800×600 build window and broke 16 tests.
10. **Hub order:** Výsledky, Kuželny, Kontakty (the new entry is appended).
11. **Copy this plan adds:**
    - the phone dialog's title „Telefon“ and its hint `+420 777 123 456`;
    - „Uloženo.“ after the phone is saved (as after the nick edit);
    - the card header is „Kontakt“ alone, with no subtitle;
    - the switches save silently, like the other profile toggles.
12. **The link is tested through its recognizer.** `tester.tapOnText` on „Můj profil“ lands on a glyph edge under the test font's letter spacing and misses, so the test finds the span's `TapGestureRecognizer` and fires it.
13. **The search lives in `lib/domain/contacts.dart`** as `contactsMatching`, mirroring `venuesMatching`: name, board nick and club name, folded with `foldDiacritics`, then sorted with `compareCzech`.
14. **Registration checks the phone last,** after name, alley and the new alley's name. The inline error clears as soon as the field changes.

## File structure

| File | Responsibility |
|---|---|
| `supabase/migrations/0048_contacts.sql` (new) | `profiles.phone` / `show_email` / `show_phone`, column grants, `register_profile` v2, `contacts()` |
| `supabase/tests/tenancy_rls.sql` | section 19 (0048) |
| `supabase/schema.sql`, `docs/SCHEMA.md` | snapshot and docs |
| `lib/domain/phone.dart` (new) | `e164Pattern`, `invalidPhoneMessage`, `normalizePhone`, `formatPhone`, `whatsappUri` |
| `lib/domain/models.dart` | `Profile.phone` / `showEmail` / `showPhone`, `Contact` |
| `lib/domain/contacts.dart` (new) | `contactsMatching` |
| `lib/data/providers.dart` | `Api.registerProfile(phone)`, `Api.updateMyContact`, `Api.contacts`, `contactFields`, `contactsProvider`, tenant reset |
| `lib/core/ui.dart` | `friendlyDbError`: `invalid_phone`, `profiles_phone_check` |
| `lib/features/clubhouse/contacts_screen.dart` (new) | Kontakty |
| `lib/features/clubhouse/clubhouse_screen.dart` | hub entry, Kuželny subtitle |
| `lib/features/auth/register_screen.dart` | phone field, injectable backend calls |
| `lib/features/profile/widgets/contact_card.dart` (new) | Kontakt card + phone dialog |
| `lib/features/profile/profile_screen.dart` | places the card, injectable `updateMyContact` |
| `lib/features/profile/changelog_data.dart` | the changelog line |

---

### Task 1: Contacts in the database — migration 0048, SQL tests, snapshot, docs

**Files:**
- Create: `supabase/migrations/0048_contacts.sql`
- Modify: `supabase/tests/tenancy_rls.sql` (new section 19 before the file's final `rollback;`)
- Modify: `supabase/schema.sql` (regenerated), `docs/SCHEMA.md`
- Test: `supabase/tests/tenancy_rls.sql`

**Interfaces:**
- Consumes:
  - `profiles`, with the RLS policies `profiles_select` (own row, or an admin of the same tenant) and `profiles_update_own` (`id = auth.uid()`);
  - `is_approved()`, `is_kiosk()`, `current_tenant_id()`;
  - `clubs(id, name, color)`;
  - 0022's `register_profile(p_display_name text, p_tenant_id uuid, p_club_id uuid default null, p_nick text default '') returns profiles`;
  - `create_tenant_and_register(p_tenant_name text, p_display_name text, p_nick text default '')`, which calls `register_profile(p_display_name, v_tenant_id, null, p_nick)`.
- Produces:
  - `profiles.phone text` (null or E.164, constraint `profiles_phone_check`), `profiles.show_email boolean not null default true`, `profiles.show_phone boolean not null default true`, all three updatable by `authenticated` (own row).
  - `register_profile(p_display_name text, p_tenant_id uuid, p_club_id uuid default null, p_nick text default '', p_phone text default null) returns profiles`. It raises `invalid_phone`; the four-argument signature is gone.
  - `contacts() returns table (id uuid, display_name text, nick text, club_id uuid, club_name text, club_color integer, email text, phone text)`. It raises `not_allowed`; EXECUTE is for `authenticated` only. PostgREST hands it to the app as a JSON array of objects with exactly these keys.

- [ ] **Step 1: Write the failing test**

In `supabase/tests/tenancy_rls.sql` replace the end of the file:

```sql
  raise notice 'OK: a moved kuželna drops the old one''s discovery job; the same one and other alleys keep theirs (0047)';
end $$;

rollback;
```

with:

```sql
  raise notice 'OK: a moved kuželna drops the old one''s discovery job; the same one and other alleys keep theirs (0047)';
end $$;

-- 0048 Klubovna → Kontakty ---------------------------------------------------
reset role;

-- 19. contacts(): the alley's registered players — approved, not the kiosk,
-- not a placeholder, not a visiting superadmin — each with the e-mail and
-- phone they chose to show. Alleys of its own (E, and F next door) keep
-- the lists exact.
insert into tenants (id, name, status) values
  ('00000000-0000-0000-0000-00000000000e', 'Kuželna E (0048)', 'approved'),
  ('00000000-0000-0000-0000-00000000000f', 'Kuželna F (0048)', 'approved');
insert into clubs (id, tenant_id, name, color) values
  ('40000000-0000-0000-0000-0000000000c1', '00000000-0000-0000-0000-00000000000e',
   'Oddíl E', 3);
insert into profiles (id, tenant_id, display_name, nick, email, phone, club_id,
                      role, status, show_email, show_phone, placeholder)
values
  ('40000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-00000000000e',
   'Adam Admin', 'Áďa', 'adam@example.com', '+420777000001',
   '40000000-0000-0000-0000-0000000000c1', 'admin', 'approved', true, true, false),
  ('40000000-0000-0000-0000-000000000002', '00000000-0000-0000-0000-00000000000e',
   'Běla Skrytá', '', 'bela@example.com', '+420777000002',
   null, 'player', 'approved', false, true, false),
  ('40000000-0000-0000-0000-000000000003', '00000000-0000-0000-0000-00000000000e',
   'Cyril Tichý', '', 'cyril@example.com', '+420777000003',
   null, 'player', 'approved', true, false, false),
  ('40000000-0000-0000-0000-000000000004', '00000000-0000-0000-0000-00000000000e',
   'Dana Čekající', '', 'dana@example.com', null,
   null, 'player', 'pending', true, true, false),
  ('40000000-0000-0000-0000-000000000005', '00000000-0000-0000-0000-00000000000e',
   'Kiosk E', '', 'kiosk-e@example.com', null,
   null, 'kiosk', 'approved', true, true, false),
  ('40000000-0000-0000-0000-000000000006', '00000000-0000-0000-0000-00000000000e',
   'Bez účtu E', '', '', null,
   null, 'player', 'approved', true, true, true),
  ('40000000-0000-0000-0000-000000000008', '00000000-0000-0000-0000-00000000000e',
   'Eva Bez Mailu', '', '', null,
   null, 'player', 'approved', true, true, false),
  ('40000000-0000-0000-0000-000000000011', '00000000-0000-0000-0000-00000000000f',
   'Filip Cizí', '', 'filip@example.com', '+420777000011',
   null, 'player', 'approved', true, true, false);
-- A superadmin at home in A, visiting E.
insert into profiles (id, tenant_id, display_name, email, role, status,
                      superadmin, home_tenant_id)
values ('40000000-0000-0000-0000-000000000007', '00000000-0000-0000-0000-00000000000e',
        'Super Návštěva', 'super-e@example.com', 'admin', 'approved',
        true, '00000000-0000-0000-0000-00000000000a');

set local role authenticated;
set local request.jwt.claims =
  '{"sub":"40000000-0000-0000-0000-000000000001","role":"authenticated"}';
do $$
declare
  v_names text[];
  v jsonb;
begin
  select array_agg(t.display_name order by t.o) into v_names
    from contacts() with ordinality
         as t(id, display_name, nick, club_id, club_name, club_color, email, phone, o);
  if v_names is distinct from
     array['Adam Admin', 'Běla Skrytá', 'Cyril Tichý', 'Eva Bez Mailu'] then
    raise exception 'FAIL: contacts should list the alley''s registered players by name, nobody else: %',
      v_names;
  end if;
  select jsonb_object_agg(c.display_name, jsonb_build_object(
           'nick', c.nick, 'club_id', c.club_id, 'club', c.club_name,
           'color', c.club_color, 'email', c.email, 'phone', c.phone))
    into v from contacts() c;
  if v is distinct from '{
       "Adam Admin": {"nick": "Áďa", "club_id": "40000000-0000-0000-0000-0000000000c1",
                      "club": "Oddíl E", "color": 3,
                      "email": "adam@example.com", "phone": "+420777000001"},
       "Běla Skrytá": {"nick": "", "club_id": null, "club": null, "color": -1,
                       "email": null, "phone": "+420777000002"},
       "Cyril Tichý": {"nick": "", "club_id": null, "club": null, "color": -1,
                       "email": "cyril@example.com", "phone": null},
       "Eva Bez Mailu": {"nick": "", "club_id": null, "club": null, "color": -1,
                         "email": null, "phone": null}}'::jsonb then
    raise exception 'FAIL: contacts returned the wrong fields, or a hidden e-mail or phone: %', v;
  end if;
  raise notice 'OK: contacts lists the alley''s registered players; a hidden e-mail or phone is null, the other still shows (0048)';
end $$;
reset role;

-- 19b. A visiting superadmin reads the alley they are in (and is not in
-- it); a player of another alley sees only their own.
set local role authenticated;
set local request.jwt.claims =
  '{"sub":"40000000-0000-0000-0000-000000000007","role":"authenticated"}';
do $$
begin
  if (select array_agg(display_name order by display_name) from contacts())
     is distinct from array['Adam Admin', 'Běla Skrytá', 'Cyril Tichý', 'Eva Bez Mailu'] then
    raise exception 'FAIL: a visiting superadmin should read the visited alley''s contacts';
  end if;
end $$;
set local request.jwt.claims =
  '{"sub":"40000000-0000-0000-0000-000000000011","role":"authenticated"}';
do $$
begin
  if (select array_agg(display_name) from contacts()) is distinct from array['Filip Cizí'] then
    raise exception 'FAIL: another alley''s player saw foreign contacts: %',
      (select array_agg(display_name) from contacts());
  end if;
  raise notice 'OK: a visiting superadmin reads the visited alley; another alley is invisible (0048)';
end $$;
reset role;

-- 19c. The pending player and the kiosk are refused; anon cannot call it.
set local role authenticated;
set local request.jwt.claims =
  '{"sub":"40000000-0000-0000-0000-000000000004","role":"authenticated"}';
do $$
begin
  perform contacts();
  raise exception 'FAIL: a pending player read the contacts';
exception when others then
  if sqlerrm <> 'not_allowed' then raise; end if;
end $$;
set local request.jwt.claims =
  '{"sub":"40000000-0000-0000-0000-000000000005","role":"authenticated"}';
do $$
begin
  perform contacts();
  raise exception 'FAIL: the kiosk read the contacts';
exception when others then
  if sqlerrm <> 'not_allowed' then raise; end if;
end $$;
reset role;
set local role anon;
set local request.jwt.claims = '{"role":"anon"}';
do $$
begin
  perform contacts();
  raise exception 'FAIL: anon read the contacts';
exception when insufficient_privilege then null;
end $$;
reset role;
do $$
begin
  if has_function_privilege('anon', 'public.contacts()', 'execute')
     or not has_function_privilege('authenticated', 'public.contacts()', 'execute') then
    raise exception 'FAIL: contacts must be callable by signed-in users only';
  end if;
  raise notice 'OK: the pending player and the kiosk get not_allowed; anon cannot call contacts (0048)';
end $$;

-- 19d. A player writes their own phone and switches — nobody else's, not
-- even the alley's admin — and the phone must be E.164.
set local role authenticated;
set local request.jwt.claims =
  '{"sub":"40000000-0000-0000-0000-000000000002","role":"authenticated"}';
do $$
declare
  n integer;
begin
  update profiles set phone = '+420777999002', show_email = true, show_phone = false
   where id = auth.uid();
  if not exists (select 1 from profiles
                  where id = auth.uid() and phone = '+420777999002'
                    and show_email and not show_phone) then
    raise exception 'FAIL: a player could not update their own phone and switches';
  end if;
  update profiles set phone = '+420777999001', show_email = false
   where id = '40000000-0000-0000-0000-000000000001';
  get diagnostics n = row_count;
  if n <> 0 then
    raise exception 'FAIL: a player updated another player''s contact';
  end if;
  begin
    update profiles set phone = '777123456' where id = auth.uid();
    raise exception 'FAIL: a phone without the country code was stored';
  exception when check_violation then null;
  end;
  begin
    update profiles set phone = '+0777123456' where id = auth.uid();
    raise exception 'FAIL: a phone starting +0 was stored';
  exception when check_violation then null;
  end;
  begin
    update profiles set phone = '+4207771234567890' where id = auth.uid();
    raise exception 'FAIL: a 16-digit phone was stored';
  exception when check_violation then null;
  end;
end $$;
set local request.jwt.claims =
  '{"sub":"40000000-0000-0000-0000-000000000001","role":"authenticated"}';
do $$
declare
  n integer;
begin
  update profiles set phone = null, show_phone = true
   where id = '40000000-0000-0000-0000-000000000002';
  get diagnostics n = row_count;
  if n <> 0 or not exists (select 1 from profiles
                            where id = '40000000-0000-0000-0000-000000000002'
                              and phone = '+420777999002' and not show_phone) then
    raise exception 'FAIL: the admin changed a player''s phone or switch';
  end if;
  raise notice 'OK: a player updates only their own phone and switches; the phone must be E.164 (0048)';
end $$;
reset role;

-- 19e. register_profile takes the phone (E.164 or blank) and refuses any
-- other; an old-style call without p_phone still resolves, and so does
-- create_tenant_and_register's four positional arguments.
set local role authenticated;
set local request.jwt.claims =
  '{"sub":"40000000-0000-0000-0000-000000000021","role":"authenticated"}';
do $$
declare
  v_p profiles;
begin
  v_p := register_profile('Nováček s telefonem', '00000000-0000-0000-0000-00000000000e',
                          null, '', '+420777000021');
  if v_p.phone is distinct from '+420777000021' or v_p.status <> 'pending'
     or not v_p.show_email or not v_p.show_phone then
    raise exception 'FAIL: register_profile did not store the phone: %', to_jsonb(v_p);
  end if;
end $$;
set local request.jwt.claims =
  '{"sub":"40000000-0000-0000-0000-000000000022","role":"authenticated"}';
do $$
begin
  begin
    perform register_profile('Špatné číslo', '00000000-0000-0000-0000-00000000000e',
                             null, '', '777000022');
    raise exception 'FAIL: register_profile stored a phone without the country code';
  exception when others then
    if sqlerrm <> 'invalid_phone' then raise; end if;
  end;
  if exists (select 1 from profiles where id = auth.uid()) then
    raise exception 'FAIL: a refused registration left a profile behind';
  end if;
end $$;
set local request.jwt.claims =
  '{"sub":"40000000-0000-0000-0000-000000000023","role":"authenticated"}';
do $$
declare
  v_p profiles;
begin
  v_p := register_profile(p_display_name => 'Starý klient',
                          p_tenant_id => '00000000-0000-0000-0000-00000000000e',
                          p_club_id => null, p_nick => 'Starý');
  if v_p.id is null or v_p.phone is not null then
    raise exception 'FAIL: a call without p_phone did not register: %', to_jsonb(v_p);
  end if;
end $$;
set local request.jwt.claims =
  '{"sub":"40000000-0000-0000-0000-000000000024","role":"authenticated"}';
do $$
declare
  v_p profiles;
begin
  v_p := register_profile('Prázdný telefon', '00000000-0000-0000-0000-00000000000e',
                          null, '', '   ');
  if v_p.phone is not null then
    raise exception 'FAIL: a blank phone was stored as %', v_p.phone;
  end if;
end $$;
set local request.jwt.claims =
  '{"sub":"40000000-0000-0000-0000-000000000025","role":"authenticated"}';
do $$
declare
  v_p profiles;
begin
  v_p := create_tenant_and_register('Kuželna G (0048)', 'Zakladatel G');
  if v_p.role <> 'admin' or v_p.status <> 'approved' or v_p.phone is not null then
    raise exception 'FAIL: create_tenant_and_register broke with the new register_profile: %',
      to_jsonb(v_p);
  end if;
end $$;
reset role;
do $$
begin
  if to_regprocedure('public.register_profile(text, uuid, uuid, text)') is not null then
    raise exception 'FAIL: the four-argument register_profile is still there';
  end if;
  if not has_function_privilege('authenticated',
       'public.register_profile(text, uuid, uuid, text, text)', 'execute')
     or not has_column_privilege('authenticated', 'public.profiles', 'phone', 'update')
     or not has_column_privilege('authenticated', 'public.profiles', 'show_email', 'update')
     or not has_column_privilege('authenticated', 'public.profiles', 'show_phone', 'update') then
    raise exception 'FAIL: the app lost register_profile or the contact columns';
  end if;
  raise notice 'OK: register_profile stores a phone and refuses a bad one; calls without p_phone still work (0048)';
end $$;

rollback;
```

- [ ] **Step 2: Run it to verify it fails**

Run: `psql "$(supabase status -o env | sed -n 's/^DB_URL="\(.*\)"/\1/p')" -X -v ON_ERROR_STOP=1 -f supabase/tests/tenancy_rls.sql 2>&1 | grep -E 'ERROR|FAIL'`
Expected: `ERROR:  column "phone" of relation "profiles" does not exist`

- [ ] **Step 3: Write the migration**

Create `supabase/migrations/0048_contacts.sql`:

```sql
-- 0048 — Klubovna → Kontakty: a phone number on the profile, and each
-- player's choice whether their e-mail and phone show to the other players
-- of the alley. Spec: docs/superpowers/specs/2026-09-25-klubovna-kontakty-design.md
-- 0047 is deployed: everything here is additive and safe to run twice.

-- ------------------------------------------------- profiles: contact
alter table profiles add column if not exists phone text;
alter table profiles add column if not exists show_email boolean not null default true;
alter table profiles add column if not exists show_phone boolean not null default true;
alter table profiles drop constraint if exists profiles_phone_check;
alter table profiles add constraint profiles_phone_check
  check (phone is null or phone ~ '^\+[1-9][0-9]{7,14}$');
comment on column profiles.phone is
  'The player''s phone in international form (E.164, +<digits>, profiles_phone_check); null = none. The app normalises what the player types (lib/domain/phone.dart).';
comment on column profiles.show_email is
  'Whether contacts() hands this player''s e-mail to the other players of the alley (0048). On by default, for existing players too.';
comment on column profiles.show_phone is
  'Whether contacts() hands this player''s phone to the other players of the alley (0048). On by default, for existing players too.';

-- Own row only: profiles_update_own limits every update to id = auth.uid().
grant update (phone, show_email, show_phone) on profiles to authenticated;

-- ------------------------------------------------- register_profile
-- 0022's register_profile plus p_phone. The old four-argument signature is
-- dropped, not overloaded: a call without p_phone (the 1.2.x app, and
-- create_tenant_and_register, which passes four positional arguments) then
-- resolves to this one through the default. Both resolve at call time —
-- PL/pgSQL records no dependency, so the drop does not cascade.
drop function if exists register_profile(text, uuid, uuid, text);

create or replace function register_profile(
  p_display_name text,
  p_tenant_id uuid,
  p_club_id uuid default null,
  p_nick text default '',
  p_phone text default null)
returns profiles language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := auth.uid();
  v_profile profiles;
  v_tenant tenants;
  v_first boolean;
  v_phone constant text := nullif(trim(coalesce(p_phone, '')), '');
begin
  if v_uid is null then
    raise exception 'not_authenticated';
  end if;

  select * into v_profile from profiles where id = v_uid;
  if found then
    return v_profile;
  end if;

  if trim(p_display_name) = '' then
    raise exception 'empty_display_name';
  end if;
  if char_length(trim(coalesce(p_nick, ''))) > 14 then
    raise exception 'nick_too_long';
  end if;
  if v_phone is not null and v_phone !~ '^\+[1-9][0-9]{7,14}$' then
    raise exception 'invalid_phone';
  end if;

  select * into v_tenant from tenants where id = p_tenant_id;
  if not found then
    raise exception 'unknown_tenant';
  end if;

  if p_club_id is not null and not exists (
    select 1 from clubs where id = p_club_id and tenant_id = p_tenant_id
  ) then
    raise exception 'unknown_club';
  end if;

  -- Serialize concurrent registrations into the same tenant so exactly one
  -- founder can win the race.
  perform pg_advisory_xact_lock(
    hashtext('register_profile'), hashtext(p_tenant_id::text));

  select not exists (
    select 1 from profiles
    where tenant_id = p_tenant_id and status = 'approved'
      and not placeholder
  ) into v_first;
  if v_tenant.founder_email is not null then
    v_first := v_first
      and lower(coalesce(auth.email(), '')) = lower(v_tenant.founder_email);
  end if;

  insert into profiles
    (id, tenant_id, display_name, club_id, nick, email, phone,
     role, status, approved_at)
  values (
    v_uid,
    p_tenant_id,
    trim(p_display_name),
    p_club_id,
    trim(coalesce(p_nick, '')),
    coalesce(auth.email(), ''),
    v_phone,
    case when v_first then 'admin' else 'player' end,
    case when v_first then 'approved' else 'pending' end,
    case when v_first then now() end
  )
  returning * into v_profile;

  return v_profile;
end;
$$;

-- The dropped function was callable by everyone (its ACL was the default,
-- PUBLIC); the new one gets the same through Postgres' own default plus
-- 0017's default privileges. Spelled out for the app and the service.
grant execute on function register_profile(text, uuid, uuid, text, text)
  to authenticated, service_role;

-- ------------------------------------------------------- contacts()
-- Klubovna → Kontakty. The alley's registered players — approved, not the
-- kiosk, not a hand-made placeholder (0022), not a superadmin who is only
-- visiting (the players view's rule) — with the e-mail and phone each of
-- them chose to show; a hidden one is null here, so it never leaves the
-- database. profiles RLS shows a player their own row only, hence security
-- definer. Callers: an approved member of the alley, not the kiosk (a
-- visiting superadmin is one — current_tenant_id() is where they are).
create or replace function contacts()
returns table (id uuid, display_name text, nick text, club_id uuid,
               club_name text, club_color integer, email text, phone text)
language plpgsql stable security definer set search_path = public as $$
begin
  if not is_approved() or is_kiosk() then
    raise exception 'not_allowed';
  end if;
  return query
    select p.id, p.display_name, p.nick, p.club_id, c.name,
           coalesce(c.color, -1),
           case when p.show_email then nullif(p.email, '') end,
           case when p.show_phone then p.phone end
      from profiles p
      left join clubs c on c.id = p.club_id
     where p.tenant_id = current_tenant_id()
       and p.status = 'approved'
       and p.role <> 'kiosk'
       and not p.placeholder
       and not (p.superadmin
                and p.home_tenant_id is not null
                and p.tenant_id <> p.home_tenant_id)
     order by p.display_name;
end;
$$;

revoke all on function contacts() from public, anon;
grant execute on function contacts() to authenticated;
```

- [ ] **Step 4: Apply it, twice**

Run: `supabase migration up --local`
Expected: `Applying migration 0048_contacts.sql...` then `Local database is up to date.`

Run: `psql "$(supabase status -o env | sed -n 's/^DB_URL="\(.*\)"/\1/p')" -X -v ON_ERROR_STOP=1 -q -f supabase/migrations/0048_contacts.sql; echo "exit $?"`
Expected: `NOTICE`s such as `column "phone" of relation "profiles" already exists, skipping` and `function register_profile(text,uuid,uuid,text) does not exist, skipping`, then `exit 0`.

- [ ] **Step 5: Run the test to verify it passes**

Run: `psql "$(supabase status -o env | sed -n 's/^DB_URL="\(.*\)"/\1/p')" -X -v ON_ERROR_STOP=1 -f supabase/tests/tenancy_rls.sql 2>&1 | grep -E 'ERROR|FAIL|0048\)'`
Expected: no `ERROR`/`FAIL`, and exactly these five lines:
```
NOTICE:  OK: contacts lists the alley's registered players; a hidden e-mail or phone is null, the other still shows (0048)
NOTICE:  OK: a visiting superadmin reads the visited alley; another alley is invisible (0048)
NOTICE:  OK: the pending player and the kiosk get not_allowed; anon cannot call contacts (0048)
NOTICE:  OK: a player updates only their own phone and switches; the phone must be E.164 (0048)
NOTICE:  OK: register_profile stores a phone and refuses a bad one; calls without p_phone still work (0048)
```

- [ ] **Step 6: Document it in `docs/SCHEMA.md`**

In the `profiles` row of the Tables section, replace the fragment:
```
what the app opens at launch); both own-row updatable (0029) | select: own row, or admin of the same tenant. update: own row, columns `display_name`, `fcm_token`, `own_color`, `followed_teams`, `default_view` only. insert/delete: RPC only. |
```
with:
```
what the app opens at launch); both own-row updatable (0029); `phone` (0048: E.164 `+<digits>`, `profiles_phone_check` = `^\+[1-9][0-9]{7,14}$`, null = none), `show_email` / `show_phone` (0048: default true, for existing rows too — whether `contacts()` hands the e-mail / phone to the alley's players) | select: own row, or admin of the same tenant. update: own row, columns `display_name`, `fcm_token`, `own_color`, `followed_teams`, `default_view`, `notify_before_minutes`, `phone`, `show_email`, `show_phone` only. insert/delete: RPC only. |
```

Replace (end of the `players` view paragraph):
```
ACL). This is the only profile data the kiosk account can read. SELECT for
`authenticated` only.
```
with:
```
ACL). This is the only profile data the kiosk account can read. SELECT for
`authenticated` only.

`contacts()` (0048) is the one other way to another player's profile: the
players' own switches decide whether their e-mail and phone leave the
database at all (see RPCs).
```

Replace the `register_profile` row of the RPC table:
```
| `register_profile(display_name, tenant_id, club_id?, nick?)` | signed-in user without a profile | First approved member of a tenant (or the `founder_email` match) becomes approved admin, everyone else pending; placeholders never count as the first member. `empty_display_name`, `nick_too_long`, `unknown_tenant`, `unknown_club`. |
```
with:
```
| `register_profile(display_name, tenant_id, club_id?, nick?, phone?)` | signed-in user without a profile | First approved member of a tenant (or the `founder_email` match) becomes approved admin, everyone else pending; placeholders never count as the first member. `phone` (0048) is stored as given when E.164, blank = none — the app normalises it first (`lib/domain/phone.dart`). 0048 dropped the four-argument signature: a call without `p_phone` (the 1.2.x app, `create_tenant_and_register`) resolves to this one through the default. `empty_display_name`, `nick_too_long`, `invalid_phone`, `unknown_tenant`, `unknown_club`. |
```

Replace the `set_nick` row:
```
| `set_nick(user_id, nick)` | self or admin | `nick_too_long`. |
```
with:
```
| `set_nick(user_id, nick)` | self or admin | `nick_too_long`. |
| `contacts()` (0048) | approved member, not the kiosk (a visiting superadmin counts, for the alley they are in) | Klubovna → Kontakty: the caller's alley's registered players — approved, not the kiosk, not a placeholder, not a visiting superadmin (the `players` view's rule) — as `(id, display_name, nick, club_id, club_name, club_color, email, phone)`, ordered by `display_name` (the app re-sorts Czech). `email` is null unless `show_email` (and for an empty one), `phone` null unless `show_phone`: a hidden one never leaves the database. Admin screens keep reading `profiles` as before; the switches do not apply there. `not_allowed`; anon has no EXECUTE. |
```

In the Checks section, replace:
```
  fetch), and the 0035
```
with:
```
  fetch), the 0048 contacts (`contacts()` lists the alley's registered
  players only — no placeholder, kiosk, pending member or visiting
  superadmin, who may still read it — with a hidden e-mail or phone null
  and the other still shown; the kiosk and a pending member refused, anon
  without EXECUTE, another alley invisible; phone and switches own-row
  only, even against the admin; the E.164 check; `register_profile` with a
  phone, a refused one, a blank one, a named call without `p_phone`, and
  `create_tenant_and_register` on top of it), and the 0035
```

- [ ] **Step 7: Regenerate the schema snapshot and re-run the test on the rebuilt DB**

Run: `tool/schema_snapshot.sh && git diff --stat supabase/schema.sql`
Expected: `supabase/schema.sql regenerated`. The diff touches `supabase/schema.sql`: the `profiles` columns `phone` / `show_email` / `show_phone`, `profiles_phone_check`, their comments, the five-argument `register_profile` and its grants, `contacts()` with its grants, and the `GRANT UPDATE("phone")` / `("show_email")` / `("show_phone")` lines.

Run: `psql "$(supabase status -o env | sed -n 's/^DB_URL="\(.*\)"/\1/p')" -X -v ON_ERROR_STOP=1 -q -f supabase/tests/tenancy_rls.sql > /dev/null 2>&1; echo "exit $?"`
Expected: `exit 0`.

- [ ] **Step 8: Commit**

```bash
git add supabase/migrations/0048_contacts.sql supabase/tests/tenancy_rls.sql supabase/schema.sql docs/SCHEMA.md
git commit -m "$(cat <<'EOF'
feat(db): a phone and contact privacy on profiles, contacts() and register_profile's phone (0048)

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 2: Phone parsing and formatting

**Files:**
- Create: `lib/domain/phone.dart`
- Test: `test/domain/phone_test.dart`

**Interfaces:**
- Consumes: nothing (pure Dart).
- Produces:
  ```dart
  final RegExp e164Pattern;                 // ^\+[1-9][0-9]{7,14}$ — profiles_phone_check
  const String invalidPhoneMessage;         // 'Telefon nemá správný tvar — třeba +420 777 123 456.'
  String? normalizePhone(String input);     // '777 123 456' → '+420777123456'; '' / junk → null
  String formatPhone(String e164);          // '+420777123456' → '+420 777 123 456'; others unchanged
  Uri whatsappUri(String e164);             // '+420777123456' → https://wa.me/420777123456
  ```

- [ ] **Step 1: Write the failing test**

Create `test/domain/phone_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:rezervator/domain/phone.dart';

void main() {
  group('normalizePhone', () {
    test('a bare Czech nine-digit number gets +420', () {
      expect(normalizePhone('777123456'), '+420777123456');
      expect(normalizePhone('777 123 456'), '+420777123456');
    });

    test('+420 with spaces, dashes, dots or brackets', () {
      expect(normalizePhone('+420 777 123 456'), '+420777123456');
      expect(normalizePhone(' +420-777-123-456 '), '+420777123456');
      expect(normalizePhone('+420 777.123.456'), '+420777123456');
      expect(normalizePhone('(+420) 777 123 456'), '+420777123456');
    });

    test('a leading 00 becomes +', () {
      expect(normalizePhone('00420 777 123 456'), '+420777123456');
      expect(normalizePhone('0049 30 1234567'), '+49301234567');
    });

    test('a foreign number stays as typed, digits only', () {
      expect(normalizePhone('+49 30 1234567'), '+49301234567');
      expect(normalizePhone('+421 905 123 456'), '+421905123456');
    });

    test('junk, too short and too long are refused', () {
      expect(normalizePhone(''), isNull);
      expect(normalizePhone('   '), isNull);
      expect(normalizePhone('abc'), isNull);
      expect(normalizePhone('777 12a 456'), isNull);
      expect(normalizePhone('12345'), isNull);
      expect(normalizePhone('+420 12'), isNull);
      expect(normalizePhone('77712345'), isNull, reason: 'eight digits, no +');
      expect(normalizePhone('+4207771234567890'), isNull, reason: '16 digits');
      expect(normalizePhone('+0777123456'), isNull, reason: 'E.164 never +0');
    });

    test('every result passes the database rule', () {
      for (final input in ['777123456', '+49 30 1234567', '00420777123456']) {
        expect(e164Pattern.hasMatch(normalizePhone(input)!), isTrue);
      }
    });
  });

  group('formatPhone', () {
    test('a Czech number reads in threes', () {
      expect(formatPhone('+420777123456'), '+420 777 123 456');
    });

    test('any other number shows as stored', () {
      expect(formatPhone('+49301234567'), '+49301234567');
      expect(formatPhone('+421905123456'), '+421905123456');
    });
  });

  group('whatsappUri', () {
    test('wa.me with the digits, no plus', () {
      expect(whatsappUri('+420777123456').toString(),
          'https://wa.me/420777123456');
      expect(whatsappUri('+49301234567').toString(),
          'https://wa.me/49301234567');
    });
  });

  test('the invalid-phone copy', () {
    expect(invalidPhoneMessage,
        'Telefon nemá správný tvar — třeba +420 777 123 456.');
  });
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `TZ=Europe/Prague flutter test test/domain/phone_test.dart`
Expected: FAIL — `Error: Error when reading 'lib/domain/phone.dart': No such file or directory`, then `Method not found: 'normalizePhone'`.

- [ ] **Step 3: Write the implementation**

Create `lib/domain/phone.dart`:

```dart
/// A player's phone number (0048): what they type at registration or in
/// Můj profil → Kontakt, stored the one way the database accepts —
/// international E.164, `+<digits>` (`profiles_phone_check`) — and shown
/// back readable. Pure Dart, unit-tested.
library;

/// The database's own rule (`profiles_phone_check`, `register_profile`):
/// a plus, a non-zero first digit, 8 to 15 digits in all.
final e164Pattern = RegExp(r'^\+[1-9][0-9]{7,14}$');

/// What the app says to a phone it cannot read — inline in the forms, and
/// for the server's own `invalid_phone` (friendlyDbError).
const invalidPhoneMessage =
    'Telefon nemá správný tvar — třeba +420 777 123 456.';

/// [input] in E.164, or null when it cannot be one. Spaces, dashes, dots
/// and brackets go; a leading `00` becomes `+`; a bare nine-digit number is
/// Czech and gets `+420`. An empty [input] is null too — the caller decides
/// whether that means "no phone" (it does, in both forms).
String? normalizePhone(String input) {
  var s = input.replaceAll(RegExp(r'[\s\-.()]'), '');
  if (s.startsWith('00')) {
    s = '+${s.substring(2)}';
  } else if (RegExp(r'^[0-9]{9}$').hasMatch(s)) {
    s = '+420$s';
  }
  return e164Pattern.hasMatch(s) ? s : null;
}

/// [e164] for reading: a Czech number grouped `+420 777 123 456`, any
/// other exactly as stored.
String formatPhone(String e164) {
  final m = RegExp(r'^\+420([0-9]{3})([0-9]{3})([0-9]{3})$').firstMatch(e164);
  return m == null ? e164 : '+420 ${m[1]} ${m[2]} ${m[3]}';
}

/// A WhatsApp chat with [e164]: `https://wa.me/<digits without the plus>`.
Uri whatsappUri(String e164) =>
    Uri.parse('https://wa.me/${e164.replaceAll('+', '')}');
```

- [ ] **Step 4: Run it to verify it passes**

Run: `TZ=Europe/Prague flutter test test/domain/phone_test.dart && flutter analyze`
Expected: `+10: All tests passed!` and `No issues found!`

- [ ] **Step 5: Commit**

```bash
git add lib/domain/phone.dart test/domain/phone_test.dart
git commit -m "$(cat <<'EOF'
feat(kontakty): parse, format and WhatsApp-link phone numbers

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 3: Models and API — the contact fields, `Contact`, `contacts()`, `updateMyContact`

**Files:**
- Modify: `lib/domain/models.dart` (`Profile`; new `Contact` right after `PlayerName`)
- Modify: `lib/data/providers.dart` (`Api.registerProfile`, `Api.updateMyContact`, `Api.contacts`, `contactFields`, `contactsProvider`, `resetTenantScopedProviders`)
- Modify: `lib/core/ui.dart` (`friendlyDbError`)
- Test: `test/domain/models_test.dart`, `test/data/contact_fields_test.dart` (new), `test/data/tenant_reset_test.dart`, `test/core/errors_test.dart`

**Interfaces:**
- Consumes:
  - Task 1: the `profiles` columns `phone` / `show_email` / `show_phone`, `register_profile(..., p_phone)` and `contacts()`;
  - Task 2: `invalidPhoneMessage`;
  - existing: `optimisticWrite`, `patchRow` (`lib/data/optimistic.dart`), `cacheKeyProfile` (`lib/data/cache.dart`), `currentUserId`, `_authUidProvider`.
- Produces:
  ```dart
  // lib/domain/models.dart
  class Profile {
    // new named constructor parameters: this.phone, this.showEmail = true, this.showPhone = true
    final String? phone;      // E.164 or null — JSON 'phone'
    final bool showEmail;     // JSON 'show_email', default true
    final bool showPhone;     // JSON 'show_phone', default true
  }
  class Contact {
    const Contact({required String id, required String displayName, String nick = '',
        String? clubId, String? clubName, int clubColor = -1, String? email, String? phone});
    final String id, displayName, nick; final String? clubId, clubName, email, phone; final int clubColor;
    factory Contact.fromJson(Map<String, dynamic> json); // keys: id, display_name, nick, club_id, club_name, club_color, email, phone
  }

  // lib/data/providers.dart
  static Future<void> Api.registerProfile(String displayName, String tenantId,
      {String? clubId, String nick = '', String? phone});          // sends p_phone
  static Future<void> Api.updateMyContact({String? phone, bool? showEmail, bool? showPhone});
      // own profiles row, optimistic; phone null = unchanged, '' = remove, else E.164
  static Future<List<Contact>> Api.contacts();                      // rpc('contacts')
  Map<String, dynamic> contactFields({String? phone, bool? showEmail, bool? showPhone});
  final contactsProvider = FutureProvider.autoDispose<List<Contact>>(...); // [] when signed out
  // resetTenantScopedProviders(ref) also invalidates contactsProvider

  // lib/core/ui.dart — friendlyDbError: 'invalid_phone' and 'profiles_phone_check' → invalidPhoneMessage
  ```

- [ ] **Step 1: Write the failing tests**

In `test/domain/models_test.dart` replace the end of the `Profile` group:

```dart
      expect(odd.defaultView, HomeView.calendar,
          reason: 'an unknown value falls back to the calendar');
    });
  });
```

with:

```dart
      expect(odd.defaultView, HomeView.calendar,
          reason: 'an unknown value falls back to the calendar');
    });

    test('fromJson reads phone, show_email and show_phone (0048)', () {
      final p = Profile.fromJson({
        'id': 'u1',
        'display_name': 'Já',
        'role': 'player',
        'status': 'approved',
        'phone': '+420777123456',
        'show_email': false,
        'show_phone': true,
      });
      expect(p.phone, '+420777123456');
      expect(p.showEmail, isFalse);
      expect(p.showPhone, isTrue);

      final bare = Profile.fromJson({
        'id': 'u2',
        'display_name': 'Ty',
        'role': 'player',
        'status': 'approved',
      });
      expect(bare.phone, isNull);
      expect(bare.showEmail, isTrue, reason: 'shown unless the player hides it');
      expect(bare.showPhone, isTrue);
    });
  });

  group('Contact', () {
    test('fromJson reads a contacts() row', () {
      final c = Contact.fromJson({
        'id': 'p1',
        'display_name': 'Adam Admin',
        'nick': 'Áďa',
        'club_id': 'c1',
        'club_name': 'Oddíl E',
        'club_color': 3,
        'email': 'adam@example.com',
        'phone': '+420777000001',
      });
      expect(c.id, 'p1');
      expect(c.displayName, 'Adam Admin');
      expect(c.nick, 'Áďa');
      expect(c.clubId, 'c1');
      expect(c.clubName, 'Oddíl E');
      expect(c.clubColor, 3);
      expect(c.email, 'adam@example.com');
      expect(c.phone, '+420777000001');
    });

    test('a hidden e-mail or phone, no club and no nick', () {
      final c = Contact.fromJson({
        'id': 'p2',
        'display_name': 'Běla Skrytá',
        'nick': null,
        'club_id': null,
        'club_name': null,
        'club_color': -1,
        'email': null,
        'phone': null,
      });
      expect(c.nick, '');
      expect(c.clubId, isNull);
      expect(c.clubName, isNull);
      expect(c.clubColor, -1);
      expect(c.email, isNull);
      expect(c.phone, isNull);
    });
  });

```

Create `test/data/contact_fields_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:rezervator/data/providers.dart';

/// Api.updateMyContact writes exactly these columns of the caller's own
/// profiles row (0048) — nothing it was not given.
void main() {
  test('only the fields passed are written', () {
    expect(contactFields(phone: '+420777123456'), {'phone': '+420777123456'});
    expect(contactFields(showEmail: false), {'show_email': false});
    expect(contactFields(showPhone: true), {'show_phone': true});
    expect(
      contactFields(showEmail: true, showPhone: false),
      {'show_email': true, 'show_phone': false},
    );
    expect(contactFields(), isEmpty);
  });

  test('an empty phone clears the number', () {
    expect(contactFields(phone: ''), {'phone': null});
  });
}
```

In `test/data/tenant_reset_test.dart` replace the file's closing `}` (its last line) with the block below; it opens with an empty line, which keeps one between the tests:

```dart

  testWidgets('resetTenantScopedProviders re-fetches the Kontakty list (0048)',
      (tester) async {
    var fetches = 0;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          contactsProvider.overrideWith((ref) async {
            fetches++;
            return const <Contact>[];
          }),
        ],
        child: MaterialApp(
          home: Consumer(
            builder: (context, ref, _) {
              ref.watch(contactsProvider);
              return TextButton(
                onPressed: () => resetTenantScopedProviders(ref),
                child: const Text('Přepnout kuželnu'),
              );
            },
          ),
        ),
      ),
    );
    await tester.pump();
    expect(fetches, 1);

    await tester.tap(find.text('Přepnout kuželnu'));
    await tester.pump();

    expect(fetches, 2);
  });
}
```

In `test/core/errors_test.dart` insert before `  test('initialsOf takes first letters of the first two words, uppercased',` (the block ends with an empty line):

```dart
  test('phone errors (0048) — the server code and the table constraint', () {
    const copy = 'Telefon nemá správný tvar — třeba +420 777 123 456.';
    expect(friendlyDbError(Exception('invalid_phone')), copy);
    expect(
      friendlyDbError(Exception('new row for relation "profiles" violates '
          'check constraint "profiles_phone_check"')),
      copy,
    );
    expect(friendlyDbError(Exception('not_allowed')),
        'Na tohle nemáš oprávnění.');
  });

```

- [ ] **Step 2: Run them to verify they fail**

Run: `TZ=Europe/Prague flutter test test/domain/models_test.dart test/data/contact_fields_test.dart test/data/tenant_reset_test.dart test/core/errors_test.dart`
Expected: FAIL:
- models: `Error: Undefined name 'Contact'.`, `Error: The getter 'phone' isn't defined for the type 'Profile'.`;
- contact fields: `Error: Method not found: 'contactFields'.`;
- tenant reset: `Error: Undefined name 'contactsProvider'.`;
- errors: `Expected: 'Telefon nemá správný tvar — třeba +420 777 123 456.'` / `Actual: 'Něco se nepovedlo. (Exception: invalid_phone)'`.

- [ ] **Step 3: Extend the models**

In `lib/domain/models.dart`, `Profile`'s constructor and fields — replace:

```dart
    this.notifyBefore = const [],
    this.defaultView = HomeView.calendar,
  });

  final String id;
  final String displayName;
  final String email;
```

with:

```dart
    this.notifyBefore = const [],
    this.defaultView = HomeView.calendar,
    this.phone,
    this.showEmail = true,
    this.showPhone = true,
  });

  final String id;
  final String displayName;
  final String email;

  /// The player's phone in E.164 (`+420777123456`, 0048), null when they
  /// gave none. Shown formatted (`formatPhone`).
  final String? phone;

  /// Whether Klubovna → Kontakty shows this player's e-mail / phone to the
  /// other players of the alley (0048). On unless the player hides it.
  final bool showEmail;
  final bool showPhone;
```

and the end of `Profile.fromJson` — replace:

```dart
        defaultView: HomeView.values.asNameMap()[json['default_view']] ??
            HomeView.calendar,
      );
}
```

with:

```dart
        defaultView: HomeView.values.asNameMap()[json['default_view']] ??
            HomeView.calendar,
        phone: json['phone'] as String?,
        showEmail: json['show_email'] as bool? ?? true,
        showPhone: json['show_phone'] as bool? ?? true,
      );
}
```

Then insert the `Contact` class, followed by an empty line, right before the line `/// One alley (kuželna): fully isolated tenant. Players pick theirs at` (the doc comment of `class Tenant`, right after `PlayerName`):

```dart
/// One row of `contacts()` (0048) — a registered player of the alley as
/// Klubovna → Kontakty shows them. [email] and [phone] are null when the
/// player hid them (or has none): the server never sends a hidden one.
class Contact {
  const Contact({
    required this.id,
    required this.displayName,
    this.nick = '',
    this.clubId,
    this.clubName,
    this.clubColor = -1,
    this.email,
    this.phone,
  });

  final String id;
  final String displayName;

  /// Short board name (<=14 chars); empty when the player set none.
  final String nick;
  final String? clubId;
  final String? clubName;

  /// The club's palette index or packed colour, -1 without a club.
  final int clubColor;
  final String? email;

  /// E.164, as stored.
  final String? phone;

  factory Contact.fromJson(Map<String, dynamic> json) => Contact(
        id: json['id'] as String,
        displayName: json['display_name'] as String,
        nick: json['nick'] as String? ?? '',
        clubId: json['club_id'] as String?,
        clubName: json['club_name'] as String?,
        clubColor: json['club_color'] as int? ?? -1,
        email: json['email'] as String?,
        phone: json['phone'] as String?,
      );
}
```

- [ ] **Step 4: Extend the data layer**

In `lib/data/providers.dart` replace `Api.registerProfile`:

```dart
  static Future<void> registerProfile(String displayName, String tenantId,
          {String? clubId, String nick = ''}) =>
      _db.rpc('register_profile', params: {
        'p_display_name': displayName,
        'p_tenant_id': tenantId,
        'p_club_id': clubId,
        'p_nick': nick,
      });
```

with:

```dart
  /// [phone] in E.164 (`normalizePhone`), or null for none (0048).
  static Future<void> registerProfile(String displayName, String tenantId,
          {String? clubId, String nick = '', String? phone}) =>
      _db.rpc('register_profile', params: {
        'p_display_name': displayName,
        'p_tenant_id': tenantId,
        'p_club_id': clubId,
        'p_nick': nick,
        'p_phone': phone,
      });
```

Insert before `  /// The view the app opens at launch (0029).` (the doc comment of `Api.setDefaultView`):

```dart
  /// The caller's own phone and Kontakty switches (0048). Only what is
  /// passed changes: [phone] null leaves the number alone, '' removes it,
  /// otherwise it is E.164 (`normalizePhone`). Optimistic, like the other
  /// profile settings: [myProfileProvider] shows it at once.
  static Future<void> updateMyContact({
    String? phone,
    bool? showEmail,
    bool? showPhone,
  }) {
    final uid = currentUserId!;
    final fields = contactFields(
        phone: phone, showEmail: showEmail, showPhone: showPhone);
    return optimisticWrite(
      uid,
      cacheKeyProfile,
      patchRow('id', uid, fields),
      () => _db.from('profiles').update(fields).eq('id', uid),
    );
  }

  /// The alley's contacts (0048 `contacts()`): registered players with the
  /// e-mail and phone they chose to show. `not_allowed` for the kiosk and
  /// a pending player.
  static Future<List<Contact>> contacts() async => [
        for (final row in await _db.rpc('contacts') as List)
          Contact.fromJson((row as Map).cast<String, dynamic>()),
      ];

```

Insert before `/// After a superadmin tenant switch (Api.switchTenant): every tenant-scoped` (the doc comment of `resetTenantScopedProviders`):

```dart
/// The `profiles` columns [Api.updateMyContact] writes: only the ones
/// passed; a [phone] of '' clears the number (null in the database).
Map<String, dynamic> contactFields({
  String? phone,
  bool? showEmail,
  bool? showPhone,
}) =>
    {
      if (phone != null) 'phone': phone.isEmpty ? null : phone,
      'show_email': ?showEmail,
      'show_phone': ?showPhone,
    };

/// Klubovna → Kontakty (0048). Fetched when the screen opens (autoDispose)
/// and again on pull-to-refresh; the screen sorts and filters it
/// (`contactsMatching`).
final contactsProvider =
    FutureProvider.autoDispose<List<Contact>>((ref) async {
  if (ref.watch(_authUidProvider) == null) return const [];
  return Api.contacts();
});

```

In `resetTenantScopedProviders` replace:

```dart
  ref.invalidate(playersProvider);
  ref.invalidate(tenantsProvider);
```

with:

```dart
  ref.invalidate(playersProvider);
  ref.invalidate(contactsProvider);
  ref.invalidate(tenantsProvider);
```

- [ ] **Step 5: Map the phone errors**

In `lib/core/ui.dart` replace:

```dart
import '../domain/models.dart';
import 'messages.dart';
```

with:

```dart
import '../domain/models.dart';
import '../domain/phone.dart';
import 'messages.dart';
```

and at the end of `friendlyDbError`'s `messages` map replace:

```dart
    'empty_name': 'Název nesmí být prázdný.',
  };
```

with:

```dart
    'empty_name': 'Název nesmí být prázdný.',
    'invalid_phone': invalidPhoneMessage,
    'profiles_phone_check': invalidPhoneMessage,
  };
```

- [ ] **Step 6: Run the tests to verify they pass**

Run: `TZ=Europe/Prague flutter test test/domain/models_test.dart test/data/contact_fields_test.dart test/data/tenant_reset_test.dart test/core/errors_test.dart && flutter analyze`
Expected: `All tests passed!` and `No issues found!`

- [ ] **Step 7: Commit**

```bash
git add lib/domain/models.dart lib/data/providers.dart lib/core/ui.dart test/domain/models_test.dart test/data/contact_fields_test.dart test/data/tenant_reset_test.dart test/core/errors_test.dart
git commit -m "$(cat <<'EOF'
feat(kontakty): the Contact model, contacts() and updateMyContact in the data layer

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 4: Klubovna → Kontakty screen and its hub entry

**Files:**
- Create: `lib/domain/contacts.dart`, `lib/features/clubhouse/contacts_screen.dart`
- Modify: `lib/features/clubhouse/clubhouse_screen.dart`
- Test: `test/domain/contacts_test.dart` (new), `test/features/contacts_screen_test.dart` (new), `test/features/clubhouse_screen_test.dart`

**Interfaces:**
- Consumes:
  - Task 3: `Contact`, `contactsProvider`;
  - Task 2: `whatsappUri`;
  - existing: `foldDiacritics` and `compareCzech` (`lib/domain/collation.dart`); `launchEmail`, `launchPhone`, `launchWeb`, `friendlyDbError`, `snack` (`lib/core/ui.dart`); `ColorDot` (`lib/features/admin/widgets/form_fields.dart`); `ProfileScreen`; `HubMenu` / `HubEntry` (`lib/core/hub_menu.dart`).
- Produces:
  ```dart
  // lib/domain/contacts.dart
  List<Contact> contactsMatching(List<Contact> contacts, String query); // compareCzech by name; name/nick/club, accent- and case-insensitive
  // lib/features/clubhouse/contacts_screen.dart
  class ContactsScreen extends ConsumerStatefulWidget {
    const ContactsScreen({super.key,
      void Function(String address) sendEmail = launchEmail,
      void Function(String number) callPhone = launchPhone,
      void Function(String url) openUrl = launchWeb,
      WidgetBuilder profilePage = _profilePage}); // _profilePage builds const ProfileScreen()
  }
  // The list has Key('contacts-list') (pull-to-refresh tests fling it).
  ```

- [ ] **Step 1: Write the failing tests**

Create `test/domain/contacts_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:rezervator/domain/contacts.dart';
import 'package:rezervator/domain/models.dart';

void main() {
  group('contactsMatching', () {
    const contacts = [
      Contact(id: 'z', displayName: 'Zdeněk Zelený'),
      Contact(
        id: 's',
        displayName: 'Šárka Svobodová',
        nick: 'Šára',
        clubName: 'KK Slovan Rosice',
      ),
      Contact(id: 'c', displayName: 'Čeněk Černý', clubName: 'TJ Sokol'),
      Contact(id: 'h', displayName: 'Chalupa Jan'),
      Contact(id: 'a', displayName: 'Adam Admin', nick: 'Áďa'),
    ];

    List<String> names(List<Contact> list) =>
        [for (final c in list) c.displayName];

    test('an empty query keeps everyone, Czech-sorted', () {
      expect(names(contactsMatching(contacts, '')), [
        'Adam Admin',
        'Čeněk Černý',
        'Chalupa Jan',
        'Šárka Svobodová',
        'Zdeněk Zelený',
      ]);
      expect(names(contactsMatching(contacts, '   ')), hasLength(5));
    });

    test('the name, accent- and case-insensitive', () {
      expect(names(contactsMatching(contacts, 'cerny')), ['Čeněk Černý']);
      expect(names(contactsMatching(contacts, 'ŠÁRKA')), ['Šárka Svobodová']);
    });

    test('the board nick', () {
      expect(names(contactsMatching(contacts, 'sara')), ['Šárka Svobodová']);
    });

    test('the club', () {
      expect(names(contactsMatching(contacts, 'rosice')), ['Šárka Svobodová']);
      expect(names(contactsMatching(contacts, 'sokol')), ['Čeněk Černý']);
    });

    test('nobody matches', () {
      expect(contactsMatching(contacts, 'Havířov'), isEmpty);
    });
  });
}
```

Create `test/features/contacts_screen_test.dart`:

```dart
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rezervator/data/providers.dart';
import 'package:rezervator/domain/models.dart';
import 'package:rezervator/features/clubhouse/contacts_screen.dart';

/// Klubovna → Kontakty (0048): the rows, the actions each visibility
/// allows, the note's way to Můj profil, and the list's states.
void main() {
  const adam = Contact(
    id: 'a',
    displayName: 'Adam Admin',
    nick: 'Áďa',
    clubId: 'c1',
    clubName: 'Oddíl E',
    clubColor: 3,
    email: 'adam@example.com',
    phone: '+420777000001',
  );
  const bela = Contact(
    id: 'b',
    displayName: 'Běla Skrytá',
    clubName: 'Oddíl E',
    clubColor: 3,
    phone: '+420777000002',
  );
  const cenek = Contact(
    id: 'c',
    displayName: 'Čeněk Černý',
    nick: 'Čenda',
    email: 'cenek@example.com',
  );
  const chalupa = Contact(id: 'h', displayName: 'Chalupa Jan');

  late List<String> launched;
  late int fetches;

  setUp(() {
    launched = [];
    fetches = 0;
  });

  Widget app(Future<List<Contact>> Function() fetch) => ProviderScope(
        overrides: [
          contactsProvider.overrideWith((ref) {
            fetches++;
            return fetch();
          }),
        ],
        child: MaterialApp(
          home: ContactsScreen(
            sendEmail: (v) => launched.add('email:$v'),
            callPhone: (v) => launched.add('call:$v'),
            openUrl: (v) => launched.add('url:$v'),
            profilePage: (_) => Scaffold(
              appBar: AppBar(title: const Text('Profil (test)')),
            ),
          ),
        ),
      );

  const note = 'Svůj e-mail a telefon můžeš v Kontaktech skrýt v Můj profil → '
      'Kontakt.';

  /// The recognizer on the note's „Můj profil" words — tapped directly, as
  /// tapOnText lands on a glyph edge under the test font's letter spacing.
  TapGestureRecognizer profileLink(WidgetTester tester) {
    GestureRecognizer? link;
    tester.widget<RichText>(find.text(note, findRichText: true)).text
        .visitChildren((span) {
      if (span is TextSpan && span.text == 'Můj profil') link = span.recognizer;
      return link == null;
    });
    return link! as TapGestureRecognizer;
  }

  Finder rowOf(String name) => find.widgetWithText(ListTile, name);
  Finder inRow(String name, Finder matching) =>
      find.descendant(of: rowOf(name), matching: matching);

  testWidgets('rows are Czech-sorted, with the nick and club under the name',
      (tester) async {
    await tester.pumpWidget(app(() async => [chalupa, cenek, bela, adam]));
    await tester.pumpAndSettle();

    expect(find.widgetWithText(AppBar, 'Kontakty'), findsOneWidget);
    final titles = [
      for (final tile in tester.widgetList<ListTile>(find.byType(ListTile)))
        (tile.title! as Text).data,
    ];
    expect(titles,
        ['Adam Admin', 'Běla Skrytá', 'Čeněk Černý', 'Chalupa Jan']);
    expect(inRow('Adam Admin', find.text('„Áďa“ · Oddíl E')), findsOneWidget);
    expect(inRow('Běla Skrytá', find.text('Oddíl E')), findsOneWidget);
    expect(inRow('Čeněk Černý', find.text('„Čenda“')), findsOneWidget);
    expect(tester.widget<ListTile>(rowOf('Chalupa Jan')).subtitle, isNull);
  });

  testWidgets('each row offers what its player shows, and the actions call '
      'the launchers — WhatsApp through wa.me', (tester) async {
    await tester.pumpWidget(app(() async => [adam, bela, cenek, chalupa]));
    await tester.pumpAndSettle();

    // Both shown: e-mail, call, WhatsApp.
    await tester.tap(inRow('Adam Admin', find.byTooltip('Napsat e-mail')));
    await tester.tap(inRow('Adam Admin', find.byTooltip('Zavolat')));
    await tester.tap(inRow('Adam Admin', find.byTooltip('WhatsApp')));
    expect(launched, [
      'email:adam@example.com',
      'call:+420777000001',
      'url:https://wa.me/420777000001',
    ]);

    // Phone only: no e-mail button.
    expect(inRow('Běla Skrytá', find.byTooltip('Napsat e-mail')), findsNothing);
    expect(inRow('Běla Skrytá', find.byTooltip('Zavolat')), findsOneWidget);
    expect(inRow('Běla Skrytá', find.byTooltip('WhatsApp')), findsOneWidget);

    // E-mail only: no call, no WhatsApp.
    expect(inRow('Čeněk Černý', find.byTooltip('Napsat e-mail')),
        findsOneWidget);
    expect(inRow('Čeněk Černý', find.byTooltip('Zavolat')), findsNothing);
    expect(inRow('Čeněk Černý', find.byTooltip('WhatsApp')), findsNothing);

    // Neither: a muted note instead of buttons.
    expect(inRow('Chalupa Jan', find.text('kontakt skrytý')), findsOneWidget);
    expect(inRow('Chalupa Jan', find.byType(IconButton)), findsNothing);
    expect(find.text('kontakt skrytý'), findsOneWidget);
  });

  testWidgets('search ignores accents and case, over name, nick and club',
      (tester) async {
    await tester.pumpWidget(app(() async => [adam, bela, cenek, chalupa]));
    await tester.pumpAndSettle();

    expect(find.text('Hledat jméno, přezdívku nebo oddíl'), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'CERNY');
    await tester.pumpAndSettle();
    expect(find.byType(ListTile), findsOneWidget);
    expect(rowOf('Čeněk Černý'), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'oddil e');
    await tester.pumpAndSettle();
    expect(find.byType(ListTile), findsNWidgets(2));

    await tester.enterText(find.byType(TextField), 'Havířov');
    await tester.pumpAndSettle();
    expect(find.byType(ListTile), findsNothing);
    expect(find.text('Nikdo takový tu není.'), findsOneWidget);
  });

  testWidgets('the note says where to hide one\'s own contact, and „Můj '
      'profil" opens the profile; coming back re-reads the list',
      (tester) async {
    await tester.pumpWidget(app(() async => [adam]));
    await tester.pumpAndSettle();

    expect(find.text(note, findRichText: true), findsOneWidget);
    expect(fetches, 1);

    profileLink(tester).onTap!();
    await tester.pumpAndSettle();
    expect(find.widgetWithText(AppBar, 'Profil (test)'), findsOneWidget);

    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.widgetWithText(AppBar, 'Kontakty'), findsOneWidget);
    expect(fetches, 2);
  });

  testWidgets('pull-to-refresh fetches the list again', (tester) async {
    await tester.pumpWidget(app(() async => [adam, bela]));
    await tester.pumpAndSettle();
    expect(fetches, 1);

    await tester.fling(
      find.byKey(const Key('contacts-list')),
      const Offset(0, 300),
      1000,
    );
    await tester.pumpAndSettle();

    expect(fetches, 2);
  });

  testWidgets('an empty alley says so', (tester) async {
    await tester.pumpWidget(app(() async => const []));
    await tester.pumpAndSettle();

    expect(find.text('Zatím tu nikdo není.'), findsOneWidget);
  });

  testWidgets('a failed load shows the friendly message and „Zkusit znovu"',
      (tester) async {
    var fail = true;
    // An Error, not an Exception: Riverpod's own retry gives up on it at
    // once — the state a request is left in after its retries ran out.
    await tester.pumpWidget(app(() async {
      if (fail) throw StateError('not_allowed');
      return [adam];
    }));
    await tester.pumpAndSettle();

    expect(find.text('Na tohle nemáš oprávnění.'), findsOneWidget);
    expect(rowOf('Adam Admin'), findsNothing);

    fail = false;
    await tester.tap(find.widgetWithText(OutlinedButton, 'Zkusit znovu'));
    await tester.pumpAndSettle();

    expect(find.text('Na tohle nemáš oprávnění.'), findsNothing);
    expect(rowOf('Adam Admin'), findsOneWidget);
  });
}
```

In `test/features/clubhouse_screen_test.dart`:

Replace `/// The Klubovna hub: its two entries, the shell's trailing icons riding` with `/// The Klubovna hub: its three entries, the shell's trailing icons riding`.

In `app()`'s overrides replace:

```dart
          nowProvider.overrideWith(
            (ref) => Stream.value(DateTime(2026, 9, 23, 18, 0)),
          ),
        ],
```

with:

```dart
          nowProvider.overrideWith(
            (ref) => Stream.value(DateTime(2026, 9, 23, 18, 0)),
          ),
          contactsProvider.overrideWith((ref) async => const <Contact>[]),
        ],
```

Replace the first test:

```dart
  testWidgets('shows the Výsledky and Kuželny entries with their subtitles', (
    tester,
  ) async {
    narrow(tester);
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();

    expect(find.text('Výsledky'), findsOneWidget);
    expect(find.text('Zápasy a výsledky našich týmů'), findsOneWidget);
    expect(find.text('Kuželny'), findsOneWidget);
    expect(find.text('Kontakty a vybavení kuželen'), findsOneWidget);
    expect(find.byIcon(Icons.scoreboard_outlined), findsOneWidget);
    expect(find.byIcon(Icons.location_on_outlined), findsOneWidget);
  });
```

with:

```dart
  testWidgets('shows the Výsledky, Kuželny and Kontakty entries with their '
      'subtitles', (tester) async {
    narrow(tester);
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();

    expect(find.text('Výsledky'), findsOneWidget);
    expect(find.text('Zápasy a výsledky našich týmů'), findsOneWidget);
    expect(find.text('Kuželny'), findsOneWidget);
    // Kuželny no longer says „Kontakty" — that is the new entry's word.
    expect(find.text('Adresy a vybavení kuželen'), findsOneWidget);
    expect(find.text('Kontakty a vybavení kuželen'), findsNothing);
    expect(find.text('Kontakty'), findsOneWidget);
    expect(find.text('Hráči kuželny — e-mail a telefon'), findsOneWidget);
    expect(find.byIcon(Icons.scoreboard_outlined), findsOneWidget);
    expect(find.byIcon(Icons.location_on_outlined), findsOneWidget);
    expect(find.byIcon(Icons.contacts_outlined), findsOneWidget);
  });
```

Replace `    expect(find.byType(ListTile), findsNWidgets(2));` with `    expect(find.byType(ListTile), findsNWidgets(3));`, and `    expect(find.byType(Card), findsNWidgets(2));` with `    expect(find.byType(Card), findsNWidgets(3));`.

Replace the navigation test's name:

```dart
    'tapping Výsledky opens the real results screen, Kuželny opens the '
    'real venues screen',
```

with:

```dart
    'tapping Výsledky opens the real results screen, Kuželny the real '
    'venues screen, Kontakty the real contacts screen',
```

and its end:

```dart
      await tester.tap(find.text('Kuželny'));
      await tester.pumpAndSettle();
      expect(find.widgetWithText(AppBar, 'Kuželny'), findsOneWidget);
      expect(failures.errors, isEmpty);
```

with:

```dart
      await tester.tap(find.text('Kuželny'));
      await tester.pumpAndSettle();
      expect(find.widgetWithText(AppBar, 'Kuželny'), findsOneWidget);

      await tester.pageBack();
      await tester.pumpAndSettle();

      await tester.tap(find.text('Kontakty'));
      await tester.pumpAndSettle();
      expect(find.widgetWithText(AppBar, 'Kontakty'), findsOneWidget);
      expect(find.text('Zatím tu nikdo není.'), findsOneWidget);
      expect(failures.errors, isEmpty);
```

- [ ] **Step 2: Run them to verify they fail**

Run: `TZ=Europe/Prague flutter test test/domain/contacts_test.dart test/features/contacts_screen_test.dart test/features/clubhouse_screen_test.dart`
Expected: FAIL:
- `Error when reading 'lib/domain/contacts.dart': No such file or directory`;
- `Error when reading 'lib/features/clubhouse/contacts_screen.dart': No such file or directory`;
- the hub test: `Found 0 widgets with text "Adresy a vybavení kuželen"`.

- [ ] **Step 3: Write the search**

Create `lib/domain/contacts.dart`:

```dart
/// Klubovna → Kontakty's list (0048): the alley's contacts, Czech-sorted,
/// narrowed by the search field. Pure Dart, unit-tested.
library;

import 'collation.dart';
import 'models.dart';

/// The Czech-sorted [contacts] whose name, board nick or club matches
/// [query] — accent- and case-insensitive, the same folding as the other
/// searches (`venuesMatching`, `upcomingMatches`); an empty query keeps
/// everyone.
List<Contact> contactsMatching(List<Contact> contacts, String query) {
  final q = foldDiacritics(query.trim()).toLowerCase();
  bool hit(String s) => foldDiacritics(s).toLowerCase().contains(q);
  return [
    for (final c in contacts)
      if (q.isEmpty ||
          hit(c.displayName) ||
          hit(c.nick) ||
          hit(c.clubName ?? ''))
        c,
  ]..sort((a, b) => compareCzech(a.displayName, b.displayName));
}
```

- [ ] **Step 4: Write the screen**

Create `lib/features/clubhouse/contacts_screen.dart`:

```dart
/// Klubovna → Kontakty (0048): the alley's registered players with the
/// e-mail and phone each of them chose to show — write, call or WhatsApp
/// straight from the row. Czech-sorted, searchable.
library;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/ui.dart';
import '../../data/providers.dart';
import '../../domain/contacts.dart';
import '../../domain/models.dart';
import '../../domain/phone.dart';
import '../admin/widgets/form_fields.dart' show ColorDot;
import '../profile/profile_screen.dart';

Widget _profilePage(BuildContext _) => const ProfileScreen();

class ContactsScreen extends ConsumerStatefulWidget {
  const ContactsScreen({
    super.key,
    this.sendEmail = launchEmail,
    this.callPhone = launchPhone,
    this.openUrl = launchWeb,
    this.profilePage = _profilePage,
  });

  /// Injectable so widget tests never reach the platform.
  final void Function(String address) sendEmail;
  final void Function(String number) callPhone;
  final void Function(String url) openUrl;

  /// What „Můj profil" in the note opens — the same screen as the shell's
  /// profile icon; a test swaps in a stand-in.
  final WidgetBuilder profilePage;

  @override
  ConsumerState<ContactsScreen> createState() => _ContactsScreenState();
}

class _ContactsScreenState extends ConsumerState<ContactsScreen> {
  String _query = '';
  late final _profileLink = TapGestureRecognizer()..onTap = _openProfile;

  @override
  void dispose() {
    _profileLink.dispose();
    super.dispose();
  }

  Future<void> _openProfile() async {
    await Navigator.of(context)
        .push(MaterialPageRoute<void>(builder: widget.profilePage));
    // A switch just flipped there shows here at once.
    if (mounted) ref.invalidate(contactsProvider);
  }

  Future<void> _refresh() async {
    try {
      ref.invalidate(contactsProvider);
      await ref.read(contactsProvider.future);
    } catch (e) {
      if (mounted) snack(context, friendlyDbError(e));
    }
  }

  Widget _note(ThemeData theme) {
    final scheme = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.info_outline, size: 18, color: scheme.onSurfaceVariant),
          const SizedBox(width: 8),
          Expanded(
            child: Text.rich(
              TextSpan(
                children: [
                  const TextSpan(
                    text: 'Svůj e-mail a telefon můžeš v Kontaktech skrýt v ',
                  ),
                  TextSpan(
                    text: 'Můj profil',
                    style: TextStyle(
                      color: scheme.primary,
                      decoration: TextDecoration.underline,
                    ),
                    recognizer: _profileLink,
                  ),
                  const TextSpan(text: ' → Kontakt.'),
                ],
              ),
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ),
        ],
      ),
    );
  }

  Widget _row(ThemeData theme, Contact contact) {
    final subtitle = [
      if (contact.nick.isNotEmpty) '„${contact.nick}“',
      ?contact.clubName,
    ].join(' · ');
    final email = contact.email;
    final phone = contact.phone;
    return ListTile(
      leading: ColorDot(colorIndex: contact.clubColor),
      title: Text(contact.displayName),
      subtitle: subtitle.isEmpty ? null : Text(subtitle),
      trailing: email == null && phone == null
          ? Text(
              'kontakt skrytý',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            )
          : Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (email != null)
                  IconButton(
                    icon: const Icon(Icons.mail_outline),
                    tooltip: 'Napsat e-mail',
                    visualDensity: VisualDensity.compact,
                    onPressed: () => widget.sendEmail(email),
                  ),
                if (phone != null) ...[
                  IconButton(
                    icon: const Icon(Icons.phone_outlined),
                    tooltip: 'Zavolat',
                    visualDensity: VisualDensity.compact,
                    onPressed: () => widget.callPhone(phone),
                  ),
                  IconButton(
                    icon: const Icon(Icons.chat_outlined),
                    tooltip: 'WhatsApp',
                    visualDensity: VisualDensity.compact,
                    onPressed: () =>
                        widget.openUrl(whatsappUri(phone).toString()),
                  ),
                ],
              ],
            ),
    );
  }

  Widget _centered(String text) => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(text, textAlign: TextAlign.center),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final contactsAsync = ref.watch(contactsProvider);

    Widget body;
    if (contactsAsync.hasError && !contactsAsync.hasValue) {
      body = Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                friendlyDbError(contactsAsync.error!),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 12),
              OutlinedButton(
                onPressed: () => ref.invalidate(contactsProvider),
                child: const Text('Zkusit znovu'),
              ),
            ],
          ),
        ),
      );
    } else if (!contactsAsync.hasValue) {
      body = const Center(child: CircularProgressIndicator());
    } else {
      final all = contactsAsync.value!;
      final shown = contactsMatching(all, _query);
      body = RefreshIndicator(
        onRefresh: _refresh,
        child: all.isEmpty
            ? ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                children: [_centered('Zatím tu nikdo není.')],
              )
            : shown.isEmpty
                ? ListView(
                    physics: const AlwaysScrollableScrollPhysics(),
                    children: [_centered('Nikdo takový tu není.')],
                  )
                : ListView.builder(
                    key: const Key('contacts-list'),
                    physics: const AlwaysScrollableScrollPhysics(),
                    padding: const EdgeInsets.only(bottom: 24),
                    itemCount: shown.length,
                    itemBuilder: (context, i) => _row(theme, shown[i]),
                  ),
      );
    }

    return Scaffold(
      appBar: AppBar(title: const Text('Kontakty')),
      body: Column(
        children: [
          _note(theme),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
            child: TextField(
              decoration: const InputDecoration(
                hintText: 'Hledat jméno, přezdívku nebo oddíl',
                prefixIcon: Icon(Icons.search),
              ),
              onChanged: (v) => setState(() => _query = v),
            ),
          ),
          Expanded(child: body),
        ],
      ),
    );
  }
}
```

- [ ] **Step 5: Add the hub entry**

In `lib/features/clubhouse/clubhouse_screen.dart` replace the library comment:

```dart
/// Klubovna — the third home tab: a hub of team-facing screens (results,
/// venues), the same [HubMenu] Správa kuželny uses.
```

with:

```dart
/// Klubovna — the third home tab: a hub of team-facing screens (results,
/// venues, contacts), the same [HubMenu] Správa kuželny uses.
```

replace:

```dart
import '../schedule/widgets/home_header.dart';
import 'results_screen.dart';
```

with:

```dart
import '../schedule/widgets/home_header.dart';
import 'contacts_screen.dart';
import 'results_screen.dart';
```

and replace the Kuželny entry's tail:

```dart
                subtitle: 'Kontakty a vybavení kuželen',
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const VenuesScreen()),
                ),
              ),
```

with:

```dart
                subtitle: 'Adresy a vybavení kuželen',
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const VenuesScreen()),
                ),
              ),
              (
                label: 'Kontakty',
                icon: Icons.contacts_outlined,
                subtitle: 'Hráči kuželny — e-mail a telefon',
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const ContactsScreen()),
                ),
              ),
```

- [ ] **Step 6: Run the tests to verify they pass**

Run: `TZ=Europe/Prague flutter test test/domain/contacts_test.dart test/features/contacts_screen_test.dart test/features/clubhouse_screen_test.dart test/features/home_shell_test.dart && flutter analyze`
Expected: `All tests passed!` and `No issues found!`

- [ ] **Step 7: Commit**

```bash
git add lib/domain/contacts.dart lib/features/clubhouse/contacts_screen.dart lib/features/clubhouse/clubhouse_screen.dart test/domain/contacts_test.dart test/features/contacts_screen_test.dart test/features/clubhouse_screen_test.dart
git commit -m "$(cat <<'EOF'
feat(kontakty): Klubovna → Kontakty

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 5: An optional phone at registration

**Files:**
- Modify: `lib/features/auth/register_screen.dart`
- Test: `test/features/register_screen_test.dart`

**Interfaces:**
- Consumes: Task 3 `Api.registerProfile(..., {String? phone})`, `Api.updateMyContact({String? phone, ...})`; existing `Api.createTenantAndRegister(String tenantName, String displayName, {String nick = ''})`; Task 2 `normalizePhone`, `invalidPhoneMessage`.
- Produces:
  ```dart
  const RegisterScreen({super.key,
    this.registerProfile = Api.registerProfile,
    this.createTenantAndRegister = Api.createTenantAndRegister,
    this.updateMyContact = Api.updateMyContact});
  final Future<void> Function(String displayName, String tenantId,
      {String? clubId, String nick, String? phone}) registerProfile;
  final Future<void> Function(String tenantName, String displayName, {String nick})
      createTenantAndRegister;
  final Future<void> Function({String? phone, bool? showEmail, bool? showPhone})
      updateMyContact;
  ```
  Existing callers (`const RegisterScreen()` in `auth_gate.dart`) are unchanged.

- [ ] **Step 1: Write the failing tests**

In `test/features/register_screen_test.dart` replace the top of `main()`:

```dart
void main() {
  Widget app(List<Tenant> tenants,
      {Map<String, List<Club>> clubs = const {}}) {
    return ProviderScope(
      overrides: [
        tenantsProvider.overrideWith((ref) async => tenants),
        registrationClubsProvider.overrideWith(
            (ref, tenantId) async => clubs[tenantId] ?? const <Club>[]),
      ],
      child: const MaterialApp(home: RegisterScreen()),
    );
  }
```

with:

```dart
void main() {
  /// What the screen sent, one line per backend call.
  late List<String> calls;
  setUp(() => calls = []);

  Widget app(List<Tenant> tenants,
      {Map<String, List<Club>> clubs = const {}}) {
    return ProviderScope(
      overrides: [
        tenantsProvider.overrideWith((ref) async => tenants),
        registrationClubsProvider.overrideWith(
            (ref, tenantId) async => clubs[tenantId] ?? const <Club>[]),
      ],
      child: MaterialApp(
        home: RegisterScreen(
          registerProfile: (name, tenantId, {clubId, nick = '', phone}) async =>
              calls.add('register $name|$tenantId|$clubId|$nick|$phone'),
          createTenantAndRegister: (tenantName, name, {nick = ''}) async =>
              calls.add('found $tenantName|$name|$nick'),
          updateMyContact: ({phone, showEmail, showPhone}) async =>
              calls.add('contact $phone|$showEmail|$showPhone'),
        ),
      ),
    );
  }

  const phoneLabel = 'Telefon (nepovinné)';
  const phoneError = 'Telefon nemá správný tvar — třeba +420 777 123 456.';
```

In the test `founding a new alley reveals its name field and requires it`, replace:

```dart
    await tester.enterText(
        find.widgetWithText(TextField, 'Jméno a příjmení'), 'Jan Novák');
    await tester.tap(find.text('Zaregistrovat se'));
    await tester.pump();
    expect(find.text('Napiš název nové kuželny.'), findsOneWidget);
```

with:

```dart
    await tester.enterText(
        find.widgetWithText(TextField, 'Jméno a příjmení'), 'Jan Novák');
    // The phone field pushed the button below the fold of the test screen.
    await tester.ensureVisible(find.text('Zaregistrovat se'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Zaregistrovat se'));
    await tester.pump();
    expect(find.text('Napiš název nové kuželny.'), findsOneWidget);
```

and replace the file's closing `}` (its last line) with the block below; it opens with an empty line:

```dart

  testWidgets('the phone is optional: without one nothing is sent for it',
      (tester) async {
    await tester.pumpWidget(app(const [Tenant(id: 't1', name: 'Kuželna č. 1')]));
    await tester.pumpAndSettle();

    final field = find.widgetWithText(TextField, phoneLabel);
    expect(field, findsOneWidget);
    expect(tester.widget<TextField>(field).keyboardType, TextInputType.phone);

    await tester.enterText(
        find.widgetWithText(TextField, 'Jméno a příjmení'), 'Jan Novák');
    await tester.tap(find.text('Zaregistrovat se'));
    await tester.pumpAndSettle();

    expect(calls, ['register Jan Novák|t1|null||null']);
  });

  testWidgets('an invalid phone is refused inline and nothing is sent; '
      'typing again clears the message', (tester) async {
    await tester.pumpWidget(app(const [Tenant(id: 't1', name: 'Kuželna č. 1')]));
    await tester.pumpAndSettle();

    await tester.enterText(
        find.widgetWithText(TextField, 'Jméno a příjmení'), 'Jan Novák');
    await tester.enterText(find.widgetWithText(TextField, phoneLabel), '12345');
    await tester.tap(find.text('Zaregistrovat se'));
    await tester.pumpAndSettle();

    expect(find.text(phoneError), findsOneWidget);
    expect(calls, isEmpty);

    await tester.enterText(
        find.widgetWithText(TextField, phoneLabel), '777 123 45');
    await tester.pump();
    expect(find.text(phoneError), findsNothing);
  });

  testWidgets('a valid phone is sent normalised to register_profile',
      (tester) async {
    await tester.pumpWidget(app(const [Tenant(id: 't1', name: 'Kuželna č. 1')]));
    await tester.pumpAndSettle();

    await tester.enterText(
        find.widgetWithText(TextField, 'Jméno a příjmení'), 'Jan Novák');
    await tester.enterText(
        find.widgetWithText(TextField, 'Přezdívka na tabuli (nepovinné)'),
        'Honza');
    await tester.enterText(
        find.widgetWithText(TextField, phoneLabel), '777 123 456');
    await tester.tap(find.text('Zaregistrovat se'));
    await tester.pumpAndSettle();

    expect(calls, ['register Jan Novák|t1|null|Honza|+420777123456']);
  });

  testWidgets('a founder\'s phone is saved on their new profile right after '
      'the alley is founded', (tester) async {
    await tester.pumpWidget(app(two));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Kuželna'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('➕ Založit novou kuželnu').last);
    await tester.pumpAndSettle();

    await tester.enterText(
        find.widgetWithText(TextField, 'Název nové kuželny'), 'Kuželna Nová');
    await tester.enterText(
        find.widgetWithText(TextField, 'Jméno a příjmení'), 'Jan Novák');
    await tester.enterText(
        find.widgetWithText(TextField, phoneLabel), '+49 30 1234567');
    await tester.ensureVisible(find.text('Zaregistrovat se'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Zaregistrovat se'));
    await tester.pumpAndSettle();

    expect(calls, [
      'found Kuželna Nová|Jan Novák|',
      'contact +49301234567|null|null',
    ]);
  });
}
```

- [ ] **Step 2: Run them to verify they fail**

Run: `TZ=Europe/Prague flutter test test/features/register_screen_test.dart`
Expected: FAIL — `Error: No named parameter with the name 'registerProfile'.`

- [ ] **Step 3: Implement**

In `lib/features/auth/register_screen.dart` replace:

```dart
import '../../domain/limits.dart';
import '../../domain/models.dart';
```

with:

```dart
import '../../domain/limits.dart';
import '../../domain/models.dart';
import '../../domain/phone.dart';
```

Replace the class head:

```dart
/// First sign-in: pick an existing alley (kuželna) — or found a new one —
/// plus a display name, optional board nick and, for an existing alley, a
/// club from its actual club list. A new alley's founder becomes its admin
/// right away; everyone else waits for the admin's approval.
class RegisterScreen extends ConsumerStatefulWidget {
  const RegisterScreen({super.key});
```

with:

```dart
/// First sign-in: pick an existing alley (kuželna) — or found a new one —
/// plus a display name, optional board nick and phone and, for an existing
/// alley, a club from its actual club list. A new alley's founder becomes
/// its admin right away; everyone else waits for the admin's approval.
class RegisterScreen extends ConsumerStatefulWidget {
  const RegisterScreen({
    super.key,
    this.registerProfile = Api.registerProfile,
    this.createTenantAndRegister = Api.createTenantAndRegister,
    this.updateMyContact = Api.updateMyContact,
  });

  /// Injectable for widget tests (the Api ones need a live Supabase client).
  final Future<void> Function(String displayName, String tenantId,
      {String? clubId, String nick, String? phone}) registerProfile;
  final Future<void> Function(String tenantName, String displayName,
      {String nick}) createTenantAndRegister;
  final Future<void> Function({String? phone, bool? showEmail, bool? showPhone})
      updateMyContact;
```

Replace:

```dart
  final _nick = TextEditingController();
  String? _tenantId;
```

with:

```dart
  final _nick = TextEditingController();
  final _phone = TextEditingController();
  String? _phoneError;
  String? _tenantId;
```

Replace:

```dart
    _nick.dispose();
    super.dispose();
```

with:

```dart
    _nick.dispose();
    _phone.dispose();
    super.dispose();
```

Replace the end of `_register` from the new-alley check through the `tryAction` call:

```dart
    if (tenantId == _newTenant && _tenantName.text.trim().isEmpty) {
      snack(context, 'Napiš název nové kuželny.');
      return;
    }
    setState(() => _saving = true);
    await tryAction(
      context,
      () => tenantId == _newTenant
          ? Api.createTenantAndRegister(_tenantName.text.trim(), name,
              nick: _nick.text.trim())
          : Api.registerProfile(name, tenantId,
              clubId: _clubId, nick: _nick.text.trim()),
      errorText: friendlyDbError,
    );
```

with:

```dart
    if (tenantId == _newTenant && _tenantName.text.trim().isEmpty) {
      snack(context, 'Napiš název nové kuželny.');
      return;
    }
    final typedPhone = _phone.text.trim();
    final phone = typedPhone.isEmpty ? null : normalizePhone(typedPhone);
    if (typedPhone.isNotEmpty && phone == null) {
      setState(() => _phoneError = invalidPhoneMessage);
      return;
    }
    setState(() => _saving = true);
    await tryAction(
      context,
      () async {
        if (tenantId == _newTenant) {
          await widget.createTenantAndRegister(_tenantName.text.trim(), name,
              nick: _nick.text.trim());
          // create_tenant_and_register takes no phone: the founder's own
          // row takes it right after.
          if (phone != null) await widget.updateMyContact(phone: phone);
        } else {
          await widget.registerProfile(name, tenantId,
              clubId: _clubId, nick: _nick.text.trim(), phone: phone);
        }
      },
      errorText: friendlyDbError,
    );
```

Add the field under the nick field — replace:

```dart
                decoration: const InputDecoration(
                  labelText: 'Přezdívka na tabuli (nepovinné)',
                  border: OutlineInputBorder(),
                  counterText: '',
                ),
              ),
```

with:

```dart
                decoration: const InputDecoration(
                  labelText: 'Přezdívka na tabuli (nepovinné)',
                  border: OutlineInputBorder(),
                  counterText: '',
                ),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _phone,
                keyboardType: TextInputType.phone,
                decoration: InputDecoration(
                  labelText: 'Telefon (nepovinné)',
                  border: const OutlineInputBorder(),
                  errorText: _phoneError,
                ),
                onChanged: (_) {
                  if (_phoneError != null) setState(() => _phoneError = null);
                },
              ),
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `TZ=Europe/Prague flutter test test/features/register_screen_test.dart test/features/auth_gate_test.dart && flutter analyze`
Expected: `All tests passed!` (the `Warning: A call to tap() … would not hit test` lines of the club-dropdown test were there before this task) and `No issues found!`

- [ ] **Step 5: Commit**

```bash
git add lib/features/auth/register_screen.dart test/features/register_screen_test.dart
git commit -m "$(cat <<'EOF'
feat(kontakty): an optional phone at registration

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 6: Můj profil → Kontakt, and the changelog line

**Files:**
- Create: `lib/features/profile/widgets/contact_card.dart`
- Modify: `lib/features/profile/profile_screen.dart`, `lib/features/profile/changelog_data.dart`
- Test: `test/features/profile_screen_test.dart`

**Interfaces:**
- Consumes:
  - Task 3: `Profile.phone` / `showEmail` / `showPhone`, `Api.updateMyContact`;
  - Task 2: `formatPhone`, `normalizePhone`, `invalidPhoneMessage`;
  - existing: `tryAction`, `closeDialog`, `friendlyDbError` (`lib/core/ui.dart`).
- Produces:
  ```dart
  class ContactCard extends StatelessWidget {
    const ContactCard({super.key, required Profile profile,
      required Future<void> Function({String? phone, bool? showEmail, bool? showPhone}) updateMyContact});
  }
  // ProfileScreen gains: this.updateMyContact = Api.updateMyContact
  //   final Future<void> Function({String? phone, bool? showEmail, bool? showPhone}) updateMyContact;
  ```

- [ ] **Step 1: Write the failing tests**

In `test/features/profile_screen_test.dart` replace:

```dart
import 'package:rezervator/features/profile/widgets/calendar_link_card.dart';
```

with:

```dart
import 'package:rezervator/features/profile/widgets/calendar_link_card.dart';
import 'package:rezervator/features/profile/widgets/contact_card.dart';
```

In `app()`'s parameters replace:

```dart
    Future<void> Function(HomeView view)? setDefaultView,
    List<PrioritySlot> matches = const [],
```

with:

```dart
    Future<void> Function(HomeView view)? setDefaultView,
    Future<void> Function({String? phone, bool? showEmail, bool? showPhone})?
        updateMyContact,
    List<PrioritySlot> matches = const [],
```

and in its `ProfileScreen(...)` replace:

```dart
          setDefaultView:
              setDefaultView ?? (_) async => throw StateError('unexpected'),
        ),
```

with:

```dart
          setDefaultView:
              setDefaultView ?? (_) async => throw StateError('unexpected'),
          updateMyContact: updateMyContact ??
              ({phone, showEmail, showPhone}) async =>
                  throw StateError('unexpected'),
        ),
```

Then replace the file's closing `}` (its last line) with the block below; it opens with an empty line:

```dart

  group('Kontakt card (0048)', () {
    // Tall enough that the whole list is built: the card sits between
    // Google kalendář and Vzhled, below the default test viewport.
    void tall(WidgetTester tester) {
      tester.view.physicalSize = const Size(800, 2600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
    }

    const withPhone = Profile(
      id: 'me',
      displayName: 'Já Hráč',
      email: 'me@example.com',
      role: Role.player,
      status: ProfileStatus.approved,
      phone: '+420777123456',
      showEmail: false,
    );
    const phoneError = 'Telefon nemá správný tvar — třeba +420 777 123 456.';

    late List<String> saved;
    setUp(() => saved = []);
    Future<void> record({String? phone, bool? showEmail, bool? showPhone}) async =>
        saved.add('phone=$phone showEmail=$showEmail showPhone=$showPhone');

    Finder inCard(Finder matching) =>
        find.descendant(of: find.byType(ContactCard), matching: matching);
    Finder inDialog(Finder matching) =>
        find.descendant(of: find.byType(AlertDialog), matching: matching);
    Finder switchTile(String title) =>
        find.widgetWithText(SwitchListTile, title);

    testWidgets('shows the phone formatted and both switches as saved',
        (tester) async {
      tall(tester);
      await tester.pumpWidget(app(withPhone, updateMyContact: record));
      await tester.pumpAndSettle();

      expect(inCard(find.text('Kontakt')), findsOneWidget);
      expect(inCard(find.text('Telefon')), findsOneWidget);
      expect(inCard(find.text('+420 777 123 456')), findsOneWidget);
      expect(
        tester.widget<SwitchListTile>(switchTile('Ukázat e-mail v Kontaktech'))
            .value,
        isFalse,
      );
      expect(find.text('Ostatní hráči kuželny ti můžou napsat.'),
          findsOneWidget);
      expect(
        tester.widget<SwitchListTile>(switchTile('Ukázat telefon v Kontaktech'))
            .value,
        isTrue,
      );
      expect(find.text('Zavolat nebo napsat přes WhatsApp.'), findsOneWidget);
    });

    testWidgets('without a phone it reads „nenastaven"', (tester) async {
      tall(tester);
      await tester.pumpWidget(app(me, updateMyContact: record));
      await tester.pumpAndSettle();

      expect(inCard(find.text('nenastaven')), findsOneWidget);
    });

    testWidgets('Upravit: a bad number is refused in the dialog, a good one '
        'is saved normalised', (tester) async {
      tall(tester);
      await tester.pumpWidget(app(withPhone, updateMyContact: record));
      await tester.pumpAndSettle();

      await tester.tap(inCard(find.text('Upravit')));
      await tester.pumpAndSettle();
      expect(inDialog(find.text('Telefon')), findsOneWidget);
      final field = inDialog(find.byType(TextField));
      expect(tester.widget<TextField>(field).controller!.text,
          '+420 777 123 456');
      expect(tester.widget<TextField>(field).keyboardType,
          TextInputType.phone);

      await tester.enterText(field, '12345');
      await tester.tap(inDialog(find.widgetWithText(FilledButton, 'Uložit')));
      await tester.pumpAndSettle();
      expect(inDialog(find.text(phoneError)), findsOneWidget);
      expect(saved, isEmpty);

      await tester.enterText(field, '00420 602 111 222');
      await tester.pump();
      expect(inDialog(find.text(phoneError)), findsNothing);
      await tester.tap(inDialog(find.widgetWithText(FilledButton, 'Uložit')));
      await tester.pumpAndSettle();

      expect(saved, ['phone=+420602111222 showEmail=null showPhone=null']);
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.text('Uloženo.'), findsOneWidget);
    });

    testWidgets('an empty number removes the phone; Zrušit saves nothing',
        (tester) async {
      tall(tester);
      await tester.pumpWidget(app(withPhone, updateMyContact: record));
      await tester.pumpAndSettle();

      await tester.tap(inCard(find.text('Upravit')));
      await tester.pumpAndSettle();
      await tester.enterText(inDialog(find.byType(TextField)), '');
      await tester.tap(inDialog(find.widgetWithText(FilledButton, 'Uložit')));
      await tester.pumpAndSettle();
      expect(saved, ['phone= showEmail=null showPhone=null']);

      await tester.tap(inCard(find.text('Upravit')));
      await tester.pumpAndSettle();
      await tester.tap(inDialog(find.widgetWithText(TextButton, 'Zrušit')));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(saved, hasLength(1));
    });

    testWidgets('the switches save at once — the phone one even without a '
        'phone', (tester) async {
      tall(tester);
      await tester.pumpWidget(app(me, updateMyContact: record));
      await tester.pumpAndSettle();

      await tester.tap(switchTile('Ukázat e-mail v Kontaktech'));
      await tester.pumpAndSettle();
      await tester.tap(switchTile('Ukázat telefon v Kontaktech'));
      await tester.pumpAndSettle();

      expect(saved, [
        'phone=null showEmail=false showPhone=null',
        'phone=null showEmail=null showPhone=false',
      ]);
    });
  });
}
```

- [ ] **Step 2: Run them to verify they fail**

Run: `TZ=Europe/Prague flutter test test/features/profile_screen_test.dart`
Expected: FAIL — `Error when reading 'lib/features/profile/widgets/contact_card.dart': No such file or directory` and `No named parameter with the name 'updateMyContact'.`

- [ ] **Step 3: Write the card**

Create `lib/features/profile/widgets/contact_card.dart`:

```dart
/// Můj profil → Kontakt (0048): the player's phone, and whether Klubovna →
/// Kontakty shows their e-mail and phone to the other players of the alley.
library;

import 'package:flutter/material.dart';

import '../../../core/ui.dart';
import '../../../domain/models.dart';
import '../../../domain/phone.dart';

class ContactCard extends StatelessWidget {
  const ContactCard({
    super.key,
    required this.profile,
    required this.updateMyContact,
  });

  final Profile profile;

  /// `Api.updateMyContact` in the app — optimistic, so a switch flips at
  /// once; a fake in widget tests.
  final Future<void> Function({String? phone, bool? showEmail, bool? showPhone})
      updateMyContact;

  Future<void> _editPhone(BuildContext context) async {
    final current = profile.phone;
    final phone = await showDialog<String>(
      context: context,
      builder: (_) =>
          _PhoneDialog(initial: current == null ? '' : formatPhone(current)),
    );
    if (phone == null || !context.mounted) return;
    await tryAction(
      context,
      () => updateMyContact(phone: phone),
      success: 'Uloženo.',
      errorText: friendlyDbError,
    );
  }

  @override
  Widget build(BuildContext context) {
    final phone = profile.phone;
    return Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const ListTile(title: Text('Kontakt')),
          ListTile(
            title: const Text('Telefon'),
            subtitle: Text(phone == null ? 'nenastaven' : formatPhone(phone)),
            trailing: TextButton(
              onPressed: () => _editPhone(context),
              child: const Text('Upravit'),
            ),
          ),
          SwitchListTile(
            title: const Text('Ukázat e-mail v Kontaktech'),
            subtitle: const Text('Ostatní hráči kuželny ti můžou napsat.'),
            value: profile.showEmail,
            onChanged: (v) => tryAction(
              context,
              () => updateMyContact(showEmail: v),
              errorText: friendlyDbError,
            ),
          ),
          // Works without a phone too — there is just nothing to show yet.
          SwitchListTile(
            title: const Text('Ukázat telefon v Kontaktech'),
            subtitle: const Text('Zavolat nebo napsat přes WhatsApp.'),
            value: profile.showPhone,
            onChanged: (v) => tryAction(
              context,
              () => updateMyContact(showPhone: v),
              errorText: friendlyDbError,
            ),
          ),
        ],
      ),
    );
  }
}

/// Resolves to the E.164 number, '' to remove the phone, or null (Zrušit).
class _PhoneDialog extends StatefulWidget {
  const _PhoneDialog({required this.initial});

  final String initial;

  @override
  State<_PhoneDialog> createState() => _PhoneDialogState();
}

class _PhoneDialogState extends State<_PhoneDialog> {
  late final _controller = TextEditingController(text: widget.initial);
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _save() {
    final typed = _controller.text.trim();
    if (typed.isEmpty) {
      closeDialog(context, '');
      return;
    }
    final phone = normalizePhone(typed);
    if (phone == null) {
      setState(() => _error = invalidPhoneMessage);
      return;
    }
    closeDialog(context, phone);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Telefon'),
      content: TextField(
        controller: _controller,
        autofocus: true,
        keyboardType: TextInputType.phone,
        decoration: InputDecoration(
          hintText: '+420 777 123 456',
          errorText: _error,
        ),
        onChanged: (_) {
          if (_error != null) setState(() => _error = null);
        },
        onSubmitted: (_) => _save(),
      ),
      actions: [
        TextButton(
          onPressed: () => closeDialog<String>(context),
          child: const Text('Zrušit'),
        ),
        FilledButton(onPressed: _save, child: const Text('Uložit')),
      ],
    );
  }
}
```

- [ ] **Step 4: Place it on Můj profil**

In `lib/features/profile/profile_screen.dart` replace:

```dart
import 'widgets/calendar_link_card.dart';
```

with:

```dart
import 'widgets/calendar_link_card.dart';
import 'widgets/contact_card.dart';
```

Replace:

```dart
    this.setDefaultView = Api.setDefaultView,
  });
```

with:

```dart
    this.setDefaultView = Api.setDefaultView,
    this.updateMyContact = Api.updateMyContact,
  });
```

Replace:

```dart
  final Future<void> Function(HomeView view) setDefaultView;
```

with:

```dart
  final Future<void> Function(HomeView view) setDefaultView;
  final Future<void> Function({String? phone, bool? showEmail, bool? showPhone})
      updateMyContact;
```

Replace (between the Google kalendář card and Vzhled):

```dart
                // Appearance (theme, text size) last: it is about the app
```

with:

```dart
                // Kontakt (0048): the phone, and what Klubovna → Kontakty
                // shows of it and of the e-mail.
                ContactCard(profile: profile, updateMyContact: updateMyContact),
                const SizedBox(height: 16),
                // Appearance (theme, text size) last: it is about the app
```

- [ ] **Step 5: Add the changelog line**

In `lib/features/profile/changelog_data.dart`, in the top web batch `Release(null, '23. 9. 2026', [...])`, replace:

```dart
    'Detail zápasu má zápis jako na kuzelky.com — ikonou vpravo nahoře ho '
        'otevřeš přes celou obrazovku, na výšku i na šířku.',
  ]),
```

with:

```dart
    'Detail zápasu má zápis jako na kuzelky.com — ikonou vpravo nahoře ho '
        'otevřeš přes celou obrazovku, na výšku i na šířku.',
    'Klubovna → Kontakty: e-mail a telefon hráčů kuželny. Svůj e-mail i '
        'telefon můžeš skrýt v Můj profil → Kontakt.',
  ]),
```

- [ ] **Step 6: Run the tests to verify they pass**

Run: `TZ=Europe/Prague flutter test test/features/profile_screen_test.dart test/features/store_notes_test.dart test/changelog_test.dart && flutter analyze`
Expected: `All tests passed!` (the profile file ends with `Kontakt card (0048) the switches save at once — the phone one even without a phone`) and `No issues found!`

- [ ] **Step 7: Commit**

```bash
git add lib/features/profile/widgets/contact_card.dart lib/features/profile/profile_screen.dart lib/features/profile/changelog_data.dart test/features/profile_screen_test.dart
git commit -m "$(cat <<'EOF'
feat(kontakty): Můj profil → Kontakt, and the changelog line

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 7: All gates

**Files:** none changed. A gate that fails is fixed in the task that owns the file, and that fix is committed on its own.

**Interfaces:**
- Consumes: everything from Tasks 1–6.
- Produces: a green branch, ready for review. Nothing is pushed.

- [ ] **Step 1: Static analysis**

Run: `flutter analyze`
Expected: `No issues found!`

- [ ] **Step 2: The whole Flutter suite**

Run: `TZ=Europe/Prague flutter test`
Expected: `All tests passed!`. The known `Warning: A call to tap() … would not hit test` lines, for example in `register_screen_test.dart`'s club dropdown, are warnings, not failures.

- [ ] **Step 3: Edge functions**

Run: `deno test --allow-read supabase/functions`
Expected: `ok | 154 passed | 0 failed`. Nothing here changed; the count only has to stay green.

- [ ] **Step 4: The schema snapshot matches the migrations**

Run: `tool/schema_snapshot.sh && git diff --exit-code supabase/schema.sql; echo "diff exit $?"`
Expected: `supabase/schema.sql regenerated`, then `diff exit 0`. The committed snapshot is exactly what the migrations build.

- [ ] **Step 5: The SQL suite on the freshly reset DB**

Run: `psql "$(supabase status -o env | sed -n 's/^DB_URL="\(.*\)"/\1/p')" -X -v ON_ERROR_STOP=1 -f supabase/tests/tenancy_rls.sql 2>&1 | grep -E 'ERROR|FAIL|\(0048\)'`
Expected: no `ERROR`/`FAIL` line, and exactly the five `NOTICE:  OK: … (0048)` lines of Task 1 Step 5.

- [ ] **Step 6: A clean tree, one commit per task**

Run: `git status --short && git log --oneline -7`
Expected: no output from `git status --short`. The log shows, newest first: `feat(kontakty): Můj profil → Kontakt, and the changelog line`, `feat(kontakty): an optional phone at registration`, `feat(kontakty): Klubovna → Kontakty`, `feat(kontakty): the Contact model, contacts() and updateMyContact in the data layer`, `feat(kontakty): parse, format and WhatsApp-link phone numbers`, `feat(db): a phone and contact privacy on profiles, contacts() and register_profile's phone (0048)`, `docs: plan for Klubovna Kontakty`. Nothing is pushed.
