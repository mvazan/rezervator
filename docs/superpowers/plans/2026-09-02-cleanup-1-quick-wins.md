# Rezervátor — cleanup 1: quick wins (plan)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Land the low-risk findings of the 2026-09-02 audit (spec: `docs/superpowers/specs/2026-09-02-cleanup-audit.md`, section F + the two real backend defects + decision 2's client half) so the later, bigger cleanups start from a smaller surface.

**Architecture:** Pure deletions in the schedule/kiosk/admin widgets (no behaviour change for players), two fail-closed guards in the edge functions, one migration (0016) that moves `notify_webhook`'s URL + secret into Supabase Vault so git reproduces prod, and one small client fix that reads a player's club from the `clubs` table instead of the stale `profiles.club` text.

**Tech Stack:** Flutter 3 / Dart 3.10 (`flutter analyze`, `flutter test`), Supabase CLI + Docker (`supabase start`, `supabase db reset`, `psql`), Deno edge functions (no local deno — verified via `supabase functions serve`).

**Branch:** `cleanup-1-quick-wins` from `main` (note: the unmerged branch `sentry-filter-network` stays as is).

## Global Constraints

- Czech UI copy stays byte-identical unless a task says otherwise.
- No `flutter analyze` warnings; the full `flutter test` suite must pass after every task (baseline: 210 tests on main; the unmerged `sentry-filter-network` branch adds 6 more).
- One commit per task, message in the repo's `type(scope): summary` style, ending with `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>`. Never push.
- Migrations are append-only: never edit `0001`–`0015`; new SQL goes to `0016_notify_webhook_vault.sql`.
- Do not bump `pubspec.yaml` version or `changelog_data.dart` — release decisions are the owner's.

---

### Task 1: Drop the dead schedule-view surface

The orientation is the only view switch, `fitWidth` is a hard-coded `true`, and the portrait admin hooks are never passed. Remove all three.

**Files:**
- Modify: `lib/features/schedule/week_screen.dart:16-18, 169-174, 579, 601`
- Modify: `lib/features/schedule/day_pager_view.dart` (constructor, `_DayPage`, `_blockLabel`, `_dayRows`, `_laneCell`)
- Modify: `lib/features/schedule/widgets/gap_rows.dart:26-30, 136-187`
- Test: `test/features/week_screen_test.dart:415`

- [x] **Step 1: Create the branch**

```bash
git checkout main && git checkout -b cleanup-1-quick-wins
```

- [x] **Step 2: Make the test independent of the enum being removed**

In `test/features/week_screen_test.dart` replace

```dart
    expect(find.byType(SegmentedButton<ScheduleView>), findsNothing);
```

with

```dart
    expect(find.bySubtype<SegmentedButton>(), findsNothing);
```

Run: `flutter test test/features/week_screen_test.dart`
Expected: all pass (the assertion still means "no toggle buttons").

- [x] **Step 3: week_screen.dart — remove `ScheduleView` and `fitWidth`**

Delete lines 16–18:

```dart
/// The two schedule layouts a device can be set to; persisted per-device via
/// [scheduleViewPrefKey].
enum ScheduleView { day, week }
```

Replace lines 169–174

```dart
    // Orientation IS the view switch: portrait reads day-by-day, landscape
    // shows the whole week. Both always stretch to the full width.
    final view = MediaQuery.orientationOf(context) == Orientation.portrait
        ? ScheduleView.day
        : ScheduleView.week;
    const fitWidth = true;
```

with

```dart
    // Orientation IS the view switch: portrait reads day-by-day, landscape
    // shows the whole week. Both always stretch to the full width.
    final landscape =
        MediaQuery.orientationOf(context) == Orientation.landscape;
```

Replace `child: view == ScheduleView.week` (line 579) with `child: landscape`, and delete the line `fitWidth: fitWidth,` (601) from the `DayPagerView(...)` call.

- [x] **Step 4: day_pager_view.dart — remove `fitWidth`, `onLongPressBlock`, `onAddBlockInGap`**

In the `DayPagerView` constructor delete `required this.fitWidth,`, `this.onLongPressBlock,`, `this.onAddBlockInGap,`. Delete the fields and their doc comments:

