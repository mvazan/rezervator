# ČKA setup wizard Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A new admin sets up the ČKA results service in Správa → Oddíly through a 3-step wizard; clubs remember their ČKA identity, so discovery links or creates them and a rename in the app never breaks the pairing; the card shows a running sync's progress; team rows edit through a pencil.

**Architecture:** One additive migration `0047_federation_setup.sql` gives `clubs` a `site_slug`/`site_name`, adds `apply_federation_discovery` (links or creates every venue club, then upserts the teams, in one transaction), makes discovery no longer a sync run, and adds the admin RPC `federation_sync_progress`. The notify edge function's `runDiscover` matches venue clubs to ours (by slug, else by name) and calls the new function. In the app, `FederationCard` becomes wizard-or-normal-view derived from the sync row, polls the progress RPC while jobs are pending, and the clubs screen swaps the team switch for a pencil.

**Tech Stack:** Supabase (Postgres 15, PL/pgSQL, RLS), Deno edge functions (TypeScript, `jsr:@std/assert@1`), Flutter 3.38 + Riverpod 3, `flutter_test` fake async.

**Spec:** `docs/superpowers/specs/2026-09-25-federation-setup-wizard-design.md` (approved 2026-09-25, variant A).

## Global Constraints

- Repo `/Users/mvazan/Home/rezervator`, branch `federation-setup-wizard`; run every command from the repo root.
- One commit per task; never `git push`, never deploy.
- Every commit message ends with the trailer line `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.
- `supabase/migrations/0047_federation_setup.sql` is additive and idempotent — `add column if not exists`, `create unique index if not exists`, `create or replace function`, re-runnable `revoke`/`grant` — and running the whole file twice must succeed. `0045_federation.sql` is deployed and never edited.
- The local DB holds seed data only, so `tool/schema_snapshot.sh` (it runs `supabase db reset`) is fine to run; commit the regenerated `supabase/schema.sql` with the migration change.
- Server-only functions: `revoke all … from public, anon, authenticated; grant execute … to service_role`. App RPCs: `revoke all … from public, anon; grant execute … to authenticated`.
- Club palette: indexes 0–8 (`ClubColors.count` = 9, `clubs_color_check`); -1 = none; values ≥ 0x1000000 are hand-picked colours.
- The club pencil stays. A rename or recolour in the app changes only `name` and `color` (`upsert_club`); `site_slug` and `site_name` stay, so scraping keeps its original club identity.
- No hint text explaining the team pencil or the row tap (user: „to je zrejmé“).
- Discovery shows a loader in the wizard (step 2) and after „Přenačíst týmy z webu“ (the progress line), both driven by `federation_sync_progress`. A failed discovery's error in the row ends the loader (plan decision 7).
- UI copy is Czech, code and comments English. Colours come from `Theme.of(context).colorScheme` (this repo has no SurfaceColors class); no hard-coded colours.
- Lists are Czech-alphabetical (`compareCzech`) or chronological.
- Wizard copy, verbatim from the spec:
  - Step 1: title „Kuželna na webu ČKA“; help „Na vysledky.kuzelky.cz otevři Kuželny, najdi svou kuželnu a zkopíruj adresu stránky. Stačí ji celou vložit.“; button „Pokračovat“.
  - Step 2: title „Oddíly a týmy“; text „Načteme oddíly, které na kuželně hrají, a jejich týmy. Chybějící oddíly založíme.“; button „Načíst oddíly a týmy“; loader „Načítají se oddíly a týmy z webu…“; summary „N oddílů (M nových: …)“ and „T týmů v S soutěžích“; buttons „Načíst znovu“ and „Pokračovat“.
  - Step 3: title „Zapnout stahování“; text „Stáhnou se všechny zápasy a výsledky těchto týmů. Zápasy z rozpisu se spárují a zůstanou. První stažení trvá asi půl hodiny, pak se vše aktualizuje samo.“; button „Zapnout a stáhnout zápasy“.
- Normal-view copy, verbatim from the spec:
  - „Kuželna na webu“ above a read-only `detail-kuzelny/<slug>`, with a pencil tooltip „Změnit kuželnu“ opening a dialog with Zrušit / Uložit.
  - „Stahovat automaticky“ saves on change; there is no „Uložit“.
  - Buttons „Přenačíst týmy z webu“ and „Synchronizovat teď“.
- Progress-line copy, verbatim from the spec:
  - „Načítají se týmy z webu…“ while discovery is pending.
  - Otherwise „Synchronizuje se… zbývá X zápasů“, plus soutěže and kuželny.
  - Plurals: zápas / zápasy / zápasů, soutěž / soutěže / soutěží, kuželna / kuželny / kuželen.
  - „Poslední synchronizace: …“ stays as a second, muted line.
  - The spinner is 14 dp with stroke 2.
- Clubs-screen copy, verbatim from the spec: club dialog „Na webu ČKA: <site_name>“; team pencil tooltip „Upravit tým“; an inactive team's subtitle ends „ · nestahuje se“.
- The wizard shows while `!enabled && last_run_at == null`: step 1 without a slug, step 2 with a slug but no teams, step 3 with both. "Teams" means the teams of a successful discovery of the current kuželna (plan decision 14).
- Polling runs every 5 s while anything is pending, plus a grace window of up to 60 s after a request button. It stops at 0, on dispose and in the background, and at 0 it fetches the sync row again.
- A widget test with a spinner on screen uses `tester.pump(…)`, never `pumpAndSettle()` (a spinner never settles).
- Gates: `flutter analyze` → `No issues found!`; `TZ=Europe/Prague flutter test`; `deno check --import-map supabase/functions/import_map.json supabase/functions/notify/index.ts`; `deno test --allow-read supabase/functions`; `supabase/tests/tenancy_rls.sql`; schema snapshot diff.

## Plan decisions (where the spec is silent)

1. **Discovery is no longer a sync run.** 0045's `record_federation_run` stamps `last_run_at` for `discover` too, which would end the wizard at step 2 and make the spec's "step 3 when there is a slug and teams" unreachable. 0047 replaces it: only `competition:<slug>` runs stamp `last_run_at`/`last_success_at`, and `discover` keeps its report under its key.
2. **Every venue club is linked or created**, even one without a team this season (spec: "Discovery matches every venue club").
3. `clubs.name` has no length check; a created club's name is cut to 80 characters, like `teams.name`.
4. `clubs_linked` holds our names of the clubs matched by slug or by name, so the summary's N = linked + created.
5. A venue club whose site name another club of the alley already has (one linked to another venue club) creates nothing, and its teams stay without a club.
6. The report gains `competitions` (distinct competitions among the discovered teams) for „T týmů v S soutěžích“.
7. **„Leased“ means `attempts > 0` and `run_at` within the notify tick's 10-minute lease** (`LEASE_MS`). A retry backing off within that window counts too. So a failed discovery (a well-formed slug of no kuželna → HTTP 404, or „na stránce kuželny nejsou žádné kluby“) stays counted for about a quarter of an hour: `jobOutcome` re-arms it at +1, +2, +4 and +8 min, with attempts 1–4. The card therefore trusts the row over the count. Once `last_report.discover` holds an error, and no newer request from the card is still waiting for its report, neither the wizard's loader nor „Načítají se týmy z webu…“ shows. The error shows instead, with „Načíst znovu“ (wizard) or as „Chyba: …“ (normal view). The looks go on while the job counts; only what the card shows leaves the discovery out.
8. **Grace window**: 12 looks × 5 s. It ends early once a look sees the run pending. After a discovery's jobs are done, up to 2 more looks wait for its report to reach the row.
9. When a discovery settles, the card also fetches teams and clubs again: the wizard's step and the list under the card depend on them.
10. The progress line leaves out zero counts, and the verb agrees with the first count („zbývají 2 zápasy“). The summary's locative takes „ve“ before dvou–čtyřech, dvanácti–čtrnácti and dvaceti–čtyřiceti. New club names are Czech-sorted.
11. **„Zpět“ on steps 2 and 3.** Without it a wrong kuželna would be a dead end: step 1 never opens once a slug exists. Another kuželna saved after Zpět does not inherit the old one's discovery (decision 14).
12. The wizard's field starts empty for a new alley; the old `tj-sokol-brno-iv` default is gone. The discovery success snackbar is replaced by the loader, and enabling the sync shows no snackbar.
13. Copy the plan adds:
    - dialog title „Změnit kuželnu“, field label „Adresa kuželny“, hint `vysledky.kuzelky.cz/detail-kuzelny/…`;
    - field errors „Vlož adresu stránky kuželny.“ and „Tohle není adresa kuželny — zkopíruj adresu stránky, která obsahuje /detail-kuzelny/.“;
    - „Zpět“, „Načtení se nepovedlo: <error>“, „Na kuželně se nenašel žádný tým. Zkontroluj adresu kuželny.“;
    - the delete warning „Oddíl je propojený s webem ČKA, takže ho příští „Přenačíst týmy z webu“ založí znovu.“;
    - tooltips „Upravit oddíl“ and „Smazat oddíl“, plus „Zatím nenastavená“ and „Načítám…“.
14. **Step 3 needs a discovery of the current kuželna.** The spec's "step 3 when there is a slug and teams" assumes the teams belong to that kuželna. It covers two paths:
    - **Leaving and coming back.** Since 0047, `set_federation_sync` drops `last_report.discover` when the kuželna changes. The wizard opens step 3 only when there are teams and a successful report.
    - **The same visit.** After Zpět → another kuželna → Pokračovat, step 2 ignores the report the row held before the save (matched by its `at`) until the row's echo drops it. It shows „Načíst oddíly a týmy“, and has no Pokračovat, until the new kuželna's report arrives.

    The old kuželna's teams, and any clubs its discovery created, stay. The app cannot delete a team, so the admin switches them off in the list under the card (team pencil → „Stahovat zápasy“) and deletes those clubs there before step 3. The wizard does not do this for them. Only a pasted address of another real kuželna leaves any behind; a wrong address fails the discovery (HTTP 404) and creates nothing.

## File structure

| File | Responsibility |
|---|---|
| `supabase/migrations/0047_federation_setup.sql` (new) | clubs' ČKA identity, `apply_federation_discovery`, `upsert_federation_teams` v2, `record_federation_run` v2, `set_federation_sync` v2, `federation_sync_progress` |
| `supabase/tests/tenancy_rls.sql` | sections 16–18 (0047); section 13/13b updated for "discovery is no run" |
| `supabase/schema.sql`, `docs/SCHEMA.md` | snapshot and docs |
| `supabase/functions/_shared/federation_jobs.ts` (+ `_test.ts`) | `planClubs`, `planTeams` with `club_slug`, `runDiscover` → `apply_federation_discovery` |
| `lib/domain/models.dart` | `Club.siteSlug/siteName/linked`, `FederationSync.discover`, `FederationDiscoverReport`, `FederationSyncProgress` |
| `lib/data/providers.dart` | `Api.federationSyncProgress` |
| `lib/domain/slug.dart` | `venueSlugPattern`, `venueSlugFromInput`, `venueSlugInputError` |
| `lib/domain/labels.dart` | `czechCount`, `teamsLoadingLabel`, `federationProgressLabel`, `discoveryClubsLabel`, `discoveryTeamsLabel` |
| `lib/features/admin/widgets/venue_slug_field.dart` (new) | `VenueSlugField`, `VenueSlugDialog`, `venueSlugHelp` |
| `lib/features/admin/widgets/federation_wizard.dart` (new) | the 3-step wizard |
| `lib/features/admin/widgets/federation_card.dart` | wizard-or-normal view, progress polling |
| `lib/features/admin/clubs_screen.dart`, `widgets/club_dialog.dart` | team pencil, club site name, delete warning |
| `test/features/federation_card_test.dart` (new), `test/features/clubs_screen_test.dart`, `test/domain/*` | tests |
| `README.md` | the setup wizard in „Zápasy ze svazu“ |

---

### Task 1: Clubs remember their ČKA identity; discovery links or creates them (SQL)

**Files:**
- Create: `supabase/migrations/0047_federation_setup.sql`
- Modify: `supabase/tests/tenancy_rls.sql` (new section 16 before the file's final `reset role;` / `rollback;`)
- Modify: `supabase/schema.sql` (regenerated), `docs/SCHEMA.md`
- Test: `supabase/tests/tenancy_rls.sql`

**Interfaces:**
- Consumes: 0045 `upsert_federation_teams(uuid, jsonb) returns integer`, `federation_refresh_error(uuid)`; `clubs` (unique `(tenant_id, name)`, `clubs_color_check`); `upsert_club(p_id uuid, p_name text, p_color integer)` (writes `name`, `color` only).
- Produces:
  - `clubs.site_slug text` and `clubs.site_name text`, both nullable; unique index `clubs_tenant_site_slug_key` on `(tenant_id, site_slug) where site_slug is not null`.
  - `apply_federation_discovery(p_tenant uuid, p_clubs jsonb, p_teams jsonb) returns jsonb`, service_role only.
    - `p_clubs` = `[{"slug": text, "name": text, "match_id": uuid | null}]`, the venue page's order.
    - `p_teams` = `[{"site_slug", "site_team_id", "site_name", "competition_slug", "competition_name", "name", "club_slug"}]`.
    - It returns `{"created": int, "clubs_created": [text], "clubs_linked": [text]}`.
  - `upsert_federation_teams(p_tenant uuid, p_teams jsonb) returns integer`, same signature. It now gives an existing team with `club_id is null` the club it is handed, and treats another tenant's club id as none.

- [ ] **Step 1: Write the failing test**

In `supabase/tests/tenancy_rls.sql` replace the end of the file:

```sql
  raise notice 'OK: with both alleys configured, each admin sees only their own sync settings (0045)';
end $$;

reset role;
rollback;
```

with:

```sql
  raise notice 'OK: with both alleys configured, each admin sees only their own sync settings (0045)';
end $$;

-- 0047 průvodce nastavením ČKA -----------------------------------------------
reset role;

-- 16. apply_federation_discovery matches every venue club to a club of
-- ours — by site_slug, else by the edge function's name match, which it
-- links — or creates it, and hands the teams their clubs. An alley of its
-- own keeps the colour counts exact.
insert into tenants (id, name)
values ('00000000-0000-0000-0000-00000000000c', 'Kuželna C (0047)');
do $$
declare
  v_c constant uuid := '00000000-0000-0000-0000-00000000000c';
  v_teams constant jsonb := '[
    {"site_slug":"tj-sokol-brno-iv-muzi","site_team_id":1,"site_name":"TJ Sokol Brno IV",
     "competition_slug":"jihomoravska-divize-2026-2027","competition_name":"Jihomoravská divize",
     "name":"TJ Sokol Brno IV A","club_slug":"tj-sokol-brno-iv"},
    {"site_slug":"ks-devitka-brno-b-muzi","site_team_id":2,"site_name":"KS Devítka Brno B",
     "competition_slug":"krajsky-prebor-2026-2027","competition_name":"Krajský přebor",
     "name":"KS Devítka Brno B","club_slug":"ks-devitka-brno"}]';
  v_sokol uuid;
  v_veverky uuid;
  v_devitka uuid;
  v_clubs jsonb;
  r jsonb;
begin
  insert into clubs (tenant_id, name, color) values (v_c, 'Sokol Brno IV', 0)
  returning id into v_sokol;
  insert into clubs (tenant_id, name, color) values (v_c, 'Veverky', 1)
  returning id into v_veverky;
  v_clubs := jsonb_build_array(
    jsonb_build_object('slug', 'tj-sokol-brno-iv', 'name', 'TJ Sokol Brno IV',
                       'match_id', v_sokol),
    jsonb_build_object('slug', 'ks-devitka-brno', 'name', 'KS Devítka Brno',
                       'match_id', null));

  r := apply_federation_discovery(v_c, v_clubs, v_teams);
  if r is distinct from
     '{"created":2,"clubs_created":["KS Devítka Brno"],"clubs_linked":["Sokol Brno IV"]}'::jsonb then
    raise exception 'FAIL: the first discovery reported %', r;
  end if;
  if not exists (select 1 from clubs
                  where id = v_sokol and name = 'Sokol Brno IV' and color = 0
                    and site_slug = 'tj-sokol-brno-iv' and site_name = 'TJ Sokol Brno IV') then
    raise exception 'FAIL: the club matched by name was not linked, or lost its name or colour';
  end if;
  select id into v_devitka from clubs
   where tenant_id = v_c and site_slug = 'ks-devitka-brno' and name = 'KS Devítka Brno'
     and site_name = 'KS Devítka Brno' and color = 2;
  if v_devitka is null then
    raise exception 'FAIL: the missing club was not created, linked, in the first free colour: %',
      (select jsonb_agg(to_jsonb(k)) from clubs k where k.tenant_id = v_c);
  end if;
  if (select club_id from teams where tenant_id = v_c and site_slug = 'tj-sokol-brno-iv-muzi')
       is distinct from v_sokol
     or (select club_id from teams where tenant_id = v_c and site_slug = 'ks-devitka-brno-b-muzi')
       is distinct from v_devitka then
    raise exception 'FAIL: the new teams did not get their clubs';
  end if;

  r := apply_federation_discovery(v_c, v_clubs, v_teams);
  if r is distinct from
     '{"created":0,"clubs_created":[],"clubs_linked":["Sokol Brno IV","KS Devítka Brno"]}'::jsonb
     or (select count(*) from clubs where tenant_id = v_c) <> 3 then
    raise exception 'FAIL: a second discovery was not idempotent: %', r;
  end if;

  -- Renamed and recoloured in the app (upsert_club writes those two only).
  update clubs set name = 'Devítka', color = 5 where id = v_devitka;
  r := apply_federation_discovery(v_c, v_clubs, v_teams);
  if r is distinct from
     '{"created":0,"clubs_created":[],"clubs_linked":["Sokol Brno IV","Devítka"]}'::jsonb
     or not exists (select 1 from clubs
                     where id = v_devitka and name = 'Devítka' and color = 5
                       and site_slug = 'ks-devitka-brno') then
    raise exception 'FAIL: a renamed club no longer matched its venue club: %', r;
  end if;

  -- The admin's club stands; a team left without one gets its venue club's.
  update teams set club_id = v_veverky
   where tenant_id = v_c and site_slug = 'ks-devitka-brno-b-muzi';
  update teams set club_id = null
   where tenant_id = v_c and site_slug = 'tj-sokol-brno-iv-muzi';
  perform apply_federation_discovery(v_c, v_clubs, v_teams);
  if (select club_id from teams where tenant_id = v_c and site_slug = 'ks-devitka-brno-b-muzi')
       is distinct from v_veverky
     or (select club_id from teams where tenant_id = v_c and site_slug = 'tj-sokol-brno-iv-muzi')
       is distinct from v_sokol then
    raise exception 'FAIL: discovery replaced the admin''s club or left a team without its club';
  end if;

  -- A linked club deleted in the app comes back with the next discovery.
  delete from clubs where id = v_devitka;
  r := apply_federation_discovery(v_c, v_clubs, v_teams);
  if r->'clubs_created' is distinct from '["KS Devítka Brno"]'::jsonb
     or not exists (select 1 from clubs
                     where tenant_id = v_c and site_slug = 'ks-devitka-brno'
                       and name = 'KS Devítka Brno') then
    raise exception 'FAIL: a deleted linked club was not created again: %', r;
  end if;
  raise notice 'OK: discovery links clubs by site_slug, else by name, else creates them once; renames and the admin''s clubs hold (0047)';
end $$;

-- 16b. A created club takes the first palette colour (0–8) no club of the
-- alley uses, else the least used one; a name another club has creates
-- nothing.
do $$
declare
  v_c constant uuid := '00000000-0000-0000-0000-00000000000c';
  r jsonb;
begin
  delete from teams where tenant_id = v_c;
  delete from clubs where tenant_id = v_c;
  insert into clubs (tenant_id, name, color)
  select v_c, 'Barva ' || i, i from generate_series(0, 8) i;
  insert into clubs (tenant_id, name, color)
  values (v_c, 'Barva 0 znovu', 0), (v_c, 'Bez barvy', -1), (v_c, 'Vlastní', 16777216);
  perform apply_federation_discovery(v_c,
    '[{"slug":"kk-novy","name":"KK Nový","match_id":null}]', '[]');
  if (select color from clubs where tenant_id = v_c and site_slug = 'kk-novy')
     is distinct from 1 then
    raise exception 'FAIL: with the palette used up the new club should take the least used colour, 1';
  end if;
  r := apply_federation_discovery(v_c,
    '[{"slug":"kk-barva","name":"Barva 3","match_id":null}]', '[]');
  if r is distinct from '{"created":0,"clubs_created":[],"clubs_linked":[]}'::jsonb
     or exists (select 1 from clubs where tenant_id = v_c and site_slug = 'kk-barva') then
    raise exception 'FAIL: a venue club whose name another club has was created or linked: %', r;
  end if;
  raise notice 'OK: a created club takes the first free palette colour, else the least used; a taken name creates nothing (0047)';
end $$;

-- 16c. Renaming or recolouring a club in the app keeps its ČKA identity.
insert into clubs (tenant_id, name, color, site_slug, site_name)
values ('00000000-0000-0000-0000-00000000000a', 'Propojený oddíl', 3,
        'kk-propojeny', 'KK Propojený');
set local role authenticated;
set local request.jwt.claims =
  '{"sub":"10000000-0000-0000-0000-000000000001","role":"authenticated"}';
do $$
declare
  v uuid;
begin
  select id into v from clubs where site_slug = 'kk-propojeny';
  perform upsert_club(v, 'Přejmenovaný oddíl', 4);
  if not exists (select 1 from clubs
                  where id = v and name = 'Přejmenovaný oddíl' and color = 4
                    and site_slug = 'kk-propojeny' and site_name = 'KK Propojený') then
    raise exception 'FAIL: upsert_club touched the club''s ČKA identity';
  end if;
  raise notice 'OK: renaming or recolouring a club keeps its site_slug and site_name (0047)';
end $$;
reset role;

-- 16d. Discovery's function is the service's alone.
do $$
declare
  f constant text := 'public.apply_federation_discovery(uuid, jsonb, jsonb)';
begin
  if has_function_privilege('authenticated', f, 'execute')
     or has_function_privilege('anon', f, 'execute')
     or not has_function_privilege('service_role', f, 'execute') then
    raise exception 'FAIL: apply_federation_discovery must be callable by the service only';
  end if;
  raise notice 'OK: apply_federation_discovery is callable by the service only (0047)';
end $$;

reset role;
rollback;
```

- [ ] **Step 2: Run it to verify it fails**

Run: `psql "$(supabase status -o env | sed -n 's/^DB_URL="\(.*\)"/\1/p')" -X -v ON_ERROR_STOP=1 -f supabase/tests/tenancy_rls.sql 2>&1 | grep -E 'ERROR|FAIL'`
Expected: `ERROR:  function apply_federation_discovery(uuid, jsonb, jsonb) does not exist`

- [ ] **Step 3: Write the migration**

Create `supabase/migrations/0047_federation_setup.sql`:

```sql
-- 0047 — průvodce nastavením ČKA (Správa → Oddíly): clubs remember the
-- venue club they are on vysledky.kuzelky.cz, and discovery links the
-- venue's clubs to ours or creates them, in one transaction. Spec:
-- docs/superpowers/specs/2026-09-25-federation-setup-wizard-design.md
-- 0045 is deployed: everything here is additive and safe to run twice.

-- ------------------------------------------------- clubs: ČKA identity
alter table clubs add column if not exists site_slug text;
alter table clubs add column if not exists site_name text;
comment on column clubs.site_slug is
  'The venue club on vysledky.kuzelky.cz (detail-klubu/<slug>) this club is linked to; null = not linked. Written by discovery only, so a rename in the app keeps the link.';
comment on column clubs.site_name is
  'The linked club''s name on vysledky.kuzelky.cz, refreshed by every discovery.';
create unique index if not exists clubs_tenant_site_slug_key
  on clubs (tenant_id, site_slug) where site_slug is not null;

-- ------------------------------------------------------- discovery
-- 0045's upsert_federation_teams, except that an existing team without a
-- club (discovered before its club existed, or whose club was deleted)
-- takes the one discovery matched. A club the admin chose is never
-- replaced, and a club id of another alley reads as none.
create or replace function upsert_federation_teams(p_tenant uuid, p_teams jsonb)
returns integer language plpgsql security definer set search_path = public as $$
declare
  t jsonb;
  v_name text;
  v_club uuid;
  v_new integer := 0;
begin
  for t in select * from jsonb_array_elements(p_teams) loop
    select id into v_club from clubs
     where id = (t->>'club_id')::uuid and tenant_id = p_tenant;
    update teams
       set site_team_id = (t->>'site_team_id')::integer, site_name = t->>'site_name',
           competition_slug = t->>'competition_slug',
           competition_name = t->>'competition_name',
           club_id = coalesce(club_id, v_club)
     where tenant_id = p_tenant and site_slug = t->>'site_slug';
    if found then
      continue;
    end if;
    v_name := left(t->>'name', 80);
    if exists (select 1 from teams where tenant_id = p_tenant and name = v_name) then
      v_name := left((t->>'name') || ' (' || (t->>'competition_name') || ')', 80);
    end if;
    if exists (select 1 from teams where tenant_id = p_tenant and name = v_name) then
      v_name := left((t->>'site_name') || ' (' || (t->>'site_slug') || ')', 80);
    end if;
    insert into teams (tenant_id, name, club_id, site_team_id, site_slug, site_name,
                       competition_slug, competition_name)
    values (p_tenant, v_name, v_club, (t->>'site_team_id')::integer,
            t->>'site_slug', t->>'site_name', t->>'competition_slug',
            t->>'competition_name');
    v_new := v_new + 1;
  end loop;
  -- A team rolled over to a new season leaves its old competition dead.
  perform federation_refresh_error(p_tenant);
  return v_new;
end;
$$;

-- Discovery in one transaction. p_clubs: every venue club, in the venue
-- page's order, as [{slug, name, match_id}] — match_id is the club of ours
-- the edge function matched (by slug, else by name among the unlinked
-- ones), or null. p_teams: upsert_federation_teams' rows, each with
-- club_slug, the venue club the team plays for, in place of club_id.
-- A venue club becomes, in this order:
--   1. the club linked to its slug — whatever the admin renamed it to; its
--      site_name follows the site;
--   2. the club match_id names, when it is not linked yet: it gets linked;
--   3. a new club: the site's name, cut to 80 like teams.name (clubs.name
--      has no bound of its own), linked, in the first palette colour no
--      club of the alley uses, else the least used one. A name another club
--      already has creates nothing: its teams stay without a club.
-- Returns {created: new teams, clubs_created: [names], clubs_linked: [our
-- names of the clubs found in 1 or 2]}, both in p_clubs order.
create or replace function apply_federation_discovery(
  p_tenant uuid, p_clubs jsonb, p_teams jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  c jsonb;
  v_club uuid;
  v_name text;
  v_ids jsonb := '{}'::jsonb;
  v_created text[] := '{}';
  v_linked text[] := '{}';
  v_teams jsonb;
begin
  for c in select * from jsonb_array_elements(coalesce(p_clubs, '[]'::jsonb)) loop
    select id, name into v_club, v_name from clubs
     where tenant_id = p_tenant and site_slug = c->>'slug';
    if v_club is not null then
      update clubs set site_name = c->>'name'
       where id = v_club and site_name is distinct from c->>'name';
    else
      update clubs set site_slug = c->>'slug', site_name = c->>'name'
       where tenant_id = p_tenant and id = (c->>'match_id')::uuid and site_slug is null
      returning id, name into v_club, v_name;
    end if;
    if v_club is not null then
      v_linked := v_linked || v_name;
    else
      v_name := rtrim(left(coalesce(nullif(trim(c->>'name'), ''), c->>'slug'), 80));
      -- Palette entries are 0–8 (clubs_color_check since 0031, ClubColors
      -- in lib/domain/palette.dart); -1 and hand-picked colours use none.
      insert into clubs (tenant_id, name, color, site_slug, site_name)
      values (p_tenant, v_name,
              (select i from generate_series(0, 8) i
                order by (select count(*) from clubs k
                           where k.tenant_id = p_tenant and k.color = i), i
                limit 1),
              c->>'slug', c->>'name')
      on conflict do nothing
      returning id into v_club;
      if v_club is not null then
        v_created := v_created || v_name;
      end if;
    end if;
    if v_club is not null then
      v_ids := v_ids || jsonb_build_object(c->>'slug', v_club);
    end if;
  end loop;
  select coalesce(jsonb_agg(x || jsonb_build_object('club_id', v_ids->(x->>'club_slug'))
                            order by o), '[]'::jsonb)
    into v_teams
    from jsonb_array_elements(coalesce(p_teams, '[]'::jsonb)) with ordinality e(x, o);
  return jsonb_build_object(
    'created', upsert_federation_teams(p_tenant, v_teams),
    'clubs_created', to_jsonb(v_created),
    'clubs_linked', to_jsonb(v_linked));
end;
$$;

revoke all on function apply_federation_discovery(uuid, jsonb, jsonb)
  from public, anon, authenticated;
grant execute on function apply_federation_discovery(uuid, jsonb, jsonb) to service_role;
```

- [ ] **Step 4: Apply it, twice**

Run: `supabase migration up --local`
Expected: `Applying migration 0047_federation_setup.sql...` then `Local database is up to date.`

Run: `psql "$(supabase status -o env | sed -n 's/^DB_URL="\(.*\)"/\1/p')" -X -v ON_ERROR_STOP=1 -q -f supabase/migrations/0047_federation_setup.sql; echo "exit $?"`
Expected: `NOTICE`s like `column "site_slug" of relation "clubs" already exists, skipping`, then `exit 0`.

- [ ] **Step 5: Run the test to verify it passes**

Run: `psql "$(supabase status -o env | sed -n 's/^DB_URL="\(.*\)"/\1/p')" -X -v ON_ERROR_STOP=1 -f supabase/tests/tenancy_rls.sql 2>&1 | grep -E 'ERROR|FAIL|0047\)'`
Expected: no `ERROR`/`FAIL`, and exactly these four lines:
```
NOTICE:  OK: discovery links clubs by site_slug, else by name, else creates them once; renames and the admin's clubs hold (0047)
NOTICE:  OK: a created club takes the first free palette colour, else the least used; a taken name creates nothing (0047)
NOTICE:  OK: renaming or recolouring a club keeps its site_slug and site_name (0047)
NOTICE:  OK: apply_federation_discovery is callable by the service only (0047)
```

- [ ] **Step 6: Document it in `docs/SCHEMA.md`**

Replace the `clubs` row:
```
| `clubs` | `name` unique per tenant, `color` (−1 = none) | select approved/kiosk; all admin. |
```
with:
```
| `clubs` | `name` unique per tenant, `color` (−1 = none), `site_slug` / `site_name` (0047: the venue club on vysledky.kuzelky.cz this club is linked to — its `detail-klubu/<slug>`, unique per tenant when set — and its name there; null = not linked. Only discovery writes them (`apply_federation_discovery`), so a rename or recolour in the app keeps the link) | select approved/kiosk; all admin. |
```

In the service-role functions row, replace:
```
`federation_last_error(tenant, report)` (0045) | service_role only (notify function) |
```
with:
```
`federation_last_error(tenant, report)` (0045), `apply_federation_discovery(tenant, clubs, teams)` (0047) | service_role only (notify function) |
```

Replace the **Discovery** bullet:
```
- **Discovery** (`federation_discover` job, `request_federation_discovery`):
  the venue's teams → `upsert_federation_teams`. A new team arrives active
  under the site's name, cut to 80 chars (a clash with an existing name
  gets ` (<competition>)` appended; if that is taken too,
  `<site_name> (<site_slug>)`); an existing one (same `site_slug`) keeps
  the admin's name, club and switch — only the site's facts are refreshed.
  A team rolled over to the next season's competition leaves the past
  season's `competition:` and `match:` keys dead, so their errors leave
  `last_error` at once.
```
with:
```
- **Discovery** (`federation_discover` job, `request_federation_discovery`):
  the venue's clubs and their teams → `apply_federation_discovery` (0047),
  one transaction. Every venue club (`detail-klubu/<slug>` on the venue
  page) becomes a club of ours: the one linked to its slug
  (`clubs.site_slug`, whatever the admin renamed it to; `site_name`
  follows the site), else the unlinked club the edge function matched by
  name (it gets linked), else a new one — the site's name cut to 80, in
  the first palette colour no club of the alley uses, else the least used
  one. A name another club already has creates nothing. A deleted club
  that still plays at the venue is created again. Then
  `upsert_federation_teams`: a new team arrives active under the site's
  name, cut to 80 chars (a clash with an existing name gets
  ` (<competition>)` appended; if that is taken too,
  `<site_name> (<site_slug>)`), with its venue club's club; an existing
  one (same `site_slug`) keeps the admin's name, club and switch — only
  the site's facts are refreshed, and one without a club gets its venue
  club's. A team rolled over to the next season's competition leaves the
  past season's `competition:` and `match:` keys dead, so their errors
  leave `last_error` at once. Its report (`last_report.discover`):
  `{teams, competitions, created, clubs_created, clubs_linked, at}`.
```

- [ ] **Step 7: Regenerate the schema snapshot and re-run the test on the rebuilt DB**

Run: `tool/schema_snapshot.sh && git diff --stat supabase/schema.sql`
Expected: `supabase/schema.sql regenerated`; the diff touches `supabase/schema.sql` (the `clubs` columns, `clubs_tenant_site_slug_key`, `apply_federation_discovery`, `upsert_federation_teams`).

Run: `psql "$(supabase status -o env | sed -n 's/^DB_URL="\(.*\)"/\1/p')" -X -v ON_ERROR_STOP=1 -q -f supabase/tests/tenancy_rls.sql > /dev/null 2>&1; echo "exit $?"`
Expected: `exit 0`.

- [ ] **Step 8: Commit**

```bash
git add supabase/migrations/0047_federation_setup.sql supabase/tests/tenancy_rls.sql supabase/schema.sql docs/SCHEMA.md
git commit -m "$(cat <<'EOF'
feat(federation): clubs remember their ČKA identity; discovery links or creates them

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 2: runDiscover hands the venue's clubs to apply_federation_discovery (Deno)

**Files:**
- Modify: `supabase/functions/_shared/federation_jobs.ts`
- Test: `supabase/functions/_shared/federation_jobs_test.ts`

**Interfaces:**
- Consumes: Task 1's `apply_federation_discovery(p_tenant, p_clubs, p_teams)` → `{created, clubs_created, clubs_linked}`; `clubs.site_slug`; the existing private `clubIdFor(club: VenueClub, ours: {id: string; name: string}[]): string | null`; `VenueClub = { slug: string; name: string }` from `federation.ts`.
- Produces:
  - `export type TeamUpsert = { site_slug: string; site_team_id: number | null; site_name: string; competition_slug: string; competition_name: string; name: string; club_slug: string }`. `club_slug` replaces `club_id`.
  - `export type OurClub = { id: string; name: string; site_slug: string | null }`.
  - `export type ClubPlan = { slug: string; name: string; match_id: string | null }`.
  - `export function planClubs(clubs: VenueClub[], ours: OurClub[]): ClubPlan[]`.
  - `export function planTeams(args: { clubs: VenueClub[]; competitions: { slug: string; competition: SiteCompetition }[]; existingNames: string[] }): TeamUpsert[]`. The `ourClubs` argument is gone.
  - `runDiscover(db, get, tenantId)` resolves to `{ teams: number; competitions: number; created: number; clubs_created: string[]; clubs_linked: string[] }`, which `record_federation_run` stores as `last_report.discover`.

- [ ] **Step 1: Write the failing tests**

In `supabase/functions/_shared/federation_jobs_test.ts`, replace the import:
```ts
import {
  jobOutcome, matchJobsFor, planCompetition, planTeams,
  processFederationJobs, runCompetition, runDiscover, SITE,
} from "./federation_jobs.ts";
```
with:
```ts
import {
  jobOutcome, matchJobsFor, planClubs, planCompetition, planTeams,
  processFederationJobs, runCompetition, runDiscover, SITE,
} from "./federation_jobs.ts";
```

Replace the whole `planTeams` test:
```ts
Deno.test("planTeams: teams of venue clubs, names reused, clubs matched", () => {
  const teamsOut = planTeams({
    clubs: [{ slug: "tj-sokol-brno-iv", name: "TJ Sokol Brno IV" },
      { slug: "tj-sokol-husovice", name: "TJ Sokol Husovice" }],
    competitions: [{
      slug: "jihomoravska-divize-2026-2027",
      competition: { name: "Jihomoravská divize", roundIds: [1], currentRound: 1,
        matches: [match({ id: 1 })],
        standings: [
          { teamSlug: "tj-sokol-brno-iv-muzi", teamName: "TJ Sokol Brno IV" },
          { teamSlug: "tj-sokol-husovice-b-muzi", teamName: "TJ Sokol Husovice B" },
          { teamSlug: "kc-zlin-b-muzi", teamName: "KC Zlín B" },
        ] },
    }],
    existingNames: ["TJ Sokol Brno IV A", "KC Zlín B"],
    ourClubs: [{ id: "c1", name: "Sokol Brno IV" }, { id: "c2", name: "Veverky" }],
  });
  assertEquals(teamsOut, [
    { site_slug: "tj-sokol-brno-iv-muzi", site_team_id: 1, site_name: "TJ Sokol Brno IV",
      competition_slug: "jihomoravska-divize-2026-2027", competition_name: "Jihomoravská divize",
      name: "TJ Sokol Brno IV A", club_id: "c1" },
    { site_slug: "tj-sokol-husovice-b-muzi", site_team_id: null, site_name: "TJ Sokol Husovice B",
      competition_slug: "jihomoravska-divize-2026-2027", competition_name: "Jihomoravská divize",
      name: "TJ Sokol Husovice B", club_id: null },
  ]);
});
```
with:
```ts
Deno.test("planTeams: teams of venue clubs with their venue club, names reused", () => {
  const teamsOut = planTeams({
    clubs: [{ slug: "tj-sokol-brno-iv", name: "TJ Sokol Brno IV" },
      { slug: "tj-sokol-husovice", name: "TJ Sokol Husovice" }],
    competitions: [{
      slug: "jihomoravska-divize-2026-2027",
      competition: { name: "Jihomoravská divize", roundIds: [1], currentRound: 1,
        matches: [match({ id: 1 })],
        standings: [
          { teamSlug: "tj-sokol-brno-iv-muzi", teamName: "TJ Sokol Brno IV" },
          { teamSlug: "tj-sokol-husovice-b-muzi", teamName: "TJ Sokol Husovice B" },
          { teamSlug: "kc-zlin-b-muzi", teamName: "KC Zlín B" },
        ] },
    }],
    existingNames: ["TJ Sokol Brno IV A", "KC Zlín B"],
  });
  assertEquals(teamsOut, [
    { site_slug: "tj-sokol-brno-iv-muzi", site_team_id: 1, site_name: "TJ Sokol Brno IV",
      competition_slug: "jihomoravska-divize-2026-2027", competition_name: "Jihomoravská divize",
      name: "TJ Sokol Brno IV A", club_slug: "tj-sokol-brno-iv" },
    { site_slug: "tj-sokol-husovice-b-muzi", site_team_id: null, site_name: "TJ Sokol Husovice B",
      competition_slug: "jihomoravska-divize-2026-2027", competition_name: "Jihomoravská divize",
      name: "TJ Sokol Husovice B", club_slug: "tj-sokol-husovice" },
  ]);
});

Deno.test("planClubs: a renamed club by its slug, else one unlinked club by name, else none", () => {
  const venue = [
    { slug: "tj-sokol-brno-iv", name: "TJ Sokol Brno IV" },
    { slug: "tj-sokol-husovice", name: "TJ Sokol Husovice" },
    { slug: "ks-devitka-brno", name: "KS Devítka Brno" },
    { slug: "skk-veverky-brno", name: "SKK Veverky Brno" },
  ];
  const ours = [
    { id: "c1", name: "Sokol Brno IV", site_slug: null },
    // Renamed in the app after a discovery linked it: its slug still wins,
    // even over an unlinked club with the site's very name.
    { id: "c2", name: "Devítka", site_slug: "ks-devitka-brno" },
    { id: "c4", name: "KS Devítka Brno", site_slug: null },
    { id: "c3", name: "Veverky", site_slug: null },
  ];
  assertEquals(planClubs(venue, ours), [
    { slug: "tj-sokol-brno-iv", name: "TJ Sokol Brno IV", match_id: "c1" },
    { slug: "tj-sokol-husovice", name: "TJ Sokol Husovice", match_id: null },
    { slug: "ks-devitka-brno", name: "KS Devítka Brno", match_id: "c2" },
    { slug: "skk-veverky-brno", name: "SKK Veverky Brno", match_id: "c3" },
  ]);
  // A club linked to another venue club is never matched by name.
  assertEquals(
    planClubs([{ slug: "tj-sokol-brno-iv-b", name: "Sokol Brno IV" }],
      [{ id: "c1", name: "Sokol Brno IV", site_slug: "tj-sokol-brno-iv" }]),
    [{ slug: "tj-sokol-brno-iv-b", name: "Sokol Brno IV", match_id: null }],
  );
});
```

Replace `fakeDiscoverDb`:
```ts
/** The reads and the RPC runDiscover issues. */
function fakeDiscoverDb(sync: { venue_slug: string | null } | null) {
  const rpcs: { name: string; args: Record<string, unknown> }[] = [];
  const db = {
    from(table: string) {
      // deno-lint-ignore no-explicit-any
      const chain: any = {
        select() {
          return chain;
        },
        eq() {
          return chain;
        },
        not() {
          return chain;
        },
        maybeSingle() {
          return Promise.resolve({ data: table === "federation_sync" ? sync : null, error: null });
        },
        then(onFulfilled: (v: unknown) => unknown) {
          const data = table === "clubs"
            ? [{ id: "c1", name: "Sokol Brno IV" }]
            : table === "priority_slots"
            ? [{ home_team: "TJ Sokol Brno IV A", away_team: "KK Blansko" }]
            : [];
          return Promise.resolve({ data, error: null }).then(onFulfilled);
        },
      };
      return chain;
    },
    async rpc(name: string, args: Record<string, unknown>) {
      rpcs.push({ name, args });
      return { data: 1, error: null };
    },
  };
  return { db, rpcs };
}
```
with:
```ts
/** The reads and the RPC runDiscover issues. `clubs`: the alley's clubs;
 * `result`: what apply_federation_discovery answers. */
