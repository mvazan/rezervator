import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/ui.dart';
import '../../../data/providers.dart';
import '../../../domain/collation.dart';
import '../../../domain/models.dart';

/// Google Calendar link on Můj profil: connect (opens Google's consent page
/// in the browser), show the current state, edit reminders, pick the teams
/// whose matches go to the calendar, or disconnect.
/// Nothing comes back into the app via a deep link — the backend writes the
/// result and this card flips on its own through the live stream.
class CalendarLinkCard extends ConsumerStatefulWidget {
  const CalendarLinkCard({
    super.key,
    this.consentUrl = Api.calendarConsentUrl,
    this.openUrl = launchWeb,
    this.disconnect = Api.disconnectCalendar,
    this.setReminders = Api.setCalendarReminders,
    this.setMatchTeams = Api.setCalendarMatchTeams,
  });

  /// The backend calls and the browser launch, injectable for widget tests
  /// (the Api ones need a live Supabase client).
  final Future<Uri> Function() consentUrl;
  final void Function(String url) openUrl;
  final Future<bool> Function() disconnect;
  final Future<void> Function(List<int> minutes) setReminders;
  final Future<void> Function(List<String> teams) setMatchTeams;

  @override
  ConsumerState<CalendarLinkCard> createState() => _CalendarLinkCardState();
}

class _CalendarLinkCardState extends ConsumerState<CalendarLinkCard> {
  bool _busy = false;

