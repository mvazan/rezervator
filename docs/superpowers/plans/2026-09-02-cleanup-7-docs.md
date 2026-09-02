# Rezervátor — cleanup 7: dokumentácia (plan)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The three operator documents describe the backend as it is after migrations 0001–0020 and the current CI, and the release notes have a test-enforced single source.

**Branch:** `cleanup-7-docs` from `main` (docs + one test; no code).

- [x] **SETUP.md** — §3 `supabase config push` for auth/SMTP; §4 registration per kuželna + superadmin bootstrap (SQL) instead of "first sign-in is admin"; §5 optional `SENTRY_DSN`/`FIREBASE_*` secrets; §8.2 drop the non-existent `google-services.json.example` step (Firebase initialises from dart-defines, no Gradle plugin); new §9 Sentry, §10 local dev / tests / schema snapshot / edge-function checks.
- [x] **CICD.md** — secrets table gains `SENTRY_DSN` + `FIREBASE_*`; `config.toml` push note; the ship flow: changelog entry → bump → tag (the tag body is not the release notes; `tool/whatsnew.dart` reads `changelog_data.dart`).
- [x] **PLAY.md** — same ship-flow fix.
- [x] **test/changelog_test.dart** — newest changelog entry == pubspec version; versions unique and descending; every entry has notes.

## Outcome (2026-09-02)

Every SETUP.md claim now matches the repo (checked against `push.dart`,
`android/*.gradle.kts`, `release.yml`, `deploy-web.yml`, migrations 0014/0016).
Not done on purpose: a rewrite of SETUP.md's phase-numbered structure — the
steps still read in build order and renumbering would break existing links.
