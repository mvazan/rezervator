/// The news ticker in the kiosk's status bar: the active notices as one
/// line of text running right to left, like the strip under a TV news
/// broadcast, over the space between the clock and „Rezervovat“. A text
/// that fits just stands. The same notices are in the drawer — this is a
/// second way to read them, from across the room.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/models.dart';

/// How fast the text runs, in logical pixels per second.
const kioskTickerSpeed = 70.0;

/// The gap between the end of the text and its next round.
const _gap = 80.0;

/// Whether the ticker runs. A test turns it off: a repeating animation never
/// lets `pumpAndSettle` settle.
final kioskTickerRunningProvider = Provider<bool>((ref) => true);

/// The notices as the ticker's line: „Title: text“ each, one line (line
/// breaks and runs of spaces collapsed), told apart by a bullet.
String kioskTickerText(List<Message> notices) => notices
    .map((m) {
      final body = m.body.replaceAll(RegExp(r'\s+'), ' ').trim();
      final title = (m.title ?? '').trim();
      return title.isEmpty ? body : '$title: $body';
    })
    .join('   •   ');

class KioskTicker extends ConsumerStatefulWidget {
  const KioskTicker({super.key, required this.notices});

  final List<Message> notices;

  @override
  ConsumerState<KioskTicker> createState() => _KioskTickerState();
}

class _KioskTickerState extends ConsumerState<KioskTicker>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(vsync: this);
  Duration? _running;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// (Re)starts the loop for a round of [length] px; a text that changes
  /// changes the round, and the loop starts over.
  void _loop(double length) {
    final duration = Duration(
      milliseconds: (length / kioskTickerSpeed * 1000).round(),
    );
    if (_running == duration) return;
    _running = duration;
    _controller.duration = duration;
    _controller.repeat();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final style = DefaultTextStyle.of(context).style.merge(
      TextStyle(
        fontSize: 20,
        fontWeight: FontWeight.w600,
        color: scheme.onSurface,
      ),
    );
    final text = kioskTickerText(widget.notices);
    final running = ref.watch(kioskTickerRunningProvider);
    // One line tall: the status bar gives the strip no height of its own.
    return SizedBox(
      height: 36,
      child: LayoutBuilder(
        builder: (context, box) {
          final painter = TextPainter(
            text: TextSpan(text: text, style: style),
            textDirection: Directionality.of(context),
            textScaler: MediaQuery.textScalerOf(context),
            maxLines: 1,
          )..layout();
          final width = painter.width;
          painter.dispose();
          final line = Text(text, style: style, maxLines: 1, softWrap: false);
          if (width <= box.maxWidth || !running) {
            _controller.stop();
            _running = null;
            return Align(
              alignment: Alignment.centerLeft,
              child: ClipRect(
                child: SizedBox(
                  width: box.maxWidth,
                  child: Text(
                    text,
                    style: style,
                    maxLines: 1,
                    softWrap: false,
                    overflow: TextOverflow.fade,
                  ),
                ),
              ),
            );
          }
          final round = width + _gap;
          _loop(round);
          return ShaderMask(
            // Soft edges, so the text does not just stop at the border.
            shaderCallback: (rect) => const LinearGradient(
              colors: [
                Colors.transparent,
                Colors.black,
                Colors.black,
                Colors.transparent,
              ],
              stops: [0, 0.04, 0.96, 1],
            ).createShader(rect),
            blendMode: BlendMode.dstIn,
            child: ClipRect(
              child: AnimatedBuilder(
                animation: _controller,
                builder: (context, child) => OverflowBox(
                  alignment: Alignment.centerLeft,
                  minWidth: 0,
                  // Room for both rounds — finite: an infinite max width
                  // makes the alignment arithmetic NaN.
                  maxWidth: 2 * round + 8,
                  child: Transform.translate(
                    offset: Offset(-_controller.value * round, 0),
                    child: child,
                  ),
                ),
                // Two rounds side by side: the second one is on screen while
                // the first runs out, so the loop has no seam.
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    line,
                    const SizedBox(width: _gap),
                    line,
                    const SizedBox(width: _gap),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}
