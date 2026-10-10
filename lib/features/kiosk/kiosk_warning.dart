/// The admin's warning in the kiosk's status bar (0068): a warning icon and
/// the text from Správa → Kiosk → Obrazovka kiosku → Upozornění, on the
/// error container so it reads as a warning in both kiosk themes. Alone in
/// the bar's middle while it hangs (the shell hides the rest), centred.
library;

import 'package:flutter/material.dart';

class KioskWarning extends StatelessWidget {
  const KioskWarning({super.key, required this.text});

  final String text;

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
                size: 32,
                color: scheme.onErrorContainer,
              ),
              const SizedBox(width: 10),
              Flexible(
                child: Text(
                  text,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                    color: scheme.onErrorContainer,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
