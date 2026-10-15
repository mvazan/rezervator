/// Napište nám — a message to the app's author: what is missing, what does
/// not work. Sent as Sentry user feedback (the project the error reports
/// already go to), so it arrives with the build, the platform and the
/// device; nothing is stored in Supabase. Opened from Klubovna (signed in:
/// name, e-mail and kuželna filled in) and, with no sign-in, from the web
/// route `#/napiste-nam` — where the kiosk's QR code leads (`?z=kiosk`), as
/// typing on a 32" touch screen is no way to write a message.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sentry_flutter/sentry_flutter.dart';

/// Where a message was written from — its `source` tag in Sentry.
enum FeedbackSource {
  /// Klubovna's tile, signed in.
  clubhouse,

  /// The kiosk's QR code (`#/napiste-nam?z=kiosk`).
  kiosk,

  /// The web route without the kiosk's mark — a link someone shared.
  link,
}

/// The web route's `z` parameter as a [FeedbackSource]: `kiosk` is the
/// kiosk's code, anything else a plain link — the route never claims to
/// be Klubovna.
FeedbackSource feedbackSourceFromQuery(String? z) =>
    z == FeedbackSource.kiosk.name ? FeedbackSource.kiosk : FeedbackSource.link;

/// Sentry caps a feedback message at 4096 characters (it cuts the rest).
const feedbackMaxLength = 4000;

/// One message as the form hands it over: trimmed, an empty name or e-mail
/// null.
class FeedbackMessage {
  const FeedbackMessage({
    required this.message,
    required this.source,
    this.name,
    this.email,
    this.tenantId,
  });

  final String message;
  final FeedbackSource source;
  final String? name;
  final String? email;

  /// The signed-in player's kuželna; null on the web route.
  final String? tenantId;
}

/// Sends a [FeedbackMessage]; false when it could not.
typedef FeedbackSender = Future<bool> Function(FeedbackMessage message);

/// The real sender; tests put their own in.
final feedbackSenderProvider = Provider<FeedbackSender>(
  (ref) => sendFeedbackToSentry,
);

/// [message] as Sentry user feedback, tagged with its source and kuželna.
/// False without Sentry (a build with no DSN) or when the SDK throws. True
/// means handed to the SDK: on Android it keeps an envelope it could not
/// send for later, the web's goes once.
Future<bool> sendFeedbackToSentry(FeedbackMessage message) async {
  if (!Sentry.isEnabled) return false;
  try {
    await Sentry.captureFeedback(
      SentryFeedback(
        message: message.message,
        name: message.name,
        contactEmail: message.email,
      ),
      withScope: (scope) async {
        await scope.setTag('source', message.source.name);
        final tenant = message.tenantId;
        if (tenant != null && tenant.isNotEmpty) {
          await scope.setTag('tenant', tenant);
        }
      },
    );
    return true;
  } catch (e) {
    debugPrint('Feedback: send failed: $e');
    return false;
  }
}

/// A loose check — something@something.something — to catch a name typed
/// into the e-mail field, not to judge an address.
final _emailShape = RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$');

class FeedbackScreen extends ConsumerStatefulWidget {
  const FeedbackScreen({
    super.key,
    required this.source,
    this.initialName,
    this.initialEmail,
    this.tenantId,
  });

  final FeedbackSource source;
  final String? initialName;
  final String? initialEmail;
  final String? tenantId;

  @override
  ConsumerState<FeedbackScreen> createState() => _FeedbackScreenState();
}

class _FeedbackScreenState extends ConsumerState<FeedbackScreen> {
  final _message = TextEditingController();
  late final _name = TextEditingController(text: widget.initialName ?? '');
  late final _email = TextEditingController(text: widget.initialEmail ?? '');

  String? _messageError;
  String? _emailError;
  bool _sending = false;
  bool _failed = false;

  /// The last message went through: the thanks instead of the form.
  bool _sent = false;

  /// The e-mail that message went with; null = none, no reply promised.
  String? _sentTo;

  @override
  void dispose() {
    _message.dispose();
    _name.dispose();
    _email.dispose();
    super.dispose();
  }

  String? _orNull(String text) {
    final t = text.trim();
    return t.isEmpty ? null : t;
  }

  Future<void> _send() async {
    if (_sending) return;
    final message = _message.text.trim();
    final email = _orNull(_email.text);
    setState(() {
      _messageError = message.isEmpty ? 'Napiš, co nám chceš vzkázat.' : null;
      _emailError = email != null && !_emailShape.hasMatch(email)
          ? 'Tohle nevypadá jako e-mail.'
          : null;
      _failed = false;
    });
    if (_messageError != null || _emailError != null) return;
    setState(() => _sending = true);
    final ok = await ref.read(feedbackSenderProvider)(
      FeedbackMessage(
        message: message,
        source: widget.source,
        name: _orNull(_name.text),
        email: email,
        tenantId: widget.tenantId,
      ),
    );
    if (!mounted) return;
    setState(() {
      _sending = false;
      _failed = !ok;
      _sent = ok;
      _sentTo = ok ? email : null;
      if (ok) _message.clear();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Napište nám')),
      body: SafeArea(
        child: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 600),
            child: _sent ? _thanks(context) : _form(context),
          ),
        ),
      ),
    );
  }

  Widget _form(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const Text(
          'Co ti v Rezervátoru chybí, co nefunguje nebo co by šlo udělat '
          'líp? Zprávu čte autor aplikace.',
        ),
        const SizedBox(height: 16),
        TextField(
          controller: _message,
          minLines: 5,
          maxLines: 12,
          maxLength: feedbackMaxLength,
          textCapitalization: TextCapitalization.sentences,
          decoration: InputDecoration(
            labelText: 'Zpráva',
            alignLabelWithHint: true,
            border: const OutlineInputBorder(),
            errorText: _messageError,
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _name,
          textCapitalization: TextCapitalization.words,
          decoration: const InputDecoration(
            labelText: 'Jméno (nepovinné)',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _email,
          keyboardType: TextInputType.emailAddress,
          autocorrect: false,
          decoration: InputDecoration(
            labelText: 'E-mail pro odpověď (nepovinné)',
            helperText: 'Jen když chceš, abychom ti odpověděli.',
            border: const OutlineInputBorder(),
            errorText: _emailError,
          ),
        ),
        if (_failed) ...[
          const SizedBox(height: 12),
          Text(
            'Zprávu se nepodařilo odeslat. Zkus to prosím později.',
            style: TextStyle(color: scheme.error),
          ),
        ],
        const SizedBox(height: 16),
        Align(
          alignment: Alignment.centerRight,
          child: FilledButton.icon(
            onPressed: _sending ? null : _send,
            icon: _sending
                ? const SizedBox.square(
                    dimension: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.send),
            label: const Text('Odeslat'),
          ),
        ),
      ],
    );
  }

  Widget _thanks(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final to = _sentTo;
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Icon(Icons.check_circle_outline, size: 56, color: scheme.primary),
        const SizedBox(height: 12),
        Text(
          'Díky, zpráva odešla.',
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.titleLarge,
        ),
        if (to != null) ...[
          const SizedBox(height: 8),
          Text('Na $to ti můžeme odpovědět.', textAlign: TextAlign.center),
        ],
        const SizedBox(height: 24),
        Center(
          child: OutlinedButton(
            onPressed: () => setState(() {
              _sent = false;
              _sentTo = null;
            }),
            child: const Text('Napsat další zprávu'),
          ),
        ),
      ],
    );
  }
}
