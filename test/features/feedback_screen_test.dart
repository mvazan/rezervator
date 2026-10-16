import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rezervator/features/feedback/feedback_screen.dart';
import 'package:sentry_flutter/sentry_flutter.dart';

/// Napište nám: the form, what it hands to the sender, and what a visitor
/// sees after a send that went through or did not.
void main() {
  late List<FeedbackMessage> sent;
  late bool delivered;

  setUp(() {
    sent = [];
    delivered = true;
  });

  Widget app(Widget screen, {Future<void>? until}) => ProviderScope(
    overrides: [
      feedbackSenderProvider.overrideWithValue((message) async {
        sent.add(message);
        await until;
        return delivered;
      }),
    ],
    child: MaterialApp(home: screen),
  );

  Finder field(String label) => find.widgetWithText(TextField, label);

  testWidgets('sends the message, name and e-mail with its source, then '
      'thanks', (tester) async {
    await tester.pumpWidget(
      app(const FeedbackScreen(source: FeedbackSource.kiosk)),
    );
    await tester.enterText(field('Zpráva'), '  Chybí mi tmavý režim.  ');
    await tester.enterText(field('Jméno (nepovinné)'), ' Pepa ');
    await tester.enterText(field('E-mail pro odpověď (nepovinné)'), 'p@x.cz');
    await tester.tap(find.text('Odeslat'));
    await tester.pumpAndSettle();

    expect(sent, hasLength(1));
    expect(sent.single.message, 'Chybí mi tmavý režim.');
    expect(sent.single.name, 'Pepa');
    expect(sent.single.email, 'p@x.cz');
    expect(sent.single.source, FeedbackSource.kiosk);
    expect(sent.single.tenantId, isNull);
    expect(find.text('Díky, zpráva odešla.'), findsOneWidget);
    expect(find.textContaining('p@x.cz'), findsOneWidget);
    expect(field('Zpráva'), findsNothing);
  });

  testWidgets('empty name and e-mail go as null', (tester) async {
    await tester.pumpWidget(
      app(const FeedbackScreen(source: FeedbackSource.link)),
    );
    await tester.enterText(field('Zpráva'), 'Ahoj');
    await tester.tap(find.text('Odeslat'));
    await tester.pumpAndSettle();

    expect(sent.single.name, isNull);
    expect(sent.single.email, isNull);
    // Nobody to answer: the thanks do not promise a reply.
    expect(find.text('Díky, zpráva odešla.'), findsOneWidget);
    expect(find.textContaining('odpovědět'), findsNothing);
  });

  testWidgets('an empty message is not sent', (tester) async {
    await tester.pumpWidget(
      app(const FeedbackScreen(source: FeedbackSource.link)),
    );
    await tester.enterText(field('Zpráva'), '   ');
    await tester.tap(find.text('Odeslat'));
    await tester.pumpAndSettle();

    expect(sent, isEmpty);
    expect(find.text('Napiš, co nám chceš vzkázat.'), findsOneWidget);
  });

  testWidgets('an e-mail without @ is not sent', (tester) async {
    await tester.pumpWidget(
      app(const FeedbackScreen(source: FeedbackSource.link)),
    );
    await tester.enterText(field('Zpráva'), 'Ahoj');
    await tester.enterText(field('E-mail pro odpověď (nepovinné)'), 'pepa');
    await tester.tap(find.text('Odeslat'));
    await tester.pumpAndSettle();

    expect(sent, isEmpty);
    expect(find.text('Tohle nevypadá jako e-mail.'), findsOneWidget);
  });

  testWidgets('a send that did not go through keeps the form and says so', (
    tester,
  ) async {
    delivered = false;
    await tester.pumpWidget(
      app(const FeedbackScreen(source: FeedbackSource.link)),
    );
    await tester.enterText(field('Zpráva'), 'Ahoj');
    await tester.tap(find.text('Odeslat'));
    await tester.pumpAndSettle();

    expect(sent, hasLength(1));
    expect(find.text('Díky, zpráva odešla.'), findsNothing);
    expect(
      find.text('Zprávu se nepodařilo odeslat. Zkus to prosím později.'),
      findsOneWidget,
    );
    expect(find.text('Ahoj'), findsOneWidget);
  });

  testWidgets('the signed-in player\'s name, e-mail and kuželna come filled '
      'in', (tester) async {
    await tester.pumpWidget(
      app(
        const FeedbackScreen(
          source: FeedbackSource.clubhouse,
          initialName: 'Já Hráč',
          initialEmail: 'me@example.com',
          tenantId: 't1',
        ),
      ),
    );
    expect(find.text('Já Hráč'), findsOneWidget);
    expect(find.text('me@example.com'), findsOneWidget);
    await tester.enterText(field('Zpráva'), 'Ahoj');
    await tester.tap(find.text('Odeslat'));
    await tester.pumpAndSettle();

    expect(sent.single.name, 'Já Hráč');
    expect(sent.single.email, 'me@example.com');
    expect(sent.single.tenantId, 't1');
    expect(sent.single.source, FeedbackSource.clubhouse);
  });

  testWidgets('„Napsat další zprávu“ brings back an empty message, the name '
      'and e-mail kept', (tester) async {
    await tester.pumpWidget(
      app(const FeedbackScreen(source: FeedbackSource.link)),
    );
    await tester.enterText(field('Zpráva'), 'První');
    await tester.enterText(field('Jméno (nepovinné)'), 'Pepa');
    await tester.tap(find.text('Odeslat'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Napsat další zprávu'));
    await tester.pumpAndSettle();

    expect(field('Zpráva'), findsOneWidget);
    expect(find.text('První'), findsNothing);
    expect(find.text('Pepa'), findsOneWidget);
  });

  testWidgets('a second tap while sending sends once', (tester) async {
    final done = Completer<void>();
    await tester.pumpWidget(
      app(
        const FeedbackScreen(source: FeedbackSource.link),
        until: done.future,
      ),
    );
    await tester.enterText(field('Zpráva'), 'Ahoj');
    await tester.tap(find.text('Odeslat'));
    await tester.pump();
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    await tester.tap(find.text('Odeslat'));
    await tester.pump();
    done.complete();
    await tester.pumpAndSettle();

    expect(sent, hasLength(1));
    expect(find.text('Díky, zpráva odešla.'), findsOneWidget);
  });

  group('feedbackSourceFromQuery', () {
    test('z=kiosk is the kiosk\'s QR code', () {
      expect(feedbackSourceFromQuery('kiosk'), FeedbackSource.kiosk);
    });

    test('anything else is a plain link', () {
      expect(feedbackSourceFromQuery(null), FeedbackSource.link);
      expect(feedbackSourceFromQuery(''), FeedbackSource.link);
      expect(feedbackSourceFromQuery('clubhouse'), FeedbackSource.link);
    });
  });

  group('with Sentry', () {
    Future<void> start(SentryId? answer) => Sentry.init((o) {
          o.dsn = 'https://key@o0.ingest.de.sentry.io/1';
          o.transport = _FakeTransport(answer);
        });
    tearDown(Sentry.close);
    const message =
        FeedbackMessage(message: 'Ahoj', source: FeedbackSource.link);

    test('a message Sentry takes is sent', () async {
      await start(SentryId.newId());
      expect(await sendFeedbackToSentry(message), isTrue);
    });

    // The web: a blocked or failed request (an ad blocker, no network)
    // ends in the SDK as an empty id, not as an exception — the visitor
    // must not read „odešla“ then.
    test('a message the transport could not deliver is not sent', () async {
      await start(null);
      expect(await sendFeedbackToSentry(message), isFalse);
    });
  });

  test('without Sentry the sender says it could not send', () async {
    expect(
      await sendFeedbackToSentry(
        const FeedbackMessage(message: 'Ahoj', source: FeedbackSource.link),
      ),
      isFalse,
    );
  });
}

/// Answers every envelope with [answer] — Sentry's id, or null for a
/// request that failed.
class _FakeTransport implements Transport {
  _FakeTransport(this.answer);

  final SentryId? answer;

  @override
  Future<SentryId?> send(SentryEnvelope envelope) async => answer;
}
