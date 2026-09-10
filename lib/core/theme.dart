/// App-wide Material 3 theme for the "Noční liga" redesign: indigo `#6366F1`
/// seed with a cyan `#22D3EE` secondary/tertiary family, Manrope typography,
/// and a slate surface ramp for dark mode.
library;

import 'package:flutter/material.dart';

/// The brand gradient (indigo → cyan) used for "today" headers, the selected
/// day chip, the primary kiosk button and the name picker's back tile.
const brandGradientColors = [Color(0xFF6366F1), Color(0xFF22D3EE)];

/// Threads the [buildTheme] call's `contrastLevel` down to widgets that pick
/// a translucent container tint (see [containerTint]) — `ColorScheme` does
/// not expose back the level it was built at, so this is how a call site
/// far from `main.dart` knows whether it's rendering a high-contrast variant
/// without re-deriving that from scratch. Read via
/// `Theme.of(context).extension<ContrastLevel>()`.
class ContrastLevel extends ThemeExtension<ContrastLevel> {
  const ContrastLevel(this.value);

  final double value;

  @override
  ContrastLevel copyWith({double? value}) =>
      ContrastLevel(value ?? this.value);

  @override
  ContrastLevel lerp(ThemeExtension<ContrastLevel>? other, double t) {
    if (other is! ContrastLevel) return this;
    return ContrastLevel(value + (other.value - value) * t);
  }
}

/// A translucent container fill and its matching foreground, safe at every
/// contrast level. At normal contrast ([contrastLevel] 0) this is
/// [container] washed toward the page at [alpha] — the soft pastel pill/band
/// look call sites want. At `contrastLevel == 1`, `ColorScheme.fromSeed`
/// already tunes [onContainer] against the FULL-strength [container] to hit
/// Material's own high-contrast target; washing the fill toward the page
/// with [alpha] would pull it away from that pairing and silently drop the
/// rendered ratio below AA (see theme_contrast_test.dart, which measures
/// exactly this against the composited fill). So at contrastLevel 1 this
/// keeps [container] at full strength instead of applying [alpha] — the one
/// place that decision gets made, rather than each call site guessing.
(Color fill, Color foreground) containerTint({
  required Color container,
  required Color onContainer,
  required double alpha,
  required double contrastLevel,
}) =>
    contrastLevel == 0
        ? (container.withValues(alpha: alpha), onContainer)
        : (container, onContainer);

/// The app's typeface, bundled in assets/fonts. Named once because it has
/// to be repeated wherever a widget REPLACES the ambient text style rather
/// than merging with it (buttons — see filledButtonTheme below).
const appFontFamily = 'Manrope';

