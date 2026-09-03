import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:rezervator/data/providers.dart';
import 'package:rezervator/domain/models.dart';
import 'package:rezervator/features/admin/players_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Pins the Hráči screen's placeholder flows at the HTTP layer: what the
/// delete and merge menu paths send once confirmed.
void main() {
  const admin = Profile(
    id: 'admin1',
    displayName: 'Správce',
    email: 'admin@example.com',
    role: Role.admin,
    status: ProfileStatus.approved,
  );
  const placeholder = Profile(
    id: 'ph1',
    displayName: 'Bohumil Kroupa',
    email: '',
    role: Role.player,
    status: ProfileStatus.approved,
    nick: 'Bohouš',
    clubId: 'c1',
    hasAccount: false,
  );
  const registrant = Profile(
    id: 'u1',
    displayName: 'B. Kroupa',
    email: 'b@example.com',
    role: Role.player,
    status: ProfileStatus.pending,
  );
  const clubs = [Club(id: 'c1', name: 'Sokol', colorIndex: 1)];

  late List<http.Request> requests;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues({});
    final mock = MockClient((request) async {
      requests.add(request);
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

  // One ProviderScope per test: a second pumpWidget does not swap overrides.
  Widget app(List<Profile> profiles) => ProviderScope(
        overrides: [
          myProfileProvider.overrideWith((ref) => Stream.value(admin)),
          profilesProvider.overrideWith((ref) => Stream.value(profiles)),
          clubsProvider.overrideWith((ref) => Stream.value(clubs)),
        ],
        child: const MaterialApp(home: PlayersScreen()),
      );

  Finder menuOf(String name) => find.descendant(
        of: find.widgetWithText(ListTile, name),
        matching: find.byType(PopupMenuButton<String>),
      );

  Finder inSheet(String text) =>
      find.descendant(of: find.byType(BottomSheet), matching: find.text(text));

  http.Request rpc(String name) => requests.singleWhere(
      (r) => r.method == 'POST' && r.url.path.endsWith('/rpc/$name'));

  Map<String, dynamic> bodyOf(http.Request r) =>
      jsonDecode(r.body) as Map<String, dynamic>;

  testWidgets('Smazat → Ano posts delete_placeholder_player', (tester) async {
    await tester.pumpWidget(app([admin, placeholder]));
    await tester.pumpAndSettle();

    await tester.tap(menuOf('Bohumil Kroupa'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Smazat'));
    await tester.pumpAndSettle();
    expect(find.text('Smazat hráče?'), findsOneWidget);
    await tester.tap(find.text('Ano'));
    await tester.pumpAndSettle();

    expect(bodyOf(rpc('delete_placeholder_player')), {'p_id': 'ph1'});
    expect(find.text('Smazáno.'), findsOneWidget);
  });

  testWidgets('Sloučit do účtu… → picker → dialog → Sloučit posts '
      'merge_placeholder_player with both ids', (tester) async {
    await tester.pumpWidget(app([admin, placeholder, registrant]));
    await tester.pumpAndSettle();

    await tester.tap(menuOf('Bohumil Kroupa'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Sloučit do účtu…'));
    await tester.pumpAndSettle();
    await tester.tap(inSheet('B. Kroupa'));
    await tester.pumpAndSettle();
    expect(find.text('Sloučit hráče'), findsOneWidget);

    await tester.tap(find.text('Sloučit'));
    await tester.pumpAndSettle();

    final body = bodyOf(rpc('merge_placeholder_player'));
    expect(body['p_placeholder_id'], 'ph1');
    expect(body['p_target_id'], 'u1');
    expect(body['p_display_name'], 'B. Kroupa'); // the account's by default
    expect(body['p_nick'], 'Bohouš'); // the only nick there is
    expect(body['p_club_id'], 'c1'); // the only club there is
    expect(find.text('Sloučit hráče'), findsNothing);
    expect(find.text('Hráči sloučeni.'), findsOneWidget);
  });
}