```dart
  /// When true the lane grid drops its horizontal scroller and lets lanes
  /// share the full width (names ellipsis-clipped); see [_DayPage].
  final bool fitWidth;
```

```dart
  /// Admin-only (null otherwise): long-press a block label to edit it; tap
  /// an empty gap to add a block prefilled with the gap's range.
  final void Function(TimeBlock)? onLongPressBlock;
  final void Function(HourMinute start, HourMinute end)? onAddBlockInGap;
```

In the `_DayPage(...)` construction inside `_DayPagerViewState.build` delete the three pass-through lines `fitWidth: widget.fitWidth,`, `onLongPressBlock: widget.onLongPressBlock,`, `onAddBlockInGap: widget.onAddBlockInGap,`.

In `_DayPage`: delete `required this.fitWidth,`, `this.onLongPressBlock,`, `this.onAddBlockInGap,` from the constructor and these fields:

```dart
  /// See [DayPagerView.fitWidth].
  final bool fitWidth;
```

```dart
  final void Function(TimeBlock)? onLongPressBlock;
  final void Function(HourMinute start, HourMinute end)? onAddBlockInGap;
```

Replace the three-way `if (day.blocks.isEmpty) … else if (fitWidth) … else SingleChildScrollView(…)` chain (with its preceding comment about the horizontal scroller) by:

```dart
            // A day whose every block a priority slot cancelled has no lane
            // grid — a 'Dráha 1..N' header would label rows that don't
            // exist, so it only renders when blocks do.
            Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (day.blocks.isNotEmpty) _laneHeaderRow(day),
                ..._dayRows(context, day),
              ],
            ),
```

Delete `_laneTileWidth`, `_rowWidth` and its doc comment. Replace `_blockLabel` with:

```dart
  Widget _blockLabel(TimeBlock block) => Text(
        block.label,
        style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
      );
```

(and its call site `_blockLabel(context, block)` → `_blockLabel(block)`; drop the now-stale doc comment "for admins it long-presses into the block editor").

In `_dayRows` replace the `EmptyGapItem` arm with `final EmptyGapItem gap => EmptyGapRow(item: gap),`.

Replace `_laneCell` with:

```dart
  /// Every lane flexes to share the row's width. Inter-lane spacing lives in
  /// [_laneCells]' spacers — NOT in per-cell padding, which under Expanded
  /// would eat into every lane but the last and render lane N visibly wider
  /// than the others.
  Widget _laneCell({required Widget child}) => Expanded(child: child);
```

- [x] **Step 5: gap_rows.dart — `EmptyGapRow` is a seam only**

Replace the `EmptyGapItem` doc ("…or (admin) an add-block affordance prefilled with the hole's range.") with "An event-free hole between two consecutive blocks — renders as a thin seam." and replace the whole `EmptyGapRow` class with:

```dart
/// An event-free hole between blocks: a 10px faint seam keeping the day
/// pager time-honest. (The week calendar offers admins add-in-gap on tap;
/// the pager is read-only for layout edits.)
class EmptyGapRow extends StatelessWidget {
  const EmptyGapRow({super.key, required this.item});

  final EmptyGapItem item;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      height: 10,
      margin: const EdgeInsets.symmetric(vertical: 1),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(4),
      ),
    );
  }
}
```

- [x] **Step 6: Verify**

Run: `flutter analyze && flutter test`
Expected: `No issues found!` and `All tests passed!` (216).

- [x] **Step 7: Commit**

```bash
git add lib/features/schedule test/features/week_screen_test.dart
git commit -m "refactor(schedule): drop dead view toggle, fit-width branch and portrait admin hooks"
```

---

### Task 2: Kiosk dead surface

**Files:**
- Modify: `lib/features/kiosk/kiosk_board_view.dart:24-30, 118-136, 215-218, ~248`
- Modify: `lib/features/kiosk/kiosk_shell.dart:116`
- Test: `test/features/kiosk_test.dart:1-9`

- [x] **Step 1: Test imports the board widgets from their home**

In `test/features/kiosk_test.dart` add after the kiosk imports:

```dart
import 'package:rezervator/features/schedule/widgets/calendar_board.dart';
```

