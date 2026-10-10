/// The kiosk's stream window (0066): the match on air, embedded, in a
/// window the visitor moves by its title bar, resizes by the grip,
/// maximizes, collapses to a pill — and the idle reset leaves alone. One
/// widget for as long as anything streams: its state (place, size, which
/// match) outlives rebuilds, idle resets and a change of the streaming
/// matches; only the player reloads when the shown video changes.
library;

import 'dart:math' as math;

import 'package:flutter/gestures.dart' show DragStartBehavior;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/clock.dart';
import '../../data/providers.dart';
import '../../domain/kiosk_panel.dart' show kioskStreamMatches;
import '../../domain/models.dart';
import '../../domain/youtube.dart' show youtubeVideoId;
import 'stream/kiosk_stream_view.dart';

/// Builds the player for [videoId]; [interactive] false = the player must
/// not take touches (a gesture on the window, a route above the kiosk).
typedef KioskStreamContent =
    Widget Function(String videoId, {required bool interactive});

/// The player — tests put a plain widget here (a platform view does not
/// run under flutter_test).
final kioskStreamContentProvider = Provider<KioskStreamContent>(
  (ref) => (videoId, {required interactive}) => KioskStreamView(
    key: ValueKey(videoId),
    videoId: videoId,
    interactive: interactive,
  ),
);

/// The matches whose stream the window shows now — none with the admin's
/// switch off.
final kioskStreamProvider = Provider<List<PrioritySlot>>((ref) {
  if (!(ref.watch(settingsProvider).value?.kioskStream ?? false)) {
    return const [];
  }
  return kioskStreamMatches(
    slots: ref.watch(prioritySlotsProvider),
    results: ref.watch(matchResultsProvider).value ?? const {},
    now: ref.watch(nowProvider).value ?? DateTime.now(),
  );
});

class KioskStreamWindow extends StatefulWidget {
  const KioskStreamWindow({
    super.key,
    required this.matches,
    required this.content,
    required this.corner,
    required this.widthPercent,
    this.interactive = true,
  });

  /// The matches on air with a video, chronological; never empty.
  final List<PrioritySlot> matches;
  final KioskStreamContent content;

  /// Where the window first appears, and how wide, in percent of the area.
  final KioskCorner corner;
  final int widthPercent;

  /// False while a route sits above the kiosk: the player takes no touches.
  final bool interactive;

  static const titleHeight = 40.0;
  static const bottomHeight = 20.0;
  static const pillHeight = 36.0;
  static const minWidth = 240.0;
  static const margin = 8.0;

  /// The whole frame for a player [width] wide: the bars and 16:9.
  static double heightFor(double width) =>
      titleHeight + bottomHeight + width * 9 / 16;

  @override
  State<KioskStreamWindow> createState() => _KioskStreamWindowState();
}

class _KioskStreamWindowState extends State<KioskStreamWindow> {
  /// The frame (bars included) — null until the first layout.
  Rect? _rect;
  Size _area = Size.zero;
  bool _maximized = false;
  bool _collapsed = false;

  /// A drag or a resize is running: the player takes no touches.
  bool _gesture = false;

  /// The match shown, by id; the first one until a visitor turns.
  String? _shownId;

  Rect _initial(Size area) {
    final w = (area.width * widget.widthPercent / 100)
        .clamp(
          KioskStreamWindow.minWidth,
          math.max(
            KioskStreamWindow.minWidth,
            area.width - 2 * KioskStreamWindow.margin,
          ),
        )
        .toDouble();
    final h = KioskStreamWindow.heightFor(w);
    final left = widget.corner.left
        ? KioskStreamWindow.margin
        : area.width - KioskStreamWindow.margin - w;
    final top = widget.corner.top
        ? KioskStreamWindow.margin
        : area.height - KioskStreamWindow.margin - h;
    return Rect.fromLTWH(left, top, w, h);
  }