  Future<void> _connect() async {
    setState(() => _busy = true);
    try {
      final url = await widget.consentUrl();
      if (!mounted) return;
      widget.openUrl(url.toString());
      snack(context, 'Dokonči propojení v prohlížeči a vrať se sem.');
    } catch (e) {
      if (mounted) snack(context, 'Propojení se nepovedlo: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _disconnect() async {
    final ok = await confirmDialog(
      context,
      title: 'Odpojit kalendář?',
      message: 'Kalendář „Rezervátor" se z Googlu smaže i s tréninky. '
          'Propojení jde kdykoli obnovit.',
      confirmLabel: 'Odpojit a smazat',
    );
    if (!ok || !mounted) return;
    setState(() => _busy = true);
    try {
      // Waits on purpose: until the disconnect finishes, the card must not
      // offer a new link — that race would leave an orphaned calendar.
      final orphaned = await widget.disconnect();
      if (mounted) {
        snack(
          context,
          orphaned
              ? 'Odpojeno. Přístup byl odvolaný už dřív, takže kalendář '
                  '„Rezervátor" v Googlu zůstal — smaž si ho tam sám(a).'
              : 'Kalendář odpojen a smazán.',
        );
      }
    } catch (_) {
      if (mounted) {
        snack(
            context,
            'Odpojení se nepovedlo, nic se nezměnilo. '
            'Zkus to prosím znovu.');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Reminder editor: a live list of "N hodin/dní předem" entries with
  /// add/remove, mirroring Google Calendar's own model (max 5, max 4 weeks).
  /// Every change is saved immediately — the sheet watches the same stream
  /// as the card, so it redraws itself when the row lands.
  Future<void> _editReminders() {
    return showModalBottomSheet<void>(
      context: context,
      builder: (sheetContext) => Consumer(
        builder: (context, ref, _) {
          final link =
              ref.watch(myCalendarLinkProvider).value ?? CalendarLink.none;
          final minutes = link.reminderMinutes;
          return SafeArea(
            child: ListView(
              shrinkWrap: true,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
                  child: Text('Připomínky tréninků v kalendáři',
                      style: Theme.of(context).textTheme.titleMedium),
                ),
                if (minutes.isEmpty)
                  const ListTile(
                    leading: Icon(Icons.notifications_off_outlined),
                    title: Text('Žádné připomínky'),
                    subtitle:
                        Text('Tréninky se přidávají tiše, bez upozornění.'),
                  ),
                for (final m in minutes)
                  ListTile(
                    leading: const Icon(Icons.notifications_none_outlined),
                    title: Text(reminderOffsetLabel(m)),
                    trailing: IconButton(
                      tooltip: 'Odebrat',
                      icon: const Icon(Icons.close),
                      onPressed: () => tryAction(
                          context,
                          () => widget.setReminders(
                              [for (final x in minutes) if (x != m) x])),
                    ),
                  ),
                if (minutes.length < maxCalendarReminders)
                  ListTile(
                    leading: const Icon(Icons.add),
                    title: const Text('Přidat připomínku'),
                    onTap: () => _addReminder(context, minutes),
                  ),
                const SizedBox(height: 8),
              ],
            ),
          );
        },
      ),
    );
  }

  /// "Number + unit" dialog; converts to minutes and saves.
  Future<void> _addReminder(BuildContext context, List<int> current) async {
    final minutes = await showDialog<int>(
      context: context,
      builder: (_) => const _ReminderDialog(),
    );
    if (minutes == null || !context.mounted) return;
    if (minutes > maxReminderMinutes) {
      snack(context, 'Nejdál to jde 4 týdny (28 dní) předem.');
      return;
    }
    await tryAction(
        context, () => widget.setReminders([...current, minutes]));
  }

  /// Team picker: every team the schedule knows (home team of a home match,
  /// away team of an away match) plus whatever is already chosen, so a team
  /// that vanished from the schedule can still be unticked. Each toggle is
  /// saved at once — the sheet watches the same stream as the card.
  Future<void> _editMatchTeams() {
    return showModalBottomSheet<void>(
      context: context,
      builder: (sheetContext) => Consumer(
        builder: (context, ref, _) {
          final link =
              ref.watch(myCalendarLinkProvider).value ?? CalendarLink.none;
          final chosen = link.matchTeams;
          final teams = {...ref.watch(ourTeamsProvider), ...chosen}.toList()
            ..sort(compareCzech);
          return SafeArea(
            child: ListView(
              shrinkWrap: true,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
                  child: Text('Zápasy v kalendáři',
                      style: Theme.of(context).textTheme.titleMedium),
                ),
                const Padding(
                  padding: EdgeInsets.fromLTRB(16, 0, 16, 8),
                  child: Text('Vyber svůj tým — jeho domácí i venkovní zápasy '
                      'se přidají do kalendáře.'),
                ),
                if (teams.isEmpty)
                  const ListTile(
                    leading: Icon(Icons.sports_outlined),
                    title: Text('Zatím žádné zápasy v rozvrhu'),
                  ),
                for (final team in teams)
                  CheckboxListTile(
                    value: chosen.contains(team),
                    title: Text(team),
                    onChanged: (on) => tryAction(
                      context,
                      () => widget.setMatchTeams([
                        for (final t in chosen)
                          if (t != team) t,
                        if (on == true) team,
                      ]),
                    ),
                  ),
                const SizedBox(height: 8),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _connectButton() => Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
        child: Align(
          alignment: Alignment.centerLeft,
          child: FilledButton.tonalIcon(
            onPressed: _busy ? null : _connect,
            icon: _busy ? const _Spinner() : const Icon(Icons.link),
            label: const Text('Propojit s Google kalendářem'),
          ),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final link = ref.watch(myCalendarLinkProvider).value ?? CalendarLink.none;
    // Locals, not fields: the switch arms below close over them.
    final email = link.googleEmail;
    final error = link.lastError;

    final rows = switch (link.status) {
      CalendarLinkStatus.linked => [
          ListTile(
            leading: const Icon(Icons.event_available_outlined),
            title: const Text('Google kalendář'),
            subtitle: Text(email == null
                ? 'Propojeno — tréninky se přidávají samy.'
                : 'Propojeno jako $email.'),
            trailing: _busy
                ? const _Spinner()
                : TextButton(
                    onPressed: _disconnect, child: const Text('Odpojit')),
          ),
          ListTile(
            leading: const Icon(Icons.notifications_none_outlined),
            title: const Text('Připomínky…'),
            subtitle: Text(remindersSummary(link.reminderMinutes)),
            trailing: const Icon(Icons.chevron_right),
            onTap: _editReminders,
          ),
          ListTile(
            leading: const Icon(Icons.sports_outlined),
            title: const Text('Zápasy v kalendáři…'),
            subtitle: Text(matchTeamsSummary(link.matchTeams)),
            trailing: const Icon(Icons.chevron_right),
            onTap: _editMatchTeams,
          ),
        ],
      // Google said yes; the backend is creating the calendar. The retry
      // stays on offer so a callback that died half-way is no dead end.
      CalendarLinkStatus.pending => [
          ListTile(
            leading: const Icon(Icons.event_outlined),
            title: const Text('Google kalendář'),
            subtitle: Text(error ?? 'Propojuji…'),
            trailing: _busy
                ? const _Spinner()
                : TextButton(
                    onPressed: _connect, child: const Text('Zkusit znovu')),
          ),
        ],
      CalendarLinkStatus.broken => [
          ListTile(
            leading: Icon(Icons.event_busy_outlined,
                color: Theme.of(context).colorScheme.error),
            title: const Text('Google kalendář'),
            subtitle: Text(error == null
                ? 'Propojení se přerušilo. Propoj ho prosím znovu.'
                : '$error Propoj ho prosím znovu.'),
            isThreeLine: true,
          ),
          _connectButton(),
        ],
      CalendarLinkStatus.notLinked => [
          const ListTile(
            leading: Icon(Icons.event_outlined),
            title: Text('Google kalendář'),
            subtitle: Text(
                'Tvoje tréninky se budou samy přidávat do kalendáře '
                '„Rezervátor" ve tvém Google účtu.'),
            isThreeLine: true,
          ),
          _connectButton(),
        ],
    };
    return Card(child: Column(children: rows));
  }
}

/// "Kolik" + hodiny/dny; pops with the offset in minutes (never with zero
/// or garbage — the button just waits for a real number). Owns its text
/// controller, so the exit animation can still rebuild the field safely.
class _ReminderDialog extends StatefulWidget {
  const _ReminderDialog();

  @override
  State<_ReminderDialog> createState() => _ReminderDialogState();
}

class _ReminderDialogState extends State<_ReminderDialog> {
  final _amount = TextEditingController();
  var _unit = _ReminderUnit.hours;

  @override
  void dispose() {
    _amount.dispose();
    super.dispose();
  }

  void _submit() {
    final n = int.tryParse(_amount.text.trim());
    if (n == null || n <= 0) return;
    Navigator.pop(context, n * _unit.inMinutes);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Připomínka předem'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _amount,
            autofocus: true,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(labelText: 'Kolik'),
            onSubmitted: (_) => _submit(),
          ),
          const SizedBox(height: 12),
          SegmentedButton<_ReminderUnit>(
            segments: [
              for (final u in _ReminderUnit.values)
                ButtonSegment(value: u, label: Text(u.label)),
            ],
            selected: {_unit},
            onSelectionChanged: (s) => setState(() => _unit = s.first),
          ),
        ],
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Zrušit')),
        FilledButton(onPressed: _submit, child: const Text('Přidat')),
      ],
    );
  }
}

/// Units for the "reminder ahead" dialog, converted to minutes on save.
/// Deliberately no minutes — for a training nobody sets "37 minut předem",
/// and two units keep the dialog one glance wide.
enum _ReminderUnit {
  hours('hodiny', 60),
  days('dny', 1440);

  const _ReminderUnit(this.label, this.inMinutes);

  final String label;
  final int inMinutes;
}

class _Spinner extends StatelessWidget {
  const _Spinner();

  @override
  Widget build(BuildContext context) => const SizedBox(
        width: 20,
        height: 20,
        child: CircularProgressIndicator(strokeWidth: 2),
      );
}