- [x] **Step 2: kiosk_board_view.dart**

Delete the `export '../schedule/widgets/calendar_board.dart' show …;` block (lines 24–30).

Constructor → `const KioskBoardView({super.key, required this.selected});`; delete the `onBooked` field and its doc comment; delete the `widget.onBooked();` line at the end of `_book`.

Replace `resetToToday`:

```dart
  /// Same as [resetToNow], reading the current time itself — the shell's
  /// idle-reset entry point.
  void resetToToday() {
    final now = DateTime.now();
    resetToNow(HourMinute(now.hour, now.minute));
  }
```

- [x] **Step 3: kiosk_shell.dart**

Delete the line `onBooked: () {}, // selection persists — no-op by design.`

- [x] **Step 4: Verify**

Run: `flutter analyze && flutter test test/features/kiosk_test.dart test/features/kiosk_screen_test.dart`
Expected: no issues, all pass.

- [x] **Step 5: Commit**

```bash
git add lib/features/kiosk test/features/kiosk_test.dart
git commit -m "refactor(kiosk): drop onBooked no-op and calendar_board re-exports"
```

---

### Task 3: Match dialog — dead `isMatch` conditionals

`MatchDialog` is only ever opened for match types (`week_screen.dart:471` checks `target.type.isMatch`; `matches_screen.dart` passes match types), so every `isMatch` branch is always true.

**Files:**
- Modify: `lib/features/admin/matches_screen.dart:237-254, 271-330`

- [x] **Step 1: `_save`**

`if (type.isMatch && awayTeam.isEmpty)` → `if (awayTeam.isEmpty)`; in the `Api.savePrioritySlot(...)` call:

```dart
        homeTeam: _homeTeam.text.trim(),
        awayTeam: awayTeam,
        prepMinutes: _isAway ? 0 : _prepMinutes,
```

- [x] **Step 2: `build`**

Delete `const isMatch = true;`. Unwrap `if (isMatch) ...[ … ]` around the Domácí/Hosté fields (keep the children), drop the `if (isMatch)` in front of the `SwitchListTile`, and change `if (isMatch && !_isAway) ...[` to `if (!_isAway) ...[`.

- [x] **Step 3: Verify**

Run: `flutter analyze && flutter test`
Expected: clean, all pass.

- [x] **Step 4: Commit**

```bash
git add lib/features/admin/matches_screen.dart
git commit -m "refactor(admin): drop always-true isMatch branches in the match dialog"
```

---

### Task 4: Stale doc comments

**Files:**
- Modify: `lib/features/schedule/widgets/slot_tile.dart:1-5, 232-237`
- Modify: `lib/features/schedule/week_calendar_view.dart:83`

- [x] **Step 1: slot_tile.dart header**

```dart
/// Shared schedule cell: one widget renders every slot in the app's week
/// calendar (compact) and day pager (large). The kiosk board draws its own
/// lane rows (kiosk_board_view.dart) — unifying them is cleanup plan 5.
/// Purely presentational — all booking policy (canBook/canCancel/isAdmin
/// gating) stays with the caller, which resolves a display name and a single
/// [onTap] callback (or null to render inert) before constructing the tile.
```

and in the `slotTileFor` doc replace "Shared by the week list view (compact tiles) and the day pager view (large tiles)" with "Shared by the week calendar view (compact tiles) and the day pager view (large tiles)".

- [x] **Step 2: week_calendar_view.dart:83**

"move it within the day (snap 15 min)." → "move it within the day (snap 5 min, see [_snapMinute])."

- [x] **Step 3: Verify + commit**

Run: `flutter analyze`
Expected: `No issues found!`

```bash
git add lib/features/schedule
git commit -m "docs(schedule): fix stale slot-tile and snap-grid comments"
```

---

### Task 5: Edge functions fail closed without `CANCEL_TOKEN_SECRET`

**Files:**
- Modify: `supabase/functions/notify/index.ts:319-323`
- Modify: `supabase/functions/cancel/index.ts:60-64`

- [x] **Step 1: notify — signing without a secret is a deployment bug**

Replace

