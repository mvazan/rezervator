# Rezervátor — CI/CD guide

## The picture

```
push / PR ──────────────► ci.yml: flutter analyze + flutter test
push to main ───────────► deploy-web.yml: flutter build web → GitHub Pages
push to main
  touching supabase/** ─► deploy-backend.yml: supabase db push
                                              supabase functions deploy notify + cancel
                                                + calendar-oauth-callback + calendar-manage
push tag v* ────────────► release.yml: signed APK + AAB with production backend
                          baked in → GitHub Releases, AAB → Play internal (draft)
twice a week cron ──────► keepalive.yml: pings Supabase so the free tier
                          never pauses
```

**Firebase?** Only for FCM push, which is dormant. Nothing to deploy: the app
gets the `FIREBASE_*` values baked in at build time (empty until push is
enabled), and the notify function reads the service-account JSON from a
Supabase secret if/when set. Nothing here changes until then.

## One-time setup

### 1. GitHub Actions secrets

Repo → Settings → Secrets and variables → Actions. `SUPABASE_URL`,
`SUPABASE_ANON_KEY` and `FIREBASE_*` already exist (used by `deploy-web.yml`).
Add the rest:

| Secret | Used by | Value |
|---|---|---|
| `SUPABASE_ACCESS_TOKEN` | deploy-backend | personal token (supabase.com/dashboard/account/tokens) |
| `SUPABASE_PROJECT_REF` | deploy-backend | `wgwijvcnslkesyqgaeul` |
| `SUPABASE_DB_PASSWORD` | deploy-backend | database password (Project Settings → Database) |
| `ANDROID_KEYSTORE_BASE64` | release | `base64 -i android/app/upload-keystore.jks` |
| `ANDROID_KEYSTORE_PASSWORD` | release | keystore password |
| `ANDROID_KEY_ALIAS` | release | `rezervator` |
| `ANDROID_KEY_PASSWORD` | release | key password (= store password) |
| `PLAY_SERVICE_ACCOUNT_JSON` | release | play-uploader service-account JSON |
| `DEMO_PASSWORD` | release | password for the Play-review demo account (see PLAY.md) |
| `SENTRY_DSN` | deploy-web, release | Sentry DSN (optional — empty keeps Sentry off) |
| `FIREBASE_*` (4) | deploy-web, release | optional; empty keeps push off |
| `GOOGLE_CLIENT_ID` | deploy-web, release | optional; the OAuth **client ID** (public) for the Google Calendar link — empty hides the calendar card. The **client secret** is a Supabase secret only (`supabase secrets set GOOGLE_CLIENT_ID=… GOOGLE_CLIENT_SECRET=…`, SETUP.md §8.4) |

### Auth + SMTP config lives in git too

`supabase/config.toml` holds the auth URLs, SMTP settings and the Czech
magic-link template. It is NOT applied by any workflow — push it by hand when
it changes, with the SMTP password from the environment:

```bash
SMTP_PASS=<app-password> supabase config push
```

### 2. Migration history must match prod

Every file in `supabase/migrations/` is applied on prod (`0001`–`0011` partly
by hand, everything later via `supabase db push`). The CI runner links fresh
each run, so as long as the prod `supabase_migrations` table reflects
everything applied, the next `db push` is a no-op until a new migration is
added. If a `db push` ever tries to re-run an applied file, repair once:

```bash
supabase link --project-ref wgwijvcnslkesyqgaeul
supabase migration repair --status applied $(ls supabase/migrations | cut -d_ -f1)
```

**New migrations go through git**: add `supabase/migrations/00NN_whatever.sql`,
merge to main, and deploy-backend applies it automatically.

**0016 needs two Vault secrets on prod before it lands** (SQL editor):
`notify_url` = `https://wgwijvcnslkesyqgaeul.supabase.co/functions/v1/notify`,
`webhook_secret` = the value already set as the notify function's
`WEBHOOK_SECRET`. Without them `notify_webhook` logs a warning and skips the
POST (writes are unaffected).

### Backend checks (CI job `backend`)

Every push/PR also rebuilds the database from `supabase/migrations/` on a
local Supabase stack (CLI pinned to 2.109.0) and then:

1. dumps the public schema and diffs it against `supabase/schema.sql` —
   **after adding a migration run `tool/schema_snapshot.sh` and commit the
   regenerated file**, otherwise the job fails;
2. runs `supabase/tests/tenancy_rls.sql` (cross-tenant isolation, superadmin
   visiting, the reservation cascade, the reject guard, rental exceptions,
   players without an account, the Google Calendar link + job queue);
3. `deno check` over every function entry point (`notify`, `cancel`,
   `calendar-oauth-callback`, `calendar-manage`) + `deno test` over
   `supabase/functions` (helpers in `_shared/` have unit tests;
   `import_map.json` pins supabase-js).

`docs/SCHEMA.md` is the human summary of the effective schema — update it
with the migration.

### 3. Google Play

One-time Play Console / signing-key / service-account setup lives in
[PLAY.md](PLAY.md). The signing key already exists at
`android/app/upload-keystore.jks` (gitignored — back it up).

## Everyday flow

- **Change code** → push / open PR → `ci.yml` runs analyzer + tests.
- **Merge to main** → web redeploys to GitHub Pages automatically.
- **Change schema or an Edge Function** → merge to main → backend deploys
  itself (path-filtered, only when `supabase/**` changed).
- **Ship to the team / Play**:

  ```bash
  # 1. add the release to lib/features/profile/changelog_data.dart (newest
  #    first) — that text becomes Play's "what's new", the GitHub Release
  #    notes and the in-app Novinky; test/changelog_test.dart fails when
  #    pubspec and the changelog disagree
  # 2. bump version in pubspec.yaml, e.g. 1.1.1+4  (versionCode must grow)
  git commit -am "chore: release 1.1.1"

  # 3. tag + push (the tag message is not used for release notes)
  git tag -a v1.1.1 -m "v1.1.1"
  git push origin main v1.1.1
  ```

  A few minutes later the signed `rezervator-v1.1.0.apk` is on the **Releases**
  page (share that link) and the AAB waits as a **draft** on Play's internal
  track — review and roll it out in Play Console.
