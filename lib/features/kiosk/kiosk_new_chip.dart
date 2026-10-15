/// „NOVÉ“ before the title of a fresh notice on the kiosk (0080): one
/// that went up less than the admin's few days ago, while the admin has
/// fresh notices highlighted. The same chip in the status bar and in the
/// panel's card.
library;

import 'package:flutter/material.dart';

class KioskNewChip extends StatelessWidget {
  const KioskNewChip({super.key});

  static const label = 'NOVÉ';

  /// The chip's text without its colour — what the panel's card measures
  /// the title beside it with.
  static const textStyle = TextStyle(
    fontSize: 11,
    fontWeight: FontWeight.w800,
    letterSpacing: 0.4,
  );

  static const padding = EdgeInsets.symmetric(horizontal: 6, vertical: 2);

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: padding,
      decoration: BoxDecoration(
        color: scheme.primary,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        label,
        maxLines: 1,
        style: textStyle.copyWith(color: scheme.onPrimary),
      ),
    );
  }
}
