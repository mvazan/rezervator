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
import '../../data/providers.dart';
import '../../domain/models.dart';
import 'kiosk_board_view.dart';
import 'name_picker.dart';

const _idleTimeout = Duration(seconds: 60);
const _clockInterval = Duration(seconds: 20);

class KioskShell extends ConsumerStatefulWidget {
  const KioskShell({super.key});

  @override
  ConsumerState<KioskShell> createState() => _KioskShellState();
}

class _KioskShellState extends ConsumerState<KioskShell> {
  Timer? _idleTimer;
  Timer? _clockTimer;
  DateTime _now = DateTime.now();
  PlayerName? _selected;
  final _boardKey = GlobalKey<KioskBoardViewState>();

  @override
  void initState() {
    super.initState();
    _touch();
    _clockTimer = Timer.periodic(_clockInterval, (_) {
      if (mounted) setState(() => _now = DateTime.now());
    });
  }

  @override
  void dispose() {
    _idleTimer?.cancel();
    _clockTimer?.cancel();
    super.dispose();
  }

  void _touch() {
    _idleTimer?.cancel();
    _idleTimer = Timer(_idleTimeout, _onIdle);
  }

  void _onIdle() {
    if (!mounted) return;
    // Pop unconditionally (root navigator — dialogs push onto it): besides
    // the name picker this also dismisses an abandoned booking-confirm
    // dialog, which captured the previously selected player and would let
    // the next visitor book under their name.
    Navigator.of(context, rootNavigator: true).popUntil((r) => r.isFirst);
    setState(() => _selected = null);
    // Board horizontal scroll resets to today too (spec §1) — imperative
    // because the board owns its own PageController; there's no offset
    // field on this shell to reset via rebuild the way _weekOffset used to.
    _boardKey.currentState?.resetToToday();
    ref.invalidate(playersProvider);
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

  @override
  Widget build(BuildContext context) {
    // The kiosk is a shared, always-on tablet whose brightness is an admin
    // choice (spec §4), independent of the device's system brightness and of
    // the rest of the app (which follows light/dark via MaterialApp.theme/
    // darkTheme). Defaults to dark — the historical kiosk look — until the
    // settings stream resolves.
    final kioskDark =
        ref.watch(settingsProvider).value?.kioskDark ?? true;
    return Theme(
      data: buildTheme(kioskDark ? Brightness.dark : Brightness.light),
      child: Listener(
        onPointerDown: (_) => _touch(),
        behavior: HitTestBehavior.translucent,
        child: Scaffold(
          body: Column(
            children: [
              _StatusBar(
                now: _now,
                selected: _selected,
                onReserve: _openPicker,
                onClearSelection: _clearSelection,
              ),
              Expanded(
                child: KioskBoardView(
                  key: _boardKey,
                  selected: _selected,
                  onBooked: () {}, // selection persists — no-op by design.
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _StatusBar extends ConsumerWidget {
  const _StatusBar({
    required this.now,
    required this.selected,
    required this.onReserve,
    required this.onClearSelection,
  });

  final DateTime now;
  final PlayerName? selected;
  final VoidCallback onReserve;
  final VoidCallback onClearSelection;

  String _infoLine(WidgetRef ref, Day todayDay) {
    final priority = ref.watch(prioritySlotsProvider);
    // Úklid children are plumbing (their match already announces); away
    // matches announce with a "(venku)" marker.
    final todaysMatches = priority
        .where((m) => m.date == todayDay && m.parentId == null)
        .toList()
      ..sort((a, b) => a.startsAt.compareTo(b.startsAt));
    if (todaysMatches.isNotEmpty) {
      return todaysMatches
          .map(
            (m) => '🏆 ${m.title}${m.isAway ? ' (venku)' : ''} '
                '${m.startsAt.display()}–${m.endsAt.display()}',
          )
          .join(' · ');
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
    final todayDay = Day.fromDateTime(now);
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
              child: Text(
                _infoLine(ref, todayDay),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 14, color: scheme.onSurfaceVariant),
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
