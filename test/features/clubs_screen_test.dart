import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rezervator/data/providers.dart';
import 'package:rezervator/domain/models.dart';
import 'package:rezervator/features/admin/clubs_screen.dart';
import 'package:rezervator/features/admin/widgets/form_fields.dart';

/// Smoke test for the clubs admin list: renders for an admin, shows its
/// empty state, teams grouped under their club (0045), and the FAB opens
/// the add dialog (never saved — that would hit the RPC). The ČKA card has
/// its own tests in federation_card_test.dart.
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
    Stream<List<Team>> Function()? teamsStream,
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
          teamsProvider.overrideWith(
              (ref) => teamsStream?.call() ?? Stream.value(teams)),
          federationSyncProvider
              .overrideWith((ref) => syncStream ?? Stream.value(sync)),
        ],
        child: MaterialApp(
          home: ClubsScreen(
            saveFederation: saveFederation ?? (_, _) async {},
            discoverTeams: discoverTeams ?? () async {},
            syncNow: syncNow ?? () async {},
            syncProgress: () async => FederationSyncProgress.idle,
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
    // Scope to the dialog: the ČKA card has buttons of its own.
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

    // Scope to the dialog: the ČKA card has buttons of its own.
    await tester.tap(find.descendant(
      of: find.byType(AlertDialog),
      matching: find.text('Uložit'),
    ));
    await tester.pumpAndSettle();

    expect(find.text('Vyplň název oddílu.'), findsOneWidget);
    expect(find.byType(AlertDialog), findsOneWidget); // still open
  });

  group('teams under their clubs (0045)', () {
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
        'a team whose club was deleted opens its dialog on Bez oddílu and '
        'saves without a club', (tester) async {
      const team = Team(
        id: 't1',
        name: 'Bývalí Nešemice',
        clubId: 'gone', // no club in `clubs` has this id
        competitionName: 'OP II. třída',
      );
      var saved = false;
      String? capturedClubId = 'unset';
      await pumpApp(
        tester,
        app(
          clubs,
          teams: const [team],
          updateTeam: (t,
              {required String name,
              String? clubId,
              required bool active}) async {
            saved = true;
            capturedClubId = clubId;
          },
        ),
      );

      await tester.tap(find.text('Bývalí Nešemice'));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.text('Tým'), findsOneWidget);
      expect(
          find.descendant(
            of: find.byType(DropdownButtonFormField<String?>),
            matching: find.text('Bez oddílu'),
          ),
          findsOneWidget);

      await tester.tap(find.descendant(
        of: find.byType(AlertDialog),
        matching: find.text('Uložit'),
      ));
      await tester.pumpAndSettle();

      expect(saved, isTrue);
      expect(capturedClubId, isNull);
    });

    testWidgets('a failed teams stream shows its error with a retry, not an '
        'empty club list', (tester) async {
      var calls = 0;
      await pumpApp(
        tester,
        app(
          clubs,
          // An Error, not an Exception: Riverpod's own retry gives up on it
          // at once — the state a stream is left in after its retries ran out.
          teamsStream: () => ++calls == 1
              ? Stream.error(StateError('boom'))
              : Stream.value(const [
                  Team(id: 't1', name: 'Veverky A', clubId: 'c2'),
                ]),
        ),
      );

      expect(find.text('Něco se nepovedlo. (Bad state: boom)'), findsOneWidget);
      expect(find.text('Veverky A'), findsNothing);

      await tester.tap(find.widgetWithText(TextButton, 'Zkusit znovu'));
      await tester.pumpAndSettle();

      expect(find.text('Něco se nepovedlo. (Bad state: boom)'), findsNothing);
      expect(find.text('Veverky A'), findsOneWidget);
    });

    testWidgets('deleting a club with teams says its teams lose it too',
        (tester) async {
      const teams = [
        Team(id: 't1', name: 'Veverky A', clubId: 'c2'),
        Team(id: 't2', name: 'Veverky B', clubId: 'c2'),
      ];
      await pumpApp(tester, app(clubs, teams: teams));

      // Clubs are Czech-sorted: Sokol Dlouhá Lhota (no teams), Veverky.
      await tester.tap(find.byIcon(Icons.delete_outline).last);
      await tester.pumpAndSettle();
      expect(
        find.text('Opravdu smazat oddíl „Veverky"? Hráči i týmy (2) '
            'zůstanou bez oddílu.'),
        findsOneWidget,
      );
      await tester.tap(find.text('Zrušit'));
      await tester.pumpAndSettle();

      await tester.tap(find.byIcon(Icons.delete_outline).first);
      await tester.pumpAndSettle();
      expect(
        find.text('Opravdu smazat oddíl „Sokol Dlouhá Lhota"? Hráči '
            'zůstanou bez oddílu.'),
        findsOneWidget,
      );
      await tester.tap(find.text('Zrušit'));
      await tester.pumpAndSettle();
    });

    // Devítka is linked to the ČKA site (0046); Veverky is not.
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

      // Scope to the dialog: the ČKA card has buttons of its own.
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

    testWidgets('a refused team save keeps the dialog open with the edits',
        (tester) async {
      const team = Team(
        id: 't1',
        name: 'TJ Sokol Brno IV B',
        clubId: 'c1',
        siteName: 'TJ Sokol Brno IV',
        competitionName: 'OP I. třída',
      );
      var calls = 0;
      await pumpApp(
        tester,
        app(
          clubs,
          teams: const [team],
          updateTeam: (t,
              {required String name,
              String? clubId,
              required bool active}) async {
            calls++;
            throw Exception('team_name_taken');
          },
        ),
      );

      await tester.tap(find.text('TJ Sokol Brno IV B'));
      await tester.pumpAndSettle();
      await tester.enterText(
          find.widgetWithText(TextField, 'TJ Sokol Brno IV B'),
          'TJ Sokol Brno IV');
      await tester.tap(find.text('Stahovat zápasy'));
      await tester.pumpAndSettle();
      await tester.tap(find.descendant(
        of: find.byType(AlertDialog),
        matching: find.text('Uložit'),
      ));
      await tester.pumpAndSettle();

      expect(calls, 1);
      expect(find.text('Tým s tímto názvem už existuje.'), findsOneWidget);
      final dialog = find.byType(AlertDialog);
      expect(dialog, findsOneWidget);
      expect(
        find.descendant(
            of: dialog,
            matching: find.widgetWithText(TextField, 'TJ Sokol Brno IV')),
        findsOneWidget,
      );
      final toggle = tester.widget<SwitchListTile>(
          find.widgetWithText(SwitchListTile, 'Stahovat zápasy'));
      expect(toggle.value, isFalse);
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
