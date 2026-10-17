import 'package:flutter/material.dart';

import '../../../core/ui.dart';
import 'form_dialog.dart';

/// The nickname of a club that is not the alley's own (0083) — an
/// opponent's. A club from the list comes with its [name]; „Přidat jiný
/// oddíl“ opens it without one, to be typed as it starts the club's
/// teams' names. Saves through [save] itself (nickname null = remove) and
/// pops with true.
class OtherClubDialog extends StatefulWidget {
  const OtherClubDialog({
    super.key,
    this.name,
    this.nickname,
    required this.save,
  });

  final String? name;

  /// The club's nickname so far; null = none yet.
  final String? nickname;
  final Future<void> Function(String name, String? nickname) save;

  @override
  State<OtherClubDialog> createState() => _OtherClubDialogState();
}

/// The dialog's field width; a narrow phone gives it less.
const double _fieldWidth = 360;

class _OtherClubDialogState extends State<OtherClubDialog> {
  final _name = TextEditingController();
  final _nickname = TextEditingController();

  /// A save or a removal is on its way: neither button starts another.
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _nickname.text = widget.nickname ?? '';
    // The example under the nickname follows the typed name.
    _name.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _name.dispose();
    _nickname.dispose();
    super.dispose();
  }

  String get _clubName => (widget.name ?? _name.text).trim();

  Future<bool?> _save() async {
    final name = _clubName;
    if (name.isEmpty) {
      snack(context, 'Vyplň název oddílu.');
      return null;
    }
    final nickname = _nickname.text.trim();
    if (nickname.isEmpty && widget.nickname == null) {
      snack(context, 'Vyplň přezdívku.');
      return null;
    }
    setState(() => _busy = true);
    final ok = await tryAction(
      context,
      () => widget.save(name, nickname.isEmpty ? null : nickname),
      success: nickname.isEmpty ? 'Přezdívka odebrána.' : 'Uloženo.',
      errorText: friendlyDbError,
    );
    if (!ok && mounted) setState(() => _busy = false);
    return ok ? true : null;
  }

  Future<void> _remove() async {
    setState(() => _busy = true);
    final ok = await tryAction(
      context,
      () => widget.save(_clubName, null),
      success: 'Přezdívka odebrána.',
      errorText: friendlyDbError,
    );
    if (!mounted) return;
    if (ok) {
      closeDialog(context, true);
    } else {
      setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final name = _clubName;
    return FormDialog<bool>(
      title: widget.name == null ? 'Jiný oddíl' : 'Přezdívka oddílu',
      onSave: _save,
      saveEnabled: !_busy,
      leadingActions: [
        if (widget.nickname != null)
          TextButton(
            onPressed: _busy ? null : _remove,
            child: const Text('Odebrat přezdívku'),
          ),
      ],
      children: [
        if (widget.name case final fixed?)
          Text(fixed, style: Theme.of(context).textTheme.titleMedium)
        else
          TextField(
            controller: _name,
            autofocus: true,
            maxLength: 80,
            decoration: const InputDecoration(
              labelText: 'Název oddílu',
              helperText:
                  'Jak začínají názvy jeho družstev, třeba „TJ Sokol '
                  'Husovice“.',
              helperMaxLines: 2,
            ),
          ),
        const SizedBox(height: 8),
        // Wide enough for the example under it, whatever the name; a
        // narrow phone gives it less.
        SizedBox(
          width: _fieldWidth,
          child: TextField(
            controller: _nickname,
            autofocus: widget.name != null,
            maxLength: 30,
            decoration: InputDecoration(
              labelText: 'Přezdívka',
              helperText: name.isEmpty
                  ? 'Krátké jméno, které appka ukazuje místo názvu — i v '
                        'názvech družstev.'
                  : 'Krátké jméno, které appka ukazuje místo názvu — i v '
                        'názvech družstev: „$name B“ → „přezdívka B“.',
              helperMaxLines: 3,
            ),
          ),
        ),
      ],
    );
  }
}
