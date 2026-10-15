/// Shared building blocks of the calendar-style schedule views: the hour
/// ruler, one day column (a Stack of time-positioned entries over hour
/// gridlines), the day header, and the column-snap physics. The kiosk board
/// (fit-height, read-only) and the app's week view (fixed scale, scrollable,
/// interactive) both compose these — they share ONE [CalendarWindow] +
/// px/minute pair per build, so the ruler and every column are geometrically
/// aligned by construction.
library;

import 'package:flutter/material.dart';

import '../../../core/widgets/emoji_text.dart';
import '../../../core/theme.dart';
import '../../../core/ui.dart';
import '../../../domain/calendar_layout.dart';
import '../../../domain/labels.dart' show BandLine, bandGap;
import '../../../domain/models.dart';
import '../../../domain/schedule.dart' show headerEventLabel;
import 'day_matches_dialog.dart';

/// Width of the hour ruler column.
const double calendarRulerWidth = 46.0;

/// Height of every day-column header (shared so column content below the
/// headers starts on one line).
const double calendarHeaderHeight = 56.0;

/// The base header comfortably fits the day label + two event lines; every
/// event beyond that adds one 10px/1.25 line. ALL columns of a board share
/// the height of the busiest day (the ruler offset must match too), so a
/// third match on Thursday never gets clipped away.
double boardHeaderHeight(int maxEvents) =>
    calendarHeaderHeight + (maxEvents <= 2 ? 0 : (maxEvents - 2) * 13.0);

/// Height of the collapsed (scrolled-down) header strip: exactly the
/// day+date line (2px padding + one 16px line + 2px) — a taller strip
/// would leave a sliver of the first event line peeking through the clip.
const double collapsedHeaderHeight = 20.0;

/// What a [BoardBand] adds to the header's height: an 18px strip and the
/// 2px between it and the label or the events. A board drawing one adds it
/// to [boardHeaderHeight] for every column, banded or not, so the day
/// labels stay on one line — wherever in the header the band runs.
const double boardBandHeight = 20.0;

/// One time-positioned widget inside a [CalendarColumn].
class CalendarEntry {
  const CalendarEntry({
    required this.start,
    required this.end,
    required this.child,
  });

  final HourMinute start;
  final HourMinute end;
  final Widget child;
}

/// The hour ruler: right-aligned `HH:00` labels on the shared hour lines,
/// plus quieter `HH:30` labels when [halfHourMarks] is set (the alley
/// actually uses half-hour block boundaries). Labels thin out automatically
/// when the scale gets too tight.
class HourRuler extends StatelessWidget {
  const HourRuler({
    super.key,
    required this.window,
    required this.pxPerMinute,
    this.halfHourMarks = false,
  });

  final CalendarWindow window;
  final double pxPerMinute;

  /// Also label (and let columns line) the half hours — only worth the ink
  /// when some visible block starts/ends on one.
  final bool halfHourMarks;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final hourPx = pxPerMinute * 60;
    final step = hourPx >= 26 ? 1 : (hourPx >= 13 ? 2 : 3);
    final showHalves = halfHourMarks && step == 1 && hourPx >= 28;
    final firstHour = (window.startMinute + 59) ~/ 60;
    final labels = <Widget>[];
    for (var m = window.startMinute; m <= window.endMinute; m += 30) {
      final isHour = m % 60 == 0;
      // Step is anchored to the window's first full hour so the top of the
      // window always gets a label even when thinning.
      if (isHour && (m ~/ 60 - firstHour) % step != 0) continue;
      // A window starting on :30 labels its top edge even without the
      // half-hour marks (an event can stretch the window to :30 while every
      // block stays hour-aligned).
      if (!isHour && !showHalves && m != window.startMinute) continue;
      labels.add(Positioned(
        top: (m - window.startMinute) * pxPerMinute - 6,
        right: 6,
        child: Text(
          '${'${m ~/ 60}'.padLeft(2, '0')}:${'${m % 60}'.padLeft(2, '0')}',
          style: TextStyle(
            fontSize: 10,
            fontWeight: FontWeight.w600,
            color: scheme.onSurfaceVariant
                .withValues(alpha: isHour ? 0.7 : 0.45),
          ),
        ),
      ));
    }
    return SizedBox(
      width: calendarRulerWidth,
      height: window.minutes * pxPerMinute,
      child: Stack(clipBehavior: Clip.none, children: labels),
    );
  }
}

