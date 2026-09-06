# Moje tréninky — implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A second view beside the calendar — the player's upcoming trainings and the matches of the teams they follow — with bottom tabs on a phone and a rail on wide screens, opening at launch on the view chosen in the profile.

**Architecture:** Two profile columns (`followed_teams`, `default_view`) written directly by the player like `own_color`; a pure timeline builder in `domain/upcoming.dart`; a `MyTrainingsScreen` fed by the existing streams; `HomeShell` grows adaptive navigation and reads the launch view from the profile once. The Google Calendar integration is untouched — its team choice stays on the link; only the checkbox sheet is shared.

**Tech Stack:** Flutter 3.38 / Dart 3.10 (CI runs Dart 3.11 — copy nullable fields to locals before closures), Riverpod 3, Supabase (append-only migrations, `tool/schema_snapshot.sh`, `supabase/tests/tenancy_rls.sql`).

**Spec:** `docs/superpowers/specs/2026-09-06-upcoming-trainings-design.md`.

## Global Constraints

- Czech UI copy, English code and comments; every list alphabetical (`compareCzech`) or chronological.
- `flutter analyze` clean and `flutter test` green after every task (446 today). Local `supabase db reset` (never `--linked`) + `psql … -f supabase/tests/tenancy_rls.sql` ending in `ROLLBACK` for the migration.
- Commit per task with `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>`. Two PRs: Part 1 = Tasks 1–3 on branch `profile-teams-and-default-view`; Part 2 = Tasks 4–7 on branch `my-trainings-view` cut from `main` **after Part 1 is merged** (never stack on a feature branch).
- Widget tests inject the Api calls (`ProfileScreen.setOwnColor` pattern); the mocked HTTP client cannot serve `functions.invoke`, but these are plain PostgREST updates, which it can — assert on the PATCH when convenient, injection when simpler.
- `week_screen_test` pins `nowProvider`; the new screen tests do the same.

---

# Part 1 — profile: teams and the launch view (branch `profile-teams-and-default-view`)

### Task 1: Migration 0029 + SQL tests + snapshot + docs

**Files:**
- Create: `supabase/migrations/0029_profile_followed_teams_default_view.sql`
- Modify: `supabase/tests/tenancy_rls.sql` (append before the final `reset role; rollback;`), `docs/SCHEMA.md` (profiles row)
- Regenerate: `supabase/schema.sql`

**Interfaces:**
- Produces: columns `profiles.followed_teams text[]` (≤ 20) and `profiles.default_view text` (`'calendar' | 'trainings'`), both updatable on the own row by `authenticated`.

- [ ] **Step 1: Write the SQL test first (red)**

Append to `supabase/tests/tenancy_rls.sql` right before the last `reset role;\nrollback;`:

```sql
-- Followed teams + launch view (0029): own row only, inside the checks.
set local role authenticated;
set local request.jwt.claims =
  '{"sub":"10000000-0000-0000-0000-000000000001","role":"authenticated"}';
do $$
begin
  update profiles
    set followed_teams = array['SKK Veverky Brno A'], default_view = 'trainings'
  where id = '10000000-0000-0000-0000-000000000001';
  if (select followed_teams from profiles
      where id = '10000000-0000-0000-0000-000000000001') <> array['SKK Veverky Brno A']
     or (select default_view from profiles
      where id = '10000000-0000-0000-0000-000000000001') <> 'trainings' then
    raise exception 'FAIL: followed_teams / default_view did not stick on the own row';
  end if;
  update profiles set default_view = 'trainings'
  where id = '10000000-0000-0000-0000-000000000003';
  if (select default_view from profiles
      where id = '10000000-0000-0000-0000-000000000003') <> 'calendar' then
    raise exception 'FAIL: default_view changed on a foreign row';
  end if;
  begin
    update profiles set default_view = 'week'
    where id = '10000000-0000-0000-0000-000000000001';
    raise exception 'FAIL: an unknown default_view accepted';
  exception when check_violation then null;
  end;
  begin
    update profiles
      set followed_teams = (select array_agg('T' || g) from generate_series(1, 21) g)
    where id = '10000000-0000-0000-0000-000000000001';
    raise exception 'FAIL: 21 followed teams accepted';
  exception when check_violation then null;
  end;
  if has_column_privilege('anon', 'public.profiles', 'followed_teams', 'update')
     or has_column_privilege('anon', 'public.profiles', 'default_view', 'update') then
    raise exception 'FAIL: anon may update the new profile columns';
  end if;
  raise notice 'OK: followed_teams and default_view are editable on the own row only, inside the checks';
end $$;
```

- [ ] **Step 2: Run it to see it fail**

Run: `supabase db reset && psql postgresql://postgres:postgres@127.0.0.1:54322/postgres -X -v ON_ERROR_STOP=1 -f supabase/tests/tenancy_rls.sql 2>&1 | tail -3`
Expected: `ERROR:  column "followed_teams" of relation "profiles" does not exist`

- [ ] **Step 3: Write the migration**

`supabase/migrations/0029_profile_followed_teams_default_view.sql`:

```sql
-- 0029 — two profile choices for the new Moje tréninky view.
--
-- followed_teams: the teams whose matches the player wants to SEE in the
-- app's upcoming list. Display only — the Google Calendar sync keeps its own
-- choice on google_calendar_links.match_teams and is not touched here; a
-- player manages the two lists separately.
--
-- default_view: which view the app opens at launch — the calendar (today's
-- behaviour, hence the default) or the upcoming list. A tap in the app
-- changes the view for that run only; this is what the next launch reads.

alter table profiles
  add column followed_teams text[] not null default '{}'
    check (coalesce(array_length(followed_teams, 1), 0) <= 20),
  add column default_view text not null default 'calendar'
    check (default_view in ('calendar', 'trainings'));

comment on column profiles.followed_teams is
  'Teams whose matches the player sees in Moje tréninky (names as in priority_slots.home_team/away_team). Display only; the calendar sync has its own list on google_calendar_links.';
comment on column profiles.default_view is
  'View the app opens at launch: calendar | trainings.';

-- Own row only (profiles_update_own); the whole-row UPDATE stays revoked
-- (0001/0017) and these columns join display_name, fcm_token and own_color.
grant update (followed_teams, default_view) on profiles to authenticated;
```

- [ ] **Step 4: Run the suite to see it pass, refresh the snapshot**

