import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rezervator/data/clock.dart';
import 'package:rezervator/data/providers.dart';
import 'package:rezervator/domain/models.dart';
import 'package:rezervator/features/clubhouse/notice_board_screen.dart';

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
  }) =>
      ProviderScope(
        overrides: [
          myProfileProvider.overrideWith((ref) => Stream.value(profile)),
          messagesProvider.overrideWith((ref) => Stream.value(notices)),
          myMessageRecipientsProvider.overrideWith((ref) => Stream.value(
              [for (final r in recipients) if (r.userId == profile.id) r])),
          messageParticipantsProvider.overrideWith((ref, id) => Stream.value(
              [for (final r in recipients) if (r.messageId == id) r])),
          playersProvider.overrideWith((ref) async => roster),
          nowProvider.overrideWith((ref) => Stream.value(DateTime(2026, 10, 2, 12))),
        ],
        child: MaterialApp(
          home: NoticeBoardScreen(markRead: markRead ?? (_) async {}),
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

  testWidgets('„Kdo si to zobrazil“ lists who has not opened it', (tester) async {
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
    expect(find.text('Ještě nezobrazili:'), findsOneWidget);
    expect(find.text('Tomáš'), findsOneWidget);
    expect(find.text('Petr'), findsNothing);
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
}
