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
import '../../domain/kiosk_panel.dart' show kioskNotices;
import '../../domain/models.dart';
import '../../domain/results.dart' show hasScoreData;
import '../../domain/schedule.dart'
    show headerEventLabel, isDayOpen, nextTrainingDay;
import 'kiosk_board_view.dart';
import 'kiosk_info_panel.dart';
import 'kiosk_ticker.dart';
import 'kiosk_zapis_page.dart';
import 'name_picker.dart';
import '../../core/widgets/emoji_text.dart';

class KioskShell extends ConsumerStatefulWidget {
  const KioskShell({super.key});

  @override
  ConsumerState<KioskShell> createState() => _KioskShellState();
}

class _KioskShellState extends ConsumerState<KioskShell> {
  Timer? _idleTimer;
  PlayerName? _selected;

  /// What a visitor did to the drawer (true = open); null = the admin's
  /// resting state. The idle reset puts it back.
  bool? _drawerOverride;
  final _boardKey = GlobalKey<KioskBoardViewState>();

  @override
  void initState() {
    super.initState();
    _touch();
  }

  @override
  void dispose() {
    _idleTimer?.cancel();
    super.dispose();
  }

  void _touch() {
    _idleTimer?.cancel();
    final seconds = ref.read(settingsProvider).value?.kioskIdleSeconds ?? 60;
    _idleTimer = Timer(Duration(seconds: seconds), _onIdle);
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
    behavior: HitTestBehavior.translucent,
    child: Theme(data: _kioskTheme(), child: child),
  );

  void _openNotice(Message notice) {
    showDialog<void>(
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
  }

  /// A tap on a match of the board: only one with a score has a Zápis.
  void _openMatchIfScored(PrioritySlot match) {
    final result = ref.read(matchResultsProvider).value?[match.id];
    if (hasScoreData(result)) _openMatch(match);
  }

  void _openMatch(PrioritySlot match) {
    unawaited(
      showKioskZapis(
        context,
        slot: match,
        brightness: (ref.read(settingsProvider).value?.kioskDark ?? true)
            ? Brightness.dark
            : Brightness.light,
        percent: ref.read(settingsProvider).value?.kioskZapisPercent ?? 80,
        onTouch: _touch,
      ),
    );
  }

  /// The board with the drawer (notices and matches) on its right — no
  /// drawer at all when there is nothing to put in it.
  Widget _boardWithPanel() {
    final board = KioskBoardView(
      key: _boardKey,
      selected: _selected,
      onOpenMatch: _openMatchIfScored,
    );
    final content = ref.watch(kioskPanelContentProvider);
    if (content == null) return board;
    final settings = ref.watch(settingsProvider).value;
    // A match being played keeps the drawer open: a visitor may close it,
    // and it opens again after the idle time.
    final restingOpen =
        (settings?.kioskDrawerOpen ?? false) || content.live.isNotEmpty;
    final open = _drawerOverride ?? restingOpen;
    final drawerWidth = kioskDrawerWidthFor(
      MediaQuery.sizeOf(context).width,
      settings?.kioskDrawerWidth ?? 440,
    );
    void toggle() => setState(() => _drawerOverride = !open);
    return Stack(
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(child: board),
            KioskDrawer(
              content: content,
              open: open,
              onOpenNotice: _openNotice,
              onOpenMatch: _openMatch,
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
            child: KioskDrawerButton(open: open, onTap: toggle),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
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
        behavior: HitTestBehavior.translucent,
        child: Scaffold(
          body: Column(
            children: [
              _StatusBar(
                selected: _selected,
                onReserve: _openPicker,
                onClearSelection: _clearSelection,
              ),
              Expanded(child: _boardWithPanel()),
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
  });

  final PlayerName? selected;
  final VoidCallback onReserve;
  final VoidCallback onClearSelection;

  String _infoLine(WidgetRef ref, Day todayDay) {
    final priority = ref.watch(prioritySlotsProvider);
    // Úklid children are plumbing (their match already announces); the
    // shared label gives home matches the 🏠, away matches no icon.
    final todaysMatches =
        priority.where((m) => m.date == todayDay && m.parentId == null).toList()
          ..sort((a, b) => a.startsAt.compareTo(b.startsAt));
    if (todaysMatches.isNotEmpty) {
      return todaysMatches.map(headerEventLabel).join('  ·  ');
    }

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
    final info = _infoLine(ref, todayDay);
    final notices = kioskNotices(
      ref.watch(messagesProvider).value ?? const [],
      now,
    );
    final clock =
        '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}';

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
              ],
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Row(
                children: [
                  if (info.isNotEmpty)
                    Flexible(
                      flex: notices.isEmpty ? 1 : 2,
                      child: EmojiText(
                        info,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 14,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  if (info.isNotEmpty && notices.isNotEmpty)
                    const SizedBox(width: 24),
                  // The notices as a news strip in what is left.
                  if (notices.isNotEmpty)
                    Expanded(flex: 3, child: KioskTicker(notices: notices)),
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
                    constraints: const BoxConstraints(minHeight: 56),
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
