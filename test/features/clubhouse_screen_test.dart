import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rezervator/data/clock.dart';
import 'package:rezervator/data/providers.dart';
import 'package:rezervator/domain/models.dart';
import 'package:rezervator/core/hub_menu.dart';
import 'package:rezervator/features/clubhouse/clubhouse_screen.dart';

/// Records every provider that fails — a screen reaching past its test
/// doubles to the uninitialised Supabase client shows up here.
final class _Failures extends ProviderObserver {
  final errors = <Object>[];

  @override
  void providerDidFail(
    ProviderObserverContext context,
    Object error,
    StackTrace stackTrace,
  ) => errors.add(error);
}

/// The Klubovna hub: its six entries, the shell's trailing icons riding
/// along on the same header, and the shared HubMenu's list/grid breakpoint
/// (below vs at/above 840 dp).
void main() {
  // HomeShell always wraps its body in a Scaffold — reproduced here so the
  // hub's ListTiles/Cards find the Material ancestor they need, same as in
  // the real app.
  // The pushed Výsledky screen watches these too — without them it would
  // reach through to the real Supabase client.
  const me = Profile(
    id: 'me',
    displayName: 'Já Hráč',
    email: 'me@example.com',
    role: Role.player,
    status: ProfileStatus.approved,
  );
  Widget app({
    List<Widget> trailing = const [],
    ProviderObserver? observer,
    List<Message> messages = const [],
    List<MessageRecipient> recipients = const [],
  }) =>
      ProviderScope(
        observers: [?observer],
        overrides: [
          // The Nástěnka and Zprávy badges (unreadCountsProvider) read these.
          messagesProvider.overrideWith((ref) => Stream.value(messages)),
          myMessageRecipientsProvider.overrideWith(
            (ref) => Stream.value(recipients),
          ),
          venuesProvider.overrideWith((ref) => Stream.value(const <Venue>[])),
          prioritySlotsProvider.overrideWithValue(const []),
          prioritySlotsLoadingProvider.overrideWithValue(false),
          matchResultsProvider.overrideWith((ref) => Stream.value(const {})),
          matchPlayerResultsProvider.overrideWith(
            (ref, id) => Stream.value(const []),
          ),
          myProfileProvider.overrideWith((ref) => Stream.value(me)),
          ourTeamsProvider.overrideWithValue(const []),
          myTeamColorsProvider.overrideWith((ref) => Stream.value(const {})),
          myCalendarTeamsProvider.overrideWith(
            (ref) => Stream.value(const <CalendarTeam>[]),
          ),
          myMatchExceptionsProvider.overrideWith(
            (ref) => Stream.value(const {}),
          ),
          nowProvider.overrideWith(
            (ref) => Stream.value(DateTime(2026, 9, 23, 18, 0)),
          ),
          contactsProvider.overrideWith((ref) async => const <Contact>[]),
          dutyPeriodsProvider.overrideWith(
            (ref) => Stream.value(const <DutyPeriod>[]),
          ),
          dutyAssignmentsProvider.overrideWith(
            (ref) => Stream.value(const <DutyAssignment>[]),
          ),
          playersProvider.overrideWith((ref) async => const <PlayerName>[]),
          // The pushed Zprávy screen reads the blocks for its context chips.
          timeBlocksProvider.overrideWith((ref) => Stream.value(const <TimeBlock>[])),
          settingsProvider.overrideWith(
            (ref) => Stream.value(ScheduleSettings.defaults),
          ),
        ],
        child: MaterialApp(
          home: Scaffold(body: ClubhouseScreen(trailing: trailing)),
        ),
      );

  void narrow(WidgetTester tester) {
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  void wide(WidgetTester tester) {
    tester.view.physicalSize = const Size(1200, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  testWidgets('shows the Výsledky, Kuželny, Kontakty, Služby, Nástěnka and '
      'Zprávy entries with their subtitles', (tester) async {
    narrow(tester);
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();

    expect(find.text('Výsledky'), findsOneWidget);
    expect(find.text('Zápasy a výsledky našich týmů'), findsOneWidget);
    expect(find.text('Kuželny'), findsOneWidget);
    // Kuželny no longer says „Kontakty" — that is the new entry's word.
    expect(find.text('Adresy a vybavení kuželen'), findsOneWidget);
    expect(find.text('Kontakty a vybavení kuželen'), findsNothing);
    expect(find.text('Kontakty'), findsOneWidget);
    expect(find.text('Hráči kuželny — e-mail a telefon'), findsOneWidget);
    expect(find.byIcon(Icons.scoreboard_outlined), findsOneWidget);
    expect(find.byIcon(Icons.location_on_outlined), findsOneWidget);
    expect(find.byIcon(Icons.contacts_outlined), findsOneWidget);
    expect(find.text('Služby'), findsOneWidget);
    expect(find.text('Kdo slouží na kantýně'), findsOneWidget);
    expect(find.byIcon(Icons.local_cafe_outlined), findsOneWidget);
    expect(find.text('Nástěnka'), findsOneWidget);
    expect(find.text('Oznámení správce'), findsOneWidget);
    expect(find.byIcon(Icons.campaign_outlined), findsOneWidget);
    expect(find.text('Zprávy'), findsOneWidget);
    expect(find.text('Zprávy pro tebe a od tebe'), findsOneWidget);
    expect(find.byIcon(Icons.forum_outlined), findsOneWidget);
  });

  /// Hub labels top to bottom (list) or in reading order (grid).
  List<String> labels(WidgetTester tester) {
    final found = find.descendant(
      of: find.byType(HubMenu),
      matching: find.byWidgetPredicate(
        (w) => w is Text && const {'Kontakty', 'Kuželny', 'Nástěnka', 'Služby', 'Výsledky', 'Zprávy'}
            .contains(w.data),
      ),
    );
    final texts = found.evaluate().toList()
      ..sort((a, b) {
        final pa = tester.getTopLeft(find.byWidget(a.widget));
        final pb = tester.getTopLeft(find.byWidget(b.widget));
        return pa.dy != pb.dy ? pa.dy.compareTo(pb.dy) : pa.dx.compareTo(pb.dx);
      });
    return [for (final e in texts) (e.widget as Text).data!];
  }

  testWidgets('the entries are in Czech alphabetical order, in the list',
      (tester) async {
    narrow(tester);
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();

    expect(labels(tester), [
      'Kontakty',
      'Kuželny',
      'Nástěnka',
      'Služby',
      'Výsledky',
      'Zprávy',
    ]);
  });

  testWidgets('the entries are in Czech alphabetical order, in the grid',
      (tester) async {
    wide(tester);
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();

    expect(labels(tester), [
      'Kontakty',
      'Kuželny',
      'Nástěnka',
      'Služby',
      'Výsledky',
      'Zprávy',
    ]);
  });

  testWidgets('below 840 dp the hub renders a list', (tester) async {
    narrow(tester);
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();

    expect(find.byType(ListView), findsOneWidget);
    expect(find.byType(GridView), findsNothing);
    expect(find.byType(ListTile), findsNWidgets(6));
  });

  testWidgets('at 840 dp and above the hub renders a card grid', (
    tester,
  ) async {
    wide(tester);
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();

    expect(find.byType(GridView), findsOneWidget);
    expect(find.byType(ListView), findsNothing);
    expect(find.byType(Card), findsNWidgets(6));
  });

  testWidgets(
    'tapping Výsledky opens the real results screen, Kuželny the real '
    'venues screen, Kontakty the real contacts screen, Služby the real duty '
    'roster',
    (tester) async {
      narrow(tester);
      final failures = _Failures();
      await tester.pumpWidget(app(observer: failures));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Výsledky'));
      await tester.pumpAndSettle();
      expect(find.widgetWithText(AppBar, 'Výsledky'), findsOneWidget);

      await tester.pageBack();
      await tester.pumpAndSettle();

      await tester.tap(find.text('Kuželny'));
      await tester.pumpAndSettle();
      expect(find.widgetWithText(AppBar, 'Kuželny'), findsOneWidget);

      await tester.pageBack();
      await tester.pumpAndSettle();

      await tester.tap(find.text('Kontakty'));
      await tester.pumpAndSettle();
      expect(find.widgetWithText(AppBar, 'Kontakty'), findsOneWidget);
      expect(find.text('Zatím tu nikdo není.'), findsOneWidget);

      await tester.pageBack();
      await tester.pumpAndSettle();

      await tester.tap(find.text('Služby'));
      await tester.pumpAndSettle();
      expect(find.widgetWithText(AppBar, 'Služby'), findsOneWidget);
      expect(find.text('Služby zatím nejsou naplánované.'), findsOneWidget);
      expect(failures.errors, isEmpty);
    },
  );

  testWidgets('the shell\'s trailing actions ride along on the header', (
    tester,
  ) async {
    narrow(tester);
    await tester.pumpWidget(app(trailing: const [Icon(Icons.person)]));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.person), findsOneWidget);
  });

  testWidgets('Nástěnka carries an unread-notice badge, and none when read', (tester) async {
    narrow(tester);
    final notice = Message(
      id: 'n1', kind: MessageKind.notice, audience: MessageAudience.all,
      authorId: 'admin', authorRole: MessageAuthorRole.admin, onDate: null, blockId: null,
      title: 'Nové dráhy', body: 'Od pondělí.', expiresAt: null, notify: true,
      createdAt: DateTime(2026, 9, 1), updatedAt: DateTime(2026, 9, 1),
    );
    MessageRecipient row({DateTime? readAt}) => MessageRecipient(
        messageId: 'n1', userId: 'me', readAt: readAt,
        reaction: null, reply: null, reactedAt: null);

    await tester.pumpWidget(app(messages: [notice], recipients: [row()]));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(Badge, '1'), findsOneWidget);

    // A fresh scope: re-pumping the same ProviderScope keeps the stream
    // overrides' first values.
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(app(messages: [notice], recipients: [row(readAt: DateTime(2026, 9, 2))]));
    await tester.pumpAndSettle();
    expect(find.byType(Badge), findsNothing);
  });

  testWidgets('tapping Nástěnka opens the real notice board', (tester) async {
    narrow(tester);
    final failures = _Failures();
    await tester.pumpWidget(app(observer: failures));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Nástěnka'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(AppBar, 'Nástěnka'), findsOneWidget);
    expect(find.text('Na nástěnce zatím nic není.'), findsOneWidget);
    expect(failures.errors, isEmpty);
  });

  testWidgets('Zprávy carries an unread-message badge, and none when read', (tester) async {
    narrow(tester);
    final message = Message(
      id: 'm1', kind: MessageKind.message, audience: MessageAudience.day,
      authorId: 'staff', authorRole: MessageAuthorRole.player,
      onDate: Day(2026, 9, 24), blockId: null,
      title: null, body: 'Přijďte dřív.', expiresAt: null, notify: true,
      createdAt: DateTime(2026, 9, 23), updatedAt: DateTime(2026, 9, 23),
    );
    MessageRecipient row({DateTime? readAt}) => MessageRecipient(
        messageId: 'm1', userId: 'me', readAt: readAt,
        reaction: null, reply: null, reactedAt: null);

    await tester.pumpWidget(app(messages: [message], recipients: [row()]));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(Badge, '1'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(app(messages: [message], recipients: [row(readAt: DateTime(2026, 9, 23))]));
    await tester.pumpAndSettle();
    expect(find.byType(Badge), findsNothing);
  });

  // Each entry counts its own kind: a swapped count would still leave a
  // badge somewhere, so each is looked for on its own entry.
  testWidgets('Nástěnka counts the unread notices and Zprávy the unread '
      'messages, each on its own entry', (tester) async {
    narrow(tester);
    Message message(String id, MessageKind kind) => Message(
          id: id, kind: kind,
          audience: kind == MessageKind.notice ? MessageAudience.all : MessageAudience.day,
          authorId: 'admin', authorRole: MessageAuthorRole.admin,
          onDate: kind == MessageKind.notice ? null : Day(2026, 9, 24), blockId: null,
          title: kind == MessageKind.notice ? 'Oznam $id' : null, body: 'Text $id.',
          expiresAt: null, notify: true,
          createdAt: DateTime(2026, 9, 23), updatedAt: DateTime(2026, 9, 23),
        );
    MessageRecipient unread(String id) => MessageRecipient(
        messageId: id, userId: 'me', readAt: null,
        reaction: null, reply: null, reactedAt: null);

    await tester.pumpWidget(app(
      messages: [
        message('n1', MessageKind.notice),
        message('n2', MessageKind.notice),
        message('m1', MessageKind.message),
      ],
      recipients: [unread('n1'), unread('n2'), unread('m1')],
    ));
    await tester.pumpAndSettle();
    Finder badgeOf(String entry, String count) => find.descendant(
        of: find.widgetWithText(ListTile, entry),
        matching: find.widgetWithText(Badge, count));
    expect(badgeOf('Nástěnka', '2'), findsOneWidget);
    expect(badgeOf('Zprávy', '1'), findsOneWidget);
    expect(badgeOf('Nástěnka', '1'), findsNothing);
    expect(badgeOf('Zprávy', '2'), findsNothing);
  });

  testWidgets('tapping Zprávy opens the real messages screen', (tester) async {
    narrow(tester);
    final failures = _Failures();
    await tester.pumpWidget(app(observer: failures));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Zprávy'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(AppBar, 'Zprávy'), findsOneWidget);
    expect(find.text('Zatím žádné zprávy.'), findsOneWidget);
    expect(failures.errors, isEmpty);
  });
}
