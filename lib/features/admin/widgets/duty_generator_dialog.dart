/// „Vygenerovat…“ in Správa → Služby (0050): a run of duties from „Od“ to
/// „Do“, weekly from a chosen change day or every N days, with a live
/// preview of what `duty_generate` will do — computed by the same rules in
/// `planDutyPeriods`.
library;

import 'package:flutter/material.dart';

import '../../../core/ui.dart';
import '../../../domain/duties.dart';
import '../../../domain/labels.dart' show czechCount;
import '../../../domain/models.dart';
import 'duty_parts.dart';
import 'form_dialog.dart';
import 'form_fields.dart';

/// The preview sentence for [plan]: „Vznikne 40 služeb, poslední zkrácená
/// na 3 dny. 2 se překrývají a přeskočí se.“ — the verbs agreeing with
/// their numbers, the clipped part only when the end cut the last duty
/// short.
String dutyPlanPreview(DutyPlan plan) {
  final n = plan.created;
  final created = switch (n) {
    0 => 'Nevznikne žádná služba',
    1 => 'Vznikne 1 služba',
    >= 2 && <= 4 => 'Vzniknou $n služby',
    _ => 'Vznikne $n služeb',
  };
  final clippedDays = plan.lastClippedDays;
  final clipped = clippedDays == null
      ? ''
      : '${n == 1 ? ', zkrácená' : ', poslední zkrácená'} na '
            '${czechCount(clippedDays, 'den', 'dny', 'dní')}';
  final skipped = switch (plan.skipped) {
    0 => '',
    final k when k >= 2 && k <= 4 => ' $k se překrývají a přeskočí se.',
    final k => ' $k se překrývá a přeskočí se.',
  };
  return '$created$clipped.$skipped';
}

enum _Rhythm { weekly, everyN }

/// Pops the number of duties created, or null when cancelled.
class DutyGeneratorDialog extends StatefulWidget {
  const DutyGeneratorDialog({
    super.key,
    required this.existing,
    required this.today,
    required this.generate,
  });

  /// Every period of the alley — the defaults continue after the last one,
  /// and the preview skips the ones a new duty would overlap.
  final List<DutyPeriod> existing;
  final Day today;

  final Future<({int created, int skipped})> Function({
    required Day from,
    required int days,
    required Day until,
  })
  generate;

  @override
  State<DutyGeneratorDialog> createState() => _DutyGeneratorDialogState();
}

class _DutyGeneratorDialogState extends State<DutyGeneratorDialog> {
  late _Rhythm _rhythm;

  /// „Od“ as picked; in the weekly rhythm the first duty starts on the
  /// first [_weekday] from here.
  late Day _from;

  /// The weekly change day, ISO (1 = po).
  late int _weekday;

  /// „Počet dní“ of the every-N rhythm.
  late int _days;
  late Day _until;

  @override
  void initState() {
    super.initState();
    final next = nextDutyDefaults(widget.existing, widget.today);
    _from = next.start;
    _weekday = next.start.weekday;
    _rhythm = next.days == 7 ? _Rhythm.weekly : _Rhythm.everyN;
    _days = next.days;
    _until = seasonEndFor(next.start);
  }

  /// The first duty's first day.
  Day get _start => _rhythm == _Rhythm.weekly
      ? _from.addDays((_weekday - _from.weekday + 7) % 7)
      : _from;

  int get _length => _rhythm == _Rhythm.weekly ? 7 : _days;

  DutyPlan get _plan =>
      planDutyPeriods(_start, _length, _until, widget.existing);

  Future<void> _pickFrom() async {
    final picked = await pickDay(
      context,
      initial: _from,
      first: widget.today.addDays(-366),
      last: widget.today.addDays(800),
    );
    if (picked == null) return;
    setState(() {
      _from = picked;
      _weekday = picked.weekday;
    });
  }