/// One day's time area: hour gridlines, an optional full-height [background]
/// (e.g. the closed-day filler), the time-positioned [entries], a "now" line
/// when [nowMinute] is set, and — when [onTapFreeAt] is given — taps on
/// uncovered space reported as the minute under the finger. Entries sit
/// above the tap target, so a tap only counts as "free" if no entry consumed
/// it AND the caller's own gap check agrees.
class CalendarColumn extends StatefulWidget {
  const CalendarColumn({
    super.key,
    required this.window,
    required this.pxPerMinute,
    required this.entries,
    this.background,
    this.nowMinute,
    this.onTapFreeAt,
    this.onDropAt,
    this.onDragAt,
    this.onDragExit,
    this.halfHourMarks = false,
  });

  final CalendarWindow window;
  final double pxPerMinute;
  final List<CalendarEntry> entries;
  final Widget? background;

  /// Draw fainter half-hour gridlines too (see [HourRuler.halfHourMarks]).
  final bool halfHourMarks;

  /// Minutes from midnight to draw the current-time line at (today's column
  /// only), already known to lie inside the window.
  final int? nowMinute;

  /// Admin-only: called with the minute-from-midnight under a tap that
  /// landed on empty (entry-free) space.
  final void Function(int minute)? onTapFreeAt;

  /// Drag&drop landing: called with the dragged payload and the minute the
  /// FEEDBACK'S TOP EDGE landed on (the ghost's top is what the admin
  /// aligns) — the caller snaps/validates/commits.
  final void Function(Object data, int minute)? onDropAt;

  /// Fires continuously while a drag hovers over this column, with the same
  /// top-edge minute as [onDropAt] — callers use it to live-preview the
  /// would-be drop time on the ghost. [onDragExit] fires when the ghost
  /// leaves the column so the preview can reset.
  final void Function(Object data, int minute)? onDragAt;
  final void Function(Object data)? onDragExit;

  @override
  State<CalendarColumn> createState() => _CalendarColumnState();
}

class _CalendarColumnState extends State<CalendarColumn> {
  /// The DragTarget builder's context — the drop handler resolves the
  /// column's RenderBox through it (a GlobalKey here trips DragTarget's
  /// child-identity assert when the subtree rebuilds mid-drag).
  BuildContext? _targetContext;

  CalendarWindow get window => widget.window;
  double get pxPerMinute => widget.pxPerMinute;
  List<CalendarEntry> get entries => widget.entries;
  Widget? get background => widget.background;
  int? get nowMinute => widget.nowMinute;
  void Function(int minute)? get onTapFreeAt => widget.onTapFreeAt;
  void Function(Object data, int minute)? get onDropAt => widget.onDropAt;
  bool get halfHourMarks => widget.halfHourMarks;

  /// Top-edge minute for a drag event, or null when the column's RenderBox
  /// isn't resolvable (mid-rebuild).
  int? _dragMinute(Offset globalOffset) {
    final box = _targetContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.attached) return null;
    final local = box.globalToLocal(globalOffset);
    return window.minuteAt(local.dy, pxPerMinute);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final firstHour = window.startMinute ~/ 60 + 1;
    final lastHour = (window.endMinute - 1) ~/ 60;

