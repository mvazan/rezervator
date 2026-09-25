/// Správa → Oddíly: the ČKA card's first setup — 1. the kuželna on
/// vysledky.kuzelky.cz, 2. its oddíly and their teams (a discovery, which
/// links the venue's clubs to ours or creates them, 0046), 3. automatic
/// sync on and the first run. The step it opens on comes from the server
/// state ([FederationWizard.stepFor]), so an admin who leaves half-way
/// comes back where they left; Pokračovat and Zpět move on or back.
library;

import 'package:flutter/material.dart';

import '../../../domain/labels.dart';
import '../../../domain/models.dart';
import '../../../domain/slug.dart';
import 'venue_slug_field.dart';

class FederationWizard extends StatefulWidget {
  const FederationWizard({
    super.key,
    required this.sync,
    required this.teams,
    required this.discovering,
    required this.saveSlug,
    required this.discover,
    required this.enable,
  });

  final FederationSync sync;
  final List<Team> teams;

  /// A discovery is running, or its report is not in yet — the card polls.
  final bool discovering;

  /// Each resolves to whether it worked; the card shows any error.
  final Future<bool> Function(String slug) saveSlug;
  final Future<bool> Function() discover;
  final Future<bool> Function() enable;

  /// The step the server state opens on, 0-based: no slug → the kuželna;
  /// no team, or no successful discovery of this kuželna → the oddíly and
  /// teams; else switching the sync on. A moved kuželna's teams are the old
  /// one's: 0046's set_federation_sync drops the report with the move.
  static int stepFor(FederationSync sync, List<Team> teams) {
    if (!sync.configured) return 0;
    final report = sync.discover;
    return teams.isEmpty || report == null || report.failed ? 1 : 2;
  }

  @override
  State<FederationWizard> createState() => _FederationWizardState();
}

class _FederationWizardState extends State<FederationWizard> {
  static const _titles = [
    'Kuželna na webu ČKA',
    'Oddíly a týmy',
    'Zapnout stahování',
  ];

  /// Where Pokračovat / Zpět took the admin; null follows the server state.
  int? _step;
  bool _busy = false;
  late final _input = TextEditingController(text: widget.sync.venueSlug);
  String? _inputError;

  /// Step 1 saved another kuželna than the row had. The discovery report
  /// the row held then ([_movedFrom] is its `at`) was the old kuželna's.
  /// 0046's set_federation_sync drops it, but until that echo arrives step 2
  /// must not show it, nor offer Pokračovat for the old kuželna's teams.
  bool _moved = false;
  DateTime? _movedFrom;

  int get _current =>
      _step ?? FederationWizard.stepFor(widget.sync, widget.teams);

  /// The row's discovery report, unless it is the one from before a move.
  FederationDiscoverReport? get _report {
    final report = widget.sync.discover;
    return _moved && report?.at == _movedFrom ? null : report;
  }

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  Future<void> _run(Future<void> Function() action) async {
    setState(() => _busy = true);
    try {
      await action();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _saveSlug() => _run(() async {
        final error = venueSlugInputError(_input.text);
        if (error != null) {
          setState(() => _inputError = error);
          return;
        }
        final slug = venueSlugFromInput(_input.text)!;
        final before = widget.sync;
        final ok = await widget.saveSlug(slug);
        if (!ok || !mounted) return;
        setState(() {
          if (slug != before.venueSlug) {
            _moved = true;
            _movedFrom = before.discover?.at;
          }
          _step = 1;
        });
      });

  Future<void> _discover() => _run(() async {
        final ok = await widget.discover();
        if (ok && mounted) setState(() => _step = 1);
      });

  void _go(int step) => setState(() {
        _step = step;
        if (step == 0) {
          _input.text = widget.sync.venueSlug;
          _inputError = null;
        }
      });

  @override
  Widget build(BuildContext context) {
    final step = _current;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _StepBar(step: step, count: _titles.length),
        const SizedBox(height: 12),
        Text(_titles[step], style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 8),
        ...switch (step) {
          0 => _venue(),
          1 => _clubsAndTeams(),
          _ => _switchOn(),
        },
      ],
    );
  }

  Widget _buttons(List<Widget> children) => Padding(
        padding: const EdgeInsets.only(top: 12),
        child: Wrap(spacing: 8, runSpacing: 8, children: children),
      );

  Widget _back() => TextButton(
        onPressed: _busy ? null : () => _go(_current - 1),
        child: const Text('Zpět'),
      );

  List<Widget> _venue() => [
        const Text(venueSlugHelp),
        const SizedBox(height: 8),
        VenueSlugField(
          controller: _input,
          enabled: !_busy,
          errorText: _inputError,
          onChanged: () {
            if (_inputError != null) setState(() => _inputError = null);
          },
        ),
        _buttons([
          FilledButton(
            onPressed: _busy ? null : _saveSlug,
            child: const Text('Pokračovat'),
          ),
        ]),
      ];

  List<Widget> _clubsAndTeams() {
    final error = TextStyle(color: Theme.of(context).colorScheme.error);
    final report = _report;
    return [
      const Text(
        'Načteme oddíly, které na kuželně hrají, a jejich týmy. Chybějící '
        'oddíly založíme.',
      ),
      const SizedBox(height: 8),
      if (widget.discovering)
        const Row(
          children: [
            SizedBox.square(
              dimension: 14,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            SizedBox(width: 8),
            Expanded(child: Text('Načítají se oddíly a týmy z webu…')),
          ],
        )
      else if (report == null)
        _buttons([
          _back(),
          FilledButton(
            onPressed: _busy ? null : _discover,
            child: const Text('Načíst oddíly a týmy'),
          ),
        ])
      else ...[
        if (report.failed)
          Text('Načtení se nepovedlo: ${report.error}', style: error)
        else if (report.teams == 0)
          Text(
            'Na kuželně se nenašel žádný tým. Zkontroluj adresu kuželny.',
            style: error,
          )
        else ...[
          Text(discoveryClubsLabel(report)),
          Text(discoveryTeamsLabel(report)),
        ],
        _buttons([
          _back(),
          OutlinedButton(
            onPressed: _busy ? null : _discover,
            child: const Text('Načíst znovu'),
          ),
          FilledButton(
            onPressed: _busy || widget.teams.isEmpty ? null : () => _go(2),
            child: const Text('Pokračovat'),
          ),
        ]),
      ],
    ];
  }

  List<Widget> _switchOn() => [
        const Text(
          'Stáhnou se všechny zápasy a výsledky těchto týmů. Zápasy z rozpisu '
          'se spárují a zůstanou. První stažení trvá asi půl hodiny, pak se '
          'vše aktualizuje samo.',
        ),
        _buttons([
          _back(),
          FilledButton(
            onPressed: _busy ? null : () => _run(widget.enable),
            child: const Text('Zapnout a stáhnout zápasy'),
          ),
        ]),
      ];
}

/// Three short bars over the step: the done and the current ones filled.
class _StepBar extends StatelessWidget {
  const _StepBar({required this.step, required this.count});

  final int step;
  final int count;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      children: [
        for (var i = 0; i < count; i++) ...[
          if (i > 0) const SizedBox(width: 4),
          Expanded(
            child: Container(
              height: 4,
              decoration: BoxDecoration(
                color:
                    i <= step ? scheme.primary : scheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
        ],
      ],
    );
  }
}
