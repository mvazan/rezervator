import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rezervator/core/text_size.dart';
import 'package:rezervator/core/theme.dart';

/// The app's typeface has to survive every hop between a theme and a glyph.
///
/// Two traps live on that road. A BUTTON hands its resolved textStyle to
/// `Material(textStyle:)`, which replaces the ambient DefaultTextStyle
/// wholesale — a style naming only a weight silently falls back to the
/// platform font (every „Uložit" was Roboto inside a Manrope dialog). And a
/// TextTheme copied onto `const TextTheme()`, whose styles are all null,
/// stays null: the weights this app asks for did nothing at all until they
/// were stated outright.
void main() {
  /// The weights Material's own text theme is asked to take on. Sizes,
  /// letter spacing and colour deliberately stay Material's — see the
  /// scaling test at the bottom.
  const wanted = <String, FontWeight>{
    'displayLarge': FontWeight.w800,
    'displayMedium': FontWeight.w800,
    'displaySmall': FontWeight.w800,
    'headlineLarge': FontWeight.w800,
    'headlineMedium': FontWeight.w800,
    'headlineSmall': FontWeight.w800,
    'titleLarge': FontWeight.w800,
    'titleMedium': FontWeight.w700,
    'titleSmall': FontWeight.w700,
    'bodyLarge': FontWeight.w400,
    'bodyMedium': FontWeight.w400,
    'bodySmall': FontWeight.w400,
    'labelLarge': FontWeight.w700,
    'labelMedium': FontWeight.w500,
    'labelSmall': FontWeight.w500,
  };

  TextStyle? styleOf(TextTheme t, String role) => switch (role) {
        'displayLarge' => t.displayLarge,
        'displayMedium' => t.displayMedium,
        'displaySmall' => t.displaySmall,
        'headlineLarge' => t.headlineLarge,
        'headlineMedium' => t.headlineMedium,
        'headlineSmall' => t.headlineSmall,
        'titleLarge' => t.titleLarge,
        'titleMedium' => t.titleMedium,
        'titleSmall' => t.titleSmall,
        'bodyLarge' => t.bodyLarge,
        'bodyMedium' => t.bodyMedium,
        'bodySmall' => t.bodySmall,
        'labelLarge' => t.labelLarge,
        'labelMedium' => t.labelMedium,
        _ => t.labelSmall,
      };

  /// The text theme as a WIDGET sees it: sizes reach a TextTheme only once
  /// `Theme` has merged Material's locale-dependent geometry into it, so
  /// asking `buildTheme(...)` directly would find them null.
  Future<TextTheme> localized(WidgetTester tester, Brightness brightness) async {
    late TextTheme resolved;
    await tester.pumpWidget(MaterialApp(
      theme: buildTheme(brightness),
      home: Builder(builder: (context) {
        resolved = Theme.of(context).textTheme;
        return const SizedBox.shrink();
      }),
    ));
    return resolved;
  }

  for (final brightness in [Brightness.light, Brightness.dark]) {
    group(brightness.name, () {
      testWidgets('every role carries its weight, its font and a size',
          (tester) async {
        final theme = await localized(tester, brightness);
        wanted.forEach((role, weight) {
          final style = styleOf(theme, role);
          expect(style?.fontWeight, weight, reason: '$role weight');
          expect(style?.fontFamily, appFontFamily, reason: '$role font');
          expect(style?.fontSize, isNotNull,
              reason: '$role must keep Material\'s size — the user\'s '
                  'text-size choice scales that, and there is nothing to '
                  'scale without it');
        });
      });

      test('the filled button keeps the app font, and its weight', () {
        final style = buildTheme(brightness)
            .filledButtonTheme
            .style
            ?.textStyle
            ?.resolve({});
        expect(style, isNotNull);
        expect(style!.fontFamily, appFontFamily);
        expect(style.fontWeight, FontWeight.w700);
      });

      // Any other button theme that pins a textStyle has to name the family
      // as well — same replacement, same fallback.
      test('no button theme pins a style without the family', () {
        final theme = buildTheme(brightness);
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

      // An AppBar title style pinned in the theme would replace Material's
      // own — and one built from the weights above carries no size or
      // family, so the title would come out small and in the wrong font.
      test('the app bar tints its title instead of restyling it', () {
        final bar = buildTheme(brightness).appBarTheme;
        expect(bar.titleTextStyle, isNull);
        expect(bar.foregroundColor, isNotNull);
      });
    });
  }

  test('every weight asked for is a font the app actually bundles', () {
    // A weight with no file behind it is synthesised by the engine, which
    // looks like a smeared version of the real thing.
    final bundled = <int>{
      for (final line in File('pubspec.yaml').readAsLinesSync())
        if (RegExp(r'^\s+weight:\s*(\d+)\s*$').firstMatch(line)
            case final m?)
          int.parse(m.group(1)!),
    };
    expect(bundled, isNotEmpty, reason: 'pubspec declares no font weights');
    for (final weight in wanted.values.toSet()) {
      expect(bundled, contains(weight.value),
          reason: 'no Manrope file for ${weight.value}');
    }
  });

  // The question the weights raise: do they get in the way of the text-size
  // choice in Můj profil? They cannot — a weight is one axis, the size
  // another, and the choice is a TextScaler applied to whatever size the
  // style ends up with. Measured rather than argued.
  testWidgets('the text-size choice still scales the same sizes',
      (tester) async {
    for (final choice in TextSizeChoice.values) {
      late double size;
      late FontWeight? weight;
      await tester.pumpWidget(MaterialApp(
        theme: buildTheme(Brightness.light),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            textScaler: AppTextScaler(TextScaler.noScaling, choice),
          ),
          child: child!,
        ),
        home: Builder(builder: (context) {
          final style = Theme.of(context).textTheme.bodyMedium!;
          weight = style.fontWeight;
          size = MediaQuery.textScalerOf(context).scale(style.fontSize!);
          return const SizedBox.shrink();
        }),
      ));
      expect(size, closeTo(14 * textSizeFactor(choice), 0.01),
          reason: '${choice.name} scales Material\'s 14');
      expect(weight, FontWeight.w400, reason: 'the weight does not move');
    }
  });
}