    Widget base = Stack(
      children: [
        if (background != null) Positioned.fill(child: background!),
        for (var h = firstHour; h <= lastHour; h++)
          Positioned(
            top: (h * 60 - window.startMinute) * pxPerMinute,
            left: 0,
            right: 0,
            child: Divider(
              height: 1,
              thickness: 1,
              color: scheme.outlineVariant.withValues(alpha: 0.25),
            ),
          ),
        if (halfHourMarks)
          for (var m = window.startMinute - window.startMinute % 60 + 30;
              m < window.endMinute;
              m += 60)
            if (m > window.startMinute)
              Positioned(
                top: (m - window.startMinute) * pxPerMinute,
                left: 0,
                right: 0,
                child: Divider(
                  height: 1,
                  thickness: 1,
                  color: scheme.outlineVariant.withValues(alpha: 0.12),
                ),
              ),
        for (final entry in entries)
          Positioned(
            top: window.topFor(entry.start, pxPerMinute),
            left: 0,
            right: 0,
            height: window.heightFor(entry.start, entry.end, pxPerMinute),
            child: entry.child,
          ),
        if (nowMinute != null)
          Positioned(
            top: (nowMinute! - window.startMinute) * pxPerMinute - 1,
            left: 0,
            right: 0,
            child: IgnorePointer(
              child: Row(
                children: [
                  Container(
                    width: 6,
                    height: 6,
                    decoration: BoxDecoration(
                      color: scheme.error,
                      shape: BoxShape.circle,
                    ),
                  ),
                  Expanded(child: Container(height: 2, color: scheme.error)),
                ],
              ),
            ),
          ),
      ],
    );
    if (onTapFreeAt != null) {
      base = GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapUp: (details) =>
            onTapFreeAt!(window.minuteAt(details.localPosition.dy, pxPerMinute)),
        child: base,
      );
    }
    if (onDropAt != null) {
      // NOTE: capture into a `final` FIRST — Dart closures capture the
      // VARIABLE, so `return base;` after the reassignment below would
      // return the DragTarget itself and recurse forever.
      final inner = base;
      base = DragTarget<Object>(
        onWillAcceptWithDetails: (_) => true,
        onAcceptWithDetails: (details) {
          final minute = _dragMinute(details.offset);
          if (minute != null) onDropAt!(details.data, minute);
        },
        onMove: widget.onDragAt == null
            ? null
            : (details) {
                final minute = _dragMinute(details.offset);
                if (minute != null) widget.onDragAt!(details.data, minute);
              },
        onLeave: widget.onDragExit == null
            ? null
            : (data) {
                if (data != null) widget.onDragExit!(data);
              },
        builder: (context, candidates, rejected) {
          _targetContext = context;
          return inner;
        },
      );
    }
    return SizedBox(height: window.minutes * pxPerMinute, child: base);
  }
}

/// A type/rental-colored band for an event rendered outside any block —
/// positioned by a [CalendarEntry] at the event's true time.
class CalendarEventBand extends StatelessWidget {
  const CalendarEventBand({
    super.key,
    required this.background,
    required this.foreground,
    required this.text,
    this.bold = false,
    this.lines,
    this.fontSize = 10,
  });

  final Color background;
  final Color foreground;

  /// The band's text in two lines at most — what a short band shows.
  final String text;
  final bool bold;

  /// The same, line by line ([matchBandLines]: the cup with the time, a
  /// blank line, home, „x“, away) — shown when the band is tall enough for
  /// every line, else without its blank lines ([bandGap]) when that is
  /// enough; a team's name then wraps within its own line, onto as many as
  /// the band has to spare, rather than the pair breaking in the middle of
  /// one.
  final List<BandLine>? lines;

  /// The text's size in px — the app's 10, the kiosk admin's choice on the
  /// kiosk board (0069).
  final double fontSize;

  /// One line of the band's text as the engine lays it out — measured, not
  /// estimated: the Text below gets [style] over the inherited one (the
  /// theme's bodyMedium sets a line height of 1.43 of the size), the text
  /// scale, and the engine rounds the line to whole pixels. An estimate of
  /// 1.4 × the size held only at 10 px and the normal text size; anywhere
  /// else it fell short by up to a pixel a line, and a stack that used
  /// every line it was given ran past the band, the time row cut off.
  static double _lineHeight(BuildContext context, TextStyle style) {
    final inherited = DefaultTextStyle.of(context);
    final painter = TextPainter(
      text: TextSpan(text: '0', style: inherited.style.merge(style)),
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
      textHeightBehavior:
          DefaultTextHeightBehavior.maybeOf(context) ??
          inherited.textHeightBehavior,
      locale: Localizations.maybeLocaleOf(context),
      maxLines: 1,
    )..layout();
    final height = painter.height;
    painter.dispose();
    return height;
  }