  /// [r] inside [area]: no wider than the area and no taller either (the
  /// height follows the width, so the width is bounded by the height that
  /// fits — a grip dragged far right must not push the bottom bar, and
  /// the grip with it, out of reach), then shifted in. A window taller
  /// than the area at the minimum width overflows at the bottom rather
  /// than shrinking further.
  Rect _fit(Rect r, Size area) {
    final tallest =
        (area.height -
            KioskStreamWindow.titleHeight -
            KioskStreamWindow.bottomHeight) *
        16 /
        9;
    final w = r.width
        .clamp(
          KioskStreamWindow.minWidth,
          math.max(
            KioskStreamWindow.minWidth,
            math.min(area.width, tallest),
          ),
        )
        .toDouble();
    final h = KioskStreamWindow.heightFor(w);
    final left = r.left.clamp(0.0, math.max(0.0, area.width - w)).toDouble();
    final top = r.top.clamp(0.0, math.max(0.0, area.height - h)).toDouble();
    return Rect.fromLTWH(left, top, w, h);
  }

  PrioritySlot get _shown =>
      widget.matches.where((s) => s.id == _shownId).firstOrNull ??
      widget.matches.first;

  int get _index => widget.matches.indexWhere((s) => s.id == _shown.id);

  void _turn(int direction) {
    final n = widget.matches.length;
    setState(() => _shownId = widget.matches[(_index + direction) % n].id);
  }

  void _moveBy(Offset delta) {
    final rect = _rect;
    if (rect == null || _maximized) return;
    setState(() => _rect = _fit(rect.shift(delta), _area));
  }

  void _resizeBy(double dx) {
    final rect = _rect;
    if (rect == null || _maximized) return;
    final w = (rect.width + dx)
        .clamp(
          KioskStreamWindow.minWidth,
          math.max(KioskStreamWindow.minWidth, _area.width - rect.left),
        )
        .toDouble();
    setState(() {
      _rect = _fit(
        Rect.fromLTWH(
          rect.left,
          rect.top,
          w,
          KioskStreamWindow.heightFor(w),
        ),
        _area,
      );
    });
  }

  void _gestureRuns(bool runs) {
    if (_gesture != runs) setState(() => _gesture = runs);
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      _area = Size(constraints.maxWidth, constraints.maxHeight);
      final rect = _rect = _fit(_rect ?? _initial(_area), _area);
      final shown = _shown;
      // The provider lets only matches with a YouTube id through.
      final videoId = youtubeVideoId(shown.videoUrl ?? '')!;
      final title = '${shown.homeTeam} – ${shown.awayTeam}';
      final frame = _maximized ? Offset.zero & _area : rect;
      final interactive = widget.interactive && !_gesture;
      final Rect player;
      if (_collapsed) {
        // Kept alive in a pixel just under the pill — the same element,
        // the stream runs on; nothing of Flutter is drawn over it.
        player = Rect.fromLTWH(
          rect.left,
          rect.top + KioskStreamWindow.pillHeight,
          1,
          1,
        );
      } else {
        player = Rect.fromLTWH(
          frame.left,
          frame.top + KioskStreamWindow.titleHeight,
          frame.width,
          frame.height -
              KioskStreamWindow.titleHeight -
              (_maximized ? 0 : KioskStreamWindow.bottomHeight),
        );
      }
      return Stack(
        children: [
          // The player first and alone in its box: nothing of the frame is
          // ever drawn over it (on the web, Flutter pixels above an iframe
          // cost another canvas every frame).
          Positioned.fromRect(
            rect: player,
            child: widget.content(videoId, interactive: interactive),
          ),
          if (_collapsed)
            Positioned(
              left: rect.left,
              top: rect.top,
              height: KioskStreamWindow.pillHeight,
              child: _Pill(
                title: title,
                onTap: () => setState(() => _collapsed = false),
              ),
            )
          else ...[
            Positioned(
              left: frame.left,
              top: frame.top,
              width: frame.width,
              height: KioskStreamWindow.titleHeight,
              child: _TitleBar(
                title: title,
                index: _index,
                count: widget.matches.length,
                maximized: _maximized,
                onTurn: _turn,
                // Either one takes the gesture surfaces away (the bar's
                // pan, the grip) mid-gesture at worst — a recognizer
                // disposed that way never reports its end, so the flag
                // goes with the change, or the player stays untouchable.
                onCollapse: () => setState(() {
                  _collapsed = true;
                  _gesture = false;
                }),
                onMaximize: () => setState(() {
                  _maximized = !_maximized;
                  _gesture = false;
                }),
                onDragStart: _maximized ? null : () => _gestureRuns(true),
                onDrag: _moveBy,
                onDragEnd: () => _gestureRuns(false),
              ),
            ),
            if (!_maximized)
              Positioned(
                left: frame.left,
                top: frame.bottom - KioskStreamWindow.bottomHeight,
                width: frame.width,
                height: KioskStreamWindow.bottomHeight,
                child: _BottomBar(
                  onResizeStart: () => _gestureRuns(true),
                  onResize: _resizeBy,
                  onResizeEnd: () => _gestureRuns(false),
                ),
              ),
          ],
        ],
      );
    },
  );
}

