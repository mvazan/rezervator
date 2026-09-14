import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/ui.dart';
import '../../../data/providers.dart';
import '../../../domain/models.dart';
import 'event_color_picker.dart';
import 'reminders_sheet.dart';

/// What the player has to clean up by hand after a disconnect: Google
/// refused to delete these calendars (the grant was already revoked, or the
/// DELETE itself came back 401), and the revoke that follows puts them out
/// of the app's reach for good — so they are named, and the message says
/// only what is certain. It deliberately does NOT guess at a cause: the
/// grant may have been revoked earlier, or the token may have died between
/// the refresh and the delete, and the player can act on neither.
String _orphanedText(List<CalendarSlot> orphaned) {
  final names = [
    for (final slot in orphaned)
      slot == CalendarSlot.secondary ? '„Rezervátor 2"' : '„Rezervátor"',
  ];
  return names.length == 1
      ? 'Odpojeno, ale kalendář ${names.single} v Googlu zůstal — smazat '
            'se ho nepodařilo, smaž si ho tam prosím sám(a).'
      : 'Odpojeno, ale kalendáře ${names.join(' a ')} v Googlu zůstaly — '
            'smazat se je nepodařilo, smaž si je tam prosím sám(a).';
}

/// Google Calendar link on Můj profil: connect (opens Google's consent page
/// in the browser), show the current state, edit reminders, turn the second
/// calendar on/off, set the trainings' own colour, or disconnect. WHICH
/// teams go to the calendar is not here: that is one of the three boxes a
/// team has in Moje týmy (`my_teams_sheet.dart`), where it sits beside the
/// two the calendar knows nothing about.
/// Nothing comes back into the app via a deep link — the backend writes the
/// result and this card flips on its own through the live stream.
class CalendarLinkCard extends ConsumerStatefulWidget {
  const CalendarLinkCard({
    super.key,
    this.consentUrl = Api.calendarConsentUrl,
    this.openUrl = launchWeb,
    this.disconnect = Api.disconnectCalendar,
    this.setReminders = Api.setCalendarReminders,
    this.setSecondaryCalendar = Api.setSecondaryCalendar,
    this.setTrainingColor = Api.setTrainingColor,
  });

  /// The backend calls and the browser launch, injectable for widget tests
  /// (the Api ones need a live Supabase client).
  final Future<Uri> Function() consentUrl;
  final void Function(String url) openUrl;
  final Future<List<CalendarSlot>> Function() disconnect;
  final Future<void> Function(List<int> minutes, {CalendarSlot calendar})
  setReminders;
  final Future<bool> Function(bool enabled) setSecondaryCalendar;
  final Future<void> Function(int? colorId) setTrainingColor;

  @override
  ConsumerState<CalendarLinkCard> createState() => _CalendarLinkCardState();
}

class _CalendarLinkCardState extends ConsumerState<CalendarLinkCard> {
  bool _busy = false;