function fakeDiscoverDb(
  sync: { venue_slug: string | null } | null,
  clubs: { id: string; name: string; site_slug: string | null }[] =
    [{ id: "c1", name: "Sokol Brno IV", site_slug: null }],
  result: unknown = {
    created: 1, clubs_linked: ["Sokol Brno IV"],
    clubs_created: ["TJ Sokol Husovice", "KS Devítka Brno", "SKK Veverky Brno"],
  },
) {
  const rpcs: { name: string; args: Record<string, unknown> }[] = [];
  const db = {
    from(table: string) {
      // deno-lint-ignore no-explicit-any
      const chain: any = {
        select() {
          return chain;
        },
        eq() {
          return chain;
        },
        not() {
          return chain;
        },
        maybeSingle() {
          return Promise.resolve({ data: table === "federation_sync" ? sync : null, error: null });
        },
        then(onFulfilled: (v: unknown) => unknown) {
          const data = table === "clubs"
            ? clubs
            : table === "priority_slots"
            ? [{ home_team: "TJ Sokol Brno IV A", away_team: "KK Blansko" }]
            : [];
          return Promise.resolve({ data, error: null }).then(onFulfilled);
        },
      };
      return chain;
    },
    async rpc(name: string, args: Record<string, unknown>) {
      rpcs.push({ name, args });
      return { data: result, error: null };
    },
  };
  return { db, rpcs };
}
```

In the test `runDiscover: venue clubs → season sitemap → competitions → teams`, replace its assertions:
```ts
  assertEquals(rpcs.map((r) => r.name), ["upsert_federation_teams"]);
  assertEquals(rpcs[0].args, {
    p_tenant: "t1",
    p_teams: [{
      site_slug: "tj-sokol-brno-iv-muzi", site_team_id: 243, site_name: "TJ Sokol Brno IV",
      competition_slug: "jihomoravska-divize-2026-2027", competition_name: "Jihomoravská divize",
      name: "TJ Sokol Brno IV A", club_id: "c1",
    }],
  });
  assertEquals(report, { teams: 1, created: 1 });
});
```
with:
```ts
  assertEquals(rpcs.map((r) => r.name), ["apply_federation_discovery"]);
  assertEquals(rpcs[0].args, {
    p_tenant: "t1",
    p_clubs: [
      { slug: "tj-sokol-brno-iv", name: "TJ Sokol Brno IV", match_id: "c1" },
      { slug: "tj-sokol-husovice", name: "TJ Sokol Husovice", match_id: null },
      { slug: "ks-devitka-brno", name: "KS Devítka Brno", match_id: null },
      { slug: "skk-veverky-brno", name: "SKK Veverky Brno", match_id: null },
    ],
    p_teams: [{
      site_slug: "tj-sokol-brno-iv-muzi", site_team_id: 243, site_name: "TJ Sokol Brno IV",
      competition_slug: "jihomoravska-divize-2026-2027", competition_name: "Jihomoravská divize",
      name: "TJ Sokol Brno IV A", club_slug: "tj-sokol-brno-iv",
    }],
  });
  assertEquals(report, {
    teams: 1, competitions: 1, created: 1, clubs_linked: ["Sokol Brno IV"],
    clubs_created: ["TJ Sokol Husovice", "KS Devítka Brno", "SKK Veverky Brno"],
  });
});