  @override
  Widget build(BuildContext context) {
    final style = TextStyle(
      fontSize: fontSize,
      fontWeight: bold ? FontWeight.w700 : FontWeight.w600,
      color: foreground,
    );
    final lineHeight = _lineHeight(context, style);
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 3, vertical: 1.5),
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(6),
      ),
      alignment: Alignment.center,
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final fit = (constraints.maxHeight / lineHeight).floor();
          var rows = lines;
          // A line short: the blank lines go before the stack does.
          if (rows != null && fit < rows.length) {
            rows = [
              for (final r in rows)
                if (r != bandGap) r,
            ];
          }
          if (rows == null || fit < rows.length) {
            return EmojiText(
              text,
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: style,
            );
          }
          // The lines to spare go to the lines that wrap (the names, the
          // cup with the time), shared evenly: each wraps onto as many as
          // it gets, then ellipsizes.
          final wrapping = rows.where((r) => r.wraps).length;
          final wrapLines = wrapping == 0
              ? 1
              : 1 + (fit - rows.length) ~/ wrapping;
          return Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final row in rows)
                if (row == bandGap)
                  SizedBox(height: lineHeight)
                else
                  // Each row held to the lines it was given, so the stack
                  // is never taller than the band whatever a row draws: the
                  // cup's image sets its line a pixel taller than the
                  // text's at some sizes (12 px: 18 against 17) — that pixel
                  // goes, empty under the image, which stays whole.
                  ConstrainedBox(
                    constraints: BoxConstraints(
                      maxHeight: (row.wraps ? wrapLines : 1) * lineHeight,
                    ),
                    child: EmojiText(
                      row.text,
                      textAlign: TextAlign.center,
                      maxLines: row.wraps ? wrapLines : 1,
                      overflow: TextOverflow.ellipsis,
                      style: style,
                    ),
                  ),
            ],
          );
        },
      ),
    );
  }
}

/// Where a band's one label stands and how wide it is drawn while the
/// board scrolls, like a multi-day event's title in Google Calendar —
/// [viewportLeft] (the visible row's left edge), [bandStart] and [bandEnd]
/// in one space, the header list's scroll space. The label starts
/// [padding] in from the band's visible start: the band's start while
/// that is in view, the row's left edge once the band runs off it. It is
/// [labelWidth] wide, or as wide as the room left before the band's end
/// ([padding] short of it) where that is less — cut there with an
/// ellipsis, so a name is never cut in its middle by the row's edge. Only
/// when that room falls below [minWidth] (about two glyphs and the
/// ellipsis) does the end push the label, that wide, off to the left with
/// the band — never past the end; a band too narrow even for that keeps
/// it at its start, cut to the band. Continuous in [viewportLeft]:
/// scrolling moves or narrows the label, never makes it jump.
({double left, double width}) stickyBandLabel({
  required double viewportLeft,
  required double bandStart,
  required double bandEnd,
  required double labelWidth,
  double padding = 6,
  double minWidth = 24,
}) {
  final visible = viewportLeft > bandStart ? viewportLeft : bandStart;
  final left = visible + padding;
  final room = bandEnd - padding - left;
  if (room >= labelWidth) return (left: left, width: labelWidth);
  final least = labelWidth < minWidth ? labelWidth : minWidth;
  if (room >= least) return (left: left, width: room);
  final first = bandStart + padding;
  final pushed = bandEnd - padding - least;
  final kept = pushed < first ? first : pushed;
  final width = bandEnd - padding - kept;
  return (left: kept, width: width < 0 ? 0.0 : width);
}

/// One day's piece of a band drawn across the board's day headers, like an
/// all-day event — the kiosk's canteen duty (0073). The band runs [days]
/// days and this piece is its [day]: rounded where the band starts and
/// ends. Every piece carries the band's one [label] and draws the part of
/// it that crosses the piece, where and as wide as [stickyBandLabel] puts
/// it in the header list ([scroll]) — so it reads as one text however the
/// board scrolls; null leaves the band blank.
class BoardBandSegment {
  const BoardBandSegment({
    required this.day,
    required this.days,
    this.label,
    this.onTap,
    this.scroll,
    this.column = 0,
  }) : assert(0 <= day && day < days);

