/// „Jak začít“ on the kiosk (the panels' module `guide`, 0077): how to book
/// a training at the wall tablet, and where else Rezervátor is — the
/// Android app, with its Google Play QR code (kiosk_qr.dart), and the web.
/// One page of fixed text, no turning; a tap opens it whole with a large
/// code ([showKioskGuide]). Display only, like the rest of the panels.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'kiosk_info_panel.dart' show KioskCard;
import 'kiosk_qr.dart';

/// The first paragraph: booking here, step by step.
const kioskGuideStepsTitle = 'Rezervace na kiosku';
const kioskGuideSteps = <String>[
  'Ťukni na „Rezervace tréninku“ a najdi své jméno.',
  'Ťukni na volnou dráhu v tabuli a potvrď.',
  // Only with an account: a player without one (0022) has no e-mail and
  // no app, and nothing comes.
  'Máš-li v Rezervátoru účet, přijde ti potvrzení — v aplikaci, a když ji '
      'nepoužíváš, e-mailem s odkazem na zrušení.',
];

/// The second paragraph: Rezervátor beyond the kiosk.
const kioskGuideMobileTitle = 'Rezervátor i v mobilu';

/// The second paragraph's text with the QR code beside or under it.
const kioskGuideMobile =
    'Rezervace, zrušení a upozornění odkudkoli: aplikace pro Android (QR) '
    'nebo web rezervator.online.';

/// The same when the card has no room for the code: the tap shows it.
const kioskGuideMobileTap =
    'Rezervace, zrušení a upozornění odkudkoli: aplikace pro Android — '
    'ťukni pro QR kód — nebo web rezervator.online.';

/// Drawn bold in either text.
const kioskGuideWeb = 'rezervator.online';

const _headingStyle = TextStyle(fontSize: 18, fontWeight: FontWeight.w800);
// Nástěnka's body.
const _bodyStyle = TextStyle(fontSize: 16, height: 1.3);
const _headingGap = 6.0;
const _stepGap = 4.0;
const _paragraphGap = 14.0;

/// Between the text and the code beside or under it.
const _qrGap = 12.0;

/// The code's largest and smallest tile in the card (the dialog's is
/// larger), and the least the text keeps beside it.
const _qrMax = 220.0;
const _qrMin = 120.0;
const _textMin = 200.0;

/// The „Více“ line under a cut text (as Nástěnka's).
const _footerHeight = 32.0;

/// Where the card puts the QR code.
enum _QrPlace { beside, under, none }