```ts
        const token = await signCancelToken(
          record.id as string,
          exp,
          Deno.env.get("CANCEL_TOKEN_SECRET") ?? "",
        );
```

with

```ts
        // Fail closed: signing with an empty key would mint links anyone
        // could forge. A missing secret is a deployment bug — surface it
        // as a 500 in the function logs instead.
        const cancelSecret = Deno.env.get("CANCEL_TOKEN_SECRET");
        if (!cancelSecret) throw new Error("CANCEL_TOKEN_SECRET is not set");
        const token = await signCancelToken(
          record.id as string,
          exp,
          cancelSecret,
        );
```

- [x] **Step 2: cancel — refuse to verify against an empty key**

Replace

```ts
  const secret = Deno.env.get("CANCEL_TOKEN_SECRET") ?? "";
```

with

```ts
  // Fail closed (mirrors notify's WEBHOOK_SECRET guard): with no secret the
  // HMAC check would pass for tokens signed with an empty key.
  const secret = Deno.env.get("CANCEL_TOKEN_SECRET");
  if (!secret) {
    console.error("CANCEL_TOKEN_SECRET is not set");
    return new Response("misconfigured", { status: 500 });
  }
```

- [x] **Step 3: Verify with the local runtime**

```bash
supabase start
printf 'RESEND_API_KEY=x\n' > /tmp/ef.env
supabase functions serve cancel --no-verify-jwt --env-file /tmp/ef.env &
sleep 8
curl -s -o /dev/null -w '%{http_code}\n' 'http://127.0.0.1:54321/functions/v1/cancel?token=a.b'
```
Expected: `500`.

```bash
printf 'RESEND_API_KEY=x\nCANCEL_TOKEN_SECRET=test\n' > /tmp/ef.env
# restart serve with the new env file, then:
curl -s 'http://127.0.0.1:54321/functions/v1/cancel?token=a.b' | grep -o 'Odkaz neplatí'
```
Expected: `Odkaz neplatí` (a 200 page — the token is invalid, the key is present).

- [x] **Step 4: Commit**

```bash
git add supabase/functions
git commit -m "fix(functions): fail closed when CANCEL_TOKEN_SECRET is missing"
```

---

### Task 6: `notify_webhook` reads URL + secret from Vault (migration 0016)

`0001` bakes `<PROJECT_REF>`/`<WEBHOOK_SECRET>` placeholders into `notify_webhook`; prod was patched by hand, so a `supabase db push` of git as-is would target a bogus host. Same pattern as Termínátor's `0012_webhook_secret_vault.sql`, plus the URL in Vault too (the repo is meant to be self-hostable) and a revoke so PostgREST never exposes the secret.

**Files:**
- Create: `supabase/migrations/0016_notify_webhook_vault.sql`
- Modify: `SETUP.md` §2 (lines 20–44) and §6 step 3 (lines 141–152)
- Modify: `CICD.md` §2 (lines 42–56)

- [x] **Step 1: Migration**

```sql
-- 0016 — notify_webhook reads its target URL and shared secret from Supabase
-- Vault instead of literals baked into 0001 (which shipped <PROJECT_REF> /
-- <WEBHOOK_SECRET> placeholders that prod had patched by hand — git no
-- longer reproduced prod). A backend is configured ONCE, in the SQL editor,
-- never by editing a migration:
--
--   select vault.create_secret(
--     'https://<project-ref>.supabase.co/functions/v1/notify', 'notify_url');
--   select vault.create_secret('<value>', 'webhook_secret');
--
-- `webhook_secret` must equal the notify Edge Function's WEBHOOK_SECRET env
-- (supabase secrets set). PROD: create both secrets BEFORE this migration
-- lands, or notifications pause (with a warning in Postgres logs) until
-- they exist.

create or replace function notify_webhook_config()
returns table (url text, secret text)
language sql stable security definer set search_path = ''
as $$
  select
    (select decrypted_secret from vault.decrypted_secrets
      where name = 'notify_url'),
    (select decrypted_secret from vault.decrypted_secrets
      where name = 'webhook_secret');
$$;

-- The trigger runs as the function owner, which keeps EXECUTE; every app
-- role loses it — PostgREST would otherwise serve the secret as an RPC to
-- any signed-in user.
revoke all on function notify_webhook_config() from public, anon, authenticated;

-- Same body as 0001, literals swapped for the Vault lookup, plus a guard so
-- an unconfigured backend logs a warning instead of failing the write.
create or replace function notify_webhook()
returns trigger
language plpgsql security definer set search_path = public
as $$
declare
  v_url text;
  v_secret text;
begin
  select c.url, c.secret into v_url, v_secret from notify_webhook_config() c;
  if v_url is null or v_secret is null then
    raise warning 'notify_webhook: vault secrets notify_url / webhook_secret missing, notification skipped';
    return coalesce(new, old);
  end if;
  perform net.http_post(
    url := v_url,
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'x-webhook-secret', v_secret
    ),
    body := jsonb_build_object(
      'type', tg_op,
      'table', tg_table_name,
      'schema', tg_table_schema,
      'record', case when tg_op = 'DELETE' then null else to_jsonb(new) end,
      'old_record', case when tg_op = 'INSERT' then null else to_jsonb(old) end
    )
  );
  return coalesce(new, old);
end;
$$;
```