Deno.test("runDiscover: a renamed club by its slug, a club by its name, a missing one to create", async () => {
  const prebor = "krajsky-prebor-jmk-2-tridy-sever-a-2026-2027";
  const sitemap = matchesSitemap.replace("</urlset>",
    `<url><loc>${SITE}/detail-zapasu/${prebor}-kolo-1-ks-devitka-brno-b-muzi-kk-slovan-rosice-d-muzi</loc></url></urlset>`);
  const ours = [
    { id: "c1", name: "Sokol Brno IV", site_slug: null },
    { id: "c2", name: "Devítka", site_slug: "ks-devitka-brno" },
    { id: "c3", name: "Veverky", site_slug: null },
  ];
  const { db, rpcs } = fakeDiscoverDb({ venue_slug: "tj-sokol-brno-iv" }, ours, {
    created: 5, clubs_created: ["TJ Sokol Husovice"],
    clubs_linked: ["Sokol Brno IV", "Devítka", "Veverky"],
  });
  const { get } = discoverSite({
    "/sitemap/matches-20.xml": sitemap,
    [`/detail-souteze/${prebor}`]: fixture("competition_current_teams_of_4.html"),
  });

  const report = await runDiscover(db, get, "t1");

  assertEquals(rpcs.map((r) => r.name), ["apply_federation_discovery"]);
  assertEquals(rpcs[0].args.p_clubs, [
    { slug: "tj-sokol-brno-iv", name: "TJ Sokol Brno IV", match_id: "c1" },
    { slug: "tj-sokol-husovice", name: "TJ Sokol Husovice", match_id: null },
    { slug: "ks-devitka-brno", name: "KS Devítka Brno", match_id: "c2" },
    { slug: "skk-veverky-brno", name: "SKK Veverky Brno", match_id: "c3" },
  ]);
  const teams = rpcs[0].args.p_teams as { site_slug: string; club_slug: string }[];
  assertEquals(teams.map((t) => [t.site_slug, t.club_slug]), [
    ["tj-sokol-brno-iv-muzi", "tj-sokol-brno-iv"],
    ["skk-veverky-brno-b-muzi", "skk-veverky-brno"],
    ["tj-sokol-husovice-e-muzi", "tj-sokol-husovice"],
    ["tj-sokol-brno-iv-b-muzi", "tj-sokol-brno-iv"],
    ["ks-devitka-brno-b-muzi", "ks-devitka-brno"],
  ]);
  assertEquals(report, {
    teams: 5, competitions: 2, created: 5, clubs_created: ["TJ Sokol Husovice"],
    clubs_linked: ["Sokol Brno IV", "Devítka", "Veverky"],
  });
});
```

- [ ] **Step 2: Run them to verify they fail**

Run: `deno test --allow-read supabase/functions`
Expected: FAIL at type-check — `TS2305 [ERROR]: Module '"…/federation_jobs.ts"' has no exported member 'planClubs'.` (plus `TS2353 … 'club_slug' does not exist in type 'TeamUpsert'`).

- [ ] **Step 3: Implement**

In `supabase/functions/_shared/federation_jobs.ts`:

Replace:
```ts
export type TeamUpsert = {
  site_slug: string; site_team_id: number | null; site_name: string;
  competition_slug: string; competition_name: string; name: string; club_id: string | null;
};
```
with:
```ts
/** `club_slug`: the venue club the team plays for (`/detail-klubu/<slug>`);
 * apply_federation_discovery (0047) turns it into the club of ours it links
 * or creates. */
export type TeamUpsert = {
  site_slug: string; site_team_id: number | null; site_name: string;
  competition_slug: string; competition_name: string; name: string; club_slug: string;
};
/** A club of ours as discovery reads it; `site_slug` is the venue club it
 * is linked to (0047), null until a discovery links it. */
export type OurClub = { id: string; name: string; site_slug: string | null };
/** One venue club for apply_federation_discovery: `match_id` is the club of
 * ours linked to its slug, else the one unlinked club its name matches,
 * else null (the database creates the club). */
export type ClubPlan = { slug: string; name: string; match_id: string | null };
```

Replace:
```ts
export function planTeams(args: {
  clubs: VenueClub[];
  competitions: { slug: string; competition: SiteCompetition }[];
  existingNames: string[];
  ourClubs: { id: string; name: string }[];
}): TeamUpsert[] {
```
with:
```ts
export function planTeams(args: {
  clubs: VenueClub[];
  competitions: { slug: string; competition: SiteCompetition }[];
  existingNames: string[];
}): TeamUpsert[] {
```

Replace (the end of `planTeams`):
```ts
        club_id: clubIdFor(club, args.ourClubs),
      });
    }
  }
  return [...out.values()];
}
```
with:
```ts
        club_slug: club.slug,
      });
    }
  }
  return [...out.values()];
}

/** Every venue club with the club of ours it is: the one linked to its slug
 * (whatever the admin renamed it to), else the one unlinked club its name
 * matches ([clubIdFor]), else none — apply_federation_discovery creates it.
 * A club linked to another venue club is never matched by name. */
export function planClubs(clubs: VenueClub[], ours: OurClub[]): ClubPlan[] {
  const unlinked = ours.filter((c) => c.site_slug === null);
  return clubs.map((c) => ({
    slug: c.slug, name: c.name,
    match_id: ours.find((o) => o.site_slug === c.slug)?.id ?? clubIdFor(c, unlinked),
  }));
}
```

In `runDiscover`, replace:
```ts
  const ourClubs = must(await db.from("clubs").select("id, name").eq("tenant_id", tenantId)) as
    { id: string; name: string }[];
  const teams = planTeams({
    clubs, competitions, ourClubs,
    existingNames: [...new Set(slots.flatMap((s) => [s.home_team, s.away_team]))],
  });
  const created = must(await db.rpc("upsert_federation_teams", { p_tenant: tenantId, p_teams: teams }));
  return { teams: teams.length, created };
}
```
with:
```ts
  const ourClubs = must(await db.from("clubs").select("id, name, site_slug")
    .eq("tenant_id", tenantId)) as OurClub[];
  const teams = planTeams({
    clubs, competitions,
    existingNames: [...new Set(slots.flatMap((s) => [s.home_team, s.away_team]))],
  });
  // One transaction (0047): the venue's clubs linked or created, then the
  // teams with their clubs.
  const applied = must(await db.rpc("apply_federation_discovery", {
    p_tenant: tenantId, p_clubs: planClubs(clubs, ourClubs), p_teams: teams,
  })) as { created: number; clubs_created: string[]; clubs_linked: string[] };
  return {
    teams: teams.length,
    competitions: new Set(teams.map((t) => t.competition_slug)).size,
    created: applied.created,
    clubs_created: applied.clubs_created,
    clubs_linked: applied.clubs_linked,
  };
}
```

- [ ] **Step 4: Run them to verify they pass**

Run: `deno test --allow-read supabase/functions`
Expected: `ok | … passed | 0 failed` (two more tests than before).

Run: `deno check --import-map supabase/functions/import_map.json supabase/functions/notify/index.ts`
Expected: `Check supabase/functions/notify/index.ts` and no error.

- [ ] **Step 5: Commit**

```bash
git add supabase/functions/_shared/federation_jobs.ts supabase/functions/_shared/federation_jobs_test.ts
git commit -m "$(cat <<'EOF'
feat(federation): discovery matches venue clubs by slug, then name, and lets the database link or create them

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 3: Discovery is no sync run, a moved kuželna drops its report; federation_sync_progress (SQL)

**Files:**
- Modify: `supabase/migrations/0047_federation_setup.sql` (append)
- Modify: `supabase/tests/tenancy_rls.sql` (sections 13 and 13b; new sections 17 and 18)
- Modify: `supabase/functions/_shared/federation_jobs.ts` (a comment on `LEASE_MS`)
- Modify: `supabase/schema.sql` (regenerated), `docs/SCHEMA.md`
- Test: `supabase/tests/tenancy_rls.sql`

**Interfaces:**
- Consumes: 0045 `record_federation_run(uuid, text, jsonb, text)`, `set_federation_sync(text, boolean)`, `federation_live_report(uuid, jsonb)`, `federation_last_error(uuid, jsonb)`, `federation_refresh_error(uuid)`, `notification_jobs(kind, dedupe_key, run_at, attempts)`, `current_tenant_id()`, `is_admin()`. Dedupe keys: `federation_discover:<tenant>`, `federation_competition:<tenant>:<slug>`, `federation_match:<tenant>:<id>`, `federation_venue:<tenant>:<slug>`. `LEASE_MS = 10 * 60e3` in `federation_jobs.ts`.
- Produces:
  - `federation_sync_progress() returns jsonb` → `{"discover": int, "competitions": int, "matches": int, "venues": int}`. It is granted to authenticated and raises `not_allowed` for non-admins.
  - `record_federation_run`: only `competition:%` keys stamp `last_run_at`/`last_success_at`. `discover` keeps `{report…, at}` or `{error, at}`.
  - `set_federation_sync(p_venue_slug text, p_enabled boolean) returns void`, same signature and grants: a changed `venue_slug` also drops `last_report.discover`, which was the old kuželna's (plan decision 14). Saving the same slug keeps it.

- [ ] **Step 1: Write the failing tests**

In section 13 of `supabase/tests/tenancy_rls.sql` replace:
```sql
  perform record_federation_run(v_b, 'discover', '{"teams":3}', null);
  select * into s from federation_sync where tenant_id = v_b;
  if s.last_success_at is null or s.last_error is not null
     or s.last_report->'discover'->>'teams' <> '3'
     or s.last_report->'discover'->>'at' is null then
    raise exception 'FAIL: a successful run was not recorded: %', to_jsonb(s);
  end if;
  perform record_federation_run(v_b, 'competition:krajsky-prebor-2026-2027', '{"inserted":1}', null);
  update federation_sync set last_success_at = now() - interval '1 hour' where tenant_id = v_b;
  perform record_federation_run(v_b, 'discover', '{"teams":0}', 'site down');
  select * into s from federation_sync where tenant_id = v_b;
  if s.last_error <> 'site down' or s.last_success_at <> now() - interval '1 hour'
```
with:
```sql
  perform record_federation_run(v_b, 'discover', '{"teams":3}', null);
  select * into s from federation_sync where tenant_id = v_b;
  -- 0047: a discovery keeps its report but is no sync run.
  if s.last_run_at is not null or s.last_success_at is not null or s.last_error is not null
     or s.last_report->'discover'->>'teams' <> '3'
     or s.last_report->'discover'->>'at' is null then
    raise exception 'FAIL: a discovery should keep its report without stamping a run: %', to_jsonb(s);
  end if;
  perform record_federation_run(v_b, 'competition:krajsky-prebor-2026-2027', '{"inserted":1}', null);
  update federation_sync
     set last_run_at = now() - interval '1 hour', last_success_at = now() - interval '1 hour'
   where tenant_id = v_b;
  perform record_federation_run(v_b, 'discover', '{"teams":0}', 'site down');
  select * into s from federation_sync where tenant_id = v_b;
  if s.last_error <> 'site down' or s.last_success_at <> now() - interval '1 hour'
     or s.last_run_at <> now() - interval '1 hour'
```

In section 13b replace its whole leading comment (six lines; the second line runs on past `last_success_at.`):
```sql
-- 13b. Only discovery and competition runs are the sync's runs: they
-- stamp last_run_at and last_success_at. A match or venue job reports
-- only trouble, under its own key (match:<site_match_id>, venue:<slug>):
-- a failure is written there, a success removes just that entry, and a
-- success with nothing to remove writes nothing — no row, no update, so no
-- Realtime event for every fetched match.
```
with:
```sql
-- 13b. Only competition runs are the sync's runs (discovery was one too
-- until 0047): they stamp last_run_at and last_success_at. A match or
-- venue job reports only trouble, under its own key (match:<site_match_id>,
-- venue:<slug>): a failure is written there, a success removes just that
-- entry, and a success with nothing to remove writes nothing — no row, no
-- update, so no Realtime event for every fetched match.
```
and its notice:
```sql
  raise notice 'OK: only discovery and competitions stamp a run; a match or venue success removes its own key or writes nothing (0045)';
```
with:
```sql
  raise notice 'OK: only competitions stamp a run; a match or venue success removes its own key or writes nothing (0045, 0047)';
```

At the end of the file replace:
```sql
  raise notice 'OK: apply_federation_discovery is callable by the service only (0047)';
end $$;

reset role;
rollback;
```
with:
```sql
  raise notice 'OK: apply_federation_discovery is callable by the service only (0047)';
end $$;

-- 17. federation_sync_progress: the caller's federation jobs due now or
-- leased, per kind — never a future checkpoint, never another alley's —
-- and for admins only.
do $$
declare
  v_a constant text := '00000000-0000-0000-0000-00000000000a';
  v_b constant text := '00000000-0000-0000-0000-000000000002';
begin
  delete from notification_jobs
   where kind in ('federation_discover', 'federation_competition',
                  'federation_match', 'federation_venue');
  insert into notification_jobs (kind, dedupe_key, payload, run_at, attempts) values
    -- due
    ('federation_discover', 'federation_discover:' || v_a, '{}', now() - interval '1 minute', 0),
    ('federation_competition', 'federation_competition:' || v_a || ':okresni-prebor', '{}', now(), 0),
    ('federation_venue', 'federation_venue:' || v_a || ':kuzelna-a', '{}', now(), 0),
    -- leased: the lease pushed run_at ahead and counted an attempt
    ('federation_match', 'federation_match:' || v_a || ':1', '{}', now() + interval '9 minutes', 1),
    -- not yet due, never leased: a spaced nightly job, a match's checkpoint
    ('federation_competition', 'federation_competition:' || v_a || ':krajsky-prebor', '{}',
     now() + interval '1 minute', 0),
    ('federation_match', 'federation_match:' || v_a || ':2', '{}', now() + interval '1 day', 0),
    -- a retry backing off past the lease window
    ('federation_match', 'federation_match:' || v_a || ':3', '{}', now() + interval '32 minutes', 5),
    -- another alley's, and a job that is no federation job
    ('federation_match', 'federation_match:' || v_b || ':9', '{}', now(), 0),
    ('calendar_sync', 'calendar:' || v_a || ':progress-probe', '{}', now(), 0);
end $$;
set local role authenticated;
set local request.jwt.claims =
  '{"sub":"10000000-0000-0000-0000-000000000001","role":"authenticated"}';
do $$
declare
  v constant jsonb := federation_sync_progress();
begin
  if v is distinct from '{"discover":1,"competitions":1,"matches":1,"venues":1}'::jsonb then
    raise exception 'FAIL: progress should count the alley''s due and leased jobs only: %', v;
  end if;
end $$;
reset role;
set local role authenticated;
set local request.jwt.claims =
  '{"sub":"10000000-0000-0000-0000-000000000002","role":"authenticated"}';
do $$
declare
  v constant jsonb := federation_sync_progress();
begin
  if v is distinct from '{"discover":0,"competitions":0,"matches":1,"venues":0}'::jsonb then
    raise exception 'FAIL: another alley''s admin got our progress: %', v;
  end if;
end $$;
reset role;
set local role authenticated;
set local request.jwt.claims =
  '{"sub":"20000000-0000-0000-0000-000000000001","role":"authenticated"}';
do $$
begin
  begin
    perform federation_sync_progress();
    raise exception 'FAIL: a player read the sync progress';
  exception when others then
    if sqlerrm <> 'not_allowed' then raise; end if;
  end;
end $$;
reset role;
do $$
begin
  if has_function_privilege('anon', 'public.federation_sync_progress()', 'execute')
     or not has_function_privilege('authenticated', 'public.federation_sync_progress()', 'execute') then
    raise exception 'FAIL: federation_sync_progress must be callable by the app only';
  end if;
  raise notice 'OK: federation_sync_progress counts the alley''s due and leased jobs, for admins only (0047)';
end $$;

-- 18. A moved kuželna drops the last discovery's report: it was the old
-- kuželna's, and the setup wizard reads a successful report as "this
-- kuželna's teams are loaded". Saving the same kuželna keeps it. B is not
-- enabled; its kuželna goes back at the end.
do $$
begin
  perform record_federation_run('00000000-0000-0000-0000-000000000002', 'discover',
                                '{"teams":2}', null);
end $$;
set local role authenticated;
set local request.jwt.claims =
  '{"sub":"10000000-0000-0000-0000-000000000002","role":"authenticated"}';
do $$
declare
  v_slug constant text := (select venue_slug from federation_sync);
begin
  perform set_federation_sync(v_slug, false);
  if not (select last_report ? 'discover' from federation_sync) then
    raise exception 'FAIL: saving the same kuželna dropped its discovery report';
  end if;
  perform set_federation_sync('kuzelna-b-jinde', false);
  if (select last_report ? 'discover' from federation_sync) then
    raise exception 'FAIL: a moved kuželna kept the old one''s discovery report';
  end if;
  perform set_federation_sync(v_slug, false);
  raise notice 'OK: a moved kuželna drops the last discovery''s report; the same one keeps it (0047)';
end $$;

reset role;
rollback;
```

- [ ] **Step 2: Run them to verify they fail**

Run: `psql "$(supabase status -o env | sed -n 's/^DB_URL="\(.*\)"/\1/p')" -X -v ON_ERROR_STOP=1 -f supabase/tests/tenancy_rls.sql 2>&1 | grep -E 'ERROR|FAIL'`
Expected: `ERROR:  FAIL: a discovery should keep its report without stamping a run: {…}`

- [ ] **Step 3: Implement**

Append to `supabase/migrations/0047_federation_setup.sql`:

```sql

-- ------------------------------------------------ discovery is no run
-- 0045's record_federation_run, except that only competition:<slug> runs
-- are the sync's runs and stamp last_run_at / last_success_at. discover
-- still keeps its report + at, or {error, at}, under its key. The setup
-- wizard reads "never synced" as last_run_at is null, and its own
-- discovery (step 2) must not end it.
create or replace function record_federation_run(
  p_tenant uuid, p_key text, p_report jsonb, p_error text)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_run constant boolean := p_key like 'competition:%';
  v_keep constant boolean := v_run or p_key = 'discover';
  v_report jsonb;
begin
  select last_report into v_report from federation_sync
   where tenant_id = p_tenant for update;
  if p_error is null and not v_keep and not coalesce(v_report ? p_key, false) then
    return;
  end if;
  if v_report is null then
    insert into federation_sync (tenant_id) values (p_tenant) on conflict do nothing;
    select last_report into v_report from federation_sync
     where tenant_id = p_tenant for update;
  end if;
  v_report := case
    when p_error is not null then v_report || jsonb_build_object(p_key,
      jsonb_build_object('error', p_error, 'at', now()))
    when v_keep then v_report || jsonb_build_object(p_key,
      coalesce(p_report, '{}'::jsonb) || jsonb_build_object('at', now()))
    else v_report - p_key end;
  v_report := federation_live_report(p_tenant, v_report);
  update federation_sync
     set last_run_at = case when v_run then now() else last_run_at end,
         last_success_at = case when v_run and p_error is null then now()
                                else last_success_at end,
         last_report = v_report,
         last_error = federation_last_error(p_tenant, v_report)
   where tenant_id = p_tenant;
end;
$$;

-- ----------------------------------------------------- sync progress
-- The admin card's „Synchronizuje se… zbývá …“: the caller's federation
-- jobs due now or leased, per kind. The notify tick's lease counts an
-- attempt and pushes run_at up to 10 minutes ahead (LEASE_MS in
-- federation_jobs.ts), so attempts > 0 with run_at inside that window is a
-- job in flight (or retrying within it). A run that finishes deletes its
-- job or re-arms it with attempts 0, so a match's future checkpoint
-- (T−24 h, T+24 h …) never counts. The tenant is the dedupe key's second
-- part: federation_discover:<tenant>, federation_competition:<tenant>:<slug>,
-- federation_match:<tenant>:<id>, federation_venue:<tenant>:<slug>.
create or replace function federation_sync_progress()
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  v_tenant constant uuid := current_tenant_id();
  v jsonb;
begin
  if not is_admin() then
    raise exception 'not_allowed';
  end if;
  select jsonb_build_object(
           'discover', count(*) filter (where kind = 'federation_discover'),
           'competitions', count(*) filter (where kind = 'federation_competition'),
           'matches', count(*) filter (where kind = 'federation_match'),
           'venues', count(*) filter (where kind = 'federation_venue'))
    into v
    from notification_jobs
   where kind in ('federation_discover', 'federation_competition',
                  'federation_match', 'federation_venue')
     and split_part(dedupe_key, ':', 2) = v_tenant::text
     and (run_at <= now()
          or (attempts > 0 and run_at <= now() + interval '10 minutes'));
  return v;
end;
$$;

revoke all on function federation_sync_progress() from public, anon;
grant execute on function federation_sync_progress() to authenticated;

-- ------------------------------------------ a moved kuželna's discovery
-- 0045's set_federation_sync, except that moving the alley to another
-- kuželna also drops the last discovery's report (last_report.discover):
-- it was the old kuželna's. The setup wizard opens step 3 only on a
-- successful report, so the old kuželna's teams never get it there.
-- Saving the same slug (the switch, step 3) keeps the report. create or
-- replace keeps 0045's grants.
create or replace function set_federation_sync(p_venue_slug text, p_enabled boolean)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_slug text := lower(trim(coalesce(p_venue_slug, '')));
begin
  if not is_admin() then
    raise exception 'not_allowed';
  end if;
  if v_slug !~ '^[a-z0-9]+(-[a-z0-9]+)*$' then
    raise exception 'invalid_venue_slug';
  end if;
  insert into federation_sync (tenant_id, venue_slug, enabled)
  values (current_tenant_id(), v_slug, p_enabled)
  on conflict (tenant_id) do update
    set venue_slug = excluded.venue_slug, enabled = excluded.enabled,
        last_report = case
          when federation_sync.venue_slug = excluded.venue_slug
            then federation_sync.last_report
          else federation_sync.last_report - 'discover' end;
  -- A moved kuželna leaves the old one's venue key dead, and its
  -- discovery's error with the report.
  perform federation_refresh_error(current_tenant_id());
end;
$$;
```

