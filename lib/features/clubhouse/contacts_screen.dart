/// Klubovna → Kontakty (0048): the alley's registered players with the
/// e-mail and phone each of them chose to show — write, call or WhatsApp
/// straight from the row. Czech-sorted, searchable.
library;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/ui.dart';
import '../../data/providers.dart';
import '../../domain/contacts.dart';
import '../../domain/models.dart';
import '../../domain/phone.dart';
import '../admin/widgets/form_fields.dart' show ColorDot;
import '../profile/profile_screen.dart';

Widget _profilePage(BuildContext _) => const ProfileScreen();

class ContactsScreen extends ConsumerStatefulWidget {
  const ContactsScreen({
    super.key,
    this.sendEmail = launchEmail,
    this.callPhone = launchPhone,
    this.openUrl = launchWeb,
    this.profilePage = _profilePage,
  });

  /// Injectable so widget tests never reach the platform.
  final void Function(String address) sendEmail;
  final void Function(String number) callPhone;
  final void Function(String url) openUrl;

  /// What „Můj profil" in the note opens — the same screen as the shell's
  /// profile icon; a test swaps in a stand-in.
  final WidgetBuilder profilePage;

  @override
  ConsumerState<ContactsScreen> createState() => _ContactsScreenState();
}

class _ContactsScreenState extends ConsumerState<ContactsScreen> {
  String _query = '';
  late final _profileLink = TapGestureRecognizer()..onTap = _openProfile;

  @override
  void dispose() {
    _profileLink.dispose();
    super.dispose();
  }

  Future<void> _openProfile() async {
    await Navigator.of(context)
        .push(MaterialPageRoute<void>(builder: widget.profilePage));
    // A switch just flipped there shows here at once.
    if (mounted) ref.invalidate(contactsProvider);
  }

  Future<void> _refresh() async {
    try {
      ref.invalidate(contactsProvider);
      await ref.read(contactsProvider.future);
    } catch (e) {
      if (mounted) snack(context, friendlyDbError(e));
    }
  }

  Widget _note(ThemeData theme) {
    final scheme = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.info_outline, size: 18, color: scheme.onSurfaceVariant),
          const SizedBox(width: 8),
          Expanded(
            child: Text.rich(
              TextSpan(
                children: [
                  const TextSpan(
                    text: 'Svůj e-mail a telefon můžeš v Kontaktech skrýt v ',
                  ),
                  TextSpan(
                    text: 'Můj profil',
                    style: TextStyle(
                      color: scheme.primary,
                      decoration: TextDecoration.underline,
                    ),
                    recognizer: _profileLink,
                  ),
                  const TextSpan(text: ' → Kontakt.'),
                ],
              ),
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ),
        ],
      ),
    );
  }

  Widget _row(ThemeData theme, Contact contact) {
    final subtitle = [
      if (contact.nick.isNotEmpty) '„${contact.nick}“',
      ?contact.clubName,
    ].join(' · ');
    final email = contact.email;
    final phone = contact.phone;
    return ListTile(
      leading: ColorDot(colorIndex: contact.clubColor),
      title: Text(contact.displayName),
      subtitle: subtitle.isEmpty ? null : Text(subtitle),
      trailing: email == null && phone == null
          ? Text(
              'kontakt skrytý',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            )
          : Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (email != null)
                  IconButton(
                    icon: const Icon(Icons.mail_outline),
                    tooltip: 'Napsat e-mail',
                    visualDensity: VisualDensity.compact,
                    onPressed: () => widget.sendEmail(email),
                  ),
                if (phone != null) ...[
                  IconButton(
                    icon: const Icon(Icons.phone_outlined),
                    tooltip: 'Zavolat',
                    visualDensity: VisualDensity.compact,
                    onPressed: () => widget.callPhone(phone),
                  ),
                  IconButton(
                    icon: const Icon(Icons.chat_outlined),
                    tooltip: 'WhatsApp',
                    visualDensity: VisualDensity.compact,
                    onPressed: () =>
                        widget.openUrl(whatsappUri(phone).toString()),
                  ),
                ],
              ],
            ),
    );
  }

  Widget _centered(String text) => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(text, textAlign: TextAlign.center),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final contactsAsync = ref.watch(contactsProvider);

    Widget body;
    if (contactsAsync.hasError && !contactsAsync.hasValue) {
      body = Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                friendlyDbError(contactsAsync.error!),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 12),
              OutlinedButton(
                onPressed: () => ref.invalidate(contactsProvider),
                child: const Text('Zkusit znovu'),
              ),
            ],
          ),
        ),
      );
    } else if (!contactsAsync.hasValue) {
      body = const Center(child: CircularProgressIndicator());
    } else {
      final all = contactsAsync.value!;
      final shown = contactsMatching(all, _query);
      body = RefreshIndicator(
        onRefresh: _refresh,
        child: all.isEmpty
            ? ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                children: [_centered('Zatím tu nikdo není.')],
              )
            : shown.isEmpty
                ? ListView(
                    physics: const AlwaysScrollableScrollPhysics(),
                    children: [_centered('Nikdo takový tu není.')],
                  )
                : ListView.builder(
                    key: const Key('contacts-list'),
                    physics: const AlwaysScrollableScrollPhysics(),
                    padding: const EdgeInsets.only(bottom: 24),
                    itemCount: shown.length,
                    itemBuilder: (context, i) => _row(theme, shown[i]),
                  ),
      );
    }

    return Scaffold(
      appBar: AppBar(title: const Text('Kontakty')),
      body: Column(
        children: [
          _note(theme),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
            child: TextField(
              decoration: const InputDecoration(
                hintText: 'Hledat jméno, přezdívku nebo oddíl',
                prefixIcon: Icon(Icons.search),
              ),
              onChanged: (v) => setState(() => _query = v),
            ),
          ),
          Expanded(child: body),
        ],
      ),
    );
  }
}
