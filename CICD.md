# Rezervátor — CI/CD guide

## The picture

```
push / PR ──────────────► ci.yml: flutter analyze + flutter test
push to main ───────────► deploy-web.yml: flutter build web → GitHub Pages
push to main
  touching supabase/** ─► deploy-backend.yml: supabase db push
                                              supabase functions deploy notify + cancel
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

### 2. Migration history must match prod

Migrations `0001`–`0011` are already applied on prod (some by hand, later ones
via `supabase db push`). The CI runner links fresh each run, so as long as the
prod `supabase_migrations` table reflects everything applied, the next
`db push` is a no-op until a new migration is added. If a `db push` ever tries
to re-run an applied file, repair once:

```bash
supabase link --project-ref wgwijvcnslkesyqgaeul
supabase migration repair --status applied 0001 0002 0003 0004 0005 0006 0007 0008 0009 0010 0011
```

From then on, **new migrations go through git**: add
`supabase/migrations/0012_whatever.sql`, merge to main, and deploy-backend
applies it automatically.

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
  # 1. bump version in pubspec.yaml, e.g. 1.1.0+2  (versionCode must grow)
  git commit -am "Bump version to 1.1.0"

  # 2. annotated tag; the message body becomes Play's "what's new"
  git tag -a v1.1.0 -m "v1.1.0" -m "- Oprava X
  - Nová funkce Y"
  git push origin main v1.1.0
  ```

  A few minutes later the signed `rezervator-v1.1.0.apk` is on the **Releases**
  page (share that link) and the AAB waits as a **draft** on Play's internal
  track — review and roll it out in Play Console.
