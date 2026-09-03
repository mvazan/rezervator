import 'package:flutter/material.dart';

import '../../../core/ui.dart';
import '../../../data/providers.dart';
import '../../../domain/limits.dart';
import '../../../domain/models.dart';
import 'form_dialog.dart';

/// Which of the two profiles a field's value comes from.
enum _Side { account, placeholder }

/// The person behind [placeholder] (a hand-made "hráč bez účtu") registered
/// as [target]: the admin picks which name / nick / club survive, the
/// account takes over the placeholder's reservations (and gets approved
/// when pending), and the placeholder row disappears. Pops `true` after
/// the merge.
///
/// A field gets a side-by-side chooser only when both profiles fill it
/// differently; otherwise the one value there is prefills the editable
/// field. A radio pick copies that side into the field; whatever is in the
/// field at Sloučit is what gets sent, so a later manual edit wins.
class MergePlayersDialog extends StatefulWidget {
  const MergePlayersDialog({
    super.key,
    required this.placeholder,
    required this.target,
    required this.clubs,
  });

  final Profile placeholder;

  /// The account (pending registrant or approved member) that survives.
  final Profile target;
  final List<Club> clubs;

  @override
  State<MergePlayersDialog> createState() => _MergePlayersDialogState();
}

class _MergePlayersDialogState extends State<MergePlayersDialog> {
  final _name = TextEditingController();
  final _nick = TextEditingController();
  String? _clubId;

  /// [clubId] when the club still exists, else null — a deleted club is
  /// "no club" for both the chooser and the dropdown.
  String? _validClub(String? clubId) =>
      widget.clubs.any((c) => c.id == clubId) ? clubId : null;

  String? get _accountClub => _validClub(widget.target.clubId);
  String? get _placeholderClub => _validClub(widget.placeholder.clubId);

  @override
  void initState() {
    super.initState();
    final account = widget.target;
    final placeholder = widget.placeholder;
    _name.text = account.displayName;
    _nick.text = placeholder.nick.isNotEmpty ? placeholder.nick : account.nick;
    _clubId = _accountClub ?? _placeholderClub;
  }

  @override
  void dispose() {
    _name.dispose();
    _nick.dispose();
    super.dispose();
  }

  /// Validates and merges; null keeps the dialog open (the snack said why).
  Future<bool?> _save() async {
    final name = _name.text.trim();
    if (name.isEmpty) {
      snack(context, 'Vyplň jméno hráče.');
      return null;
    }
    final ok = await tryAction(
      context,
      () => Api.mergePlaceholderPlayer(
        placeholderId: widget.placeholder.id,
        targetId: widget.target.id,
        displayName: name,
        nick: _nick.text.trim(),
        clubId: _clubId,
      ),
      success: 'Hráči sloučeni.',
      errorText: friendlyDbError,
    );
    return ok ? true : null;
  }

  /// Both sides filled and different — the only case worth a chooser.
  bool _differ(String account, String placeholder) =>
      account.isNotEmpty && placeholder.isNotEmpty && account != placeholder;

  /// The side whose value the field currently holds verbatim (null after
  /// a manual edit — neither radio applies any more).
  _Side? _sideOf(String current, String account, String placeholder) {
    if (current == account) return _Side.account;
    if (current == placeholder) return _Side.placeholder;
    return null;
  }

  Widget _chooser({
    required String label,
    required String accountValue,
    required String placeholderValue,
    required _Side? selected,
    required ValueChanged<_Side> onPick,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: Theme.of(context).textTheme.titleSmall),
        RadioGroup<_Side>(
          groupValue: selected,
          onChanged: (side) {
            if (side != null) onPick(side);
          },
          child: Column(
            children: [
              RadioListTile<_Side>(
                value: _Side.account,
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: Text(accountValue),
                subtitle: const Text('z účtu'),
              ),
              RadioListTile<_Side>(
                value: _Side.placeholder,
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: Text(placeholderValue),
                subtitle: const Text('od hráče bez účtu'),
              ),
            ],
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final account = widget.target;
    final placeholder = widget.placeholder;
    final theme = Theme.of(context);
    final accountClub = _accountClub;
    final placeholderClub = _placeholderClub;
    final accountLabel =
        account.email.isEmpty ? account.displayName : account.email;
    final approval =
        account.status == ProfileStatus.pending ? ' a bude schválen' : '';

    return FormDialog<bool>(
      title: 'Sloučit hráče',
      saveLabel: 'Sloučit',
      savingLabel: 'Slučuji…',
      onSave: _save,
      children: [
        Text(
          'Účet $accountLabel převezme rezervace hráče bez účtu '
          '„${placeholder.displayName}“$approval. '
          'Vyber, které údaje zůstanou:',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 12),
        if (_differ(account.displayName, placeholder.displayName))
          _chooser(
            label: 'Jméno',
            accountValue: account.displayName,
            placeholderValue: placeholder.displayName,
            selected: _sideOf(
              _name.text,
              account.displayName,
              placeholder.displayName,
            ),
            onPick: (side) => setState(() {
              _name.text = side == _Side.account
                  ? account.displayName
                  : placeholder.displayName;
            }),
          ),
        TextField(
          controller: _name,
          textCapitalization: TextCapitalization.words,
          decoration: const InputDecoration(labelText: 'Jméno a příjmení'),
          onChanged: (_) => setState(() {}),
        ),
        const SizedBox(height: 12),
        if (_differ(account.nick, placeholder.nick))
          _chooser(
            label: 'Přezdívka',
            accountValue: account.nick,
            placeholderValue: placeholder.nick,
            selected: _sideOf(_nick.text, account.nick, placeholder.nick),
            onPick: (side) => setState(() {
              _nick.text =
                  side == _Side.account ? account.nick : placeholder.nick;
            }),
          ),
        TextField(
          controller: _nick,
          maxLength: Limits.nickLength,
          decoration: const InputDecoration(
            labelText: 'Přezdívka na tabuli (nepovinné)',
            counterText: '',
          ),
          onChanged: (_) => setState(() {}),
        ),
        if (widget.clubs.isNotEmpty) ...[
          const SizedBox(height: 12),
          if (accountClub != null &&
              placeholderClub != null &&
              accountClub != placeholderClub)
            _chooser(
              label: 'Oddíl',
              accountValue: clubNameOf(accountClub, widget.clubs),
              placeholderValue: clubNameOf(placeholderClub, widget.clubs),
              selected: _clubId == accountClub
                  ? _Side.account
                  : _clubId == placeholderClub
                      ? _Side.placeholder
                      : null,
              onPick: (side) => setState(() {
                _clubId =
                    side == _Side.account ? accountClub : placeholderClub;
              }),
            ),
          // Keyed on the value: the dropdown only reads initialValue on its
          // first build, so a radio pick has to rebuild it to show.
          DropdownButtonFormField<String?>(
            key: ValueKey(_clubId),
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