In `supabase/functions/_shared/federation_jobs.ts` replace:
```ts
const MAX_ATTEMPTS = 5;
const LEASE_MS = 10 * 60e3;
```
with:
```ts
const MAX_ATTEMPTS = 5;
// federation_sync_progress (0047) counts a job with attempts > 0 and run_at
// within this lease as in flight — keep the two in step.
const LEASE_MS = 10 * 60e3;
```

- [ ] **Step 4: Apply it (0047 is already recorded locally, so through psql), twice**

Run: `for i in 1 2; do psql "$(supabase status -o env | sed -n 's/^DB_URL="\(.*\)"/\1/p')" -X -v ON_ERROR_STOP=1 -q -f supabase/migrations/0047_federation_setup.sql || echo FAILED; done`
Expected: only `NOTICE … already exists, skipping` lines, no `FAILED`.

- [ ] **Step 5: Run the tests to verify they pass**

Run: `psql "$(supabase status -o env | sed -n 's/^DB_URL="\(.*\)"/\1/p')" -X -v ON_ERROR_STOP=1 -f supabase/tests/tenancy_rls.sql 2>&1 | grep -E 'ERROR|FAIL|0047\)'`
Expected: no `ERROR`/`FAIL`; the four Task 1 lines plus
```
NOTICE:  OK: only competitions stamp a run; a match or venue success removes its own key or writes nothing (0045, 0047)
NOTICE:  OK: federation_sync_progress counts the alley's due and leased jobs, for admins only (0047)
NOTICE:  OK: a moved kuželna drops the last discovery's report; the same one keeps it (0047)
```

Run: `deno check --import-map supabase/functions/import_map.json supabase/functions/notify/index.ts`
Expected: no error.

- [ ] **Step 6: Document it in `docs/SCHEMA.md`**

In the `federation_sync` row replace:
```
`last_success_at` (stamped only by `discover` and `competition:<slug>` runs — the nightly sync's; match and venue jobs never touch them)
```
with:
```
`last_success_at` (stamped only by `competition:<slug>` runs — the nightly sync's; since 0047 not by `discover`, so `last_run_at` null means never synced, which the setup wizard reads; match and venue jobs never touch them)
```

In the `set_federation_sync(venue_slug, enabled)` (0045) row replace:
```
drops the old kuželna's `venue:` key when no match of the alley is there either, re-deriving `last_error`.
```
with:
```
drops the old kuželna's `venue:` key when no match of the alley is there either, re-deriving `last_error`. Since 0047 a changed slug also drops `last_report.discover`, which was the old kuželna's, so the setup wizard never offers step 3 for its teams.
```

After the `request_federation_discovery()`, `request_federation_sync()` (0045) row, add the row:
```
| `federation_sync_progress()` (0047) | admin | The caller's federation jobs due now (`run_at <= now()`) or leased (`attempts > 0` and `run_at` within the notify tick's 10-minute lease), per kind → `{discover, competitions, matches, venues}`; a match's future checkpoint never counts. The ČKA card polls it. `not_allowed`. |
```

In **Runs** replace:
```
  - `discover` and `competition:<slug>` are the sync's runs: they stamp
    `last_run_at`, a success also `last_success_at` (the card's „Poslední
    synchronizace“) and merges `{key: report + at}`, a failure merges
    `{key: {error, at}}` — the key's entry is whatever happened last.
```
with:
```
  - `discover` and `competition:<slug>` keep their last run: a success
    merges `{key: report + at}`, a failure `{key: {error, at}}` — the
    key's entry is whatever happened last. Only `competition:<slug>` runs
    are the sync's runs (0047; `discover` was one too until then): they
    stamp `last_run_at`, a success also `last_success_at` (the card's
    „Poslední synchronizace“).
```

- [ ] **Step 7: Regenerate the schema snapshot and re-run the test on the rebuilt DB**

Run: `tool/schema_snapshot.sh && git diff --stat supabase/schema.sql`
Expected: `supabase/schema.sql regenerated`; the diff touches `record_federation_run` and `set_federation_sync`, and adds `federation_sync_progress`.

Run: `psql "$(supabase status -o env | sed -n 's/^DB_URL="\(.*\)"/\1/p')" -X -v ON_ERROR_STOP=1 -q -f supabase/tests/tenancy_rls.sql > /dev/null 2>&1; echo "exit $?"`
Expected: `exit 0`.

- [ ] **Step 8: Commit**

```bash
git add supabase/migrations/0047_federation_setup.sql supabase/tests/tenancy_rls.sql supabase/functions/_shared/federation_jobs.ts supabase/schema.sql docs/SCHEMA.md
git commit -m "$(cat <<'EOF'
feat(federation): federation_sync_progress for the ČKA card; discovery is no sync run, and a moved kuželna drops its report

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 4: App models and API (Dart)

**Files:**
- Modify: `lib/domain/models.dart` (`Club`, `FederationSync`; new `FederationDiscoverReport`, `FederationSyncProgress`)
- Modify: `lib/data/providers.dart` (`Api.federationSyncProgress`)
- Test: `test/domain/team_test.dart`, `test/domain/models_test.dart`

**Interfaces:**
- Consumes: Task 1 columns `clubs.site_slug`/`site_name`; Task 2 report `last_report.discover` = `{teams, competitions, created, clubs_created, clubs_linked, at}` or `{error, at}`; Task 3 RPC `federation_sync_progress()`.
- Produces:
  - `Club({required String id, required String name, int colorIndex = -1, String? siteSlug, String? siteName})`, with `bool get linked`.
  - `FederationSync({…, FederationDiscoverReport? discover})`. `fromJson` reads `last_report.discover`.
  - `FederationDiscoverReport({int teams = 0, int competitions = 0, int created = 0, List<String> clubsCreated = const [], List<String> clubsLinked = const [], DateTime? at, String? error})`, with `bool get failed` and `fromJson`.
  - `FederationSyncProgress({int discover = 0, int competitions = 0, int matches = 0, int venues = 0})`, with `static const idle`, `bool get pending`, `fromJson`, `==`/`hashCode`.
  - `Api.federationSyncProgress() → Future<FederationSyncProgress>`.

- [ ] **Step 1: Write the failing tests**

In `test/domain/team_test.dart` replace the file's end:
```dart
    expect(s.lastError, 'competition: HTTP 500');
  });
}
```
with:
```dart
    expect(s.lastError, 'competition: HTTP 500');
  });

  test('FederationSync.fromJson reads the last discovery report (0047)', () {
    final s = FederationSync.fromJson({
      'venue_slug': 'tj-sokol-brno-iv',
      'last_report': {
        'discover': {
          'teams': 5, 'competitions': 2, 'created': 5,
          'clubs_created': ['KS Devítka Brno'],
          'clubs_linked': ['Sokol Brno IV', 'Veverky'],
          'at': '2026-09-25T08:00:00+00:00',
        },
        'competition:jihomoravska-divize-2026-2027': {'inserted': 1},
      },
    });
    final r = s.discover!;
    expect(r.teams, 5);
    expect(r.competitions, 2);
    expect(r.created, 5);
    expect(r.clubsCreated, ['KS Devítka Brno']);
    expect(r.clubsLinked, ['Sokol Brno IV', 'Veverky']);
    expect(r.at, DateTime.utc(2026, 9, 25, 8));
    expect(r.failed, isFalse);

    expect(FederationSync.fromJson({'venue_slug': 'x'}).discover, isNull);
    final failed = FederationSync.fromJson({
      'last_report': {
        'discover': {'error': 'boom', 'at': '2026-09-25T08:00:00+00:00'},
      },
    }).discover!;
    expect(failed.failed, isTrue);
    expect(failed.error, 'boom');
    expect(failed.teams, 0);
    expect(failed.clubsCreated, isEmpty);
  });

  test('FederationSyncProgress.fromJson, pending and idle (0047)', () {
    final p = FederationSyncProgress.fromJson(
        {'discover': 0, 'competitions': 2, 'matches': 12, 'venues': 1});
    expect(p.discover, 0);
    expect(p.competitions, 2);
    expect(p.matches, 12);
    expect(p.venues, 1);
    expect(p.pending, isTrue);
    expect(FederationSyncProgress.idle.pending, isFalse);
    expect(FederationSyncProgress.fromJson(const {}), FederationSyncProgress.idle);
    expect(const FederationSyncProgress(matches: 1),
        const FederationSyncProgress(matches: 1));
  });
}
```

In `test/domain/models_test.dart`, in `group('Club', …)`, replace:
```dart
    test('fromJson defaults color to -1 when absent', () {
      final c = Club.fromJson({'id': 'club-2', 'name': 'KK Brno'});
      expect(c.colorIndex, -1);
    });
```
with:
```dart
    test('fromJson defaults color to -1 when absent', () {
      final c = Club.fromJson({'id': 'club-2', 'name': 'KK Brno'});
      expect(c.colorIndex, -1);
    });

    test('fromJson reads the ČKA identity; unlinked without it (0047)', () {
      final c = Club.fromJson({
        'id': 'club-3',
        'name': 'Devítka',
        'color': 3,
        'site_slug': 'ks-devitka-brno',
        'site_name': 'KS Devítka Brno',
      });
      expect(c.siteSlug, 'ks-devitka-brno');
      expect(c.siteName, 'KS Devítka Brno');
      expect(c.linked, isTrue);
      expect(Club.fromJson({'id': 'club-2', 'name': 'KK Brno'}).linked, isFalse);
    });
```

- [ ] **Step 2: Run them to verify they fail**

Run: `flutter test test/domain/team_test.dart test/domain/models_test.dart`
Expected: FAIL to compile — `The getter 'discover' isn't defined for the type 'FederationSync'`, `Undefined name 'FederationSyncProgress'`, `The getter 'siteSlug' isn't defined for the type 'Club'`.

- [ ] **Step 3: Implement**

In `lib/domain/models.dart` replace:
```dart
/// A club (spec §2): a named group of players sharing a palette color.
class Club {
  const Club({
    required this.id,
    required this.name,
    this.colorIndex = -1,
  });

  final String id;
  final String name;

  /// Palette index 0–11, or -1 for "no color assigned".
  final int colorIndex;

  factory Club.fromJson(Map<String, dynamic> json) => Club(
        id: json['id'] as String,
        name: json['name'] as String,
        colorIndex: json['color'] as int? ?? -1,
      );
}
```
with:
```dart
/// A club (spec §2): a named group of players sharing a palette color.
class Club {
  const Club({
    required this.id,
    required this.name,
    this.colorIndex = -1,
    this.siteSlug,
    this.siteName,
  });

  final String id;
  final String name;

  /// Palette index 0–11, or -1 for "no color assigned".
  final int colorIndex;

  /// The venue club on vysledky.kuzelky.cz this club is linked to
  /// (`detail-klubu/<slug>`) and its name there (0047). null until a
  /// discovery links it; renaming the club in the app keeps both, so the
  /// next discovery still finds it.
  final String? siteSlug;
  final String? siteName;

  bool get linked => siteSlug != null;

  factory Club.fromJson(Map<String, dynamic> json) => Club(
        id: json['id'] as String,
        name: json['name'] as String,
        colorIndex: json['color'] as int? ?? -1,
        siteSlug: json['site_slug'] as String?,
        siteName: json['site_name'] as String?,
      );
}
```

and replace:
```dart
class FederationSync {
  const FederationSync({
    this.venueSlug = '',
    this.enabled = false,
    this.lastRunAt,
    this.lastSuccessAt,
    this.lastError,
  });

  static const none = FederationSync();

  final String venueSlug;
  final bool enabled;
  final DateTime? lastRunAt;
  final DateTime? lastSuccessAt;
  final String? lastError;

  bool get configured => venueSlug.isNotEmpty;

  static DateTime? _time(Object? v) =>
      v == null ? null : DateTime.parse(v as String);

  factory FederationSync.fromJson(Map<String, dynamic> json) => FederationSync(
        venueSlug: json['venue_slug'] as String? ?? '',
        enabled: json['enabled'] as bool? ?? false,
        lastRunAt: _time(json['last_run_at']),
        lastSuccessAt: _time(json['last_success_at']),
        lastError: json['last_error'] as String?,
      );
}
```
with:
```dart
class FederationSync {
  const FederationSync({
    this.venueSlug = '',
    this.enabled = false,
    this.lastRunAt,
    this.lastSuccessAt,
    this.lastError,
    this.discover,
  });

  static const none = FederationSync();

  final String venueSlug;
  final bool enabled;

  /// Stamped by the schedule's (competition) runs only — since 0047 not by
  /// a discovery — so null means the alley was never synced.
  final DateTime? lastRunAt;
  final DateTime? lastSuccessAt;
  final String? lastError;

  /// The last discovery (`last_report.discover`), null before the first.
  final FederationDiscoverReport? discover;

  bool get configured => venueSlug.isNotEmpty;

  static DateTime? _time(Object? v) =>
      v == null ? null : DateTime.parse(v as String);

  factory FederationSync.fromJson(Map<String, dynamic> json) {
    final discover = (json['last_report'] as Map?)?['discover'];
    return FederationSync(
      venueSlug: json['venue_slug'] as String? ?? '',
      enabled: json['enabled'] as bool? ?? false,
      lastRunAt: _time(json['last_run_at']),
      lastSuccessAt: _time(json['last_success_at']),
      lastError: json['last_error'] as String?,
      discover: discover is Map
          ? FederationDiscoverReport.fromJson(
              Map<String, dynamic>.from(discover))
          : null,
    );
  }
}

/// What the last discovery did (0047): the venue's [teams] in how many
/// [competitions], how many teams it [created], and the clubs of ours it
/// matched ([clubsLinked], our names) or created ([clubsCreated]). A failed
/// discovery carries only [error] and [at].
class FederationDiscoverReport {
  const FederationDiscoverReport({
    this.teams = 0,
    this.competitions = 0,
    this.created = 0,
    this.clubsCreated = const [],
    this.clubsLinked = const [],
    this.at,
    this.error,
  });

  final int teams;
  final int competitions;
  final int created;
  final List<String> clubsCreated;
  final List<String> clubsLinked;
  final DateTime? at;
  final String? error;

  bool get failed => error != null;

  static int _count(Object? v) => (v as num?)?.toInt() ?? 0;

  static List<String> _names(Object? v) =>
      [for (final name in v as List? ?? const []) name as String];

  factory FederationDiscoverReport.fromJson(Map<String, dynamic> json) =>
      FederationDiscoverReport(
        teams: _count(json['teams']),
        competitions: _count(json['competitions']),
        created: _count(json['created']),
        clubsCreated: _names(json['clubs_created']),
        clubsLinked: _names(json['clubs_linked']),
        at: FederationSync._time(json['at']),
        error: json['error'] as String?,
      );
}

/// The alley's federation jobs due now or in flight, per kind (0047
/// `federation_sync_progress`) — what the ČKA card polls while a sync runs.
class FederationSyncProgress {
  const FederationSyncProgress({
    this.discover = 0,
    this.competitions = 0,
    this.matches = 0,
    this.venues = 0,
  });

  static const idle = FederationSyncProgress();

  final int discover;
  final int competitions;
  final int matches;
  final int venues;

  bool get pending => discover + competitions + matches + venues > 0;

  static int _count(Object? v) => (v as num?)?.toInt() ?? 0;

  factory FederationSyncProgress.fromJson(Map<String, dynamic> json) =>
      FederationSyncProgress(
        discover: _count(json['discover']),
        competitions: _count(json['competitions']),
        matches: _count(json['matches']),
        venues: _count(json['venues']),
      );

  @override
  bool operator ==(Object other) =>
      other is FederationSyncProgress &&
      other.discover == discover &&
      other.competitions == competitions &&
      other.matches == matches &&
      other.venues == venues;

  @override
  int get hashCode => Object.hash(discover, competitions, matches, venues);

  @override
  String toString() => 'FederationSyncProgress(discover: $discover, '
      'competitions: $competitions, matches: $matches, venues: $venues)';
}
```

In `lib/data/providers.dart` replace:
```dart
  static Future<void> requestFederationSync() =>
      _db.rpc('request_federation_sync');
```
with:
```dart
  static Future<void> requestFederationSync() =>
      _db.rpc('request_federation_sync');

  /// The alley's federation jobs due now or in flight (0047) — what the ČKA
  /// card polls while a sync or discovery runs. Admin only (`not_allowed`).
  static Future<FederationSyncProgress> federationSyncProgress() async =>
      FederationSyncProgress.fromJson(Map<String, dynamic>.from(
          await _db.rpc('federation_sync_progress') as Map));
```

- [ ] **Step 4: Run them to verify they pass**

Run: `flutter test test/domain/team_test.dart test/domain/models_test.dart`
Expected: `All tests passed!`

Run: `flutter analyze`
Expected: `No issues found!`

- [ ] **Step 5: Commit**

```bash
git add lib/domain/models.dart lib/data/providers.dart test/domain/team_test.dart test/domain/models_test.dart
git commit -m "$(cat <<'EOF'
feat(federation): the app reads clubs' ČKA identity, the discovery report and the sync progress

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 5: Club and team rows — team pencil, club site name, delete warning

**Files:**
- Modify: `lib/features/admin/clubs_screen.dart`
- Modify: `lib/features/admin/widgets/club_dialog.dart`
- Test: `test/features/clubs_screen_test.dart`

**Interfaces:**
- Consumes: Task 4 `Club.linked`, `Club.siteName`; existing `TeamDialog(team:, clubs:, updateTeam:)`, `confirmDelete`, `Api.deleteClub`.
- Produces: the team row with a trailing pencil `IconButton` (tooltip „Upravit tým“) and a row tap, both opening `TeamDialog`; no `Switch`; an inactive team's subtitle is `'<competition> · nestahuje se'`. Club rows get tooltips „Upravit oddíl“ / „Smazat oddíl“. `ClubDialog` shows „Na webu ČKA: <siteName>“ as the name field's helper text. `_toggleTeamActive` is removed.

- [ ] **Step 1: Write the failing tests**

In `test/features/clubs_screen_test.dart` replace the whole test `testWidgets('toggling a team switch calls updateTeam with the flip', …)` (from its `testWidgets(` line through its closing `});`) with:

```dart
    testWidgets('a team row edits through its pencil or a tap — no switch',
        (tester) async {
      const team = Team(
        id: 't1',
        name: 'Veverky A',
        clubId: 'c2',
        competitionName: 'OP I. třída',
      );
      await pumpApp(tester, app(clubs, teams: const [team]));

      final row = find.ancestor(
          of: find.text('Veverky A'), matching: find.byType(ListTile));
      expect(find.descendant(of: row, matching: find.byType(Switch)),
          findsNothing);

      await tester.tap(find.byTooltip('Upravit tým'));
      await tester.pumpAndSettle();
      expect(find.text('Tým'), findsOneWidget);
      await tester.tap(find.text('Zrušit'));
      await tester.pumpAndSettle();
      expect(find.text('Tým'), findsNothing);

      await tester.tap(find.text('Veverky A'));
      await tester.pumpAndSettle();
      expect(find.text('Tým'), findsOneWidget);
    });

    testWidgets('a team that is not downloaded is greyed out and says so',
        (tester) async {
      const team = Team(
        id: 't1',
        name: 'Veverky B',
        clubId: 'c2',
        competitionName: 'OP II. třída',
        active: false,
      );
      await pumpApp(tester, app(clubs, teams: const [team]));

      expect(find.text('OP II. třída · nestahuje se'), findsOneWidget);
      final title = tester.widget<Text>(find.text('Veverky B'));
      final scheme =
          Theme.of(tester.element(find.text('Veverky B'))).colorScheme;
      expect(title.style?.color, scheme.onSurfaceVariant);
    });
```

Right after the test `'deleting a club with teams says its teams lose it too'` (after its closing `});`), add:

```dart

    // Devítka is linked to the ČKA site (0047); Veverky is not.
    const linkedClubs = [
      Club(
        id: 'c1',
        name: 'Devítka',
        colorIndex: 3,
        siteSlug: 'ks-devitka-brno',
        siteName: 'KS Devítka Brno',
      ),
      Club(id: 'c2', name: 'Veverky', colorIndex: 2),
    ];

    testWidgets('a linked club\'s dialog shows its name on the ČKA site',
        (tester) async {
      await pumpApp(tester, app(linkedClubs));

      await tester.tap(find.byTooltip('Upravit oddíl').first);
      await tester.pumpAndSettle();
      expect(find.text('Na webu ČKA: KS Devítka Brno'), findsOneWidget);
      await tester.tap(find.text('Zrušit'));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Upravit oddíl').last);
      await tester.pumpAndSettle();
      expect(find.textContaining('Na webu ČKA'), findsNothing);
    });

    testWidgets('deleting a linked club warns that discovery brings it back',
        (tester) async {
      await pumpApp(tester, app(linkedClubs));

      await tester.tap(find.byTooltip('Smazat oddíl').first);
      await tester.pumpAndSettle();
      expect(
        find.text('Opravdu smazat oddíl „Devítka"? Hráči zůstanou bez '
            'oddílu. Oddíl je propojený s webem ČKA, takže ho příští '
            '„Přenačíst týmy z webu“ založí znovu.'),
        findsOneWidget,
      );
      await tester.tap(find.text('Zrušit'));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Smazat oddíl').last);
      await tester.pumpAndSettle();
      expect(
        find.text('Opravdu smazat oddíl „Veverky"? Hráči zůstanou bez '
            'oddílu.'),
        findsOneWidget,
      );
    });
```