/// Builds the light or dark [ThemeData] for [brightness]. [contrastLevel]
/// feeds `ColorScheme.fromSeed` (0 = normal, 1 = Material's own maximum
/// contrast) for the high-contrast appearance choices.
ThemeData buildTheme(Brightness brightness, {double contrastLevel = 0}) {
  final isDark = brightness == Brightness.dark;

  var scheme = ColorScheme.fromSeed(
    seedColor: const Color(0xFF6366F1),
    brightness: brightness,
    contrastLevel: contrastLevel,
  );

  // The hand-picked "Noční liga" ramp below applies ONLY at normal contrast.
  // It overrides dozens of ColorScheme roles with fixed hex values that were
  // tuned against each other, not against a target contrast level — so
  // layering them on top of a high-contrast fromSeed scheme would silently
  // throw away Material's own high-contrast guarantees. The contrast variants
  // instead keep fromSeed's contrastLevel-driven scheme untouched (same seed,
  // so the hues still match the brand). See theme_contrast_test.dart, which
  // is what actually proves this rather than eyeballing it.
  if (contrastLevel == 0) {
    scheme = isDark
        ? scheme.copyWith(
            secondary: const Color(0xFF67E8F9),
            onSecondary: const Color(0xFF083344),
            secondaryContainer: const Color(0xFF155E63),
            onSecondaryContainer: const Color(0xFFCFFAFE),
            tertiary: const Color(0xFF5EEAD4),
            onTertiary: const Color(0xFF042F2E),
            tertiaryContainer: const Color(0xFF115E59),
            onTertiaryContainer: const Color(0xFFCCFBF1),
            error: const Color(0xFFFDA4AF),
            onError: const Color(0xFF4C0519),
            errorContainer: const Color(0xFF9F1239),
            onErrorContainer: const Color(0xFFFFE4E6),
            surface: const Color(0xFF0F172A),
            surfaceContainerLowest: const Color(0xFF0B1120),
            surfaceContainerLow: const Color(0xFF141D2E),
            surfaceContainer: const Color(0xFF1E293B),
            surfaceContainerHigh: const Color(0xFF283548),
            surfaceContainerHighest: const Color(0xFF334155),
            outlineVariant: const Color(0xFF334155),
          )
        : scheme.copyWith(
            secondary: const Color(0xFF0E7490),
            onSecondary: const Color(0xFFFFFFFF),
            secondaryContainer: const Color(0xFFCFFAFE),
            onSecondaryContainer: const Color(0xFF164E63),
            tertiary: const Color(0xFF0F766E),
            onTertiary: const Color(0xFFFFFFFF),
            tertiaryContainer: const Color(0xFFCCFBF1),
            onTertiaryContainer: const Color(0xFF134E4A),
            error: const Color(0xFFE11D48),
            onError: const Color(0xFFFFFFFF),
            errorContainer: const Color(0xFFFFE4E6),
            onErrorContainer: const Color(0xFF881337),
          );
  }

  return ThemeData(
    colorScheme: scheme,
    useMaterial3: true,
    fontFamily: appFontFamily,
    textTheme: _textTheme,
    scaffoldBackgroundColor: scheme.surfaceContainerLowest,
    appBarTheme: AppBarTheme(
      backgroundColor: scheme.surfaceContainerLowest,
      elevation: 0,
      scrolledUnderElevation: 0,
      // Colour only. Pinning titleTextStyle here would REPLACE Material's
      // own title style — and a style built from the weights above carries
      // no size or family, so the title would come out small and in the
      // platform font (the trap filledButtonTheme fell into below).
      foregroundColor: scheme.onSurface,
    ),
    // Both use `outline`, not the `outlineVariant` every divider/chip border
    // in this theme otherwise uses: `outlineVariant` is a low-emphasis role
    // that measures only ~1.7:1 (light) / ~1.8:1 (dark) against the scaffold
    // background here, well under the 3:1 shape bar (see
    // theme_contrast_test.dart) — fine for a subtle divider, not enough to
    // make a card's edge actually visible. `outline` is the role Material
    // tunes to read against the page at every contrast level.
    cardTheme: isDark
        ? CardThemeData(
            elevation: 0,
            color: scheme.surfaceContainer,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
              side: BorderSide(color: scheme.outline),
            ),
            margin: const EdgeInsets.symmetric(vertical: 6),
          )
        : CardThemeData(
            elevation: 2,
            color: scheme.surfaceContainer,
            shadowColor: const Color(0x1A6366F1),
            surfaceTintColor: Colors.transparent,
            // A border, not just the shadow: surfaceContainer sits only
            // ~1.2:1 from the scaffold background (neighbouring tones in
            // the same ramp), so without an edge the card all but
            // disappears against the page.
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
              side: BorderSide(color: scheme.outline),
            ),
            margin: const EdgeInsets.symmetric(vertical: 6),
          ),
    inputDecorationTheme: InputDecorationTheme(
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
      filled: true,
      fillColor: scheme.surfaceContainer,
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
        shape:
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        // The family has to be repeated here. A button hands its resolved
        // textStyle to `Material(textStyle:)`, which REPLACES the ambient
        // DefaultTextStyle instead of merging with it — so a style that
        // names only a weight loses the app's font, and every Uložit was
        // being drawn in the platform's default (Roboto) while the dialog
        // around it was Manrope.
        textStyle: const TextStyle(
          fontFamily: appFontFamily,
          fontWeight: FontWeight.w700,
        ),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        shape:
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    ),
    chipTheme: ChipThemeData(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      side: BorderSide(color: scheme.outlineVariant),
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: scheme.surfaceContainerLowest,
      indicatorColor: scheme.primaryContainer,
    ),
    dialogTheme: DialogThemeData(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
    ),
    snackBarTheme: const SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(12)),
      ),
    ),
    dividerTheme: DividerThemeData(
      color: scheme.outlineVariant.withValues(alpha: 0.4),
    ),
    extensions: [ContrastLevel(contrastLevel)],
  );
}

/// The weights the design asks for — and NOTHING else. Material merges this
/// over its own text theme (`defaultTextTheme.merge(textTheme)`), so every
/// size, letter spacing and colour still comes from there, and with the
/// sizes comes the user's text-size choice: that is a [TextScaler] applied
/// to whatever size a style ends up with (core/text_size.dart), a different
/// axis from weight, so the two never fight.
///
/// This used to be built by copying onto `const TextTheme()`, whose styles
/// are all null — `base.titleLarge?.copyWith(…)` is null, `copyWith` keeps
/// null, and the whole thing quietly did nothing for as long as it existed.
/// Stating the styles outright is both shorter and the only version that
/// works.
///
/// Every weight here has a Manrope file behind it (400/500/700/800, see
/// pubspec.yaml); asking for one that is not bundled makes Flutter
/// synthesise it, which looks like a smeared version of the real thing.
const _textTheme = TextTheme(
  displayLarge: TextStyle(fontWeight: FontWeight.w800),
  displayMedium: TextStyle(fontWeight: FontWeight.w800),
  displaySmall: TextStyle(fontWeight: FontWeight.w800),
  headlineLarge: TextStyle(fontWeight: FontWeight.w800),
  headlineMedium: TextStyle(fontWeight: FontWeight.w800),
  headlineSmall: TextStyle(fontWeight: FontWeight.w800),
  titleLarge: TextStyle(fontWeight: FontWeight.w800),
  titleMedium: TextStyle(fontWeight: FontWeight.w700),
  titleSmall: TextStyle(fontWeight: FontWeight.w700),
  bodyLarge: TextStyle(fontWeight: FontWeight.w400),
  bodyMedium: TextStyle(fontWeight: FontWeight.w400),
  bodySmall: TextStyle(fontWeight: FontWeight.w400),
  labelLarge: TextStyle(fontWeight: FontWeight.w700),
  labelMedium: TextStyle(fontWeight: FontWeight.w500),
  labelSmall: TextStyle(fontWeight: FontWeight.w500),
);
