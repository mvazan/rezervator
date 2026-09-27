/// „Rezervovat termín?" for a player in a group (0044): the same question,
/// plus whom it is for — "Já" by default, then each group mate. A group is
/// a handful of people, so a short choice, not the admin's roster search.
/// create_reservation holds everyone to their own cap, so whoever is at it
/// is offered greyed out, and the choice starts on the first one who is not.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../data/providers.dart';
import '../../../domain/models.dart';
import '../../../domain/schedule.dart';

Future<String?> showGroupBookingDialog(
  BuildContext context, {
  required String message,
  required String meId,
  required List<({String id, String name})> mates,
  ScheduleSettings? settings,
}) =>
    showDialog<String>(
      context: context,
      builder: (_) => _GroupBookingDialog(
        message: message,
        meId: meId,
        mates: mates,
        settings: settings,
      ),
    );

class _GroupBookingDialog extends ConsumerStatefulWidget {
  const _GroupBookingDialog({
    required this.message,
    required this.meId,
    required this.mates,
    this.settings,
  });

  final String message;
  final String meId;
  final List<({String id, String name})> mates;

  /// For the cap; null (not loaded yet) greys out nobody.
  final ScheduleSettings? settings;

  @override
  ConsumerState<_GroupBookingDialog> createState() =>
      _GroupBookingDialogState();
}

class _GroupBookingDialogState extends ConsumerState<_GroupBookingDialog> {
  /// The option tapped, null until one is. Not a `late` default: the
  /// counts arrive after the first frame, and until a tap the choice
  /// follows them to the first enabled option.
  String? _picked;

  /// Whether [playerId] is at the cap. A count still loading or failed is
  /// not — the RPC decides then, and a count the app could not fetch must
  /// not stand in the way.
  bool _atLimit(String playerId) {
    final settings = widget.settings;
    if (settings == null) return false;
    final count = ref.watch(activeReservationCountProvider(playerId)).value;
    return count != null && atReservationLimit(count, settings);
  }

  @override
  Widget build(BuildContext context) {
    final options = [
      for (final o in [(id: widget.meId, name: 'Já'), ...widget.mates])
        (id: o.id, name: o.name, atLimit: _atLimit(o.id)),
    ];
    final enabled = [
      for (final o in options)
        if (!o.atLimit) o.id,
    ];
    // The tapped option while it stays enabled, else the first enabled one
    // (Já, then the mates in their Czech order); null when nobody is.
    final chosen = enabled.contains(_picked) ? _picked : enabled.firstOrNull;
    return AlertDialog(
      title: const Text('Rezervovat termín?'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(widget.message),
          const SizedBox(height: 12),
          Text('Pro koho', style: Theme.of(context).textTheme.titleSmall),
          RadioGroup<String>(
            groupValue: chosen,
            onChanged: (v) => setState(() => _picked = v ?? _picked),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final o in options)
                  RadioListTile<String>(
                    contentPadding: EdgeInsets.zero,
                    value: o.id,
                    enabled: !o.atLimit,
                    title: Text(o.name),
                    subtitle: o.atLimit
                        ? Text(o.id == widget.meId
                            ? 'Máš maximální počet rezervací.'
                            : 'Má maximální počet rezervací.')
                        : null,
                  ),
              ],
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Zrušit'),
        ),
        FilledButton(
          onPressed:
              chosen == null ? null : () => Navigator.pop(context, chosen),
          child: const Text('Rezervovat'),
        ),
      ],
    );
  }
}
