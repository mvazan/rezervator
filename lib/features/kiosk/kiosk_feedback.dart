/// „Napište nám“ on the kiosk (the panels' module `feedback`): a QR code
/// of the web's feedback form (kiosk_qr.dart) — a message is typed on a
/// phone, not on the kiosk's 32" screen with its giant keyboard. A tap
/// opens the code large ([showKioskFeedback]). Display only, like the rest
/// of the panels.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'kiosk_info_panel.dart' show KioskCard;
import 'kiosk_qr.dart';

const kioskFeedbackTitle = 'Chybí ti něco, nebo něco nefunguje?';

/// The text with the QR code beside or under it.
const kioskFeedbackText =
    'Naskenuj kód mobilem a napiš nám — přečte si to autor Rezervátoru.';

/// The same when the card has no room for the code: the tap shows it.
const kioskFeedbackTextTap =
    'Ťukni pro QR kód, naskenuj ho mobilem a napiš nám — přečte si to autor '
    'Rezervátoru.';

// „Jak začít“'s heading and body.
const _headingStyle = TextStyle(fontSize: 18, fontWeight: FontWeight.w800);
const _bodyStyle = TextStyle(fontSize: 16, height: 1.3);
const _headingGap = 6.0;

/// Between the text and the code beside or under it.
const _qrGap = 12.0;

/// The code's largest and smallest tile in the card (the dialog's is
/// larger), and the least the text keeps beside it.
const _qrMax = 220.0;
const _qrMin = 120.0;
const _textMin = 160.0;

/// Where the card puts the QR code.
enum _QrPlace { beside, under, none }

/// The card: the question and the text, the code beside them when the card
/// is wide and tall enough for a tile of at least [_qrMin] (whole device
/// pixels a module, [kioskQrTile]), under them when only the height allows,
/// else none — the text then sends a visitor to the tap. A tap anywhere
/// opens the code large ([onOpen]).
class KioskFeedbackCard extends StatelessWidget {
  const KioskFeedbackCard({super.key, required this.onOpen});

  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) => GestureDetector(
    behavior: HitTestBehavior.opaque,
    onTap: onOpen,
    child: KioskCard(
      icon: Icons.rate_review_outlined,
      title: 'NAPIŠTE NÁM',
      fill: true,
      child: LayoutBuilder(
        builder: (context, box) {
          final fit = _fit(context, box);
          // Too low even for the text: cut, never an overflow.
          return ClipRect(
            child: SingleChildScrollView(
              physics: const NeverScrollableScrollPhysics(),
              child: _FeedbackText(qr: fit.place, qrSize: fit.qrSize),
            ),
          );
        },
      ),
    ),
  );

  /// Where the code goes in [box] (the card's interior) and how much room
  /// it gets. Measured with the styles the text is drawn in, merged into
  /// the ambient one, at the visitor's text size.
  ({_QrPlace place, double qrSize}) _fit(
    BuildContext context,
    BoxConstraints box,
  ) {
    final base = DefaultTextStyle.of(context).style;
    final scaler = MediaQuery.textScalerOf(context);
    final direction = Directionality.of(context);
    final dpr = MediaQuery.devicePixelRatioOf(context);
    double height(String text, TextStyle style, double width) {
      final painter = TextPainter(
        text: TextSpan(text: text, style: base.merge(style)),
        textDirection: direction,
        textScaler: scaler,
      )..layout(maxWidth: math.max(width, 0));
      final h = painter.height;
      painter.dispose();
      return h;
    }

    double text(double width) =>
        height(kioskFeedbackTitle, _headingStyle, width) +
        _headingGap +
        height(kioskFeedbackText, _bodyStyle, width);

    final width = box.maxWidth;
    final room = box.hasBoundedHeight ? box.maxHeight : double.infinity;
    bool shown(double size) =>
        kioskQrTile(size, dpr, kioskFeedbackQr.length) >= _qrMin;

    // Beside the text: as large as the height and the text's least width
    // allow, the text no taller than the card.
    final beside = math.min(_qrMax, math.min(room, width - _qrGap - _textMin));
    if (shown(beside)) {
      final tile = kioskQrTile(beside, dpr, kioskFeedbackQr.length);
      if (text(width - _qrGap - tile) <= room) {
        return (place: _QrPlace.beside, qrSize: beside);
      }
    }
    // Under it, the text at the card's width.
    final under = math.min(
      _qrMax,
      math.min(room - text(width) - _qrGap, width),
    );
    if (shown(under)) return (place: _QrPlace.under, qrSize: under);
    return (place: _QrPlace.none, qrSize: 0);
  }
}

/// The question, the text and the code [qr] (beside or under them, at
/// [qrSize]) or none — the card's and the dialog's.
class _FeedbackText extends StatelessWidget {
  const _FeedbackText({required this.qr, required this.qrSize});

  final _QrPlace qr;
  final double qrSize;

  @override
  Widget build(BuildContext context) {
    final words = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        const Text(kioskFeedbackTitle, style: _headingStyle),
        const SizedBox(height: _headingGap),
        Text(
          qr == _QrPlace.none ? kioskFeedbackTextTap : kioskFeedbackText,
          style: _bodyStyle,
        ),
      ],
    );
    final code = KioskQr(
      rows: kioskFeedbackQr,
      size: qrSize,
      semanticLabel: kioskFeedbackQrLabel,
    );
    return switch (qr) {
      _QrPlace.beside => Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(child: words),
          const SizedBox(width: _qrGap),
          code,
        ],
      ),
      _QrPlace.under => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          words,
          const SizedBox(height: _qrGap),
          Center(child: code),
        ],
      ),
      _QrPlace.none => words,
    };
  }
}

/// Opens „Napište nám“ over the kiosk: the text and the code at 300 px.
/// [wrap] is the shell's: the kiosk's theme, and a touch on the dialog
/// counts for the idle timer — whose reset closes it, with every other
/// dialog.
Future<void> showKioskFeedback(
  BuildContext context, {
  required Widget Function(Widget child) wrap,
}) => showDialog<void>(
  context: context,
  builder: (context) => wrap(const KioskFeedbackDialog()),
);

/// „Napište nám“ whole: the text and the code under it, large.
class KioskFeedbackDialog extends StatelessWidget {
  const KioskFeedbackDialog({super.key});

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Napište nám'),
    content: const SizedBox(
      width: 480,
      child: SingleChildScrollView(
        child: _FeedbackText(qr: _QrPlace.under, qrSize: 300),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('Zavřít'),
      ),
    ],
  );
}
