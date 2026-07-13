/// App-wide Material 3 theme for the "Noční liga" redesign: indigo `#6366F1`
/// seed with a cyan `#22D3EE` secondary/tertiary family, Manrope typography,
/// and a slate surface ramp for dark mode.
library;

import 'package:flutter/material.dart';

/// Builds the light or dark [ThemeData] for [brightness].
ThemeData buildTheme(Brightness brightness) {
  final isDark = brightness == Brightness.dark;

  var scheme = ColorScheme.fromSeed(
    seedColor: const Color(0xFF6366F1),
    brightness: brightness,
  );

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

  final textTheme = _textTheme(scheme);

  return ThemeData(
    colorScheme: scheme,
    useMaterial3: true,
    fontFamily: 'Manrope',
    textTheme: textTheme,
    scaffoldBackgroundColor: scheme.surfaceContainerLowest,
    appBarTheme: AppBarTheme(
      backgroundColor: scheme.surfaceContainerLowest,
      elevation: 0,
      scrolledUnderElevation: 0,
      titleTextStyle: textTheme.titleLarge?.copyWith(color: scheme.onSurface),
    ),
    cardTheme: isDark
        ? CardThemeData(
            elevation: 0,
            color: scheme.surfaceContainer,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
              side: BorderSide(color: scheme.outlineVariant),
            ),
            margin: const EdgeInsets.symmetric(vertical: 6),
          )
        : CardThemeData(
            elevation: 2,
            color: scheme.surfaceContainer,
            shadowColor: const Color(0x1A6366F1),
            surfaceTintColor: Colors.transparent,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
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
        textStyle: const TextStyle(fontWeight: FontWeight.w700),
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
  );
}

TextTheme _textTheme(ColorScheme scheme) {
  const base = TextTheme();
  return base.copyWith(
    displayLarge:
        base.displayLarge?.copyWith(fontWeight: FontWeight.w800),
    displayMedium:
        base.displayMedium?.copyWith(fontWeight: FontWeight.w800),
    displaySmall:
        base.displaySmall?.copyWith(fontWeight: FontWeight.w800),
    headlineLarge:
        base.headlineLarge?.copyWith(fontWeight: FontWeight.w800),
    headlineMedium:
        base.headlineMedium?.copyWith(fontWeight: FontWeight.w800),
    headlineSmall:
        base.headlineSmall?.copyWith(fontWeight: FontWeight.w800),
    titleLarge: base.titleLarge?.copyWith(fontWeight: FontWeight.w800),
    titleMedium: base.titleMedium?.copyWith(fontWeight: FontWeight.w700),
    titleSmall: base.titleSmall?.copyWith(fontWeight: FontWeight.w700),
    bodyLarge: base.bodyLarge?.copyWith(fontWeight: FontWeight.w400),
    bodyMedium: base.bodyMedium?.copyWith(fontWeight: FontWeight.w400),
    bodySmall: base.bodySmall?.copyWith(fontWeight: FontWeight.w400),
    labelLarge: base.labelLarge?.copyWith(fontWeight: FontWeight.w700),
    labelMedium: base.labelMedium?.copyWith(fontWeight: FontWeight.w500),
    labelSmall: base.labelSmall?.copyWith(fontWeight: FontWeight.w500),
  );
}
