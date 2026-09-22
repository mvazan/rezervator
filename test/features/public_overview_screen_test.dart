import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rezervator/data/providers.dart';
import 'package:rezervator/domain/models.dart';
import 'package:rezervator/domain/public_week.dart';
import 'package:rezervator/features/admin/public_overview_screen.dart';

void main() {
  const admin = Profile(
    id: 'a',
    displayName: 'Správce',
    email: 'a@example.com',
    role: Role.admin,
    status: ProfileStatus.approved,
  );

  Widget app(
    PublicOverview overview, {
    Future<void> Function(String, bool)? save,
  }) =>
      ProviderScope(
        overrides: [
          myProfileProvider.overrideWith((ref) => Stream.value(admin)),
          publicOverviewProvider.overrideWith((ref) async => overview),
        ],
        child: MaterialApp(
          home: PublicOverviewScreen(save: save ?? (_, _) async {}),
        ),
      );

  Finder link(String url) => find.byWidgetPredicate(
      (w) => w is SelectableText && w.data == url);

  testWidgets('no slug yet: suggests one from the name, off, no link', (tester) async {
    await tester.pumpWidget(app(const PublicOverview(
        slug: null, enabled: false, tenantName: 'Kuželna Sokol')));
    await tester.pumpAndSettle();

    expect(find.text('Veřejný přehled'), findsOneWidget);
    expect(find.widgetWithText(TextField, 'kuzelna-sokol'), findsOneWidget);
    expect(tester.widget<SwitchListTile>(find.byType(SwitchListTile)).value, isFalse);
    expect(find.text('Odkaz na přehled'), findsNothing);
  });

  testWidgets('published: shows the link to copy', (tester) async {
    await tester.pumpWidget(app(const PublicOverview(
        slug: 'sokol', enabled: true, tenantName: 'Kuželna Sokol')));
    await tester.pumpAndSettle();

    expect(find.widgetWithText(TextField, 'sokol'), findsOneWidget);
    expect(link('https://rezervator.online/#/prehled/sokol'), findsOneWidget);
    expect(find.byTooltip('Kopírovat adresu'), findsOneWidget);
  });

  testWidgets('Uložit sends the typed slug and the switch', (tester) async {
    final calls = <(String, bool)>[];
    await tester.pumpWidget(app(
      const PublicOverview(slug: null, enabled: false, tenantName: 'Kuželna Sokol'),
      save: (slug, enabled) async => calls.add((slug, enabled)),
    ));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), '  Muj-Slug ');
    await tester.tap(find.byType(SwitchListTile));
    await tester.pump();
    await tester.tap(find.text('Uložit'));
    await tester.pumpAndSettle();

    expect(calls, [('muj-slug', true)]);
    expect(find.text('Uloženo.'), findsOneWidget);
  });

  testWidgets('a taken slug says so', (tester) async {
    await tester.pumpWidget(app(
      const PublicOverview(slug: null, enabled: false, tenantName: 'Kuželna Sokol'),
      save: (_, _) async => throw Exception('slug_taken'),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Uložit'));
    await tester.pumpAndSettle();
    expect(find.text('Tuhle adresu už má jiná kuželna.'), findsOneWidget);
  });
}
