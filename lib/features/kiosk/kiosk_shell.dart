/// Kiosk shell: fullscreen status bar + week grid, no AppBar, no navigation,
/// no cancel — the shared-tablet UI performs exactly one action (book a
/// slot for whichever player picks themselves from the name picker).
/// Selection and half-finished picker state both reset after 60 s of no
/// touch, so a walked-away kiosk never leaves someone else's name selected.
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme.dart';
import '../../core/ui.dart';
import '../../core/widgets/gradient_button.dart';
import '../../data/clock.dart';
import '../../data/providers.dart';
import '../../domain/kiosk_header.dart';
import '../../domain/kiosk_layout.dart';
import '../../domain/kiosk_panel.dart'
    show hasKioskVideo, kioskNotices, kioskStreamLabel;
import '../../domain/models.dart';
import '../../domain/namedays.dart' show czechNameDay, nameDayHeader;
import '../../domain/results.dart' show hasScoreData;
import '../../domain/schedule.dart'
    show headerEventLabel, isDayOpen, nextTrainingDay;
import '../../domain/weather.dart' show freshWeather;
import 'kiosk_board_view.dart';
import 'kiosk_info_panel.dart';
import 'kiosk_connection.dart';
import 'kiosk_day_info.dart';
import 'kiosk_display.dart';
import 'kiosk_duty.dart';
import 'kiosk_feedback.dart';
import 'kiosk_guide.dart';
import 'kiosk_header_module.dart';
import 'kiosk_headline.dart';
import 'kiosk_warning.dart';
import 'kiosk_stream_window.dart';
import 'kiosk_week.dart';
import 'kiosk_zapis_page.dart';
import 'name_picker.dart';
import '../../core/widgets/emoji_text.dart';
import '../schedule/widgets/calendar_board.dart' show calendarRulerWidth;

/// How long before the idle reset the bar starts running out.
const _warnFor = Duration(seconds: 10);

/// The kiosk's main action, in the status bar: what the wall tablet is for.
const kioskReserveLabel = 'Rezervace tréninku';

class KioskShell extends ConsumerStatefulWidget {
  const KioskShell({super.key});

  @override
  ConsumerState<KioskShell> createState() => _KioskShellState();
}

