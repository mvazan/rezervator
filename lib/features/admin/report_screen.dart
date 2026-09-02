import 'dart:convert';

import 'package:file_saver/file_saver.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/ui.dart';
import '../../data/providers.dart';
import '../../domain/csv.dart';
import '../../domain/grouping.dart';
import '../../domain/models.dart';
import 'widgets/admin_scaffold.dart';

/// Admin: monthly attendance report (per player training count) with CSV
/// export. The rows come from [attendanceProvider] keyed by the shown
/// month — switching the month is a different key, a retry an invalidate.
class ReportScreen extends ConsumerStatefulWidget {
  const ReportScreen({super.key});

  @override
  ConsumerState<ReportScreen> createState() => _ReportScreenState();
}

class _ReportScreenState extends ConsumerState<ReportScreen> {
  late int _year;
  late int _month;
  bool _exporting = false;

  @override
  void initState() {
    super.initState();
    final now = today();
    _year = now.year;
    _month = now.month;
  }

  void _shiftMonth(int delta) {
    setState(() {
      final total = _year * 12 + (_month - 1) + delta;
      _year = total ~/ 12;
      _month = total % 12 + 1;
    });
  }

  Future<void> _export(List<AttendanceRow> rows) async {
    setState(() => _exporting = true);
    final csv = toCsv([
      ['Hráč', 'Klub', 'Tréninků'],
      for (final r in rows) [r.displayName, r.club, '${r.attended}'],
    ]);
    final monthTag = _month.toString().padLeft(2, '0');
    await tryAction(
      context,
      () => FileSaver.instance.saveFile(
        name: 'dochazka-$_year-$monthTag',
        bytes: utf8.encode(csv),
        fileExtension: 'csv',
        mimeType: MimeType.csv,
      ),
      success: 'Uloženo.',
      // A failed file save carries no schema error code to map.
      errorText: (_) => 'Export se nepovedl.',
    );
    if (mounted) setState(() => _exporting = false);
  }

  /// Czech pluralization for players: 1 hráč, 2–4 hráči, 5+ hráčů.
  static String _players(int n) =>
      n == 1 ? '1 hráč' : (n >= 2 && n <= 4 ? '$n hráči' : '$n hráčů');

  @override
  Widget build(BuildContext context) {
    final month = (_year, _month);
    final rows = ref.watch(attendanceProvider(month));
    final loaded = rows.value ?? const <AttendanceRow>[];
    final canExport = !rows.isLoading && !_exporting && loaded.isNotEmpty;

    return AdminScaffold(
      title: 'Docházka',
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                IconButton(
                  icon: const Icon(Icons.chevron_left),
                  onPressed: () => _shiftMonth(-1),
                ),
                SizedBox(
                  width: 160,
                  child: Text(
                    '„${monthsFull[_month]} $_year“',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.chevron_right),
                  onPressed: () => _shiftMonth(1),
                ),
              ],
            ),
          ),
          Expanded(
            child: AsyncBody(
              value: rows,
              onRetry: () => ref.invalidate(attendanceProvider(month)),
              builder: (report) {
                if (report.isEmpty) {
                  return const Center(
                    child: Text('Žádné rezervace v tomto měsíci.'),
                  );
                }
                final scheme = Theme.of(context).colorScheme;
                return ListView(
                  children: [
                    for (final (club, members) in attendanceByClub(report)) ...[
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 12, 16, 2),
                        child: Text(
                          '$club — '
                          '${members.fold(0, (s, r) => s + r.attended)}× / '
                          '${_players(members.length)}',
                          style: Theme.of(context).textTheme.labelLarge
                              ?.copyWith(color: scheme.onSurfaceVariant),
                        ),
                      ),
                      for (final r in members)
                        ListTile(
                          dense: true,
                          title: Text('${r.displayName} — ${r.attended}×'),
                        ),
                    ],
                  ],
                );
              },
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(16),
            child: FilledButton(
              onPressed: canExport ? () => _export(loaded) : null,
              child: Text(_exporting ? 'Exportuji…' : 'Export CSV'),
            ),
          ),
        ],
      ),
    );
  }
}
