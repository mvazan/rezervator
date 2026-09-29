import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' show Tristate;

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart' show SemanticsData;
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:rezervator/core/theme.dart' show appFontFamily, buildTheme;
import 'package:rezervator/data/clock.dart';
import 'package:rezervator/data/providers.dart';
import 'package:rezervator/domain/duties.dart' show MyDuty;
import 'package:rezervator/domain/models.dart';
import 'package:rezervator/features/clubhouse/message_detail_screen.dart';
import 'package:rezervator/features/clubhouse/messages_screen.dart';
import 'package:rezervator/features/clubhouse/widgets/message_composers.dart'
    show MessageSend;
import 'package:rezervator/features/clubhouse/widgets/message_tile.dart';

/// Klubovna → Zprávy (0051): the tile's received and sent sides, the list
/// (read marking, „Starší (N)“, failed reactions) and the detail screen.
/// The app's own font, for the FAB layout tests (see
/// venue_slug_field_test.dart).
Future<void> _loadManrope() async {
  final loader = FontLoader(appFontFamily);
  for (final weight in ['Regular', 'Medium', 'Bold', 'ExtraBold']) {
    final bytes = File('assets/fonts/Manrope-$weight.ttf').readAsBytesSync();
    loader.addFont(Future.value(ByteData.view(bytes.buffer)));
  }
  await loader.load();
}

/// The composers' RPC for a test that does not look: succeeds, no Supabase.
Future<String> _sendNothing({
  required MessageKind kind,
  required MessageAudience audience,
  Day? onDate,
  String? blockId,
  String? title,
  required String body,
  DateTime? expiresAt,
  bool notify = true,
}) async => 'new-id';

/// The semantics node of [finder] as data: label and flags.
SemanticsData semanticsData(WidgetTester tester, Finder finder) =>
    tester.getSemantics(finder).getSemanticsData();

