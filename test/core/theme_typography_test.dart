import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rezervator/core/theme.dart';

/// The app's typeface has to survive every hop between a theme and a glyph.
/// Most widgets merge their style with the ambient one and keep the family
/// for free; a BUTTON does not — it hands its resolved textStyle to
/// `Material(textStyle:)`, which replaces the DefaultTextStyle wholesale, so
/// a style naming only a weight silently falls back to the platform font.
/// Every „Uložit" in the app was Roboto inside a Manrope dialog.
void main() {
  for (final brightness in [Brightness.light, Brightness.dark]) {
    group(brightness.name, () {
      final theme = buildTheme(brightness);

      test('the filled button keeps the app font, and its weight', () {
        final style = theme.filledButtonTheme.style?.textStyle?.resolve({});
        expect(style, isNotNull);
        expect(style!.fontFamily, appFontFamily);
        expect(style.fontWeight, FontWeight.w700);
      });

      test('the theme itself is set in it too', () {
        expect(theme.textTheme.bodyMedium?.fontFamily, appFontFamily);
        expect(theme.textTheme.labelLarge?.fontFamily, appFontFamily);
      });

      // Any other button theme that pins a textStyle has to name the family
      // as well — same replacement, same fallback.
      test('no button theme pins a style without the family', () {
        final styles = <String, TextStyle?>{
          'filled': theme.filledButtonTheme.style?.textStyle?.resolve({}),
          'outlined': theme.outlinedButtonTheme.style?.textStyle?.resolve({}),
          'text': theme.textButtonTheme.style?.textStyle?.resolve({}),
          'elevated': theme.elevatedButtonTheme.style?.textStyle?.resolve({}),
        };
        styles.forEach((which, style) {
          if (style == null) return; // inherits the theme's own label style
          expect(style.fontFamily, appFontFamily,
              reason: '$which button would fall back to the platform font');
        });
      });
    });
  }
}