  /// This piece's day in the band, from 0 — the band's first day may lie
  /// before the board's first column (a band begun before it).
  final int day;

  /// How many days the band runs.
  final int days;

  final String? label;
  final VoidCallback? onTap;

  /// The header list the pieces scroll in: the label follows it frame by
  /// frame. Null: a list standing at its start.
  final ScrollController? scroll;

  /// This piece's column in that list — its columns one width, from 0.
  final int column;

  /// The band's first day: rounded, a little in from the column's side.
  bool get starts => day == 0;

  /// The band's last day, likewise.
  bool get ends => day == days - 1;
}

/// A [BoardBandSegment] in its [boardBandHeight]: a strip tinted
/// `secondaryContainer`, out to the column's edge where the band runs on —
/// over the header's [bleed] too, so the neighbours' pieces meet — a
/// little in and rounded where it starts or ends, with its part of the
/// band's one-line label ([BoardBandSegment.label]).
class BoardBand extends StatelessWidget {
  const BoardBand({
    super.key,
    required this.segment,
    this.bleed = 0,
    this.leading = false,
  });

  static const radius = Radius.circular(6);

  /// How far in from the header's background the strip starts or ends.
  static const endInset = 4.0;

  /// The label's room from the strip's ends, and from the row's left edge
  /// it sticks to ([stickyBandLabel]).
  static const labelPadding = 6.0;

  final BoardBandSegment segment;

  /// How far past its own sides the strip reaches where the band runs on:
  /// the header's [BoardColumnHeader.gap].
  final double bleed;

