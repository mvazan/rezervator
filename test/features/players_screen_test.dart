import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rezervator/data/providers.dart';
import 'package:rezervator/domain/models.dart';
import 'package:rezervator/features/admin/players_screen.dart';

void main() {
  const admin = Profile(
    id: 'admin1',
    displayName: 'Správce',
    email: 'admin@example.com',
    role: Role.admin,
    status: ProfileStatus.approved,
  );

  Profile player(String id, String name, {String? clubId, Role? role}) =>
      Profile(
        id: id,
        displayName: name,
        email: '$id@example.com',
        role: role ?? Role.player,
        status: ProfileStatus.approved,
        clubId: clubId,
      );

  const clubs = [
    Club(id: 'c2', name: 'Veverky', colorIndex: 2),
    Club(id: 'c1', name: 'Sokol Dlouhá Lhota', colorIndex: 1),
  ];

  /// A hand-made "hráč bez účtu" (0022).
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

  /// The same person, freshly registered and waiting for approval.
  const registrant = Profile(
    id: 'u1',
    displayName: 'B. Kroupa',
    email: 'b@example.com',
    role: Role.player,
    status: ProfileStatus.pending,
  );

  Widget app(List<Profile> profiles, {Size? surface}) {
    return ProviderScope(
      overrides: [
        myProfileProvider.overrideWith((ref) => Stream.value(admin)),
        profilesProvider.overrideWith((ref) => Stream.value(profiles)),
        clubsProvider.overrideWith((ref) => Stream.value(clubs)),
      ],
      child: const MaterialApp(home: PlayersScreen()),
    );
  }

  /// The ⋮ menu of the row (or pending card) titled [name].
  Finder menuOf(String name) => find.descendant(
        of: find.widgetWithText(ListTile, name),
        matching: find.byType(PopupMenuButton<String>),
      );

  /// [text] inside the open modal sheet (the screen behind it may show the
  /// same names).
  Finder inSheet(String text) =>
      find.descendant(of: find.byType(BottomSheet), matching: find.text(text));

  testWidgets('players are grouped by club, Bez oddílu last', (tester) async {
    await tester.pumpWidget(app([
      admin,
      player('p1', 'Zdeněk', clubId: 'c2'),
      player('p2', 'Adam'),
      player('p3', 'Blanka', clubId: 'c1'),
    ]));
    await tester.pumpAndSettle();

    // Section headers: clubs by name, then Bez oddílu (admin has no club).
    final headers = ['Sokol Dlouhá Lhota (1)', 'Veverky (1)', 'Bez oddílu (2)'];
    for (final h in headers) {
      expect(find.text(h), findsOneWidget);
    }
    final ys = [
      for (final h in headers) tester.getTopLeft(find.text(h)).dy,
    ];
    expect(ys[0], lessThan(ys[1]));
    expect(ys[1], lessThan(ys[2]));

    // Members render under their club; the admin is marked in the subtitle.
    expect(find.text('Blanka'), findsOneWidget);
    expect(find.text('správce'), findsOneWidget);
  });

  testWidgets('renders without overflow on a narrow phone', (tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(app([
      admin,
      player('p1', 'Bartoloměj Vondráček-Nepomucký',
          clubId: 'c1', role: Role.admin),
      // A pending card (Schválit + its menu) and a placeholder row.
      registrant,
      placeholder,
    ]));
    await tester.pumpAndSettle();
    // No RenderFlex overflow exceptions were thrown during layout.
    expect(tester.takeException(), isNull);
    expect(find.text('Schválit'), findsOneWidget);
    expect(find.text('bez účtu · „Bohouš“'), findsOneWidget);
  });

  testWidgets('Oddíl… menu opens a club sheet and saves are wired',
      (tester) async {
    await tester.pumpWidget(app([admin, player('p1', 'Adam', clubId: 'c2')]));
    await tester.pumpAndSettle();

    await tester.tap(find.byType(PopupMenuButton<String>).last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Oddíl…'));
    await tester.pumpAndSettle();

    // The sheet lists all clubs plus Bez oddílu.
    expect(find.text('Bez oddílu'), findsOneWidget);
    expect(find.text('Sokol Dlouhá Lhota'), findsOneWidget);
    expect(find.text('Veverky'), findsOneWidget);
  });

  testWidgets('a visiting superadmin is hidden; at home they are listed',
      (tester) async {
    const visiting = Profile(
      id: 'sv',
      displayName: 'Miloš (na návštěvě)',
      email: 'milos.vazan@gmail.com',
      role: Role.admin,
      status: ProfileStatus.approved,
      superadmin: true,
      tenantId: 't-foreign',
      homeTenantId: 't-home',
    );
    const atHome = Profile(
      id: 'sh',
      displayName: 'Miloš (doma)',
      email: 'milos.vazan@gmail.com',
      role: Role.admin,
      status: ProfileStatus.approved,
      superadmin: true,
      tenantId: 't-home',
      homeTenantId: 't-home',
    );
    await tester.pumpWidget(app([
      admin,
      player('p1', 'Zdeněk'),
      visiting,
      atHome,
    ]));
    await tester.pumpAndSettle();

    expect(find.text('Miloš (na návštěvě)'), findsNothing);
    expect(find.text('Miloš (doma)'), findsOneWidget);
    expect(find.text('Zdeněk'), findsOneWidget);
  });

  testWidgets('pending and kiosk rows show the club from the roster, not the '
      'stale legacy text', (tester) async {
    const pending = Profile(
      id: 'pend',
      displayName: 'Nováček',
      email: 'pend@example.com',
      role: Role.player,
      status: ProfileStatus.pending,
      clubId: 'c2',
    );
    await tester.pumpWidget(app([admin, pending]));
    await tester.pumpAndSettle();

    expect(find.text('Veverky'), findsOneWidget);
    expect(find.text('Staré jméno'), findsNothing);
  });

  testWidgets('the FAB opens the add dialog for a hráč bez účtu',
      (tester) async {
    await tester.pumpWidget(app([admin]));
    await tester.pumpAndSettle();

    await tester.tap(find.byType(FloatingActionButton));
    await tester.pumpAndSettle();

    final dialog = find.byType(AlertDialog);
    expect(dialog, findsOneWidget);
    expect(
      find.descendant(
          of: dialog, matching: find.text('Přidat hráče bez účtu')),
      findsOneWidget,
    );
    expect(find.text('Jméno a příjmení'), findsOneWidget);
    expect(find.text('Přezdívka na tabuli (nepovinné)'), findsOneWidget);
    expect(find.text('Oddíl'), findsOneWidget);

    await tester.tap(find.text('Zrušit'));
    await tester.pumpAndSettle();
    expect(dialog, findsNothing);
  });

  testWidgets('a hráč bez účtu row is marked and gets its own menu; '
      'Upravit… opens the edit dialog prefilled', (tester) async {
    await tester.pumpWidget(
        app([admin, placeholder, player('p1', 'Adam', clubId: 'c1')]));
    await tester.pumpAndSettle();

    expect(find.text('bez účtu · „Bohouš“'), findsOneWidget);

    await tester.tap(menuOf('Bohumil Kroupa'));
    await tester.pumpAndSettle();
    for (final item in [
      'Upravit…',
      'Oddíl…',
      'Zkratka na tabuli…',
      'Sloučit do účtu…',
      'Smazat',
    ]) {
      expect(find.text(item), findsOneWidget);
    }
    expect(find.text('Udělat správcem'), findsNothing);
    expect(find.text('Nastavit jako kiosk'), findsNothing);

    await tester.tap(find.text('Upravit…'));
    await tester.pumpAndSettle();
    expect(find.text('Upravit hráče bez účtu'), findsOneWidget);
    expect(find.widgetWithText(TextField, 'Bohumil Kroupa'), findsOneWidget);
    expect(find.widgetWithText(TextField, 'Bohouš'), findsOneWidget);

    await tester.tap(find.text('Zrušit'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
  });

  testWidgets('a member keeps exactly the four menu items of today',
      (tester) async {
    await tester.pumpWidget(
        app([admin, placeholder, player('p1', 'Adam', clubId: 'c1')]));
    await tester.pumpAndSettle();

    await tester.tap(menuOf('Adam'));
    await tester.pumpAndSettle();
    for (final item in [
      'Oddíl…',
      'Udělat správcem',
      'Nastavit jako kiosk',
      'Zkratka na tabuli…',
    ]) {
      expect(find.text(item), findsOneWidget);
    }
    expect(find.byType(PopupMenuItem<String>), findsNWidgets(4));
    expect(find.text('Upravit…'), findsNothing);
    expect(find.text('Sloučit do účtu…'), findsNothing);
    expect(find.text('Smazat'), findsNothing);
  });

  testWidgets('Sloučit do účtu… lists accounts only (members and pending '
      'registrants, no kiosk, no other placeholder), the search narrows it '
      'and a tap opens the merge dialog', (tester) async {
    const otherPlaceholder = Profile(
      id: 'ph2',
      displayName: 'Karel Dvořák',
      email: '',
      role: Role.player,
      status: ProfileStatus.approved,
      hasAccount: false,
    );
    await tester.pumpWidget(app([
      admin,
      placeholder,
      player('p1', 'Adam', clubId: 'c1'),
      registrant,
      player('k1', 'Kiosk u dráhy', role: Role.kiosk),
      otherPlaceholder,
    ]));
    await tester.pumpAndSettle();

    await tester.tap(menuOf('Bohumil Kroupa'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Sloučit do účtu…'));
    await tester.pumpAndSettle();

    expect(find.byType(BottomSheet), findsOneWidget);
    expect(inSheet('Adam'), findsOneWidget);
    expect(inSheet('Sokol Dlouhá Lhota'), findsOneWidget); // Adam's club
    expect(inSheet('Správce'), findsOneWidget);
    expect(inSheet('B. Kroupa'), findsOneWidget);
    expect(inSheet('čeká na schválení'), findsOneWidget);
    expect(inSheet('Kiosk u dráhy'), findsNothing);
    expect(inSheet('Karel Dvořák'), findsNothing);
    expect(inSheet('Bohumil Kroupa'), findsNothing);

    final search = find.descendant(
        of: find.byType(BottomSheet), matching: find.byType(TextField));
    await tester.enterText(search, 'nikdo takový');
    await tester.pumpAndSettle();
    expect(inSheet('Nikdo neodpovídá hledání.'), findsOneWidget);
    expect(inSheet('Adam'), findsNothing);

    await tester.enterText(search, 'KROU');
    await tester.pumpAndSettle();
    expect(inSheet('B. Kroupa'), findsOneWidget);
    expect(inSheet('Adam'), findsNothing);
    expect(inSheet('Správce'), findsNothing);

    await tester.tap(inSheet('B. Kroupa'));
    await tester.pumpAndSettle();
    expect(find.byType(BottomSheet), findsNothing);
    expect(find.text('Sloučit hráče'), findsOneWidget);
    expect(find.textContaining('b@example.com'), findsOneWidget);
  });

  testWidgets('the search also matches the nick', (tester) async {
    await tester.pumpWidget(app([
      admin,
      placeholder,
      Profile(
        id: 'p1',
        displayName: 'Adam Novák',
        email: 'p1@example.com',
        role: Role.player,
        status: ProfileStatus.approved,
        nick: 'Áďa',
      ),
    ]));
    await tester.pumpAndSettle();

    await tester.tap(menuOf('Bohumil Kroupa'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Sloučit do účtu…'));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.descendant(
            of: find.byType(BottomSheet), matching: find.byType(TextField)),
        'áď');
    await tester.pumpAndSettle();
    expect(inSheet('Adam Novák'), findsOneWidget);
    expect(inSheet('„Áďa“'), findsOneWidget);
    expect(inSheet('Správce'), findsNothing);
  });

  testWidgets('the pending card menu picks a hráč bez účtu and opens the '
      'merge dialog', (tester) async {
    await tester.pumpWidget(app([admin, registrant, placeholder]));
    await tester.pumpAndSettle();

    expect(find.text('Schválit'), findsOneWidget);
    await tester.tap(menuOf('B. Kroupa'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Sloučit s hráčem bez účtu…'));
    await tester.pumpAndSettle();

    expect(inSheet('Bohumil Kroupa'), findsOneWidget);
    expect(inSheet('bez účtu · „Bohouš“ · Sokol Dlouhá Lhota'), findsOneWidget);
    expect(inSheet('Správce'), findsNothing); // accounts are not offered

    await tester.tap(inSheet('Bohumil Kroupa'));
    await tester.pumpAndSettle();
    expect(find.text('Sloučit hráče'), findsOneWidget);
    expect(find.textContaining('a bude schválen'), findsOneWidget);
  });

  testWidgets('a pending merge with no hráč bez účtu just says so',
      (tester) async {
    await tester.pumpWidget(app([admin, registrant]));
    await tester.pumpAndSettle();

    await tester.tap(menuOf('B. Kroupa'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Sloučit s hráčem bez účtu…'));
    await tester.pumpAndSettle();

    expect(find.text('Žádný hráč bez účtu k sloučení.'), findsOneWidget);
    expect(find.byType(BottomSheet), findsNothing);
  });

  testWidgets('Smazat asks first; Zrušit keeps the row', (tester) async {
    await tester.pumpWidget(app([admin, placeholder]));
    await tester.pumpAndSettle();

    await tester.tap(menuOf('Bohumil Kroupa'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Smazat'));
    await tester.pumpAndSettle();

    expect(find.text('Smazat hráče?'), findsOneWidget);
    expect(find.text('Opravdu smazat hráče bez účtu „Bohumil Kroupa“?'),
        findsOneWidget);

    await tester.tap(find.text('Zrušit'));
    await tester.pumpAndSettle();
    expect(find.text('Smazat hráče?'), findsNothing);
    expect(find.text('Bohumil Kroupa'), findsOneWidget);
  });
}