- [ ] **Step 2: Run them to verify they fail**

Run: `flutter test test/features/clubs_screen_test.dart`
Expected: FAIL — `Some tests failed`, e.g. `Expected: exactly one matching candidate … Found 0 widgets with tooltip "Upravit tým"` and the same for „Upravit oddíl“ / „Smazat oddíl“, and no `'OP II. třída · nestahuje se'`.

- [ ] **Step 3: Implement**

In `lib/features/admin/clubs_screen.dart` replace:
```dart
  Future<void> _delete(BuildContext context, Club club, int teamCount) =>
      confirmDelete(
        context,
        title: 'Smazat oddíl?',
        message: teamCount == 0
            ? 'Opravdu smazat oddíl „${club.name}"? Hráči zůstanou bez oddílu.'
            : 'Opravdu smazat oddíl „${club.name}"? Hráči i týmy '
                '($teamCount) zůstanou bez oddílu.',
        action: () => Api.deleteClub(club.id),
        success: 'Smazáno.',
      );

  Future<void> _toggleTeamActive(
          BuildContext context, Team team, bool active) =>
      tryAction(
        context,
        () => updateTeam(team,
            name: team.name, clubId: team.clubId, active: active),
        errorText: friendlyDbError,
      );
```
with:
```dart
  Future<void> _delete(BuildContext context, Club club, int teamCount) {
    final message = teamCount == 0
        ? 'Opravdu smazat oddíl „${club.name}"? Hráči zůstanou bez oddílu.'
        : 'Opravdu smazat oddíl „${club.name}"? Hráči i týmy '
            '($teamCount) zůstanou bez oddílu.';
    return confirmDelete(
      context,
      title: 'Smazat oddíl?',
      // Discovery finds a linked club by its site_slug (0047): deleted, it
      // is created again while it plays at the kuželna.
      message: club.linked
          ? '$message Oddíl je propojený s webem ČKA, takže ho příští '
              '„Přenačíst týmy z webu“ založí znovu.'
          : message,
      action: () => Api.deleteClub(club.id),
      success: 'Smazáno.',
    );
  }
```

Replace:
```dart
  Widget _teamTile(BuildContext context, Team team, List<Club> clubs) {
    return ListTile(
      contentPadding: const EdgeInsets.only(left: 56, right: 16),
      dense: true,
      title: Text(
        team.name,
        style: team.active
            ? null
            : TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
      ),
      subtitle: Text(
        team.competitionName.isEmpty ? 'bez soutěže' : team.competitionName,
      ),
      trailing: Switch(
        value: team.active,
        onChanged: (active) => _toggleTeamActive(context, team, active),
      ),
      onTap: () => _editTeam(context, team, clubs),
    );
  }
```
with:
```dart
  Widget _teamTile(BuildContext context, Team team, List<Club> clubs) {
    final competition =
        team.competitionName.isEmpty ? 'bez soutěže' : team.competitionName;
    return ListTile(
      contentPadding: const EdgeInsets.only(left: 56, right: 16),
      dense: true,
      title: Text(
        team.name,
        style: team.active
            ? null
            : TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
      ),
      subtitle: Text(team.active ? competition : '$competition · nestahuje se'),
      trailing: IconButton(
        icon: const Icon(Icons.edit_outlined),
        tooltip: 'Upravit tým',
        onPressed: () => _editTeam(context, team, clubs),
      ),
      onTap: () => _editTeam(context, team, clubs),
    );
  }
```

In the club row's trailing `Row`, replace:
```dart
                        IconButton(
                          icon: const Icon(Icons.edit_outlined),
                          onPressed: () =>
                              _addOrEdit(context, existing: club),
                        ),
                        IconButton(
                          icon: const Icon(Icons.delete_outline),
                          onPressed: () => _delete(
```
with:
```dart
                        IconButton(
                          icon: const Icon(Icons.edit_outlined),
                          tooltip: 'Upravit oddíl',
                          onPressed: () =>
                              _addOrEdit(context, existing: club),
                        ),
                        IconButton(
                          icon: const Icon(Icons.delete_outline),
                          tooltip: 'Smazat oddíl',
                          onPressed: () => _delete(
```

Replace the whole of `lib/features/admin/widgets/club_dialog.dart` with:
```dart
import 'package:flutter/material.dart';

import '../../../core/ui.dart';
import '../../../domain/models.dart';
import 'color_picker.dart';
import 'form_dialog.dart';

/// Add/edit dialog for a club: name field + [ColorPickerGrid]. Pops with
/// `(name, colorIndex)` — the screen runs the RPC, so a failed save can be
/// retried from the list. A club linked to the ČKA site (0047) shows its
/// name there under the field: the link survives any rename.
class ClubDialog extends StatefulWidget {
  const ClubDialog({super.key, this.existing});

  final Club? existing;

  @override
  State<ClubDialog> createState() => _ClubDialogState();
}

class _ClubDialogState extends State<ClubDialog> {
  final _name = TextEditingController();
  late int _colorIndex;

  @override
  void initState() {
    super.initState();
    _name.text = widget.existing?.name ?? '';
    _colorIndex = widget.existing?.colorIndex ?? -1;
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<(String, int)?> _save() async {
    final name = _name.text.trim();
    if (name.isEmpty) {
      snack(context, 'Vyplň název oddílu.');
      return null;
    }
    return (name, _colorIndex);
  }

  @override
  Widget build(BuildContext context) {
    final siteName = widget.existing?.siteName;
    return FormDialog<(String, int)>(
      title: widget.existing == null ? 'Přidat oddíl' : 'Upravit oddíl',
      onSave: _save,
      children: [
        TextField(
          controller: _name,
          autofocus: true,
          decoration: InputDecoration(
            labelText: 'Název',
            helperText: siteName == null ? null : 'Na webu ČKA: $siteName',
            helperMaxLines: 2,
          ),
        ),
        const SizedBox(height: 16),
        ColorPickerGrid(
          selected: _colorIndex,
          noneValue: -1,
          noneLabel: 'Žádná',
          onChanged: (index) => setState(() => _colorIndex = index),
        ),
      ],
    );
  }
}
```

- [ ] **Step 4: Run them to verify they pass**

Run: `flutter test test/features/clubs_screen_test.dart`
Expected: `All tests passed!`

Run: `flutter analyze`
Expected: `No issues found!`

- [ ] **Step 5: Commit**

```bash
git add lib/features/admin/clubs_screen.dart lib/features/admin/widgets/club_dialog.dart test/features/clubs_screen_test.dart
git commit -m "$(cat <<'EOF'
feat(clubs): a team row edits through a pencil; a linked club shows its ČKA name and warns on delete

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 6: ČKA card normal view — read-only kuželna with a pencil, the switch saves at once

**Files:**
- Modify: `lib/domain/slug.dart`
- Create: `lib/features/admin/widgets/venue_slug_field.dart`
- Modify: `lib/features/admin/widgets/federation_card.dart` (rewrite)
- Create: `test/features/federation_card_test.dart`
- Modify: `test/domain/slug_test.dart`, `test/features/clubs_screen_test.dart`

**Interfaces:**
- Consumes: `FederationSync`, `Api.setFederationSync/requestFederationDiscovery/requestFederationSync`, `federationSyncProvider`, `teamsProvider`, `clubsProvider`, `FormDialog<T>`, `tryAction`, `friendlyDbError`.
- Produces:
  - In `slug.dart`: `final RegExp venueSlugPattern`, `String? venueSlugFromInput(String input)`, `String? venueSlugInputError(String input)`.
  - In `venue_slug_field.dart`: `const String venueSlugHelp`; `VenueSlugField({required TextEditingController controller, String? errorText, VoidCallback? onChanged, bool autofocus = false, bool enabled = true})`; `VenueSlugDialog({required String initial, required Future<void> Function(String slug) save})`, which pops `true` on a save.
  - `FederationCard({saveFederation, discoverTeams, syncNow})`, same parameters as today, now with the normal view.
  - The test harness `_Harness` in `federation_card_test.dart` (Tasks 7 and 8 extend it).

- [ ] **Step 1: Write the failing tests**

Append inside `main()` of `test/domain/slug_test.dart` — replace its end:
```dart
        expect(slugPattern.hasMatch(s), isFalse, reason: s);
      }
    });
  });
}
```
with:
```dart
        expect(slugPattern.hasMatch(s), isFalse, reason: s);
      }
    });
  });

  group('the kuželna on the ČKA site (0047)', () {
    test('venueSlugPattern mirrors set_federation_sync\'s check', () {
      for (final s in ['a', 'kk2', 'tj-sokol-brno-iv']) {
        expect(venueSlugPattern.hasMatch(s), isTrue, reason: s);
      }
      for (final s in ['', 'A', 'a-', '-a', 'a--b', 'a_b', 'kuželna']) {
        expect(venueSlugPattern.hasMatch(s), isFalse, reason: s);
      }
    });

    test('takes the slug or the page\'s whole address, host optional', () {
      for (final input in [
        'tj-sokol-brno-iv',
        '  TJ-Sokol-Brno-IV ',
        'tj-sokol-brno-iv/',
        'https://vysledky.kuzelky.cz/detail-kuzelny/tj-sokol-brno-iv',
        'vysledky.kuzelky.cz/detail-kuzelny/tj-sokol-brno-iv/',
        'https://vysledky.kuzelky.cz/detail-kuzelny/tj-sokol-brno-iv?tab=info#mapa',
        '/detail-kuzelny/tj-sokol-brno-iv',
      ]) {
        expect(venueSlugFromInput(input), 'tj-sokol-brno-iv', reason: input);
      }
    });

    test('null for anything that is no kuželna slug', () {
      for (final input in [
        '',
        '   ',
        'https://vysledky.kuzelky.cz/detail-klubu/ks-devitka-brno',
        'https://vysledky.kuzelky.cz/detail-kuzelny/',
        'vysledky.kuzelky.cz',
        'detail-kuzelny/a/b',
        'Kuželna Brno',
        'tj--sokol',
      ]) {
        expect(venueSlugFromInput(input), isNull, reason: input);
      }
    });

    test('the inline error: nothing typed, or no kuželna', () {
      expect(venueSlugInputError('tj-sokol-brno-iv'), isNull);
      expect(venueSlugInputError('  '), 'Vlož adresu stránky kuželny.');
      expect(
        venueSlugInputError(
            'https://vysledky.kuzelky.cz/detail-klubu/ks-devitka-brno'),
        'Tohle není adresa kuželny — zkopíruj adresu stránky, která '
        'obsahuje /detail-kuzelny/.',
      );
    });
  });
}
```

Create `test/features/federation_card_test.dart`:
```dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rezervator/data/providers.dart';
import 'package:rezervator/domain/models.dart';
import 'package:rezervator/features/admin/widgets/federation_card.dart';

/// The ČKA card on its own (Správa → Oddíly). Each (re)build of the sync
/// row's or the teams' provider takes the next of [rows] / [teams], the
/// last one repeating, so a test sees what the card fetches again.
class _Harness {
  _Harness({List<FederationSync>? rows, List<List<Team>>? teams})
      : rows = rows ?? const [FederationSync.none],
        teams = teams ?? const [<Team>[]];

  final List<FederationSync> rows;
  final List<List<Team>> teams;
  int rowBuilds = 0;
  int teamBuilds = 0;
  final saved = <(String, bool)>[];
  int discoveries = 0;
  int syncs = 0;

  /// Thrown by the next saves instead of saving.
  Object? saveError;

  static T _nth<T>(List<T> list, int i) =>
      list[i < list.length ? i : list.length - 1];

  Widget app() => ProviderScope(
        overrides: [
          federationSyncProvider
              .overrideWith((ref) => Stream.value(_nth(rows, rowBuilds++))),
          teamsProvider
              .overrideWith((ref) => Stream.value(_nth(teams, teamBuilds++))),
          clubsProvider.overrideWith((ref) => Stream.value(const <Club>[])),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: FederationCard(
                saveFederation: (slug, enabled) async {
                  final error = saveError;
                  if (error != null) throw error;
                  saved.add((slug, enabled));
                },
                discoverTeams: () async => discoveries++,
                syncNow: () async => syncs++,
              ),
            ),
          ),
        ),
      );
}

/// Pumps without settling: a spinning progress line never settles.
Future<void> _pump(WidgetTester tester, _Harness h) async {
  tester.view.physicalSize = const Size(800, 1600);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(h.app());
  await tester.pump();
  await tester.pump();
}

const _on = FederationSync(venueSlug: 'tj-sokol-brno-iv', enabled: true);

/// Synced before and switched off since: still the normal view.
final _off = FederationSync(
  venueSlug: 'tj-sokol-brno-iv',
  lastRunAt: DateTime.utc(2026, 9, 24, 1),
);

void main() {
  group('normal view', () {
    testWidgets('the kuželna is read-only behind a pencil; there is no Uložit',
        (tester) async {
      await _pump(tester, _Harness(rows: [_on]));

      expect(find.text('Kuželna na webu'), findsOneWidget);
      expect(find.text('detail-kuzelny/tj-sokol-brno-iv'), findsOneWidget);
      expect(find.byType(TextField), findsNothing);
      expect(find.byTooltip('Změnit kuželnu'), findsOneWidget);
      expect(find.text('Uložit'), findsNothing);
    });

    testWidgets(
        'the pencil saves the slug of a pasted page address, the switch kept',
        (tester) async {
      final h = _Harness(rows: [_on]);
      await _pump(tester, h);

      await tester.tap(find.byTooltip('Změnit kuželnu'));
      await tester.pumpAndSettle();
      final dialog = find.byType(AlertDialog);
      expect(find.descendant(of: dialog, matching: find.text('Změnit kuželnu')),
          findsOneWidget);
      expect(find.widgetWithText(TextField, 'tj-sokol-brno-iv'), findsOneWidget);

      await tester.enterText(find.byType(TextField),
          'https://vysledky.kuzelky.cz/detail-kuzelny/KS-Devitka-Brno/?tab=1');
      await tester.tap(find.descendant(of: dialog, matching: find.text('Uložit')));
      await tester.pumpAndSettle();

      expect(h.saved, [('ks-devitka-brno', true)]);
      expect(dialog, findsNothing);
    });

    testWidgets('the pencil refuses the address of another page, inline',
        (tester) async {
      final h = _Harness(rows: [_on]);
      await _pump(tester, h);

      await tester.tap(find.byTooltip('Změnit kuželnu'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField),
          'https://vysledky.kuzelky.cz/detail-klubu/ks-devitka-brno');
      await tester.tap(find.descendant(
          of: find.byType(AlertDialog), matching: find.text('Uložit')));
      await tester.pumpAndSettle();

      expect(h.saved, isEmpty);
      expect(
        find.text('Tohle není adresa kuželny — zkopíruj adresu stránky, která '
            'obsahuje /detail-kuzelny/.'),
        findsOneWidget,
      );
      expect(find.byType(AlertDialog), findsOneWidget);
    });

    testWidgets('Stahovat automaticky saves at once', (tester) async {
      final h = _Harness(rows: [_on]);
      await _pump(tester, h);

      await tester.tap(find.text('Stahovat automaticky'));
      await tester.pump();
      await tester.pump();

      expect(h.saved, [('tj-sokol-brno-iv', false)]);
      expect(tester.widget<SwitchListTile>(find.byType(SwitchListTile)).value,
          isFalse);
    });

    testWidgets('a refused switch save flips back and says why',
        (tester) async {
      final h = _Harness(rows: [_on])..saveError = Exception('not_allowed');
      await _pump(tester, h);

      await tester.tap(find.text('Stahovat automaticky'));
      await tester.pump();
      await tester.pump();

      expect(find.text('Na tohle nemáš oprávnění.'), findsOneWidget);
      expect(tester.widget<SwitchListTile>(find.byType(SwitchListTile)).value,
          isTrue);
    });

    testWidgets(
        'Přenačíst týmy z webu asks for a discovery; Synchronizovat teď '
        'needs the switch on', (tester) async {
      final h = _Harness(rows: [_off]);
      await _pump(tester, h);

      final sync = tester.widget<OutlinedButton>(
          find.widgetWithText(OutlinedButton, 'Synchronizovat teď'));
      expect(sync.onPressed, isNull);

      await tester.tap(find.widgetWithText(OutlinedButton, 'Přenačíst týmy z webu'));
      await tester.pump();
      expect(h.discoveries, 1);
    });

    testWidgets('Synchronizovat teď asks for a sync', (tester) async {
      final h = _Harness(rows: [_on]);
      await _pump(tester, h);

      await tester.tap(find.widgetWithText(OutlinedButton, 'Synchronizovat teď'));
      await tester.pump();
      expect(h.syncs, 1);
    });

    testWidgets('the last error shows', (tester) async {
      await _pump(
        tester,
        _Harness(rows: [
          const FederationSync(
              venueSlug: 'tj-sokol-brno-iv', enabled: true, lastError: 'boom'),
        ]),
      );

      expect(find.text('Chyba: boom'), findsOneWidget);
      expect(find.text('Poslední synchronizace: Zatím neproběhla'),
          findsOneWidget);
    });
  });

}
```

In `test/features/clubs_screen_test.dart` (the card's tests move to `federation_card_test.dart`):
- delete the seven card tests — the contiguous block from `    testWidgets(\n        'unconfigured sync seeds the default slug and disables Načíst týmy',` up to, not including, `    testWidgets('a team row edits through its pencil or a tap — no switch',` (added in Task 5). The seven are: `unconfigured sync seeds…`, `saving the slug calls saveFederation…`, `a sync row that arrives after the first frame…`, `a newer row after the cached one…`, `a cached empty row…`, `a row arriving while the admin edits…`, `a configured+enabled sync enables both actions and shows the error`;
- delete the first line `import 'dart:async';` and the blank line after it (nothing uses `StreamController` any more);
- rename `group('federation sync card (0045)', () {` to `group('teams under their clubs (0045)', () {`;
- replace every comment `// The ČKA card has its own Uložit button — scope to the dialog.` (three) with `// Scope to the dialog: the ČKA card has buttons of its own.`;
- replace the file's doc comment
```dart
/// Smoke test for the clubs admin list: renders for an admin, shows its
/// empty state, the ČKA sync card (0045), teams grouped under their club,
/// and the FAB opens the add dialog (never saved — that would hit the RPC).
```
with
```dart
/// Smoke test for the clubs admin list: renders for an admin, shows its
/// empty state, teams grouped under their club (0045), and the FAB opens
/// the add dialog (never saved — that would hit the RPC). The ČKA card has
/// its own tests in federation_card_test.dart.
```

- [ ] **Step 2: Run them to verify they fail**

Run: `flutter test test/domain/slug_test.dart test/features/federation_card_test.dart`
Expected: FAIL — `slug_test.dart` does not compile (`Method not found: 'venueSlugFromInput'`, `Undefined name 'venueSlugPattern'`), and `federation_card_test.dart` fails (`find.byType(TextField)` finds the old slug field; no tooltip „Změnit kuželnu“; no „Přenačíst týmy z webu“).

- [ ] **Step 3: Implement**

In `lib/domain/slug.dart` replace the library doc:
```dart
/// The public overview's address part (0043): what an admin types after
/// `#/prehled/`. Pure Dart, unit-tested.
library;
```
with:
```dart
/// Slugs an admin types: the public overview's address part (0043), what
/// comes after `#/prehled/`, and the kuželna's page on the ČKA results site
/// (0045/0047). Pure Dart, unit-tested.
library;
```
and append at the end of the file:
```dart

/// Mirrors set_federation_sync's check on the kuželna's slug (0045):
/// lower-case letters without diacritics and digits, a single hyphen only
/// between them.
final venueSlugPattern = RegExp(r'^[a-z0-9]+(-[a-z0-9]+)*$');

/// The kuželna's slug out of what the admin pasted: its page's whole
/// address, with or without the host, or the slug alone. Trimmed and
/// lower-cased; a query, a fragment and trailing slashes are dropped. null
/// when what is left is no slug.
String? venueSlugFromInput(String input) {
  var s = input.trim().toLowerCase();
  final tail = s.indexOf(RegExp('[?#]'));
  if (tail >= 0) s = s.substring(0, tail);
  s = s.replaceAll(RegExp(r'/+$'), '');
  const page = 'detail-kuzelny/';
  final at = s.lastIndexOf(page);
  if (at >= 0) s = s.substring(at + page.length);
  return venueSlugPattern.hasMatch(s) ? s : null;
}

/// The kuželna field's inline error for [input], or null when it holds a
/// slug.
String? venueSlugInputError(String input) {
  if (input.trim().isEmpty) return 'Vlož adresu stránky kuželny.';
  if (venueSlugFromInput(input) == null) {
    return 'Tohle není adresa kuželny — zkopíruj adresu stránky, která '
        'obsahuje /detail-kuzelny/.';
  }
  return null;
}
```

Create `lib/features/admin/widgets/venue_slug_field.dart`:
```dart
/// Správa → Oddíly: the kuželna's page on vysledky.kuzelky.cz — the field
/// the ČKA setup wizard's first step and the „Změnit kuželnu“ dialog share.
/// It takes the page's whole address or just the slug
/// ([venueSlugFromInput]) and says inline what is wrong
/// ([venueSlugInputError]).
library;

import 'package:flutter/material.dart';

import '../../../core/ui.dart';
import '../../../domain/slug.dart';
import 'form_dialog.dart';

/// Where the admin finds the address — step 1 and the dialog say the same.
const venueSlugHelp = 'Na vysledky.kuzelky.cz otevři Kuželny, najdi svou '
    'kuželnu a zkopíruj adresu stránky. Stačí ji celou vložit.';

class VenueSlugField extends StatelessWidget {
  const VenueSlugField({
    super.key,
    required this.controller,
    this.errorText,
    this.onChanged,
    this.autofocus = false,
    this.enabled = true,
  });

  final TextEditingController controller;
  final String? errorText;
  final VoidCallback? onChanged;
  final bool autofocus;
  final bool enabled;

  @override
  Widget build(BuildContext context) => TextField(
        controller: controller,
        enabled: enabled,
        autofocus: autofocus,
        autocorrect: false,
        enableSuggestions: false,
        keyboardType: TextInputType.url,
        onChanged: (_) => onChanged?.call(),
        decoration: InputDecoration(
          labelText: 'Adresa kuželny',
          hintText: 'vysledky.kuzelky.cz/detail-kuzelny/…',
          errorText: errorText,
          errorMaxLines: 3,
        ),
      );
}

/// The normal view's pencil: another kuželna. Saves the parsed slug
/// through [save] and pops `true`; stays open on bad input or a refused
/// save; null on Zrušit.
class VenueSlugDialog extends StatefulWidget {
  const VenueSlugDialog({super.key, required this.initial, required this.save});

  final String initial;
  final Future<void> Function(String slug) save;

  @override
  State<VenueSlugDialog> createState() => _VenueSlugDialogState();
}

class _VenueSlugDialogState extends State<VenueSlugDialog> {
  late final _input = TextEditingController(text: widget.initial);
  String? _error;

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  Future<bool?> _save() async {
    final error = venueSlugInputError(_input.text);
    if (error != null) {
      setState(() => _error = error);
      return null;
    }
    final slug = venueSlugFromInput(_input.text)!;
    final ok = await tryAction(
      context,
      () => widget.save(slug),
      success: 'Uloženo.',
      errorText: friendlyDbError,
    );
    return ok ? true : null;
  }

  @override
  Widget build(BuildContext context) => FormDialog<bool>(
        title: 'Změnit kuželnu',
        onSave: _save,
        children: [
          Text(venueSlugHelp, style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(height: 12),
          VenueSlugField(
            controller: _input,
            autofocus: true,
            errorText: _error,
            onChanged: () {
              if (_error != null) setState(() => _error = null);
            },
          ),
        ],
      );
}
```

Replace the whole of `lib/features/admin/widgets/federation_card.dart` with:
```dart
/// Správa → Oddíly: the ČKA results-service card — the alley's kuželna on
/// vysledky.kuzelky.cz (read-only, changed behind a pencil), automatic sync
/// on/off (saved at once), and a one-off team discovery or sync run.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/ui.dart';
import '../../../data/providers.dart';
import '../../../domain/models.dart';
import 'venue_slug_field.dart';

class FederationCard extends ConsumerStatefulWidget {
  const FederationCard({
    super.key,
    this.saveFederation = _defaultSave,
    this.discoverTeams = Api.requestFederationDiscovery,
    this.syncNow = Api.requestFederationSync,
  });

  /// Injectable so a widget test can drive the card without the backend.
  final Future<void> Function(String venueSlug, bool enabled) saveFederation;
  final Future<void> Function() discoverTeams;
  final Future<void> Function() syncNow;

  static Future<void> _defaultSave(String venueSlug, bool enabled) =>
      Api.setFederationSync(venueSlug: venueSlug, enabled: enabled);

  @override
  ConsumerState<FederationCard> createState() => _FederationCardState();
}

class _FederationCardState extends ConsumerState<FederationCard> {
  /// The switch's value from a tap until the row echoes it — the save runs
  /// at once, the echo comes over Realtime a moment later. null: the row's.
  bool? _enabledWanted;
  bool _savingEnabled = false;

  Future<void> _setEnabled(FederationSync sync, bool enabled) async {
    setState(() {
      _enabledWanted = enabled;
      _savingEnabled = true;
    });
    final ok = await tryAction(
      context,
      () => widget.saveFederation(sync.venueSlug, enabled),
      errorText: friendlyDbError,
    );
    if (!mounted) return;
    setState(() {
      _savingEnabled = false;
      if (!ok) _enabledWanted = null;
    });
  }

  Future<void> _editSlug(FederationSync sync, bool enabled) =>
      showDialog<bool>(
        context: context,
        builder: (_) => VenueSlugDialog(
          initial: sync.venueSlug,
          save: (slug) => widget.saveFederation(slug, enabled),
        ),
      );

  Future<void> _discover() => tryAction(
        context,
        widget.discoverTeams,
        success: 'Týmy se načítají — za chvíli se objeví níže.',
        errorText: friendlyDbError,
      );

  Future<void> _sync() => tryAction(
        context,
        widget.syncNow,
        success: 'Synchronizace spuštěna.',
        errorText: friendlyDbError,
      );

  /// "čt 23.4. 9:05" — local time, reusing core/ui.dart's date label and
  /// [HourMinute]'s own display instead of hand-rolling another format.
  String _lastSuccessLabel(DateTime? at) {
    if (at == null) return 'Zatím neproběhla';
    final local = at.toLocal();
    final day = Day.fromDateTime(local);
    final time = HourMinute(local.hour, local.minute);
    return '${dayLabel(day)} ${time.display()}';
  }

  @override
  Widget build(BuildContext context) {
    final loaded = ref.watch(federationSyncProvider);
    final sync = loaded.value;
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Výsledkový servis ČKA', style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            if (sync != null)
              ..._settings(sync)
            else if (loaded.hasError)
              Text(
                friendlyDbError(loaded.error!),
                style: TextStyle(color: theme.colorScheme.error),
              )
            else
              const Text('Načítám…'),
          ],
        ),
      ),
    );
  }

  List<Widget> _settings(FederationSync sync) {
    // The tapped value stays until the row catches up with it.
    if (_enabledWanted == sync.enabled) _enabledWanted = null;
    final enabled = _enabledWanted ?? sync.enabled;
    final theme = Theme.of(context);
    return [
      const Text(
        'Zápasy a výsledky týmů, které hrají na této kuželně, se stahují '
        'z vysledky.kuzelky.cz.',
      ),
      const SizedBox(height: 8),
      Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Kuželna na webu', style: theme.textTheme.labelMedium),
                Text(sync.configured
                    ? 'detail-kuzelny/${sync.venueSlug}'
                    : 'Zatím nenastavená'),
              ],
            ),
          ),
          IconButton(
            icon: const Icon(Icons.edit_outlined),
            tooltip: 'Změnit kuželnu',
            onPressed: () => _editSlug(sync, enabled),
          ),
        ],
      ),
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: const Text('Stahovat automaticky'),
        value: enabled,
        onChanged: _savingEnabled || !sync.configured
            ? null
            : (v) => _setEnabled(sync, v),
      ),
      const SizedBox(height: 8),
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          OutlinedButton(
            onPressed: sync.configured ? _discover : null,
            child: const Text('Přenačíst týmy z webu'),
          ),
          OutlinedButton(
            onPressed: sync.configured && enabled ? _sync : null,
            child: const Text('Synchronizovat teď'),
          ),
        ],
      ),
      const SizedBox(height: 8),
      Text('Poslední synchronizace: ${_lastSuccessLabel(sync.lastSuccessAt)}'),
      if (sync.lastError != null)
        Text(
          'Chyba: ${sync.lastError}',
          style: TextStyle(color: theme.colorScheme.error),
        ),
    ];
  }
}
```

- [ ] **Step 4: Run them to verify they pass**

Run: `flutter test test/domain/slug_test.dart test/features/federation_card_test.dart test/features/clubs_screen_test.dart`
Expected: `All tests passed!`

Run: `flutter analyze`
Expected: `No issues found!`

- [ ] **Step 5: Commit**

```bash
git add lib/domain/slug.dart lib/features/admin/widgets/venue_slug_field.dart lib/features/admin/widgets/federation_card.dart test/domain/slug_test.dart test/features/federation_card_test.dart test/features/clubs_screen_test.dart
git commit -m "$(cat <<'EOF'
feat(federation): the ČKA card shows the kuželna read-only behind a pencil and saves the switch at once

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 7: ČKA card progress line and polling

