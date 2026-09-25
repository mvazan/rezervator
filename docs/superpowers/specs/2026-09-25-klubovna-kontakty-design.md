# Klubovna → Kontakty, a phone number, contact privacy

Approved by the user on 2026-09-25 in chat (mockup shown). The app speaks Czech; the user writes Slovak.

## Why

The players of one alley have no way to reach each other in the app. The user wants a contact list in Klubovna. It shows each registered player's name, board nickname and club. Email offers "write an email". Phone offers "call" and "send a WhatsApp message".

A phone number becomes an optional registration field, and it can be edited in the profile. Each player decides whether their email and phone show in the list.

**Decision (user):** both switches default to **on**, for existing players as well. The user's words: "if we did it the other way round, they would never switch them on". As a compromise, the Kontakty page carries a note that everyone can hide their own contact details, with a way to get to that setting.

## Who sees what

- **Viewers.** The list is visible to an **approved, non-kiosk** member of the current alley. A superadmin visiting the alley counts as its member. A pending member sees nothing, and a kiosk sees nothing.
- **Listed players.** The list holds the alley's **registered** players:
  - approved;
  - not a kiosk;
  - not a placeholder ("player without an account", 0022);
  - not a superadmin who only visits the alley (the same rule as the `players` view).
- **Privacy is enforced on the server.** A hidden email or phone never leaves the database. Today a player reads only their own `profiles` row (the RLS `profiles_select`); other players are visible only through the `players` view, which carries no email. So contacts come from a new security-definer RPC, never from `profiles` directly.
- **Admin screens stay as they are.** An admin already sees players' emails in Správa → Hráči. The contacts privacy switches do not apply there.

## Backend: migration `0048_contacts.sql`

The migration is additive and idempotent. 0047 is the latest one.

**New `profiles` columns**
- `phone text null`:
  - stored in international form `+<digits>`, for example `+420777123456`;
  - checked by the constraint `phone is null or phone ~ '^\+[1-9][0-9]{7,14}$'` (E.164).
- `show_email boolean not null default true`.
- `show_phone boolean not null default true`.

**Grants.** `grant update (phone, show_email, show_phone) on profiles to authenticated`. The existing policy `profiles_update_own` limits the update to the player's own row. Select on the new columns follows the existing table grant, which is fine because RLS already limits `profiles` select to the player's own row or to an admin.

**`register_profile`** gets `p_phone text default null`.
- Replace it with `drop function` of the old signature, then `create` with the extra parameter. An app that calls it without `p_phone` still resolves, because the parameter has a default and PostgREST passes named arguments.
- Keep the grants.
- It validates the phone with the same pattern and raises `invalid_phone`.

**`create_tenant_and_register`** gets `p_phone text default null` the same way (drop the three-argument signature, create, grant) and hands it to `register_profile`. A founder's phone is then stored in the same transaction as the tenant and the profile; an `invalid_phone` founds no tenant. (Added after review: a separate write after the founding could be lost while the app had already moved on.)

**`contacts()`** returns a table with:
- `id`, `display_name`, `nick`, `club_id`, `club_name`, `club_color`;
- `email` (null unless `show_email`);
- `phone` (null unless `show_phone`).

It is `security definer`, `stable`, `set search_path = public`.
- The caller must be approved and not a kiosk. Otherwise it raises `not_allowed`. A superadmin visiting the alley passes, the same as `current_tenant_id()`.
- It lists the tenant `current_tenant_id()` with the filters above.
- It is ordered by `display_name`; the app re-sorts with `compareCzech`.
- Grants: `revoke all from public, anon`; `grant execute to authenticated`.

**Tests** in `supabase/tests/tenancy_rls.sql`, section 19:
- a member sees their own alley's registered players only; placeholders, kiosk and pending members are not listed;
- a hidden email or phone comes back null while the other field still shows;
- a kiosk and a pending caller get `not_allowed`, and so does anon;
- another alley is invisible;
- a player can update only their own phone and switches;
- the phone constraint refuses a bad format;
- `register_profile` stores the phone and refuses an invalid one;
- an old-style call without `p_phone` still works;
- `create_tenant_and_register` stores the founder's phone, and a bad one founds no tenant;
- the E.164 bounds: 8 and 15 digits stored, 7 and 16 refused.

**Artefacts.** Regenerate `supabase/schema.sql` and update `docs/SCHEMA.md`.

## App

**Phone parsing and formatting** is a pure function in `lib/domain/phone.dart`.
- `normalizePhone(String input) → String?` returns null for invalid input.
  - It strips spaces, dashes, dots and brackets.
  - It turns a leading `00` into `+`.
  - A bare 9-digit number gets `+420`.
  - The result must match E.164 as above.
  - An empty input means "no phone" (the caller handles that).
- `formatPhone(String e164) → String` gives a readable form. For `+420` it groups as `+420 777 123 456`; any other number is shown as stored.
- `whatsappUri(String e164) → Uri` gives `https://wa.me/<digits without +>`.

**Data layer** (`lib/data/providers.dart`)
- A `Contact` model with `fromJson` in `models.dart`.
- `contactsProvider`, a FutureProvider backed by the RPC. It is refreshed on pull-to-refresh and reset on tenant switch in `resetTenantScopedProviders`.
- `Api.updateMyContact({String? phone, bool? showEmail, bool? showPhone})`.
- `registerProfile(..., phone)`.
- `friendlyDbError` maps `invalid_phone` to „Telefon nemá správný tvar — třeba +420 777 123 456.“ and `not_allowed` as today.
- `Profile` gets `phone`, `showEmail` and `showPhone`.

