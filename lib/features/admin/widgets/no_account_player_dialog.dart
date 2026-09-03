import 'package:flutter/material.dart';

import '../../../core/ui.dart';
import '../../../data/providers.dart';
import '../../../domain/limits.dart';
import '../../../domain/models.dart';
import 'form_dialog.dart';

/// Add/edit dialog for a "hráč bez účtu" (0022): a profile the admin keeps
/// by hand for someone who never signs in — booked from the calendar,
/// picked by name on the kiosk. Pops `true` after a successful save.
class NoAccountPlayerDialog extends StatefulWidget {
  const NoAccountPlayerDialog({super.key, this.existing, required this.clubs});

  /// The row being edited; null adds a new one.
  final Profile? existing;
  final List<Club> clubs;

  @override
  State<NoAccountPlayerDialog> createState() => _NoAccountPlayerDialogState();
}

class _NoAccountPlayerDialogState extends State<NoAccountPlayerDialog> {
  final _name = TextEditingController();
  final _nick = TextEditingController();
  String? _clubId;

  @override
  void initState() {
    super.initState();
    final existing = widget.existing;
    _name.text = existing?.displayName ?? '';
    _nick.text = existing?.nick ?? '';
    // A club deleted since the row was made reads as "Bez oddílu" — the
    // dropdown has no item for it.
    final clubId = existing?.clubId;
    _clubId = widget.clubs.any((c) => c.id == clubId) ? clubId : null;
  }

  @override
  void dispose() {
    _name.dispose();
    _nick.dispose();
    super.dispose();
  }

  /// Validates and saves; null keeps the dialog open (the snack said why).
  Future<bool?> _save() async {
    final name = _name.text.trim();
    if (name.isEmpty) {
      snack(context, 'Vyplň jméno hráče.');
      return null;
    }
    final existing = widget.existing;
    final ok = await tryAction(
      context,
      () => Api.savePlaceholderPlayer(
        id: existing?.id,
        displayName: name,
        nick: _nick.text.trim(),
        clubId: _clubId,
      ),
      success: existing == null ? 'Hráč přidán.' : 'Uloženo.',
      errorText: friendlyDbError,
    );
    return ok ? true : null;
  }

  @override
  Widget build(BuildContext context) {
    final existing = widget.existing;
    final theme = Theme.of(context);

    return FormDialog<bool>(
      title:
          existing == null ? 'Přidat hráče bez účtu' : 'Upravit hráče bez účtu',
      onSave: _save,
      children: [
        if (existing == null) ...[
          Text(
            'Pro hráče, který se nepřihlašuje. Správce ho rezervuje '
            'z kalendáře, na kiosku si vybere své jméno. Až si založí účet, '
            'oba profily sloučíš.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 12),
        ],
        TextField(
          controller: _name,
          autofocus: true,
          textCapitalization: TextCapitalization.words,
          decoration: const InputDecoration(labelText: 'Jméno a příjmení'),
        ),
        const SizedBox(height: 8),
        TextField(
          controller: _nick,
          maxLength: Limits.nickLength,
          decoration: const InputDecoration(
            labelText: 'Přezdívka na tabuli (nepovinné)',
            counterText: '',
          ),
        ),
        if (widget.clubs.isNotEmpty) ...[
          const SizedBox(height: 8),
          DropdownButtonFormField<String?>(
            initialValue: _clubId,
            isExpanded: true,
            decoration: const InputDecoration(labelText: 'Oddíl'),
            items: [
              const DropdownMenuItem(value: null, child: Text('Bez oddílu')),
              for (final club in widget.clubs)
                DropdownMenuItem(value: club.id, child: Text(club.name)),
            ],
            onChanged: (id) => setState(() => _clubId = id),
          ),
        ],
      ],
    );
  }
}