class _TitleBar extends StatelessWidget {
  const _TitleBar({
    required this.title,
    required this.index,
    required this.count,
    required this.maximized,
    required this.onTurn,
    required this.onCollapse,
    required this.onMaximize,
    required this.onDragStart,
    required this.onDrag,
    required this.onDragEnd,
  });

  final String title;
  final int index;
  final int count;
  final bool maximized;
  final void Function(int direction) onTurn;
  final VoidCallback onCollapse;
  final VoidCallback onMaximize;

  /// Null = the bar does not drag (the window is maximized).
  final VoidCallback? onDragStart;
  final void Function(Offset delta) onDrag;
  final VoidCallback onDragEnd;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surfaceContainerHighest,
      child: Row(
        children: [
          Expanded(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              // Every pixel from the finger's landing moves the window.
              dragStartBehavior: DragStartBehavior.down,
              onPanStart: onDragStart == null ? null : (_) => onDragStart!(),
              onPanUpdate: onDragStart == null
                  ? null
                  : (d) => onDrag(d.delta),
              onPanEnd: onDragStart == null ? null : (_) => onDragEnd(),
              onPanCancel: onDragStart == null ? null : onDragEnd,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                ),
              ),
            ),
          ),
          if (count > 1) ...[
            IconButton(
              tooltip: 'Předchozí zápas',
              visualDensity: VisualDensity.compact,
              onPressed: () => onTurn(-1),
              icon: const Icon(Icons.chevron_left),
            ),
            Text(
              '${index + 1}/$count',
              style: Theme.of(context).textTheme.labelMedium,
            ),
            IconButton(
              tooltip: 'Další zápas',
              visualDensity: VisualDensity.compact,
              onPressed: () => onTurn(1),
              icon: const Icon(Icons.chevron_right),
            ),
          ],
          IconButton(
            tooltip: 'Sbalit',
            visualDensity: VisualDensity.compact,
            onPressed: onCollapse,
            icon: const Icon(Icons.expand_more),
          ),
          IconButton(
            tooltip: maximized ? 'Zmenšit' : 'Na celou obrazovku',
            visualDensity: VisualDensity.compact,
            onPressed: onMaximize,
            icon: Icon(
              maximized ? Icons.close_fullscreen : Icons.open_in_full,
            ),
          ),
        ],
      ),
    );
  }
}

/// The strip under the player with the resize grip at its right end.
class _BottomBar extends StatelessWidget {
  const _BottomBar({
    required this.onResizeStart,
    required this.onResize,
    required this.onResizeEnd,
  });

  final VoidCallback onResizeStart;
  final void Function(double dx) onResize;
  final VoidCallback onResizeEnd;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surfaceContainerHighest,
      child: Align(
        alignment: Alignment.centerRight,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          dragStartBehavior: DragStartBehavior.down,
          onPanStart: (_) => onResizeStart(),
          onPanUpdate: (d) => onResize(d.delta.dx),
          onPanEnd: (_) => onResizeEnd(),
          onPanCancel: onResizeEnd,
          // Manual: a long-press tooltip would race the pan for a finger
          // that lands on the grip and pauses before it drags.
          child: Tooltip(
            message: 'Změnit velikost',
            triggerMode: TooltipTriggerMode.manual,
            child: SizedBox(
              width: 48,
              height: KioskStreamWindow.bottomHeight,
              child: Icon(
                Icons.drag_handle,
                size: 18,
                color: scheme.onSurfaceVariant,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The collapsed window: ▶ and the title; a tap brings the window back.
class _Pill extends StatelessWidget {
  const _Pill({required this.title, required this.onTap});

  final String title;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(KioskStreamWindow.pillHeight / 2),
      child: Tooltip(
        message: 'Rozbalit stream',
        child: InkWell(
          borderRadius: BorderRadius.circular(KioskStreamWindow.pillHeight / 2),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.play_arrow, size: 20, color: scheme.primary),
                const SizedBox(width: 6),
                Text(title, style: Theme.of(context).textTheme.labelLarge),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