**Klubovna hub** (`lib/features/clubhouse/clubhouse_screen.dart`)
- A new entry „Kontakty“ with icon `Icons.contacts_outlined` and subtitle „Hráči kuželny — e-mail a telefon“.
- The entries are in Czech alphabetical order, Kontakty, Kuželny, Výsledky (the user's call after the first build). The hub sorts them with `compareCzech`.
- The Kuželny subtitle changes to „Adresy a vybavení kuželen“, so the two entries are not confused.

**`ContactsScreen`** (`lib/features/clubhouse/contacts_screen.dart`)
- AppBar „Kontakty“.
- **Note at the top**, a quiet info line, not an error: „Svůj e-mail a telefon můžeš v Kontaktech skrýt v Můj profil.“ The words „Můj profil“ are a tappable link that opens the profile screen, the same way the shell's profile icon does.
- **Search field**, placeholder „Hledat jméno, přezdívku nebo oddíl“. It ignores diacritics and case, reusing the app's existing search normalisation, for example the one `upcomingMatches` uses.
- **One row per contact**, in Czech alphabetical order:
  - a leading dot in the club colour, or neutral without a club;
  - the name as the title;
  - the subtitle `„nick“ · club name`, leaving out parts that are missing;
  - trailing icon buttons: `Icons.mail_outline` (tooltip „Napsat e-mail“) when an email is shown, `Icons.phone_outlined` („Zavolat“) and a WhatsApp action when a phone is shown.
- **WhatsApp icon.** Material has no WhatsApp glyph. Use `Icons.chat_outlined` with the tooltip „WhatsApp“. Do not add a new icon package.
- A player with neither shown gets a muted trailing text „kontakt skrytý“.
- The player's own row is listed like any other.
- **States:**
  - empty list: „Zatím tu nikdo není.“;
  - no search hits: „Nikdo takový tu není.“;
  - load error: the friendly message with „Zkusit znovu“.
- Pull-to-refresh re-fetches.
- The actions use the existing `launchEmail`, `launchPhone` and `launchWeb` (wa.me) from `core/ui.dart`, injectable for tests like `VenueDetailScreen`.

**Registration** (`register_screen.dart`)
- An optional field „Telefon (nepovinné)“ with a phone keyboard and the helper text „Uvidí ho ostatní hráči kuželny v Kontaktech. Skrýt ho můžeš v Můj profil.“ (added after review: the switch starts on, so the player learns it where the number is given).
- An invalid value is refused inline with the same text as `invalid_phone`.
- A valid one is normalised and passed to `register_profile`, or to `create_tenant_and_register` for a founder.

**Můj profil** (`profile_screen.dart`)
- No card of its own (the user's call after the first build): the contact rows join the **first card**, which reads top to bottom Jméno, E-mail, Telefon, Oddíl, then the two switches, then the existing note.
  - „Telefon“ shows the formatted number or „nenastaven“, with „Upravit“ opening a dialog. The dialog has a field, validation, Zrušit / Uložit, and an empty value removes the phone.
  - A switch „Ukázat e-mail v Kontaktech“ with subtitle „Ostatní hráči kuželny ti můžou napsat.“
  - A switch „Ukázat telefon v Kontaktech“ with subtitle „Zavolat nebo napsat přes WhatsApp.“ The phone switch still works when no phone is set; there is just nothing to show.
- Both switches save immediately with the app's optimistic write pattern, as the other profile settings do. Every contact write carries the phone and both switches as shown, with one of them changed: `optimisticWrite` keeps one pending patch per key, so a patch naming only its own field would show a quick earlier change to another as undone.
- Colours come from `Theme.of(context).colorScheme`, and every string is Czech.

**Changelog.** The web batch at the top of `changelog_data.dart` gets a line: „Klubovna → Kontakty: e-mail a telefon hráčů kuželny. Svůj e-mail i telefon můžeš skrýt v Můj profil.“ Add a `store:` summary only if the batch goes over 500 characters. The batch's Klubovna line says the Kuželny have „adresou, telefonem a navigací“ rather than „kontakty“, so the word means only the new entry.

**Legal pages.** `web/privacy.html` (the Play privacy-policy URL) says who sees the e-mail and the optional phone in Kontakty, that both show by default and where to hide them. `web/delete-account.html` lists the phone among the deleted data. The Play Console data-safety form must say the same: the phone number is collected, and the e-mail and phone are shown to other users of the alley.

## Tests (app)

- **Phone:** unit tests for normalise, format and whatsapp:
  - Czech 9-digit, `+420` with spaces, `00420`, a foreign `+49` number;
  - junk, too short, too long.
- **Models:** parsing `Contact` and the new `Profile` fields.
- **`ContactsScreen`:**
  - Czech sort;
  - search with diacritics;
  - the actions per visibility, each calling the injected launchers with the right values, including the wa.me link;
  - „kontakt skrytý“;
  - the note, and its link opens the profile;
  - the empty and error states.
- **Hub:** the new entry and the renamed Kuželny subtitle.
- **Registration:** an optional phone, invalid input refused inline, a valid one passed normalised.
- **Profile:** the first card holds the phone and the switches in that order, shows the phone, the edit dialog validates and saves, and the switches save at once.