  /// The band opens the header (above the day label): its 2px go under the
  /// strip, which then sits on the header's top edge. Otherwise they go
  /// above it, apart from the label or the events.
  final bool leading;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final label = segment.label;
    final left = segment.starts ? endInset : -bleed;
    final right = segment.ends ? endInset : -bleed;
    return Padding(
      padding: leading
          ? const EdgeInsets.only(bottom: 2)
          : const EdgeInsets.only(top: 2),
      child: SizedBox(
        height: boardBandHeight - 2,
        width: double.infinity,
        // Unclipped past the sides: the [bleed] is painted, a touch on
        // that sliver misses the strip.
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            Positioned.fill(
              left: left,
              right: right,
              child: Material(
                color: scheme.secondaryContainer,
                borderRadius: BorderRadius.horizontal(
                  left: segment.starts ? radius : Radius.zero,
                  right: segment.ends ? radius : Radius.zero,
                ),
                clipBehavior: Clip.antiAlias,
                child: InkWell(
                  onTap: segment.onTap,
                  child: const SizedBox.expand(),
                ),
              ),
            ),
            // Over the strip, not in it: the label stays [labelPadding]
            // clear of the rounded ends, so a plain clip to the strip
            // will do — and the neighbours' clips meet on one pixel, the
            // text across them unbroken. The strip takes the touch.
            if (label != null)
              Positioned.fill(
                left: left,
                right: right,
                child: IgnorePointer(
                  child: _BandLabel(
                    segment: segment,
                    label: label,
                    bleed: bleed,
                    style: theme.textTheme.labelSmall?.copyWith(
                      fontWeight: FontWeight.w600,
                      color: scheme.onSecondaryContainer,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// A piece's part of the band's label: the whole label where and as wide
/// as [stickyBandLabel] puts it (cut with an ellipsis where it is
/// narrower), clipped to the piece's strip — nothing where it does not
/// cross the piece. Only this rebuilds while the header list scrolls; the
/// strip and the header stay as they are.
class _BandLabel extends StatelessWidget {
  const _BandLabel({
    required this.segment,
    required this.label,
    required this.bleed,
    required this.style,
  });

  final BoardBandSegment segment;
  final String label;
  final double bleed;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) {
    final style = DefaultTextStyle.of(context).style.merge(this.style);
    final direction = Directionality.of(context);
    final scaler = MediaQuery.textScalerOf(context);
    // Measured as the [Text] below lays it out, the reader's text size
    // included: the label is cut, and pushed, by its real right edge.
    double measure(String text) {
      final painter = TextPainter(
        text: TextSpan(text: text, style: style),
        textDirection: direction,
        textScaler: scaler,
        maxLines: 1,
      )..layout();
      final width = painter.width;
      painter.dispose();
      return width;
    }

    final labelWidth = measure(label);
    // The least worth cutting the label to: two glyphs and the ellipsis.
    final minWidth = measure('${label.characters.take(2)}…');
    return LayoutBuilder(
      builder: (context, constraints) {
        // In the header list's scroll space: the column's width and where
        // this strip, the band's start and its end lie.
        const pad = BoardBand.labelPadding;
        final end = bleed + BoardBand.endInset;
        final s = segment;
        final stripWidth = constraints.maxWidth;
        final columnWidth =
            (s.starts ? end : 0) + stripWidth + (s.ends ? end : 0);
        final stripLeft = s.column * columnWidth + (s.starts ? end : 0);
        final firstColumn = s.column - s.day;
        final bandStart = firstColumn * columnWidth + end;
        final bandEnd = (firstColumn + s.days) * columnWidth - end;

        final scroll = s.scroll;

        Widget place(BuildContext context, Widget? _) {
          // Not [ScrollController.offset]: a list built anew around the
          // controller attaches before the old one lets go, and for that
          // frame there are two. The newest is the one being built.
          final positions = scroll?.positions;
          final viewportLeft = positions == null || positions.isEmpty
              ? 0.0
              : positions.last.pixels;
          final at = stickyBandLabel(
            viewportLeft: viewportLeft,
            bandStart: bandStart,
            bandEnd: bandEnd,
            labelWidth: labelWidth,
            padding: pad,
            minWidth: minWidth,
          );
          final x = at.left - stripLeft;
          if (at.width <= 0 || x >= stripWidth || x + at.width <= 0) {
            return const SizedBox.shrink();
          }
          return Stack(
            clipBehavior: Clip.hardEdge,
            children: [
              Positioned(
                left: x,
                top: 0,
                bottom: 0,
                // Where the band left in view is narrower, the label is
                // cut to it with an ellipsis.
                width: at.width,
                child: Align(
                  alignment: Alignment.centerLeft,
                  // Read once: by the piece where the label starts.
                  child: ExcludeSemantics(
                    excluding: x < 0,
                    child: Text(
                      label,
                      maxLines: 1,
                      softWrap: false,
                      overflow: TextOverflow.ellipsis,
                      style: style,
                    ),
                  ),
                ),
              ),
            ],
          );
        }

        return scroll == null
            ? place(context, null)
            : ListenableBuilder(listenable: scroll, builder: place);
      },
    );
  }
}

/// One board column's header: the day label (today gets the "DNES · …"
/// gradient treatment) pinned to the TOP edge — same y in every column no
/// matter how many events a day has — with the day's events stacked under
/// it, one ellipsized line each ('🏠 domáci zápas · od–do', away matches
/// without any icon, ⛔ blockages; pass [headerEvents]' output). A quiet
/// [subtitle] shows when there are none. A [band] runs above the label,
/// between the label and the events or along the bottom edge
/// ([bandPosition]). When [collapsed], only the day label renders as a
/// thin strip. Typed on [date] so widget tests can enumerate visible days.
class BoardColumnHeader extends StatelessWidget {
  const BoardColumnHeader({
    super.key,
    required this.date,
    required this.isToday,
    required this.priority,
    this.height = calendarHeaderHeight,
    this.collapsed = false,
    this.subtitle,
    this.onAdd,
    this.interactive = true,
    this.watch,
    this.onOpenMatch,
    this.onPlayVideo,
    this.pulseLive = true,
    this.dayMatchesWidth = 340,
    this.band,
    this.bandPosition,
    this.gap = 0,
  }) : assert(band == null || bandPosition != null);

  final Day date;
  final bool isToday;
  final List<PrioritySlot> priority;

  /// The freed-spot bell (0058), beside the [subtitle]; null = none.
  final Widget? watch;

  /// Shared per-board header height — [boardHeaderHeight] of the busiest
  /// visible day, so every event line fits without clipping.
  final double height;

  /// Scrolled-down mode: a [collapsedHeaderHeight] strip with the day label
  /// only (events reappear at the top of the scroll).
  final bool collapsed;

  /// Quiet second line shown when [priority] is empty (e.g. "3 volné").
  final String? subtitle;

  /// Admin-only (week view): tapping the header opens the add-slot dialog
  /// for this day — a packed column may have no empty space left to tap.
  final VoidCallback? onAdd;

  /// Passed straight through to [showDayMatchesDialog]: false on the kiosk
  /// board and the public overview (see its own doc for why).
  final bool interactive;

  /// The kiosk's: a finished match of the day's list opens its Zápis (see
  /// [showDayMatchesDialog]).
  final void Function(PrioritySlot match)? onOpenMatch;

  /// The kiosk's: the video control of a match in the day's list plays it
  /// in the kiosk's stream window (see [showDayMatchesDialog]).
  final void Function(PrioritySlot match)? onPlayVideo;

  /// The live badge in the day's list pulses (see [showDayMatchesDialog]);
  /// the kiosk's „Opakující se animace“.
  final bool pulseLive;

  /// The width of the day's list (see [showDayMatchesDialog]): the app's
  /// 340, the kiosk's as its admin sets it (0075).
  final double dayMatchesWidth;

  /// The kiosk's: this day's piece of the band across the headers (the
  /// canteen duty, 0073), a [BoardBand] where [bandPosition] says; null =
  /// none on this day.
  final BoardBandSegment? band;

  /// The kiosk's, with the band on: where it runs in the headers (the
  /// admin's choice, 0073) — on the top edge above the day label, under
  /// the label, or on the bottom edge under the events, there however many
  /// lines the day has. [height] must hold its [boardBandHeight], the same
  /// in each; a day without a [band] piece keeps its label on the line of
  /// the others. Null (the app's week board): no band, no room for one.
  final KioskDutyBandPosition? bandPosition;

  /// The kiosk's: how far the background stands in from each side — the
  /// room the board keeps between neighbouring headers, drawn inside the
  /// header so the [band] runs on through it. 0 (the app's week board,
  /// its headers side by side): none.
  final double gap;

  /// The label's and the events' sides (the [band] has none).
  static const _inset = EdgeInsets.symmetric(horizontal: 6);

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final dayText = Text(
      isToday ? 'DNES · ${dayLabel(date)}' : dayLabel(date),
      textAlign: TextAlign.center,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(
        fontSize: 12,
        fontWeight: FontWeight.w800,
        color: isToday ? Colors.white : scheme.onSurface,
      ),
    );
    // Gone in the thin strip, which has room for the label alone.
    final bandAt = collapsed ? null : bandPosition;
    final piece = band;
    final pad = collapsed ? 2.0 : 4.0;
    // The content is ALWAYS the full top-anchored column; collapsing just
    // animates the container height down so the event lines clip away —
    // that's what makes the squeeze read as one smooth motion instead of a
    // content swap.
    final body = AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeOutCubic,
      height: collapsed ? collapsedHeaderHeight : height,
      margin: EdgeInsets.symmetric(horizontal: gap),
      // The sides inset the label and the events, not the [band]: it runs
      // on from column to column. On the top or the bottom edge it takes
      // that edge's padding too.
      padding: EdgeInsets.only(
        top: bandAt == KioskDutyBandPosition.top ? 0 : pad,
        bottom: bandAt == KioskDutyBandPosition.bottom ? 0 : pad,
      ),
      decoration: BoxDecoration(
        gradient:
            isToday ? const LinearGradient(colors: brandGradientColors) : null,
        color: isToday ? null : scheme.surfaceContainerHigh,
      ),
      child: Column(
        // Top-anchored: the day+date line sits on ONE height across all
        // columns; events stack under it. When collapsed they also FADE —
        // the clip alone can leave a pixel-high sliver of the first event
        // line visible under the day label.
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          // Above the label the band's room stays on a day without a
          // piece: the labels keep to one line.
          if (bandAt == KioskDutyBandPosition.top)
            piece == null
                ? const SizedBox(height: boardBandHeight)
                : BoardBand(segment: piece, bleed: gap, leading: true),
          Padding(padding: _inset, child: dayText),
          if (bandAt == KioskDutyBandPosition.middle && piece != null)
            BoardBand(segment: piece, bleed: gap),
          Padding(
            padding: _inset,
            child: AnimatedOpacity(
              duration: const Duration(milliseconds: 150),
              opacity: collapsed ? 0 : 1,
              // The event lines are one-line ellipsised, so a long match
              // reads "…"; tapping the strip opens the day's events in full.
              // Not while collapsed — then the header's own tap (admin: add
              // a slot) wins.
              child: priority.isNotEmpty
                  ? GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: collapsed
                          ? null
                          : () => showDayMatchesDialog(
                                context,
                                date,
                                priority,
                                interactive: interactive,
                                onOpenMatch: onOpenMatch,
                                onPlayVideo: onPlayVideo,
                                pulseLive: pulseLive,
                                width: dayMatchesWidth,
                              ),
                      child: Column(
                        children: [
                          for (final m in priority)
                            EmojiText(
                              headerEventLabel(m),
                              textAlign: TextAlign.center,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 10,
                                height: 1.25,
                                color: isToday
                                    ? Colors.white.withValues(alpha: 0.9)
                                    : scheme.primary,
                              ),
                            ),
                        ],
                      ),
                    )
                  : subtitle != null
                      ? Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Flexible(
                              child: Text(
                                subtitle!,
                                textAlign: TextAlign.center,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 10,
                                  color: isToday
                                      ? Colors.white.withValues(alpha: 0.85)
                                      : scheme.onSurfaceVariant
                                          .withValues(alpha: 0.7),
                                ),
                              ),
                            ),
                            if (watch != null) ...[
                              const SizedBox(width: 2),
                              watch!,
                            ],
                          ],
                        )
                      : const SizedBox.shrink(),
            ),
          ),
          // The header's height is fixed: the room the day's lines leave
          // goes above the band, which stays on the bottom edge.
          if (bandAt == KioskDutyBandPosition.bottom && piece != null) ...[
            const Spacer(),
            BoardBand(segment: piece, bleed: gap),
          ],
        ],
      ),
    );
    // Clipped here, around the [gap], not by the container inside it: the
    // [band] runs on through the gap.
    final clipped = ClipRect(child: body);
    if (onAdd == null) return clipped;
    return InkWell(onTap: onAdd, child: clipped);
  }
}