**Files:**
- Modify: `lib/domain/labels.dart`
- Modify: `lib/features/admin/widgets/federation_card.dart` (rewrite)
- Modify: `lib/features/admin/clubs_screen.dart`
- Test: `test/domain/labels_test.dart`, `test/features/federation_card_test.dart`, `test/features/clubs_screen_test.dart`

**Interfaces:**
- Consumes: Task 4 `FederationSyncProgress`, `FederationSync.discover`, `Api.federationSyncProgress`; Task 6 `FederationCard`, `VenueSlugDialog`, `_Harness`.
- Produces:
  - In `labels.dart`: `String czechCount(int n, String one, String few, String many)`, `const String teamsLoadingLabel`, `String federationProgressLabel(FederationSyncProgress p)`.
  - `FederationCard({…, Future<FederationSyncProgress> Function() syncProgress = Api.federationSyncProgress})`.
  - `ClubsScreen({…, Future<FederationSyncProgress> Function() syncProgress = Api.federationSyncProgress})`.
  - Card internals Task 8 uses: `_afterRequest({bool discovery = false})`, `Future<bool> _requestDiscovery()`, `bool _discovering(FederationSync sync)` (false once the row's discovery report is a failure no request is waiting past), `bool? _enabledWanted`.
  - In the test harness: `_Harness.push(FederationSync row)`, which delivers a row the way the Realtime stream does, without a refetch. Task 8 uses it.

- [ ] **Step 1: Write the failing tests**

In `test/domain/labels_test.dart` replace the file's end:
```dart
      expect(rentalMoreDatesLabel(5), '…a dalších 5 termínů');
    });
  });
}
```
with:
```dart
      expect(rentalMoreDatesLabel(5), '…a dalších 5 termínů');
    });
  });

  group('czechCount', () {
    test('1, 2–4, and everything else', () {
      expect(czechCount(1, 'zápas', 'zápasy', 'zápasů'), '1 zápas');
      expect(czechCount(2, 'zápas', 'zápasy', 'zápasů'), '2 zápasy');
      expect(czechCount(4, 'zápas', 'zápasy', 'zápasů'), '4 zápasy');
      expect(czechCount(5, 'zápas', 'zápasy', 'zápasů'), '5 zápasů');
      expect(czechCount(0, 'zápas', 'zápasy', 'zápasů'), '0 zápasů');
      expect(czechCount(22, 'zápas', 'zápasy', 'zápasů'), '22 zápasů');
    });
  });

  group('federationProgressLabel (0047)', () {
    test('what is left, the non-zero counts only, the verb agreeing', () {
      expect(
        federationProgressLabel(const FederationSyncProgress(
            matches: 12, competitions: 2, venues: 1)),
        'Synchronizuje se… zbývá 12 zápasů, 2 soutěže a 1 kuželna',
      );
      expect(federationProgressLabel(const FederationSyncProgress(matches: 3)),
          'Synchronizuje se… zbývají 3 zápasy');
      expect(federationProgressLabel(const FederationSyncProgress(matches: 1)),
          'Synchronizuje se… zbývá 1 zápas');
      expect(
        federationProgressLabel(
            const FederationSyncProgress(competitions: 2, venues: 5)),
        'Synchronizuje se… zbývají 2 soutěže a 5 kuželen',
      );
      expect(federationProgressLabel(const FederationSyncProgress(venues: 1)),
          'Synchronizuje se… zbývá 1 kuželna');
    });

    test('a discovery reads as loading the teams', () {
      expect(
        federationProgressLabel(
            const FederationSyncProgress(discover: 1, matches: 4)),
        'Načítají se týmy z webu…',
      );
      expect(teamsLoadingLabel, 'Načítají se týmy z webu…');
    });
  });
}
```

In `test/features/federation_card_test.dart` replace the first line:
```dart
import 'package:flutter/material.dart';
```
with:
```dart
import 'dart:async';

import 'package:flutter/material.dart';
```
and replace the whole `_Harness` class (with its doc comment):
```dart
/// The ČKA card on its own (Správa → Oddíly). Each (re)build of the sync
/// row's or the teams' provider takes the next of [rows] / [teams], the
/// last one repeating, so a test sees what the card fetches again.
class _Harness {
  _Harness({List<FederationSync>? rows, List<List<Team>>? teams})
      : rows = rows ?? const [FederationSync.none],
        teams = teams ?? const [<Team>[]];

  final List<FederationSync> rows;
  final List<List<Team>> teams;
  int rowBuilds = 0;
  int teamBuilds = 0;
  final saved = <(String, bool)>[];
  int discoveries = 0;
  int syncs = 0;

  /// Thrown by the next saves instead of saving.
  Object? saveError;

  static T _nth<T>(List<T> list, int i) =>
      list[i < list.length ? i : list.length - 1];

  Widget app() => ProviderScope(
        overrides: [
          federationSyncProvider
              .overrideWith((ref) => Stream.value(_nth(rows, rowBuilds++))),
          teamsProvider
              .overrideWith((ref) => Stream.value(_nth(teams, teamBuilds++))),
          clubsProvider.overrideWith((ref) => Stream.value(const <Club>[])),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: FederationCard(
                saveFederation: (slug, enabled) async {
                  final error = saveError;
                  if (error != null) throw error;
                  saved.add((slug, enabled));
                },
                discoverTeams: () async => discoveries++,
                syncNow: () async => syncs++,
              ),
            ),
          ),
        ),
      );
}
```
with:
```dart
/// The ČKA card on its own (Správa → Oddíly). Each (re)build of the sync
/// row's or the teams' provider takes the next of [rows] / [teams], and
/// each look at the progress the next of [progress] — the last one
/// repeating — so a test sees what the card fetches again, and when.
/// [push] is the row's Realtime stream: a newer row without a refetch.
class _Harness {
  _Harness({
    List<FederationSync>? rows,
    List<List<Team>>? teams,
    List<FederationSyncProgress>? progress,
  })  : rows = rows ?? const [FederationSync.none],
        teams = teams ?? const [<Team>[]],
        progress = progress ?? const [FederationSyncProgress.idle];

  final List<FederationSync> rows;
  final List<List<Team>> teams;
  final List<FederationSyncProgress> progress;
  int rowBuilds = 0;
  int teamBuilds = 0;
  int looks = 0;
  final saved = <(String, bool)>[];
  int discoveries = 0;
  int syncs = 0;
  final _live = StreamController<FederationSync>.broadcast();

  /// Thrown by the next saves instead of saving.
  Object? saveError;

  /// Delivers [row] as Realtime does: the card sees it without a refetch.
  void push(FederationSync row) => _live.add(row);

  static T _nth<T>(List<T> list, int i) =>
      list[i < list.length ? i : list.length - 1];

  Widget app() => ProviderScope(
        overrides: [
          federationSyncProvider.overrideWith((ref) async* {
            yield _nth(rows, rowBuilds++);
            yield* _live.stream;
          }),
          teamsProvider
              .overrideWith((ref) => Stream.value(_nth(teams, teamBuilds++))),
          clubsProvider.overrideWith((ref) => Stream.value(const <Club>[])),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: FederationCard(
                saveFederation: (slug, enabled) async {
                  final error = saveError;
                  if (error != null) throw error;
                  saved.add((slug, enabled));
                },
                discoverTeams: () async => discoveries++,
                syncNow: () async => syncs++,
                syncProgress: () async => _nth(progress, looks++),
              ),
            ),
          ),
        ),
      );
}
```

and add after the `group('normal view', …)` block, before `main()`'s closing `}`:
```dart

  group('progress (0047)', () {
    testWidgets(
        'a running sync spins with what is left; Poslední synchronizace '
        'stays below, muted', (tester) async {
      await _pump(
        tester,
        _Harness(rows: [
          _on
        ], progress: [
          const FederationSyncProgress(matches: 12, competitions: 2, venues: 1),
        ]),
      );

      expect(find.text('Synchronizuje se… zbývá 12 zápasů, 2 soutěže a 1 kuželna'),
          findsOneWidget);
      final spinner = find.byType(CircularProgressIndicator);
      expect(tester.getSize(spinner), const Size(14, 14));
      expect(tester.widget<CircularProgressIndicator>(spinner).strokeWidth, 2);
      final last = tester
          .widget<Text>(find.text('Poslední synchronizace: Zatím neproběhla'));
      final scheme =
          Theme.of(tester.element(find.byType(FederationCard))).colorScheme;
      expect(last.style?.color, scheme.onSurfaceVariant);
    });

    testWidgets('a running discovery reads Načítají se týmy z webu…',
        (tester) async {
      await _pump(
        tester,
        _Harness(rows: [
          _on
        ], progress: [
          const FederationSyncProgress(discover: 1, matches: 4),
        ]),
      );

      expect(find.text('Načítají se týmy z webu…'), findsOneWidget);
    });

    testWidgets(
        'looks every 5 s while anything is pending, stops at 0 and fetches '
        'the row again', (tester) async {
      final h = _Harness(rows: [
        _on
      ], progress: [
        const FederationSyncProgress(matches: 2),
        const FederationSyncProgress(matches: 1),
        FederationSyncProgress.idle,
      ]);
      await _pump(tester, h);
      expect(h.looks, 1);
      expect(find.text('Synchronizuje se… zbývají 2 zápasy'), findsOneWidget);

      await tester.pump(const Duration(seconds: 5));
      expect(h.looks, 2);
      expect(find.text('Synchronizuje se… zbývá 1 zápas'), findsOneWidget);

      await tester.pump(const Duration(seconds: 5));
      await tester.pump();
      expect(h.looks, 3);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(h.rowBuilds, 2);

      await tester.pump(const Duration(seconds: 30));
      expect(h.looks, 3);
    });

    testWidgets('after Synchronizovat teď it looks for 60 s even at 0',
        (tester) async {
      final h = _Harness(rows: [_on]);
      await _pump(tester, h);
      expect(h.looks, 1);

      await tester.tap(find.widgetWithText(OutlinedButton, 'Synchronizovat teď'));
      await tester.pump();
      expect(h.syncs, 1);
      expect(h.looks, 2);

      for (var i = 0; i < 11; i++) {
        await tester.pump(const Duration(seconds: 5));
      }
      expect(h.looks, 13);
      await tester.pump(const Duration(seconds: 30));
      expect(h.looks, 13);
    });

    testWidgets('no look while the app is in the background; one on return',
        (tester) async {
      final h = _Harness(
          rows: [_on], progress: [const FederationSyncProgress(matches: 3)]);
      await _pump(tester, h);
      expect(h.looks, 1);

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump(const Duration(seconds: 30));
      expect(h.looks, 1);

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      expect(h.looks, 2);
      await tester.pump(const Duration(seconds: 5));
      expect(h.looks, 3);
    });

    testWidgets('leaves no timer running once disposed', (tester) async {
      final h = _Harness(
          rows: [_on], progress: [const FederationSyncProgress(matches: 3)]);
      await _pump(tester, h);
      expect(h.looks, 1);

      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 30));
      // testWidgets itself fails a test that ends with a timer pending.
      expect(h.looks, 1);
    });

    testWidgets(
        'Přenačíst týmy z webu reads Načítají se týmy z webu… until its '
        'report is in', (tester) async {
      final h = _Harness(
        rows: [
          FederationSync(
            venueSlug: 'tj-sokol-brno-iv',
            enabled: true,
            discover: FederationDiscoverReport(
                teams: 4, at: DateTime.utc(2026, 9, 24, 8)),
          ),
          FederationSync(
            venueSlug: 'tj-sokol-brno-iv',
            enabled: true,
            discover: FederationDiscoverReport(
                teams: 5, at: DateTime.utc(2026, 9, 25, 8)),
          ),
        ],
        progress: [
          FederationSyncProgress.idle,
          const FederationSyncProgress(discover: 1),
          FederationSyncProgress.idle,
        ],
      );
      await _pump(tester, h);

      await tester.tap(find.widgetWithText(OutlinedButton, 'Přenačíst týmy z webu'));
      await tester.pump();
      expect(h.discoveries, 1);
      expect(find.text('Načítají se týmy z webu…'), findsOneWidget);

      await tester.pump(const Duration(seconds: 5));
      await tester.pump();
      await tester.pump();
      expect(find.text('Načítají se týmy z webu…'), findsNothing);
      expect(find.byType(CircularProgressIndicator), findsNothing);
    });

    testWidgets(
        'a failed discovery ends Načítají se týmy z webu… once its error is '
        'in the row, though its job still counts while it waits to retry',
        (tester) async {
      final h = _Harness(rows: [
        _on
      ], progress: [
        FederationSyncProgress.idle,
        const FederationSyncProgress(discover: 1),
      ]);
      await _pump(tester, h);

      await tester.tap(find.widgetWithText(OutlinedButton, 'Přenačíst týmy z webu'));
      await tester.pump();
      expect(find.text('Načítají se týmy z webu…'), findsOneWidget);

      // A well-formed slug of no kuželna: HTTP 404. jobOutcome re-arms the
      // job at +1, +2, +4 and +8 min, and every look still counts it.
      const error =
          'federation_discover: GET /detail-kuzelny/tj-sokol-brno-iv: HTTP 404';
      h.push(FederationSync(
        venueSlug: 'tj-sokol-brno-iv',
        enabled: true,
        lastError: error,
        discover: FederationDiscoverReport(
            error: error, at: DateTime.utc(2026, 9, 25, 8)),
      ));
      await tester.pump();
      await tester.pump(const Duration(seconds: 5));

      expect(h.looks, 3);
      expect(find.text('Načítají se týmy z webu…'), findsNothing);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.text('Chyba: $error'), findsOneWidget);
    });
  });
```

In `test/features/clubs_screen_test.dart`, in the `app()` helper, replace:
```dart
            syncNow: syncNow ?? () async {},
```
with:
```dart
            syncNow: syncNow ?? () async {},
            syncProgress: () async => FederationSyncProgress.idle,
```

- [ ] **Step 2: Run them to verify they fail**

Run: `flutter test test/domain/labels_test.dart test/features/federation_card_test.dart test/features/clubs_screen_test.dart`
Expected: FAIL to compile — `Method not found: 'czechCount'`, `Undefined name 'teamsLoadingLabel'`, `No named parameter with the name 'syncProgress'`.

- [ ] **Step 3: Implement**

Append to `lib/domain/labels.dart`:
```dart

/// [n] with its noun in the right Czech form: [one] for 1, [few] for 2–4,
/// [many] for anything else (0, 5+, and 22 too — written in digits it takes
/// the genitive).
String czechCount(int n, String one, String few, String many) =>
    '$n ${n == 1 ? one : n >= 2 && n <= 4 ? few : many}';

/// The ČKA card's progress line while a discovery runs.
const teamsLoadingLabel = 'Načítají se týmy z webu…';

/// The ČKA card's progress line while federation jobs are still to run
/// (0047 `federation_sync_progress`): „Synchronizuje se… zbývá 12 zápasů,
/// 2 soutěže a 1 kuželna“ — only the non-zero counts, the verb agreeing
/// with the first of them. A discovery reads [teamsLoadingLabel].
String federationProgressLabel(FederationSyncProgress p) {
  if (p.discover > 0) return teamsLoadingLabel;
  final counts = [
    if (p.matches > 0)
      (p.matches, czechCount(p.matches, 'zápas', 'zápasy', 'zápasů')),
    if (p.competitions > 0)
      (
        p.competitions,
        czechCount(p.competitions, 'soutěž', 'soutěže', 'soutěží'),
      ),
    if (p.venues > 0)
      (p.venues, czechCount(p.venues, 'kuželna', 'kuželny', 'kuželen')),
  ];
  if (counts.isEmpty) return 'Synchronizuje se…';
  final first = counts.first.$1;
  final verb = first >= 2 && first <= 4 ? 'zbývají' : 'zbývá';
  final parts = [for (final (_, label) in counts) label];
  final list = parts.length == 1
      ? parts.single
      : '${parts.sublist(0, parts.length - 1).join(', ')} a ${parts.last}';
  return 'Synchronizuje se… $verb $list';
}
```

Replace the whole of `lib/features/admin/widgets/federation_card.dart` with:
```dart
/// Správa → Oddíly: the ČKA results-service card — the alley's kuželna on
/// vysledky.kuzelky.cz (read-only, changed behind a pencil), automatic sync
/// on/off (saved at once), a one-off team discovery or sync run, and while
/// federation jobs are still to run, a spinning line that says what is
/// left (0047 `federation_sync_progress`).
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/ui.dart';
import '../../../data/providers.dart';
import '../../../domain/labels.dart';
import '../../../domain/models.dart';
import 'venue_slug_field.dart';

class FederationCard extends ConsumerStatefulWidget {
  const FederationCard({
    super.key,
    this.saveFederation = _defaultSave,
    this.discoverTeams = Api.requestFederationDiscovery,
    this.syncNow = Api.requestFederationSync,
    this.syncProgress = Api.federationSyncProgress,
  });

  /// Injectable so a widget test can drive the card without the backend.
  final Future<void> Function(String venueSlug, bool enabled) saveFederation;
  final Future<void> Function() discoverTeams;
  final Future<void> Function() syncNow;
  final Future<FederationSyncProgress> Function() syncProgress;

  static Future<void> _defaultSave(String venueSlug, bool enabled) =>
      Api.setFederationSync(venueSlug: venueSlug, enabled: enabled);

  @override
  ConsumerState<FederationCard> createState() => _FederationCardState();
}

class _FederationCardState extends ConsumerState<FederationCard>
    with WidgetsBindingObserver {
  static const _pollEvery = Duration(seconds: 5);

  /// Looks after a request even while nothing is pending yet — its jobs may
  /// not be due, or be done before the first look: 12 × 5 s = 60 s.
  static const _graceLooks = 12;

  /// Looks after a discovery's jobs are done, while its report is on its
  /// way to the row: 2 × 5 s.
  static const _reportLooks = 2;

  FederationSyncProgress _progress = FederationSyncProgress.idle;
  Timer? _timer;
  bool _looking = false;
  bool _foreground = true;
  int _graceLeft = 0;

  /// A request since the row was last fetched: it is fetched again at 0
  /// even when no look saw the run pending.
  bool _refreshAtZero = false;

  /// A discovery ran since the last fetch: its teams and clubs are fetched
  /// again with the row.
  bool _discoveryRan = false;

  /// A discovery was asked for and the row still holds the report from
  /// before it ([_reportBefore] is that report's `at`).
  bool _awaitingDiscovery = false;
  DateTime? _reportBefore;

  /// The switch's value from a tap until the row echoes it — the save runs
  /// at once, the echo comes over Realtime a moment later. null: the row's.
  bool? _enabledWanted;
  bool _savingEnabled = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // One look on opening: an admin coming back to a running first sync
    // sees it still going.
    _look();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _timer?.cancel();
    super.dispose();
  }

  /// No looks behind the admin's back: the background stops them, the
  /// foreground looks again at once.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.resumed:
        if (_foreground) return;
        _foreground = true;
        _look();
      case AppLifecycleState.hidden:
      case AppLifecycleState.paused:
      case AppLifecycleState.detached:
        _foreground = false;
        _timer?.cancel();
        _timer = null;
      case AppLifecycleState.inactive:
        break;
    }
  }

  /// A run was just requested: look now, then every 5 s for up to a minute
  /// even while nothing is pending yet.
  void _afterRequest({bool discovery = false}) {
    _graceLeft = _graceLooks;
    _refreshAtZero = true;
    if (discovery) {
      _discoveryRan = true;
      setState(() {
        _awaitingDiscovery = true;
        _reportBefore = ref.read(federationSyncProvider).value?.discover?.at;
      });
    }
    _look();
  }

  Future<void> _look() async {
    _timer?.cancel();
    _timer = null;
    // A look already under way schedules the next one itself.
    if (_looking || !_foreground) return;
    _looking = true;
    FederationSyncProgress? next;
    try {
      next = await widget.syncProgress();
    } catch (_) {
      // Offline for a moment: the line stays, the next look asks again.
    }
    _looking = false;
    if (!mounted) return;
    if (_graceLeft > 0) _graceLeft--;
    if (next != null) {
      if (next.discover > 0) _discoveryRan = true;
      if (next.pending) {
        // Seen running: from here on the looks stop at 0.
        _graceLeft = 0;
      } else if (_progress.pending || _refreshAtZero) {
        _refreshAtZero = false;
        if (_awaitingDiscovery && _graceLeft < _reportLooks) {
          _graceLeft = _reportLooks;
        }
        ref.invalidate(federationSyncProvider);
        if (_discoveryRan) {
          _discoveryRan = false;
          ref
            ..invalidate(teamsProvider)
            ..invalidate(clubsProvider);
        }
      }
      if (next != _progress) setState(() => _progress = next!);
    }
    if (_awaitingDiscovery && _graceLeft == 0 && !_progress.pending) {
      setState(() => _awaitingDiscovery = false);
    }
    if (_foreground && (_progress.pending || _graceLeft > 0)) {
      _timer = Timer(_pollEvery, _look);
    }
  }

  /// A discovery is running, or its report is not in the row yet. A failed
  /// discovery's job only waits to retry: jobOutcome re-arms it at +1, +2,
  /// +4 and +8 min, and federation_sync_progress counts each as leased. So
  /// once the row holds its error, that error shows, not a quarter of an
  /// hour's loader. A newer request still waits for its own report.
  bool _discovering(FederationSync sync) {
    final report = sync.discover;
    if (_awaitingDiscovery && report?.at != _reportBefore) {
      _awaitingDiscovery = false;
    }
    if (_awaitingDiscovery) return true;
    return _progress.discover > 0 && !(report?.failed ?? false);
  }

  /// What the progress line counts: the discovery only while
  /// [_discovering] — a failed one waiting to retry is left out.
  FederationSyncProgress _shownProgress(bool discovering) =>
      discovering || _progress.discover == 0
          ? _progress
          : FederationSyncProgress(
              competitions: _progress.competitions,
              matches: _progress.matches,
              venues: _progress.venues,
            );

  Future<bool> _requestDiscovery() async {
    final ok = await tryAction(
      context,
      widget.discoverTeams,
      errorText: friendlyDbError,
    );
    if (ok && mounted) _afterRequest(discovery: true);
    return ok;
  }

  Future<void> _sync() async {
    final ok = await tryAction(
      context,
      widget.syncNow,
      success: 'Synchronizace spuštěna.',
      errorText: friendlyDbError,
    );
    if (ok && mounted) _afterRequest();
  }

  Future<void> _setEnabled(FederationSync sync, bool enabled) async {
    setState(() {
      _enabledWanted = enabled;
      _savingEnabled = true;
    });
    final ok = await tryAction(
      context,
      () => widget.saveFederation(sync.venueSlug, enabled),
      errorText: friendlyDbError,
    );
    if (!mounted) return;
    setState(() {
      _savingEnabled = false;
      if (!ok) _enabledWanted = null;
    });
  }

  Future<void> _editSlug(FederationSync sync, bool enabled) =>
      showDialog<bool>(
        context: context,
        builder: (_) => VenueSlugDialog(
          initial: sync.venueSlug,
          save: (slug) => widget.saveFederation(slug, enabled),
        ),
      );

  /// "čt 23.4. 9:05" — local time, reusing core/ui.dart's date label and
  /// [HourMinute]'s own display instead of hand-rolling another format.
  String _lastSuccessLabel(DateTime? at) {
    if (at == null) return 'Zatím neproběhla';
    final local = at.toLocal();
    final day = Day.fromDateTime(local);
    final time = HourMinute(local.hour, local.minute);
    return '${dayLabel(day)} ${time.display()}';
  }

  @override
  Widget build(BuildContext context) {
    final loaded = ref.watch(federationSyncProvider);
    final sync = loaded.value;
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Výsledkový servis ČKA', style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            if (sync != null)
              ..._settings(sync)
            else if (loaded.hasError)
              Text(
                friendlyDbError(loaded.error!),
                style: TextStyle(color: theme.colorScheme.error),
              )
            else
              const Text('Načítám…'),
          ],
        ),
      ),
    );
  }

  List<Widget> _settings(FederationSync sync) {
    // The tapped value stays until the row catches up with it.
    if (_enabledWanted == sync.enabled) _enabledWanted = null;
    final enabled = _enabledWanted ?? sync.enabled;
    final discovering = _discovering(sync);
    final progress = _shownProgress(discovering);
    final busy = discovering || progress.pending;
    final theme = Theme.of(context);
    return [
      const Text(
        'Zápasy a výsledky týmů, které hrají na této kuželně, se stahují '
        'z vysledky.kuzelky.cz.',
      ),
      const SizedBox(height: 8),
      Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Kuželna na webu', style: theme.textTheme.labelMedium),
                Text(sync.configured
                    ? 'detail-kuzelny/${sync.venueSlug}'
                    : 'Zatím nenastavená'),
              ],
            ),
          ),
          IconButton(
            icon: const Icon(Icons.edit_outlined),
            tooltip: 'Změnit kuželnu',
            onPressed: () => _editSlug(sync, enabled),
          ),
        ],
      ),
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: const Text('Stahovat automaticky'),
        value: enabled,
        onChanged: _savingEnabled || !sync.configured
            ? null
            : (v) => _setEnabled(sync, v),
      ),
      const SizedBox(height: 8),
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          OutlinedButton(
            onPressed: sync.configured ? _requestDiscovery : null,
            child: const Text('Přenačíst týmy z webu'),
          ),
          OutlinedButton(
            onPressed: sync.configured && enabled ? _sync : null,
            child: const Text('Synchronizovat teď'),
          ),
        ],
      ),
      const SizedBox(height: 8),
      if (busy)
        Row(
          children: [
            const SizedBox.square(
              dimension: 14,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(discovering
                  ? teamsLoadingLabel
                  : federationProgressLabel(progress)),
            ),
          ],
        ),
      Text(
        'Poslední synchronizace: ${_lastSuccessLabel(sync.lastSuccessAt)}',
        style: busy
            ? theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant)
            : null,
      ),
      if (sync.lastError != null)
        Text(
          'Chyba: ${sync.lastError}',
          style: TextStyle(color: theme.colorScheme.error),
        ),
    ];
  }
}
```

In `lib/features/admin/clubs_screen.dart` replace:
```dart
    this.syncNow = Api.requestFederationSync,
    this.updateTeam = _defaultUpdateTeam,
  });
```
with:
```dart
    this.syncNow = Api.requestFederationSync,
    this.syncProgress = Api.federationSyncProgress,
    this.updateTeam = _defaultUpdateTeam,
  });
```
replace:
```dart
  final Future<void> Function() syncNow;
  final Future<void> Function(Team team,
```
with:
```dart
  final Future<void> Function() syncNow;
  final Future<FederationSyncProgress> Function() syncProgress;
  final Future<void> Function(Team team,
```
and in `build` replace:
```dart
                syncNow: syncNow,
              ),
```
with:
```dart
                syncNow: syncNow,
                syncProgress: syncProgress,
              ),
```

- [ ] **Step 4: Run them to verify they pass**

Run: `flutter test test/domain/labels_test.dart test/features/federation_card_test.dart test/features/clubs_screen_test.dart`
Expected: `All tests passed!` (a test that ends with a timer pending fails on its own, so this also proves every poll is cancelled on dispose)

Run: `flutter analyze`
Expected: `No issues found!`

- [ ] **Step 5: Commit**

```bash
git add lib/domain/labels.dart lib/features/admin/widgets/federation_card.dart lib/features/admin/clubs_screen.dart test/domain/labels_test.dart test/features/federation_card_test.dart test/features/clubs_screen_test.dart
git commit -m "$(cat <<'EOF'
feat(federation): the ČKA card spins with what is left while a sync or discovery runs

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 8: ČKA setup wizard

**Files:**
- Modify: `lib/domain/labels.dart`
- Create: `lib/features/admin/widgets/federation_wizard.dart`
- Modify: `lib/features/admin/widgets/federation_card.dart`
- Modify: `README.md`
- Test: `test/domain/labels_test.dart`, `test/features/federation_card_test.dart`

**Interfaces:**
- Consumes:
  - From Task 3: `set_federation_sync` drops `last_report.discover` when the kuželna changes.
  - From Task 4: `FederationDiscoverReport` (`at`, `failed`).
  - From Task 6: `venueSlugFromInput`, `venueSlugInputError`, `VenueSlugField`, `venueSlugHelp`.
  - From Task 7: `czechCount`; the card's `_afterRequest`, `_requestDiscovery`, `_discovering`, `_enabledWanted`; the test harness's `_Harness.push`.
  - `compareCzech` from `lib/domain/collation.dart`.
- Produces:
  - In `labels.dart`: `String discoveryClubsLabel(FederationDiscoverReport r)` and `String discoveryTeamsLabel(FederationDiscoverReport r)`.
  - `FederationWizard({required FederationSync sync, required List<Team> teams, required bool discovering, required Future<bool> Function(String slug) saveSlug, required Future<bool> Function() discover, required Future<bool> Function() enable})`, with `static int stepFor(FederationSync sync, List<Team> teams)`. That is 0 without a slug; 1 without teams or without a successful discovery report; else 2.
  - After step 1 saves another kuželna, step 2 ignores the report the row held at the save (matched by its `at`) until a newer one arrives (plan decision 14).
  - `FederationCard` shows the wizard while `!_setupDone && !sync.enabled && sync.lastRunAt == null`.

- [ ] **Step 1: Write the failing tests**

In `test/domain/labels_test.dart` add before `main()`'s closing `}` (after the `federationProgressLabel (0047)` group):
```dart

  group('discovery summary (0047)', () {
    test('counts the oddíly and names the new ones, Czech-sorted', () {
      expect(
        discoveryClubsLabel(
            const FederationDiscoverReport(clubsLinked: ['Sokol Brno IV'])),
        '1 oddíl',
      );
      expect(
        discoveryClubsLabel(const FederationDiscoverReport(
          clubsLinked: ['Sokol Brno IV'],
          clubsCreated: ['TJ Sokol Husovice', 'KS Devítka Brno'],
        )),
        '3 oddíly (2 nové: KS Devítka Brno, TJ Sokol Husovice)',
      );
      expect(
        discoveryClubsLabel(const FederationDiscoverReport(
          clubsLinked: ['A', 'B', 'C', 'D'],
          clubsCreated: ['Čáslav'],
        )),
        '5 oddílů (1 nový: Čáslav)',
      );
    });

    test('counts the teams in their soutěže — ve before dvou…čtyřech', () {
      expect(
        discoveryTeamsLabel(
            const FederationDiscoverReport(teams: 1, competitions: 1)),
        '1 tým v 1 soutěži',
      );
      expect(
        discoveryTeamsLabel(
            const FederationDiscoverReport(teams: 5, competitions: 2)),
        '5 týmů ve 2 soutěžích',
      );
      expect(
        discoveryTeamsLabel(
            const FederationDiscoverReport(teams: 3, competitions: 5)),
        '3 týmy v 5 soutěžích',
      );
      expect(
        discoveryTeamsLabel(
            const FederationDiscoverReport(teams: 12, competitions: 12)),
        '12 týmů ve 12 soutěžích',
      );
    });
  });
