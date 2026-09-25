/// Můj profil → Kontakt (0048): the player's phone, and whether Klubovna →
/// Kontakty shows their e-mail and phone to the other players of the alley.
library;

import 'package:flutter/material.dart';

import '../../../core/ui.dart';
import '../../../domain/models.dart';
import '../../../domain/phone.dart';

class ContactCard extends StatelessWidget {
  const ContactCard({
    super.key,
    required this.profile,
    required this.updateMyContact,
  });

  final Profile profile;

  /// `Api.updateMyContact` in the app — optimistic, so a switch flips at
  /// once; a fake in widget tests.
  final Future<void> Function({String? phone, bool? showEmail, bool? showPhone})
      updateMyContact;

  Future<void> _editPhone(BuildContext context) async {
    final current = profile.phone;
    final phone = await showDialog<String>(
      context: context,
      builder: (_) =>
          _PhoneDialog(initial: current == null ? '' : formatPhone(current)),
    );
    if (phone == null || !context.mounted) return;
    await tryAction(
      context,
      () => updateMyContact(phone: phone),
      success: 'Uloženo.',
      errorText: friendlyDbError,
    );
  }

  @override
  Widget build(BuildContext context) {
    final phone = profile.phone;
    return Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const ListTile(title: Text('Kontakt')),
          ListTile(
            title: const Text('Telefon'),
            subtitle: Text(phone == null ? 'nenastaven' : formatPhone(phone)),
            trailing: TextButton(
              onPressed: () => _editPhone(context),
              child: const Text('Upravit'),
            ),
          ),
          SwitchListTile(
            title: const Text('Ukázat e-mail v Kontaktech'),
            subtitle: const Text('Ostatní hráči kuželny ti můžou napsat.'),
            value: profile.showEmail,
            onChanged: (v) => tryAction(
              context,
              () => updateMyContact(showEmail: v),
              errorText: friendlyDbError,
            ),
          ),
          // Works without a phone too — there is just nothing to show yet.
          SwitchListTile(
            title: const Text('Ukázat telefon v Kontaktech'),
            subtitle: const Text('Zavolat nebo napsat přes WhatsApp.'),
            value: profile.showPhone,
            onChanged: (v) => tryAction(
              context,
              () => updateMyContact(showPhone: v),
              errorText: friendlyDbError,
            ),
          ),
        ],
      ),
    );
  }
}

/// Resolves to the E.164 number, '' to remove the phone, or null (Zrušit).
class _PhoneDialog extends StatefulWidget {
  const _PhoneDialog({required this.initial});

  final String initial;

  @override
  State<_PhoneDialog> createState() => _PhoneDialogState();
}

class _PhoneDialogState extends State<_PhoneDialog> {
  late final _controller = TextEditingController(text: widget.initial);
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _save() {
    final typed = _controller.text.trim();
    if (typed.isEmpty) {
      closeDialog(context, '');
      return;
    }
    final phone = normalizePhone(typed);
    if (phone == null) {
      setState(() => _error = invalidPhoneMessage);
      return;
    }
    closeDialog(context, phone);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Telefon'),
      content: TextField(
        controller: _controller,
        autofocus: true,
        keyboardType: TextInputType.phone,
        decoration: InputDecoration(
          hintText: '+420 777 123 456',
          errorText: _error,
        ),
        onChanged: (_) {
          if (_error != null) setState(() => _error = null);
        },
        onSubmitted: (_) => _save(),
      ),
      actions: [
        TextButton(
          onPressed: () => closeDialog<String>(context),
          child: const Text('Zrušit'),
        ),
        FilledButton(onPressed: _save, child: const Text('Uložit')),
      ],
    );
  }
}