  /// Separate from [_busy]: turning the second calendar on/off must disable
  /// just the switch while it settles, not swap the header row's own
  /// Odpojit button for a spinner too.
  bool _secondaryBusy = false;

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
    final link = ref.read(myCalendarLinkProvider).value ?? CalendarLink.none;
    final ok = await confirmDialog(
      context,
      title: 'Odpojit kalendář?',
      message: link.secondaryEnabled
          ? 'Kalendáře „Rezervátor" i „Rezervátor 2" se z Googlu smažou '
                'i s tréninky a zápasy. Propojení jde kdykoli obnovit.'
          : 'Kalendář „Rezervátor" se z Googlu smaže i s tréninky. '
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
          orphaned.isEmpty
              ? 'Kalendář odpojen a smazán.'
              : _orphanedText(orphaned),
        );
      }
    } catch (_) {
      if (mounted) {
        snack(
          context,
          'Odpojení se nepovedlo, nic se nezměnilo. '
          'Zkus to prosím znovu.',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Turns the second Google calendar on or off. Off is destructive — it
  /// deletes "Rezervátor 2" in Google along with its events and moves its
  /// teams back to primary — so, like disconnect, it asks first. Either way
  /// this waits for the call: the switch must not offer another tap (and
  /// the teams sheet must not offer "Druhý" again) before the backend
  /// settles, the same reasoning `Api.setSecondaryCalendar`'s doc comment
  /// spells out.
  Future<void> _setSecondaryCalendar(bool enabled) async {
    if (!enabled) {
      final ok = await confirmDialog(
        context,
        title: 'Vypnout druhý kalendář?',
        message:
            'Kalendář „Rezervátor 2" se z Googlu smaže i se zápasy. '
            'Týmy, které do něj patřily, se přesunou do hlavního kalendáře.',
        confirmLabel: 'Vypnout a smazat',
      );
      if (!ok || !mounted) return;
    }
    setState(() => _secondaryBusy = true);
    try {
      // The backend deletes "Rezervátor 2" before it answers, and tells us
      // when Google would not let it — exactly like a disconnect. Dropping
      // that on the floor would leave the player with a calendar they can
      // no longer reach from the app and no idea it is there.
      var orphaned = false;
      final ok = await tryAction(
        context,
        () async => orphaned = await widget.setSecondaryCalendar(enabled),
        errorText: friendlyDbError,
      );
      if (ok && orphaned && mounted) {
        snack(
          context,
          'Druhý kalendář je vypnutý, ale „Rezervátor 2" v Googlu zůstal '
          '— smazat se ho nepodařilo, smaž si ho tam prosím sám(a).',
        );
      }
    } finally {
      if (mounted) setState(() => _secondaryBusy = false);
    }
  }

  /// Reminder editor for [calendar]: a live list of "N hodin/dní předem"
  /// entries with add/remove, mirroring Google Calendar's own model (max 5,
  /// max 4 weeks). Every change is saved immediately — the sheet watches the
  /// same stream as the card, so it redraws itself when the row lands. The
  /// list itself is shared with Můj profil's own reminders (0040).
  Future<void> _editReminders(CalendarSlot calendar) {
    final link = ref.read(myCalendarLinkProvider).value ?? CalendarLink.none;
    // The second calendar never carries trainings (those always stay on
    // primary, per the design), so its empty state talks about matches
    // instead — and while there is only one calendar, the title stays
    // exactly what it always was.
    final title = !link.secondaryEnabled
        ? 'Připomínky tréninků v kalendáři'
        : (calendar == CalendarSlot.secondary
            ? 'Připomínky druhého kalendáře'
            : 'Připomínky hlavního kalendáře');
    return showRemindersSheet(
      context,
      title: title,
      emptyCopy: calendar == CalendarSlot.secondary
          ? 'Zápasy se přidávají tiše, bez upozornění.'
          : 'Tréninky se přidávají tiše, bez upozornění.',
      minutesOf: (ref) {
        final live = ref.watch(myCalendarLinkProvider).value ?? CalendarLink.none;
        return calendar == CalendarSlot.secondary
            ? live.reminderMinutesSecondary
            : live.reminderMinutes;
      },
      onChanged: (minutes) => widget.setReminders(minutes, calendar: calendar),
    );
  }

  Future<void> _editTrainingColor() async {
    final link = ref.read(myCalendarLinkProvider).value ?? CalendarLink.none;
    final picked = await pickEventColor(
      context,
      current: link.trainingColorId,
      title: 'Barva tréninků',
    );
    if (!mounted || picked == link.trainingColorId) return;
    await tryAction(
      context,
      () => widget.setTrainingColor(picked),
      errorText: friendlyDbError,
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
          subtitle: Text(
            email == null
                ? 'Propojeno — tréninky se přidávají samy.'
                : 'Propojeno jako $email.',
          ),
          trailing: _busy
              ? const _Spinner()
              : TextButton(
                  onPressed: _disconnect,
                  child: const Text('Odpojit'),
                ),
        ),
        SwitchListTile(
          title: const Text('Druhý kalendář'),
          subtitle: const Text(
            'Založí v Googlu kalendář „Rezervátor 2". V Moje týmy pak '
            'podržíš tým a vybereš, do kterého kalendáře jeho zápasy patří.',
          ),
          value: link.secondaryEnabled,
          onChanged: _secondaryBusy
              ? null
              : (enabled) => _setSecondaryCalendar(enabled),
        ),
        if (link.secondaryEnabled) ...[
          ListTile(
            leading: const Icon(Icons.notifications_none_outlined),
            title: const Text('Připomínky hlavního kalendáře…'),
            subtitle: Text(remindersSummary(link.reminderMinutes)),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _editReminders(CalendarSlot.primary),
          ),
          ListTile(
            leading: const Icon(Icons.notifications_none_outlined),
            title: const Text('Připomínky druhého kalendáře…'),
            subtitle: Text(remindersSummary(link.reminderMinutesSecondary)),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _editReminders(CalendarSlot.secondary),
          ),
        ] else
          ListTile(
            leading: const Icon(Icons.notifications_none_outlined),
            title: const Text('Připomínky…'),
            subtitle: Text(remindersSummary(link.reminderMinutes)),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _editReminders(CalendarSlot.primary),
          ),
        ListTile(
          leading: EventColorDot(colorId: link.trainingColorId),
          title: const Text('Barva tréninků'),
          subtitle: Text(eventColorName(link.trainingColorId)),
          trailing: const Icon(Icons.chevron_right),
          onTap: _editTrainingColor,
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
                  onPressed: _connect,
                  child: const Text('Zkusit znovu'),
                ),
        ),
      ],
      CalendarLinkStatus.broken => [
        ListTile(
          leading: Icon(
            Icons.event_busy_outlined,
            color: Theme.of(context).colorScheme.error,
          ),
          title: const Text('Google kalendář'),
          subtitle: Text(
            error == null
                ? 'Propojení se přerušilo. Propoj ho prosím znovu.'
                : '$error Propoj ho prosím znovu.',
          ),
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
            '„Rezervátor" ve tvém Google účtu.',
          ),
          isThreeLine: true,
        ),
        _connectButton(),
      ],
    };
    return Card(child: Column(children: rows));
  }
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
