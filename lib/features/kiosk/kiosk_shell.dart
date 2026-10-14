/// Kiosk shell: fullscreen status bar + week grid, no AppBar, no navigation,
/// no cancel — the shared-tablet UI performs exactly one action (book a
/// slot for whichever player picks themselves from the name picker).
/// Selection and half-finished picker state both reset after 60 s of no
/// touch, so a walked-away kiosk never leaves someone else's name selected.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme.dart';
import '../../core/ui.dart';
import '../../core/widgets/gradient_button.dart';
import '../../data/clock.dart';
import '../../data/providers.dart';
import '../../domain/kiosk_panel.dart'
    show hasKioskVideo, kioskNotices, kioskStreamLabel;
import '../../domain/models.dart';
import '../../domain/results.dart' show hasScoreData;
import '../../domain/schedule.dart'
    show headerEventLabel, isDayOpen, nextTrainingDay;
import 'kiosk_board_view.dart';
import 'kiosk_info_panel.dart';
import 'kiosk_connection.dart';
import 'kiosk_day_info.dart';
import 'kiosk_display.dart';
import 'kiosk_duty.dart';
import 'kiosk_headline.dart';
import 'kiosk_warning.dart';
import 'kiosk_stream_window.dart';
import 'kiosk_zapis_page.dart';
import 'name_picker.dart';
import '../../core/widgets/emoji_text.dart';

