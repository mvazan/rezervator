/// The kiosk's stream windows (0066, 0072): a match's video, embedded, in
/// a window the visitor moves by its title bar, resizes by the grip,
/// maximizes, collapses to a pill or closes with the × — and the idle
/// reset leaves alone. Any visitor opens one (▶ at a match: live or the
/// recording); the admin may let the match on air open by itself. A
/// window closes by itself when its video ends. One window turns through
/// the open streams, or — the admin's choice — each stream has its own.
/// A window's state (place, size, which match) outlives rebuilds, idle
/// resets and a change of the streams; only the player reloads when the
/// shown video changes.
library;

import 'dart:math' as math;

import 'package:flutter/gestures.dart' show DragStartBehavior;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/clock.dart';
import '../../data/providers.dart';
import '../../domain/kiosk_panel.dart'
    show kioskStreamMatches, kioskVisibleStreams;
import '../../domain/models.dart';
import '../../domain/youtube.dart' show youtubeVideoId;
import 'stream/kiosk_stream_view.dart';

/// Builds the player for [videoId]; [interactive] false = the player must
/// not take touches (a gesture on the window, a route above the kiosk);
/// [onEnded] = the video has ended.
typedef KioskStreamContent =
    Widget Function(
      String videoId, {
      required bool interactive,
      VoidCallback? onEnded,
    });

/// The player — tests put a plain widget here (a platform view does not
/// run under flutter_test).
final kioskStreamContentProvider = Provider<KioskStreamContent>(
  (ref) => (videoId, {required interactive, onEnded}) => KioskStreamView(
    key: ValueKey(videoId),
    videoId: videoId,
    interactive: interactive,
    onEnded: onEnded,
  ),
);

/// A visitor's latest ▶: [id] and a count, so the same stream asked for
/// twice still comes up.
typedef KioskStreamReveal = ({String id, int seq});

/// What visitors did to the streams: the ones they [opened] (▶), in the
/// order they did, and the [closed] ones — by the × or by the video ending
/// — which never open by themselves again until a ▶ opens them. [reveal]
/// is the latest ▶: its window comes up, expanded and turned to it.
@immutable
class KioskStreams {
  const KioskStreams({
    this.opened = const [],
    this.closed = const {},
    this.reveal,
  });

  final List<String> opened;
  final Set<String> closed;
  final KioskStreamReveal? reveal;
}

class KioskStreamsNotifier extends Notifier<KioskStreams> {
  @override
  KioskStreams build() => const KioskStreams();

  /// A visitor's ▶ at match [id]. With a window per stream there are never
  /// more opened than windows: the oldest one opened gives way.
  void open(String id) {
    final max = ref.read(settingsProvider).value?.kioskStreamMax ?? 1;
    var opened = state.opened.contains(id)
        ? state.opened
        : [...state.opened, id];
    final closed = {...state.closed}..remove(id);
    if (max > 1 && opened.length > max) {
      closed.addAll(opened.take(opened.length - max));
      opened = opened.sublist(opened.length - max);
    }
    state = KioskStreams(
      opened: opened,
      closed: closed,
      reveal: (id: id, seq: (state.reveal?.seq ?? 0) + 1),
    );
  }

  /// The × on stream [id], or its video ended.
  void close(String id) {
    if (!state.opened.contains(id) && state.closed.contains(id)) return;
    state = KioskStreams(
      opened: [for (final o in state.opened) if (o != id) o],
      closed: {...state.closed, id},
      reveal: state.reveal,
    );
  }
}

/// The kiosk's open streams and what visitors did to them.
final kioskStreamsProvider =
    NotifierProvider<KioskStreamsNotifier, KioskStreams>(
      KioskStreamsNotifier.new,
    );

/// The streams the windows show now ([kioskVisibleStreams]): the match on
/// air by itself only with the admin's switch on.
final kioskStreamProvider = Provider<List<PrioritySlot>>((ref) {
  final settings = ref.watch(settingsProvider).value;
  final slots = ref.watch(prioritySlotsProvider);
  final streams = ref.watch(kioskStreamsProvider);
  return kioskVisibleStreams(
    slots: slots,
    live: (settings?.kioskStream ?? false)
        ? kioskStreamMatches(
            slots: slots,
            results: ref.watch(matchResultsProvider).value ?? const {},
            now: ref.watch(nowProvider).value ?? DateTime.now(),
          )
        : const [],
    opened: streams.opened,
    closed: streams.closed,
    max: settings?.kioskStreamMax ?? 1,
  );
});