  Future<void> _pickUntil() async {
    final picked = await pickDay(
      context,
      initial: _until,
      first: widget.today.addDays(-366),
      last: widget.today.addDays(1200),
    );
    if (picked != null) setState(() => _until = picked);
  }

  Future<int?> _save() async {
    int? created;
    final ok = await tryAction(
      context,
      () async => created = (await widget.generate(
        from: _start,
        days: _length,
        until: _until,
      )).created,
      errorText: friendlyDbError,
    );
    return ok ? created : null;
  }

  /// Why the range cannot be planned, in the words of its field.
  String _errorText(DutyPlan plan) => switch (plan.error) {
    'invalid_range' when !_until.isBefore(_start) =>
      'Najednou jde naplánovat nejvýše 400 dní.',
    'invalid_range' => '„Do“ musí být po „Od“.',
    _ => 'Počet dní musí být 1–31.',
  };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final plan = _plan;
    final first = plan.periods.isEmpty ? null : plan.periods.first;
    return FormDialog<int>(
      title: 'Vygenerovat služby',
      saveLabel: 'Vygenerovat',
      saveEnabled: plan.error == null && plan.created > 0,
      onSave: _save,
      children: [
        SegmentedButton<_Rhythm>(
          segments: const [
            ButtonSegment(value: _Rhythm.weekly, label: Text('Každý týden')),
            ButtonSegment(value: _Rhythm.everyN, label: Text('Po N dnech')),
          ],
          selected: {_rhythm},
          showSelectedIcon: false,
          onSelectionChanged: (selected) =>
              setState(() => _rhythm = selected.single),
        ),
        const SizedBox(height: 12),
        if (_rhythm == _Rhythm.weekly) ...[
          Text('Mění se v', style: theme.textTheme.labelLarge),
          const SizedBox(height: 4),
          Wrap(
            spacing: 4,
            runSpacing: 4,
            children: [
              for (var weekday = 1; weekday <= 7; weekday++)
                ChoiceChip(
                  label: Text(weekdaysShort[weekday - 1]),
                  selected: _weekday == weekday,
                  onSelected: (_) => setState(() => _weekday = weekday),
                ),
            ],
          ),
        ] else
          _DaysStepper(
            value: _days,
            onChanged: (days) => setState(() => _days = days),
          ),
        PickerTile(label: 'Od', value: dutyPickerDate(_from), onTap: _pickFrom),
        PickerTile(
          label: 'Do',
          value: dutyPickerDate(_until),
          onTap: _pickUntil,
        ),
        const SizedBox(height: 8),
        if (plan.error != null)
          Text(
            _errorText(plan),
            style: TextStyle(color: theme.colorScheme.error),
          )
        else ...[
          Text(dutyPlanPreview(plan)),
          if (first != null) ...[
            const SizedBox(height: 4),
            Text(
              first.startsOn == first.endsOn
                  ? 'První služba: ${dutyDayLabel(first.startsOn)}'
                  : 'První služba: ${dutyDayLabel(first.startsOn)} – '
                        '${dutyDayLabel(first.endsOn)}',
              style: theme.textTheme.bodySmall,
            ),
          ],
        ],
      ],
    );
  }
}

/// „Počet dní  −  7  +“, 1–31 like `duty_generate`.
class _DaysStepper extends StatelessWidget {
  const _DaysStepper({required this.value, required this.onChanged});

  final int value;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        const Expanded(child: Text('Počet dní')),
        IconButton(
          icon: const Icon(Icons.remove),
          tooltip: 'Méně dní',
          onPressed: value > 1 ? () => onChanged(value - 1) : null,
        ),
        SizedBox(width: 32, child: Text('$value', textAlign: TextAlign.center)),
        IconButton(
          icon: const Icon(Icons.add),
          tooltip: 'Více dní',
          onPressed: value < 31 ? () => onChanged(value + 1) : null,
        ),
      ],
    );
  }
}