/// How long before the idle reset the bar starts running out.
const _warnFor = Duration(seconds: 10);

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

  /// What a visitor did to the drawer (true = open); null = the admin's
  /// resting state. The idle reset puts it back.
  bool? _drawerOverride;

  /// Bumped on every idle reset; the drawer's match list starts over on it.
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
      _drawerOverride = null;
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

  void _openMatch(PrioritySlot match) {
    final now = ref.read(nowProvider).value ?? DateTime.now();
    final play = _play;
    unawaited(
      showKioskZapis(
        context,
        slot: match,
        brightness: (ref.read(settingsProvider).value?.kioskDark ?? true)
            ? Brightness.dark
            : Brightness.light,
        percent: ref.read(settingsProvider).value?.kioskZapisPercent ?? 80,
        onTouch: _touch,
        // The Zápis closes and the stream opens beside the board.
        play: play != null && hasKioskVideo(match)
            ? (
                label: kioskStreamLabel(
                  match,
                  ref.read(matchResultsProvider).value?[match.id],
                  now,
                ),
                onPlay: () => play(match),
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

  /// The board with the drawer (notices and matches) on its right — no
  /// drawer at all when there is nothing to put in it.
  Widget _boardWithPanel() {
    final content = ref.watch(kioskPanelContentProvider);
    final settings = ref.watch(settingsProvider).value;
    final screenWidth = MediaQuery.sizeOf(context).width;
    final play = _play;
    final drawerWidth = kioskDrawerWidthFor(
      screenWidth,
      columns: settings?.kioskDrawerColumns ?? 2,
      visibleDays: settings?.kioskVisibleDays ?? 7,
    );
    final board = KioskBoardView(
      key: _boardKey,
      selected: _selected,
      onOpenMatch: _openMatchOrStream,
      onPlayVideo: play,
      // The columns are sized on the whole screen, the drawer is a whole
      // number of them (kioskDrawerWidthFor): open or closed, the board
      // shows whole days, and the columns never resize mid-slide.
      columnBasisWidth: screenWidth,
      onVisibleDays: (first, last) =>
          setState(() => _boardDays = (first: first, last: last)),
      onOpenDuty: _openDuty,
    );
    if (content == null) return board;
    // A match being played keeps the drawer open: a visitor may close it,
    // and it opens again after the idle time.
    final restingOpen =
        (settings?.kioskDrawerOpen ?? false) || content.live.isNotEmpty;
    final open = _drawerOverride ?? restingOpen;
    void toggle() => setState(() => _drawerOverride = !open);
    // The board and the drawer each on their own layer: the drawer's turns
    // (a notice, the live match) do not re-record the board, nor the
    // board's scroll the drawer. On the web the GPU still redraws every
    // layer each frame — this spares the Dart side (0065).
    return Stack(
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(child: RepaintBoundary(child: board)),
            RepaintBoundary(
              child: KioskDrawer(
                content: content,
                open: open,
                onOpenNotice: _openNotice,
                onOpenMatch: _openMatch,
                onPlay: play,
                resetToken: _resets,
                showLive: !_liveHidden,
                onShowLive: (live) => setState(() => _liveHidden = !live),
                boardDays: (settings?.kioskFollowBoard ?? true)
                    ? _boardDays
                    : null,
              ),
            ),
          ],
        ),
        // Floats over the board, vertically centred, at the drawer's left
        // edge — or at the screen's, once the drawer is gone.
        AnimatedPositioned(
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOutCubic,
          top: 0,
          bottom: 0,
          right: (open ? drawerWidth : 0) + KioskDrawerButton.margin,
          child: Center(
            child: KioskDrawerButton(
              open: open,
              onTap: toggle,
              breathe: settings?.kioskAnimations ?? true,
            ),
          ),
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

/// Clock + today's headline. Watches [nowProvider] itself, so a minute tick
/// repaints this strip only — never the shell or the board beneath it.
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

  /// A tap on the canteen duty's line: the plan.
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

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final now = ref.watch(nowProvider).value ?? DateTime.now();
    final todayDay = Day.fromDateTime(now);
    // The admin's warning (0068): while it hangs, it is all the bar says
    // beside the clock — today's matches, the info line and the notices
    // step aside, so nobody reads past it.
    final warning = ref.watch(settingsProvider).value?.kioskWarning;
    final info = warning != null ? '' : _infoLine(ref, todayDay);
    final todays = warning != null
        ? const <PrioritySlot>[]
        : _todaysMatches(ref, todayDay);
    // Kept listened to: a tap on a match reads it to decide whether there
    // is a Zápis, and with the drawer closed nothing else may hold it.
    ref.watch(matchResultsProvider);
    final infoStyle = TextStyle(fontSize: 14, color: scheme.onSurfaceVariant);
    final notices =
        warning == null &&
            (ref.watch(settingsProvider).value?.kioskNoticesInHeader ?? true)
        ? kioskNotices(ref.watch(messagesProvider).value ?? const [], now)
        : const <Message>[];
    final clock =
        '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}';
    // Who serves today (0073) — the plan is read only with the line on.
    // The canteen duty's line (0073) steps aside for the warning too.
    final duty =
        warning == null &&
            (ref.watch(settingsProvider).value?.kioskDutyHeader ?? false)
        ? ref.watch(kioskDutyPlanProvider.select((plan) => plan.now))
        : null;

    return Container(
      color: scheme.surfaceContainerHighest,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: SafeArea(
        bottom: false,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  clock,
                  style: const TextStyle(
                    fontSize: 28,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                Text(
                  dayFull(todayDay),
                  style: TextStyle(color: scheme.onSurfaceVariant),
                ),
                if (duty != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: KioskDutyLine(entry: duty, onTap: onOpenDuty),
                  ),
              ],
            ),
            // Today's weather and name day, when the admin wants them —
            // and no warning hangs: it is then all the bar says.
            if (warning == null) const KioskDayInfo(),
            const SizedBox(width: 16),
            Expanded(
              child: Row(
                children: [
                  // The admin's warning: alone in the bar's middle.
                  if (warning != null)
                    Expanded(child: KioskWarning(text: warning, maxLines: 3)),
                  // Today's matches, one tap target each: a match with a score
                  // opens its Zápis, as everywhere else on the kiosk; one
                  // with a video and no score yet, its stream.
                  if (todays.isNotEmpty)
                    Expanded(
                      flex: notices.isEmpty ? 1 : 2,
                      child: Wrap(
                        alignment: WrapAlignment.center,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          for (var i = 0; i < todays.length; i++) ...[
                            if (i > 0) Text('  ·  ', style: infoStyle),
                            InkWell(
                              onTap: () => onOpenMatch(todays[i]),
                              borderRadius: BorderRadius.circular(6),
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 4,
                                  vertical: 2,
                                ),
                                child: EmojiText(
                                  headerEventLabel(todays[i]),
                                  style: infoStyle,
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  if (info.isNotEmpty)
                    Expanded(
                      flex: notices.isEmpty ? 1 : 2,
                      child: EmojiText(
                        info,
                        textAlign: TextAlign.center,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 14,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  if ((info.isNotEmpty || todays.isNotEmpty) &&
                      notices.isNotEmpty)
                    const SizedBox(width: 24),
                  // One notice's title at a time, in what is left.
                  if (notices.isNotEmpty)
                    Expanded(
                      flex: 3,
                      child: KioskHeadline(
                        notices: notices,
                        turn: Duration(
                          seconds:
                              ref
                                  .watch(settingsProvider)
                                  .value
                                  ?.kioskNoticesRotationSeconds ??
                              12,
                        ),
                        onOpen: onOpenNotice,
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(width: 16),
            selected == null
                ? GradientButton(
                    onPressed: onReserve,
                    icon: Icons.person_add,
                    minHeight: 56,
                    child: const Text('Rezervovat'),
                  )
                : Container(
                    // Capped, so a long name ellipsizes in its chip rather
                    // than push the bar wider than the screen — the middle
                    // is all that gives way (it may shrink to nothing).
                    constraints: const BoxConstraints(
                      minHeight: 56,
                      maxWidth: 360,
                    ),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 8,
                    ),
                    decoration: BoxDecoration(
                      color: scheme.primaryContainer,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        CircleAvatar(
                          radius: 16,
                          backgroundColor: scheme.onPrimaryContainer.withValues(
                            alpha: 0.16,
                          ),
                          child: Text(
                            initialsOf(selected!.displayName),
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
                              color: scheme.onPrimaryContainer,
                            ),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Flexible(
                          child: Text(
                            'Rezervuje: ${selected!.displayName}',
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w700,
                              color: scheme.onPrimaryContainer,
                            ),
                          ),
                        ),
                        IconButton(
                          iconSize: 40,
                          icon: const Icon(Icons.close),
                          color: scheme.onPrimaryContainer,
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