/// The card: the two paragraphs, the code beside the second one when the
/// card is wide and tall enough for a tile of at least [_qrMin] (whole
/// device pixels a module, [kioskQrTile]), under it when only the height
/// allows, else none — the text then sends a visitor to the tap. A text
/// taller than the card is cut, faded, with „Více“. A tap anywhere opens
/// the whole of it ([onOpen]).
class KioskGuideCard extends StatelessWidget {
  const KioskGuideCard({super.key, required this.onOpen});

  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onOpen,
      child: KioskCard(
        icon: Icons.lightbulb_outline,
        title: 'JAK ZAČÍT',
        fill: true,
        child: LayoutBuilder(
          builder: (context, box) {
            final fit = _fit(context, box);
            final text = _GuideText(qr: fit.place, qrSize: fit.qrSize);
            if (!fit.cut) {
              return Align(alignment: Alignment.topLeft, child: text);
            }
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  child: ShaderMask(
                    // The last lines fade out: the text goes on.
                    shaderCallback: (rect) => const LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      stops: [0.8, 1],
                      colors: [Colors.white, Colors.transparent],
                    ).createShader(rect),
                    blendMode: BlendMode.dstIn,
                    child: SingleChildScrollView(
                      physics: const NeverScrollableScrollPhysics(),
                      child: text,
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                SizedBox(
                  height: _footerHeight - 8,
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      Text(
                        'Více',
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                          color: scheme.primary,
                        ),
                      ),
                      Icon(Icons.expand_more, size: 20, color: scheme.primary),
                    ],
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  /// Where the code goes in [box] (the card's interior), how much room it
  /// gets, and whether the text is cut. Measured with the styles the text
  /// is drawn in, merged into the ambient one, at the visitor's text size.
  ({_QrPlace place, double qrSize, bool cut}) _fit(
    BuildContext context,
    BoxConstraints box,
  ) {
    final base = DefaultTextStyle.of(context).style;
    final scaler = MediaQuery.textScalerOf(context);
    final direction = Directionality.of(context);
    final dpr = MediaQuery.devicePixelRatioOf(context);
    double height(InlineSpan span, double width) {
      final painter = TextPainter(
        text: span,
        textDirection: direction,
        textScaler: scaler,
      )..layout(maxWidth: math.max(width, 0));
      final h = painter.height;
      painter.dispose();
      return h;
    }

    TextSpan plain(String text, TextStyle style) =>
        TextSpan(text: text, style: base.merge(style));
    double mobile(double width, String text) =>
        height(plain(kioskGuideMobileTitle, _headingStyle), width) +
        _headingGap +
        height(_mobileSpan(text, base.merge(_bodyStyle)), width);

    final width = box.maxWidth;
    final room = box.hasBoundedHeight ? box.maxHeight : double.infinity;
    var steps =
        height(plain(kioskGuideStepsTitle, _headingStyle), width) + _headingGap;
    for (final (i, step) in kioskGuideSteps.indexed) {
      if (i > 0) steps += _stepGap;
      steps += height(plain('${i + 1}. $step', _bodyStyle), width);
    }
    final left = room - steps - _paragraphGap;
    bool shown(double size) =>
        kioskQrTile(size, dpr, kioskPlayQr.length) >= _qrMin;

    // Beside the second paragraph: as large as the height left and the
    // text's least width allow.
    final beside = math.min(_qrMax, math.min(left, width - _qrGap - _textMin));
    if (shown(beside)) {
      final tile = kioskQrTile(beside, dpr, kioskPlayQr.length);
      if (mobile(width - _qrGap - tile, kioskGuideMobile) <= left) {
        return (place: _QrPlace.beside, qrSize: beside, cut: false);
      }
    }
    // Under it, the paragraph at the card's width.
    final text = mobile(width, kioskGuideMobile);
    final under = math.min(_qrMax, math.min(left - text - _qrGap, width));
    if (shown(under)) {
      return (place: _QrPlace.under, qrSize: under, cut: false);
    }
    return (
      place: _QrPlace.none,
      qrSize: 0,
      cut: mobile(width, kioskGuideMobileTap) > left,
    );
  }
}

/// [text] with [kioskGuideWeb] in it drawn bold.
TextSpan _mobileSpan(String text, TextStyle? style) {
  final at = text.indexOf(kioskGuideWeb);
  return TextSpan(
    style: style,
    children: [
      TextSpan(text: text.substring(0, at)),
      const TextSpan(
        text: kioskGuideWeb,
        style: TextStyle(fontWeight: FontWeight.w800),
      ),
      TextSpan(text: text.substring(at + kioskGuideWeb.length)),
    ],
  );
}

/// The two paragraphs, the code [qr] (beside or under the second one, at
/// [qrSize]) or none — the card's and the dialog's.
class _GuideText extends StatelessWidget {
  const _GuideText({required this.qr, required this.qrSize});

  final _QrPlace qr;
  final double qrSize;

  @override
  Widget build(BuildContext context) {
    final code = KioskQr(
      rows: kioskPlayQr,
      size: qrSize,
      semanticLabel: kioskPlayQrLabel,
    );
    final mobile = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(kioskGuideMobileTitle, style: _headingStyle),
        const SizedBox(height: _headingGap),
        Text.rich(
          _mobileSpan(
            qr == _QrPlace.none ? kioskGuideMobileTap : kioskGuideMobile,
            null,
          ),
          style: _bodyStyle,
        ),
      ],
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        const Text(kioskGuideStepsTitle, style: _headingStyle),
        const SizedBox(height: _headingGap),
        for (final (i, step) in kioskGuideSteps.indexed) ...[
          if (i > 0) const SizedBox(height: _stepGap),
          Text('${i + 1}. $step', style: _bodyStyle),
        ],
        const SizedBox(height: _paragraphGap),
        switch (qr) {
          _QrPlace.beside => Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: mobile),
              const SizedBox(width: _qrGap),
              code,
            ],
          ),
          _QrPlace.under => Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              mobile,
              const SizedBox(height: _qrGap),
              Center(child: code),
            ],
          ),
          _QrPlace.none => mobile,
        },
      ],
    );
  }
}

/// Opens „Jak začít“ over the kiosk: the whole text and the code at 300 px.
/// [wrap] is the shell's: the kiosk's theme, and a touch on the dialog
/// counts for the idle timer — whose reset closes it, with every other
/// dialog.
Future<void> showKioskGuide(
  BuildContext context, {
  required Widget Function(Widget child) wrap,
}) => showDialog<void>(
  context: context,
  builder: (context) => wrap(const KioskGuideDialog()),
);

/// „Jak začít“ whole: both paragraphs and the code under them, large.
class KioskGuideDialog extends StatelessWidget {
  const KioskGuideDialog({super.key});

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Jak začít'),
    content: const SizedBox(
      width: 560,
      child: SingleChildScrollView(
        child: _GuideText(qr: _QrPlace.under, qrSize: 300),
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
