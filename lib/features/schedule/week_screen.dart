import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/ui.dart';
import '../../data/providers.dart';
import '../../domain/models.dart';

/// Static week view (Phase 0): the grid renders from settings + blocks but
/// cells are inert. Booking arrives in Phase 1, matches/rentals in Phase 2.
class WeekScreen extends ConsumerStatefulWidget {
  const WeekScreen({super.key});

  @override
  ConsumerState<WeekScreen> createState() => _WeekScreenState();
}

class _WeekScreenState extends ConsumerState<WeekScreen> {
  int _weekOffset = 0;

  Day get _monday {
    final t = today();
    return t.addDays(1 - t.weekday + 7 * _weekOffset);
  }

  @override
  Widget build(BuildContext context) {
    final settings =
        ref.watch(settingsProvider).value ?? ScheduleSettings.defaults;
    final dbBlocks = ref.watch(timeBlocksProvider).value ?? const [];
    final blocks = dbBlocks.where((b) => b.active).toList();
    final effectiveBlocks = blocks.isEmpty ? defaultTimeBlocks() : blocks;
    final monday = _monday;

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Row(
            children: [
              IconButton(
                icon: const Icon(Icons.chevron_left),
                onPressed: () => setState(() => _weekOffset--),
              ),
              Expanded(
                child: Text(
                  rangeLabel(monday, monday.addDays(6)),
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              if (_weekOffset != 0)
                TextButton(
                  onPressed: () => setState(() => _weekOffset = 0),
                  child: const Text('dnes'),
                ),
              IconButton(
                icon: const Icon(Icons.chevron_right),
                onPressed: () => setState(() => _weekOffset++),
              ),
            ],
          ),
        ),
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 24),
            itemCount: 7,
            itemBuilder: (context, i) => _DaySection(
              date: monday.addDays(i),
              open: settings.trainingWeekdays.contains(monday.addDays(i).weekday),
              laneCount: settings.laneCount,
              blocks: effectiveBlocks,
            ),
          ),
        ),
      ],
    );
  }
}

class _DaySection extends StatelessWidget {
  const _DaySection({
    required this.date,
    required this.open,
    required this.laneCount,
    required this.blocks,
  });

  final Day date;
  final bool open;
  final int laneCount;
  final List<TimeBlock> blocks;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(dayFull(date),
                style: Theme.of(context)
                    .textTheme
                    .titleSmall
                    ?.copyWith(fontWeight: FontWeight.w700)),
            const SizedBox(height: 8),
            if (!open)
              Text('Zavřeno',
                  style: TextStyle(color: scheme.onSurfaceVariant))
            else
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Table(
                  defaultColumnWidth: const FixedColumnWidth(72),
                  columnWidths: const {0: FixedColumnWidth(100)},
                  border: TableBorder.all(
                      color: scheme.outlineVariant.withValues(alpha: 0.5)),
                  children: [
                    TableRow(
                      children: [
                        const SizedBox.shrink(),
                        for (var lane = 1; lane <= laneCount; lane++)
                          Padding(
                            padding: const EdgeInsets.all(6),
                            child: Text('Dráha $lane',
                                textAlign: TextAlign.center,
                                style: const TextStyle(
                                    fontWeight: FontWeight.w600)),
                          ),
                      ],
                    ),
                    for (final block in blocks)
                      TableRow(
                        children: [
                          Padding(
                            padding: const EdgeInsets.all(6),
                            child: Text(block.label,
                                style: const TextStyle(fontSize: 12)),
                          ),
                          for (var lane = 1; lane <= laneCount; lane++)
                            const SizedBox(height: 40),
                        ],
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
