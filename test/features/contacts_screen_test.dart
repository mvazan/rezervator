import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rezervator/data/providers.dart';
import 'package:rezervator/domain/models.dart';
import 'package:rezervator/features/clubhouse/contacts_screen.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show PostgrestException;

/// Klubovna → Kontakty (0048): the rows, the actions each visibility
/// allows, the note's way to Můj profil, and the list's states.
void main() {
  const adam = Contact(
    id: 'a',
    displayName: 'Adam Admin',
    nick: 'Áďa',
    clubId: 'c1',
    clubName: 'Oddíl E',
    clubColor: 3,
    email: 'adam@example.com',
    phone: '+420777000001',
  );
  const bela = Contact(
    id: 'b',
    displayName: 'Běla Skrytá',
    clubName: 'Oddíl E',
    clubColor: 3,
    phone: '+420777000002',
  );
  const cenek = Contact(
    id: 'c',
    displayName: 'Čeněk Černý',
    nick: 'Čenda',
    email: 'cenek@example.com',
  );
  const chalupa = Contact(id: 'h', displayName: 'Chalupa Jan');

  late List<String> launched;
  late int fetches;

  setUp(() {
    launched = [];
    fetches = 0;
  });

  Widget app(Future<List<Contact>> Function() fetch) => ProviderScope(
        overrides: [
          contactsProvider.overrideWith((ref) {
            fetches++;
            return fetch();
          }),
        ],
        child: MaterialApp(
          home: ContactsScreen(
            sendEmail: (v) => launched.add('email:$v'),
            callPhone: (v) => launched.add('call:$v'),
            openUrl: (v) => launched.add('url:$v'),
            profilePage: (_) => Scaffold(
              appBar: AppBar(title: const Text('Profil (test)')),
            ),
          ),
        ),
      );

  const note = 'Svůj e-mail a telefon můžeš v Kontaktech skrýt v Můj profil → '
      'Kontakt.';

  /// The recognizer on the note's „Můj profil" words — tapped directly, as
  /// tapOnText lands on a glyph edge under the test font's letter spacing.
  TapGestureRecognizer profileLink(WidgetTester tester) {
    GestureRecognizer? link;
    tester.widget<RichText>(find.text(note, findRichText: true)).text
        .visitChildren((span) {
      if (span is TextSpan && span.text == 'Můj profil') link = span.recognizer;
      return link == null;
    });
    return link! as TapGestureRecognizer;
  }

  Finder rowOf(String name) => find.widgetWithText(ListTile, name);
  Finder inRow(String name, Finder matching) =>
      find.descendant(of: rowOf(name), matching: matching);

  testWidgets('rows are Czech-sorted, with the nick and club under the name',
      (tester) async {
    await tester.pumpWidget(app(() async => [chalupa, cenek, bela, adam]));
    await tester.pumpAndSettle();

    expect(find.widgetWithText(AppBar, 'Kontakty'), findsOneWidget);
    final titles = [
      for (final tile in tester.widgetList<ListTile>(find.byType(ListTile)))
        (tile.title! as Text).data,
    ];
    expect(titles,
        ['Adam Admin', 'Běla Skrytá', 'Čeněk Černý', 'Chalupa Jan']);
    expect(inRow('Adam Admin', find.text('„Áďa“ · Oddíl E')), findsOneWidget);
    expect(inRow('Běla Skrytá', find.text('Oddíl E')), findsOneWidget);
    expect(inRow('Čeněk Černý', find.text('„Čenda“')), findsOneWidget);
    expect(tester.widget<ListTile>(rowOf('Chalupa Jan')).subtitle, isNull);
  });

  testWidgets('each row offers what its player shows, and the actions call '
      'the launchers — WhatsApp through wa.me', (tester) async {
    await tester.pumpWidget(app(() async => [adam, bela, cenek, chalupa]));
    await tester.pumpAndSettle();

    // Both shown: e-mail, call, WhatsApp.
    await tester.tap(inRow('Adam Admin', find.byTooltip('Napsat e-mail')));
    await tester.tap(inRow('Adam Admin', find.byTooltip('Zavolat')));
    await tester.tap(inRow('Adam Admin', find.byTooltip('WhatsApp')));
    expect(launched, [
      'email:adam@example.com',
      'call:+420777000001',
      'url:https://wa.me/420777000001',
    ]);

    // Phone only: no e-mail button.
    expect(inRow('Běla Skrytá', find.byTooltip('Napsat e-mail')), findsNothing);
    expect(inRow('Běla Skrytá', find.byTooltip('Zavolat')), findsOneWidget);
    expect(inRow('Běla Skrytá', find.byTooltip('WhatsApp')), findsOneWidget);

    // E-mail only: no call, no WhatsApp.
    expect(inRow('Čeněk Černý', find.byTooltip('Napsat e-mail')),
        findsOneWidget);
    expect(inRow('Čeněk Černý', find.byTooltip('Zavolat')), findsNothing);
    expect(inRow('Čeněk Černý', find.byTooltip('WhatsApp')), findsNothing);

    // Neither: a muted note instead of buttons.
    expect(inRow('Chalupa Jan', find.text('kontakt skrytý')), findsOneWidget);
    expect(inRow('Chalupa Jan', find.byType(IconButton)), findsNothing);
    expect(find.text('kontakt skrytý'), findsOneWidget);
  });

  testWidgets('search ignores accents and case, over name, nick and club',
      (tester) async {
    await tester.pumpWidget(app(() async => [adam, bela, cenek, chalupa]));
    await tester.pumpAndSettle();

    expect(find.text('Hledat jméno, přezdívku nebo oddíl'), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'CERNY');
    await tester.pumpAndSettle();
    expect(find.byType(ListTile), findsOneWidget);
    expect(rowOf('Čeněk Černý'), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'oddil e');
    await tester.pumpAndSettle();
    expect(find.byType(ListTile), findsNWidgets(2));

    await tester.enterText(find.byType(TextField), 'Havířov');
    await tester.pumpAndSettle();
    expect(find.byType(ListTile), findsNothing);
    expect(find.text('Nikdo takový tu není.'), findsOneWidget);
  });

  testWidgets('the note says where to hide one\'s own contact, and „Můj '
      'profil" opens the profile; coming back re-reads the list',
      (tester) async {
    await tester.pumpWidget(app(() async => [adam]));
    await tester.pumpAndSettle();

    expect(find.text(note, findRichText: true), findsOneWidget);
    expect(fetches, 1);

    profileLink(tester).onTap!();
    await tester.pumpAndSettle();
    expect(find.widgetWithText(AppBar, 'Profil (test)'), findsOneWidget);

    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.widgetWithText(AppBar, 'Kontakty'), findsOneWidget);
    expect(fetches, 2);
  });

  testWidgets('pull-to-refresh fetches the list again', (tester) async {
    await tester.pumpWidget(app(() async => [adam, bela]));
    await tester.pumpAndSettle();
    expect(fetches, 1);

    await tester.fling(
      find.byKey(const Key('contacts-list')),
      const Offset(0, 300),
      1000,
    );
    await tester.pumpAndSettle();

    expect(fetches, 2);
  });

  testWidgets('an offline pull-to-refresh says so at once and keeps the list',
      (tester) async {
    var offline = false;
    await tester.pumpWidget(app(() async {
      if (offline) throw const SocketException('Failed host lookup');
      return [adam, bela];
    }));
    await tester.pumpAndSettle();
    expect(fetches, 1);

    offline = true;
    await tester.fling(
      find.byKey(const Key('contacts-list')),
      const Offset(0, 300),
      1000,
    );
    // One second: Riverpod's default retry kept the spinner going ~40 s.
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }

    expect(find.text('Jsi offline — zkus to znovu po připojení.'),
        findsOneWidget);
    expect(fetches, 2);
    expect(rowOf('Adam Admin'), findsOneWidget);
    await tester.pumpAndSettle();
  });

  testWidgets('an empty alley says so', (tester) async {
    await tester.pumpWidget(app(() async => const []));
    await tester.pumpAndSettle();

    expect(find.text('Zatím tu nikdo není.'), findsOneWidget);
  });

  testWidgets('a failed load shows the friendly message and „Zkusit znovu", '
      'and is not re-sent behind the user\'s back', (tester) async {
    var fail = true;
    await tester.pumpWidget(app(() async {
      if (fail) throw const PostgrestException(message: 'not_allowed');
      return [adam];
    }));
    await tester.pumpAndSettle();

    expect(find.text('Na tohle nemáš oprávnění.'), findsOneWidget);
    expect(rowOf('Adam Admin'), findsNothing);
    // Riverpod's default retry would have fetched ~6 more times by now.
    await tester.pump(const Duration(seconds: 10));
    expect(fetches, 1);

    fail = false;
    await tester.tap(find.widgetWithText(OutlinedButton, 'Zkusit znovu'));
    await tester.pumpAndSettle();

    expect(find.text('Na tohle nemáš oprávnění.'), findsNothing);
    expect(rowOf('Adam Admin'), findsOneWidget);
  });
}
