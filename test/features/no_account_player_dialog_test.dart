import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:rezervator/domain/models.dart';
import 'package:rezervator/features/admin/widgets/no_account_player_dialog.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Pins the "hráč bez účtu" add/edit dialog at the HTTP layer: what the
/// save_placeholder_player RPC receives, and which inputs are refused.
void main() {
  const clubs = [
    Club(id: 'c1', name: 'Sokol', colorIndex: 1),
    Club(id: 'c2', name: 'Veverky', colorIndex: 2),
  ];
  const existing = Profile(
    id: 'ph1',
    displayName: 'Bohumil Kroupa',
    email: '',
    role: Role.player,
    status: ProfileStatus.approved,
    nick: 'Bohouš',
    clubId: 'c1',
    hasAccount: false,
  );

  late List<http.Request> requests;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues({});
    final mock = MockClient((request) async {
      requests.add(request);
      // postgrest reads response.request — MockClient doesn't attach it
      // unless we do.
      return http.Response('{}', 200,
          headers: {'content-type': 'application/json'}, request: request);
    });
    await Supabase.initialize(
      url: 'http://localhost:54321',
      publishableKey: 'test-anon-key',
      httpClient: mock,
      authOptions: const FlutterAuthClientOptions(
        detectSessionInUri: false,
        localStorage: EmptyLocalStorage(),
      ),
    );
  });

  setUp(() => requests = []);

  /// The dialog is pushed with showDialog (as the app does) so popping it —
  /// and what it pops with — is observable through [onResult].
  Future<void> open(
    WidgetTester tester,
    NoAccountPlayerDialog dialog, {
    void Function(bool?)? onResult,
  }) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => Center(
            child: TextButton(
              onPressed: () async {
                final result = await showDialog<bool>(
                    context: context, builder: (_) => dialog);
                onResult?.call(result);
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  Iterable<http.Request> rpc(String name) => requests.where(
      (r) => r.method == 'POST' && r.url.path.endsWith('/rpc/$name'));

  Map<String, dynamic> bodyOf(http.Request r) =>
      jsonDecode(r.body) as Map<String, dynamic>;

  testWidgets('add: sends save_placeholder_player without an id and pops true',
      (tester) async {
    bool? result;
    await open(tester, const NoAccountPlayerDialog(clubs: clubs),
        onResult: (r) => result = r);
    expect(find.text('Přidat hráče bez účtu'), findsOneWidget);
    expect(find.textContaining('Pro hráče, který se nepřihlašuje.'),
        findsOneWidget);

    await tester.enterText(
        find.widgetWithText(TextField, 'Jméno a příjmení'), 'Bohumil Kroupa');
    await tester.enterText(
        find.widgetWithText(TextField, 'Přezdívka na tabuli (nepovinné)'),
        'Bohouš');
    await tester.tap(find.byType(DropdownButtonFormField<String?>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Sokol').last);
    await tester.pumpAndSettle();

    await tester.tap(find.text('Uložit'));
    await tester.pumpAndSettle();

    final body = bodyOf(rpc('save_placeholder_player').single);
    expect(body.containsKey('p_id'), isTrue);
    expect(body['p_id'], isNull);
    expect(body['p_display_name'], 'Bohumil Kroupa');
    expect(body['p_nick'], 'Bohouš');
    expect(body['p_club_id'], 'c1');
    expect(result, isTrue);
    expect(find.text('Přidat hráče bez účtu'), findsNothing);
    expect(find.text('Hráč přidán.'), findsOneWidget);
  });

  testWidgets('edit: prefills the row, titles Upravit and sends the id',
      (tester) async {
    bool? result;
    await open(
        tester, const NoAccountPlayerDialog(existing: existing, clubs: clubs),
        onResult: (r) => result = r);
    expect(find.text('Upravit hráče bez účtu'), findsOneWidget);
    // The intro is for a first-time add only.
    expect(find.textContaining('Pro hráče, který se nepřihlašuje.'),
        findsNothing);
    expect(find.widgetWithText(TextField, 'Bohumil Kroupa'), findsOneWidget);
    expect(find.widgetWithText(TextField, 'Bohouš'), findsOneWidget);
    expect(
      tester
          .widget<DropdownButtonFormField<String?>>(
              find.byType(DropdownButtonFormField<String?>))
          .initialValue,
      'c1',
    );

    await tester.enterText(
        find.widgetWithText(TextField, 'Bohumil Kroupa'), 'Bohumil Kroupa ml.');
    await tester.tap(find.text('Uložit'));
    await tester.pumpAndSettle();

    final body = bodyOf(rpc('save_placeholder_player').single);
    expect(body['p_id'], 'ph1');
    expect(body['p_display_name'], 'Bohumil Kroupa ml.');
    expect(body['p_nick'], 'Bohouš');
    expect(body['p_club_id'], 'c1');
    expect(result, isTrue);
    expect(find.text('Uloženo.'), findsOneWidget);
  });

  testWidgets('a deleted club prefills as Bez oddílu', (tester) async {
    await open(
        tester,
        const NoAccountPlayerDialog(
            existing: existing, clubs: [Club(id: 'c2', name: 'Veverky')]));
    expect(
      tester
          .widget<DropdownButtonFormField<String?>>(
              find.byType(DropdownButtonFormField<String?>))
          .initialValue,
      isNull,
    );
  });

  testWidgets('an empty name is refused — no request, dialog stays open',
      (tester) async {
    await open(tester, const NoAccountPlayerDialog(clubs: clubs));
    await tester.enterText(
        find.widgetWithText(TextField, 'Jméno a příjmení'), '   ');
    await tester.tap(find.text('Uložit'));
    await tester.pumpAndSettle();

    expect(find.text('Vyplň jméno hráče.'), findsOneWidget);
    expect(requests, isEmpty);
    expect(find.text('Přidat hráče bez účtu'), findsOneWidget);
  });

  testWidgets('without clubs there is no Oddíl field', (tester) async {
    await open(tester, const NoAccountPlayerDialog(clubs: []));
    expect(find.text('Jméno a příjmení'), findsOneWidget);
    expect(find.text('Přezdívka na tabuli (nepovinné)'), findsOneWidget);
    expect(find.text('Oddíl'), findsNothing);
    expect(find.byType(DropdownButtonFormField<String?>), findsNothing);
  });
}
