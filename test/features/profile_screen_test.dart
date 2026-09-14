import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rezervator/data/providers.dart';
import 'package:rezervator/domain/models.dart';
import 'package:rezervator/features/profile/profile_screen.dart';
import 'package:rezervator/features/admin/widgets/color_picker.dart';
import 'package:rezervator/features/profile/match_exceptions_screen.dart';
import 'package:rezervator/features/profile/widgets/calendar_link_card.dart';
import 'package:rezervator/features/profile/widgets/event_color_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Stubs for the card's injected backend calls: a test that reaches one it
/// did not expect fails on its own assertions (the card swallows the throw
/// into an error snack).
Future<Uri> noConsent() async => throw StateError('unexpected consent');
Future<List<CalendarSlot>> noDisconnect() async =>
    throw StateError('unexpected disconnect');
Future<void> noReminders(
  List<int> _, {
  CalendarSlot calendar = CalendarSlot.primary,
}) async => throw StateError('unexpected reminders');
Future<void> noMatchTeams(List<CalendarTeam> _) async =>
    throw StateError('unexpected match teams');
Future<void> noTeamColors(Map<String, int?> _) async =>
    throw StateError('unexpected team colors');
Future<bool> noSecondaryCalendar(bool _) async =>
    throw StateError('unexpected secondary calendar');
Future<void> noTrainingColor(int? _) async =>
    throw StateError('unexpected training color');

/// CalendarTeam has no == override (lib/domain/models.dart) — two separate
/// instances with the same fields are NOT equal. Tests compare its fields
/// structurally instead of relying on ==.
(String, CalendarSlot) teamTuple(CalendarTeam t) => (t.team, t.calendar);
List<(String, CalendarSlot)> teamTuples(List<CalendarTeam> teams) =>
    teams.map(teamTuple).toList();

/// The alley's schedule as the calendar card sees it: a home match of
/// Veverky A, an away match of Devítka B, and a foreign opponent on each —
/// only our two teams may be offered.
PrioritySlot match(String id, String home, String away, {bool away_ = false}) =>
    PrioritySlot(
      id: id,
      date: Day(2026, 10, 1),
      startsAt: const HourMinute(18, 0),
      endsAt: const HourMinute(21, 0),
      type: PrioritySlot.fallbackMatchType,
      homeTeam: home,
      awayTeam: away,
      isAway: away_,
    );
final schedule = [
  match('m1', 'SKK Veverky Brno A', 'KK MS Brno D'),
  match('m2', 'KK Slovan Rosice D', 'KS Devítka Brno B', away_: true),
];

