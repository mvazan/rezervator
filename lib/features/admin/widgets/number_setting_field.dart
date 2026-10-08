/// A whole number the admin types in (Správa → Kiosk): a text field with
/// its unit, written when the admin presses Enter or leaves the field —
/// only when the number is new and between [min] and [max]; out of that
/// range the field says so and writes nothing.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class NumberSettingField extends StatefulWidget {
  const NumberSettingField({
    super.key,
    required this.label,
    required this.value,
    required this.unit,
    required this.min,
    required this.max,
    this.helper,
    required this.onChanged,
  });

  final String label;

  /// The stored value; a change from outside (another admin, the echo of
  /// a write) lands in the field while it is not being edited.
  final int value;

  /// Shown after the number: „s“, „px“, „%“, „dní“.
  final String unit;
  final int min;
  final int max;
  final String? helper;

  /// Null = read-only (no settings row yet).
  final ValueChanged<int>? onChanged;

  @override
  State<NumberSettingField> createState() => _NumberSettingFieldState();
}

class _NumberSettingFieldState extends State<NumberSettingField> {
  late final _controller = TextEditingController(text: '${widget.value}');
  final _focus = FocusNode();
  String? _error;

  @override
  void initState() {
    super.initState();
    _focus.addListener(() {
      if (!_focus.hasFocus) _commit();
    });
  }

  @override
  void didUpdateWidget(NumberSettingField old) {
    super.didUpdateWidget(old);
    if (old.value != widget.value && !_focus.hasFocus) {
      _controller.text = '${widget.value}';
      _error = null;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  /// Writes the field's number when it is valid and new; an invalid one
  /// shows the allowed range instead.
  void _commit() {
    final text = _controller.text.trim();
    final n = int.tryParse(text);
    if (n == null || n < widget.min || n > widget.max) {
      setState(
        () => _error = 'Zadej číslo od ${widget.min} do ${widget.max}.',
      );
      return;
    }
    if (_error != null) setState(() => _error = null);
    if (n != widget.value) widget.onChanged?.call(n);
  }

  @override
  Widget build(BuildContext context) => TextField(
    controller: _controller,
    focusNode: _focus,
    enabled: widget.onChanged != null,
    keyboardType: TextInputType.number,
    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
    textInputAction: TextInputAction.done,
    onSubmitted: (_) => _commit(),
    onChanged: (_) {
      if (_error != null) setState(() => _error = null);
    },
    decoration: InputDecoration(
      labelText: widget.label,
      suffixText: widget.unit,
      helperText: widget.helper,
      helperMaxLines: 4,
      errorText: _error,
      errorMaxLines: 2,
      border: const OutlineInputBorder(),
    ),
  );
}