Run: `supabase db reset 2>&1 | grep -E "0029|Finished" && psql postgresql://postgres:postgres@127.0.0.1:54322/postgres -X -v ON_ERROR_STOP=1 -f supabase/tests/tenancy_rls.sql 2>&1 | grep -E "followed_teams|FAIL|ROLLBACK" && tool/schema_snapshot.sh >/dev/null && git diff --stat supabase/schema.sql`
Expected: `NOTICE:  OK: followed_teams and default_view are editable …`, `ROLLBACK`, and a non-empty diff of `schema.sql`.

- [ ] **Step 5: Document**

In `docs/SCHEMA.md`, extend the `profiles` row's column list with: `` `followed_teams` (≤ 20 names, the Moje tréninky list — separate from the calendar's `match_teams`), `default_view` (`calendar` | `trainings`, what the app opens at launch); both own-row updatable (0029) ``.

- [ ] **Step 6: Commit**

```bash
git add supabase/migrations/0029_profile_followed_teams_default_view.sql supabase/tests/tenancy_rls.sql supabase/schema.sql docs/SCHEMA.md
git commit -m "feat(db): 0029 — followed_teams a default_view na profilu

Dva sloupce pro nový pohled Moje tréninky: sledované týmy (jen zobrazení,
výběr pro Google kalendář zůstává na propojení) a pohled po spuštění.
Zapisuje si je hráč sám na vlastním řádku jako own_color.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 2: `Profile.followedTeams`, `Profile.defaultView`, `HomeView`, two Api calls

**Files:**
- Modify: `lib/domain/models.dart` (enum + Profile), `lib/data/providers.dart` (next to `setOwnColor`, line ~703)
- Test: `test/domain/models_test.dart` (inside `group('Profile', …)`)

**Interfaces:**
- Produces: `enum HomeView { calendar, trainings }`; `Profile.followedTeams: List<String>`; `Profile.defaultView: HomeView`; `Api.setFollowedTeams(List<String>)`; `Api.setDefaultView(HomeView)`.

- [ ] **Step 1: Failing tests**

Add inside `group('Profile', () {` in `test/domain/models_test.dart`:

```dart
    test('fromJson reads followed_teams and default_view, with defaults', () {
      final p = Profile.fromJson({
        'id': 'u1',
        'display_name': 'Já',
        'role': 'player',
        'status': 'approved',
        'followed_teams': ['SKK Veverky Brno A', 'TJ Sokol Brno IV'],
        'default_view': 'trainings',
      });
      expect(p.followedTeams, ['SKK Veverky Brno A', 'TJ Sokol Brno IV']);
      expect(p.defaultView, HomeView.trainings);

      final bare = Profile.fromJson({
        'id': 'u2',
        'display_name': 'Ty',
        'role': 'player',
        'status': 'approved',
      });
      expect(bare.followedTeams, isEmpty);
      expect(bare.defaultView, HomeView.calendar);

      final odd = Profile.fromJson({
        'id': 'u3',
        'display_name': 'On',
        'role': 'player',
        'status': 'approved',
        'default_view': 'week',
      });
      expect(odd.defaultView, HomeView.calendar,
          reason: 'an unknown value falls back to the calendar');
    });
```

- [ ] **Step 2: Run to see it fail**

Run: `flutter test test/domain/models_test.dart 2>&1 | grep -E "Error:|Some tests failed" | head -3`
Expected: `Error: The getter 'followedTeams' isn't defined for the type 'Profile'.`

- [ ] **Step 3: Implement**

In `lib/domain/models.dart`, above `class Profile`:

```dart
/// Which view the app opens at launch (0029) — a profile choice; a tap on
/// a tab changes the view for that run only.
enum HomeView { calendar, trainings }
```

In `Profile`: constructor params `this.followedTeams = const [], this.defaultView = HomeView.calendar,`; fields (after `ownColor`):

```dart
  /// Teams whose matches show in Moje tréninky (0029) — names as they stand
  /// in priority_slots. Display only: the Google Calendar sync has its own
  /// list on the link, managed separately.
  final List<String> followedTeams;

  /// The view the app opens at launch (0029).
  final HomeView defaultView;
```

In `fromJson` (after `ownColor:`):

```dart
        followedTeams: [
          for (final t in json['followed_teams'] as List? ?? const [])
            t as String,
        ],
        defaultView: HomeView.values.asNameMap()[json['default_view']] ??
            HomeView.calendar,
```

In `lib/data/providers.dart`, right after `setOwnColor`:

```dart
  /// Which teams' matches the player sees in Moje tréninky (0029). Own row,
  /// like the colour; the calendar sync's own list is untouched.
  static Future<void> setFollowedTeams(List<String> teams) => _db
      .from('profiles')
      .update({'followed_teams': teams})
      .eq('id', currentUserId!);

  /// The view the app opens at launch (0029).
  static Future<void> setDefaultView(HomeView view) => _db
      .from('profiles')
      .update({'default_view': view.name})
      .eq('id', currentUserId!);
```

- [ ] **Step 4: Run to see it pass**

Run: `flutter analyze 2>&1 | tail -1 && flutter test test/domain/models_test.dart 2>&1 | grep -E "All tests passed|Some tests failed"`
Expected: `No issues found!` and `All tests passed!`

- [ ] **Step 5: Commit**

```bash
git add lib/domain/models.dart lib/data/providers.dart test/domain/models_test.dart
git commit -m "feat: Profile.followedTeams a defaultView, Api.setFollowedTeams/setDefaultView

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 3: Shared team picker sheet, „Moje týmy" and „Po spuštění" cards

**Files:**
- Create: `lib/features/profile/widgets/team_picker_sheet.dart`, `lib/features/profile/widgets/my_teams_card.dart`
- Modify: `lib/features/profile/widgets/calendar_link_card.dart` (`_editMatchTeams`), `lib/features/profile/profile_screen.dart` (constructor + two cards)
- Test: `test/features/profile_screen_test.dart`

**Interfaces:**
- Produces: `showTeamPickerSheet(context, {title, hint, chosenOf, onChanged})`; `MyTeamsCard({profile, setFollowedTeams})`; `ProfileScreen({…, setFollowedTeams = Api.setFollowedTeams, setDefaultView = Api.setDefaultView})`.

- [ ] **Step 1: Failing widget tests**

In `test/features/profile_screen_test.dart`, extend `app(...)`:

```dart
  Widget app(
    Profile profile, {
    bool calendarAvailable = false,
    CalendarLink link = CalendarLink.none,
    Future<void> Function(int color)? setOwnColor,
    Future<void> Function(List<String> teams)? setFollowedTeams,
    Future<void> Function(HomeView view)? setDefaultView,
    List<PrioritySlot> matches = const [],
  }) {
    …
        home: ProfileScreen(
          setOwnColor: setOwnColor ?? (_) async => throw StateError('unexpected'),
          setFollowedTeams:
              setFollowedTeams ?? (_) async => throw StateError('unexpected'),
          setDefaultView:
              setDefaultView ?? (_) async => throw StateError('unexpected'),
        ),
```

Add a group (reuse the file's `me`; a home match fixture gives the sheet a team to offer):

```dart
  group('Moje týmy and Po spuštění', () {
    final match = PrioritySlot(
      id: 'm1',
      date: Day(2026, 9, 11),
      startsAt: const HourMinute(18, 30),
      endsAt: const HourMinute(21, 30),
      type: PrioritySlot.fallbackMatchType,
      homeTeam: 'SKK Veverky Brno A',
      awayTeam: 'KK MS Brno D',
    );

    testWidgets('the card sums up the followed teams and the sheet ticks one',
        (tester) async {
      tester.view.physicalSize = const Size(800, 1800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final saved = <List<String>>[];
      await tester.pumpWidget(app(
        me,
        matches: [match],
        setFollowedTeams: (t) async => saved.add(t),
      ));
      await tester.pumpAndSettle();

      expect(find.text('Moje týmy'), findsOneWidget);
      expect(find.text('Žádný tým'), findsOneWidget);

      await tester.tap(find.text('Vybrat týmy…'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(CheckboxListTile, 'SKK Veverky Brno A'));
      await tester.pumpAndSettle();

      expect(saved, [
        ['SKK Veverky Brno A'],
      ]);
    });

    testWidgets('a followed team reads in the summary, and unticking drops it',
        (tester) async {
      tester.view.physicalSize = const Size(800, 1800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      const follower = Profile(
        id: 'me',
        displayName: 'Já Hráč',
        email: 'me@example.com',
        role: Role.player,
        status: ProfileStatus.approved,
        followedTeams: ['SKK Veverky Brno A'],
      );
      final saved = <List<String>>[];
      await tester.pumpWidget(app(
        follower,
        matches: [match],
        setFollowedTeams: (t) async => saved.add(t),
      ));
      await tester.pumpAndSettle();

      expect(find.text('SKK Veverky Brno A'), findsOneWidget);
      await tester.tap(find.text('Vybrat týmy…'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(CheckboxListTile, 'SKK Veverky Brno A'));
      await tester.pumpAndSettle();
      expect(saved, [<String>[]]);
    });

    testWidgets('Po spuštění saves the chosen launch view', (tester) async {
      tester.view.physicalSize = const Size(800, 1800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final saved = <HomeView>[];
      await tester.pumpWidget(app(me, setDefaultView: (v) async => saved.add(v)));
      await tester.pumpAndSettle();

      expect(find.text('Po spuštění'), findsOneWidget);
      await tester.tap(find.text('Moje tréninky'));
      await tester.pumpAndSettle();
      expect(saved, [HomeView.trainings]);
    });
  });
```

- [ ] **Step 2: Run to see it fail**

Run: `flutter test test/features/profile_screen_test.dart 2>&1 | grep -E "Error:|Some tests failed" | head -3`
Expected: `Error: No named parameter with the name 'setFollowedTeams'.`

- [ ] **Step 3: The shared sheet**

`lib/features/profile/widgets/team_picker_sheet.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/ui.dart';
import '../../../data/providers.dart';
import '../../../domain/collation.dart';

/// The checkbox sheet both the calendar card and the Moje týmy card open:
/// every team the schedule knows (home team of a home match, away team of
/// an away match) plus whatever is already chosen, so a team that vanished
/// from the schedule can still be unticked. Each toggle is saved at once by
/// [onChanged]; the chosen list is re-read through [chosenOf] on every
/// build, so the sheet follows the same stream the card watches.
Future<void> showTeamPickerSheet(
  BuildContext context, {
  required String title,
  required String hint,
  required List<String> Function(WidgetRef ref) chosenOf,
  required Future<void> Function(List<String> teams) onChanged,
}) {
  return showModalBottomSheet<void>(
    context: context,
    builder: (sheetContext) => Consumer(
      builder: (context, ref, _) {
        final chosen = chosenOf(ref);
        final teams = {...ref.watch(ourTeamsProvider), ...chosen}.toList()
          ..sort(compareCzech);
        return SafeArea(
          child: ListView(
            shrinkWrap: true,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
                child:
                    Text(title, style: Theme.of(context).textTheme.titleMedium),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: Text(hint),
              ),
              if (teams.isEmpty)
                const ListTile(
                  leading: Icon(Icons.sports_outlined),
                  title: Text('Zatím žádné zápasy v rozvrhu'),
                ),
              for (final team in teams)
                CheckboxListTile(
                  value: chosen.contains(team),
                  title: Text(team),
                  onChanged: (on) => tryAction(
                    context,
                    () => onChanged([
                      for (final t in chosen)
                        if (t != team) t,
                      if (on == true) team,
                    ]),
                  ),
                ),
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    ),
  );
}
```

In `calendar_link_card.dart`, replace the whole `_editMatchTeams` method body with:

```dart
  Future<void> _editMatchTeams() => showTeamPickerSheet(
        context,
        title: 'Zápasy v kalendáři',
        hint: 'Vyber svůj tým — jeho domácí i venkovní zápasy se přidají do '
            'kalendáře.',
        chosenOf: (ref) =>
            (ref.watch(myCalendarLinkProvider).value ?? CalendarLink.none)
                .matchTeams,
        onChanged: widget.setMatchTeams,
      );
```

and add `import 'team_picker_sheet.dart';` (drop the now-unused `compareCzech` import if the analyzer flags it).

- [ ] **Step 4: The two cards**

`lib/features/profile/widgets/my_teams_card.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../data/providers.dart';
import '../../../domain/models.dart';
import 'team_picker_sheet.dart';

/// Which teams' matches the player sees in Moje tréninky (0029). Its own
/// list — the calendar card keeps a separate one for the Google sync.
class MyTeamsCard extends ConsumerWidget {
  const MyTeamsCard({
    super.key,
    required this.profile,
    required this.setFollowedTeams,
  });

  final Profile profile;
  final Future<void> Function(List<String> teams) setFollowedTeams;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ListTile(
            leading: const Icon(Icons.sports_outlined),
            title: const Text('Moje týmy'),
            subtitle: Text(matchTeamsSummary(profile.followedTeams)),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: Align(
              alignment: Alignment.centerLeft,
              child: FilledButton.tonal(
                onPressed: () => showTeamPickerSheet(
                  context,
                  title: 'Moje týmy',
                  hint: 'Jejich domácí i venkovní zápasy uvidíš v Moje '
                      'tréninky. Do Google kalendáře jdou zápasy podle '
                      'vlastního výběru u kalendáře.',
                  chosenOf: (ref) =>
                      ref.watch(myProfileProvider).value?.followedTeams ??
                      const [],
                  onChanged: setFollowedTeams,
                ),
                child: const Text('Vybrat týmy…'),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
```

In `profile_screen.dart`: constructor gains

```dart
    this.setFollowedTeams = Api.setFollowedTeams,
    this.setDefaultView = Api.setDefaultView,
  …
  final Future<void> Function(List<String> teams) setFollowedTeams;
  final Future<void> Function(HomeView view) setDefaultView;
```

and between the colour card's trailing `const SizedBox(height: 16),` and the calendar card's `if (ref.watch(calendarAvailableProvider) …`:

```dart
                MyTeamsCard(
                  profile: profile,
                  setFollowedTeams: setFollowedTeams,
                ),
                const SizedBox(height: 16),
                // What opens at launch (0029). A tab tap changes the view for
                // one run; this is what the next launch reads.
                Card(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const ListTile(
                        title: Text('Po spuštění'),
                        subtitle: Text(
                          'Co appka otevře jako první. Přepnutí dole platí '
                          'do jejího zavření.',
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                        child: SegmentedButton<HomeView>(
                          segments: const [
                            ButtonSegment(
                              value: HomeView.calendar,
                              label: Text('Kalendář'),
                              icon: Icon(Icons.calendar_month_outlined),
                            ),
                            ButtonSegment(
                              value: HomeView.trainings,
                              label: Text('Moje tréninky'),
                              icon: Icon(Icons.event_available_outlined),
                            ),
                          ],
                          selected: {profile.defaultView},
                          onSelectionChanged: (chosen) => tryAction(
                            context,
                            () => setDefaultView(chosen.first),
                            errorText: friendlyDbError,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
```

with `import 'widgets/my_teams_card.dart';`.

- [ ] **Step 5: Run to see it pass; fix the card-order test**

Run: `flutter analyze 2>&1 | tail -1 && flutter test test/features/profile_screen_test.dart 2>&1 | grep -E "All tests passed|Some tests failed|\[E\]"`
Expected: green. If the existing card-order test (nick → colour → calendar → sign-out) fails, extend its expected order to nick → colour → Moje týmy → Po spuštění → calendar → sign-out (and its surface height if the ListView no longer builds the last cards).

- [ ] **Step 6: Full gate and commit**

Run: `flutter test 2>&1 | tr '\r' '\n' | grep -E "All tests passed|Some tests failed" | tail -1`
Expected: `All tests passed!`

```bash
git add lib/features/profile/widgets/team_picker_sheet.dart lib/features/profile/widgets/my_teams_card.dart lib/features/profile/widgets/calendar_link_card.dart lib/features/profile/profile_screen.dart test/features/profile_screen_test.dart
git commit -m "feat: karty Moje týmy a Po spuštění v profilu

Sledované týmy pro Moje tréninky mají vlastní seznam, nezávislý na výběru
pro Google kalendář; sdílí se jen zaškrtávací sheet. Po spuštění volí,
co appka otevře jako první.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

Then push, open the PR (`--base main`), wait for CI, and merge before starting Part 2.

---

# Part 2 — the list and the navigation (branch `my-trainings-view`, cut from `main` after Part 1 merged)

### Task 4: `domain/upcoming.dart` — the timeline builder

**Files:**
- Create: `lib/domain/upcoming.dart`
- Test: `test/domain/upcoming_test.dart`

**Interfaces:**
- Produces: `sealed class UpcomingItem { Day get date; HourMinute get startsAt; }`, `UpcomingTraining(reservation, block)`, `UpcomingMatch(slot)`, `UpcomingDay(date, items)`, `List<UpcomingDay> upcomingTimeline({reservations, blocks, slots, teams, today})`.

- [ ] **Step 1: Failing tests**

`test/domain/upcoming_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:rezervator/domain/models.dart';
import 'package:rezervator/domain/upcoming.dart';

void main() {
  final today = Day(2026, 9, 9);
  const b1 = TimeBlock(
    id: 'b1',
    startsAt: HourMinute(18, 0),
    endsAt: HourMinute(19, 0),
    position: 0,
    active: true,
  );
  const b2 = TimeBlock(
    id: 'b2',
    startsAt: HourMinute(19, 0),
    endsAt: HourMinute(20, 0),
    position: 1,
    active: true,
  );
  Reservation res(String id, Day date, {String block = 'b1', DateTime? cancelled}) =>
      Reservation(
        id: id,
        playerId: 'me',
        date: date,
        blockId: block,
        lane: 2,
        createdVia: 'app',
        createdAt: DateTime.utc(2026, 1, 1),
        cancelledAt: cancelled,
      );
  PrioritySlot match(String id, Day date, HourMinute start,
          {String home = 'SKK Veverky Brno A',
          String away = 'KK MS Brno D',
          bool isAway = false,
          String? parentId}) =>
      PrioritySlot(
        id: id,
        date: date,
        startsAt: start,
        endsAt: HourMinute(start.hour + 2, start.minute),
        type: PrioritySlot.fallbackMatchType,
        homeTeam: home,
        awayTeam: away,
        isAway: isAway,
        parentId: parentId,
      );

  test('days ascending, items by start, a training before a match at the '
      'same start', () {
    final days = upcomingTimeline(
      reservations: [res('r2', today.addDays(1), block: 'b2'), res('r1', today)],
      blocks: const [b1, b2],
      slots: [
        match('m1', today.addDays(1), const HourMinute(19, 0)),
        match('m0', today, const HourMinute(16, 0)),
      ],
      teams: const ['SKK Veverky Brno A'],
      today: today,
    );
    expect([for (final d in days) d.date], [today, today.addDays(1)]);
    expect(days[0].items.map((i) => i is UpcomingMatch ? 'm' : 't'), ['m', 't']);
    expect(
      days[1].items.map((i) => i is UpcomingMatch ? 'm' : 't'),
      ['t', 'm'],
      reason: 'r2 (19:00) sorts before m1 (19:00)',
    );
  });

  test('cancelled, past and orphaned reservations are dropped', () {
    final days = upcomingTimeline(
      reservations: [
        res('gone', today.addDays(2), cancelled: DateTime.utc(2026, 9, 1)),
        res('past', today.addDays(-1)),
        res('orphan', today.addDays(2), block: 'deleted-block'),
        res('ok', today.addDays(2)),
      ],
      blocks: const [b1],
      slots: const [],
      teams: const [],
      today: today,
    );
    expect(days, hasLength(1));
    expect((days.single.items.single as UpcomingTraining).reservation.id, 'ok');
  });

  test('matches: followed as home or away, away kept, úklid children and '
      'unfollowed skipped', () {
    final days = upcomingTimeline(
      reservations: const [],
      blocks: const [],
      slots: [
        match('home', today.addDays(1), const HourMinute(18, 0)),
        match('away', today.addDays(2), const HourMinute(18, 0),
            home: 'KK Blansko B', away: 'SKK Veverky Brno A', isAway: true),
        match('other', today.addDays(3), const HourMinute(18, 0),
            home: 'TJ Sokol Husovice', away: 'KK Vyškov'),
        match('child', today.addDays(1), const HourMinute(17, 30), parentId: 'home'),
      ],
      teams: const ['SKK Veverky Brno A'],
      today: today,
    );
    expect(
      [for (final d in days) for (final i in d.items) (i as UpcomingMatch).slot.id],
      ['home', 'away'],
    );
  });

  test('no followed teams means no matches; nothing at all means no days', () {
    final only = upcomingTimeline(
      reservations: const [],
      blocks: const [],
      slots: [match('m', today, const HourMinute(18, 0))],
      teams: const [],
      today: today,
    );
    expect(only, isEmpty);
  });
}
```

- [ ] **Step 2: Run to see it fail**

Run: `flutter test test/domain/upcoming_test.dart 2>&1 | grep -E "Error:|Some tests failed" | head -2`
Expected: `Error: Error when reading 'lib/domain/upcoming.dart'`

- [ ] **Step 3: Implement**

`lib/domain/upcoming.dart`:

```dart
/// What is coming for a player: their live future reservations and the
/// future matches of the teams they follow, one timeline by day. Pure Dart,
/// unit-tested; the screen only renders it.
library;

import 'models.dart';

sealed class UpcomingItem {
  const UpcomingItem();

  Day get date;
  HourMinute get startsAt;
}

/// One of the player's own reservations with the block it sits in.
class UpcomingTraining extends UpcomingItem {
  const UpcomingTraining(this.reservation, this.block);

  final Reservation reservation;
  final TimeBlock block;

  @override
  Day get date => reservation.date;
  @override
  HourMinute get startsAt => block.startsAt;
}

/// A match of a followed team — home or away.
class UpcomingMatch extends UpcomingItem {
  const UpcomingMatch(this.slot);

  final PrioritySlot slot;

  @override
  Day get date => slot.date;
  @override
  HourMinute get startsAt => slot.startsAt;
}

class UpcomingDay {
  UpcomingDay(this.date, this.items);

  final Day date;
  final List<UpcomingItem> items;
}

/// Live reservations from [today] on whose block still exists, plus match
/// slots (no úklid children) of [teams] from [today] on; days ascending,
/// within a day by start, a training before a match at the same start.
List<UpcomingDay> upcomingTimeline({
  required List<Reservation> reservations,
  required List<TimeBlock> blocks,
  required List<PrioritySlot> slots,
  required List<String> teams,
  required Day today,
}) {
  final blockById = {for (final b in blocks) b.id: b};
  final items = <UpcomingItem>[
    for (final r in reservations)
      if (r.isLive && !r.date.isBefore(today))
        if (blockById[r.blockId] case final block?)
          UpcomingTraining(r, block),
    for (final s in slots)
      if (s.type.isMatch && s.parentId == null && !s.date.isBefore(today))
        if (teams.contains(s.homeTeam) || teams.contains(s.awayTeam))
          UpcomingMatch(s),
  ];
  items.sort((a, b) {
    final byDate = a.date.compareTo(b.date);
    if (byDate != 0) return byDate;
    final byStart = a.startsAt.compareTo(b.startsAt);
    if (byStart != 0) return byStart;
    return (a is UpcomingMatch ? 1 : 0) - (b is UpcomingMatch ? 1 : 0);
  });
  final days = <UpcomingDay>[];
  for (final item in items) {
    if (days.isNotEmpty && days.last.date == item.date) {
      days.last.items.add(item);
    } else {
      days.add(UpcomingDay(item.date, [item]));
    }
  }
  return days;
}
```

- [ ] **Step 4: Run to see it pass, commit**

Run: `flutter analyze 2>&1 | tail -1 && flutter test test/domain/upcoming_test.dart 2>&1 | grep -E "All tests passed|Some tests failed"`
Expected: green.

```bash
git add lib/domain/upcoming.dart test/domain/upcoming_test.dart
git commit -m "feat(domain): časová osa Moje tréninky — rezervace a zápasy sledovaných týmů po dnech

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 5: `MyTrainingsScreen`

**Files:**
- Create: `lib/features/schedule/my_trainings_screen.dart`
- Test: `test/features/my_trainings_screen_test.dart`

**Interfaces:**
- Consumes: `upcomingTimeline`, `myActiveReservationsProvider`, `timeBlocksProvider`, `prioritySlotsProvider`, `myProfileProvider`, `nowProvider`, `dayFull`, `confirmDialog`, `tryAction`, `friendlyDbError`.
- Produces: `MyTrainingsScreen({trailing = const [], required onOpenCalendar, cancelReservation = _cancel})`.

- [ ] **Step 1: Failing tests**

`test/features/my_trainings_screen_test.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rezervator/data/clock.dart';
import 'package:rezervator/data/providers.dart';
import 'package:rezervator/domain/models.dart';
import 'package:rezervator/features/schedule/my_trainings_screen.dart';

void main() {
  final now = DateTime(2026, 9, 9, 10, 0); // středa
  final today = Day.fromDateTime(now);
  const b1 = TimeBlock(
    id: 'b1',
    startsAt: HourMinute(18, 0),
    endsAt: HourMinute(19, 0),
    position: 0,
    active: true,
  );
  const me = Profile(
    id: 'me',
    displayName: 'Já Hráč',
    email: 'me@example.com',
    role: Role.player,
    status: ProfileStatus.approved,
    followedTeams: ['SKK Veverky Brno A'],
  );
  const nobody = Profile(
    id: 'me',
    displayName: 'Já Hráč',
    email: 'me@example.com',
    role: Role.player,
    status: ProfileStatus.approved,
  );
  Reservation res(String id, Day date) => Reservation(
        id: id,
        playerId: 'me',
        date: date,
        blockId: 'b1',
        lane: 2,
        createdVia: 'app',
        createdAt: DateTime.utc(2026, 1, 1),
      );
  final match = PrioritySlot(
    id: 'm1',
    date: today.addDays(2),
    startsAt: const HourMinute(18, 30),
    endsAt: const HourMinute(21, 30),
    type: PrioritySlot.fallbackMatchType,
    homeTeam: 'SKK Veverky Brno A',
    awayTeam: 'KK MS Brno D',
    description: 'KP1 Sever',
  );

  Widget app({
    Profile profile = me,
    List<Reservation> reservations = const [],
    List<PrioritySlot> slots = const [],
    Future<void> Function(String id)? cancel,
    VoidCallback? onOpenCalendar,
  }) {
    return ProviderScope(
      overrides: [
        myProfileProvider.overrideWith((ref) => Stream.value(profile)),
        myActiveReservationsProvider.overrideWith((ref) => Stream.value(reservations)),
        timeBlocksProvider.overrideWith((ref) => Stream.value(const [b1])),
        prioritySlotsProvider.overrideWithValue(slots),
        nowProvider.overrideWith((ref) => Stream.value(now)),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: MyTrainingsScreen(
            onOpenCalendar: onOpenCalendar ?? () {},
            cancelReservation: cancel ?? (_) async => throw StateError('unexpected'),
          ),
        ),
      ),
    );
  }

  testWidgets('lists trainings and followed matches by day, today and '
      'tomorrow by name', (tester) async {
    await tester.pumpWidget(app(
      reservations: [res('r1', today), res('r2', today.addDays(1))],
      slots: [match],
    ));
    await tester.pumpAndSettle();

    expect(find.text('Moje tréninky'), findsOneWidget);
    expect(find.text('Dnes'), findsOneWidget);
    expect(find.text('Zítra'), findsOneWidget);
    expect(find.text('18:00–19:00 · Dráha 2'), findsNWidgets(2));
    expect(find.text('SKK Veverky Brno A – KK MS Brno D'), findsOneWidget);
    expect(find.text('18:30–21:30 · doma · KP1 Sever'), findsOneWidget);
    // Chronological: today's training above the match two days out.
    expect(
      tester.getTopLeft(find.text('Dnes')).dy,
      lessThan(tester.getTopLeft(find.text('SKK Veverky Brno A – KK MS Brno D')).dy),
    );
    expect(find.textContaining('Moje týmy'), findsNothing);
  });

  testWidgets('tapping a training asks, then cancels it', (tester) async {
    final cancelled = <String>[];
    await tester.pumpWidget(app(
      reservations: [res('r1', today.addDays(1))],
      cancel: (id) async => cancelled.add(id),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.text('18:00–19:00 · Dráha 2'));
    await tester.pumpAndSettle();
    expect(find.text('Zrušit rezervaci?'), findsOneWidget);
    await tester.tap(find.text('Zrušit rezervaci'));
    await tester.pumpAndSettle();

    expect(cancelled, ['r1']);
    expect(find.text('Rezervace zrušena.'), findsOneWidget);
  });

  testWidgets('empty: says so and the button opens the calendar', (tester) async {
    var opened = 0;
    await tester.pumpWidget(app(onOpenCalendar: () => opened++));
    await tester.pumpAndSettle();

    expect(find.text('Zatím nic.'), findsOneWidget);
    await tester.tap(find.text('Do kalendáře'));
    expect(opened, 1);
  });

  testWidgets('without followed teams the list ends with the hint', (tester) async {
    await tester.pumpWidget(app(
      profile: nobody,
      reservations: [res('r1', today)],
      slots: [match],
    ));
    await tester.pumpAndSettle();

    expect(find.text('SKK Veverky Brno A – KK MS Brno D'), findsNothing);
    expect(find.textContaining('Moje týmy'), findsOneWidget);
  });
}
```

- [ ] **Step 2: Run to see it fail**

Run: `flutter test test/features/my_trainings_screen_test.dart 2>&1 | grep -E "Error:|Some tests failed" | head -2`
Expected: `Error: Error when reading 'lib/features/schedule/my_trainings_screen.dart'`

- [ ] **Step 3: Implement**

`lib/features/schedule/my_trainings_screen.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/ui.dart';
import '../../data/clock.dart';
import '../../data/providers.dart';
import '../../domain/models.dart';
import '../../domain/upcoming.dart';
import '../profile/profile_screen.dart';

/// The second view beside the calendar: what is coming for the player — the
/// trainings they booked and the matches of the teams they follow, by day.
/// A training can be cancelled here (own future reservation, the same
/// confirm as the calendar); matches are read-only.
class MyTrainingsScreen extends ConsumerWidget {
  const MyTrainingsScreen({
    super.key,
    this.trailing = const [],
    required this.onOpenCalendar,
    this.cancelReservation = _cancel,
  });

  /// The shell's icons, on the same top line as the title — like the week
  /// header of the calendar.
  final List<Widget> trailing;

  /// „Do kalendáře" in the empty state: the shell switches the view.
  final VoidCallback onOpenCalendar;

  /// Injectable for widget tests (the Api one needs a live client).
  final Future<void> Function(String id) cancelReservation;

  static Future<void> _cancel(String id) => Api.cancelReservation(id);

  Future<void> _confirmCancel(BuildContext context, UpcomingTraining t) async {
    final ok = await confirmDialog(
      context,
      title: 'Zrušit rezervaci?',
      message: '${dayFull(t.date)} · ${t.block.label} · Dráha ${t.reservation.lane}',
      confirmLabel: 'Zrušit rezervaci',
      cancelLabel: 'Zpět',
    );
    if (!ok || !context.mounted) return;
    await tryAction(
      context,
      () => cancelReservation(t.reservation.id),
      success: 'Rezervace zrušena.',
      errorText: friendlyDbError,
    );
  }

  static String _dayLabel(Day date, Day today) {
    if (date == today) return 'Dnes';
    if (date == today.addDays(1)) return 'Zítra';
    return dayFull(date);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final now = ref.watch(nowProvider).value ?? DateTime.now();
    final today = Day.fromDateTime(now);
    final profile = ref.watch(myProfileProvider).value;
    final teams = profile?.followedTeams ?? const <String>[];
    final days = upcomingTimeline(
      reservations: ref.watch(myActiveReservationsProvider).value ?? const [],
      blocks: ref.watch(timeBlocksProvider).value ?? const [],
      slots: ref.watch(prioritySlotsProvider),
      teams: teams,
      today: today,
    );
    final theme = Theme.of(context);

    final header = Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 8, 0),
      child: Row(
        children: [
          Expanded(
            child: Text('Moje tréninky', style: theme.textTheme.titleLarge),
          ),
          ...trailing,
        ],
      ),
    );

    if (days.isEmpty) {
      return Column(
        children: [
          header,
          Expanded(
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('Zatím nic.', style: theme.textTheme.titleMedium),
                  const SizedBox(height: 4),
                  const Text('Trénink si rezervuješ v kalendáři.'),
                  const SizedBox(height: 16),
                  FilledButton.tonal(
                    onPressed: onOpenCalendar,
                    child: const Text('Do kalendáře'),
                  ),
                ],
              ),
            ),
          ),
        ],
      );
    }

    return Column(
      children: [
        header,
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(8, 4, 8, 24),
            children: [
              for (final day in days) ...[
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
                  child: Text(
                    _dayLabel(day.date, today),
                    style: theme.textTheme.titleSmall,
                  ),
                ),
                for (final item in day.items)
                  switch (item) {
                    UpcomingTraining() => ListTile(
                        leading: const Icon(Icons.sports_outlined),
                        title: Text(
                          '${item.block.label} · Dráha ${item.reservation.lane}',
                        ),
                        trailing: const Icon(Icons.close),
                        onTap: () => _confirmCancel(context, item),
                      ),
                    UpcomingMatch() => ListTile(
                        leading: const Icon(Icons.emoji_events_outlined),
                        title: Text(item.slot.title),
                        subtitle: Text([
                          '${item.slot.startsAt.display()}–'
                              '${item.slot.endsAt.display()}',
                          item.slot.isAway ? 'venku' : 'doma',
                          if (item.slot.description.isNotEmpty)
                            item.slot.description,
                        ].join(' · ')),
                      ),
                  },
              ],
              if (teams.isEmpty)
                ListTile(
                  leading: Icon(Icons.info_outline,
                      color: theme.colorScheme.outline),
                  title: Text(
                    'Zápasy svých týmů tu uvidíš, když si je vybereš v '
                    'Můj profil → Moje týmy.',
                    style: theme.textTheme.bodySmall,
                  ),
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const ProfileScreen()),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}
```

Note: `TimeBlock.label` is `'18:00–19:00'` (en dash, `_pad`), which the tests assert; check the exact glyph in `models.dart:354` if a text finder misses.

- [ ] **Step 4: Run to see it pass, commit**

Run: `flutter analyze 2>&1 | tail -1 && flutter test test/features/my_trainings_screen_test.dart 2>&1 | grep -E "All tests passed|Some tests failed|\[E\]"`
Expected: green.

```bash
git add lib/features/schedule/my_trainings_screen.dart test/features/my_trainings_screen_test.dart
git commit -m "feat: obrazovka Moje tréninky — rezervace a zápasy sledovaných týmů po dnech

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 6: `HomeShell` — two views, adaptive navigation, launch view from the profile

**Files:**
- Modify: `lib/features/schedule/home_shell.dart`
- Test: `test/features/home_shell_test.dart`

**Interfaces:**
- Consumes: `HomeView`, `Profile.defaultView`, `WeekScreen(trailing)`, `MyTrainingsScreen(trailing, onOpenCalendar)`.
- Produces: `HomeShell` as a `ConsumerStatefulWidget`; bottom `NavigationBar` when `MediaQuery.sizeOf(context).shortestSide < 600`, else a left `NavigationRail`.

- [ ] **Step 1: Failing tests**

In `test/features/home_shell_test.dart`, add to the imports `import 'package:rezervator/features/schedule/my_trainings_screen.dart';` and `import 'package:rezervator/features/schedule/week_screen.dart';`, give `app` a `Stream<Profile>? profileStream` parameter used as `myProfileProvider.overrideWith((ref) => profileStream ?? Stream.value(profile))`, and append:

```dart
  const listFirst = Profile(
    id: 'me',
    displayName: 'Já Hráč',
    email: 'me@example.com',
    role: Role.player,
    status: ProfileStatus.approved,
    defaultView: HomeView.trainings,
  );

  void phone(WidgetTester tester) {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  void wide(WidgetTester tester) {
    tester.view.physicalSize = const Size(1600, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  group('two views', () {
    testWidgets('opens on the profile\'s launch view: calendar by default',
        (tester) async {
      phone(tester);
      await tester.pumpWidget(app());
      await tester.pumpAndSettle();
      expect(find.byType(WeekScreen), findsOneWidget);
      expect(find.byType(MyTrainingsScreen), findsNothing);
    });

    testWidgets('…and on the list when the profile says so', (tester) async {
      phone(tester);
      await tester.pumpWidget(app(profile: listFirst));
      await tester.pumpAndSettle();
      expect(find.byType(MyTrainingsScreen), findsOneWidget);
      expect(find.byType(WeekScreen), findsNothing);
    });

    testWidgets('the launch view is read once; a later profile change does '
        'not move the app, a tap does', (tester) async {
      phone(tester);
      final profiles = StreamController<Profile>();
      await tester.pumpWidget(app(profileStream: profiles.stream));
      profiles.add(me); // calendar-first
      await tester.pumpAndSettle();
      expect(find.byType(WeekScreen), findsOneWidget);

      // The profile now says list-first (changed in Můj profil meanwhile);
      // the running app stays where it is.
      profiles.add(listFirst);
      await tester.pumpAndSettle();
      expect(find.byType(WeekScreen), findsOneWidget);

      await tester.tap(find.text('Moje tréninky'));
      await tester.pumpAndSettle();
      expect(find.byType(MyTrainingsScreen), findsOneWidget);
      await profiles.close();
    });

    testWidgets('a phone gets bottom tabs, a wide screen a rail', (tester) async {
      phone(tester);
      await tester.pumpWidget(app());
      await tester.pumpAndSettle();
      expect(find.byType(NavigationBar), findsOneWidget);
      expect(find.byType(NavigationRail), findsNothing);
    });

    testWidgets('…rail on a wide screen, and it switches too', (tester) async {
      wide(tester);
      await tester.pumpWidget(app());
      await tester.pumpAndSettle();
      expect(find.byType(NavigationRail), findsOneWidget);
      expect(find.byType(NavigationBar), findsNothing);

      await tester.tap(find.text('Moje tréninky'));
      await tester.pumpAndSettle();
      expect(find.byType(MyTrainingsScreen), findsOneWidget);
    });

    testWidgets('the banners stay above the view on the list too', (tester) async {
      phone(tester);
      await tester.pumpWidget(app(profile: visiting));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Moje tréninky'));
      await tester.pumpAndSettle();
      expect(find.text('Prohlížíš kuželnu Demo'), findsOneWidget);
      expect(find.byType(MyTrainingsScreen), findsOneWidget);
    });
  });
```

The `visiting` fixture has `defaultView` calendar; its tab tap works because `MyTrainingsScreen` reads the same overridden providers. If `find.text('Moje tréninky')` matches both a destination and the screen title after switching, tap `find.text(…).first` before the switch only (the title is not there yet).

- [ ] **Step 2: Run to see it fail**

Run: `flutter test test/features/home_shell_test.dart 2>&1 | grep -E "Error:|Expected|Some tests failed" | head -3`
Expected: `Error: No named parameter with the name 'profileStream'.` (then, after adding it, failures on `NavigationBar` / `MyTrainingsScreen` not found).

- [ ] **Step 3: Implement**

Rewrite `lib/features/schedule/home_shell.dart` — keep `_goHome`, the banners and the `actions` list exactly as they are; the class becomes:

```dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/ui.dart';
import '../../data/providers.dart';
import '../../domain/models.dart';
import '../admin/admin_screen.dart';
import '../profile/profile_screen.dart';
import 'my_trainings_screen.dart';
import 'week_screen.dart';

/// The signed-in home: two views — the calendar and Moje tréninky — behind
/// bottom tabs on a phone and a rail on a wide screen. Which one opens at
/// launch is the profile's choice; a tap changes it for this run only.
class HomeShell extends ConsumerStatefulWidget {
  const HomeShell({super.key});

  @override
  ConsumerState<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends ConsumerState<HomeShell> {
  /// Tapped in this run — wins over the profile's launch choice.
  HomeView? _chosen;

  /// The profile's choice as it stood when the shell first saw a profile.
  /// Captured once on purpose: changing it in Můj profil must not yank the
  /// running app to the other view.
  HomeView? _atLaunch;

  Future<void> _goHome(BuildContext context, String homeTenantId) async {
    … // unchanged body, `ref` is the state's
  }

  @override
  Widget build(BuildContext context) {
    final profile = ref.watch(myProfileProvider).value;
    _atLaunch ??= profile?.defaultView;
    final view = _chosen ?? _atLaunch ?? HomeView.calendar;
    final offline = ref.watch(offlineProvider).value ?? false;
    final visiting = profile?.isVisiting ?? false;
    final visitingName = visiting
        ? ref.watch(tenantNameProvider(profile!.tenantId)).value
        : null;
    final actions = [ … unchanged … ];

    final content = switch (view) {
      HomeView.calendar => WeekScreen(trailing: actions),
      HomeView.trainings => MyTrainingsScreen(
          trailing: actions,
          onOpenCalendar: () => setState(() => _chosen = HomeView.calendar),
        ),
    };
    final body = Column(
      children: [
        if (offline) … unchanged banner …,
        if (visiting) … unchanged banner …,
        Expanded(child: content),
      ],
    );

    // A phone in either orientation gets tabs; a tablet or the desktop web
    // a rail on the left — same two destinations.
    final compact = MediaQuery.sizeOf(context).shortestSide < 600;
    void select(int index) => setState(() => _chosen = HomeView.values[index]);

    return Scaffold(
      body: SafeArea(
        child: compact
            ? body
            : Row(
                children: [
                  NavigationRail(
                    selectedIndex: view.index,
                    onDestinationSelected: select,
                    labelType: NavigationRailLabelType.all,
                    destinations: const [
                      NavigationRailDestination(
                        icon: Icon(Icons.calendar_month_outlined),
                        selectedIcon: Icon(Icons.calendar_month),
                        label: Text('Kalendář'),
                      ),
                      NavigationRailDestination(
                        icon: Icon(Icons.event_available_outlined),
                        selectedIcon: Icon(Icons.event_available),
                        label: Text('Moje tréninky'),
                      ),
                    ],
                  ),
                  const VerticalDivider(width: 1),
                  Expanded(child: body),
                ],
              ),
      ),
      bottomNavigationBar: compact
          ? NavigationBar(
              selectedIndex: view.index,
              onDestinationSelected: select,
              destinations: const [
                NavigationDestination(
                  icon: Icon(Icons.calendar_month_outlined),
                  selectedIcon: Icon(Icons.calendar_month),
                  label: 'Kalendář',
                ),
                NavigationDestination(
                  icon: Icon(Icons.event_available_outlined),
                  selectedIcon: Icon(Icons.event_available),
                  label: 'Moje tréninky',
                ),
              ],
            )
          : null,
    );
  }
}
```

(`_goHome` loses its `WidgetRef ref` parameter — the state has `ref`; update its one call site in the visiting banner.)

- [ ] **Step 4: Run to see it pass; full gate**

Run: `flutter analyze 2>&1 | tail -1 && flutter test 2>&1 | tr '\r' '\n' | grep -E "All tests passed|Some tests failed|\[E\]" | tail -3`
Expected: green. If `week_screen_test` or `kiosk_test` break on the `HomeShell` signature, they do not use it — investigate before changing them.

- [ ] **Step 5: Commit**

```bash
git add lib/features/schedule/home_shell.dart test/features/home_shell_test.dart
git commit -m "feat: dva pohledy — Kalendář a Moje tréninky, taby dole / lišta vlevo

Po spuštění se otevře pohled z profilu; ťuknutí platí do zavření appky.
Telefon má dole dva taby, tablet a desktopový web lištu vlevo.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 7: Changelog and local check

**Files:**
- Modify: `lib/features/profile/changelog_data.dart`

- [ ] **Step 1: The web-only entry** (top of `appChangelog`; date = the day the PR merges):

```dart
  Release(null, '<d. m. 2026>', [
    'Nový pohled Moje tréninky: co mě čeká — moje rezervace a zápasy mých '
        'týmů, po dnech. Na telefonu taby dole, na webu lišta vlevo.',
    'V Můj profil si vybereš týmy, jejichž zápasy uvidíš, a co se má po '
        'spuštění otevřít jako první.',
  ]),
```

- [ ] **Step 2: Gate and commit**

Run: `flutter test test/changelog_test.dart 2>&1 | grep -E "All tests passed|Some tests failed" && flutter test 2>&1 | tr '\r' '\n' | grep -E "All tests passed|Some tests failed" | tail -1`
Expected: green.

```bash
git add lib/features/profile/changelog_data.dart
git commit -m "docs: changelog — Moje tréninky

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

- [ ] **Step 3: See it** — build the local web (`flutter build web --dart-define=SUPABASE_URL=http://127.0.0.1:54321 --dart-define=SUPABASE_ANON_KEY=<local anon>`) and open http://localhost:8765: the rail on the desktop, the tabs at a phone width (`resize_window mobile`), the list with the imported matches of a followed team. Then push, open the PR (`--base main`), wait for CI.
