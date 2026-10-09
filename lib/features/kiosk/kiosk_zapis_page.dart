/// The kiosk's „Zápis“: one match's score sheet ([ZapisPage]) in a modal. A
/// tap anywhere counts as touching the kiosk (the shell's idle timer is
/// outside this route), and the idle reset closes it.
library;

import 'package:flutter/material.dart';

import '../../core/theme.dart';
import '../../domain/models.dart';
import '../clubhouse/widgets/zapis_page.dart';

/// Opens [slot]'s Zápis in a modal covering [percent] of the screen, fading
/// in (no slide); a tap outside closes it. At 100 % there is no outside, so
/// a close button appears. [onTouch] is the shell's „somebody touched the
/// kiosk“.
Future<void> showKioskZapis(
  BuildContext context, {
  required PrioritySlot slot,
  required Brightness brightness,
  required int percent,
  required VoidCallback onTouch,
}) {
  return showGeneralDialog<void>(
    context: context,
    barrierDismissible: true,
    barrierLabel: 'Zavřít',
    barrierColor: Colors.black54,
    transitionDuration: const Duration(milliseconds: 250),
    transitionBuilder: (context, animation, _, child) => FadeTransition(
      opacity: CurvedAnimation(parent: animation, curve: Curves.easeOut),
      child: child,
    ),
    pageBuilder: (context, _, _) {
      final size = MediaQuery.sizeOf(context);
      final full = percent >= 100;
      return Listener(
        onPointerDown: (_) => onTouch(),
        onPointerSignal: (_) => onTouch(),
        onPointerPanZoomStart: (_) => onTouch(),
        behavior: HitTestBehavior.translucent,
        child: Theme(
          data: buildTheme(brightness),
          child: Center(
            child: SizedBox(
              width: size.width * percent / 100,
              height: size.height * percent / 100,
              child: Material(
                clipBehavior: Clip.antiAlias,
                borderRadius: BorderRadius.circular(full ? 0 : 16),
                elevation: 8,
                child: ZapisPage(slot: slot, closeButton: full),
              ),
            ),
          ),
        ),
      );
    },
  );
}
