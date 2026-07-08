import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../config.dart';
import '../../core/ui.dart';
import '../../core/widgets/auth_background.dart';
import '../../data/providers.dart';

class LoginScreen extends ConsumerStatefulWidget {
  const LoginScreen({super.key});

  @override
  ConsumerState<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends ConsumerState<LoginScreen> {
  final _email = TextEditingController();
  bool _sending = false;
  bool _sent = false;

  /// Magic-link failure (expired/used link, PKCE mismatch…). supabase_flutter
  /// reports these as errors on the onAuthStateChange stream — without
  /// surfacing them the user just lands back on this screen with no clue.
  String? _authError;

  @override
  void initState() {
    super.initState();
    // A failed deep link may have errored before this screen was built
    // (cold start straight from the e-mail link).
    final auth = ref.read(authStateProvider);
    if (auth.hasError) _authError = _friendlyAuthError(auth.error!);
  }

  @override
  void dispose() {
    _email.dispose();
    super.dispose();
  }

  static String _friendlyAuthError(Object error) {
    final raw = error is AuthException
        ? [error.code, error.message].whereType<String>().join(': ')
        : '$error';
    final lower = raw.toLowerCase();
    if (lower.contains('expired') || lower.contains('invalid')) {
      return 'Odkaz už neplatí — byl použit, vypršel, nebo je ze staršího '
          'e-mailu. Pošli si nový a klikni na odkaz v nejnovějším e-mailu.'
          '\n($raw)';
    }
    if (lower.contains('flow') || lower.contains('verifier')) {
      return 'Odkaz je ze staršího e-mailu. Pošli si nový a klikni na odkaz '
          'v nejnovějším e-mailu.\n($raw)';
    }
    return 'Přihlášení selhalo: $raw';
  }

  Future<void> _send() async {
    final email = _email.text.trim();
    if (email.isEmpty || !email.contains('@')) {
      snack(context, 'Zadej platný e-mail.');
      return;
    }
    setState(() {
      _sending = true;
      _authError = null;
    });
    final ok = await tryAction(
      context,
      () => Api.sendMagicLink(email, AppConfig.authRedirectUrl),
    );
    if (!mounted) return;
    setState(() {
      _sending = false;
      if (ok) _sent = true;
    });
  }

  @override
  Widget build(BuildContext context) {
    // A magic-link failure arriving while this screen is visible (the usual
    // case — the deep link opens the app, the token exchange fails).
    ref.listen(authStateProvider, (_, next) {
      if (next.hasError) {
        setState(() {
          _authError = _friendlyAuthError(next.error!);
          _sent = false; // back to the form so a new link can be sent
        });
      }
    });

    return Scaffold(
      body: SafeArea(
        child: AuthBackground(
          child: AuthCard(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Center(child: AuthLogo()),
                const SizedBox(height: 12),
                Text(
                  'Rezervátor',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.headlineMedium,
                ),
                Text(
                  'Kuželna na klik.',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
                const SizedBox(height: 32),
                if (_authError != null) ...[
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.errorContainer,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(
                          Icons.error_outline,
                          color: Theme.of(context).colorScheme.onErrorContainer,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            _authError!,
                            style: TextStyle(
                              color: Theme.of(
                                context,
                              ).colorScheme.onErrorContainer,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                ],
                if (_sent) ...[
                  const Icon(Icons.mark_email_read_outlined, size: 48),
                  const SizedBox(height: 12),
                  Text(
                    'Hotovo! Poslali jsme ti e-mail.\n'
                    'Otevři odkaz na tomhle zařízení — ve stejném prohlížeči,\n'
                    'ze kterého sis o něj řekl(a).\n'
                    'Odkaz platí hodinu a funguje jen ten z nejnovějšího '
                    'e-mailu.',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodyLarge,
                  ),
                  const SizedBox(height: 16),
                  TextButton(
                    onPressed: () => setState(() => _sent = false),
                    child: const Text('Poslat znovu / jiný e-mail'),
                  ),
                ] else ...[
                  TextField(
                    controller: _email,
                    keyboardType: TextInputType.emailAddress,
                    autocorrect: false,
                    decoration: const InputDecoration(
                      labelText: 'Tvůj e-mail',
                      border: OutlineInputBorder(),
                    ),
                    onSubmitted: (_) => _send(),
                  ),
                  const SizedBox(height: 16),
                  FilledButton(
                    onPressed: _sending ? null : _send,
                    child: Text(
                      _sending ? 'Odesílám…' : 'Poslat přihlašovací odkaz',
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Žádné heslo. Přijde ti e-mail s odkazem, '
                    'kliknutím se přihlásíš.',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
