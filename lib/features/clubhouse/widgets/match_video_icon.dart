/// The leading icon of a match row (Klubovna's Výsledky list, the day
/// header's match dialog): the video control when a link is worth showing,
/// otherwise the row's own plain glyph. A YouTube URL alone can't say
/// live-vs-recording — [isLive] can.
library;

import 'package:flutter/material.dart';

import '../../../core/ui.dart';
import '../../../domain/models.dart';
import '../../../domain/palette.dart';
import '../../../domain/results.dart';

const double _slotSize = 40;
const double _badgeSize = 36;

/// [slot.videoUrl] present and [linksEnabled]: a tappable video control —
/// a pulsing red camera badge while [isLive], else a plain play button.
/// Otherwise renders [fallback] unchanged (Výsledky's team-colour
/// `MatchTrophy`, the day-matches dialog's plain trophy/block icon).
///
/// The control's own tap launches [launch] and does not propagate to an
/// ancestor row's tap handler — same nested-tap isolation the previous
/// trailing `IconButton` already relied on. Every state renders in the same
/// 40×40 footprint so a row's leading column never shifts.
class MatchLeading extends StatefulWidget {
  const MatchLeading({
    super.key,
    required this.slot,
    required this.result,
    required this.now,
    required this.linksEnabled,
    required this.fallback,
    this.colorId,
    this.launch = launchWeb,
  });

  final PrioritySlot slot;
  final MatchResult? result;
  final DateTime now;

  /// False hides the video control unconditionally (e.g. the public,
  /// unauthenticated overview) — [fallback] renders instead, same as when
  /// there is no video at all.
  final bool linksEnabled;

  /// The row's own "nothing to show" glyph.
  final Widget fallback;

  /// The match's team colour (a Google event colour id, as the row's
  /// trophy has it): a recording's play button wears it, like the trophy.
  /// Null keeps the plain play button; a live stream stays red either way.
  final int? colorId;

  final void Function(String url) launch;

  @override
  State<MatchLeading> createState() => _MatchLeadingState();
}

class _MatchLeadingState extends State<MatchLeading>
    with SingleTickerProviderStateMixin {
  // Lazily created — only in the LIVE branch of _syncPulse — so the ~200
  // non-live rows results_screen builds eagerly never force a controller
  // (and its Ticker) into existence just to immediately stop it.
  AnimationController? _pulse;

  /// True once [_syncPulse] has actually built the controller — a real
  /// regression guard for the lazy-creation fix (the private field itself
  /// isn't reachable from another library, but a public member on this
  /// otherwise-private State is, via `(state as dynamic)`).
  @visibleForTesting
  bool get debugHasPulseController => _pulse != null;

  bool get _live =>
      widget.slot.videoUrl != null &&
      widget.linksEnabled &&
      isLive(widget.slot, widget.result, widget.now);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncPulse();
  }

  @override
  void didUpdateWidget(covariant MatchLeading oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncPulse();
  }

  /// The ring only repeats while live AND the platform hasn't asked for
  /// reduced motion — [MediaQuery.disableAnimationsOf] can change (a
  /// setting flips) just as easily as [_live] can, so both call sites run
  /// this instead of deciding once in [initState].
  void _syncPulse() {
    final shouldRun = _live && !MediaQuery.disableAnimationsOf(context);
    if (shouldRun) {
      final pulse = _pulse ??= AnimationController(
        vsync: this,
        duration: const Duration(milliseconds: 1400),
      );
      if (!pulse.isAnimating) pulse.repeat();
    } else if (_pulse case final pulse? when pulse.isAnimating) {
      pulse.stop();
    }
  }

  @override
  void dispose() {
    _pulse?.dispose();
    super.dispose();
  }

  Widget _recordingBadge(ThemeData theme) {
    final color = googleEventColorOf(widget.colorId);
    if (color == null) {
      return Icon(
        Icons.play_circle_fill,
        size: _badgeSize,
        color: theme.colorScheme.primary,
      );
    }
    return Container(
      width: _badgeSize,
      height: _badgeSize,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: color,
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: Icon(Icons.play_arrow, size: 22, color: legibleGlyphOn(color)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final videoUrl = widget.slot.videoUrl;
    if (videoUrl == null || !widget.linksEnabled) {
      return SizedBox(
        width: _slotSize,
        height: _slotSize,
        child: Center(child: widget.fallback),
      );
    }

    final theme = Theme.of(context);
    final live = _live;
    final pulsing = live && !MediaQuery.disableAnimationsOf(context);
    final status = widget.result?.status;
    final recorded =
        status == MatchStatus.finished || status == MatchStatus.forfeit;
    final tooltip = live ? 'Živý přenos' : (recorded ? 'Záznam' : 'Video');

    final Widget badge = live
        ? Stack(
            alignment: Alignment.center,
            children: [
              if (pulsing)
                AnimatedBuilder(
                  // pulsing implies _syncPulse already created it (same
                  // condition it runs the LIVE branch under).
                  animation: _pulse!,
                  builder: (context, _) {
                    final t = _pulse!.value;
                    return Opacity(
                      opacity: (0.6 * (1 - t)).clamp(0.0, 1.0),
                      child: Transform.scale(
                        scale: 1 + 0.5 * t,
                        child: Container(
                          width: _badgeSize,
                          height: _badgeSize,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: theme.colorScheme.error,
                          ),
                        ),
                      ),
                    );
                  },
                ),
              Container(
                width: _badgeSize,
                height: _badgeSize,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: theme.colorScheme.error,
                ),
                child: Icon(
                  Icons.videocam,
                  size: 20,
                  color: theme.colorScheme.onError,
                ),
              ),
            ],
          )
        : _recordingBadge(theme);

    // IconButton's own tooltip already carries the accessible name (Tooltip
    // wraps its child in Semantics with that message) — no extra wrapper
    // needed for "Tooltip + semantics Živý přenos".
    return IconButton(
      icon: badge,
      tooltip: tooltip,
      padding: EdgeInsets.zero,
      constraints:
          const BoxConstraints.tightFor(width: _slotSize, height: _slotSize),
      onPressed: () => widget.launch(videoUrl),
    );
  }
}