/// Column-snap scroll physics for the horizontal day list. A plain
/// [PageView] can't be used instead because its `viewportFraction` — the
/// mechanism that would let multiple column-widths share one viewport — is
/// fixed at [PageController] construction time, before the [LayoutBuilder]
/// that computes the column width from the available width ever runs. This
/// mirrors [PageScrollPhysics]'s own `createBallisticSimulation`,
/// substituting `pixels / columnWidth` for its "page" unit so a fling
/// settles on the nearest column boundary.
class ColumnSnapPhysics extends ScrollPhysics {
  const ColumnSnapPhysics({required this.columnWidth, super.parent});

  final double columnWidth;

  @override
  ColumnSnapPhysics applyTo(ScrollPhysics? ancestor) =>
      ColumnSnapPhysics(columnWidth: columnWidth, parent: buildParent(ancestor));

  double _targetPixels(
      ScrollMetrics position, Tolerance tolerance, double velocity) {
    var column = position.pixels / columnWidth;
    if (velocity < -tolerance.velocity) {
      column -= 0.5;
    } else if (velocity > tolerance.velocity) {
      column += 0.5;
    }
    return column.roundToDouble() * columnWidth;
  }

  @override
  Simulation? createBallisticSimulation(
      ScrollMetrics position, double velocity) {
    if ((velocity <= 0.0 && position.pixels <= position.minScrollExtent) ||
        (velocity >= 0.0 && position.pixels >= position.maxScrollExtent)) {
      return super.createBallisticSimulation(position, velocity);
    }
    final tolerance = toleranceFor(position);
    final target = _targetPixels(position, tolerance, velocity)
        .clamp(position.minScrollExtent, position.maxScrollExtent);
    if (target != position.pixels) {
      return ScrollSpringSimulation(spring, position.pixels, target, velocity,
          tolerance: tolerance);
    }
    return null;
  }

  @override
  bool get allowImplicitScrolling => false;
}