```

In `test/features/federation_card_test.dart` add the import after the `federation_card.dart` import:
```dart
import 'package:rezervator/features/admin/widgets/venue_slug_field.dart';
```
and add after the `group('progress (0047)', …)` block, before `main()`'s closing `}`:
```dart

  group('setup wizard (0047)', () {
    const slugOnly = FederationSync(venueSlug: 'tj-sokol-brno-iv');
    const team = Team(
      id: 't1',
      name: 'TJ Sokol Brno IV A',
      clubId: 'c1',
      competitionName: 'Jihomoravská divize',
    );
    // This kuželna's teams are loaded: a successful discovery report.
    final discovered = FederationSync(
      venueSlug: 'tj-sokol-brno-iv',
      discover: FederationDiscoverReport(
        teams: 1,
        competitions: 1,
        created: 1,
        clubsLinked: const ['Sokol Brno IV'],
        at: DateTime.utc(2026, 9, 25, 8),
      ),
    );
    const notFound =
        'federation_discover: GET /detail-kuzelny/tj-sokol-brno-iv: HTTP 404';

    testWidgets('a new alley starts on step 1, the kuželna', (tester) async {
      await _pump(tester, _Harness());

      expect(find.text('Kuželna na webu ČKA'), findsOneWidget);
      expect(find.text(venueSlugHelp), findsOneWidget);
      expect(find.widgetWithText(FilledButton, 'Pokračovat'), findsOneWidget);
      expect(find.text('Stahovat automaticky'), findsNothing);
    });

    testWidgets('a saved kuželna without teams opens step 2', (tester) async {
      await _pump(tester, _Harness(rows: [slugOnly]));

      expect(find.text('Oddíly a týmy'), findsOneWidget);
      expect(
        find.text('Načteme oddíly, které na kuželně hrají, a jejich týmy. '
            'Chybějící oddíly založíme.'),
        findsOneWidget,
      );
      expect(find.widgetWithText(FilledButton, 'Načíst oddíly a týmy'),
          findsOneWidget);
    });

    testWidgets('a saved kuželna with its discovered teams opens step 3',
        (tester) async {
      await _pump(tester, _Harness(rows: [discovered], teams: [[team]]));

      expect(find.text('Zapnout stahování'), findsOneWidget);
      expect(
        find.text('Stáhnou se všechny zápasy a výsledky těchto týmů. Zápasy '
            'z rozpisu se spárují a zůstanou. První stažení trvá asi půl '
            'hodiny, pak se vše aktualizuje samo.'),
        findsOneWidget,
      );
    });

    testWidgets(
        'teams without a discovery of this kuželna open step 2 — a moved '
        'kuželna drops the old report', (tester) async {
      await _pump(tester, _Harness(rows: [slugOnly], teams: [[team]]));

      expect(find.text('Oddíly a týmy'), findsOneWidget);
      expect(find.widgetWithText(FilledButton, 'Načíst oddíly a týmy'),
          findsOneWidget);
      expect(find.text('Zapnout stahování'), findsNothing);
    });

    testWidgets(
        'step 1 saves the slug of a pasted address, the sync still off, '
        'and moves on', (tester) async {
      final h = _Harness();
      await _pump(tester, h);

      await tester.enterText(find.byType(TextField),
          ' https://vysledky.kuzelky.cz/detail-kuzelny/TJ-Sokol-Brno-IV/?tab=info#mapa ');
      await tester.tap(find.widgetWithText(FilledButton, 'Pokračovat'));
      await tester.pump();

      expect(h.saved, [('tj-sokol-brno-iv', false)]);
      expect(find.text('Oddíly a týmy'), findsOneWidget);
    });

    testWidgets('step 1 refuses the address of another page, inline',
        (tester) async {
      final h = _Harness();
      await _pump(tester, h);

      await tester.enterText(find.byType(TextField),
          'https://vysledky.kuzelky.cz/detail-klubu/ks-devitka-brno');
      await tester.tap(find.widgetWithText(FilledButton, 'Pokračovat'));
      await tester.pump();

      expect(h.saved, isEmpty);
      expect(
        find.text('Tohle není adresa kuželny — zkopíruj adresu stránky, která '
            'obsahuje /detail-kuzelny/.'),
        findsOneWidget,
      );
      expect(find.text('Kuželna na webu ČKA'), findsOneWidget);
    });

    testWidgets(
        'step 2 spins while the discovery runs, then sums up what it found',
        (tester) async {
      final report = FederationDiscoverReport(
        teams: 5,
        competitions: 2,
        created: 5,
        clubsLinked: const ['Sokol Brno IV'],
        clubsCreated: const ['TJ Sokol Husovice', 'KS Devítka Brno'],
        at: DateTime.utc(2026, 9, 25, 8),
      );
      final h = _Harness(
        rows: [
          slugOnly,
          FederationSync(venueSlug: 'tj-sokol-brno-iv', discover: report),
        ],
        teams: [const [], const [team]],
        progress: [
          FederationSyncProgress.idle,
          const FederationSyncProgress(discover: 1),
          FederationSyncProgress.idle,
        ],
      );
      await _pump(tester, h);

      await tester.tap(find.widgetWithText(FilledButton, 'Načíst oddíly a týmy'));
      await tester.pump();
      expect(h.discoveries, 1);
      expect(find.text('Načítají se oddíly a týmy z webu…'), findsOneWidget);
      expect(find.widgetWithText(FilledButton, 'Načíst oddíly a týmy'),
          findsNothing);

      await tester.pump(const Duration(seconds: 5));
      await tester.pump();
      await tester.pump();
      expect(find.text('Načítají se oddíly a týmy z webu…'), findsNothing);
      expect(find.text('3 oddíly (2 nové: KS Devítka Brno, TJ Sokol Husovice)'),
          findsOneWidget);
      expect(find.text('5 týmů ve 2 soutěžích'), findsOneWidget);
      expect(find.widgetWithText(OutlinedButton, 'Načíst znovu'), findsOneWidget);

      await tester.tap(find.widgetWithText(FilledButton, 'Pokračovat'));
      await tester.pump();
      expect(find.text('Zapnout stahování'), findsOneWidget);
    });

    testWidgets(
        'reopened while a failed discovery waits to retry, step 2 says why '
        'and offers Načíst znovu', (tester) async {
      const error =
          'federation_discover: na stránce kuželny nejsou žádné kluby';
      final h = _Harness(
        rows: [
          FederationSync(
            venueSlug: 'tj-sokol-brno-iv',
            discover: FederationDiscoverReport(
              error: error,
              at: DateTime.utc(2026, 9, 25, 8),
            ),
          ),
        ],
        // The re-armed job still counts (plan decision 7).
        progress: [const FederationSyncProgress(discover: 1)],
      );
      await _pump(tester, h);

      expect(find.text('Načítají se oddíly a týmy z webu…'), findsNothing);
      expect(find.text('Načtení se nepovedlo: $error'), findsOneWidget);
      final next = tester.widget<FilledButton>(
          find.widgetWithText(FilledButton, 'Pokračovat'));
      expect(next.onPressed, isNull);

      await tester.tap(find.widgetWithText(OutlinedButton, 'Načíst znovu'));
      await tester.pump();
      expect(h.discoveries, 1);
      // A new request waits for its own report again.
      expect(find.text('Načítají se oddíly a týmy z webu…'), findsOneWidget);
    });

    testWidgets(
        'a discovery that fails ends the loader as soon as its error is in '
        'the row, though its job still counts while it waits to retry',
        (tester) async {
      final h = _Harness(
        rows: [slugOnly],
        progress: [
          FederationSyncProgress.idle,
          const FederationSyncProgress(discover: 1),
        ],
      );
      await _pump(tester, h);

      await tester.tap(find.widgetWithText(FilledButton, 'Načíst oddíly a týmy'));
      await tester.pump();
      expect(find.text('Načítají se oddíly a týmy z webu…'), findsOneWidget);

      // A well-formed slug of no kuželna: HTTP 404. jobOutcome re-arms the
      // job at +1, +2, +4 and +8 min, and every look still counts it.
      h.push(FederationSync(
        venueSlug: 'tj-sokol-brno-iv',
        discover: FederationDiscoverReport(
          error: notFound,
          at: DateTime.utc(2026, 9, 25, 8),
        ),
      ));
      await tester.pump();
      await tester.pump(const Duration(seconds: 5));

      expect(h.looks, 3);
      expect(find.text('Načítají se oddíly a týmy z webu…'), findsNothing);
      expect(find.text('Načtení se nepovedlo: $notFound'), findsOneWidget);
      expect(find.widgetWithText(OutlinedButton, 'Načíst znovu'), findsOneWidget);
      expect(find.widgetWithText(TextButton, 'Zpět'), findsOneWidget);
    });

    testWidgets('Zpět on step 2 goes back to the kuželna, its slug filled in',
        (tester) async {
      await _pump(tester, _Harness(rows: [slugOnly]));

      await tester.tap(find.widgetWithText(TextButton, 'Zpět'));
      await tester.pump();

      expect(find.text('Kuželna na webu ČKA'), findsOneWidget);
      expect(find.widgetWithText(TextField, 'tj-sokol-brno-iv'), findsOneWidget);
    });

    testWidgets(
        'another kuželna saved after Zpět waits for its own discovery — the '
        'old one\'s summary and teams do not carry over', (tester) async {
      final h = _Harness(rows: [discovered], teams: [[team]]);
      await _pump(tester, h);
      expect(find.text('Zapnout stahování'), findsOneWidget);

      await tester.tap(find.widgetWithText(TextButton, 'Zpět'));
      await tester.pump();
      expect(find.text('1 oddíl'), findsOneWidget);
      await tester.tap(find.widgetWithText(TextButton, 'Zpět'));
      await tester.pump();
      await tester.enterText(find.byType(TextField),
          'https://vysledky.kuzelky.cz/detail-kuzelny/ks-devitka-brno');
      await tester.tap(find.widgetWithText(FilledButton, 'Pokračovat'));
      await tester.pump();

      expect(h.saved, [('ks-devitka-brno', false)]);
      // The row still holds the old kuželna's report until its echo.
      expect(find.text('Oddíly a týmy'), findsOneWidget);
      expect(find.text('1 oddíl'), findsNothing);
      expect(find.widgetWithText(FilledButton, 'Načíst oddíly a týmy'),
          findsOneWidget);
      expect(find.widgetWithText(FilledButton, 'Pokračovat'), findsNothing);
    });

    testWidgets(
        'step 3 switches the sync on, asks for the first run and leaves '
        'the wizard', (tester) async {
      final h = _Harness(rows: [discovered], teams: [[team]]);
      await _pump(tester, h);

      await tester
          .tap(find.widgetWithText(FilledButton, 'Zapnout a stáhnout zápasy'));
      await tester.pump();

      expect(h.saved, [('tj-sokol-brno-iv', true)]);
      expect(h.syncs, 1);
      expect(find.text('Zapnout stahování'), findsNothing);
      final toggle = tester.widget<SwitchListTile>(
          find.widgetWithText(SwitchListTile, 'Stahovat automaticky'));
      expect(toggle.value, isTrue);
    });

    testWidgets('a sync that ever ran shows the normal view, even switched off',
        (tester) async {
      await _pump(tester, _Harness(rows: [_off]));

      expect(find.text('Kuželna na webu ČKA'), findsNothing);
      expect(find.text('Stahovat automaticky'), findsOneWidget);
    });
  });
