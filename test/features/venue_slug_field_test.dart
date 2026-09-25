import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rezervator/core/theme.dart';
import 'package:rezervator/domain/models.dart';
import 'package:rezervator/features/admin/widgets/federation_wizard.dart';
import 'package:rezervator/features/admin/widgets/venue_slug_field.dart';

/// The app's own font: the test font's glyphs are wider than Manrope's, so
/// line counts measured against it would not be the phone's.
Future<void> _loadManrope() async {
  final loader = FontLoader(appFontFamily);
  for (final weight in ['Regular', 'Medium', 'Bold', 'ExtraBold']) {
    final bytes = File('assets/fonts/Manrope-$weight.ttf').readAsBytesSync();
    loader.addFont(Future.value(ByteData.view(bytes.buffer)));
  }
  await loader.load();
}

const _notVenue =
    'Tohle není adresa kuželny — zkopíruj adresu stránky, která '
    'obsahuje /detail-kuzelny/.';

/// A phone [width] dp wide at text [scale] (the app caps system × Settings
/// at 2.0, see core/text_size.dart), in the app's theme.
Future<void> _phone(
  WidgetTester tester,
  double width,
  double scale,
  Widget home,
) async {
  tester.view.physicalSize = Size(width, 800);
  tester.view.devicePixelRatio = 1.0;
  tester.platformDispatcher.textScaleFactorTestValue = scale;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  await tester.pumpWidget(
    MaterialApp(theme: buildTheme(Brightness.light), home: home),
  );
}

/// The inline error, whole: its last words („/detail-kuzelny/.“) are the
/// hint the admin needs.
void _expectWhole(WidgetTester tester) {
  final error = tester.renderObject<RenderParagraph>(find.text(_notVenue));
  expect(
    error.didExceedMaxLines,
    isFalse,
    reason: 'the error is cut at ${error.maxLines} lines',
  );
}

void main() {
  setUpAll(_loadManrope);

  for (final (width, scale) in [
    (360.0, 1.0),
    (360.0, 1.3),
    (360.0, 2.0),
    (320.0, 2.0),
  ]) {
    testWidgets('„Změnit kuželnu“ shows the whole error, $width dp at text '
        'scale $scale', (tester) async {
      await _phone(
        tester,
        width,
        scale,
        Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showDialog<bool>(
                context: context,
                builder: (_) => VenueSlugDialog(
                  initial: 'tj-sokol-brno-iv',
                  save: (_) async {},
                ),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byType(TextField),
        'https://vysledky.kuzelky.cz/detail-klubu/ks-devitka-brno',
      );
      await tester.tap(find.text('Uložit'));
      await tester.pumpAndSettle();

      _expectWhole(tester);
    });

    testWidgets('the wizard\'s step 1 shows the whole error, $width dp at '
        'text scale $scale', (tester) async {
      await _phone(
        tester,
        width,
        scale,
        Scaffold(
          body: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: FederationWizard(
                  sync: FederationSync.none,
                  teams: const [],
                  discovering: false,
                  saveSlug: (_) async => true,
                  discover: () async => true,
                  enable: () async => true,
                ),
              ),
            ),
          ),
        ),
      );
      await tester.enterText(
        find.byType(TextField),
        'https://vysledky.kuzelky.cz/detail-klubu/ks-devitka-brno',
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Pokračovat'));
      await tester.pumpAndSettle();

      _expectWhole(tester);
    });
  }
}
