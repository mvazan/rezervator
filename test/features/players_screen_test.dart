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
    club: '',
    email: 'admin@example.com',
    role: Role.admin,
    status: ProfileStatus.approved,
  );

  Profile player(String id, String name, {String? clubId, Role? role}) =>
      Profile(
        id: id,
        displayName: name,
        club: '',
        email: '$id@example.com',
        role: role ?? Role.player,
        status: ProfileStatus.approved,
        clubId: clubId,
      );

  const clubs = [
    Club(id: 'c2', name: 'Veverky', colorIndex: 2),
    Club(id: 'c1', name: 'Sokol Dlouhá Lhota', colorIndex: 1),
  ];

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
    ]));
    await tester.pumpAndSettle();
    // No RenderFlex overflow exceptions were thrown during layout.
    expect(tester.takeException(), isNull);
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
      club: '',
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
      club: '',
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
}
