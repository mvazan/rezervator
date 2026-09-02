/// The admin add/edit dialog shell: title, scrolling column of fields,
/// Zrušit + Uložit, and the saving state ("Ukládám…", buttons disabled,
/// pop on success, stay open on failure) that every dialog used to keep by
/// hand. The owner keeps its fields, controllers and validation; it hands
/// over one [onSave].
library;

import 'package:flutter/material.dart';

class FormDialog<T> extends StatefulWidget {
  const FormDialog({
    super.key,
    required this.title,
    required this.children,
    required this.onSave,
    this.saveLabel = 'Uložit',
    this.savingLabel = 'Ukládám…',
    this.cancelLabel = 'Zrušit',
    this.crossAxisAlignment = CrossAxisAlignment.start,
    this.leadingActions = const [],
  });

  final String title;

  /// The form fields, laid out in a scrolling column (min height).
  final List<Widget> children;

  /// Validates and performs the save. Return the dialog's result (the
  /// dialog pops with it — `true` when the caller only needs "done") or
  /// null to stay open: validation failed or the RPC failed and
  /// [tryAction] already showed the error.
  final Future<T?> Function() onSave;

  final String saveLabel;
  final String savingLabel;
  final String cancelLabel;
  final CrossAxisAlignment crossAxisAlignment;

  /// Extra actions rendered before Zrušit (e.g. a destructive button).
  final List<Widget> leadingActions;

  @override
  State<FormDialog<T>> createState() => _FormDialogState<T>();
}

class _FormDialogState<T> extends State<FormDialog<T>> {
  bool _saving = false;

  Future<void> _save() async {
    setState(() => _saving = true);
    final result = await widget.onSave();
    if (!mounted) return;
    if (result != null) {
      Navigator.of(context).pop(result);
    } else {
      setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: widget.crossAxisAlignment,
          children: widget.children,
        ),
      ),
      actions: [
        ...widget.leadingActions,
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(widget.cancelLabel),
        ),
        FilledButton(
          onPressed: _saving ? null : _save,
          child: Text(_saving ? widget.savingLabel : widget.saveLabel),
        ),
      ],
    );
  }
}
