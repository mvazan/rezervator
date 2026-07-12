import 'dart:convert';

import 'package:file_saver/file_saver.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/ui.dart';
import '../../data/providers.dart';
import '../../domain/csv.dart';
import '../../domain/models.dart';
import 'widgets/admin_body.dart';

/// Admin: monthly attendance report (per player training count) with CSV
/// export.
class ReportScreen extends ConsumerStatefulWidget {
  const ReportScreen({super.key});

  @override
  ConsumerState<ReportScreen> createState() => _ReportScreenState();
}

class _ReportScreenState extends ConsumerState<ReportScreen> {
  late int _year;
  late int _month;
  Future<List<AttendanceRow>>? _future;
  bool _exporting = false;

  @override
  void initState() {
    super.initState();
    final now = today();
    _year = now.year;
    _month = now.month;
    _load();
  }

  void _load() {
    setState(() => _future = Api.monthlyAttendance(_year, _month));
  }

  void _shiftMonth(int delta) {
    setState(() {
      final total = _year * 12 + (_month - 1) + delta;
      _year = total ~/ 12;
      _month = total % 12 + 1;
    });
    _load();
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
      errorText: friendlyDbError,
    );
    if (mounted) setState(() => _exporting = false);
  }

  /// Czech pluralization for players: 1 hráč, 2–4 hráči, 5+ hráčů.
  static String _players(int n) =>
      n == 1 ? '1 hráč' : (n >= 2 && n <= 4 ? '$n hráči' : '$n hráčů');

  /// Rows grouped into club sections ordered by club total (desc), players
  /// by attended (desc) within — "Bez oddílu" always last. Each entry is
  /// (header, members).
  static List<(String, List<AttendanceRow>)> byClub(List<AttendanceRow> rows) {
    final groups = <String, List<AttendanceRow>>{};
    for (final r in rows) {
      groups.putIfAbsent(r.club, () => []).add(r);
    }
    int total(List<AttendanceRow> members) =>
        members.fold(0, (sum, r) => sum + r.attended);
    final named = [
      for (final entry in groups.entries)
        if (entry.key.isNotEmpty) entry,
    ]..sort((a, b) => total(b.value).compareTo(total(a.value)));
    return [
      for (final entry in named) (entry.key, entry.value),
      if (groups[''] case final unaffiliated?) ('Bez oddílu', unaffiliated),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final profile = ref.watch(myProfileProvider).value;
    if (profile?.isAdmin != true) {
      return Scaffold(
        appBar: AppBar(title: const Text('Docházka')),
        body: const Center(child: Text('Jen pro správce.')),
      );
    }

    return Scaffold(
      appBar: AppBar(title: const Text('Docházka')),
      body: AdminBody(
        child: Column(
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
              child: FutureBuilder<List<AttendanceRow>>(
                future: _future,
                builder: (context, snapshot) {
                  if (snapshot.connectionState == ConnectionState.waiting) {
                    return const Center(child: CircularProgressIndicator());
                  }
                  if (snapshot.hasError) {
                    return Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(friendlyDbError(snapshot.error!)),
                          const SizedBox(height: 8),
                          FilledButton(
                            onPressed: _load,
                            child: const Text('Zkusit znovu'),
                          ),
                        ],
                      ),
                    );
                  }
                  final rows = snapshot.data ?? const <AttendanceRow>[];
                  if (rows.isEmpty) {
                    return const Center(
                      child: Text('Žádné rezervace v tomto měsíci.'),
                    );
                  }
                  final scheme = Theme.of(context).colorScheme;
                  return ListView(
                    children: [
                      for (final (club, members) in byClub(rows)) ...[
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
              child: FutureBuilder<List<AttendanceRow>>(
                future: _future,
                builder: (context, snapshot) {
                  final rows = snapshot.data ?? const <AttendanceRow>[];
                  final loading =
                      snapshot.connectionState == ConnectionState.waiting;
                  final canExport = !loading && !_exporting && rows.isNotEmpty;
                  return FilledButton(
                    onPressed: canExport ? () => _export(rows) : null,
                    child: Text(_exporting ? 'Exportuji…' : 'Export CSV'),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}
