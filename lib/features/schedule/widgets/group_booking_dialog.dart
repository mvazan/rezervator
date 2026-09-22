/// „Rezervovat termín?" for a player in a group (0044): the same question,
/// plus whom it is for — "Já" by default, then each group mate. A group is
/// a handful of people, so a short choice, not the admin's roster search.
library;

import 'package:flutter/material.dart';

Future<String?> showGroupBookingDialog(
  BuildContext context, {
  required String message,
  required String meId,
  required List<({String id, String name})> mates,
}) =>
    showDialog<String>(
      context: context,
      builder: (_) =>
          _GroupBookingDialog(message: message, meId: meId, mates: mates),
    );

class _GroupBookingDialog extends StatefulWidget {
  const _GroupBookingDialog({
    required this.message,
    required this.meId,
    required this.mates,
  });

  final String message;
  final String meId;
  final List<({String id, String name})> mates;

  @override
  State<_GroupBookingDialog> createState() => _GroupBookingDialogState();
}

class _GroupBookingDialogState extends State<_GroupBookingDialog> {
  late String _for = widget.meId;

  @override
  Widget build(BuildContext context) {
    final options = [(id: widget.meId, name: 'Já'), ...widget.mates];
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
            groupValue: _for,
            onChanged: (v) => setState(() => _for = v ?? _for),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final o in options)
                  RadioListTile<String>(
                    contentPadding: EdgeInsets.zero,
                    value: o.id,
                    title: Text(o.name),
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
          onPressed: () => Navigator.pop(context, _for),
          child: const Text('Rezervovat'),
        ),
      ],
    );
  }
}