void main() {
  // The Vzhled card reads themeChoiceProvider/textSizeProvider, which load
  // from shared_preferences — every test in this file builds ProfileScreen,
  // so every test needs the plugin mocked or it hangs.
  setUpAll(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues({});
  });

  const me = Profile(
    id: 'me',
    displayName: 'Já Hráč',
    clubId: 'c1',
    email: 'me@example.com',
    role: Role.player,
    status: ProfileStatus.approved,
    nick: 'Já H.',
  );

  // One ProviderScope per test: a second pumpWidget does not swap overrides.
  Widget app(
    Profile profile, {
    bool calendarAvailable = false,
    CalendarLink link = CalendarLink.none,
    List<CalendarTeam> teams = const [],
    Map<String, int> teamColors = const <String, int>{},
    Future<void> Function(int color)? setOwnColor,
    Future<void> Function(List<String> teams)? setFollowedTeams,
    Future<void> Function(List<CalendarTeam> teams)? setCalendarTeams,
    Future<void> Function(List<int> minutes)? setNotifyBefore,
    Future<void> Function(Map<String, int?> colors)? setTeamColors,
    Future<void> Function(HomeView view)? setDefaultView,
    List<PrioritySlot> matches = const [],
    Map<String, bool> exceptions = const {},
  }) {
    return ProviderScope(
      overrides: [
        myProfileProvider.overrideWith((ref) => Stream.value(profile)),
        clubsProvider.overrideWith(
          (ref) => Stream.value(const [Club(id: 'c1', name: 'TJ Sokol')]),
        ),
        calendarAvailableProvider.overrideWithValue(calendarAvailable),
        myCalendarLinkProvider.overrideWith((ref) => Stream.value(link)),
        myCalendarTeamsProvider.overrideWith((ref) => Stream.value(teams)),
        myTeamColorsProvider.overrideWith((ref) => Stream.value(teamColors)),
        myMatchExceptionsProvider.overrideWith((ref) => Stream.value(exceptions)),
        prioritySlotsProvider.overrideWithValue(matches),
      ],
      child: MaterialApp(
        home: ProfileScreen(
          setOwnColor:
              setOwnColor ?? (_) async => throw StateError('unexpected'),
          setFollowedTeams:
              setFollowedTeams ?? (_) async => throw StateError('unexpected'),
          setCalendarTeams:
              setCalendarTeams ?? (_) async => throw StateError('unexpected'),
          setNotifyBefore:
              setNotifyBefore ?? (_) async => throw StateError('unexpected'),
          setTeamColors:
              setTeamColors ?? (_) async => throw StateError('unexpected'),
          setDefaultView:
              setDefaultView ?? (_) async => throw StateError('unexpected'),
        ),
      ),
    );
  }

  testWidgets('shows display name, club, current nick and the edit '
      'affordance', (tester) async {
    await tester.pumpWidget(app(me));
    await tester.pumpAndSettle();

    expect(find.text('Můj profil'), findsOneWidget);
    expect(find.text('Já Hráč'), findsOneWidget);
    expect(find.text('TJ Sokol'), findsOneWidget);
    expect(find.text('Já H.'), findsOneWidget);
    expect(find.text('Upravit'), findsOneWidget);
  });

  testWidgets('shows "nenastavena" when nick is empty', (tester) async {
    await tester.pumpWidget(
      app(
        const Profile(
          id: 'me',
          displayName: 'Já Hráč',
          email: 'me@example.com',
          role: Role.player,
          status: ProfileStatus.approved,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('nenastavena'), findsOneWidget);
  });

  testWidgets('tapping Upravit opens the prompt prefilled with the current '
      'nick', (tester) async {
    await tester.pumpWidget(app(me));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Upravit'));
    await tester.pumpAndSettle();

    expect(find.text('Přezdívka na tabuli'), findsWidgets);
    // An empty field showing "Tom P." read as a value somebody had already
    // entered; the line above it says what the field is for and what an
    // empty one means.
    expect(
      find.text('Krátké jméno do rezervace a na tabuli v kuželně. Necháš-li '
          'ji prázdnou, ukáže se tvoje celé jméno.'),
      findsOneWidget,
    );
    expect(find.text('např. Tom P.'), findsOneWidget);
    expect(find.text('Uložit'), findsOneWidget);
    expect(find.widgetWithText(TextField, 'Já H.'), findsOneWidget);
  });

  testWidgets('shows a logout action', (tester) async {
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(app(me));
    await tester.pumpAndSettle();

    expect(find.byIcon(Icons.logout), findsOneWidget);
    expect(find.text('Odhlásit se'), findsOneWidget);
  });

  testWidgets('tapping logout asks for confirmation before signing out', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(app(me));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Odhlásit se'));
    await tester.pumpAndSettle();

    // The confirm dialog appears; nothing is signed out until confirmed.
    expect(find.text('Opravdu se chceš odhlásit?'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Odhlásit se'), findsOneWidget);
    expect(find.widgetWithText(TextButton, 'Zrušit'), findsOneWidget);
  });

  testWidgets('confirmed logout pops the screen back to the root route '
      '(the pushed screen must not linger above the login gate)', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    var signedOut = false;

    await tester.pumpWidget(
      ProviderScope(
        overrides: [myProfileProvider.overrideWith((ref) => Stream.value(me))],
        child: MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: TextButton(
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) =>
                          ProfileScreen(signOut: () async => signedOut = true),
                    ),
                  ),
                  child: const Text('Otevřít profil'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Otevřít profil'));
    await tester.pumpAndSettle();
    expect(find.text('Můj profil'), findsOneWidget);

    await tester.tap(find.text('Odhlásit se'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Odhlásit se'));
    await tester.pumpAndSettle();

    expect(signedOut, isTrue);
    // Back on the root route — no stranded profile screen with a spinner.
    expect(find.text('Můj profil'), findsNothing);
    expect(find.text('Otevřít profil'), findsOneWidget);
  });

  // -------------------------------------------------------------------------
  // Google kalendář card (0023)
  // -------------------------------------------------------------------------

  const connectLabel = 'Propojit s Google kalendářem';
  const notLinkedCopy =
      'Tvoje tréninky se budou samy přidávat do kalendáře '
      '„Rezervátor" ve tvém Google účtu.';
  const linked = CalendarLink(
    status: CalendarLinkStatus.linked,
    googleEmail: 'hrac@gmail.com',
    reminderMinutes: [1440, 120],
  );

  group('Google kalendář card on Můj profil', () {
    testWidgets('is hidden without a Google client ID in the build', (
      tester,
    ) async {
      await tester.pumpWidget(app(me, link: linked));
      await tester.pumpAndSettle();

      expect(find.text('Google kalendář'), findsNothing);
      expect(find.text(connectLabel), findsNothing);
      expect(find.text('Odpojit'), findsNothing);
    });

    testWidgets('is hidden for the Play-review demo account even when '
        'available (a shared account has no calendar to link)', (tester) async {
      await tester.pumpWidget(
        app(
          const Profile(
            id: 'demo',
            displayName: 'Play Review',
            email: 'PlayReview@vvrky.cz',
            role: Role.player,
            status: ProfileStatus.approved,
          ),
          calendarAvailable: true,
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Google kalendář'), findsNothing);
      expect(find.text(connectLabel), findsNothing);
    });

    // The order the screen reads in, top to bottom: who you are, how your
    // reservations look, what opens first, whose matches you follow, the
    // calendar they go to — and only then the app's own looks, which has
    // nothing to do with kuželky at all.
    testWidgets('the cards run: name, Tabule, Po spuštění, Moje týmy, '
        'Připomínky, Google kalendář, Vzhled', (tester) async {
      // Tall enough for every card to be built (the ListView is lazy).
      tester.view.physicalSize = const Size(800, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(app(me, calendarAvailable: true));
      await tester.pumpAndSettle();

      double top(String label) => tester.getTopLeft(find.text(label)).dy;
      final order = [
        top('Jméno'),
        top('Tabule'),
        top('Po spuštění'),
        top('Moje týmy'),
        top('Připomínky z appky'),
        top('Google kalendář'),
        top('Vzhled'),
        top('Odhlásit se'),
      ];
      for (var i = 1; i < order.length; i++) {
        expect(order[i - 1], lessThan(order[i]), reason: 'card $i out of order');
      }

      // Tabule is ONE card: the nick and the colour of the cells it draws.
      expect(top('Přezdívka'), greaterThan(top('Tabule')));
      expect(top('Barva mých rezervací'), lessThan(top('Po spuštění')));
      expect(find.text('Přezdívka na tabuli'), findsNothing,
          reason: 'the card above it says Tabule now');
    });

    testWidgets('not linked: explains the calendar and offers to connect', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(800, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(app(me, calendarAvailable: true));
      await tester.pumpAndSettle();

      expect(find.text('Google kalendář'), findsOneWidget);
      expect(find.text(notLinkedCopy), findsOneWidget);
      expect(find.text(connectLabel), findsOneWidget);
      expect(find.text('Odpojit'), findsNothing);
      expect(find.text('Připomínky…'), findsNothing);
      expect(find.text('Zápasy v kalendáři…'), findsNothing);
    });

    testWidgets('pending: shows progress; a retry stays available in case '
        'the backend never finishes', (tester) async {
      tester.view.physicalSize = const Size(800, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        app(
          me,
          calendarAvailable: true,
          link: const CalendarLink(
            status: CalendarLinkStatus.pending,
            googleEmail: 'hrac@gmail.com',
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Google kalendář'), findsOneWidget);
      expect(find.text('Propojuji…'), findsOneWidget);
      expect(find.text('Zkusit znovu'), findsOneWidget);
      expect(find.text(connectLabel), findsNothing);
      expect(find.text('Odpojit'), findsNothing);
    });

    testWidgets('pending with a failure: shows the reason and a retry', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(800, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        app(
          me,
          calendarAvailable: true,
          link: const CalendarLink(
            status: CalendarLinkStatus.pending,
            lastError: 'Kalendář se nepodařilo založit.',
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Kalendář se nepodařilo založit.'), findsOneWidget);
      expect(find.text('Propojuji…'), findsNothing);
      expect(find.text('Zkusit znovu'), findsOneWidget);
    });

    testWidgets('linked: shows the Google account, the reminders summary '
        'and Odpojit', (tester) async {
      tester.view.physicalSize = const Size(800, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(app(me, calendarAvailable: true, link: linked));
      await tester.pumpAndSettle();

      expect(find.text('Google kalendář'), findsOneWidget);
      expect(find.text('Propojeno jako hrac@gmail.com.'), findsOneWidget);
      expect(find.text('Připomínky…'), findsOneWidget);
      expect(find.text('1 den předem · 2 h předem'), findsOneWidget);
      expect(find.text('Odpojit'), findsOneWidget);
      expect(find.text(connectLabel), findsNothing);
      // WHICH teams go to the calendar is not the card's business any more
      // — that is one of the three boxes a team has in Moje týmy.
      expect(find.text('Zápasy v kalendáři…'), findsNothing);
    });

    testWidgets('with a calendar linked, Moje týmy sums up both lists — what '
        'the app shows and what Google gets', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(800, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        app(
          me,
          calendarAvailable: true,
          link: const CalendarLink(status: CalendarLinkStatus.linked),
          teams: const [
            CalendarTeam(team: 'SKK Veverky Brno A'),
            CalendarTeam(team: 'SKK Veverky Brno B'),
          ],
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.text('Přehled: Žádný tým\n'
            'Kalendář: SKK Veverky Brno A · SKK Veverky Brno B'),
        findsOneWidget,
      );
    });

    // Without one there is only the overview to sum up, so the card says
    // just that — no empty "Kalendář:" line for something the player has
    // not got.
    testWidgets('without a calendar, Moje týmy sums up the overview alone',
        (tester) async {
      tester.view.physicalSize = const Size(800, 1600);
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
      await tester.pumpWidget(app(follower));
      await tester.pumpAndSettle();

      expect(find.text('SKK Veverky Brno A'), findsOneWidget);
      expect(find.textContaining('Kalendář:'), findsNothing);
    });

    testWidgets('linked without reminders reads "Žádné"', (tester) async {
      tester.view.physicalSize = const Size(800, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        app(
          me,
          calendarAvailable: true,
          link: const CalendarLink(status: CalendarLinkStatus.linked),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.text('Propojeno — tréninky se přidávají samy.'),
        findsOneWidget,
      );
      expect(find.text('Žádné'), findsOneWidget);
    });

    testWidgets('broken: shows the reason, asks for a re-link and offers '
        'the connect button', (tester) async {
      tester.view.physicalSize = const Size(800, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        app(
          me,
          calendarAvailable: true,
          link: const CalendarLink(
            status: CalendarLinkStatus.broken,
            lastError: 'Google odvolal přístup.',
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Google kalendář'), findsOneWidget);
      expect(
        find.text('Google odvolal přístup. Propoj ho prosím znovu.'),
        findsOneWidget,
      );
      expect(find.text(connectLabel), findsOneWidget);
      expect(find.text('Odpojit'), findsNothing);
    });

    // -----------------------------------------------------------------------
    // Druhý kalendář switch, doubled reminders and training colour (0032)
    // -----------------------------------------------------------------------

    testWidgets('Druhý kalendář switch is off by default, with a subtitle '
        'naming the second calendar', (tester) async {
      tester.view.physicalSize = const Size(800, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(app(me, calendarAvailable: true, link: linked));
      await tester.pumpAndSettle();

      expect(find.text('Druhý kalendář'), findsOneWidget);
      final tile = tester.widget<SwitchListTile>(
        find.widgetWithText(SwitchListTile, 'Druhý kalendář'),
      );
      expect(tile.value, isFalse);
      expect(find.textContaining('Rezervátor 2'), findsOneWidget);
    });

    testWidgets('with the second calendar on, the switch is on and the '
        'reminders row doubles into hlavního / druhého, each with its own '
        'summary', (tester) async {
      tester.view.physicalSize = const Size(800, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        app(
          me,
          calendarAvailable: true,
          link: const CalendarLink(
            status: CalendarLinkStatus.linked,
            reminderMinutes: [1440],
            secondaryEnabled: true,
            reminderMinutesSecondary: [60],
          ),
        ),
      );
      await tester.pumpAndSettle();

      final tile = tester.widget<SwitchListTile>(
        find.widgetWithText(SwitchListTile, 'Druhý kalendář'),
      );
      expect(tile.value, isTrue);

      expect(find.text('Připomínky…'), findsNothing);
      expect(find.text('Připomínky hlavního kalendáře…'), findsOneWidget);
      expect(find.text('Připomínky druhého kalendáře…'), findsOneWidget);
      expect(find.text('1 den předem'), findsOneWidget);
      expect(find.text('1 h předem'), findsOneWidget);
    });

    testWidgets('without the second calendar there is a single Připomínky '
        'row, unchanged from before 0032', (tester) async {
      tester.view.physicalSize = const Size(800, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(app(me, calendarAvailable: true, link: linked));
      await tester.pumpAndSettle();

      expect(find.text('Připomínky…'), findsOneWidget);
      expect(find.text('Připomínky hlavního kalendáře…'), findsNothing);
      expect(find.text('Připomínky druhého kalendáře…'), findsNothing);
    });

    testWidgets('Barva tréninků row shows Bez barvy by default', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(800, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(app(me, calendarAvailable: true, link: linked));
      await tester.pumpAndSettle();

      expect(find.text('Barva tréninků'), findsOneWidget);
      expect(find.text('Bez barvy'), findsOneWidget);
    });

    testWidgets('Barva tréninků row names the chosen colour', (tester) async {
      tester.view.physicalSize = const Size(800, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        app(
          me,
          calendarAvailable: true,
          link: const CalendarLink(
            status: CalendarLinkStatus.linked,
            trainingColorId: 10,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Bazalková'), findsOneWidget);
    });

    testWidgets('Odpojit asks for confirmation with the delete warning; '
        'Zrušit keeps the link', (tester) async {
      tester.view.physicalSize = const Size(800, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(app(me, calendarAvailable: true, link: linked));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Odpojit'));
      await tester.pumpAndSettle();

      expect(find.text('Odpojit kalendář?'), findsOneWidget);
      expect(
        find.text(
          'Kalendář „Rezervátor" se z Googlu smaže i s tréninky. '
          'Propojení jde kdykoli obnovit.',
        ),
        findsOneWidget,
      );
      expect(
        find.widgetWithText(FilledButton, 'Odpojit a smazat'),
        findsOneWidget,
      );

      await tester.tap(find.widgetWithText(TextButton, 'Zrušit'));
      await tester.pumpAndSettle();
      expect(find.text('Odpojit kalendář?'), findsNothing);
      expect(find.text('Propojeno jako hrac@gmail.com.'), findsOneWidget);
    });
  });

  // The card on its own, with the backend calls injected — the ProviderScope
  // above has no Supabase client behind it.
  group('CalendarLinkCard actions', () {
    Widget card(
      Stream<CalendarLink> link, {
      Future<Uri> Function() consentUrl = noConsent,
      void Function(String url)? openUrl,
      Future<List<CalendarSlot>> Function() disconnect = noDisconnect,
      Future<void> Function(List<int> minutes, {CalendarSlot calendar})
          setReminders =
          noReminders,
      Future<bool> Function(bool enabled) setSecondaryCalendar =
          noSecondaryCalendar,
      Future<void> Function(int? colorId) setTrainingColor = noTrainingColor,
      Stream<List<CalendarTeam>>? teams,
      Map<String, int> colors = const <String, int>{},
      List<PrioritySlot> matches = const [],
    }) {
      return ProviderScope(
        overrides: [
          calendarAvailableProvider.overrideWithValue(true),
          myCalendarLinkProvider.overrideWith((ref) => link),
          myCalendarTeamsProvider.overrideWith(
            (ref) => teams ?? Stream.value(const <CalendarTeam>[]),
          ),
          myTeamColorsProvider.overrideWith((ref) => Stream.value(colors)),
          prioritySlotsProvider.overrideWithValue(matches),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: CalendarLinkCard(
              consentUrl: consentUrl,
              openUrl: openUrl ?? (_) => fail('unexpected openUrl'),
              disconnect: disconnect,
              setReminders: setReminders,
              setSecondaryCalendar: setSecondaryCalendar,
              setTrainingColor: setTrainingColor,
            ),
          ),
        ),
      );
    }

    // Teams moved to Moje týmy, all three boxes of them — the calendar card
    // has no team row any more, and no way to write one.
    testWidgets('the linked card sets up the calendar itself, not who is in '
        'it', (tester) async {
      await tester.pumpWidget(
        card(
          Stream.value(const CalendarLink(status: CalendarLinkStatus.linked)),
          matches: schedule,
          teams: Stream.value(const [CalendarTeam(team: 'SKK Veverky Brno A')]),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Zápasy v kalendáři…'), findsNothing);
      expect(find.text('SKK Veverky Brno A'), findsNothing);
      // What the card does keep: the link, the second calendar, reminders
      // and the trainings' colour.
      expect(find.text('Google kalendář'), findsOneWidget);
      expect(find.text('Druhý kalendář'), findsOneWidget);
      expect(find.text('Připomínky…'), findsOneWidget);
      expect(find.text('Barva tréninků'), findsOneWidget);
    });

    testWidgets('connect opens the consent page in the browser and asks to '
        'come back', (tester) async {
      String? opened;
      await tester.pumpWidget(
        card(
          Stream.value(CalendarLink.none),
          consentUrl: () async => Uri.parse(
            'https://accounts.google.com/o/oauth2/v2/auth?state=n1',
          ),
          openUrl: (url) => opened = url,
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text(connectLabel));
      await tester.pumpAndSettle();

      expect(opened, 'https://accounts.google.com/o/oauth2/v2/auth?state=n1');
      expect(
        find.text('Dokonči propojení v prohlížeči a vrať se sem.'),
        findsOneWidget,
      );
    });

    testWidgets('a failed consent start is reported, nothing opens', (
      tester,
    ) async {
      var opened = false;
      await tester.pumpWidget(
        card(
          Stream.value(CalendarLink.none),
          consentUrl: () async => throw Exception('not_allowed'),
          openUrl: (_) => opened = true,
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text(connectLabel));
      await tester.pumpAndSettle();

      expect(opened, isFalse);
      expect(find.textContaining('Propojení se nepovedlo'), findsOneWidget);
    });

    testWidgets('confirmed disconnect calls the backend and reports the '
        'deleted calendar', (tester) async {
      var calls = 0;
      await tester.pumpWidget(
        card(
          Stream.value(linked),
          disconnect: () async {
            calls++;
            return const <CalendarSlot>[];
          },
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Odpojit'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Odpojit a smazat'));
      await tester.pumpAndSettle();

      expect(calls, 1);
      expect(find.text('Kalendář odpojen a smazán.'), findsOneWidget);
    });

    testWidgets('an orphaned calendar is reported so the user deletes it '
        'in Google', (tester) async {
      await tester.pumpWidget(
        card(
          Stream.value(linked),
          disconnect: () async => const [CalendarSlot.primary],
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Odpojit'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Odpojit a smazat'));
      await tester.pumpAndSettle();

      expect(
        find.text(
          'Odpojeno, ale kalendář „Rezervátor" v Googlu zůstal — smazat '
          'se ho nepodařilo, smaž si ho tam prosím sám(a).',
        ),
        findsOneWidget,
      );
    });

    testWidgets('only the second calendar orphaned names THAT one, not the '
        'primary', (tester) async {
      await tester.pumpWidget(
        card(
          Stream.value(linked),
          disconnect: () async => const [CalendarSlot.secondary],
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Odpojit'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Odpojit a smazat'));
      await tester.pumpAndSettle();

      expect(
        find.text(
          'Odpojeno, ale kalendář „Rezervátor 2" v Googlu zůstal — smazat '
          'se ho nepodařilo, smaž si ho tam prosím sám(a).',
        ),
        findsOneWidget,
      );
    });

    testWidgets('both calendars orphaned are named together, in plural',
        (tester) async {
      await tester.pumpWidget(
        card(
          Stream.value(linked),
          disconnect: () async =>
              const [CalendarSlot.primary, CalendarSlot.secondary],
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Odpojit'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Odpojit a smazat'));
      await tester.pumpAndSettle();

      expect(
        find.text(
          'Odpojeno, ale kalendáře „Rezervátor" a „Rezervátor 2" v Googlu '
          'zůstaly — smazat se je nepodařilo, smaž si je tam prosím sám(a).',
        ),
        findsOneWidget,
      );
    });

    testWidgets('a failed disconnect says nothing changed', (tester) async {
      await tester.pumpWidget(
        card(
          Stream.value(linked),
          disconnect: () async => throw Exception('google_unavailable'),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Odpojit'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Odpojit a smazat'));
      await tester.pumpAndSettle();

      expect(
        find.text(
          'Odpojení se nepovedlo, nic se nezměnilo. '
          'Zkus to prosím znovu.',
        ),
        findsOneWidget,
      );
      // Still linked — the backend promised it changed nothing.
      expect(find.text('Odpojit'), findsOneWidget);
    });

    /// Opens the add dialog from the sheet and submits [amount] of [unit].
    Future<void> addReminder(
      WidgetTester tester,
      String amount,
      String unit,
    ) async {
      await tester.tap(find.text('Přidat připomínku'));
      await tester.pumpAndSettle();
      expect(find.text('Připomínka předem'), findsOneWidget);
      await tester.enterText(find.byType(TextField), amount);
      await tester.tap(find.text(unit));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Přidat'));
      await tester.pumpAndSettle();
    }

    testWidgets('the reminders sheet composes [1440, 120] from "1 den" + '
        '"2 h", saving after each step', (tester) async {
      // The backend round trip: every save lands as a new link row on the
      // stream, which is what the sheet and the card redraw from.
      final rows = StreamController<CalendarLink>();
      addTearDown(rows.close);
      rows.add(const CalendarLink(status: CalendarLinkStatus.linked));
      final saved = <List<int>>[];

      await tester.pumpWidget(
        card(
          rows.stream,
          setReminders:
              (minutes, {CalendarSlot calendar = CalendarSlot.primary}) async {
                saved.add(minutes);
                rows.add(
                  CalendarLink(
                    status: CalendarLinkStatus.linked,
                    reminderMinutes: [...minutes]
                      ..sort((a, b) => b.compareTo(a)),
                  ),
                );
              },
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Žádné'), findsOneWidget);

      await tester.tap(find.text('Připomínky…'));
      await tester.pumpAndSettle();
      expect(find.text('Připomínky tréninků v kalendáři'), findsOneWidget);
      expect(find.text('Žádné připomínky'), findsOneWidget);

      // The card behind the sheet shows the same labels in its summary, so
      // the entries are looked up inside the sheet only.
      Finder inSheet(String text) => find.descendant(
        of: find.byType(BottomSheet),
        matching: find.text(text),
      );

      await addReminder(tester, '1', 'dny');
      expect(saved, [
        [1440],
      ]);
      expect(inSheet('Žádné připomínky'), findsNothing);
      expect(inSheet('1 den předem'), findsOneWidget);

      await addReminder(tester, '2', 'hodiny');
      expect(saved.last, [1440, 120]);
      expect(inSheet('1 den předem'), findsOneWidget);
      expect(inSheet('2 h předem'), findsOneWidget);

      // Close the sheet: the card's summary follows the stream.
      await tester.tapAt(const Offset(400, 20));
      await tester.pumpAndSettle();
      expect(find.byType(BottomSheet), findsNothing);
      expect(find.text('1 den předem · 2 h předem'), findsOneWidget);
    });

    testWidgets('a reminder beyond four weeks is refused before saving', (
      tester,
    ) async {
      var saves = 0;
      await tester.pumpWidget(
        card(
          Stream.value(const CalendarLink(status: CalendarLinkStatus.linked)),
          setReminders:
              (_, {CalendarSlot calendar = CalendarSlot.primary}) async =>
                  saves++,
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Připomínky…'));
      await tester.pumpAndSettle();
      await addReminder(tester, '29', 'dny');

      expect(saves, 0);
      expect(
        find.text('Nejdál to jde 4 týdny (28 dní) předem.'),
        findsOneWidget,
      );
    });

    testWidgets('an empty or zero amount does not submit', (tester) async {
      var saves = 0;
      await tester.pumpWidget(
        card(
          Stream.value(const CalendarLink(status: CalendarLinkStatus.linked)),
          setReminders:
              (_, {CalendarSlot calendar = CalendarSlot.primary}) async =>
                  saves++,
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Připomínky…'));
      await tester.pumpAndSettle();
      await addReminder(tester, '0', 'hodiny');

      expect(saves, 0);
      // The dialog stays open, waiting for a real number.
      expect(find.text('Připomínka předem'), findsOneWidget);
    });

    testWidgets('removing a reminder saves the rest', (tester) async {
      final saved = <List<int>>[];
      await tester.pumpWidget(
        card(
          Stream.value(linked),
          setReminders:
              (minutes, {CalendarSlot calendar = CalendarSlot.primary}) async =>
                  saved.add(minutes),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Připomínky…'));
      await tester.pumpAndSettle();
      expect(find.text('1 den předem'), findsOneWidget);
      expect(find.text('2 h předem'), findsOneWidget);

      await tester.tap(
        find.descendant(
          of: find.widgetWithText(ListTile, '2 h předem'),
          matching: find.byIcon(Icons.close),
        ),
      );
      await tester.pumpAndSettle();

      expect(saved, [
        [1440],
      ]);
    });

    testWidgets('with five reminders the add row disappears', (tester) async {
      await tester.pumpWidget(
        card(
          Stream.value(
            const CalendarLink(
              status: CalendarLinkStatus.linked,
              reminderMinutes: [10080, 2880, 1440, 120, 60],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Připomínky…'));
      await tester.pumpAndSettle();

      expect(find.text('7 dní předem'), findsOneWidget);
      expect(find.text('Přidat připomínku'), findsNothing);
    });

    testWidgets('turning Druhý kalendář on calls setSecondaryCalendar '
        'directly, no confirmation needed', (tester) async {
      final called = <bool>[];
      await tester.pumpWidget(
        card(
          Stream.value(const CalendarLink(status: CalendarLinkStatus.linked)),
          setSecondaryCalendar: (enabled) async {
            called.add(enabled);
            return false;
          },
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.widgetWithText(SwitchListTile, 'Druhý kalendář'));
      await tester.pumpAndSettle();

      expect(called, [true]);
    });

    testWidgets('turning Druhý kalendář off asks for confirmation (it '
        'deletes the calendar and its events); Zrušit keeps it on', (
      tester,
    ) async {
      var called = 0;
      await tester.pumpWidget(
        card(
          Stream.value(
            const CalendarLink(
              status: CalendarLinkStatus.linked,
              secondaryEnabled: true,
            ),
          ),
          setSecondaryCalendar: (_) async {
            called++;
            return false;
          },
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.widgetWithText(SwitchListTile, 'Druhý kalendář'));
      await tester.pumpAndSettle();

      expect(find.text('Vypnout druhý kalendář?'), findsOneWidget);
      await tester.tap(find.widgetWithText(TextButton, 'Zrušit'));
      await tester.pumpAndSettle();

      expect(called, 0);
      final tile = tester.widget<SwitchListTile>(
        find.widgetWithText(SwitchListTile, 'Druhý kalendář'),
      );
      expect(tile.value, isTrue);
    });

    testWidgets('confirming turns Druhý kalendář off', (tester) async {
      final called = <bool>[];
      await tester.pumpWidget(
        card(
          Stream.value(
            const CalendarLink(
              status: CalendarLinkStatus.linked,
              secondaryEnabled: true,
            ),
          ),
          setSecondaryCalendar: (enabled) async {
            called.add(enabled);
            return false;
          },
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.widgetWithText(SwitchListTile, 'Druhý kalendář'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Vypnout a smazat'));
      await tester.pumpAndSettle();

      expect(called, [false]);
    });

    testWidgets('turning Druhý kalendář off tells the player when Google '
        'kept "Rezervátor 2"', (tester) async {
      await tester.pumpWidget(
        card(
          Stream.value(
            const CalendarLink(
              status: CalendarLinkStatus.linked,
              secondaryEnabled: true,
            ),
          ),
          setSecondaryCalendar: (_) async => true,
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.widgetWithText(SwitchListTile, 'Druhý kalendář'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Vypnout a smazat'));
      await tester.pumpAndSettle();

      expect(
        find.text(
          'Druhý kalendář je vypnutý, ale „Rezervátor 2" v Googlu zůstal '
          '— smazat se ho nepodařilo, smaž si ho tam prosím sám(a).',
        ),
        findsOneWidget,
      );
    });

    testWidgets('Připomínky hlavního and druhého each save to their own '
        'calendar', (tester) async {
      // Two parallel lists, not a List<(List<int>, CalendarSlot)>: a record
      // wrapping a List falls back to the List's own == (identity) instead
      // of the deep comparison plain List-vs-List assertions get, so a
      // record here would make every assertion below fail spuriously.
      final savedMinutes = <List<int>>[];
      final savedCalendars = <CalendarSlot>[];
      await tester.pumpWidget(
        card(
          Stream.value(
            const CalendarLink(
              status: CalendarLinkStatus.linked,
              secondaryEnabled: true,
            ),
          ),
          setReminders:
              (minutes, {CalendarSlot calendar = CalendarSlot.primary}) async {
                savedMinutes.add(minutes);
                savedCalendars.add(calendar);
              },
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Připomínky hlavního kalendáře…'));
      await tester.pumpAndSettle();
      expect(find.text('Připomínky hlavního kalendáře'), findsOneWidget);
      await addReminder(tester, '2', 'hodiny');
      expect(savedMinutes.last, [120]);
      expect(savedCalendars.last, CalendarSlot.primary);

      // Closing one sheet before opening the next — showModalBottomSheet
      // stacks otherwise, and 'Přidat připomínku' would be ambiguous.
      await tester.tapAt(const Offset(400, 20));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Připomínky druhého kalendáře…'));
      await tester.pumpAndSettle();
      expect(find.text('Připomínky druhého kalendáře'), findsOneWidget);
      await addReminder(tester, '2', 'hodiny');
      expect(savedMinutes.last, [120]);
      expect(savedCalendars.last, CalendarSlot.secondary);
    });

    testWidgets('Barva tréninků opens the colour picker and saves the pick', (
      tester,
    ) async {
      final saved = <int?>[];
      await tester.pumpWidget(
        card(
          Stream.value(const CalendarLink(status: CalendarLinkStatus.linked)),
          setTrainingColor: (id) async => saved.add(id),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Barva tréninků'));
      await tester.pumpAndSettle();
      expect(find.byType(EventColorPicker), findsOneWidget);

      await tester.tap(
        find.descendant(
          of: find.byType(EventColorPicker),
          matching: find.byTooltip('Rajčatová'),
        ),
      );
      await tester.pumpAndSettle();

      expect(saved, [11]);
    });

    testWidgets('a failed training-colour save shows the friendly message', (
      tester,
    ) async {
      await tester.pumpWidget(
        card(
          Stream.value(const CalendarLink(status: CalendarLinkStatus.linked)),
          setTrainingColor: (_) async => throw Exception('not_allowed'),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Barva tréninků'));
      await tester.pumpAndSettle();
      await tester.tap(
        find.descendant(
          of: find.byType(EventColorPicker),
          matching: find.byTooltip('Rajčatová'),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Na tohle nemáš oprávnění.'), findsOneWidget);
    });
  });
  group('own colour card', () {
    Finder swatches() => find.descendant(
      of: find.byType(ColorPickerGrid),
      matching: find.byType(InkWell),
    );

    testWidgets('shows the picker with "Podle oddílu" selected by default', (
      tester,
    ) async {
      await tester.pumpWidget(app(me));
      await tester.pumpAndSettle();

      expect(find.text('Barva mých rezervací'), findsOneWidget);
      expect(find.byTooltip('Podle oddílu'), findsOneWidget);
      expect(find.byType(ColorPickerGrid), findsOneWidget);
    });

    testWidgets('tapping a swatch saves its palette index, the none option '
        'saves -1', (tester) async {
      // Tall enough that ensureVisible below brings the WHOLE grid on
      // screen at once — the Vzhled card above it pushes it further down
      // than the default test viewport allows.
      tester.view.physicalSize = const Size(800, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final saved = <int>[];
      await tester.pumpWidget(app(me, setOwnColor: (c) async => saved.add(c)));
      await tester.pumpAndSettle();

      await tester.ensureVisible(find.byType(ColorPickerGrid));
      await tester.tap(swatches().at(3)); // index 0 is the none option
      await tester.pumpAndSettle();
      // By position, not by the block icon: "Podle oddílu" is the current
      // choice here, so it wears the check mark instead.
      await tester.tap(swatches().first);
      await tester.pumpAndSettle();

      expect(saved, [2, -1]);
    });
  });

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

    // A sheet row is three fixed cells — Přehled, Kalendář (only with a
    // linked calendar) and the colour — each keyed `<team>:<column>`; see
    // my_teams_sheet.dart, whose own test covers the row in detail.
    Finder teamCell(String team, String column) =>
        find.byKey(ValueKey('$team:$column'));
    Finder teamCheckbox(String team) => find.descendant(
        of: teamCell(team, 'overview'), matching: find.byType(Checkbox));
    Finder teamColorDot(String team) => find.descendant(
        of: teamCell(team, 'color'), matching: find.byType(EventColorDot));

    testWidgets('the card sums up the followed teams and the sheet ticks one', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(800, 1800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final saved = <List<String>>[];
      await tester.pumpWidget(
        app(me, matches: [match], setFollowedTeams: (t) async => saved.add(t)),
      );
      await tester.pumpAndSettle();

      expect(find.text('Moje týmy'), findsOneWidget);
      expect(find.text('Žádný tým'), findsOneWidget);

      await tester.tap(find.text('Vybrat týmy…'));
      await tester.pumpAndSettle();
      await tester.tap(teamCheckbox('SKK Veverky Brno A'));
      await tester.pumpAndSettle();
      // Edits are local; the list goes out once, on Uložit.
      expect(saved, isEmpty);
      await tester.tap(find.widgetWithText(FilledButton, 'Uložit'));
      await tester.pumpAndSettle();

      expect(saved, [
        ['SKK Veverky Brno A'],
      ]);
    });

    testWidgets(
      'a followed team reads in the summary, and unticking drops it',
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
        await tester.pumpWidget(
          app(
            follower,
            matches: [match],
            setFollowedTeams: (t) async => saved.add(t),
          ),
        );
        await tester.pumpAndSettle();

        expect(find.text('SKK Veverky Brno A'), findsOneWidget);
        await tester.tap(find.text('Vybrat týmy…'));
        await tester.pumpAndSettle();
        await tester.tap(teamCheckbox('SKK Veverky Brno A'));
        await tester.pumpAndSettle();
        await tester.tap(find.widgetWithText(FilledButton, 'Uložit'));
        await tester.pumpAndSettle();
        expect(saved, [<String>[]]);
      },
    );

    // The rare other half of "whose matches are mine" (0039): its own
    // screen, reached from the card that owns the question.
    testWidgets('Výjimky sits under the team button and counts what is set',
        (tester) async {
      tester.view.physicalSize = const Size(800, 2000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(app(me, matches: [match]));
      await tester.pumpAndSettle();

      expect(find.text('Výjimky'), findsOneWidget);
      expect(find.text('Jednotlivé zápasy navíc nebo skryté.'), findsOneWidget);
      expect(tester.getTopLeft(find.text('Výjimky')).dy,
          greaterThan(tester.getTopLeft(find.text('Vybrat týmy…')).dy));
    });

    // One ProviderScope per test: a second pumpWidget does not swap them.
    testWidgets('Výjimky counts what is already set', (tester) async {
      tester.view.physicalSize = const Size(800, 2000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
          app(me, matches: [match], exceptions: const {'m1': true}));
      await tester.pumpAndSettle();

      // Czech counts three ways and the card says the number often enough
      // for "1 výjimek" to read as a bug.
      expect(find.text('1 výjimka'), findsOneWidget);
    });

    testWidgets('Výjimky opens its screen', (tester) async {
      tester.view.physicalSize = const Size(800, 2000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(app(me, matches: [match]));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Výjimky'));
      await tester.pumpAndSettle();
      // What the screen then shows is its own test's business (this harness
      // does not pin the schedule stream, so it may still be loading).
      expect(find.byType(MatchExceptionsScreen), findsOneWidget);
      expect(find.widgetWithText(AppBar, 'Výjimky'), findsOneWidget);
    });

    testWidgets('the identity card names the e-mail one signs in with',
        (tester) async {
      tester.view.physicalSize = const Size(800, 2000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(app(me));
      await tester.pumpAndSettle();

      expect(find.text('E-mail'), findsOneWidget);
      expect(find.text('me@example.com'), findsOneWidget);
      expect(tester.getTopLeft(find.text('E-mail')).dy,
          greaterThan(tester.getTopLeft(find.text('Jméno')).dy));
      expect(tester.getTopLeft(find.text('E-mail')).dy,
          lessThan(tester.getTopLeft(find.text('Oddíl')).dy));
    });

    // Reminders of the app's own (0040) — for the player who has no Google
    // calendar, or who wants both.
    testWidgets('Připomínky sums up the lead times and adds one',
        (tester) async {
      tester.view.physicalSize = const Size(800, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final saved = <List<int>>[];
      await tester.pumpWidget(app(me, setNotifyBefore: (m) async => saved.add(m)));
      await tester.pumpAndSettle();

      expect(
        find.text('Před tréninkem a zápasem — push do mobilu, jinak '
            'e-mailem.\nŽádné'),
        findsOneWidget,
      );
      await tester.tap(find.text('Nastavit…'));
      await tester.pumpAndSettle();
      expect(find.text('Před tréninkem ani zápasem se nic neozve.'),
          findsOneWidget);

      await tester.tap(find.text('Přidat připomínku'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '2');
      await tester.tap(find.text('Přidat'));
      await tester.pumpAndSettle();
      expect(saved, [
        [120],
      ], reason: 'hours by default');
    });

    testWidgets('Připomínky names what is set, and removing one saves the rest',
        (tester) async {
      tester.view.physicalSize = const Size(800, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      const reminded = Profile(
        id: 'me',
        displayName: 'Já Hráč',
        email: 'me@example.com',
        role: Role.player,
        status: ProfileStatus.approved,
        notifyBefore: [120, 1440],
      );
      final saved = <List<int>>[];
      await tester.pumpWidget(
          app(reminded, setNotifyBefore: (m) async => saved.add(m)));
      await tester.pumpAndSettle();

      // Farthest first, as the calendar's own lists read.
      expect(
        find.text('Před tréninkem a zápasem — push do mobilu, jinak '
            'e-mailem.\n1 den předem · 2 h předem'),
        findsOneWidget,
      );

      await tester.tap(find.text('Nastavit…'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(ListTile, '2 h předem')
          .last
          .hitTestable());
      await tester.pumpAndSettle();
      expect(saved, isEmpty, reason: 'tapping the row itself does nothing');

      await tester.tap(find.descendant(
        of: find.widgetWithText(ListTile, '2 h předem'),
        matching: find.byTooltip('Odebrat'),
      ));
      await tester.pumpAndSettle();
      expect(saved, [
        [1440],
      ]);
    });

    testWidgets('Po spuštění saves the chosen launch view', (tester) async {
      tester.view.physicalSize = const Size(800, 1800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final saved = <HomeView>[];
      await tester.pumpWidget(
        app(me, setDefaultView: (v) async => saved.add(v)),
      );
      await tester.pumpAndSettle();

      expect(find.text('Po spuštění'), findsOneWidget);
      await tester.tap(find.text('Můj přehled'));
      await tester.pumpAndSettle();
      expect(saved, [HomeView.trainings]);
    });

    testWidgets('several ticks are ONE save on Uložit, with every tick in it',
        (tester) async {
      tester.view.physicalSize = const Size(800, 1800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final saved = <List<String>>[];
      await tester.pumpWidget(app(
        me,
        matches: schedule,
        setFollowedTeams: (t) async => saved.add(t),
      ));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Vybrat týmy…'));
      await tester.pumpAndSettle();
      await tester.tap(teamCheckbox('KS Devítka Brno B'));
      await tester.pump();
      await tester.tap(teamCheckbox('SKK Veverky Brno A'));
      await tester.pumpAndSettle();

      // Both boxes tick at once and nothing has gone out yet.
      expect(tester.widget<Checkbox>(teamCheckbox('SKK Veverky Brno A')).value,
          isTrue);
      expect(saved, isEmpty);

      await tester.tap(find.widgetWithText(FilledButton, 'Uložit'));
      await tester.pumpAndSettle();
      expect(saved.length, 1, reason: 'one call carries the whole list');
      expect(saved.single, ['KS Devítka Brno B', 'SKK Veverky Brno A']);
    });

    testWidgets('a failing save shows the friendly message, not the raw '
        'exception', (tester) async {
      tester.view.physicalSize = const Size(800, 1800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        app(
          me,
          matches: schedule,
          setFollowedTeams: (_) async => throw Exception('not_allowed'),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Vybrat týmy…'));
      await tester.pumpAndSettle();
      await tester.tap(teamCheckbox('SKK Veverky Brno A'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Uložit'));
      await tester.pumpAndSettle();

      // The sheet is gone when the answer comes back, so the snack belongs
      // to the profile underneath — and the card still reads what the
      // server holds, because nothing was saved.
      expect(find.text('Na tohle nemáš oprávnění.'), findsOneWidget);
      expect(find.textContaining('Nepovedlo se'), findsNothing);
      expect(find.text('Žádný tým'), findsOneWidget);
    });

    // -----------------------------------------------------------------------
    // Team colour (0036): the SAME registry showCalendarTeamsSheet's dot
    // edits, and Můj přehled's trophy reads.
    // -----------------------------------------------------------------------

    testWidgets('an unticked team shows no colour dot', (tester) async {
      tester.view.physicalSize = const Size(800, 1800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(app(me, matches: [match]));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Vybrat týmy…'));
      await tester.pumpAndSettle();

      expect(teamCheckbox('SKK Veverky Brno A'), findsOneWidget);
      expect(teamColorDot('SKK Veverky Brno A'), findsNothing);
    });

    testWidgets('a ticked team shows its shared colour straight away, from '
        'myTeamColorsProvider — the same registry the calendar sheet uses', (
      tester,
    ) async {
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
      await tester.pumpWidget(app(
        follower,
        matches: [match],
        teamColors: const {'SKK Veverky Brno A': 5},
      ));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Vybrat týmy…'));
      await tester.pumpAndSettle();

      expect(
        tester.widget<EventColorDot>(teamColorDot('SKK Veverky Brno A')).colorId,
        5,
      );
    });

    testWidgets('ticking a team and picking its colour saves BOTH — the '
        'tick through setFollowedTeams, the colour through setTeamColors — '
        'once, on Uložit', (tester) async {
      tester.view.physicalSize = const Size(800, 1800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final savedTeams = <List<String>>[];
      final savedColors = <Map<String, int?>>[];
      await tester.pumpWidget(app(
        me,
        matches: [match],
        setFollowedTeams: (t) async => savedTeams.add(t),
        setTeamColors: (c) async => savedColors.add(c),
      ));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Vybrat týmy…'));
      await tester.pumpAndSettle();
      await tester.tap(teamCheckbox('SKK Veverky Brno A'));
      await tester.pumpAndSettle();
      await tester.tap(teamColorDot('SKK Veverky Brno A'));
      await tester.pumpAndSettle();
      await tester.tap(
        find.descendant(
          of: find.byType(EventColorPicker),
          matching: find.byTooltip('Šalvějová'),
        ),
      );
      await tester.pumpAndSettle();
      expect(savedTeams, isEmpty);
      expect(savedColors, isEmpty);

      await tester.tap(find.widgetWithText(FilledButton, 'Uložit'));
      await tester.pumpAndSettle();

      expect(savedTeams, [
        ['SKK Veverky Brno A'],
      ]);
      expect(savedColors, [
        {'SKK Veverky Brno A': 2},
      ]);
    });

    testWidgets('picking a colour on an already-followed team saves only '
        'the colour — setFollowedTeams is never called when the team list '
        'itself never changed', (tester) async {
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
      final savedColors = <Map<String, int?>>[];
      await tester.pumpWidget(app(
        follower,
        matches: [match],
        setFollowedTeams: (_) async => fail('unexpected team save'),
        setTeamColors: (c) async => savedColors.add(c),
      ));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Vybrat týmy…'));
      await tester.pumpAndSettle();
      await tester.tap(teamColorDot('SKK Veverky Brno A'));
      await tester.pumpAndSettle();
      await tester.tap(
        find.descendant(
          of: find.byType(EventColorPicker),
          matching: find.byTooltip('Bazalková'),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.widgetWithText(FilledButton, 'Uložit'));
      await tester.pumpAndSettle();

      expect(savedColors, [
        {'SKK Veverky Brno A': 10},
      ]);
    });

    testWidgets('picking a colour then picking the original one back sends '
        'nothing, like ticking a team back off does for the team list', (
      tester,
    ) async {
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
      await tester.pumpWidget(app(
        follower,
        matches: [match],
        teamColors: const {'SKK Veverky Brno A': 5},
        setFollowedTeams: (_) async => fail('unexpected team save'),
        setTeamColors: (_) async => fail('unexpected colour save'),
      ));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Vybrat týmy…'));
      await tester.pumpAndSettle();
      await tester.tap(teamColorDot('SKK Veverky Brno A'));
      await tester.pumpAndSettle();
      await tester.tap(
        find.descendant(
          of: find.byType(EventColorPicker),
          matching: find.byTooltip('Mandarinková'), // id 6
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(teamColorDot('SKK Veverky Brno A'));
      await tester.pumpAndSettle();
      await tester.tap(
        find.descendant(
          of: find.byType(EventColorPicker),
          matching: find.byTooltip('Banánová'), // id 5, back to the original
        ),
      );
      await tester.pumpAndSettle();

      expect(
        tester.widget<EventColorDot>(teamColorDot('SKK Veverky Brno A')).colorId,
        5,
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Uložit'));
      await tester.pumpAndSettle();
      // setFollowedTeams/setTeamColors would have fail()ed had either fired.
    });
  });
}
