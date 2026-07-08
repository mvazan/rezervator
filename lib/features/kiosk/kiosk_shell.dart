/// Kiosk shell: fullscreen status bar + week grid, no AppBar, no navigation,
/// no cancel — the shared-tablet UI performs exactly one action (book a
/// slot for whichever player picks themselves from the name picker).
/// Selection and half-finished picker state both reset after 60 s of no
/// touch, so a walked-away kiosk never leaves someone else's name selected.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/ui.dart';
import '../../data/providers.dart';
import '../../domain/models.dart';
import 'kiosk_week_view.dart';
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
  int _weekOffset = 0;

  /// Guards the idle handler's dialog pop: only try to close the picker
  /// route if one is actually open, and only once (popUntil is otherwise
  /// harmless-but-redundant when nothing is pushed).
  bool _pickerOpen = false;

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
    if (_pickerOpen) {
      // Root navigator: showDialog (and Dialog.fullscreen) push onto it, not
      // onto any nested Navigator this Scaffold might sit under.
      Navigator.of(context, rootNavigator: true)
          .popUntil((r) => r.isFirst);
    }
    setState(() {
      _selected = null;
      _weekOffset = 0;
    });
    ref.invalidate(playersProvider);
  }

  Future<void> _openPicker() async {
    setState(() => _pickerOpen = true);
    final picked = await showNamePicker(context);
    if (!mounted) return;
    setState(() {
      _pickerOpen = false;
      if (picked != null) _selected = picked;
    });
  }

  void _clearSelection() => setState(() => _selected = null);

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerDown: (_) => _touch(),
      behavior: HitTestBehavior.translucent,
      child: Scaffold(
        body: Column(
          children: [
            _StatusBar(
              now: _now,
              selected: _selected,
              weekOffset: _weekOffset,
              onReserve: _openPicker,
              onClearSelection: _clearSelection,
            ),
            Expanded(
              child: KioskWeekView(
                weekOffset: _weekOffset,
                onWeekOffsetChanged: (offset) =>
                    setState(() => _weekOffset = offset),
                selected: _selected,
                onBooked: () {}, // selection persists — no-op by design.
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _StatusBar extends ConsumerWidget {
  const _StatusBar({
    required this.now,
    required this.selected,
    required this.weekOffset,
    required this.onReserve,
    required this.onClearSelection,
  });

  final DateTime now;
  final PlayerName? selected;
  final int weekOffset;
  final VoidCallback onReserve;
  final VoidCallback onClearSelection;

  String _infoLine(WidgetRef ref, Day todayDay) {
    final matches = ref.watch(matchesProvider).value ?? const [];
    final todaysMatches = matches.where((m) => m.date == todayDay).toList()
      ..sort((a, b) => a.startsAt.compareTo(b.startsAt));
    if (todaysMatches.isNotEmpty) {
      return todaysMatches
          .map((m) =>
              '🏆 ${m.opponent} ${m.startsAt.display()}–${m.endsAt.display()}')
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
                Text(clock,
                    style: const TextStyle(
                        fontSize: 28, fontWeight: FontWeight.bold)),
                Text(dayFull(todayDay),
                    style: TextStyle(color: scheme.onSurfaceVariant)),
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
                ? SizedBox(
                    height: 56,
                    child: FilledButton.icon(
                      onPressed: onReserve,
                      icon: const Icon(Icons.person_add),
                      label: const Text('Rezervovat'),
                    ),
                  )
                : Container(
                    constraints: const BoxConstraints(minHeight: 56),
                    padding: const EdgeInsets.symmetric(
                        horizontal: 16, vertical: 8),
                    decoration: BoxDecoration(
                      color: scheme.primaryContainer,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
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
