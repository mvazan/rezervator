/// The admin's warning in the kiosk's status bar (0068): a warning icon and
/// the text from Správa → Kiosk → Obrazovka kiosku → Upozornění, on the
/// error container so it reads as a warning in both kiosk themes. Alone in
/// the bar's middle while it hangs (the shell hides the rest), centred.
/// The name picker shows the admin's booking note (0070) the same way,
/// with more lines to spare.
///
/// Both are one type of text, [kioskWarningStyle], in the one size the
/// admin sets (0075) — by default the size of the picker's own hint, so
/// the note under the letters never reads smaller than the line above them.
library;

import 'package:flutter/material.dart';

/// The size of the kiosk's red notices unless the admin says otherwise
/// (0075): the picker hint's titleLarge.
const kioskWarningDefaultFontSize = 22.0;

/// The kiosk's red-notice text: bold, on the error container's foreground,
/// at [size] px.
TextStyle kioskWarningStyle(ColorScheme scheme, double size) => TextStyle(
  fontSize: size,
  fontWeight: FontWeight.w700,
  color: scheme.onErrorContainer,
);

class KioskWarning extends StatelessWidget {
  const KioskWarning({
    super.key,
    required this.text,
    this.maxLines = 2,
    this.fontSize = kioskWarningDefaultFontSize,
  });

  final String text;

  /// The most lines before an ellipsis: two in the status bar.
  final int maxLines;

  /// The admin's size for the notices (0075).
  final double fontSize;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      label: 'Upozornění: $text',
      excludeSemantics: true,
      child: Align(
        alignment: Alignment.center,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: scheme.errorContainer,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.warning_amber_rounded,
                // As tall as a line and a half of the text: 32 at 20 px.
                size: fontSize * 1.6,
                color: scheme.onErrorContainer,
              ),
              const SizedBox(width: 10),
              Flexible(
                child: Text(
                  text,
                  maxLines: maxLines,
                  overflow: TextOverflow.ellipsis,
                  style: kioskWarningStyle(scheme, fontSize),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