void main() {
  setUpAll(_loadManrope);

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
    // Spec: two toggle chips 👍 / 👎 — named and with a selected state a
    // screen reader can tell apart; tapping my current one clears it.
    testWidgets('a received message: the chips send their reaction, my current '
        'one clears, the reply goes out as typed', (tester) async {
      final reactions = <Reaction?>[];
      final replies = <String>[];
      Widget tile(Reaction? mine) => MaterialApp(home: Scaffold(body: MessageTile(
        message: received(),
        recipients: [recip('me', reaction: mine), recip('p2', reaction: Reaction.up)],
        names: const {'p2': 'Petr Novák'},
        meId: 'me',
        authorName: 'Bára Kantýnská',
        authorIsAdmin: false,
        block: null,
        onReact: reactions.add,
        onReply: (text) async {
          replies.add(text);
          return true;
        },
        onDelete: null,
      )));
      final up = find.widgetWithText(FilterChip, '👍');
      final down = find.widgetWithText(FilterChip, '👎');
      await tester.pumpWidget(tile(null));
      expect(find.text('Od služby (Bára Kantýnská)'), findsOneWidget);
      // Read off the node's data: containsSemantics is deprecated on the
      // newer Flutter CI runs, and its replacement (isSemantics) is missing
      // on 3.38.
      final upData = semanticsData(tester, up);
      expect(upData.label, '👍');
      expect(upData.flagsCollection.isButton, isTrue);
      expect(upData.flagsCollection.isSelected, Tristate.isFalse);
      final downData = semanticsData(tester, down);
      expect(downData.label, '👎');
      expect(downData.flagsCollection.isButton, isTrue);
      expect(downData.flagsCollection.isSelected, Tristate.isFalse);
      await tester.tap(up);
      await tester.tap(down);
      expect(reactions, [Reaction.up, Reaction.down]);

      await tester.pumpWidget(tile(Reaction.up));
      expect(tester.widget<FilterChip>(up).selected, isTrue);
      expect(semanticsData(tester, up).flagsCollection.isSelected, Tristate.isTrue);
      await tester.tap(up);
      expect(reactions, [Reaction.up, Reaction.down, null]);

      await tester.enterText(find.byType(TextField), 'Přijdu.');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      expect(replies, ['Přijdu.']);
      // The line reads „👍 Petr Novák, ty · …“ (me, now 👍 too).
      expect(find.textContaining('👍 Petr Novák'), findsOneWidget);
    });

    // A cached snapshot may be older than my reply from another device;
    // the field must not keep (and resend) the stale text.
    testWidgets('the reply field follows my row when it changes, unless I am '
        'typing', (tester) async {
      Widget tile(String? reply) => MaterialApp(home: Scaffold(body: MessageTile(
        message: received(),
        recipients: [recip('me', reply: reply)],
        names: const {},
        meId: 'me',
        authorName: 'Bára Kantýnská',
        authorIsAdmin: false,
        block: null,
        onReact: (_) {},
        onReply: (_) async => true,
        onDelete: null,
      )));
      String field() =>
          tester.widget<TextField>(find.byType(TextField)).controller!.text;
      await tester.pumpWidget(tile('Stará'));
      expect(field(), 'Stará');
      await tester.pumpWidget(tile('Nová'));
      expect(field(), 'Nová');
      await tester.enterText(find.byType(TextField), 'Rozepsané');
      await tester.pumpWidget(tile('Z webu'));
      expect(field(), 'Rozepsané');
    });

    testWidgets('a reply from elsewhere that came while the field was focused '
        'but empty of my typing shows once I leave it', (tester) async {
      Widget tile(String? reply) => MaterialApp(home: Scaffold(body: MessageTile(
        message: received(),
        recipients: [recip('me', reply: reply)],
        names: const {},
        meId: 'me',
        authorName: 'Bára Kantýnská',
        authorIsAdmin: false,
        block: null,
        onReact: (_) {},
        onReply: (_) async => true,
        onDelete: null,
      )));
      String field() =>
          tester.widget<TextField>(find.byType(TextField)).controller!.text;
      await tester.pumpWidget(tile(null));
      await tester.tap(find.byType(TextField));
      await tester.pump();
      await tester.pumpWidget(tile('Z webu'));
      expect(field(), '', reason: 'a focused field is left alone');
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pump();
      expect(field(), 'Z webu');
    });

    // My own reply write, as LiveMessageTile hands it in: the answer says
    // whether it went through. Each submit waits on its own answer, and
    // the test plays my row's changes (the optimistic patch, a rollback,
    // a change from another device) in the order they reach the tile.
    group('the reply field and my own writes', () {
      late List<Completer<bool>> answers;
      late List<String> sent;
      setUp(() {
        answers = [];
        sent = [];
      });
      MessageTile message(String? reply) => MessageTile(
        message: received(),
        recipients: [recip('me', reply: reply)],
        names: const {},
        meId: 'me',
        authorName: 'Bára Kantýnská',
        authorIsAdmin: false,
        block: null,
        onReact: (_) {},
        onReply: (text) {
          sent.add(text);
          final answer = Completer<bool>();
          answers.add(answer);
          return answer.future;
        },
        onDelete: null,
      );
      Widget tile(String? reply) =>
          MaterialApp(home: Scaffold(body: message(reply)));
      String field(WidgetTester tester) =>
          tester.widget<TextField>(find.byType(TextField)).controller!.text;
      bool focused(WidgetTester tester) =>
          tester.widget<TextField>(find.byType(TextField)).focusNode!.hasFocus;
      Future<void> submit(WidgetTester tester, String text) async {
        await tester.enterText(find.byType(TextField), text);
        await tester.testTextInput.receiveAction(TextInputAction.done);
        await tester.pump();
        expect(focused(tester), isFalse); // „done“ leaves the field
      }

      // The tile first in a list, a spacer after it: jumping to 4000 and
      // back takes it past the cache extent, so only a keep-alive keeps it.
      Widget listed(ScrollController scroll, String? reply) =>
          MaterialApp(home: Scaffold(
            body: ListView(controller: scroll, children: [
              message(reply),
              const SizedBox(height: 5000),
            ]),
          ));
      Future<void> awayAndBack(
          WidgetTester tester, ScrollController scroll) async {
        scroll.jumpTo(4000);
        await tester.pump();
        scroll.jumpTo(0);
        await tester.pump();
      }

      testWidgets('a failed write keeps what I typed, also when its rollback '
          'reaches the tile after the failure', (tester) async {
        await tester.pumpWidget(tile(null));
        await submit(tester, 'Nestihnu.');
        await tester.pumpWidget(tile('Nestihnu.')); // the optimistic patch
        answers.single.complete(false);
        await tester.pump();
        await tester.pumpWidget(tile(null)); // the rollback, a frame later
        expect(field(tester), 'Nestihnu.');
      });

      testWidgets('once my write went through the field follows my row '
          'again: a reply cleared elsewhere clears it', (tester) async {
        await tester.pumpWidget(tile(null));
        await submit(tester, 'Přijdu. ');
        await tester.pumpWidget(tile('Přijdu.'));
        answers.single.complete(true);
        await tester.pump();
        expect(field(tester), 'Přijdu.'); // what was saved
        await tester.pumpWidget(tile(null)); // cleared on another device
        expect(field(tester), '');
        await tester.pumpWidget(tile('Z webu'));
        expect(field(tester), 'Z webu');
      });

      testWidgets('a focused field is never overwritten: not by my write '
          'going through, not by my row', (tester) async {
        await tester.pumpWidget(tile(null));
        await submit(tester, 'Přijdu. ');
        await tester.pumpWidget(tile('Přijdu.'));
        await tester.tap(find.byType(TextField)); // back in the field
        await tester.pump();
        expect(focused(tester), isTrue);
        answers.single.complete(true);
        await tester.pump();
        expect(field(tester), 'Přijdu. ');
        await tester.pumpWidget(tile('Z webu'));
        expect(field(tester), 'Přijdu. ');
        // Left again, the field holds no draft (only whitespace differs
        // from what was saved): the next change is followed.
        FocusManager.instance.primaryFocus?.unfocus();
        await tester.pump();
        await tester.pumpWidget(tile('Znovu'));
        expect(field(tester), 'Znovu');
      });

      testWidgets('two overlapping writes that both fail keep the latest '
          'text I typed', (tester) async {
        await tester.pumpWidget(tile(null));
        await submit(tester, 'Přijdu.');
        await tester.pumpWidget(tile('Přijdu.'));
        await submit(tester, 'Nestihnu.');
        await tester.pumpWidget(tile('Nestihnu.'));
        answers[0].complete(false);
        await tester.pump();
        await tester.pumpWidget(tile('Nestihnu.')); // only its patch is gone
        answers[1].complete(false);
        await tester.pump();
        await tester.pumpWidget(tile(null)); // the second rolled back too
        expect(field(tester), 'Nestihnu.');
        expect(sent, ['Přijdu.', 'Nestihnu.']);
      });

      // 'Přijdu. ' trims to the reply already saved (its optimistic patch
      // changes nothing), so the field holds no draft: only my write being
      // out keeps the change elsewhere from replacing it.
      testWidgets('a change elsewhere is not followed while my write is out',
          (tester) async {
        await tester.pumpWidget(tile('Přijdu.'));
        await submit(tester, 'Přijdu. ');
        await tester.pumpWidget(tile('Z webu')); // mine has not answered
        expect(field(tester), 'Přijdu. ');
        answers.single.complete(true);
        await tester.pump();
        expect(field(tester), 'Přijdu.'); // what was saved
        await tester.pumpWidget(tile(null)); // cleared, nothing of mine out
        expect(field(tester), '');
      });

      // A list drops a tile scrolled past its cache extent, and after
      // „done“ the field no longer holds it: the tile keeps itself while
      // my write is out or it holds a draft — and lets go after.
      testWidgets('scrolled away and back, the tile keeps my write out and '
          'a failed reply', (tester) async {
        final scroll = ScrollController();
        addTearDown(scroll.dispose);
        await tester.pumpWidget(listed(scroll, null));
        await submit(tester, 'Nestihnu.');
        await tester.pumpWidget(listed(scroll, 'Nestihnu.')); // optimistic
        await awayAndBack(tester, scroll); // while mine is out
        answers.single.complete(false);
        await tester.pump();
        await tester.pumpWidget(listed(scroll, null)); // the rollback
        expect(field(tester), 'Nestihnu.');
        await awayAndBack(tester, scroll); // nothing out, the reply kept
        expect(field(tester), 'Nestihnu.');

        await submit(tester, 'Nestihnu.'); // another try goes through
        await tester.pumpWidget(listed(scroll, 'Nestihnu.'));
        answers.last.complete(true);
        await tester.pump();
        scroll.jumpTo(4000);
        await tester.pump();
        expect(find.byType(MessageTile, skipOffstage: false), findsNothing);
      });

      // What the field holds after my latest write failed is kept as such,
      // not inferred from its text: here it equals the reply the field
      // started from, while the server holds the earlier write's.
      testWidgets('the latest write failed, an earlier one went through: '
          'the field keeps the latest', (tester) async {
        await tester.pumpWidget(tile('Přijdu.'));
        await submit(tester, 'Nestihnu.');
        await tester.pumpWidget(tile('Nestihnu.'));
        await submit(tester, 'Přijdu.');
        await tester.pumpWidget(tile('Přijdu.'));
        answers[0].complete(true);
        await tester.pump();
        answers[1].complete(false);
        await tester.pump();
        await tester.pumpWidget(tile('Nestihnu.')); // the first one stays
        expect(field(tester), 'Přijdu.');
        // Edited to what went through and left, it is no draft any more:
        // a change elsewhere is followed again.
        await tester.enterText(find.byType(TextField), 'Nestihnu.');
        FocusManager.instance.primaryFocus?.unfocus();
        await tester.pump();
        await tester.pumpWidget(tile('Z webu'));
        expect(field(tester), 'Z webu');
      });

      testWidgets('a clear that failed after an earlier write went through '
          'stays cleared', (tester) async {
        await tester.pumpWidget(tile(null));
        await submit(tester, 'Nestihnu.');
        await tester.pumpWidget(tile('Nestihnu.'));
        await submit(tester, '');
        await tester.pumpWidget(tile(null));
        answers[0].complete(true);
        await tester.pump();
        answers[1].complete(false);
        await tester.pump();
        await tester.pumpWidget(tile('Nestihnu.')); // the clear rolled back
        expect(field(tester), '');
        expect(sent, ['Nestihnu.', '']);
      });

      // Focused, the field did not take the change from another device, so
      // it still shows (and „done“ sends) the reply it took before.
      testWidgets('a reply sent from a field that skipped a change elsewhere '
          'stays when it fails', (tester) async {
        await tester.pumpWidget(tile('Přijdu.'));
        await tester.tap(find.byType(TextField));
        await tester.pump();
        await tester.pumpWidget(tile('Z webu')); // skipped: I am in the field
        expect(field(tester), 'Přijdu.');
        await tester.testTextInput.receiveAction(TextInputAction.done);
        await tester.pump();
        expect(sent, ['Přijdu.']);
        await tester.pumpWidget(tile('Přijdu.')); // the optimistic patch
        answers.single.complete(false);
        await tester.pump();
        await tester.pumpWidget(tile('Z webu')); // the rollback
        expect(field(tester), 'Přijdu.');
      });

      testWidgets('the latest write failed first, the earlier one went '
          'through after: scrolled away and back, the field keeps the latest',
          (tester) async {
        final scroll = ScrollController();
        addTearDown(scroll.dispose);
        await tester.pumpWidget(listed(scroll, 'Přijdu.'));
        await submit(tester, 'Nestihnu.');
        await tester.pumpWidget(listed(scroll, 'Nestihnu.'));
        await submit(tester, 'Přijdu.');
        await tester.pumpWidget(listed(scroll, 'Přijdu.'));
        answers[1].complete(false);
        await tester.pump();
        await tester.pumpWidget(listed(scroll, 'Nestihnu.')); // its rollback
        expect(field(tester), 'Přijdu.');
        answers[0].complete(true);
        await tester.pump();
        await tester.pumpWidget(listed(scroll, 'Nestihnu.')); // the echo
        expect(field(tester), 'Přijdu.');
        await awayAndBack(tester, scroll); // nothing out, the reply kept
        expect(field(tester), 'Přijdu.');
      });

      // A write that went through is what the server holds, in the order
      // sent, though not the latest: a draft is what differs from it.
      testWidgets('a reply I cleared while my writes were out stays cleared '
          'once the earlier one went through', (tester) async {
        await tester.pumpWidget(tile(null));
        await submit(tester, 'Přijdu.');
        await tester.pumpWidget(tile('Přijdu.'));
        await submit(tester, 'Nestihnu.');
        await tester.pumpWidget(tile('Nestihnu.'));
        answers[0].complete(true);
        await tester.pump();
        await tester.enterText(find.byType(TextField), ''); // not sent
        FocusManager.instance.primaryFocus?.unfocus();
        await tester.pump();
        answers[1].complete(false);
        await tester.pump();
        await tester.pumpWidget(tile('Přijdu.')); // the latest rolled back
        expect(field(tester), '');
      });
    });

    testWidgets('a reply over 200 code points is not sent and the counter says so',
        (tester) async {
      final replies = <String>[];
      await tester.pumpWidget(MaterialApp(home: Scaffold(body: MessageTile(
        message: received(),
        recipients: [recip('me')],
        names: const {},
        meId: 'me',
        authorName: 'Bára Kantýnská',
        authorIsAdmin: false,
        block: null,
        onReact: (_) {},
        onReply: (text) async {
          replies.add(text);
          return true;
        },
        onDelete: null,
      ))));
      // 101 characters to the field, 202 code points to the server.
      await tester.enterText(find.byType(TextField), '👍🏽' * 101);
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      expect(replies, isEmpty);
      expect(find.text('202/200'), findsOneWidget);
      await tester.enterText(find.byType(TextField), '👍🏽' * 100);
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      expect(replies, ['👍🏽' * 100]);
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
      expect(find.byType(FilterChip), findsNothing);
    });

    testWidgets('the sent tally is a button of full tap height that says '
        'whether its list is open', (tester) async {
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
      final tally = find.text('1× 👍 · 1× 👎');
      final collapsed = semanticsData(tester, tally).flagsCollection;
      expect(collapsed.isButton, isTrue);
      expect(collapsed.isExpanded, Tristate.isFalse); // has an expanded state, and is collapsed
      final target = find.ancestor(of: tally, matching: find.byType(InkWell));
      expect(tester.getSize(target).height,
          greaterThanOrEqualTo(kMinInteractiveDimension));
      await tester.tap(tally);
      await tester.pump();
      expect(semanticsData(tester, tally).flagsCollection.isExpanded, Tristate.isTrue);
      expect(find.text('👍 Petr · 👎 Tomáš'), findsOneWidget);
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
    Stream<List<MessageRecipient>>? myRowStream,
    List<PlayerName> roster = const [],
    MyDuty duty = MyDuty.none,
    List<Reservation> reservations = const [],
  }) =>
      [
        myProfileProvider.overrideWith((ref) => Stream.value(profile)),
        messagesProvider.overrideWith((ref) => messageStream ?? Stream.value(messages)),
        myMessageRecipientsProvider.overrideWith((ref) => myRowStream ?? Stream.value(
            [for (final r in recipients) if (r.userId == profile.id) r])),
        messageParticipantsProvider.overrideWith((ref, id) => Stream.value(
            [for (final r in recipients) if (r.messageId == id) r])),
        playersProvider.overrideWith((ref) async => roster),
        timeBlocksProvider.overrideWith((ref) => Stream.value(const [])),
        nowProvider.overrideWith((ref) => Stream.value(DateTime(2026, 10, 2, 12))),
        myDutyProvider.overrideWithValue(duty),
        // What the staff composer's sheet watches (its week and preview).
        settingsProvider.overrideWith((ref) => Stream.value(ScheduleSettings.defaults)),
        dayOverridesProvider.overrideWith((ref) => Stream.value(const [])),
        prioritySlotsProvider.overrideWithValue(const []),
        rentalsProvider.overrideWith((ref) => Stream.value(const [])),
        weekReservationsProvider.overrideWith((ref, monday) => Stream.value(reservations)),
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
    MyDuty duty = MyDuty.none,
    ThemeData? theme,
    TextScaler? textScaler,
    MessageSend? send,
    List<Reservation> reservations = const [],
    Stream<List<Message>>? messageStream,
    Stream<List<MessageRecipient>>? myRowStream,
    Future<void> Function(String id)? delete,
  }) =>
      ProviderScope(
        overrides: overrides(profile: profile, messages: messages,
            messageStream: messageStream, myRowStream: myRowStream,
            recipients: recipients, roster: roster, duty: duty,
            reservations: reservations),
        child: MaterialApp(
          theme: theme,
          builder: textScaler == null
              ? null
              : (context, child) => MediaQuery(
                  data: MediaQuery.of(context).copyWith(textScaler: textScaler),
                  child: child!,
                ),
          home: MessagesScreen(
            markRead: markRead ?? (_) async {},
            react: react ?? (_, _) async {},
            reply: reply ?? (_, _) async {},
            send: send ?? _sendNothing,
            delete: delete ?? (_) async {},
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
      await tester.tap(find.widgetWithText(FilterChip, '👍'));
      await tester.pumpAndSettle();
      expect(find.byType(SnackBar), findsOneWidget);
      expect(tester.widget<FilterChip>(find.widgetWithText(FilterChip, '👍')).selected,
          isFalse);
    });

    testWidgets('a reaction and a reply go out for the message they belong to',
        (tester) async {
      final reactions = <(String, Reaction?)>[];
      final replies = <(String, String)>[];
      await tester.pumpWidget(app(
        messages: [received()],
        recipients: [recip('me')],
        roster: const [PlayerName(id: 'staff', displayName: 'Bára')],
        react: (id, r) async => reactions.add((id, r)),
        reply: (id, text) async => replies.add((id, text)),
      ));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilterChip, '👎'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'Nestihnu.');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(reactions, [('m1', Reaction.down)]);
      expect(replies, [('m1', 'Nestihnu.')]);
    });

    // optimisticWrite shows my reply at once and, when the write fails,
    // rolls my row back: that rollback is not a new reply to follow — the
    // field keeps what I typed, for another try after the snack.
    testWidgets('a failed reply keeps what I typed in the field and says why',
        (tester) async {
      final myRows = StreamController<List<MessageRecipient>>()
        ..add([recip('me')]);
      addTearDown(myRows.close);
      final gate = Completer<void>();
      await tester.pumpWidget(app(
        messages: [received()],
        myRowStream: myRows.stream,
        roster: const [PlayerName(id: 'staff', displayName: 'Bára')],
        reply: (id, text) async {
          myRows.add([recip('me', reply: text)]); // the optimistic patch
          await gate.future;
          myRows.add([recip('me')]); // the rollback
          throw Exception('offline');
        },
      ));
      await tester.pumpAndSettle();
      String field() =>
          tester.widget<TextField>(find.byType(TextField)).controller!.text;
      await tester.enterText(find.byType(TextField), 'Nestihnu.');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      expect(field(), 'Nestihnu.');
      gate.complete();
      await tester.pumpAndSettle();
      expect(find.byType(SnackBar), findsOneWidget);
      expect(field(), 'Nestihnu.');
    });

    // The tile hears that the write went through (tryAction's true): a
    // reply cleared on another device afterwards is followed, not taken
    // for the rollback of mine.
    testWidgets('after a reply went through, clearing it elsewhere clears the '
        'field', (tester) async {
      final myRows = StreamController<List<MessageRecipient>>()
        ..add([recip('me')]);
      addTearDown(myRows.close);
      await tester.pumpWidget(app(
        messages: [received()],
        myRowStream: myRows.stream,
        roster: const [PlayerName(id: 'staff', displayName: 'Bára')],
        reply: (id, text) async =>
            myRows.add([recip('me', reply: text)]), // the optimistic patch
      ));
      await tester.pumpAndSettle();
      String field() =>
          tester.widget<TextField>(find.byType(TextField)).controller!.text;
      await tester.enterText(find.byType(TextField), 'Nestihnu.');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(find.byType(SnackBar), findsNothing);
      myRows.add([recip('me')]); // cleared on another device
      await tester.pumpAndSettle();
      expect(field(), '');
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
      expect(find.text('👍 Petr · bez reakce: Tomáš'), findsNothing);
      await tester.tap(find.text('1× 👍 · 1 bez reakce'));
      await tester.pumpAndSettle();
      expect(find.text('👍 Petr · bez reakce: Tomáš'), findsOneWidget);
    });

    // The RPC's realtime DELETE can beat its HTTP reply and unmount the
    // tile first; the outcome must still be told.
    testWidgets('deleting a sent message says „Zpráva smazána.“ even when the '
        'echo removed the tile first', (tester) async {
      final messages = StreamController<List<Message>>();
      addTearDown(() => unawaited(messages.close()));
      final answer = Completer<void>();
      final deleted = <String>[];
      await tester.pumpWidget(app(
        messageStream: messages.stream,
        delete: (id) {
          deleted.add(id);
          return answer.future;
        },
      ));
      messages.add([received(id: 'mine', authorId: 'me')]);
      await tester.pumpAndSettle();
      await tester.tap(find.byType(PopupMenuButton<String>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Smazat'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Ano'));
      await tester.pump();
      messages.add(const []);
      await tester.pumpAndSettle();
      expect(find.text('Přijďte dřív.'), findsNothing);
      answer.complete();
      await tester.pumpAndSettle();
      expect(deleted, ['mine']);
      expect(find.text('Zpráva smazána.'), findsOneWidget);
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
      await tester.tap(find.text('Starší (1)'));
      await tester.pumpAndSettle();
      expect(find.text('Starší zpráva.'), findsOneWidget);
      await tester.tap(find.text('Starší (1)'));
      await tester.pumpAndSettle();
      expect(find.text('Starší zpráva.'), findsNothing);
    });

    testWidgets('a plain player sees only "Napsat"', (tester) async {
      await tester.pumpWidget(app());
      await tester.pumpAndSettle();
      expect(find.text('Napsat'), findsOneWidget);
      expect(find.text('Napsat hráčům'), findsNothing);
    });

    testWidgets('an admin also sees "Napsat hráčům"', (tester) async {
      const admin = Profile(
        id: 'admin', displayName: 'Adam', email: 'a@example.com',
        role: Role.admin, status: ProfileStatus.approved,
      );
      await tester.pumpWidget(app(profile: admin));
      await tester.pumpAndSettle();
      expect(find.text('Napsat'), findsOneWidget);
      expect(find.text('Napsat hráčům'), findsOneWidget);
    });

    testWidgets('so does a player on duty today', (tester) async {
      final period = DutyPeriod(id: 'p1', startsOn: Day(2026, 10, 2), endsOn: Day(2026, 10, 2));
      await tester.pumpWidget(app(duty: MyDuty(current: period, mine: [period])));
      await tester.pumpAndSettle();
      expect(find.text('Napsat hráčům'), findsOneWidget);
    });

    // The block edits' rule (0051/0050): a duty writes about the days of
    // their own periods, serving today or not.
    testWidgets('so does a player whose duty starts later', (tester) async {
      final next = DutyPeriod(id: 'p1', startsOn: Day(2026, 10, 9), endsOn: Day(2026, 10, 15));
      await tester.pumpWidget(app(duty: MyDuty(next: next, mine: [next])));
      await tester.pumpAndSettle();
      expect(find.text('Napsat hráčům'), findsOneWidget);
    });

    testWidgets('a player with no duty period left does not', (tester) async {
      // myDuty() leaves out what has ended, so `mine` is empty.
      await tester.pumpWidget(app(duty: MyDuty.none));
      await tester.pumpAndSettle();
      expect(find.text('Napsat hráčům'), findsNothing);
      expect(find.text('Napsat'), findsOneWidget);
    });

    // WCAG 1.4.4: the app scales text up to 200 % (AppTextScaler). The two
    // extended FABs must stay on screen and not overflow — they stack when
    // they do not fit side by side.
    // In the app's theme and font: the test font's glyphs are wider than
    // Manrope's, so its labels would not measure as on the phone.
    for (final (width, scale) in const [
      (360.0, 2.0), (393.0, 1.69), (360.0, 1.3), (320.0, 2.0), (320.0, 1.15),
    ]) {
      testWidgets('both FABs stay on a ${width.toInt()} dp screen at text ×$scale',
          (tester) async {
        tester.view.physicalSize = Size(width, 780);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        const admin = Profile(
          id: 'admin', displayName: 'Adam', email: 'a@example.com',
          role: Role.admin, status: ProfileStatus.approved,
        );
        await tester.pumpWidget(app(profile: admin,
            theme: buildTheme(Brightness.light), textScaler: TextScaler.linear(scale)));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        final fabs = find.byType(FloatingActionButton);
        expect(fabs, findsNWidgets(2));
        for (final part in [
          ...fabs.evaluate().map((e) => find.byWidget(e.widget)),
          find.text('Napsat hráčům'),
          find.text('Napsat'),
        ]) {
          final rect = tester.getRect(part);
          expect(rect.left, greaterThanOrEqualTo(0), reason: '$rect');
          expect(rect.right, lessThanOrEqualTo(width), reason: '$rect');
        }
      });
    }

    // The list leaves room under its last card for the FAB block, however
    // tall it is: one row, or two once large text stacks the FABs — and
    // above a gesture-nav inset, which lifts the FABs too.
    for (final (width, scale, inset) in const [
      (360.0, 1.0, 0.0), (360.0, 1.3, 0.0), (393.0, 1.69, 0.0),
      (320.0, 1.15, 0.0), (360.0, 2.0, 0.0), (360.0, 1.3, 48.0),
    ]) {
      testWidgets('scrolled to the end, the last card clears the FABs on a '
          '${width.toInt()} dp screen at text ×$scale, inset ${inset.toInt()}',
          (tester) async {
        tester.view.physicalSize = Size(width, 780);
        tester.view.devicePixelRatio = 1.0;
        tester.view.padding = FakeViewPadding(bottom: inset);
        tester.view.viewPadding = FakeViewPadding(bottom: inset);
        addTearDown(tester.view.reset);
        const admin = Profile(
          id: 'admin', displayName: 'Adam', email: 'a@example.com',
          role: Role.admin, status: ProfileStatus.approved,
        );
        final messages = [
          for (var i = 0; i < 8; i++)
            Message(
              id: 'm$i', kind: MessageKind.message,
              audience: MessageAudience.block, authorId: 'staff',
              authorRole: MessageAuthorRole.player,
              onDate: Day(2026, 10, 2 + i), blockId: 'b1', title: null,
              body: 'Přijďte dřív.', expiresAt: null, notify: true,
              createdAt: DateTime(2026, 10, 1), updatedAt: DateTime(2026, 10, 1),
            ),
        ];
        await tester.pumpWidget(app(
          profile: admin,
          messages: messages,
          recipients: [
            for (final m in messages)
              MessageRecipient(messageId: m.id, userId: 'admin',
                  readAt: DateTime(2026, 10, 1), reaction: null, reply: null,
                  reactedAt: null),
          ],
          roster: const [PlayerName(id: 'staff', displayName: 'Bára')],
          theme: buildTheme(Brightness.light),
          textScaler: TextScaler.linear(scale),
        ));
        await tester.pumpAndSettle();
        final list = tester.state<ScrollableState>(find.byType(Scrollable).first);
        // Lazily built: the extent grows as tiles are laid out.
        for (var i = 0; i < 6; i++) {
          await tester.drag(find.byType(ListView), const Offset(0, -3000));
          await tester.pumpAndSettle();
        }
        expect(list.position.pixels, list.position.maxScrollExtent);
        final last = tester.getRect(find.byKey(const ValueKey('m7')));
        final fabTop = find.byType(FloatingActionButton).evaluate()
            .map((e) => tester.getRect(find.byWidget(e.widget)).top)
            .reduce(math.min);
        expect(last.bottom, lessThanOrEqualTo(fabTop),
            reason: 'last card $last, upper FAB top $fabTop');
      });
    }

    // The FABs float above the keyboard, but a focused field is scrolled
    // only to the keyboard's edge — so they would cover the reply I am
    // typing. They step aside while the keyboard is up.
    for (final (label, profile, theme) in [
      ('a player', me, null),
      ('an admin', const Profile(
        id: 'me', displayName: 'Já Hráč', email: 'me@example.com',
        role: Role.admin, status: ProfileStatus.approved,
      ), buildTheme(Brightness.light)),
    ]) {
      testWidgets('with the keyboard up, no FAB covers the reply field '
          '($label)', (tester) async {
        tester.view.physicalSize = const Size(360, 640);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);
        await tester.pumpWidget(app(
          profile: profile,
          messages: [for (final id in ['a', 'b', 'c']) received(id: id)],
          roster: const [PlayerName(id: 'staff', displayName: 'Bára')],
          theme: theme,
        ));
        await tester.pumpAndSettle();
        final field = find.descendant(
          of: find.byKey(const ValueKey('b')),
          matching: find.byType(TextField),
        );
        await tester.tap(field);
        await tester.pump();
        tester.view.viewInsets = const FakeViewPadding(bottom: 280);
        await tester.pumpAndSettle();
        await tester.enterText(field, 'Přijdu o deset minut později, díky');
        await tester.pumpAndSettle();
        final rect = tester.getRect(field);
        expect(rect.bottom, lessThanOrEqualTo(640 - 280), reason: '$rect');
        for (final fab in find.byType(FloatingActionButton).evaluate()) {
          final fabRect = tester.getRect(find.byWidget(fab.widget));
          expect(rect.overlaps(fabRect), isFalse,
              reason: 'field $rect, FAB $fabRect');
        }

        // The keyboard goes down: the FABs are back.
        tester.view.resetViewInsets();
        await tester.pumpAndSettle();
        expect(find.text('Napsat'), findsOneWidget);
      });
    }

    // The composer's own keyboard lifts the page's insets too, and the FABs
    // step aside under it (above). The message must still go out: the
    // sheet sends it itself instead of handing it back to the FAB.
    for (final (label, profile, fab, audience, onDate) in [
      ('the player composer', me, 'Napsat', MessageAudience.admins, null),
      ('the staff composer', const Profile(
        id: 'me', displayName: 'Já Hráč', email: 'me@example.com',
        role: Role.admin, status: ProfileStatus.approved,
      ), 'Napsat hráčům', MessageAudience.day, Day(2026, 10, 2)),
    ]) {
      testWidgets('$label, typed with the keyboard up, still sends', (tester) async {
        tester.view.physicalSize = const Size(360, 780);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);
        final calls = <(MessageAudience, Day?, String?, String)>[];
        Future<String> send({
          required MessageKind kind,
          required MessageAudience audience,
          Day? onDate,
          String? blockId,
          String? title,
          required String body,
          DateTime? expiresAt,
          bool notify = true,
        }) async {
          calls.add((audience, onDate, blockId, body));
          return 'new-id';
        }

        await tester.pumpWidget(app(
          profile: profile,
          send: send,
          roster: const [PlayerName(id: 'p1', displayName: 'Petr Novák')],
          reservations: [
            Reservation(id: 'r1', playerId: 'p1', date: Day(2026, 10, 2),
                blockId: 'b1', lane: 1, createdVia: 'app',
                createdAt: DateTime(2026, 10, 1)),
          ],
        ));
        // The app's shell keeps the clock live (myDutyProvider follows
        // it); here myDutyProvider is a fixed value, so listen as the shell
        // does — else the staff sheet's „today“ is the device clock's.
        ProviderScope.containerOf(tester.element(find.byType(MessagesScreen)))
            .listen(nowProvider, (_, _) {});
        await tester.pumpAndSettle();
        await tester.tap(find.text(fab));
        await tester.pumpAndSettle();
        tester.view.viewInsets = const FakeViewPadding(bottom: 300);
        await tester.pumpAndSettle();
        await tester.enterText(find.byType(TextField), 'Přijďte dřív.');
        await tester.pump();
        await tester.tap(find.text('Odeslat'));
        await tester.pumpAndSettle();
        expect(calls, [(audience, onDate, null, 'Přijďte dřív.')]);
        expect(find.text('Zpráva odeslána.'), findsOneWidget);
      });
    }
  });

  group('MessageDetailScreen', () {
    // A caller page whose „open“ pushes [detail]: the route every gone
    // path must land back on.
    Widget caller(List<Override> overrides, Widget Function() detail) =>
        ProviderScope(
          overrides: overrides,
          child: MaterialApp(home: Scaffold(body: Builder(builder: (context) => TextButton(
            onPressed: () => Navigator.of(context)
                .push(MaterialPageRoute<void>(builder: (_) => detail())),
            child: const Text('open'),
          )))),
        );

    testWidgets('shows a spinner before the first snapshot, then the message', (tester) async {
      await tester.pumpWidget(ProviderScope(
        overrides: overrides(messages: [received()], recipients: [recip('me')]),
        child: MaterialApp(home: MessageDetailScreen('m1', markRead: (_) async {},
            react: (_, _) async {}, reply: (_, _) async {})),
      ));
      // The first frame, before Stream.value has delivered anything: any
      // pump() would already let every snapshot in.
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      await tester.pumpAndSettle();
      expect(find.text('Přijďte dřív.'), findsOneWidget);
    });

    testWidgets('a reply: a failed one stays in the field, one that went '
        'through follows my row', (tester) async {
      final myRows = StreamController<List<MessageRecipient>>()
        ..add([recip('me')]);
      addTearDown(myRows.close);
      var fail = true;
      await tester.pumpWidget(ProviderScope(
        overrides: overrides(messages: [received()], myRowStream: myRows.stream),
        child: MaterialApp(home: MessageDetailScreen('m1', markRead: (_) async {},
            react: (_, _) async {},
            reply: (id, text) async {
              myRows.add([recip('me', reply: text)]); // the optimistic patch
              if (!fail) return;
              await Future<void>.delayed(Duration.zero);
              myRows.add([recip('me')]); // the rollback
              throw Exception('offline');
            })),
      ));
      await tester.pumpAndSettle();
      String field() =>
          tester.widget<TextField>(find.byType(TextField)).controller!.text;
      Future<void> submit(String text) async {
        await tester.enterText(find.byType(TextField), text);
        await tester.testTextInput.receiveAction(TextInputAction.done);
        await tester.pumpAndSettle();
      }
      await submit('Nestihnu.');
      expect(find.byType(SnackBar), findsOneWidget);
      expect(field(), 'Nestihnu.');
      fail = false;
      await submit('Přijdu.');
      myRows.add([recip('me')]); // cleared on another device
      await tester.pumpAndSettle();
      expect(field(), '');
    });

    // Leaving the detail while my reply is out drops its tile: the page's
    // messenger, taken before the write, still tells the failure.
    testWidgets('a reply that fails after I left the detail still says why',
        (tester) async {
      final gate = Completer<void>();
      await tester.pumpWidget(caller(
        overrides(messages: [received()], recipients: [recip('me')]),
        () => MessageDetailScreen('m1', markRead: (_) async {},
            react: (_, _) async {},
            reply: (_, _) async {
              await gate.future;
              throw Exception('offline');
            }),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'Nestihnu.');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.byType(MessageTile), findsNothing);
      gate.complete();
      await tester.pumpAndSettle();
      expect(find.byType(SnackBar), findsOneWidget);
    });

    testWidgets('deleting here says „Zpráva smazána.“ — never „Zpráva už '
        'neexistuje.“ — when the echo comes before the reply', (tester) async {
      final messages = StreamController<List<Message>>();
      addTearDown(() => unawaited(messages.close()));
      final answer = Completer<void>();
      final asked = <String>[];
      await tester.pumpWidget(caller(overrides(messageStream: messages.stream),
          () => MessageDetailScreen('mine',
              markRead: (_) async {}, react: (_, _) async {}, reply: (_, _) async {},
              messageExists: (id) async { asked.add(id); return false; },
              delete: (_) => answer.future)));
      messages.add([received(id: 'mine', authorId: 'me')]);
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(PopupMenuButton<String>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Smazat'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Ano'));
      await tester.pump();
      messages.add(const []); // the echo, before the RPC's reply
      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(asked, isEmpty);
      expect(find.text('Zpráva už neexistuje.'), findsNothing);
      answer.complete();
      await tester.pump();
      await tester.pumpAndSettle();
      expect(find.text('Zpráva smazána.'), findsOneWidget);
      expect(find.text('Zpráva už neexistuje.'), findsNothing);
      expect(find.text('open'), findsOneWidget); // back on the caller
    });

    // Deleted from another device meanwhile: the echo takes the message
    // out while this delete runs, and the RPC then refuses. The screen
    // must stop waiting for its own delete and ask the server, not spin.
    testWidgets('a delete that fails after the echo stops spinning: the '
        'screen asks the server and leaves', (tester) async {
      final messages = StreamController<List<Message>>();
      addTearDown(() => unawaited(messages.close()));
      final answer = Completer<void>();
      final asked = <String>[];
      await tester.pumpWidget(caller(overrides(messageStream: messages.stream),
          () => MessageDetailScreen('mine',
              markRead: (_) async {}, react: (_, _) async {}, reply: (_, _) async {},
              messageExists: (id) async { asked.add(id); return false; },
              delete: (_) => answer.future)));
      messages.add([received(id: 'mine', authorId: 'me')]);
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(PopupMenuButton<String>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Smazat'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Ano'));
      await tester.pump();
      messages.add(const []); // the echo of the other device's delete
      await tester.pump();
      await tester.pump();
      expect(asked, isEmpty); // still waiting for its own delete
      answer.completeError(Exception('unknown_message'));
      await tester.pump();
      await tester.pumpAndSettle();
      expect(asked, ['mine']);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.text('open'), findsOneWidget); // back on the caller
    });

    // The failed delete's snack already says it; the server's "gone" that
    // follows must not queue the same words again.
    testWidgets('a delete that fails as gone after the echo says „Zpráva už '
        'neexistuje.“ once', (tester) async {
      final messages = StreamController<List<Message>>();
      addTearDown(() => unawaited(messages.close()));
      final answer = Completer<void>();
      await tester.pumpWidget(caller(overrides(messageStream: messages.stream),
          () => MessageDetailScreen('mine',
              markRead: (_) async {}, react: (_, _) async {}, reply: (_, _) async {},
              messageExists: (_) async => false,
              delete: (_) => answer.future)));
      messages.add([received(id: 'mine', authorId: 'me')]);
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(PopupMenuButton<String>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Smazat'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Ano'));
      await tester.pump();
      messages.add(const []); // the echo of the other device's delete
      await tester.pump();
      answer.completeError(Exception('unknown_message'));
      await tester.pumpAndSettle();
      expect(find.text('open'), findsOneWidget); // back on the caller
      expect(find.text('Zpráva už neexistuje.'), findsOneWidget);
      // A second snack would be queued behind the first: let it go.
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
      expect(find.text('Zpráva už neexistuje.'), findsNothing);
    });

    testWidgets('an id the server no longer has pops once, with a snack', (tester) async {
      final asked = <String>[];
      await tester.pumpWidget(caller(overrides(), () => MessageDetailScreen('missing',
          markRead: (_) async {}, react: (_, _) async {}, reply: (_, _) async {},
          messageExists: (id) async { asked.add(id); return false; })));
      await tester.tap(find.text('open'));
      await tester.pump();
      await tester.pump(); // the snapshot is in, the id is not: ask
      await tester.pump(); // the answer: gone
      await tester.pump(const Duration(seconds: 1)); // no 5 s wait
      expect(asked, ['missing']);
      expect(find.text('Zpráva už neexistuje.'), findsOneWidget);
      expect(find.text('open'), findsOneWidget); // back on the caller
      expect(find.byType(MessageDetailScreen), findsNothing);
    });

    testWidgets('a snapshot without the id, but the server has it: spins until '
        'the stream catches up, however long', (tester) async {
      // cachedRows replays the cache first; the message a push was sent
      // for is usually newer than it and arrives with the live snapshot —
      // on a poor network well after 5 s.
      final asked = <String>[];
      final messages = StreamController<List<Message>>();
      addTearDown(() => unawaited(messages.close()));
      await tester.pumpWidget(ProviderScope(
        overrides: overrides(messageStream: messages.stream, recipients: [recip('me')]),
        child: MaterialApp(home: MessageDetailScreen('m1', markRead: (_) async {},
            react: (_, _) async {}, reply: (_, _) async {},
            messageExists: (id) async { asked.add(id); return true; })),
      ));
      messages.add(const []);
      await tester.pump();
      await tester.pump(const Duration(seconds: 6));
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.text('Zpráva už neexistuje.'), findsNothing);
      messages.add([received()]);
      await tester.pumpAndSettle();
      expect(find.text('Přijďte dřív.'), findsOneWidget);
      expect(find.text('Zpráva už neexistuje.'), findsNothing);
      expect(asked, ['m1']);
    });

    testWidgets('the server cannot be asked (offline): „Zkusit znovu“, not '
        '"gone"', (tester) async {
      // A push tap offline with a stale cache: the cache is all the stream
      // gives, and it cannot tell "gone" from "not synced yet".
      final answers = <Future<bool> Function()>[
        () async => throw Exception('SocketException: Failed host lookup'),
        () async => false,
      ];
      await tester.pumpWidget(caller(overrides(), () => MessageDetailScreen('m1',
          markRead: (_) async {}, react: (_, _) async {}, reply: (_, _) async {},
          messageExists: (_) => answers.removeAt(0)())));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.text('Jsi offline — zkus to znovu po připojení.'), findsOneWidget);
      expect(find.text('Zkusit znovu'), findsOneWidget);
      expect(find.text('Zpráva už neexistuje.'), findsNothing);
      expect(find.byType(MessageDetailScreen), findsOneWidget);
      // Back online: the retry asks again, and now it is gone for real.
      await tester.tap(find.text('Zkusit znovu'));
      await tester.pumpAndSettle();
      expect(answers, isEmpty);
      expect(find.text('Zpráva už neexistuje.'), findsOneWidget);
      expect(find.byType(MessageDetailScreen), findsNothing);
      expect(find.text('open'), findsOneWidget);
    });

    testWidgets('a sent message opens expanded: names and replies without a tap',
        (tester) async {
      // A „Reakce na tvou zprávu“ push lands here; the reply that sent it
      // must be on screen, not behind the tally.
      await tester.pumpWidget(ProviderScope(
        overrides: overrides(
          messages: [received(authorId: 'me')],
          recipients: [recip('p1', reaction: Reaction.up, reply: 'přijdu'), recip('p2')],
          roster: const [PlayerName(id: 'p1', displayName: 'Petr'),
              PlayerName(id: 'p2', displayName: 'Tomáš'),
              PlayerName(id: 'me', displayName: 'Já Hráč')],
        ),
        child: MaterialApp(home: MessageDetailScreen('m1', markRead: (_) async {},
            react: (_, _) async {}, reply: (_, _) async {})),
      ));
      await tester.pumpAndSettle();
      expect(find.text('1× 👍 · 1 bez reakce'), findsOneWidget);
      expect(find.text('👍 Petr „přijdu“ · bez reakce: Tomáš'), findsOneWidget);
    });

    testWidgets('opening marks my unread row read, once', (tester) async {
      // Every push tap and e-mail link lands here, not on the list: the
      // Zprávy badge and the Klubovna dot must drop without a detour.
      final marked = <List<String>>[];
      final messages = StreamController<List<Message>>();
      addTearDown(messages.close);
      await tester.pumpWidget(ProviderScope(
        overrides: overrides(messageStream: messages.stream, recipients: [recip('me')]),
        child: MaterialApp(home: MessageDetailScreen('m1',
            markRead: (ids) async => marked.add(ids),
            react: (_, _) async {}, reply: (_, _) async {})),
      ));
      messages.add([received()]);
      await tester.pumpAndSettle();
      // A second snapshot (the live one after the cache) rebuilds with the
      // row still unread — the mock does not patch it — and asks nothing.
      messages.add([received()]);
      await tester.pumpAndSettle();
      expect(marked, [['m1']]);
    });

    testWidgets('a message I sent marks nothing', (tester) async {
      final marked = <List<String>>[];
      await tester.pumpWidget(ProviderScope(
        overrides: overrides(messages: [received(authorId: 'me')], recipients: [recip('p1')]),
        child: MaterialApp(home: MessageDetailScreen('m1',
            markRead: (ids) async => marked.add(ids),
            react: (_, _) async {}, reply: (_, _) async {})),
      ));
      await tester.pumpAndSettle();
      expect(find.text('Přijďte dřív.'), findsOneWidget);
      expect(marked, isEmpty);
    });

    testWidgets('gone with its own ⋮ → Smazat dialog open: the dialog and the '
        'detail go, back on the caller', (tester) async {
      // Deleted elsewhere (another device, an admin, the prune) while the
      // author has „Smazat zprávu?“ up: popping whatever is on top would
      // close the dialog and leave a blank „Zpráva“ page behind.
      final messages = StreamController<List<Message>>();
      addTearDown(() => unawaited(messages.close())); // never awaits a paused listener
      await tester.pumpWidget(caller(
        overrides(messageStream: messages.stream, recipients: [recip('p1')]),
        () => MessageDetailScreen('m1', markRead: (_) async {},
            react: (_, _) async {}, reply: (_, _) async {},
            messageExists: (_) async => false),
      ));
      await tester.tap(find.text('open'));
      await tester.pump();
      messages.add([received(authorId: 'me')]);
      await tester.pumpAndSettle();
      await tester.tap(find.byType(PopupMenuButton<String>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Smazat'));
      await tester.pumpAndSettle();
      expect(find.text('Smazat zprávu?'), findsOneWidget);
      messages.add(const []);
      await tester.pumpAndSettle();
      expect(find.text('Zpráva už neexistuje.'), findsOneWidget);
      expect(find.text('Smazat zprávu?'), findsNothing);
      expect(find.byType(MessageDetailScreen), findsNothing);
      expect(find.text('open'), findsOneWidget);
    });

    testWidgets('gone under a second detail pushed on top: only its own route '
        'goes', (tester) async {
      // Two push taps in a row: the first detail still spins when the
      // second is pushed above it — its gone path must not pop the second.
      final firstAnswer = Completer<bool>();
      await tester.pumpWidget(caller(
        overrides(messages: [received()], recipients: [recip('me')]),
        () => MessageDetailScreen('missing', markRead: (_) async {},
            react: (_, _) async {}, reply: (_, _) async {},
            messageExists: (_) => firstAnswer.future),
      ));
      await tester.tap(find.text('open'));
      await tester.pump();
      await tester.pump(); // the snapshot is in; the id is not: asking
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      tester.state<NavigatorState>(find.byType(Navigator)).push(
          MaterialPageRoute<void>(builder: (_) => MessageDetailScreen('m1',
              markRead: (_) async {}, react: (_, _) async {}, reply: (_, _) async {},
              messageExists: (_) async => true)));
      await tester.pumpAndSettle();
      firstAnswer.complete(false);
      await tester.pumpAndSettle();
      expect(find.text('Zpráva už neexistuje.'), findsOneWidget);
      expect(find.byType(MessageDetailScreen), findsOneWidget);
      expect(find.text('Přijďte dřív.'), findsOneWidget);
      tester.state<NavigatorState>(find.byType(Navigator)).pop();
      await tester.pumpAndSettle();
      expect(find.text('open'), findsOneWidget); // the caller, not a blank page
    });

    testWidgets('a message already read marks nothing', (tester) async {
      final marked = <List<String>>[];
      await tester.pumpWidget(ProviderScope(
        overrides: overrides(messages: [received()], recipients: [
          MessageRecipient(messageId: 'm1', userId: 'me', readAt: DateTime(2026, 10, 1),
              reaction: null, reply: null, reactedAt: null),
        ]),
        child: MaterialApp(home: MessageDetailScreen('m1',
            markRead: (ids) async => marked.add(ids),
            react: (_, _) async {}, reply: (_, _) async {})),
      ));
      await tester.pumpAndSettle();
      expect(find.text('Přijďte dřív.'), findsOneWidget);
      expect(marked, isEmpty);
    });
  });
}
