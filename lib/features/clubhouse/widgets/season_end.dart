import 'package:flutter/material.dart';

import '../../../core/ui.dart' show launchWeb;

/// Termínátor's Google Play page — the sister app for tournaments.
const terminatorPlayUrl =
    'https://play.google.com/store/apps/details?id=cz.kuzelky.terminator';

/// The last thing under the list of matches: a high five and a pointer to
/// Termínátor, the app for tournaments. The hands clap a few times once the
/// footer scrolls into view (not before — nobody would see it) and rest;
/// a tap on them plays it again. With animations off in the system settings
/// they just rest.
class SeasonEnd extends StatefulWidget {
  const SeasonEnd({super.key});

  @override
  State<SeasonEnd> createState() => _SeasonEndState();
}

class _SeasonEndState extends State<SeasonEnd>
    with SingleTickerProviderStateMixin {
  /// One clap: the hands come together, touch at [_touch], and bounce apart.
  static const _touch = 0.4;
  static const _claps = 3;

  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1500),
    value: _touch,
  );

  ScrollPosition? _position;
  bool _played = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _position?.removeListener(_playWhenVisible);
    _position = Scrollable.maybeOf(context)?.position
      ?..addListener(_playWhenVisible);
    WidgetsBinding.instance.addPostFrameCallback((_) => _playWhenVisible());
  }

  @override
  void dispose() {
    _position?.removeListener(_playWhenVisible);
    _controller.dispose();
    super.dispose();
  }

  void _playWhenVisible() {
    if (_played || !mounted) return;
    final box = context.findRenderObject();
    if (box is! RenderBox || !box.attached || !box.hasSize) return;
    final top = box.localToGlobal(Offset.zero).dy;
    // The hands are about to show at the bottom edge of the screen.
    if (top < MediaQuery.sizeOf(context).height - 80) _play();
  }

  Future<void> _play() async {
    _played = true;
    if (MediaQuery.disableAnimationsOf(context)) return;
    try {
      await _controller.repeat(count: _claps).orCancel;
      await _controller.animateTo(_touch, curve: Curves.easeOut);
    } on TickerCanceled {
      // Left the screen mid-clap.
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 40, 24, 16),
      child: Column(
        children: [
          GestureDetector(
            onTap: _play,
            child: ExcludeSemantics(child: _HighFive(animation: _controller)),
          ),
          const SizedBox(height: 12),
          Text(
            'Dojeli jsme do cíle!',
            textAlign: TextAlign.center,
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'Víc zápasů tu už není. Hraješ i turnaje?',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 8),
          TextButton.icon(
            onPressed: () => launchWeb(terminatorPlayUrl),
            icon: const Icon(Icons.emoji_events_outlined),
            label: const Text('Termínátor – appka na turnaje'),
          ),
          Text(
            'Zdarma na Google Play',
            style: theme.textTheme.bodySmall?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

/// Two raised hands that meet in the middle, with a spark where they touch.
class _HighFive extends StatelessWidget {
  const _HighFive({required this.animation});

  final Animation<double> animation;

  static const _hand = TextStyle(fontSize: 52, height: 1);

  /// 0 = far apart, 1 = touching.
  static double _closeness(double t) {
    if (t <= _SeasonEndState._touch) {
      return Curves.easeIn.transform(t / _SeasonEndState._touch);
    }
    final back = (t - _SeasonEndState._touch) / (1 - _SeasonEndState._touch);
    // A short bounce off, then the next clap begins from apart.
    return 1 - Curves.easeOut.transform(back);
  }

  @override
  Widget build(BuildContext context) => SizedBox(
    height: 76,
    width: 200,
    child: AnimatedBuilder(
      animation: animation,
      builder: (context, _) {
        final t = animation.value;
        final close = _closeness(t);
        // The spark flashes right at the touch and fades out.
        final spark = (1 - ((t - _SeasonEndState._touch).abs() / 0.18))
            .clamp(0.0, 1.0);
        final gap = 70 * (1 - close) + 4;
        return Stack(
          alignment: Alignment.center,
          clipBehavior: Clip.none,
          children: [
            Transform.translate(
              offset: Offset(-(gap / 2 + 22), 0),
              child: Transform.rotate(
                angle: 0.25 * (1 - close) + 0.12,
                child: Transform.flip(
                  flipX: true,
                  child: const Text('✋', style: _hand),
                ),
              ),
            ),
            Transform.translate(
              offset: Offset(gap / 2 + 22, 0),
              child: Transform.rotate(
                angle: -(0.25 * (1 - close) + 0.12),
                child: const Text('✋', style: _hand),
              ),
            ),
            Opacity(
              opacity: spark,
              child: Transform.translate(
                offset: const Offset(0, -34),
                child: Transform.scale(
                  scale: 0.7 + 0.8 * spark,
                  child: const Text('✨', style: TextStyle(fontSize: 34)),
                ),
              ),
            ),
          ],
        );
      },
    ),
  );
}