- [x] **Step 2: Apply the whole chain locally and exercise the guard**

```bash
supabase start
supabase db reset
DB=postgresql://postgres:postgres@127.0.0.1:54322/postgres
psql "$DB" -c "select * from notify_webhook_config();"
```
Expected: one row `(null, null)`.

```bash
psql "$DB" -c "set role authenticated; select * from notify_webhook_config();"
```
Expected: `ERROR: permission denied for function notify_webhook_config`.

```bash
psql "$DB" -c "insert into tenants (id, name) values ('00000000-0000-0000-0000-00000000aaaa', 'Vault test');"
```
Expected: `INSERT 0 1` preceded by `WARNING: notify_webhook: vault secrets … missing` (the write goes through).

```bash
psql "$DB" -c "select vault.create_secret('http://127.0.0.1:54321/functions/v1/notify', 'notify_url'); select vault.create_secret('local-secret', 'webhook_secret'); select * from notify_webhook_config();"
```
Expected: the last statement prints the two values.

```bash
psql "$DB" -v ON_ERROR_STOP=1 -f supabase/tests/tenancy_rls.sql
```
Expected: ends with `ROLLBACK` and no `ERROR` (if it fails on a pre-existing assumption, record the failure in the commit message — it is a plan-2 item).

- [x] **Step 3: SETUP.md §2 — replace the "edit 0001 + paste into SQL editor + seed blocks" steps**

```markdown
## 2. Databázové schéma

1. Propoj lokální Supabase CLI s projektem a aplikuj všechny migrace:
   ```bash
   supabase link --project-ref <tvůj-project-ref>
   supabase db push
   ```
   Založí to všechny tabulky, RPC funkce, triggery i RLS politiky. Nic
   v `supabase/migrations/` se needituje — konfigurace projektu jde do
   Vaultu (další krok).
2. Dashboard → **SQL Editor** → vlož a spusť (obě hodnoty si poznamenej,
   `webhook_secret` bude potřeba znovu v kroku 6):
   ```sql
   select vault.create_secret(
     'https://<tvůj-project-ref>.supabase.co/functions/v1/notify',
     'notify_url');
   select vault.create_secret('<openssl rand -hex 24>', 'webhook_secret');
   ```
   Databázový trigger `notify_webhook` si obě hodnoty čte odtud; bez nich
   zápisy fungují, jen se neposílají notifikace (a v Postgres logu je
   warning).
3. Časové bloky, počet drah a tréninkové dny nastavíš po prvním přihlášení
   přímo v appce (Správa → Rozvrh).
```

- [x] **Step 4: SETUP.md §6 step 3 — the secret now comes from Vault**

Replace the paragraph starting "**`WEBHOOK_SECRET` musí být přesně stejná hodnota**, kterou jsi vložil/a za `<WEBHOOK_SECRET>` do `0001_schema.sql` v kroku 2 …" with:

