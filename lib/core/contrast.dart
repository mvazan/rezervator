/// WCAG contrast ratios — used by the contrast test
/// (test/core/theme_contrast_test.dart) to prove every appearance variant
/// stays legible, rather than relying on eyeballing it.
library;

import 'dart:math' as math;
import 'dart:ui';

/// Relative luminance per WCAG 2.1 (sRGB, gamma-corrected).
double relativeLuminance(Color c) {
  double channel(double v) =>
      v <= 0.03928 ? v / 12.92 : math.pow((v + 0.055) / 1.055, 2.4).toDouble();
  return 0.2126 * channel(c.r) + 0.7152 * channel(c.g) + 0.0722 * channel(c.b);
}

/// Contrast ratio between two OPAQUE colors: 1.0 (identical) to 21.0
/// (black/white). AA wants 4.5 for normal text, 3.0 for large text and UI
/// elements/shapes.
double contrastRatio(Color a, Color b) {
  final la = relativeLuminance(a);
  final lb = relativeLuminance(b);
  final (hi, lo) = la > lb ? (la, lb) : (lb, la);
  return (hi + 0.05) / (lo + 0.05);
}
