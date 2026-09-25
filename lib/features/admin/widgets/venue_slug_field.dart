/// Správa → Oddíly: the kuželna's page on vysledky.kuzelky.cz — the field
/// the ČKA setup wizard's first step and the „Změnit kuželnu“ dialog share.
/// It takes the page's whole address or just the slug
/// ([venueSlugFromInput]) and says inline what is wrong
/// ([venueSlugInputError]).
library;

import 'package:flutter/material.dart';

import '../../../core/ui.dart';
import '../../../domain/slug.dart';
import 'form_dialog.dart';

/// Where the admin finds the address — step 1 and the dialog say the same.
const venueSlugHelp = 'Na vysledky.kuzelky.cz otevři Kuželny, najdi svou '
    'kuželnu a zkopíruj adresu stránky. Stačí ji celou vložit.';

class VenueSlugField extends StatelessWidget {
  const VenueSlugField({
    super.key,
    required this.controller,
    this.errorText,
    this.onChanged,
    this.autofocus = false,
    this.enabled = true,
  });

  final TextEditingController controller;
  final String? errorText;
  final VoidCallback? onChanged;
  final bool autofocus;
  final bool enabled;

  @override
  Widget build(BuildContext context) => TextField(
        controller: controller,
        enabled: enabled,
        autofocus: autofocus,
        autocorrect: false,
        enableSuggestions: false,
        keyboardType: TextInputType.url,
        onChanged: (_) => onChanged?.call(),
        decoration: InputDecoration(
          labelText: 'Adresa kuželny',
          hintText: 'vysledky.kuzelky.cz/detail-kuzelny/…',
          errorText: errorText,
          errorMaxLines: 3,
        ),
      );
}

/// The normal view's pencil: another kuželna. Saves the parsed slug
/// through [save] and pops `true`; stays open on bad input or a refused
/// save; null on Zrušit.
class VenueSlugDialog extends StatefulWidget {
  const VenueSlugDialog({super.key, required this.initial, required this.save});

  final String initial;
  final Future<void> Function(String slug) save;

  @override
  State<VenueSlugDialog> createState() => _VenueSlugDialogState();
}

class _VenueSlugDialogState extends State<VenueSlugDialog> {
  late final _input = TextEditingController(text: widget.initial);
  String? _error;

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  Future<bool?> _save() async {
    final error = venueSlugInputError(_input.text);
    if (error != null) {
      setState(() => _error = error);
      return null;
    }
    final slug = venueSlugFromInput(_input.text)!;
    final ok = await tryAction(
      context,
      () => widget.save(slug),
      success: 'Uloženo.',
      errorText: friendlyDbError,
    );
    return ok ? true : null;
  }

  @override
  Widget build(BuildContext context) => FormDialog<bool>(
        title: 'Změnit kuželnu',
        onSave: _save,
        children: [
          Text(venueSlugHelp, style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(height: 12),
          VenueSlugField(
            controller: _input,
            autofocus: true,
            errorText: _error,
            onChanged: () {
              if (_error != null) setState(() => _error = null);
            },
          ),
        ],
      );
}