/// The windows over the board for [streams] (never empty): with one window
/// at once (the admin's „Oken najednou“), one that turns through them all;
/// with more, one per stream, each first in its own corner — the admin's,
/// then the one beside it, the one above or below, the one across. A
/// window keeps its place in the stack for as long as its stream is open
/// (an iframe moved in the page reloads); while one is maximized the
/// others hide, their players kept running in a pixel.
class KioskStreamLayer extends ConsumerStatefulWidget {
  const KioskStreamLayer({
    super.key,
    required this.streams,
    this.interactive = true,
  });

  final List<PrioritySlot> streams;

  /// False while a route sits above the kiosk: no player takes touches.
  final bool interactive;

  @override
  ConsumerState<KioskStreamLayer> createState() => _KioskStreamLayerState();
}

class _KioskStreamLayerState extends ConsumerState<KioskStreamLayer> {
  /// The streams in the order their windows came — never reordered.
  final _order = <String>[];

  /// The corner each window took first: the lowest one free then.
  final _corners = <String, int>{};

  /// The window on the whole area, if one is.
  String? _maximized;
  KioskStreamReveal? _reveal;

  void _sync() {
    final ids = {for (final s in widget.streams) s.id};
    _order.removeWhere((id) => !ids.contains(id));
    _corners.removeWhere((id, _) => !ids.contains(id));
    for (final s in widget.streams) {
      if (!_order.contains(s.id)) _order.add(s.id);
      if (!_corners.containsKey(s.id)) {
        var corner = 0;
        while (_corners.containsValue(corner)) {
          corner++;
        }
        _corners[s.id] = corner;
      }
    }
    if (!ids.contains(_maximized)) _maximized = null;
    // A ▶ brings its window up from under a maximized one.
    final reveal = ref.watch(kioskStreamsProvider.select((s) => s.reveal));
    if (reveal != _reveal) {
      _reveal = reveal;
      if (reveal != null && reveal.id != _maximized) _maximized = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    _sync();
    final settings = ref.watch(settingsProvider).value;
    final content = ref.watch(kioskStreamContentProvider);
    final close = ref.read(kioskStreamsProvider.notifier).close;
    final corner = settings?.kioskStreamCorner ?? KioskCorner.bl;
    final width = settings?.kioskStreamWidth ?? 35;
    final byId = {for (final s in widget.streams) s.id: s};
    final streams = [for (final id in _order) byId[id]!];
    if ((settings?.kioskStreamMax ?? 1) <= 1) {
      return KioskStreamWindow(
        matches: streams,
        content: content,
        corner: corner,
        widthPercent: width,
        interactive: widget.interactive,
        reveal: _reveal,
        onClose: close,
      );
    }
    final corners = corner.fromHere;
    return Stack(
      fit: StackFit.expand,
      children: [
        for (final s in streams)
          KioskStreamWindow(
            key: ValueKey(s.id),
            matches: [s],
            content: content,
            corner: corners[_corners[s.id]! % corners.length],
            widthPercent: width,
            interactive: widget.interactive,
            reveal: _reveal,
            onClose: close,
            hidden: _maximized != null && _maximized != s.id,
            onMaximized: (on) => setState(() {
              if (on) {
                _maximized = s.id;
              } else if (_maximized == s.id) {
                _maximized = null;
              }
            }),
          ),
      ],
    );
  }
}

class KioskStreamWindow extends StatefulWidget {
  const KioskStreamWindow({
    super.key,
    required this.matches,
    required this.content,
    required this.corner,
    required this.widthPercent,
    required this.onClose,
    this.interactive = true,
    this.reveal,
    this.hidden = false,
    this.onMaximized,
  });

  /// The streams it turns through (one with a window per stream); never
  /// empty.
  final List<PrioritySlot> matches;
  final KioskStreamContent content;

  /// Where the window first appears, and how wide, in percent of the area.
  final KioskCorner corner;
  final int widthPercent;

  /// The × on the stream shown, or its video ended.
  final void Function(String id) onClose;