```markdown
   **`WEBHOOK_SECRET` musí být přesně stejná hodnota**, kterou jsi uložil/a
   do Vaultu jako `webhook_secret` v kroku 2 (Databázové schéma) — jinak
   databázový trigger (`notify_webhook`) bude volat funkci `notify` se
   špatným hlavičkovým tokenem a ta ho odmítne (401). `CANCEL_TOKEN_SECRET` je
   nový, nezávislý řetězec — používá se jen k podepisování odkazů na zrušení
   rezervace v e-mailech (bez něj funkce `cancel` odpovídá 500 a `notify`
   neposílá kioskové e-maily).
```

and `WEBHOOK_SECRET=<hodnota-z-kroku-2>` stays as is.

- [x] **Step 5: CICD.md §2**

Replace the paragraph + repair command with:

```markdown
Every file in `supabase/migrations/` is applied on prod (`0001`–`0011` partly
by hand, everything later via `supabase db push`). The CI runner links fresh
each run, so as long as the prod `supabase_migrations` table reflects
everything applied, the next `db push` is a no-op until a new migration is
added. If a `db push` ever tries to re-run an applied file, repair once:

```bash
supabase link --project-ref wgwijvcnslkesyqgaeul
supabase migration repair --status applied $(ls supabase/migrations | cut -d_ -f1)
```

**0016 needs two Vault secrets on prod before it lands** (SQL editor):
`notify_url` = `https://wgwijvcnslkesyqgaeul.supabase.co/functions/v1/notify`,
`webhook_secret` = the value already set as the notify function's
`WEBHOOK_SECRET`. Without them `notify_webhook` logs a warning and skips the
POST (writes are unaffected).
```

- [x] **Step 6: Commit**

```bash
git add supabase/migrations/0016_notify_webhook_vault.sql SETUP.md CICD.md
git commit -m "feat(db): notify_webhook reads URL and secret from Vault (0016)"
```

---

### Task 7: Club name from the `clubs` table (decision 2, client half)

`register_profile` copies the club's name into `profiles.club`, but `set_player_club` only moves `club_id`, so the text goes stale after the first reassignment. Read the roster instead.

**Files:**
- Modify: `lib/domain/models.dart` (add `clubNameOf` after the `Club` class)
- Modify: `lib/features/admin/players_screen.dart:183, 259`
- Modify: `lib/features/profile/profile_screen.dart:59, 76-79`
- Test: `test/domain/models_test.dart`, `test/features/players_screen_test.dart`, `test/features/profile_screen_test.dart`

**Interfaces:**
- Produces: `String clubNameOf(String? clubId, Iterable<Club> clubs)` — `''` for null/unknown id.

- [x] **Step 1: Failing domain test** — append to `test/domain/models_test.dart` (inside `main`):

```dart
  group('clubNameOf', () {
    const clubs = [
      Club(id: 'c1', name: 'Sokol', colorIndex: 1),
      Club(id: 'c2', name: 'Veverky', colorIndex: 2),
    ];

    test('resolves a known club id to its current name', () {
      expect(clubNameOf('c2', clubs), 'Veverky');
    });

    test('is empty for no club and for a deleted club', () {
      expect(clubNameOf(null, clubs), '');
      expect(clubNameOf('gone', clubs), '');
    });
  });
```

Run: `flutter test test/domain/models_test.dart`
Expected: FAIL — `clubNameOf` undefined.

- [x] **Step 2: Implement** — in `lib/domain/models.dart` after the `Club` class:

```dart
/// Display name of [clubId] from the live club roster; '' when the profile
/// has no club or the club was deleted. Never read `profiles.club`: that
/// text is a copy taken at registration and goes stale the moment an admin
/// reassigns the club (set_player_club only moves club_id).
String clubNameOf(String? clubId, Iterable<Club> clubs) {
  if (clubId == null) return '';
  for (final club in clubs) {
    if (club.id == clubId) return club.name;
  }
  return '';
}
```

Run: `flutter test test/domain/models_test.dart`
Expected: PASS.

- [x] **Step 3: Failing widget test (players screen)** — append to `test/features/players_screen_test.dart`:

```dart
  testWidgets('pending and kiosk rows show the club from the roster, not the '
      'stale legacy text', (tester) async {
    const pending = Profile(
      id: 'pend',
      displayName: 'Nováček',
      club: 'Staré jméno',
      email: 'pend@example.com',
      role: Role.player,
      status: ProfileStatus.pending,
      clubId: 'c2',
    );
    await tester.pumpWidget(app([admin, pending]));
    await tester.pumpAndSettle();

    expect(find.text('Veverky'), findsOneWidget);
    expect(find.text('Staré jméno'), findsNothing);
  });
