import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:rezervator/data/clock.dart';
import 'package:rezervator/data/providers.dart';
import 'package:rezervator/domain/duties.dart' show MyDuty;
import 'package:rezervator/domain/models.dart';
import 'package:rezervator/features/clubhouse/message_detail_screen.dart';
import 'package:rezervator/features/clubhouse/messages_screen.dart';
import 'package:rezervator/features/clubhouse/widgets/message_tile.dart';

/// Klubovna → Zprávy (0051): the tile's received and sent sides, the list
/// (read marking, „Starší (N)“, failed reactions) and the detail screen.
void main() {
  const me = Profile(
    id: 'me', displayName: 'Já Hráč', email: 'me@example.com',
    role: Role.player, status: ProfileStatus.approved,
  );

  Message received({
    String id = 'm1',
    MessageAudience audience = MessageAudience.block,
    String authorId = 'staff',
  }) =>
      Message(
        id: id, kind: MessageKind.message, audience: audience,
        authorId: authorId, authorRole: MessageAuthorRole.player,
        onDate: Day(2026, 10, 2), blockId: 'b1',
        title: null, body: 'Přijďte dřív.', expiresAt: null, notify: true,
        createdAt: DateTime(2026, 10, 1), updatedAt: DateTime(2026, 10, 1),
      );

  MessageRecipient recip(String userId, {Reaction? reaction, String? reply}) =>
      MessageRecipient(
        messageId: 'm1', userId: userId, readAt: null,
        reaction: reaction, reply: reply, reactedAt: null,
      );

  group('MessageTile', () {
    testWidgets('a received message shows the reaction chips and reply field', (tester) async {
      var reacted = false;
      var replied = false;
      await tester.pumpWidget(MaterialApp(home: Scaffold(body: MessageTile(
        message: received(),
        recipients: [recip('me'), recip('p2', reaction: Reaction.up)],
        names: const {'p2': 'Petr Novák'},
        meId: 'me',
        authorName: 'Bára Kantýnská',
        authorIsAdmin: false,
        block: null,
        onReact: (r) { reacted = true; },
        onReply: (r) { replied = true; },
        onDelete: null,
      ))));
      expect(find.text('Od služby (Bára Kantýnská)'), findsOneWidget);
      expect(find.byIcon(Icons.thumb_up_outlined), findsOneWidget);
      expect(find.byIcon(Icons.thumb_down_outlined), findsOneWidget);
      await tester.tap(find.byIcon(Icons.thumb_up_outlined));
      expect(reacted, true);
      await tester.enterText(find.byType(TextField), 'Přijdu.');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      expect(replied, true);
      // The line reads „👍 Petr Novák · 1 bez reakce“ (me, unreacted).
      expect(find.textContaining('👍 Petr Novák'), findsOneWidget);
    });

    testWidgets('a sent message shows the tally, not chips', (tester) async {
      await tester.pumpWidget(MaterialApp(home: Scaffold(body: MessageTile(
        message: received(authorId: 'me'),
        recipients: [recip('p1', reaction: Reaction.up), recip('p2', reaction: Reaction.down)],
        names: const {'p1': 'Petr', 'p2': 'Tomáš'},
        meId: 'me',
        authorName: 'Já Hráč',
        authorIsAdmin: false,
        block: null,
        onReact: null,
        onReply: null,
        onDelete: () {},
      ))));
      expect(find.text('Ode mě hráčům'), findsOneWidget);
      expect(find.text('1× 👍 · 1× 👎'), findsOneWidget);
      expect(find.byType(TextField), findsNothing);
    });
  });

  // [recipients] feeds both recipient streams the way RLS splits them: my
  // own rows, and every row of one message (its author's and recipients'
  // view).
  List<Override> overrides({
    Profile profile = me,
    List<Message> messages = const [],
    Stream<List<Message>>? messageStream,
    List<MessageRecipient> recipients = const [],
    List<PlayerName> roster = const [],
  }) =>
      [
        myProfileProvider.overrideWith((ref) => Stream.value(profile)),
        messagesProvider.overrideWith((ref) => messageStream ?? Stream.value(messages)),
        myMessageRecipientsProvider.overrideWith((ref) => Stream.value(
            [for (final r in recipients) if (r.userId == profile.id) r])),
        messageParticipantsProvider.overrideWith((ref, id) => Stream.value(
            [for (final r in recipients) if (r.messageId == id) r])),
        playersProvider.overrideWith((ref) async => roster),
        timeBlocksProvider.overrideWith((ref) => Stream.value(const [])),
        nowProvider.overrideWith((ref) => Stream.value(DateTime(2026, 10, 2, 12))),
        myDutyProvider.overrideWithValue(MyDuty.none),
      ];

  // The screen's writes are injected (no Supabase in widget tests); the
  // defaults record nothing and succeed.
  Widget app({
    Profile profile = me,
    List<Message> messages = const [],
    List<MessageRecipient> recipients = const [],
    List<PlayerName> roster = const [],
    Future<void> Function(List<String> ids)? markRead,
    Future<void> Function(String id, Reaction? r)? react,
    Future<void> Function(String id, String text)? reply,
  }) =>
      ProviderScope(
        overrides: overrides(
            profile: profile, messages: messages, recipients: recipients, roster: roster),
        child: MaterialApp(
          home: MessagesScreen(
            markRead: markRead ?? (_) async {},
            react: react ?? (_, _) async {},
            reply: reply ?? (_, _) async {},
          ),
        ),
      );

  group('MessagesScreen', () {
    testWidgets('empty state', (tester) async {
      await tester.pumpWidget(app());
      await tester.pumpAndSettle();
      expect(find.text('Zatím žádné zprávy.'), findsOneWidget);
    });

    testWidgets('opening marks read only my unread received rows', (tester) async {
      final marked = <List<String>>[];
      await tester.pumpWidget(app(
        messages: [received(id: 'a'), received(id: 'b'), received(id: 'mine', authorId: 'me')],
        recipients: [
          MessageRecipient(messageId: 'a', userId: 'me', readAt: null,
              reaction: null, reply: null, reactedAt: null),
          MessageRecipient(messageId: 'b', userId: 'me', readAt: DateTime(2026, 10, 1),
              reaction: null, reply: null, reactedAt: null),
        ],
        markRead: (ids) async => marked.add(ids),
      ));
      await tester.pumpAndSettle();
      expect(marked, [['a']]);
    });

    testWidgets('a failed reaction shows a snack and keeps the chip outlined', (tester) async {
      await tester.pumpWidget(app(
        messages: [received()],
        recipients: [recip('me')],
        roster: const [PlayerName(id: 'staff', displayName: 'Bára')],
        react: (_, _) async => throw Exception('offline'),
      ));
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.thumb_up_outlined));
      await tester.pumpAndSettle();
      expect(find.byType(SnackBar), findsOneWidget);
      expect(find.byIcon(Icons.thumb_up_outlined), findsOneWidget);
    });

    testWidgets('a sent message expands its tally into names on tap', (tester) async {
      await tester.pumpWidget(app(
        messages: [received(id: 'mine', authorId: 'me')],
        recipients: [
          MessageRecipient(messageId: 'mine', userId: 'p1', readAt: null,
              reaction: Reaction.up, reply: null, reactedAt: null),
          MessageRecipient(messageId: 'mine', userId: 'p2', readAt: null,
              reaction: null, reply: null, reactedAt: null),
        ],
        roster: const [PlayerName(id: 'p1', displayName: 'Petr'), PlayerName(id: 'p2', displayName: 'Tomáš'),
            PlayerName(id: 'me', displayName: 'Já Hráč')],
      ));
      await tester.pumpAndSettle();
      expect(find.text('1× 👍 · 1 bez reakce'), findsOneWidget);
      expect(find.text('👍 Petr · 1 bez reakce'), findsNothing);
      await tester.tap(find.text('1× 👍 · 1 bez reakce'));
      await tester.pumpAndSettle();
      expect(find.text('👍 Petr · 1 bez reakce'), findsOneWidget);
    });

    testWidgets('today+ahead open, older collapsed', (tester) async {
      final soon = received(id: 'soon');
      final past = Message(
        id: 'past', kind: MessageKind.message, audience: MessageAudience.block,
        authorId: 'staff', authorRole: MessageAuthorRole.player,
        onDate: Day(2026, 9, 20), blockId: 'b1',
        title: null, body: 'Starší zpráva.', expiresAt: null, notify: true,
        createdAt: DateTime(2026, 9, 20), updatedAt: DateTime(2026, 9, 20),
      );
      await tester.pumpWidget(app(
        messages: [soon, past],
        recipients: [recip('me'), MessageRecipient(
            messageId: 'past', userId: 'me', readAt: null,
            reaction: null, reply: null, reactedAt: null)],
      ));
      await tester.pumpAndSettle();
      expect(find.text('Přijďte dřív.'), findsOneWidget);
      expect(find.text('Starší zpráva.'), findsNothing);
      expect(find.text('Starší (1)'), findsOneWidget);
    });
  });

  group('MessageDetailScreen', () {
    testWidgets('shows a spinner before the first snapshot, then the message', (tester) async {
      await tester.pumpWidget(ProviderScope(
        overrides: overrides(messages: [received()], recipients: [recip('me')]),
        child: MaterialApp(home: MessageDetailScreen('m1',
            react: (_, _) async {}, reply: (_, _) async {})),
      ));
      // The first frame, before Stream.value has delivered anything: any
      // pump() would already let every snapshot in.
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      await tester.pumpAndSettle();
      expect(find.text('Přijďte dřív.'), findsOneWidget);
    });

    testWidgets('an id absent from the data pops once, with a snack', (tester) async {
      await tester.pumpWidget(ProviderScope(
        overrides: overrides(),
        child: MaterialApp(home: Scaffold(body: Builder(builder: (context) => TextButton(
          onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(
              builder: (_) => MessageDetailScreen('missing',
                  react: (_, _) async {}, reply: (_, _) async {}))),
          child: const Text('open'),
        )))),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.text('Zpráva už neexistuje.'), findsOneWidget);
      expect(find.text('open'), findsOneWidget); // back on the caller
      expect(find.byType(MessageDetailScreen), findsNothing);
    });

    testWidgets('a stale first snapshot (the cache replay) is not taken for "gone"',
        (tester) async {
      // cachedRows replays the cache first; the message a push was sent
      // for is usually newer than it and arrives with the live snapshot.
      final messages = StreamController<List<Message>>();
      addTearDown(messages.close);
      await tester.pumpWidget(ProviderScope(
        overrides: overrides(messageStream: messages.stream, recipients: [recip('me')]),
        child: MaterialApp(home: MessageDetailScreen('m1',
            react: (_, _) async {}, reply: (_, _) async {})),
      ));
      messages.add(const []);
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      messages.add([received()]);
      await tester.pumpAndSettle();
      expect(find.text('Přijďte dřív.'), findsOneWidget);
      expect(find.text('Zpráva už neexistuje.'), findsNothing);
    });
  });
}