class _KioskShellState extends ConsumerState<KioskShell>
    with SingleTickerProviderStateMixin {
  Timer? _idleTimer;

  /// The last seconds before the idle reset, drawn as a thin bar running
  /// out under the status line — so a visitor is not surprised when the
  /// kiosk starts over. Only after a touch: an untouched kiosk has nothing
  /// to reset.
  Timer? _warnTimer;
  late final AnimationController _warning = AnimationController(
    vsync: this,
    duration: _warnFor,
  );
  PlayerName? _selected;

  /// What a visitor did to each panel (true = open); a side missing = the
  /// admin's resting state. The idle reset puts both back.
  final _drawerOverride = <PanelSide, bool>{};

  /// Bumped on every idle reset; the panels' cards that scroll or page
  /// (the match list, the duty plan) start over on it.
  int _resets = 0;

  /// A visitor switched from the match being played to the list of
  /// matches; the idle reset brings the live match back.
  bool _liveHidden = false;

  /// The days a visitor scrolled the board to; null = never (or reset).
  ({Day first, Day last})? _boardDays;
  final _boardKey = GlobalKey<KioskBoardViewState>();

  /// The display, held (screen on, bars hidden) for as long as the shell is
  /// on it — read once, so dispose does not go through ref.
  late final KioskDisplay _display;

  @override
  void initState() {
    super.initState();
    _display = ref.read(kioskDisplayProvider);
    unawaited(_display.hold());
    // The admin's „Nižší rozlišení“ as the shell comes up; build's listener
    // follows later changes (and the settings' first arrival).
    final lowRes = ref.read(settingsProvider).value?.kioskLowRes;
    if (lowRes != null) _display.lowRes(lowRes);
    _touch(byHand: false);
  }

  @override
  void dispose() {
    _idleTimer?.cancel();
    _warnTimer?.cancel();
    _warning.dispose();
    unawaited(_display.release());
    _display.forgetLowRes();
    super.dispose();
  }

  void _touch({bool byHand = true}) {
    _idleTimer?.cancel();
    _warnTimer?.cancel();
    _warning.reset();
    final seconds = ref.read(settingsProvider).value?.kioskIdleSeconds ?? 60;
    final idle = Duration(seconds: seconds);
    _idleTimer = Timer(idle, _onIdle);
    if (byHand && idle > _warnFor) {
      _warnTimer = Timer(idle - _warnFor, () {
        if (mounted) _warning.forward(from: 0);
      });
    }
  }

  void _onIdle() {
    if (!mounted) return;
    // Pop unconditionally (root navigator — dialogs push onto it): besides
    // the name picker this also dismisses an abandoned booking-confirm
    // dialog, which captured the previously selected player and would let
    // the next visitor book under their name.
    Navigator.of(context, rootNavigator: true).popUntil((r) => r.isFirst);
    setState(() {
      _selected = null;
      _drawerOverride.clear();
      _boardDays = null;
      _liveHidden = false;
      _resets++;
    });
    // Board horizontal scroll resets to today too (spec §1) — imperative
    // because the board owns its own PageController; there's no offset
    // field on this shell to reset via rebuild the way _weekOffset used to.
    _boardKey.currentState?.resetToToday();
  }

  Future<void> _openPicker() async {
    final kioskDark = ref.read(settingsProvider).value?.kioskDark ?? true;
    final picked = await showNamePicker(
      context,
      brightness: kioskDark ? Brightness.dark : Brightness.light,
      wrap: _touchable,
    );
    if (!mounted) return;
    setState(() {
      if (picked != null) _selected = picked;
    });
  }

  void _clearSelection() => setState(() => _selected = null);

  /// The kiosk's own theme — dialogs and routes are pushed on the root
  /// navigator, outside the [Theme] this shell wraps around itself.
  ThemeData _kioskTheme() => buildTheme(
    (ref.read(settingsProvider).value?.kioskDark ?? true)
        ? Brightness.dark
        : Brightness.light,
  );

  /// A route or dialog above the shell is outside its idle [Listener]:
  /// give it its own, so reading a Zápis counts as touching the kiosk.
  Widget _touchable(Widget child) => Listener(
    onPointerDown: (_) => _touch(),
    onPointerSignal: (_) => _touch(),
    onPointerPanZoomStart: (_) => _touch(),
    behavior: HitTestBehavior.translucent,
    child: Theme(data: _kioskTheme(), child: child),
  );

  Future<void> _openNotice(Message notice) => showDialog<void>(
    context: context,
    builder: (context) => _touchable(
      AlertDialog(
        title: Text(notice.title ?? ''),
        content: SizedBox(
          width: 560,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(notice.body),
                if (notice.expiresAt != null) ...[
                  const SizedBox(height: 12),
                  Text(
                    'Platí do ${notice.expiresAt!.toLocal().day}. '
                    '${notice.expiresAt!.toLocal().month}.',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Zavřít'),
          ),
        ],
      ),
    ),
  );

  /// A tap on a match of the board or the header: one with a score opens
  /// its Zápis; one without, but with a video, its stream — while the
  /// streams are on ([_play]).
  void _openMatchOrStream(PrioritySlot match) {
    final result = ref.read(matchResultsProvider).value?[match.id];
    final play = _play;
    if (hasScoreData(result)) {
      _openMatch(match);
    } else if (play != null && hasKioskVideo(match)) {
      play(match);
    }
  }

  /// A visitor's ▶ (0072): [match]'s video in a stream window.
  void _openStream(PrioritySlot match) =>
      ref.read(kioskStreamsProvider.notifier).open(match.id);

  /// The canteen duty's plan (0073), from wherever the kiosk names who
  /// serves.
  void _openDuty() =>
      unawaited(showKioskDutyDialog(context, wrap: _touchable));

  /// „Jak začít“ whole, with the large QR code — a tap on its card in a
  /// panel.
  void _openGuide() => unawaited(showKioskGuide(context, wrap: _touchable));

  /// „Napište nám“'s QR code large — a tap on its card in a panel.
  void _openFeedback() =>
      unawaited(showKioskFeedback(context, wrap: _touchable));

  /// „Hráči týdne“ full screen (0078) — a tap on its card in a panel; a tap
  /// on a line there opens that match's Zápis over it.
  void _openWeek() => unawaited(
    showKioskWeekPlayers(
      context,
      wrap: _touchable,
      onOpenMatch: (match) => _openMatch(match, overWeek: true),
    ),
  );

  /// The ▶ handed to everything that has one — the drawer's matches, the
  /// live badge, the Zápis, a day's matches, a tap on a match without a
  /// score — or null while the admin has the streams off (0072): then none
  /// of them shows one, and [kioskStreamProvider] keeps the windows shut.
  /// Read, not watched: the shell's build watches the settings already, so
  /// a flip of the switch rebuilds whatever this was handed to.
  void Function(PrioritySlot match)? get _play {
    final on = ref.read(settingsProvider).value?.kioskStreamEnabled ?? true;
    return on ? _openStream : null;
  }

  /// [match]'s Zápis. [overWeek]: opened from the week's full-screen page,
  /// which covers the board — the stream window lives on the board, so the
  /// ▶ in that Zápis first closes the week too.
  void _openMatch(PrioritySlot match, {bool overWeek = false}) {
    final now = ref.read(nowProvider).value ?? DateTime.now();
    final play = _play;
    final settings = ref.read(settingsProvider).value;
    unawaited(
      showKioskZapis(
        context,
        slot: match,
        brightness: (settings?.kioskDark ?? true)
            ? Brightness.dark
            : Brightness.light,
        percent: settings?.kioskZapisPercent ?? 80,
        onTouch: _touch,
        nav: settings?.kioskZapisNav ?? KioskZapisNav.bar,
        // The ▶ of whichever match the Zápis shows (it pages, 0079): it
        // closes and the stream opens beside the board.
        playFor: play == null
            ? null
            : (m) => hasKioskVideo(m)
                  ? (
                      label: kioskStreamLabel(
                        m,
                        ref.read(matchResultsProvider).value?[m.id],
                        now,
                      ),
                      onPlay: () {
                        // Behind the week's page the player would run
                        // unseen, sound and all: back to the board first.
                        if (overWeek) {
                          Navigator.of(
                            context,
                            rootNavigator: true,
                          ).popUntil((r) => r.isFirst);
                        }
                        play(m);
                      },
                    )
                  : null,
      ),
    );
  }

  /// The stream windows (0066, 0072) over [board] while a stream is open;
  /// [board] alone otherwise. Their own layer: the players and their
  /// frames move without re-recording the board.
  Widget _withStream(Widget board) {
    final streams = ref.watch(kioskStreamProvider);
    // The same tree with or without the windows — [board] stays in its
    // slot, so a stream opening or closing never re-inflates the board and
    // the drawer (the notices' turn, the list's weeks, the live refresh).
    return Stack(
      fit: StackFit.expand,
      children: [
        board,
        if (streams.isNotEmpty)
          RepaintBoundary(
            // No player takes touches while any route sits above the
            // shell's own — the name picker, a notice, a day's matches, the
            // Zápis, a booking confirm: on the web a dialog over an iframe
            // is see-through to YouTube (spec §5). The route itself says
            // so, nothing pushed later can be missed; isCurrentOf rebuilds
            // this builder on a push and a pop, not the board.
            child: Builder(
              builder: (context) => KioskStreamLayer(
                streams: streams,
                interactive: ModalRoute.isCurrentOf(context) ?? true,
              ),
            ),
          ),
      ],
    );
  }

  /// The board between the two panels (0077) — a side with nothing to show
  /// has neither a panel nor a button; with nothing on either side the
  /// board is alone.
  Widget _boardWithPanel() {
    final left = ref.watch(kioskPanelContentProvider(PanelSide.left));
    final right = ref.watch(kioskPanelContentProvider(PanelSide.right));
    final settings = ref.watch(settingsProvider).value;
    final panels = settings?.kioskPanels ?? KioskPanels.defaults;
    final visibleDays = settings?.kioskVisibleDays ?? 7;
    final screenWidth = MediaQuery.sizeOf(context).width;
    final play = _play;
    // Worked out once for both: each panel whole day columns, the two
    // together leaving at least one day of the board in view.
    final widths = kioskPanelWidths(
      screenWidth,
      rulerWidth: calendarRulerWidth,
      visibleDays: visibleDays,
      left: left == null ? null : panels.left.days,
      right: right == null ? null : panels.right.days,
    );
    final board = KioskBoardView(
      key: _boardKey,
      selected: _selected,
      onOpenMatch: _openMatchOrStream,
      onPlayVideo: play,
      // The columns are sized on the whole screen, a panel is a whole
      // number of them (kioskPanelWidths): open or closed, either panel
      // leaves the board whole days, and the columns never resize
      // mid-slide.
      columnBasisWidth: screenWidth,
      onVisibleDays: (first, last) =>
          setState(() => _boardDays = (first: first, last: last)),
      onOpenDuty: _openDuty,
    );
    if (left == null && right == null) return board;
    // A match being played keeps the panel holding the matches open: a
    // visitor may close it, and it opens again after the idle time.
    bool resting(PanelSide side, KioskPanelContent content) =>
        panels.panel(side).open || content.live.isNotEmpty;
    var leftOpen =
        left != null &&
        (_drawerOverride[PanelSide.left] ?? resting(PanelSide.left, left));
    var rightOpen =
        right != null &&
        (_drawerOverride[PanelSide.right] ?? resting(PanelSide.right, right));
    // Two days on the screen leave room for one open panel only.
    final exclusive = kioskPanelsExclusive(
      visibleDays: visibleDays,
      hasLeft: left != null,
      hasRight: right != null,
    );
    if (exclusive && leftOpen && rightOpen) {
      // Both rest open (a visitor's tap closes the other one itself, see
      // toggle): the one with the match being played stays, else the right.
      if (left.live.isNotEmpty && right.live.isEmpty) {
        rightOpen = false;
      } else {
        leftOpen = false;
      }
    }
    void toggle(PanelSide side, bool open) => setState(() {
      _drawerOverride[side] = !open;
      // Where only one fits, at most one panel is shown open and a tap
      // always leaves the other one shut: opening one closes the other, and
      // hiding the one shown must not let the other (resting open too, only
      // held back by the shared room) slide in instead.
      final other = side == PanelSide.left ? PanelSide.right : PanelSide.left;
      if (exclusive) _drawerOverride[other] = false;
    });
    // A visitor picked their name: the board is what they came for — both
    // panels and their buttons step aside until the pick is cleared (or the
    // idle reset), then the panels are as they were, live match and all.
    final picking = _selected != null;
    // The match being played, the switch back to it and the board's days
    // belong to the panel holding the matches.
    final matchesSide = panels.sideOf(KioskModule.matches);
    // The board and each panel on their own layer: a panel's turns (a
    // notice, the live match) do not re-record the board, nor the board's
    // scroll a panel. On the web the GPU still redraws every layer each
    // frame — this spares the Dart side (0065). Keyed by side: a panel
    // coming or going on one side leaves the other one its state.
    Widget panel(
      PanelSide side,
      KioskPanelContent content,
      double width,
      bool open,
    ) {
      final holdsMatches = side == matchesSide;
      return RepaintBoundary(
        key: ValueKey(side),
        child: KioskPanelView(
          side: side,
          width: width,
          content: content,
          open: open,
          hidden: picking,
          onOpenNotice: _openNotice,
          onOpenMatch: _openMatch,
          onOpenGuide: _openGuide,
          onOpenWeek: _openWeek,
          onOpenFeedback: _openFeedback,
          onPlay: play,
          resetToken: _resets,
          showLive: !(holdsMatches && _liveHidden),
          onShowLive: holdsMatches
              ? (live) => setState(() => _liveHidden = !live)
              : null,
          boardDays: holdsMatches && (settings?.kioskFollowBoard ?? true)
              ? _boardDays
              : null,
        ),
      );
    }

    // Each button floats over the board, vertically centred, at its
    // panel's inner edge — or at the board's edge, once the panel is gone:
    // the right one at the right edge, the left one centred on the hour
    // ruler, never over today's column (where visitors book).
    Widget button(PanelSide side, bool open) => KioskDrawerButton(
      side: side,
      open: open,
      onTap: () => toggle(side, open),
      breathe: settings?.kioskAnimations ?? true,
    );
    return Stack(
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (left != null)
              panel(PanelSide.left, left, widths.left, leftOpen),
            Expanded(child: RepaintBoundary(child: board)),
            if (right != null)
              panel(PanelSide.right, right, widths.right, rightOpen),
          ],
        ),
        if (!picking && left != null)
          AnimatedPositioned(
            key: const ValueKey(PanelSide.left),
            duration: const Duration(milliseconds: 250),
            curve: Curves.easeOutCubic,
            top: 0,
            bottom: 0,
            left:
                (leftOpen ? widths.left : 0) +
                (calendarRulerWidth - KioskDrawerButton.size) / 2,
            child: Center(child: button(PanelSide.left, leftOpen)),
          ),
        if (!picking && right != null)
          AnimatedPositioned(
            key: const ValueKey(PanelSide.right),
            duration: const Duration(milliseconds: 250),
            curve: Curves.easeOutCubic,
            top: 0,
            bottom: 0,
            right: (rightOpen ? widths.right : 0) + KioskDrawerButton.margin,
            child: Center(child: button(PanelSide.right, rightOpen)),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    // The admin flips „Nižší rozlišení“ (or the settings arrive): the display
    // stores it and, on the web, reloads when it differs from what this
    // start was given.
    ref.listen(settingsProvider.select((s) => s.value?.kioskLowRes), (_, on) {
      if (on != null) _display.lowRes(on);
    });
    // The kiosk is a shared, always-on tablet whose brightness is an admin
    // choice (spec §4), independent of the device's system brightness and of
    // the rest of the app (which follows light/dark via MaterialApp.theme/
    // darkTheme). Defaults to dark — the historical kiosk look — until the
    // settings stream resolves.
    final kioskDark = ref.watch(settingsProvider).value?.kioskDark ?? true;
    // Deliberately half-in on appearance Settings: no `contrastLevel`, so
    // the kiosk opts OUT of the personal theme choice — kioskDark above is
    // the only brightness knob a shared tablet gets, admin-controlled, and
    // always Material's normal contrast. It still opts IN to the personal
    // text-size choice, inherited for free because MediaQuery's textScaler
    // override in main.dart wraps the whole Router, kiosk screens included.
    return Theme(
      data: buildTheme(kioskDark ? Brightness.dark : Brightness.light),
      child: Listener(
        onPointerDown: (_) => _touch(),
        // A mouse wheel or a trackpad scrolls without a pointer down: it
        // counts as touching the kiosk too, or the idle reset never comes
        // to put the board back.
        onPointerSignal: (_) => _touch(),
        onPointerPanZoomStart: (_) => _touch(),
        behavior: HitTestBehavior.translucent,
        child: Scaffold(
          body: Column(
            children: [
              _StatusBar(
                selected: _selected,
                onReserve: _openPicker,
                onClearSelection: _clearSelection,
                onOpenNotice: _openNotice,
                onOpenMatch: _openMatchOrStream,
                onOpenDuty: _openDuty,
              ),
              const KioskOfflineBanner(),
              // The idle bar: thin, filling from left to right until the reset.
              AnimatedBuilder(
                animation: _warning,
                builder: (context, _) => SizedBox(
                  height: 3,
                  child: _warning.isAnimating
                      ? Align(
                          alignment: Alignment.centerLeft,
                          child: FractionallySizedBox(
                            widthFactor: _warning.value,
                            // The bar's full 3 px: a ColoredBox without a
                            // child takes the smallest height it may — 0.
                            heightFactor: 1,
                            child: ColoredBox(
                              color: Theme.of(
                                context,
                              ).colorScheme.primary.withValues(alpha: 0.7),
                            ),
                          ),
                        )
                      : null,
                ),
              ),
              Expanded(child: _withStream(_boardWithPanel())),
            ],
          ),
        ),
      ),
    );
  }
}

/// The least the header's centre (today's matches, the info line, the
/// warning) or the notices keep when the modules beside them have to
/// shrink, at text scale 1.
const _centreRoom = 200.0;

/// What [KioskHeadline] puts before a title: its 26 px icon and the 10 px
/// after it.
const _headlineIcon = 36.0;

/// The header: the clock, the admin's modules left and right of the centre
/// (0082, each a title over its value — [KioskHeaderModuleFrame]), today's
/// matches or the info line in the centre, „Rezervace tréninku“ last.
/// Watches [nowProvider] itself, so a minute tick repaints this strip only
/// — never the shell or the board beneath it.
class _StatusBar extends ConsumerWidget {
  const _StatusBar({
    required this.selected,
    required this.onReserve,
    required this.onClearSelection,
    required this.onOpenNotice,
    required this.onOpenMatch,
    required this.onOpenDuty,
  });

  final PlayerName? selected;
  final VoidCallback onReserve;
  final VoidCallback onClearSelection;
  final void Function(Message notice) onOpenNotice;

  /// A tap on one of today's matches: its Zápis once it has a score, its
  /// stream before that when it has a video.
  final void Function(PrioritySlot match) onOpenMatch;

  /// A tap on the canteen duty's module: the plan.
  final VoidCallback onOpenDuty;

  /// Today's matches the bar lists, start-ordered; Úklid children are
  /// plumbing (their match already announces). None while the admin keeps
  /// them out of the header (0071): the bar then reads as on a day without
  /// a match.
  List<PrioritySlot> _todaysMatches(WidgetRef ref, Day todayDay) {
    if (!(ref.watch(settingsProvider).value?.kioskTodaysMatches ?? true)) {
      return const [];
    }
    return ref
        .watch(prioritySlotsProvider)
        .where((m) => m.date == todayDay && m.parentId == null)
        .toList()
      ..sort((a, b) => a.startsAt.compareTo(b.startsAt));
  }

  String _infoLine(WidgetRef ref, Day todayDay) {
    // Today's matches are not a line of text: [build] lists them, each
    // one tappable. Hidden by the admin, they leave the line its say.
    if (_todaysMatches(ref, todayDay).isNotEmpty) return '';

    final settings =
        ref.watch(settingsProvider).value ?? ScheduleSettings.defaults;
    final overrides = ref.watch(dayOverridesProvider).value ?? const [];
    final override = overrides.where((o) => o.date == todayDay).firstOrNull;
    if (override != null && override.closed) {
      return override.reason.isEmpty
          ? 'Zavřeno'
          : 'Zavřeno — ${override.reason}';
    }

    // Same resolution the grid uses (isDayOpen → buildWeekSchedule), so the
    // status bar can never disagree with what the grid renders — including
    // overrides whose blockIds no longer resolve to existing blocks.
    final blocks = ref.watch(timeBlocksProvider).value ?? const [];
    final effectiveBlocks = blocks.isNotEmpty ? blocks : defaultTimeBlocks();
    final todayIsOpen = isDayOpen(
      date: todayDay,
      today: todayDay,
      settings: settings,
      blocks: effectiveBlocks,
      overrides: overrides,
    );

    if (!todayIsOpen) {
      final next = nextTrainingDay(
        today: todayDay,
        settings: settings,
        blocks: effectiveBlocks,
        overrides: overrides,
        horizonDays: settings.bookingHorizonDays,
      );
      if (next != null) return 'Další trénink: ${dayFull(next)}';
    }
    return '';
  }

  /// What lies between the clock and „Rezervace tréninku“, [width] wide:
  /// the [left] modules, the [centre], the [right] modules. A module with
  /// a short value takes at most a fifth of the screen, the weather
  /// [kioskHeaderWeatherShare] — and on a narrow kiosk with large text, or
  /// a busy one, no more than its part of what the clock and the button
  /// leave, in proportion to those shares, keeping [_centreRoom] for the
  /// centre and as much again for the notices: the names are cut and the
  /// weather shrinks, the button is never pushed off the screen.
  List<Widget> _middle({
    required double width,
    required TextScaler textScaler,
    required List<Widget> left,
    required Widget? centre,
    required List<Widget> right,
    required bool flexible,
  }) {
    final gaps = <double>[
      for (final _ in left) kioskHeaderGap,
      if (centre != null) 24,
      for (var i = 0; i < right.length; i++)
        i == 0 && centre != null ? 24 : kioskHeaderGap,
    ];
    // Split by each module's own share, not equally: the weather's row,
    // longer than a name, would shrink while the names left room unused.
    double weight(Widget w) => w is KioskWeatherModule
        ? kioskHeaderWeatherShare
        : kioskHeaderModuleShare;
    final weights = [
      for (final w in [...left, ...right])
        if (w is! Expanded) weight(w),
    ].fold(0.0, (a, b) => a + b);
    // Each of the two that is there keeps its room: the matches beside the
    // notices would squeeze the headline under its icon.
    final room =
        ((centre != null ? 1 : 0) + (flexible ? 1 : 0)) *
        math.min(width / 3, textScaler.scale(_centreRoom));
    final unit = weights == 0
        ? double.infinity
        : math.max(
            0.0,
            (width - gaps.fold(0.0, (a, b) => a + b) - room) / weights,
          );
    Widget capped(Widget w) => w is Expanded
        ? w
        : ConstrainedBox(
            key: w.key,
            constraints: BoxConstraints(maxWidth: weight(w) * unit),
            child: w,
          );
    var gap = 0;
    return [
      for (final w in left) ...[
        SizedBox(width: gaps[gap++]),
        capped(w),
      ],
      if (centre != null) ...[
        SizedBox(width: gaps[gap++]),
        Expanded(flex: 2, child: centre),
      ]
      // Neither a centre nor the notices: the right modules stay on the
      // right.
      else if (!flexible)
        const Spacer(),
      for (final w in right) ...[
        SizedBox(width: gaps[gap++]),
        capped(w),
      ],
    ];
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final now = ref.watch(nowProvider).value ?? DateTime.now();
    final todayDay = Day.fromDateTime(now);
    final settings = ref.watch(settingsProvider).value;
    final header = settings?.kioskHeader ?? KioskHeader.defaults;
    // The admin's warning (0068): while it hangs, it is all the bar says
    // beside the clock — every other module, today's matches and the info
    // line step aside, so nobody reads past it.
    final warning = settings?.kioskWarning;
    final warningFontSize = settings?.kioskWarningFontSize ?? 22;
    final info = warning != null ? '' : _infoLine(ref, todayDay);
    final todays = warning != null
        ? const <PrioritySlot>[]
        : _todaysMatches(ref, todayDay);
    // Kept listened to: a tap on a match reads it to decide whether there
    // is a Zápis, and with the drawer closed nothing else may hold it.
    ref.watch(matchResultsProvider);
    final infoStyle = TextStyle(fontSize: 14, color: scheme.onSurfaceVariant);
    final clock =
        '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}';

    // Each module's data, read only while the admin has it in the header
    // (0082) and no warning hangs.
    bool on(KioskHeaderModule m) => warning == null && header.isOn(m);
    final notices = on(KioskHeaderModule.notices)
        ? kioskNotices(ref.watch(messagesProvider).value ?? const [], now)
        : const <Message>[];
    // Who serves today (0073).
    final duty = on(KioskHeaderModule.duty)
        ? ref.watch(kioskDutyPlanProvider.select((plan) => plan.now))
        : null;
    final weather = on(KioskHeaderModule.weather)
        ? freshWeather(ref.watch(kioskWeatherProvider).value, now)
        : null;
    final nameDay = on(KioskHeaderModule.nameday)
        ? nameDayHeader(czechNameDay(todayDay))
        : null;

    // A module as the bar lays it out — null when it has nothing to say
    // today, so the others close up. Keyed: a module keeps its state (the
    // weather's source on a tap) while others come and go around it.
    Widget? module(KioskHeaderModule m) => switch (m) {
      KioskHeaderModule.weather =>
        weather == null
            ? null
            : KioskWeatherModule(
                key: ValueKey(m),
                weather: weather,
                title: kioskWeatherTitleOf(settings?.kioskWeatherTitle),
                items:
                    settings?.kioskWeatherItems ?? kioskWeatherItemsDefault,
              ),
      KioskHeaderModule.nameday =>
        nameDay == null
            ? null
            : KioskNameDayModule(key: ValueKey(m), day: nameDay),
      KioskHeaderModule.duty =>
        duty == null
            ? null
            : KioskDutyModule(key: ValueKey(m), entry: duty, onTap: onOpenDuty),
      // One notice's title at a time, in what is left.
      KioskHeaderModule.notices =>
        notices.isEmpty
            ? null
            : Expanded(
                key: ValueKey(m),
                flex: 3,
                child: KioskHeaderModuleFrame(
                  title: 'Nástěnka:',
                  // Too narrow for the icon and a glyph or two (a small
                  // kiosk with large text and a busy header): the title
                  // alone, rather than a headline that overflows.
                  child: LayoutBuilder(
                    builder: (context, constraints) =>
                        constraints.maxWidth <
                            _headlineIcon +
                                2 * MediaQuery.textScalerOf(context).scale(22)
                        ? const SizedBox.shrink()
                        : KioskHeadline(
                            notices: notices,
                            turn: Duration(
                              seconds:
                                  settings?.kioskNoticesRotationSeconds ?? 12,
                            ),
                            now: now,
                            fresh:
                                settings?.kioskNoticesFresh ??
                                KioskNoticesFresh.highlight,
                            freshDays: settings?.kioskNoticesFreshDays ?? 3,
                            onOpen: onOpenNotice,
                            alignment: Alignment.centerLeft,
                            padding: EdgeInsets.zero,
                          ),
                  ),
                ),
              ),
    };
    List<Widget> modulesOn(PanelSide side) => [
      for (final p in header.modulesOn(side)) ?module(p.module!),
    ];
    final left = modulesOn(PanelSide.left);
    final right = modulesOn(PanelSide.right);
    // The notices take the room left, like the centre.
    final flexible = [...left, ...right].any((w) => w is Expanded);

    // Today's matches, one tap target each: a match with a score opens its
    // Zápis, as everywhere else on the kiosk; one with a video and no
    // score yet, its stream.
    Widget matchLine(List<PrioritySlot> matches) => Wrap(
      alignment: WrapAlignment.center,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        for (var i = 0; i < matches.length; i++) ...[
          if (i > 0) Text('  ·  ', style: infoStyle),
          InkWell(
            onTap: () => onOpenMatch(matches[i]),
            borderRadius: BorderRadius.circular(6),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
              // One line each: on a narrow kiosk with large text a long
              // label is cut, never broken letter by letter down the bar.
              child: EmojiText(
                headerEventLabel(
                  matches[i],
                  names: ref.watch(nameDisplayProvider),
                ),
                style: infoStyle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ),
        ],
      ],
    );
    // The bar's centre, untitled: the admin's warning, alone; else today's
    // matches — the home ones (and the alley's blockages) on one line, the
    // away ones under them; else the info line.
    final home = [for (final m in todays) if (!m.isAway) m];
    final away = [for (final m in todays) if (m.isAway) m];
    final Widget? centre = warning != null
        ? KioskWarning(
            text: warning,
            maxLines: 4,
            fontSize: warningFontSize.toDouble(),
          )
        : todays.isNotEmpty
        ? Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (home.isNotEmpty) matchLine(home),
              if (home.isNotEmpty && away.isNotEmpty)
                const SizedBox(height: 4),
              if (away.isNotEmpty) matchLine(away),
            ],
          )
        : info.isNotEmpty
        ? EmojiText(
            info,
            textAlign: TextAlign.center,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: infoStyle,
          )
        : null;

    return Container(
      color: scheme.surfaceContainerHighest,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: SafeArea(
        bottom: false,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            // Always first: „Dnes je čtvrtek 15. 10.“ over the time.
            KioskHeaderModuleFrame(
              title: 'Dnes je ${dayFull(todayDay)}',
              // Like the other short modules: on a narrow kiosk with large
              // text the day ellipsizes; the time always fits.
              maxWidth:
                  MediaQuery.sizeOf(context).width * kioskHeaderModuleShare,
              child: Text(clock, style: kioskHeaderClockStyle),
            ),
            Expanded(
              child: LayoutBuilder(
                builder: (context, constraints) => Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: _middle(
                    width: constraints.maxWidth,
                    textScaler: MediaQuery.textScalerOf(context),
                    left: left,
                    centre: centre,
                    right: right,
                    flexible: flexible,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 16),
            // The kiosk's main action, the bar's largest control — scaled
            // down, never cut, on a screen too narrow for it (at most two
            // fifths of the bar).
            selected == null
                ? ConstrainedBox(
                    constraints: BoxConstraints(
                      maxWidth: MediaQuery.sizeOf(context).width * 0.4,
                    ),
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      child: GradientButton(
                        onPressed: onReserve,
                        icon: Icons.person_add,
                        minHeight: 72,
                        fontSize: 26,
                        fontWeight: FontWeight.w800,
                        iconSize: 34,
                        child: const Text(kioskReserveLabel),
                      ),
                    ),
                  )
                // Who books: the name the board shows (the nick), plain on
                // the bar. Capped like the button, so a long name
                // ellipsizes rather than push the bar wider than the
                // screen — the middle is all that gives way.
                : ConstrainedBox(
                    constraints: BoxConstraints(
                      minHeight: 72,
                      maxWidth: math.min(
                        420,
                        MediaQuery.sizeOf(context).width * 0.4,
                      ),
                    ),
                    // No avatar: the players have no pictures yet.
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Flexible(
                          child: Text(
                            'Rezervuje: ${selected!.boardName}',
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 22,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ),
                        IconButton(
                          iconSize: 40,
                          tooltip: 'Zrušit výběr',
                          icon: const Icon(Icons.close),
                          onPressed: onClearSelection,
                        ),
                      ],
                    ),
                  ),
          ],
        ),
      ),
    );
  }
}