```

Run: `flutter test test/features/players_screen_test.dart`
Expected: FAIL (`Staré jméno` found).

- [x] **Step 4: players_screen.dart** — both `subtitle: p.club.isEmpty ? null : Text(p.club),` lines become:

```dart
                    subtitle: clubNameOf(p.clubId, clubs).isEmpty
                        ? null
                        : Text(clubNameOf(p.clubId, clubs)),
```

(`clubs` is already in scope in `build`.) Run the test again → PASS.

- [x] **Step 5: Profile screen test** — in `test/features/profile_screen_test.dart` change the `me` fixture to `club: '', clubId: 'c1',` and the `app()` overrides to:

```dart
      overrides: [
        myProfileProvider.overrideWith((ref) => Stream.value(profile)),
        clubsProvider.overrideWith(
          (ref) => Stream.value(const [Club(id: 'c1', name: 'TJ Sokol')]),
        ),
      ],
```

Run: `flutter test test/features/profile_screen_test.dart`
Expected: FAIL on `find.text('TJ Sokol')`.

- [x] **Step 6: profile_screen.dart** — in `build` after `final profile = …` add `final clubs = ref.watch(clubsProvider).value ?? const <Club>[];` and change the Oddíl tile to:

```dart
                      ListTile(
                        title: const Text('Oddíl'),
                        subtitle: Text(
                          clubNameOf(profile.clubId, clubs).isEmpty
                              ? '—'
                              : clubNameOf(profile.clubId, clubs),
                        ),
                      ),
```

Run: `flutter test test/features/profile_screen_test.dart`
Expected: PASS.

- [x] **Step 7: Verify + commit**

Run: `flutter analyze && flutter test`
Expected: clean; 213 tests pass.

```bash
git add lib/domain/models.dart lib/features/admin/players_screen.dart lib/features/profile/profile_screen.dart test
git commit -m "fix(profile): show the club from the clubs table, not the stale legacy text"
```

---

### Task 8: Record the audit + plan in git

- [x] **Step 1: Commit the docs**

```bash
git add docs/superpowers/specs/2026-09-02-cleanup-audit.md docs/superpowers/plans/2026-09-02-cleanup-1-quick-wins.md
git commit -m "docs: cleanup audit + plan 1 (quick wins)"
```

- [x] **Step 2: Final gate**

Run: `flutter analyze && flutter test`
Expected: `No issues found!`, `All tests passed!`. Stop the local stack: `supabase stop`. Do not push.

---

## Outcome (2026-09-02)

All eight tasks landed on `cleanup-1-quick-wins` (8 commits, not pushed).
`flutter analyze` clean, 213 tests green. Local stack: 0001–0016 apply,
the Vault guard/revoke/lookup behave as specified, `functions serve` returns
500 without `CANCEL_TOKEN_SECRET` and the "Odkaz neplatí" page with it.

Learned while executing:

- Without 0016 a fresh database from git fails **every** insert into
  `tenants`/`profiles`/`reservations`: pg_net rejects the placeholder host
  inside the trigger. 0016 is a fresh-install fix, not just hygiene.
- `supabase/tests/tenancy_rls.sql` now reaches line 34 and fails there:
  on the local stack `authenticated` has no SELECT/INSERT/UPDATE/DELETE on
  the public tables (only TRIGGER/REFERENCES/TRUNCATE). Migrations never
  record table grants — prod has them from the hosted default privileges.
  Plan 2 must add explicit grants in a migration before wiring the test
  into CI.
- Baseline test count on `main` is 210 (216 included the unmerged
  `sentry-filter-network` branch).

Before merging to main: create `notify_url` and `webhook_secret` in the
prod Vault (SQL editor, values in CICD.md §2), otherwise notifications
pause after deploy-backend applies 0016.
