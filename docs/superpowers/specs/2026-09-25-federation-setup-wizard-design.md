# Správa → Oddíly: ČKA setup wizard, sync progress, pencil edits

Approved by the user on 2026-09-25 in chat. Mockup variant A: the wizard lives inside the ČKA card.

## Why

When the ČKA sync was first enabled in production (24. 9. 2026), four problems came up:

- **No sign of a running sync.** The first sync ran for about 30 minutes, and the card showed nothing to say it was still working.
- **Unclear team switches.** The switches on team rows did not say what they do, and it wasn't obvious that tapping a team's name opens its dialog.
- **Missing club.** „Načíst týmy“ found no KS Devítka Brno club in the app. Its teams ended up in „Nezařazené týmy“ and had to be assigned by hand.
- **Confusing setup.** A new admin gets a slug field, a switch and three buttons with no order to follow.

## Scope

1. A **sync progress** indicator on the ČKA card.
2. A **pencil** instead of the switch on team rows. The pencil on club rows stays.
3. A **first-setup wizard** in the ČKA card (3 steps), then a simplified card.
4. **Clubs remember their ČKA identity.** Discovery creates missing clubs, and renaming a club in the app never breaks the pairing.

Out of scope: registration numbers, statistics, and any change to the pairing of matches.

## Backend: migration `0047_federation_setup.sql`

0045 is deployed, so every change goes in a new migration, idempotent and additive.