```

- [ ] **Step 2: Run them to verify they fail**

Run: `flutter test test/domain/labels_test.dart test/features/federation_card_test.dart`
Expected: FAIL — `labels_test.dart` does not compile (`Method not found: 'discoveryClubsLabel'`), and the wizard tests fail (`Found 0 widgets with text "Kuželna na webu ČKA"`).

- [ ] **Step 3: Implement**

In `lib/domain/labels.dart` replace the imports:
```dart
import 'models.dart';
import 'schedule.dart';
```
with:
```dart
import 'collation.dart';
import 'models.dart';
import 'schedule.dart';
```
and append at the end:
```dart

/// The setup wizard's summary of a discovery (0047): „3 oddíly (2 nové:
/// KS Devítka Brno, TJ Sokol Husovice)“ — every venue club it found, and
/// the ones it created, Czech-sorted.
String discoveryClubsLabel(FederationDiscoverReport r) {
  final all = czechCount(r.clubsLinked.length + r.clubsCreated.length,
      'oddíl', 'oddíly', 'oddílů');
  if (r.clubsCreated.isEmpty) return all;
  final fresh =
      czechCount(r.clubsCreated.length, 'nový', 'nové', 'nových');
  final names = [...r.clubsCreated]..sort(compareCzech);
  return '$all ($fresh: ${names.join(', ')})';
}

/// „5 týmů ve 2 soutěžích“.
String discoveryTeamsLabel(FederationDiscoverReport r) =>
    '${czechCount(r.teams, 'tým', 'týmy', 'týmů')} '
    '${_inCompetitions(r.competitions)}';

/// The locative after „v“, which turns „ve“ before a numeral read with two
/// consonants up front: ve dvou/třech/čtyřech, ve dvanácti/třinácti/
/// čtrnácti, ve dvaceti…čtyřiceti devíti.
String _inCompetitions(int n) {
  final ve = (n >= 2 && n <= 4) || (n >= 12 && n <= 14) || (n >= 20 && n <= 49);
  return '${ve ? 've' : 'v'} $n ${n == 1 ? 'soutěži' : 'soutěžích'}';
}
```

Create `lib/features/admin/widgets/federation_wizard.dart`:
```dart
/// Správa → Oddíly: the ČKA card's first setup — 1. the kuželna on
/// vysledky.kuzelky.cz, 2. its oddíly and their teams (a discovery, which
/// links the venue's clubs to ours or creates them, 0047), 3. automatic
/// sync on and the first run. The step it opens on comes from the server
/// state ([FederationWizard.stepFor]), so an admin who leaves half-way
/// comes back where they left; Pokračovat and Zpět move on or back.
library;

import 'package:flutter/material.dart';

import '../../../domain/labels.dart';
import '../../../domain/models.dart';
import '../../../domain/slug.dart';
import 'venue_slug_field.dart';

class FederationWizard extends StatefulWidget {
  const FederationWizard({
    super.key,
    required this.sync,
    required this.teams,
    required this.discovering,
    required this.saveSlug,
    required this.discover,
    required this.enable,
  });

  final FederationSync sync;
  final List<Team> teams;

  /// A discovery is running, or its report is not in yet — the card polls.
  final bool discovering;

  /// Each resolves to whether it worked; the card shows any error.
  final Future<bool> Function(String slug) saveSlug;
  final Future<bool> Function() discover;
  final Future<bool> Function() enable;

  /// The step the server state opens on, 0-based: no slug → the kuželna;
  /// no team, or no successful discovery of this kuželna → the oddíly and
  /// teams; else switching the sync on. A moved kuželna's teams are the old
  /// one's: 0047's set_federation_sync drops the report with the move.
  static int stepFor(FederationSync sync, List<Team> teams) {
    if (!sync.configured) return 0;
    final report = sync.discover;
    return teams.isEmpty || report == null || report.failed ? 1 : 2;
  }

  @override
  State<FederationWizard> createState() => _FederationWizardState();
}

class _FederationWizardState extends State<FederationWizard> {
  static const _titles = [
    'Kuželna na webu ČKA',
    'Oddíly a týmy',
    'Zapnout stahování',
  ];

  /// Where Pokračovat / Zpět took the admin; null follows the server state.
  int? _step;
  bool _busy = false;
  late final _input = TextEditingController(text: widget.sync.venueSlug);
  String? _inputError;

  /// Step 1 saved another kuželna than the row had. The discovery report
  /// the row held then ([_movedFrom] is its `at`) was the old kuželna's.
  /// 0047's set_federation_sync drops it, but until that echo arrives step 2
  /// must not show it, nor offer Pokračovat for the old kuželna's teams.
  bool _moved = false;
  DateTime? _movedFrom;

  int get _current =>
      _step ?? FederationWizard.stepFor(widget.sync, widget.teams);

  /// The row's discovery report, unless it is the one from before a move.
  FederationDiscoverReport? get _report {
    final report = widget.sync.discover;
    return _moved && report?.at == _movedFrom ? null : report;
  }

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  Future<void> _run(Future<void> Function() action) async {
    setState(() => _busy = true);
    try {
      await action();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _saveSlug() => _run(() async {
        final error = venueSlugInputError(_input.text);
        if (error != null) {
          setState(() => _inputError = error);
          return;
        }
        final slug = venueSlugFromInput(_input.text)!;
        final before = widget.sync;
        final ok = await widget.saveSlug(slug);
        if (!ok || !mounted) return;
        setState(() {
          if (slug != before.venueSlug) {
            _moved = true;
            _movedFrom = before.discover?.at;
          }
          _step = 1;
        });
      });

  Future<void> _discover() => _run(() async {
        final ok = await widget.discover();
        if (ok && mounted) setState(() => _step = 1);
      });

  void _go(int step) => setState(() {
        _step = step;
        if (step == 0) {
          _input.text = widget.sync.venueSlug;
          _inputError = null;
        }
      });

  @override
  Widget build(BuildContext context) {
    final step = _current;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _StepBar(step: step, count: _titles.length),
        const SizedBox(height: 12),
        Text(_titles[step], style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 8),
        ...switch (step) {
          0 => _venue(),
          1 => _clubsAndTeams(),
          _ => _switchOn(),
        },
      ],
    );
  }

  Widget _buttons(List<Widget> children) => Padding(
        padding: const EdgeInsets.only(top: 12),
        child: Wrap(spacing: 8, runSpacing: 8, children: children),
      );

  Widget _back() => TextButton(
        onPressed: _busy ? null : () => _go(_current - 1),
        child: const Text('Zpět'),
      );

  List<Widget> _venue() => [
        const Text(venueSlugHelp),
        const SizedBox(height: 8),
        VenueSlugField(
          controller: _input,
          enabled: !_busy,
          errorText: _inputError,
          onChanged: () {
            if (_inputError != null) setState(() => _inputError = null);
          },
        ),
        _buttons([
          FilledButton(
            onPressed: _busy ? null : _saveSlug,
            child: const Text('Pokračovat'),
          ),
        ]),
      ];

  List<Widget> _clubsAndTeams() {
    final error = TextStyle(color: Theme.of(context).colorScheme.error);
    final report = _report;
    return [
      const Text(
        'Načteme oddíly, které na kuželně hrají, a jejich týmy. Chybějící '
        'oddíly založíme.',
      ),
      const SizedBox(height: 8),
      if (widget.discovering)
        const Row(
          children: [
            SizedBox.square(
              dimension: 14,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            SizedBox(width: 8),
            Expanded(child: Text('Načítají se oddíly a týmy z webu…')),
          ],
        )
      else if (report == null)
        _buttons([
          _back(),
          FilledButton(
            onPressed: _busy ? null : _discover,
            child: const Text('Načíst oddíly a týmy'),
          ),
        ])
      else ...[
        if (report.failed)
          Text('Načtení se nepovedlo: ${report.error}', style: error)
        else if (report.teams == 0)
          Text(
            'Na kuželně se nenašel žádný tým. Zkontroluj adresu kuželny.',
            style: error,
          )
        else ...[
          Text(discoveryClubsLabel(report)),
          Text(discoveryTeamsLabel(report)),
        ],
        _buttons([
          _back(),
          OutlinedButton(
            onPressed: _busy ? null : _discover,
            child: const Text('Načíst znovu'),
          ),
          FilledButton(
            onPressed: _busy || widget.teams.isEmpty ? null : () => _go(2),
            child: const Text('Pokračovat'),
          ),
        ]),
      ],
    ];
  }

  List<Widget> _switchOn() => [
        const Text(
          'Stáhnou se všechny zápasy a výsledky těchto týmů. Zápasy z rozpisu '
          'se spárují a zůstanou. První stažení trvá asi půl hodiny, pak se '
          'vše aktualizuje samo.',
        ),
        _buttons([
          _back(),
          FilledButton(
            onPressed: _busy ? null : () => _run(widget.enable),
            child: const Text('Zapnout a stáhnout zápasy'),
          ),
        ]),
      ];
}

/// Three short bars over the step: the done and the current ones filled.
class _StepBar extends StatelessWidget {
  const _StepBar({required this.step, required this.count});

  final int step;
  final int count;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      children: [
        for (var i = 0; i < count; i++) ...[
          if (i > 0) const SizedBox(width: 4),
          Expanded(
            child: Container(
              height: 4,
              decoration: BoxDecoration(
                color:
                    i <= step ? scheme.primary : scheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
        ],
      ],
    );
  }
}
```

In `lib/features/admin/widgets/federation_card.dart` make six replacements.

1. The library doc — replace:
```dart
/// Správa → Oddíly: the ČKA results-service card — the alley's kuželna on
/// vysledky.kuzelky.cz (read-only, changed behind a pencil), automatic sync
/// on/off (saved at once), a one-off team discovery or sync run, and while
/// federation jobs are still to run, a spinning line that says what is
/// left (0047 `federation_sync_progress`).
```
with:
```dart
/// Správa → Oddíly: the ČKA results-service card. Until the alley was first
/// synced it is the setup wizard ([FederationWizard]); after that the
/// kuželna on vysledky.kuzelky.cz (read-only, changed behind a pencil),
/// automatic sync on/off (saved at once), a one-off team discovery or sync
/// run, and while federation jobs are still to run, a spinning line that
/// says what is left (0047 `federation_sync_progress`).
```

2. The imports — replace:
```dart
import '../../../domain/models.dart';
import 'venue_slug_field.dart';
```
with:
```dart
import '../../../domain/models.dart';
import 'federation_wizard.dart';
import 'venue_slug_field.dart';
```

3. The state fields — replace:
```dart
  bool? _enabledWanted;
  bool _savingEnabled = false;

  @override
  void initState() {
```
with:
```dart
  bool? _enabledWanted;
  bool _savingEnabled = false;

  /// The wizard's last step switched the sync on: the normal view from now
  /// on, without waiting for the row's echo.
  bool _setupDone = false;

  @override
  void initState() {
```

4. Before `_setEnabled` — replace:
```dart
  Future<void> _setEnabled(FederationSync sync, bool enabled) async {
```
with:
```dart
  /// The wizard's last step: the sync on, then the first run.
  Future<bool> _enable(FederationSync sync) async {
    final ok = await tryAction(
      context,
      () async {
        await widget.saveFederation(sync.venueSlug, true);
        await widget.syncNow();
      },
      errorText: friendlyDbError,
    );
    if (ok && mounted) {
      setState(() {
        _setupDone = true;
        _enabledWanted = true;
      });
      _afterRequest();
    }
    return ok;
  }

  /// Never synced and never switched on: the setup is not finished. Once
  /// on, or ever synced, the normal view stays — even with the sync
  /// switched off later.
  bool _inSetup(FederationSync sync) =>
      !_setupDone && !sync.enabled && sync.lastRunAt == null;

  Future<void> _setEnabled(FederationSync sync, bool enabled) async {
```

5. In `build` — replace:
```dart
            if (sync != null)
              ..._settings(sync)
            else if (loaded.hasError)
```
with:
```dart
            if (sync != null && _inSetup(sync))
              _wizard(sync)
            else if (sync != null)
              ..._settings(sync)
            else if (loaded.hasError)
```

6. Before `_settings` — replace:
```dart
  List<Widget> _settings(FederationSync sync) {
```
with:
```dart
  Widget _wizard(FederationSync sync) {
    final teams = ref.watch(teamsProvider);
    if (!teams.hasValue && !teams.hasError) return const Text('Načítám…');
    return FederationWizard(
      sync: sync,
      teams: teams.value ?? const [],
      discovering: _discovering(sync),
      saveSlug: (slug) => tryAction(
        context,
        () => widget.saveFederation(slug, false),
        errorText: friendlyDbError,
      ),
      discover: _requestDiscovery,
      enable: () => _enable(sync),
    );
  }

  List<Widget> _settings(FederationSync sync) {
```

In `README.md` (section „Zápasy ze svazu“) replace:
```
joby `federation_*`, noční cron `federation-nightly`, migrace `0045`).
Nastavení je ve Správa → Oddíly: výběr kuželny, zapnutí synchronizace,
ruční „Synchronizovat teď". Ruční úprava zápasu v appce se při
```
with:
```
joby `federation_*`, noční cron `federation-nightly`, migrace `0045`
a `0047`). Nastavení je ve Správa → Oddíly: poprvé průvodce ve třech
krocích (kuželna, oddíly a týmy — chybějící oddíly založí —, zapnutí
stahování), potom „Přenačíst týmy z webu", ruční „Synchronizovat teď"
a řádek s průběhem synchronizace. Ruční úprava zápasu v appce se při
```

- [ ] **Step 4: Run them to verify they pass**

Run: `flutter test test/domain/labels_test.dart test/features/federation_card_test.dart test/features/clubs_screen_test.dart`
Expected: `All tests passed!`

Run: `flutter analyze`
Expected: `No issues found!`

- [ ] **Step 5: Commit**

```bash
git add lib/domain/labels.dart lib/features/admin/widgets/federation_wizard.dart lib/features/admin/widgets/federation_card.dart README.md test/domain/labels_test.dart test/features/federation_card_test.dart
git commit -m "$(cat <<'EOF'
feat(federation): a three-step setup wizard on the ČKA card

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 9: All gates

**Files:**
- Test only; modify a file only if a gate fails, and then only to fix that failure.

**Interfaces:**
- Consumes: everything above.
- Produces: a branch whose every gate passes.

- [ ] **Step 1: Analyzer**

Run: `flutter analyze`
Expected: `No issues found!`

- [ ] **Step 2: The full Flutter suite, in the app's time zone**

Run: `TZ=Europe/Prague flutter test`
Expected: `All tests passed!`

- [ ] **Step 3: Deno check and tests**

Run: `deno check --import-map supabase/functions/import_map.json supabase/functions/notify/index.ts`
Expected: no error.

Run: `deno test --allow-read supabase/functions`
Expected: `ok | … passed | 0 failed`.

- [ ] **Step 4: Schema snapshot diff (rebuilds the local DB from the migrations alone, as CI does)**

Run: `tool/schema_snapshot.sh && git diff --exit-code supabase/schema.sql && echo "snapshot current"`
Expected: `supabase/schema.sql regenerated` then `snapshot current`.

- [ ] **Step 5: Tenancy RLS smoke-test on the rebuilt DB**

Run: `psql "$(supabase status -o env | sed -n 's/^DB_URL="\(.*\)"/\1/p')" -X -v ON_ERROR_STOP=1 -q -f supabase/tests/tenancy_rls.sql > /dev/null 2>&1; echo "exit $?"`
Expected: `exit 0`.

Run: `psql "$(supabase status -o env | sed -n 's/^DB_URL="\(.*\)"/\1/p')" -X -v ON_ERROR_STOP=1 -f supabase/tests/tenancy_rls.sql 2>&1 | grep -E 'ERROR|FAIL|0047\)'`
Expected: no `ERROR`/`FAIL` line and seven `NOTICE:  OK: …` lines — the six 0047 sections (16, 16b, 16c, 16d, 17, 18) plus the 13b notice ending `(0045, 0047)`.

- [ ] **Step 6: Clean tree**

Run: `git status --short`
Expected: no output. If a gate needed a fix, commit only that fix:
```bash
git add <the fixed files>
git commit -m "$(cat <<'EOF'
fix(federation): <what the gate caught>

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
EOF
)"
```
