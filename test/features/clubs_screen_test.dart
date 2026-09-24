import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rezervator/data/providers.dart';
import 'package:rezervator/domain/models.dart';
import 'package:rezervator/features/admin/clubs_screen.dart';
import 'package:rezervator/features/admin/widgets/form_fields.dart';

/// Smoke test for the clubs admin list: renders for an admin, shows its
/// empty state, the ČKA sync card (0045), teams grouped under their club,
/// and the FAB opens the add dialog (never saved — that would hit the RPC).
void main() {
  const admin = Profile(
    id: 'admin1',
    displayName: 'Správce',
    email: 'admin@example.com',
    role: Role.admin,
    status: ProfileStatus.approved,
  );

  const clubs = [
    Club(id: 'c1', name: 'Sokol Dlouhá Lhota', colorIndex: 1),
    Club(id: 'c2', name: 'Veverky', colorIndex: 2),
  ];

  // One ProviderScope per test: a second pumpWidget does not swap overrides.
  Widget app(
    List<Club> clubs, {
    List<Team> teams = const [],
    FederationSync sync = FederationSync.none,
    Stream<FederationSync>? syncStream,
    Future<void> Function(String venueSlug, bool enabled)? saveFederation,
    Future<void> Function()? discoverTeams,
    Future<void> Function()? syncNow,
    Future<void> Function(Team team,
            {required String name, String? clubId, required bool active})?
        updateTeam,
  }) =>
      ProviderScope(
        overrides: [
          myProfileProvider.overrideWith((ref) => Stream.value(admin)),
          clubsProvider.overrideWith((ref) => Stream.value(clubs)),
          teamsProvider.overrideWith((ref) => Stream.value(teams)),
          federationSyncProvider
              .overrideWith((ref) => syncStream ?? Stream.value(sync)),
        ],
        child: MaterialApp(
          home: ClubsScreen(
            saveFederation: saveFederation ?? (_, _) async {},
            discoverTeams: discoverTeams ?? () async {},
            syncNow: syncNow ?? () async {},
            updateTeam: updateTeam ??
                (_, {required String name, String? clubId, required bool active}) async {},
          ),
        ),
      );

  // The ČKA card makes the screen taller than the 600px default test
  // surface, which would clip the club/team rows out of the sliver's build
  // range before a finder ever sees them — every test widens it first.
  Future<void> pumpApp(WidgetTester tester, Widget widget) async {
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(widget);
    await tester.pumpAndSettle();
  }

  testWidgets('renders the title and one row per club for an admin',
      (tester) async {
    await pumpApp(tester, app(clubs));

    expect(find.text('Oddíly'), findsOneWidget);
    expect(find.text('Sokol Dlouhá Lhota'), findsOneWidget);
    expect(find.text('Veverky'), findsOneWidget);
    expect(find.byType(ColorDot), findsNWidgets(2));
    expect(find.byIcon(Icons.delete_outline), findsNWidgets(2));
    expect(find.text('Zatím žádné oddíly.'), findsNothing);
  });

  testWidgets('shows the empty state without clubs', (tester) async {
    await pumpApp(tester, app(const []));

    expect(find.text('Oddíly'), findsOneWidget);
    expect(find.text('Zatím žádné oddíly.'), findsOneWidget);
    expect(find.byType(ColorDot), findsNothing);
  });

  testWidgets('the FAB opens the add dialog', (tester) async {
    await pumpApp(tester, app(clubs));

    await tester.tap(find.byType(FloatingActionButton));
    await tester.pumpAndSettle();

    final dialog = find.byType(AlertDialog);
    expect(dialog, findsOneWidget);
    expect(
      find.descendant(of: dialog, matching: find.text('Přidat oddíl')),
      findsOneWidget,
    );
    expect(find.text('Název'), findsOneWidget);
    // The ČKA card has its own Uložit button — scope to the dialog.
    expect(
      find.descendant(of: dialog, matching: find.text('Uložit')),
      findsOneWidget,
    );

    await tester.tap(find.text('Zrušit'));
    await tester.pumpAndSettle();
    expect(dialog, findsNothing);
  });

  testWidgets('an empty name is refused before anything is saved',
      (tester) async {
    await pumpApp(tester, app(clubs));
    await tester.tap(find.byType(FloatingActionButton));
    await tester.pumpAndSettle();

    // The ČKA card has its own Uložit button — scope to the dialog.
    await tester.tap(find.descendant(
      of: find.byType(AlertDialog),
      matching: find.text('Uložit'),
    ));
    await tester.pumpAndSettle();

    expect(find.text('Vyplň název oddílu.'), findsOneWidget);
    expect(find.byType(AlertDialog), findsOneWidget); // still open
  });

  group('federation sync card (0045)', () {
    testWidgets('teams render under their club; a team with no known club '
        'sits under Nezařazené týmy', (tester) async {
      const teams = [
        Team(
          id: 't1',
          name: 'Veverky A',
          clubId: 'c2',
          competitionName: 'OP I. třída',
        ),
        Team(id: 't2', name: 'Toulaví'), // clubId: null
      ];
      await pumpApp(tester, app(clubs, teams: teams));

      expect(find.text('Veverky A'), findsOneWidget);
      expect(find.text('OP I. třída'), findsOneWidget);
      expect(find.text('Nezařazené týmy'), findsOneWidget);
      expect(find.text('Toulaví'), findsOneWidget);
      expect(find.text('bez soutěže'), findsOneWidget);

      final clubY = tester.getTopLeft(find.text('Veverky')).dy;
      final teamY = tester.getTopLeft(find.text('Veverky A')).dy;
      final headerY = tester.getTopLeft(find.text('Nezařazené týmy')).dy;
      final unassignedY = tester.getTopLeft(find.text('Toulaví')).dy;
      expect(clubY, lessThan(teamY));
      expect(teamY, lessThan(headerY));
      expect(headerY, lessThan(unassignedY));
    });

    testWidgets(
        'a team whose club was deleted sits under Nezařazené týmy too',
        (tester) async {
      const teams = [
        Team(
          id: 't1',
          name: 'Bývalí Nešemice',
          clubId: 'gone', // no club in `clubs` has this id
          competitionName: 'OP II. třída',
        ),
      ];
      await pumpApp(tester, app(clubs, teams: teams));

      expect(find.text('Nezařazené týmy'), findsOneWidget);
      expect(find.text('Bývalí Nešemice'), findsOneWidget);
      expect(find.text('OP II. třída'), findsOneWidget);
    });

    testWidgets(
        'unconfigured sync seeds the default slug and disables Načíst týmy',
        (tester) async {
      await pumpApp(tester, app(clubs));

      expect(find.text('tj-sokol-brno-iv'), findsOneWidget);
      final button = tester.widget<OutlinedButton>(
          find.widgetWithText(OutlinedButton, 'Načíst týmy z webu'));
      expect(button.onPressed, isNull);
    });

    testWidgets('saving the slug calls saveFederation with the typed value',
        (tester) async {
      String? savedSlug;
      bool? savedEnabled;
      await pumpApp(
        tester,
        app(
          clubs,
          saveFederation: (slug, enabled) async {
            savedSlug = slug;
            savedEnabled = enabled;
          },
        ),
      );

      await tester.enterText(
          find.widgetWithText(TextField, 'tj-sokol-brno-iv'),
          'ks-devitka-brno');
      await tester.tap(find.text('Stahovat automaticky'));
      await tester.tap(find.text('Uložit'));
      await tester.pumpAndSettle();

      expect(savedSlug, 'ks-devitka-brno');
      expect(savedEnabled, isTrue);
    });

    testWidgets(
        'a sync row that arrives after the first frame seeds the form; '
        'Uložit keeps it', (tester) async {
      final rows = StreamController<FederationSync>();
      addTearDown(rows.close);
      String? savedSlug;
      bool? savedEnabled;
      await pumpApp(
        tester,
        app(
          clubs,
          syncStream: rows.stream,
          saveFederation: (slug, enabled) async {
            savedSlug = slug;
            savedEnabled = enabled;
          },
        ),
      );

      final saveBefore = tester.widget<FilledButton>(
          find.widgetWithText(FilledButton, 'Uložit'));
      expect(saveBefore.onPressed, isNull);

      rows.add(const FederationSync(
          venueSlug: 'ks-devitka-brno', enabled: true));
      await tester.pumpAndSettle();

      expect(find.widgetWithText(TextField, 'ks-devitka-brno'), findsOneWidget);
      final toggle = tester.widget<SwitchListTile>(
          find.widgetWithText(SwitchListTile, 'Stahovat automaticky'));
      expect(toggle.value, isTrue);

      await tester.tap(find.text('Uložit'));
      await tester.pumpAndSettle();

      expect(savedSlug, 'ks-devitka-brno');
      expect(savedEnabled, isTrue);
    });

    testWidgets(
        'a configured+enabled sync enables both actions and shows the error',
        (tester) async {
      var discovered = false;
      var synced = false;
      await pumpApp(
        tester,
        app(
          clubs,
          sync: const FederationSync(
            venueSlug: 'tj-sokol-brno-iv',
            enabled: true,
            lastError: 'boom',
          ),
          discoverTeams: () async => discovered = true,
          syncNow: () async => synced = true,
        ),
      );

      expect(find.text('Chyba: boom'), findsOneWidget);

      final discoverButton = tester.widget<OutlinedButton>(
          find.widgetWithText(OutlinedButton, 'Načíst týmy z webu'));
      final syncButton = tester.widget<OutlinedButton>(
          find.widgetWithText(OutlinedButton, 'Synchronizovat teď'));
      expect(discoverButton.onPressed, isNotNull);
      expect(syncButton.onPressed, isNotNull);

      await tester.tap(find.widgetWithText(OutlinedButton, 'Načíst týmy z webu'));
      await tester.pumpAndSettle();
      expect(discovered, isTrue);

      await tester.tap(find.widgetWithText(OutlinedButton, 'Synchronizovat teď'));
      await tester.pumpAndSettle();
      expect(synced, isTrue);
    });

    testWidgets('toggling a team switch calls updateTeam with the flip',
        (tester) async {
      const team = Team(
        id: 't1',
        name: 'Veverky A',
        clubId: 'c2',
        competitionName: 'OP I. třída',
      );
      Team? capturedTeam;
      String? capturedName;
      String? capturedClubId;
      bool? capturedActive;
      await pumpApp(
        tester,
        app(
          clubs,
          teams: const [team],
          updateTeam: (t,
              {required String name,
              String? clubId,
              required bool active}) async {
            capturedTeam = t;
            capturedName = name;
            capturedClubId = clubId;
            capturedActive = active;
          },
        ),
      );

      // Two switches exist ("Stahovat automaticky" on the card and this
      // team's own) — scope to the team's tile.
      final teamSwitch = find.descendant(
        of: find.ancestor(
            of: find.text('Veverky A'), matching: find.byType(ListTile)),
        matching: find.byType(Switch),
      );
      await tester.tap(teamSwitch);
      await tester.pumpAndSettle();

      expect(capturedTeam, team);
      expect(capturedName, team.name);
      expect(capturedClubId, team.clubId);
      expect(capturedActive, isFalse);
    });

    testWidgets(
        'editing a team via its dialog calls updateTeam with the new values',
        (tester) async {
      const team = Team(
        id: 't1',
        name: 'Brno IV',
        clubId: 'c1',
        siteName: 'TJ Sokol Brno IV',
        competitionName: 'OP I. třída',
      );
      Team? capturedTeam;
      String? capturedName;
      String? capturedClubId;
      bool? capturedActive;
      await pumpApp(
        tester,
        app(
          clubs,
          teams: const [team],
          updateTeam: (t,
              {required String name,
              String? clubId,
              required bool active}) async {
            capturedTeam = t;
            capturedName = name;
            capturedClubId = clubId;
            capturedActive = active;
          },
        ),
      );

      await tester.tap(find.text('Brno IV'));
      await tester.pumpAndSettle();

      expect(find.text('Tým'), findsOneWidget);
      expect(find.text('Na webu: TJ Sokol Brno IV · OP I. třída'),
          findsOneWidget);

      await tester.enterText(
          find.widgetWithText(TextField, 'Brno IV'), 'Brno IV A');
      await tester.tap(find.byType(DropdownButtonFormField<String?>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Bez oddílu').last);
      await tester.pumpAndSettle();

      // The ČKA card has its own Uložit button — scope to the dialog.
      await tester.tap(find.descendant(
        of: find.byType(AlertDialog),
        matching: find.text('Uložit'),
      ));
      await tester.pumpAndSettle();

      expect(capturedTeam, team);
      expect(capturedName, 'Brno IV A');
      expect(capturedClubId, isNull);
      expect(capturedActive, isTrue);
    });

    testWidgets('the team name stops at the 80 characters teams.name allows',
        (tester) async {
      const team = Team(
        id: 't1',
        name: 'Brno IV',
        clubId: 'c1',
        siteName: 'TJ Sokol Brno IV',
        competitionName: 'OP I. třída',
      );
      String? capturedName;
      await pumpApp(
        tester,
        app(
          clubs,
          teams: const [team],
          updateTeam: (t,
              {required String name,
              String? clubId,
              required bool active}) async {
            capturedName = name;
          },
        ),
      );

      await tester.tap(find.text('Brno IV'));
      await tester.pumpAndSettle();
      await tester.enterText(
          find.widgetWithText(TextField, 'Brno IV'), 'x' * 100);
      await tester.tap(find.descendant(
        of: find.byType(AlertDialog),
        matching: find.text('Uložit'),
      ));
      await tester.pumpAndSettle();

      expect(capturedName, 'x' * 80);
    });
  });
}