  /// False while a route sits above the kiosk: the player takes no touches.
  final bool interactive;

  /// A visitor's latest ▶: one of [matches] — the window expands and turns
  /// to it; another — the window gives up the whole area.
  final KioskStreamReveal? reveal;

  /// Another window is maximized: only the player is kept, in a pixel.
  final bool hidden;

  /// The window took the whole area (true) or gave it back.
  final void Function(bool maximized)? onMaximized;

  static const titleHeight = 40.0;
  static const bottomHeight = 20.0;
  static const pillHeight = 36.0;

  /// Wide enough for the title bar's buttons and some of the title.
  static const minWidth = 300.0;
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

  @override
  void initState() {
    super.initState();
    final reveal = widget.reveal;
    if (reveal != null && widget.matches.any((s) => s.id == reveal.id)) {
      _shownId = reveal.id;
    }
  }

  @override
  void didUpdateWidget(KioskStreamWindow old) {
    super.didUpdateWidget(old);
    final reveal = widget.reveal;
    if (reveal == null || reveal == old.reveal) return;
    if (widget.matches.any((s) => s.id == reveal.id)) {
      _shownId = reveal.id;
      _collapsed = false;
    } else {
      // The layer shows the other window; this one steps back.
      _maximized = false;
    }
    _gesture = false;
  }

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

  /// Closes [id]: the window turns on to the next stream, if any is left.
  void _close(String id) {
    final n = widget.matches.length;
    final at = widget.matches.indexWhere((s) => s.id == id);
    if (n > 1 && at >= 0) {
      setState(() => _shownId = widget.matches[(at + 1) % n].id);
    }
    widget.onClose(id);
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
      final interactive = widget.interactive && !_gesture && !widget.hidden;
      final playerOf = widget.content(
        videoId,
        interactive: interactive,
        onEnded: () => _close(shown.id),
      );
      if (widget.hidden) {
        // Another window has the whole area: the player runs on in a
        // pixel at the window's corner, nothing else is drawn.
        return Stack(
          children: [
            Positioned.fromRect(
              rect: Rect.fromLTWH(rect.left, rect.top, 1, 1),
              child: playerOf,
            ),
          ],
        );
      }
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
          Positioned.fromRect(rect: player, child: playerOf),
          if (_collapsed)
            Positioned(
              left: rect.left,
              top: rect.top,
              height: KioskStreamWindow.pillHeight,
              child: _Pill(
                title: title,
                onTap: () => setState(() => _collapsed = false),
                onClose: () => _close(shown.id),
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
                onMaximize: () {
                  setState(() {
                    _maximized = !_maximized;
                    _gesture = false;
                  });
                  widget.onMaximized?.call(_maximized);
                },
                onClose: () => _close(shown.id),
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
    required this.onClose,
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
  final VoidCallback onClose;

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
          IconButton(
            tooltip: 'Zavřít stream',
            visualDensity: VisualDensity.compact,
            onPressed: onClose,
            icon: const Icon(Icons.close),
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

/// The collapsed window: ▶ and the title — a tap brings the window back —
/// and the ×.
class _Pill extends StatelessWidget {
  const _Pill({
    required this.title,
    required this.onTap,
    required this.onClose,
  });

  final String title;
  final VoidCallback onTap;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    const radius = BorderRadius.horizontal(
      left: Radius.circular(KioskStreamWindow.pillHeight / 2),
    );
    return Material(
      color: scheme.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(KioskStreamWindow.pillHeight / 2),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Tooltip(
            message: 'Rozbalit stream',
            child: InkWell(
              borderRadius: radius,
              onTap: onTap,
              child: Padding(
                padding: const EdgeInsets.only(left: 12, right: 4),
                child: SizedBox(
                  height: KioskStreamWindow.pillHeight,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.play_arrow, size: 20, color: scheme.primary),
                      const SizedBox(width: 6),
                      Text(
                        title,
                        style: Theme.of(context).textTheme.labelLarge,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          IconButton(
            tooltip: 'Zavřít stream',
            visualDensity: VisualDensity.compact,
            iconSize: 18,
            onPressed: onClose,
            icon: const Icon(Icons.close),
          ),
        ],
      ),
    );
  }
}