### Clubs keep their site identity
- `clubs` gets `site_slug text` (the `detail-klubu/<slug>` of the venue page) and `site_name text` (the club's name on the site). Both are null for clubs that are not linked.
- There is a unique index on `(tenant_id, site_slug)` where `site_slug is not null`.
- Discovery matches every venue club (`parseVenueClubs`: slug + name) to an app club in this order:
  1. by `site_slug`;
  2. otherwise by name, as `clubIdFor` does today. It then **stores** `site_slug` and `site_name` on that club. This backfills the existing production clubs on their first run.
  3. otherwise it **creates the club**:
     - name = the site name, trimmed to the clubs name limit;
     - `site_slug` and `site_name` set;
     - colour = the first palette index none of the tenant's clubs uses, falling back to the least used one.
- Teams:
  - new teams get their club, as today;
  - existing teams with `club_id is null` get the matched club;
  - a club the admin chose is never overwritten.
- Renaming or recolouring a club in the app changes only `name` and `color`. `site_slug` and `site_name` stay, so the next discovery still matches it.
- A club deleted in the app that still plays at the venue is created again by the next „Přenačíst týmy z webu“. The delete confirmation says so for a linked club.
- Everything happens server-side in one transaction: a replaced `upsert_federation_teams` or a new function that runDiscover calls.
- The discovery report gains `clubs_created: [names]` and `clubs_linked: [names]`.

### Progress RPC
- `federation_sync_progress()` is security definer with a fixed search_path. It is granted to authenticated and allowed for admins of the caller's tenant only.
- It returns `{discover, competitions, matches, venues}`: the number of the tenant's federation jobs that are **due now or leased (in flight)**. Future checkpoints (T−24h, T+24h …) do not count.
- It reads the dedupe keys, which carry the tenant id.

## App

### ČKA card (`lib/features/admin/widgets/federation_card.dart`)
**Wizard vs normal view.** Both are derived from server state; no new column.
- The wizard shows while `!enabled && last_run_at == null` (never synced). That covers a missing row as well.
- Which step it opens on:
  - step 1 when there is no slug;
  - step 2 when there is a slug but no teams;
  - step 3 when there is a slug and teams.
- As soon as the sync is enabled or has ever run, the card shows the normal view, even if the sync is later switched off.

**Wizard.** Compact; a 3-segment step bar at the top of the card.
1. **„Kuželna na webu ČKA“**
   - Help text: „Na vysledky.kuzelky.cz otevři Kuželny, najdi svou kuželnu a zkopíruj adresu stránky. Stačí ji celou vložit.“
   - The field accepts the whole URL or just the slug. The host is optional; a trailing slash, query and fragment are dropped, and the input is lower-cased.
   - It validates against the DB pattern and shows an inline error.
   - „Pokračovat“ saves the slug with `enabled=false`.
2. **„Oddíly a týmy“**
   - Text: „Načteme oddíly, které na kuželně hrají, a jejich týmy. Chybějící oddíly založíme.“
   - Button „Načíst oddíly a týmy“. **While discovery runs, the step shows a loader**: a spinner and „Načítají se oddíly a týmy z webu…“, driven by the progress RPC.
   - Then a summary: „N oddílů (M nových: …)“, „T týmů v S soutěžích“.
   - Buttons „Načíst znovu“ and „Pokračovat“. Names, colours and team settings are edited later in the list under the card.
3. **„Zapnout stahování“**
   - Text: „Stáhnou se všechny zápasy a výsledky těchto týmů. Zápasy z rozpisu se spárují a zůstanou. První stažení trvá asi půl hodiny, pak se vše aktualizuje samo.“
   - „Zapnout a stáhnout zápasy“ sets `enabled=true` and requests the first sync. The card then shows the normal view with progress.

**Normal view**
- **Slug row:** „Kuželna na webu“ above a read-only `detail-kuzelny/<slug>`, with a pencil `IconButton` (tooltip „Změnit kuželnu“). The pencil opens a dialog with the same field and URL parsing, and Zrušit / Uložit.
- **„Stahovat automaticky“** saves on change, with error feedback. There is no „Uložit“ button.
- **Buttons:** „Přenačíst týmy z webu“ (renamed) and „Synchronizovat teď“.
- **Progress line**, in place of „Poslední synchronizace“ while anything is pending. Small spinner (about 14 dp, stroke 2) with:
  - „Načítají se týmy z webu…“ while discovery is pending. This is the loader after „Přenačíst týmy z webu“.
  - otherwise „Synchronizuje se… zbývá X zápasů“, adding soutěže and kuželny when they are non-zero.
  - Czech plurals: zápas / zápasy / zápasů, soutěž / soutěže / soutěží, kuželna / kuželny / kuželen.
  - „Poslední synchronizace: …“ stays as a second, muted line.
- **Polling:**
  - every 5 s while anything is pending, plus a grace window of up to 60 s after any of the three buttons (the jobs may not be due yet);
  - stops at 0, on dispose and when the app goes to the background;
  - at 0 it refreshes the sync row.
- The last error shows as today.

### Club and team rows (`lib/features/admin/clubs_screen.dart`)
- **Club rows:** the pencil and trash stay. The club dialog edits name and colour. A linked club shows „Na webu ČKA: <site_name>“ read-only. The delete confirmation warns when the club is linked, see above.
- **Team rows:** no Switch. A trailing pencil `IconButton` (tooltip „Upravit tým“) opens the existing `TeamDialog`, and a row tap does the same. An inactive team is greyed out and its subtitle ends with „· nestahuje se“.

## Tests
- **SQL (`tenancy_rls.sql`):**
  - site_slug matching and the name-match backfill;
  - club creation (once, idempotent, free colour);
  - a club renamed after linking still matches;
  - a club chosen by the admin is kept;
  - progress counts (due and leased only), non-admin refused, tenant isolation.
- **Deno:** discovery with a missing club, a renamed club and an existing name match.
- **Widget tests:**
  - wizard step derivation (3 entry states);
  - URL → slug parsing and invalid input;
  - every step's action;
  - the discovery loader and summary;
  - switching to the normal view;
  - read-only slug and the pencil dialog;
  - the switch saves immediately and there is no „Uložit“;
  - the renamed button;
  - the progress line with plurals and the discovery loader text;
  - polling starts and stops with fake async, and no timer is left after dispose;
  - the team-row pencil, no switch, the inactive subtitle;
  - the club dialog shows the site name;
  - the delete warning.
- **Gates:** `flutter analyze`, `flutter test`, Deno check and test, the RLS file, and the schema snapshot.
