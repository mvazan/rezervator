import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rezervator/data/clock.dart';
import 'package:rezervator/data/providers.dart';
import 'package:rezervator/domain/models.dart';
import 'package:rezervator/features/clubhouse/notice_board_screen.dart';
import 'package:rezervator/features/clubhouse/widgets/notice_form.dart';

/// Klubovna → Nástěnka (0051): active notices with „Starší (N)“ below,
/// read marking on open, the admin's form, seen sheet and ⋮ actions.
void main() {
  const me = Profile(
    id: 'me', displayName: 'Já Hráč', email: 'me@example.com',
    role: Role.player, status: ProfileStatus.approved,
  );
  const admin = Profile(
    id: 'admin', displayName: 'Adam Správce', email: 'admin@example.com',
    role: Role.admin, status: ProfileStatus.approved,
  );

  Message notice(String id, {DateTime? expiresAt, DateTime? createdAt, String? authorId = 'admin',
      String body = ''}) => Message(
        id: id, kind: MessageKind.notice, audience: MessageAudience.all,
        authorId: authorId, authorRole: MessageAuthorRole.admin, onDate: null, blockId: null,
        title: 'Nové dráhy $id', body: body.isEmpty ? 'Text oznamu $id.' : body,
        expiresAt: expiresAt, notify: true,
        createdAt: createdAt ?? DateTime(2026, 9, 1), updatedAt: createdAt ?? DateTime(2026, 9, 1),
      );

  MessageRecipient row(String noticeId, String userId, {DateTime? readAt}) =>
      MessageRecipient(messageId: noticeId, userId: userId, readAt: readAt,
          reaction: null, reply: null, reactedAt: null);

  // [recipients] feeds both recipient streams the way RLS would split
  // them: my own rows, and every row of one notice (the admin's view).
  Widget app({
    Profile profile = me,
    List<Message> notices = const [],
    List<MessageRecipient> recipients = const [],
    List<PlayerName> roster = const [],
    Future<void> Function(List<String> ids)? markRead,
    Stream<List<Message>>? noticeStream,
    NoticeUpdate? updateNotice,
    Future<void> Function(String id)? deleteNotice,
    Future<void> Function(String id, bool show)? setOnKiosk,
  }) =>
      ProviderScope(
        overrides: [
          myProfileProvider.overrideWith((ref) => Stream.value(profile)),
          messagesProvider.overrideWith((ref) => noticeStream ?? Stream.value(notices)),
          myMessageRecipientsProvider.overrideWith((ref) => Stream.value(
              [for (final r in recipients) if (r.userId == profile.id) r])),
          messageParticipantsProvider.overrideWith((ref, id) => Stream.value(
              [for (final r in recipients) if (r.messageId == id) r])),
          playersProvider.overrideWith((ref) async => roster),
          nowProvider.overrideWith((ref) => Stream.value(DateTime(2026, 10, 2, 12))),
        ],
        child: MaterialApp(
          home: NoticeBoardScreen(
            markRead: markRead ?? (_) async {},
            updateNotice: updateNotice ??
                (id, {required title, required body, expiresAt}) async {},
            deleteNotice: deleteNotice ?? (_) async {},
            setOnKiosk: setOnKiosk ?? (_, _) async {},
          ),
        ),
      );

  Future<void> openMenu(WidgetTester tester) async {
    await tester.tap(find.byType(PopupMenuButton<String>).first);
    await tester.pumpAndSettle();
  }

  testWidgets('active notices show, expired collapse under "Starší"', (tester) async {
    final active = notice('a1');
    final expired = notice('e1', expiresAt: DateTime(2026, 9, 15));
    await tester.pumpWidget(app(notices: [active, expired]));
    await tester.pumpAndSettle();
    expect(find.text('Nové dráhy a1'), findsOneWidget);
    expect(find.text('Nové dráhy e1'), findsNothing);
    expect(find.text('Starší (1)'), findsOneWidget);
    await tester.tap(find.text('Starší (1)'));
    await tester.pumpAndSettle();
    expect(find.text('Nové dráhy e1'), findsOneWidget);
  });

  testWidgets('empty board shows the empty state', (tester) async {
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    expect(find.text('Na nástěnce zatím nic není.'), findsOneWidget);
  });

  testWidgets('a non-admin gets no "Nový oznam" and no seen count', (tester) async {
    await tester.pumpWidget(app(notices: [notice('a1')]));
    await tester.pumpAndSettle();
    expect(find.text('Nový oznam'), findsNothing);
    expect(find.textContaining('Zobrazilo'), findsNothing);
  });

  testWidgets('an admin sees "Nový oznam" and the seen count', (tester) async {
    await tester.pumpWidget(app(
      profile: admin,
      notices: [notice('a1')],
      recipients: [
        MessageRecipient(messageId: 'a1', userId: 'p1', readAt: DateTime(2026, 9, 2),
            reaction: null, reply: null, reactedAt: null),
        MessageRecipient(messageId: 'a1', userId: 'p2', readAt: null,
            reaction: null, reply: null, reactedAt: null),
      ],
      roster: const [PlayerName(id: 'p1', displayName: 'Petr'), PlayerName(id: 'p2', displayName: 'Tomáš')],
    ));
    await tester.pumpAndSettle();
    expect(find.text('Nový oznam'), findsOneWidget);
    expect(find.textContaining('Zobrazilo 1 z 2'), findsOneWidget);
  });

  testWidgets('opening the board marks read only my unread rows that exist', (tester) async {
    final marked = <List<String>>[];
    await tester.pumpWidget(app(
      notices: [notice('a1'), notice('a2'), notice('a3')],
      recipients: [row('a1', 'me'), row('a3', 'me', readAt: DateTime(2026, 9, 2))],
      markRead: (ids) async => marked.add(ids),
    ));
    await tester.pumpAndSettle();
    // a2 has no recipient row for me (sent before I joined) — never marked.
    expect(marked, [['a1']]);
  });

  testWidgets('a long notice is cut with „Více“ and expands in place', (tester) async {
    final long = List.filled(60, 'slovo').join(' ');
    await tester.pumpWidget(app(notices: [notice('a1', body: long)]));
    await tester.pumpAndSettle();
    expect(find.text('Více'), findsOneWidget);
    expect(tester.widget<Text>(find.text(long)).maxLines, 3);
    await tester.tap(find.text('Více'));
    await tester.pumpAndSettle();
    expect(find.text('Méně'), findsOneWidget);
    expect(tester.widget<Text>(find.text(long)).maxLines, isNull);
  });

  testWidgets('a short notice has no „Více“', (tester) async {
    await tester.pumpWidget(app(notices: [notice('a1')]));
    await tester.pumpAndSettle();
    expect(find.text('Více'), findsNothing);
  });

  testWidgets('a short body of four lines is cut too, three lines are not', (tester) async {
    await tester.pumpWidget(app(notices: [
      notice('a1', body: 'jedna\ndvě\ntři\nčtyři'),
      notice('a2', body: 'jedna\ndvě\ntři'),
    ]));
    await tester.pumpAndSettle();
    expect(find.text('Více'), findsOneWidget);
    expect(tester.widget<Text>(find.text('jedna\ndvě\ntři\nčtyři')).maxLines, 3);
    expect(tester.widget<Text>(find.text('jedna\ndvě\ntři')).maxLines, isNull);
  });

  testWidgets('„Nový oznam“ opens the form with +14 days and the switches off/on', (tester) async {
    await tester.pumpWidget(app(profile: admin));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Nový oznam'));
    await tester.pumpAndSettle();
    expect(find.text('Platí do: 16. 10. 2026'), findsOneWidget);
    expect(find.text('Změnit'), findsOneWidget);
    expect(tester.widget<SwitchListTile>(find.widgetWithText(SwitchListTile, 'Do odvolání')).value, false);
    expect(tester.widget<SwitchListTile>(find.widgetWithText(SwitchListTile, 'Poslat upozornění')).value, true);
    await tester.tap(find.text('Do odvolání'));
    await tester.pumpAndSettle();
    expect(find.text('Platí do: do odvolání'), findsOneWidget);
    expect(find.text('Změnit'), findsNothing);
  });

  testWidgets('editing hides „Poslat upozornění“ and preselects „Do odvolání“ for an open-ended notice', (tester) async {
    await tester.pumpWidget(app(profile: admin, notices: [notice('a1')]));
    await tester.pumpAndSettle();
    await openMenu(tester);
    await tester.tap(find.text('Upravit'));
    await tester.pumpAndSettle();
    expect(find.text('Upravit oznam'), findsOneWidget);
    expect(find.text('Poslat upozornění'), findsNothing);
    expect(find.text('Platí do: do odvolání'), findsOneWidget);
  });

  testWidgets('„Kdo si to zobrazil“ lists who has and has not opened it', (tester) async {
    await tester.pumpWidget(app(
      profile: admin,
      notices: [notice('a1')],
      recipients: [row('a1', 'p1', readAt: DateTime(2026, 9, 2)), row('a1', 'p2')],
      roster: const [PlayerName(id: 'p1', displayName: 'Petr'), PlayerName(id: 'p2', displayName: 'Tomáš')],
    ));
    await tester.pumpAndSettle();
    await openMenu(tester);
    await tester.tap(find.text('Kdo si to zobrazil'));
    await tester.pumpAndSettle();
    expect(find.text('Zobrazili:'), findsOneWidget);
    expect(find.text('Petr'), findsOneWidget);
    expect(find.text('Ještě nezobrazili:'), findsOneWidget);
    expect(find.text('Tomáš'), findsOneWidget);
  });

  // „Zobrazilo 0 z 0“ would say the notice reached nobody.
  for (final (label, failing) in const [('loading', false), ('failed', true)]) {
    testWidgets('the seen sheet, its rows $label, never says „Zobrazilo 0 z 0“',
        (tester) async {
      await tester.pumpWidget(ProviderScope(
        overrides: [
          myProfileProvider.overrideWith((ref) => Stream.value(admin)),
          messagesProvider.overrideWith((ref) => Stream.value([notice('a1')])),
          myMessageRecipientsProvider.overrideWith((ref) => Stream.value(const [])),
          // A factory: Riverpod retries a failed provider.
          messageParticipantsProvider.overrideWith((ref, id) => failing
              ? Stream<List<MessageRecipient>>.error(
                  Exception('SocketException: offline'))
              : const Stream<List<MessageRecipient>>.empty()),
          playersProvider.overrideWith((ref) async => const []),
          nowProvider.overrideWith((ref) => Stream.value(DateTime(2026, 10, 2, 12))),
        ],
        child: const MaterialApp(home: NoticeBoardScreen(markRead: _noMark)),
      ));
      await tester.pump();
      await tester.pump();
      await openMenu(tester);
      await tester.tap(find.text('Kdo si to zobrazil'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      final sheet = find.byType(BottomSheet);
      expect(find.descendant(of: sheet, matching: find.textContaining('Zobrazilo')),
          findsNothing);
      if (failing) {
        expect(find.descendant(of: sheet,
                matching: find.text('Jsi offline — zkus to znovu po připojení.')),
            findsOneWidget);
      } else {
        expect(find.descendant(of: sheet, matching: find.byType(CircularProgressIndicator)),
            findsOneWidget);
      }
    });
  }

  // The spec's „Zobrazilo 12 z 40“ leaves 28 names to list; at a large text
  // size (2.0 is AppTextScaler's cap) or in landscape they are taller than
  // the sheet, and the last of them must still be reachable.
  for (final (size, scale) in const [
    (Size(412, 915), 2.0),
    (Size(360, 640), 1.3),
    (Size(780, 360), 1.0),
  ]) {
    final label = '${size.width.toInt()}×${size.height.toInt()}, text ×$scale';
    testWidgets('the seen sheet scrolls to its last name at $label', (tester) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      tester.platformDispatcher.textScaleFactorTestValue = scale;
      addTearDown(tester.view.reset);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      String pad(int i) => i.toString().padLeft(2, '0');
      await tester.pumpWidget(app(
        profile: admin,
        notices: [notice('a1')],
        recipients: [
          for (var i = 1; i <= 40; i++)
            row('a1', 'p$i', readAt: i <= 12 ? DateTime(2026, 9, 2) : null),
        ],
        roster: [
          for (var i = 1; i <= 40; i++)
            PlayerName(id: 'p$i', displayName: 'Jaroslav Novotný ${pad(i)}'),
        ],
      ));
      await tester.pumpAndSettle();
      await openMenu(tester);
      await tester.tap(find.text('Kdo si to zobrazil'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('Zobrazilo 12 z 40'), findsOneWidget);
      final names = find.textContaining('Novotný 13');
      expect(names, findsOneWidget);
      expect(tester.widget<Text>(names).data, endsWith('Novotný 40'));
      final sheet = find.byType(BottomSheet);
      await tester.drag(
        find.descendant(of: sheet, matching: find.byType(Scrollable)).first,
        const Offset(0, -3000),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(tester.getBottomLeft(names).dy,
          lessThanOrEqualTo(tester.getBottomLeft(sheet).dy));
    });
  }

  testWidgets('the admin hides a notice from the kiosk and shows it again',
      (tester) async {
    final calls = <(String, bool)>[];
    final hidden = Message(
      id: 'h1', kind: MessageKind.notice, audience: MessageAudience.all,
      authorId: 'admin', authorRole: MessageAuthorRole.admin, onDate: null,
      blockId: null, title: 'Skrytý', body: 'Text.', expiresAt: null,
      notify: true, showOnKiosk: false,
      createdAt: DateTime(2026, 9, 2), updatedAt: DateTime(2026, 9, 2),
    );
    await tester.pumpWidget(app(
      profile: admin,
      notices: [notice('a1'), hidden],
      setOnKiosk: (id, show) async => calls.add((id, show)),
    ));
    await tester.pumpAndSettle();
    // The hidden one says so; the other does not.
    expect(find.textContaining('skrytý na kiosku'), findsOneWidget);

    await openMenu(tester);
    await tester.tap(find.text('Skrýt na kiosku'));
    await tester.pumpAndSettle();
    expect(calls, [('a1', false)]);

    await tester.tap(find.byType(PopupMenuButton<String>).last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Zobrazit na kiosku'));
    await tester.pumpAndSettle();
    expect(calls.last, ('h1', true));
  });

  testWidgets('a notice posted ahead of time: the admin sees it under '
      '„Naplánované“, a player not yet', (tester) async {
    final scheduled = Message(
      id: 's1', kind: MessageKind.notice, audience: MessageAudience.all,
      authorId: 'admin', authorRole: MessageAuthorRole.admin, onDate: null,
      blockId: null, title: 'Brigáda', body: 'Text.', expiresAt: null,
      notify: true, visibleFrom: DateTime(2026, 10, 5, 8),
      createdAt: DateTime(2026, 10, 1), updatedAt: DateTime(2026, 10, 1),
    );
    await tester.pumpWidget(app(profile: admin, notices: [notice('a1'), scheduled]));
    await tester.pumpAndSettle();
    expect(find.text('Naplánované (1)'), findsOneWidget);
    expect(find.text('Brigáda'), findsOneWidget);
    expect(find.textContaining('zobrazí se 5. 10. v 8:00'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());

    await tester.pumpWidget(app(notices: [notice('a1'), scheduled]));
    await tester.pumpAndSettle();
    expect(find.text('Brigáda'), findsNothing);
    expect(find.textContaining('Naplánované'), findsNothing);
  });

  testWidgets('a player has no kiosk menu', (tester) async {
    await tester.pumpWidget(app(notices: [notice('a1')]));
    await tester.pumpAndSettle();
    expect(find.byType(PopupMenuButton<String>), findsNothing);
    expect(find.textContaining('kiosku'), findsNothing);
  });

  testWidgets('„Sejmout“ and „Smazat“ both ask first', (tester) async {
    await tester.pumpWidget(app(profile: admin, notices: [notice('a1')]));
    await tester.pumpAndSettle();
    await openMenu(tester);
    await tester.tap(find.text('Sejmout'));
    await tester.pumpAndSettle();
    expect(find.text('Sejmout oznam?'), findsOneWidget);
    await tester.tap(find.text('Zrušit'));
    await tester.pumpAndSettle();
    await openMenu(tester);
    await tester.tap(find.text('Smazat'));
    await tester.pumpAndSettle();
    expect(find.text('Smazat oznam?'), findsOneWidget);
  });

  // The board and the badge compare against nowProvider, which ticks once a
  // minute and polls every 15 s — up to ~75 s behind the wall clock. An
  // expiry taken from DateTime.now() is later than that, so the echoed
  // notice stayed active after „Oznam sejmut.“ until the next tick.
  testWidgets('„Sejmout“ expires at the board\'s own clock, so the card leaves at once', (tester) async {
    final uiNow = DateTime.now().subtract(const Duration(seconds: 40));
    final sent = <DateTime?>[];
    final messages = StreamController<List<Message>>();
    addTearDown(messages.close);
    await tester.pumpWidget(ProviderScope(
      overrides: [
        myProfileProvider.overrideWith((ref) => Stream.value(admin)),
        messagesProvider.overrideWith((ref) => messages.stream),
        myMessageRecipientsProvider.overrideWith((ref) => Stream.value(const [])),
        messageParticipantsProvider.overrideWith((ref, id) => Stream.value(const [])),
        nowProvider.overrideWith((ref) => Stream.value(uiNow)),
      ],
      child: MaterialApp(
        home: NoticeBoardScreen(
          markRead: (_) async {},
          updateNotice: (id, {required title, required body, expiresAt}) async {
            expect((id, title, body), ('a1', 'Nové dráhy a1', 'Text oznamu a1.'));
            sent.add(expiresAt);
          },
        ),
      ),
    ));
    messages.add([notice('a1')]);
    await tester.pumpAndSettle();
    await openMenu(tester);
    await tester.tap(find.text('Sejmout'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Ano'));
    await tester.pumpAndSettle();
    expect(sent, [uiNow]);
    expect(find.text('Oznam sejmut.'), findsOneWidget);
    // The server's echo: the notice as the RPC left it.
    messages.add([notice('a1', expiresAt: sent.single)]);
    await tester.pumpAndSettle();
    expect(find.text('Nové dráhy a1'), findsNothing);
    expect(find.text('Starší (1)'), findsOneWidget);
  });

  // „Sejmout“ = expire now: on a notice that already expired it would only
  // move its expiry later („platí do“ rewritten).
  testWidgets('„Sejmout“ is offered on an active notice only', (tester) async {
    await tester.pumpWidget(app(profile: admin, notices: [
      notice('a1'),
      notice('e1', expiresAt: DateTime(2026, 9, 15)),
    ]));
    await tester.pumpAndSettle();
    await openMenu(tester);
    expect(find.text('Sejmout'), findsOneWidget);
    await tester.tapAt(Offset.zero); // close the menu
    await tester.pumpAndSettle();
    await tester.tap(find.text('Starší (1)'));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(PopupMenuButton<String>).last);
    await tester.pumpAndSettle();
    expect(find.text('Upravit'), findsOneWidget);
    expect(find.text('Smazat'), findsOneWidget);
    expect(find.text('Sejmout'), findsNothing);
  });

  testWidgets('„Sejmout“ sends the notice as it is when confirmed, not as it '
      'was when the menu opened', (tester) async {
    final messages = StreamController<List<Message>>();
    addTearDown(() => unawaited(messages.close()));
    final sent = <(String, String)>[];
    await tester.pumpWidget(app(
      profile: admin,
      noticeStream: messages.stream,
      updateNotice: (id, {required title, required body, expiresAt}) async =>
          sent.add((title, body)),
    ));
    messages.add([notice('a1')]);
    await tester.pumpAndSettle();
    await openMenu(tester);
    await tester.tap(find.text('Sejmout'));
    await tester.pumpAndSettle();
    // Another admin's edit lands while „Sejmout oznam?“ is open.
    messages.add([notice('a1', body: 'Opravený text.')]);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Ano'));
    await tester.pumpAndSettle();
    expect(sent, [('Nové dráhy a1', 'Opravený text.')]);
  });

  // The RPC's realtime echo can beat its HTTP reply: the card moves under
  // the collapsed „Starší“ (sejmout) or disappears (smazat) first, and the
  // outcome must still be told.
  for (final (action, done) in const [
    ('Sejmout', 'Oznam sejmut.'),
    ('Smazat', 'Oznam smazán.'),
  ]) {
    testWidgets('„$action“ says „$done“ even when the echo removed the card '
        'first', (tester) async {
      final messages = StreamController<List<Message>>();
      addTearDown(() => unawaited(messages.close()));
      final reply = Completer<void>();
      final deleted = <String>[];
      await tester.pumpWidget(app(
        profile: admin,
        noticeStream: messages.stream,
        updateNotice: (id, {required title, required body, expiresAt}) =>
            reply.future,
        deleteNotice: (id) {
          deleted.add(id);
          return reply.future;
        },
      ));
      messages.add([notice('a1')]);
      await tester.pumpAndSettle();
      await openMenu(tester);
      await tester.tap(find.text(action));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Ano'));
      await tester.pump();
      messages.add(action == 'Smazat'
          ? const []
          : [notice('a1', expiresAt: DateTime(2026, 10, 1))]);
      await tester.pumpAndSettle();
      expect(find.text('Nové dráhy a1'), findsNothing);
      reply.complete();
      await tester.pumpAndSettle();
      expect(find.text(done), findsOneWidget);
      if (action == 'Smazat') expect(deleted, ['a1']);
    });
  }

  // cachedRows replays the cache (or the pre-resume state) first; the
  // notice the push was for often arrives only with the live snapshot.
  testWidgets('a notice listed after the first snapshot is marked too, once', (tester) async {
    final marked = <List<String>>[];
    final messages = StreamController<List<Message>>();
    final mine = StreamController<List<MessageRecipient>>();
    addTearDown(messages.close);
    addTearDown(mine.close);
    await tester.pumpWidget(ProviderScope(
      overrides: [
        myProfileProvider.overrideWith((ref) => Stream.value(me)),
        messagesProvider.overrideWith((ref) => messages.stream),
        myMessageRecipientsProvider.overrideWith((ref) => mine.stream),
        nowProvider.overrideWith((ref) => Stream.value(DateTime(2026, 10, 2, 12))),
      ],
      child: MaterialApp(
        home: NoticeBoardScreen(markRead: (ids) async => marked.add(ids)),
      ),
    ));
    final old = row('o1', 'me', readAt: DateTime(2026, 9, 2));
    messages.add([notice('o1')]);
    mine.add([old]);
    await tester.pumpAndSettle();
    expect(marked, isEmpty);

    messages.add([notice('o1'), notice('a1')]);
    mine.add([old, row('a1', 'me')]);
    await tester.pumpAndSettle();
    expect(find.text('Nové dráhy a1'), findsOneWidget);
    expect(marked, [['a1']]);

    // Still unread in the next snapshot (the write's echo is not back
    // yet): not sent a second time.
    mine.add([old, row('a1', 'me')]);
    await tester.pumpAndSettle();
    expect(marked, [['a1']]);
  });

  // Each seen count is its own realtime channel, and notices are never
  // pruned: opening „Starší“ must not subscribe the whole history at once.
  testWidgets('opening „Starší“ subscribes only the seen counts on screen', (tester) async {
    final subscribed = <String>{};
    final expired = [
      for (var i = 0; i < 80; i++)
        notice('e${i.toString().padLeft(2, '0')}',
            createdAt: DateTime(2026, 8, 1).add(Duration(hours: i)),
            expiresAt: DateTime(2026, 9, 15)),
    ];
    await tester.pumpWidget(ProviderScope(
      overrides: [
        myProfileProvider.overrideWith((ref) => Stream.value(admin)),
        messagesProvider.overrideWith((ref) => Stream.value(expired)),
        myMessageRecipientsProvider.overrideWith((ref) => Stream.value(const [])),
        messageParticipantsProvider.overrideWith((ref, id) {
          subscribed.add(id);
          return Stream.value([row(id, 'p1')]);
        }),
        nowProvider.overrideWith((ref) => Stream.value(DateTime(2026, 10, 2, 12))),
      ],
      child: const MaterialApp(home: NoticeBoardScreen(markRead: _noMark)),
    ));
    await tester.pumpAndSettle();
    expect(subscribed, isEmpty);
    await tester.tap(find.text('Starší (80)'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Zobrazilo 0 z 1'), findsWidgets);
    expect(subscribed.length, lessThan(20));
  });

  group('the notice form while it saves', () {
    // The form on a page of its own above home, so a stray pop shows. Home
    // watches the clock, as the board does: the form reads it once, and
    // its +14 days would otherwise count from the device's clock.
    Widget host(Future<void> Function(NoticeDraft draft) write,
            void Function(bool result) done,
            {Message? existing, DateTime? now}) =>
        ProviderScope(
          overrides: [
            nowProvider.overrideWith(
                (ref) => Stream.value(now ?? DateTime(2026, 10, 2, 12))),
          ],
          child: MaterialApp(
            // The pickers of „Naplánovat“ are the app's own, in Czech.
            supportedLocales: const [Locale('cs')],
            localizationsDelegates: GlobalMaterialLocalizations.delegates,
            home: Consumer(builder: (context, ref, _) {
              ref.watch(nowProvider);
              return Scaffold(
                body: TextButton(
                  onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(
                    builder: (context) => Scaffold(
                      body: TextButton(
                        onPressed: () async => done(await showNoticeForm(context,
                            existing: existing, write: write)),
                        child: const Text('OTEVŘÍT'),
                      ),
                    ),
                  )),
                  child: const Text('STRÁNKA'),
                ),
              );
            }),
          ),
        );

    /// Opens the form (for [existing] or a new notice, then titled „Klíč“),
    /// runs [change], saves; returns what the form handed to its write.
    Future<NoticeDraft> saved(WidgetTester tester,
        {Message? existing, DateTime? now, Future<void> Function()? change}) async {
      NoticeDraft? sent;
      await tester.pumpWidget(
          host((d) async => sent = d, (_) {}, existing: existing, now: now));
      await tester.pumpAndSettle();
      await tester.tap(find.text('STRÁNKA'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('OTEVŘÍT'));
      await tester.pumpAndSettle();
      if (existing == null) {
        await tester.enterText(find.widgetWithText(TextField, 'Nadpis'), 'Klíč');
        await tester.enterText(find.widgetWithText(TextField, 'Text'), 'Je u Petra.');
      }
      await change?.call();
      await tester.pump();
      await tester.tap(find.text('Uložit'));
      await tester.pumpAndSettle();
      return sent!;
    }

    testWidgets('a new notice expires at the end of the 14th day, and notifies',
        (tester) async {
      final draft = await saved(tester);
      expect(draft.expiresAt, DateTime(2026, 10, 16, 23, 59, 59));
      expect(draft.notify, isTrue);
    });

    testWidgets('the 14 days are calendar days, also over the clocks going back',
        (tester) async {
      // 336 hours after 12. 10. 00:30 is still 25. 10. (that day has 25
      // hours), one day short.
      final draft = await saved(tester, now: DateTime(2026, 10, 12, 0, 30));
      expect(draft.expiresAt, DateTime(2026, 10, 26, 23, 59, 59));
    });

    testWidgets('„Do odvolání“ saves no expiry; „Poslat upozornění“ off saves '
        'no notification', (tester) async {
      final draft = await saved(tester, change: () async {
        await tester.tap(find.text('Do odvolání'));
        await tester.tap(find.text('Poslat upozornění'));
      });
      expect(draft.expiresAt, isNull);
      expect(draft.notify, isFalse);
    });

    testWidgets('an edit keeps the notice\'s own expiry', (tester) async {
      final expires = DateTime(2026, 10, 20, 23, 59, 59);
      final draft = await saved(tester, existing: notice('a1', expiresAt: expires));
      expect(draft.title, 'Nové dráhy a1');
      expect(draft.expiresAt!.isAtSameMomentAs(expires), isTrue);
    });

    testWidgets('„Naplánovat“ picks a day and a time: the notice shows from '
        'then; „Změnit“ moves it; × shows it at once', (tester) async {
      final tomorrow = DateTime.now().add(const Duration(days: 1));
      final draft = await saved(tester, change: () async {
        expect(find.text('Zobrazit: hned'), findsOneWidget);
        await tester.tap(find.text('Naplánovat'));
        await tester.pumpAndSettle();
        // Tomorrow 8:00 is offered; both pickers taken as they are.
        expect(find.byType(DatePickerDialog), findsOneWidget);
        await tester.tap(find.text('OK'));
        await tester.pumpAndSettle();
        expect(find.byType(TimePickerDialog), findsOneWidget);
        await tester.tap(find.text('OK'));
        await tester.pumpAndSettle();
        expect(
          find.text('Zobrazit od: ${tomorrow.day}. ${tomorrow.month}. v 8:00'),
          findsOneWidget,
        );
        expect(find.text('Naplánovat'), findsNothing);
        expect(find.widgetWithText(TextButton, 'Změnit'), findsNWidgets(2));
      });
      expect(draft.visibleFrom, DateTime(tomorrow.year, tomorrow.month, tomorrow.day, 8));
      expect(draft.notify, isTrue);
    });

    testWidgets('a scheduled time can be cleared: shown at once again',
        (tester) async {
      final draft = await saved(tester, change: () async {
        await tester.tap(find.text('Naplánovat'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('OK'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('OK'));
        await tester.pumpAndSettle();
        expect(find.textContaining('Zobrazit od:'), findsOneWidget);
        await tester.tap(find.byTooltip('Zobrazit hned'));
        await tester.pumpAndSettle();
        expect(find.text('Zobrazit: hned'), findsOneWidget);
      });
      expect(draft.visibleFrom, isNull);
    });

    testWidgets('a picker dismissed keeps the time as it was', (tester) async {
      final draft = await saved(tester, change: () async {
        // The form has a „Zrušit“ of its own; the picker's is on top.
        await tester.tap(find.text('Naplánovat'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Zrušit').last);
        await tester.pumpAndSettle();
        expect(find.text('Zobrazit: hned'), findsOneWidget);
        // The day taken, the time not: still at once.
        await tester.tap(find.text('Naplánovat'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('OK'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Zrušit').last);
        await tester.pumpAndSettle();
        expect(find.text('Zobrazit: hned'), findsOneWidget);
      });
      expect(draft.visibleFrom, isNull);
    });

    testWidgets('an edit of a scheduled notice shows its time, local',
        (tester) async {
      final from = DateTime(2026, 10, 5, 8, 30);
      final existing = Message(
        id: 's1', kind: MessageKind.notice, audience: MessageAudience.all,
        authorId: 'admin', authorRole: MessageAuthorRole.admin, onDate: null,
        blockId: null, title: 'Brigáda', body: 'Text.', expiresAt: null,
        notify: true, visibleFrom: from.toUtc(),
        createdAt: DateTime(2026, 10, 1), updatedAt: DateTime(2026, 10, 1),
      );
      final draft = await saved(tester, existing: existing, change: () async {
        expect(find.text('Zobrazit od: 5. 10. v 8:30'), findsOneWidget);
      });
      expect(draft.visibleFrom!.isAtSameMomentAs(from), isTrue);
    });

    Future<void> openForm(WidgetTester tester) async {
      await tester.tap(find.text('STRÁNKA'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('OTEVŘÍT'));
      await tester.pumpAndSettle();
      await tester.enterText(find.widgetWithText(TextField, 'Nadpis'), 'Klíč');
      await tester.enterText(find.widgetWithText(TextField, 'Text'), 'Je u Petra.');
      await tester.tap(find.text('Uložit'));
      await tester.pump();
      expect(find.text('Ukládám…'), findsOneWidget);
    }

    testWidgets('over the limit in code points „Uložit“ is off and the counter '
        'says so, though the field counts fewer characters', (tester) async {
      await tester.pumpWidget(host((_) async {}, (_) {}));
      await tester.tap(find.text('STRÁNKA'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('OTEVŘÍT'));
      await tester.pumpAndSettle();
      FilledButton save() =>
          tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Uložit'));
      final title = find.widgetWithText(TextField, 'Nadpis');
      final body = find.widgetWithText(TextField, 'Text');
      // 👍🏽 is one character to the field, two code points to the server.
      await tester.enterText(title, '👍🏽' * 41);
      await tester.enterText(body, 'Je u Petra.');
      await tester.pump();
      expect(find.text('82/80'), findsOneWidget);
      expect(save().onPressed, isNull);
      await tester.enterText(title, '👍🏽' * 40);
      await tester.pump();
      expect(find.text('80/80'), findsOneWidget);
      expect(save().onPressed, isNotNull);
      await tester.enterText(body, '👍🏽' * 1001);
      await tester.pump();
      expect(find.text('2002/2000'), findsOneWidget);
      expect(save().onPressed, isNull);
    });

    testWidgets('the form keeps its width while a long title and text are typed',
        (tester) async {
      // Wide enough that the dialog's own cap never hides the growth.
      tester.view.physicalSize = const Size(1600, 1200);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(host((_) async {}, (_) {}));
      await tester.tap(find.text('STRÁNKA'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('OTEVŘÍT'));
      await tester.pumpAndSettle();
      // The dialog's surface — AlertDialog itself spans the inset area.
      final surface = find
          .descendant(of: find.byType(AlertDialog), matching: find.byType(Material))
          .first;
      final before = tester.getSize(surface).width;
      expect(before, lessThan(600));
      await tester.enterText(find.widgetWithText(TextField, 'Nadpis'), 'Nové dráhy ' * 7);
      await tester.enterText(find.widgetWithText(TextField, 'Text'),
          'Od pondělí hrajeme na nových drahách, klíč je u služby. ' * 4);
      await tester.pump();
      expect(tester.getSize(surface).width, before);
    });

    testWidgets('„Změnit“ opens no picker over a dialog about to close', (tester) async {
      final save = Completer<void>();
      NoticeDraft? sent;
      bool? result;
      await tester.pumpWidget(host((d) {
        sent = d;
        return save.future;
      }, (r) => result = r));
      await openForm(tester);
      await tester.tap(find.text('Změnit'), warnIfMissed: false);
      await tester.pumpAndSettle();
      expect(find.byType(DatePickerDialog), findsNothing);

      save.complete();
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(result, isTrue);
      expect(find.text('Nový oznam'), findsNothing);
      expect(find.text('OTEVŘÍT'), findsOneWidget);
      expect(sent?.title, 'Klíč');
      expect(sent?.notify, isTrue);
    });

    testWidgets('„Zrušit“ mid-save: the late result pops nothing else', (tester) async {
      final save = Completer<void>();
      bool? result;
      await tester.pumpWidget(host((_) => save.future, (r) => result = r));
      await openForm(tester);
      await tester.tap(find.text('Zrušit'));
      // The save returns while the dialog is still animating out.
      await tester.pump(const Duration(milliseconds: 20));
      save.complete();
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(result, isFalse);
      expect(find.text('OTEVŘÍT'), findsOneWidget);
    });
  });
}

Future<void> _noMark(List<String> ids) async {}
