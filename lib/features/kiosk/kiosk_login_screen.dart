import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/ui.dart';
import '../../data/providers.dart';

/// Password login for the shared kiosk device account. A separate route from
/// the magic-link [LoginScreen] since kiosks are shared hardware with no
/// mailbox of their own — the admin creates the account per SETUP.md and
/// signs the device in once with e-mail + password.
class KioskLoginScreen extends ConsumerStatefulWidget {
  const KioskLoginScreen({super.key});

  @override
  ConsumerState<KioskLoginScreen> createState() => _KioskLoginScreenState();
}

class _KioskLoginScreenState extends ConsumerState<KioskLoginScreen> {
  final _email = TextEditingController();
  final _password = TextEditingController();
  bool _sending = false;

  @override
  void initState() {
    super.initState();
    // Already signed in on this device — skip the form entirely so a kiosk
    // that just restarted doesn't flash a login screen. Deferred to
    // post-frame since context.go() during build is unsafe.
    if (Supabase.instance.client.auth.currentSession != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) context.go('/');
      });
    }
  }

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _signIn() async {
    final email = _email.text.trim();
    final password = _password.text;
    if (email.isEmpty || !email.contains('@') || password.isEmpty) {
      snack(context, 'Zadej e-mail a heslo.');
      return;
    }
    setState(() => _sending = true);
    final ok = await tryAction(
        context, () => Api.signInWithPassword(email, password));
    if (!mounted) return;
    setState(() => _sending = false);
    // AuthGate routes onward by role once the session lands.
    if (ok) context.go('/');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 400),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text('Kiosk — přihlášení',
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.headlineMedium),
                  const SizedBox(height: 32),
                  TextField(
                    controller: _email,
                    keyboardType: TextInputType.emailAddress,
                    autocorrect: false,
                    decoration: const InputDecoration(
                      labelText: 'E-mail',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: _password,
                    obscureText: true,
                    decoration: const InputDecoration(
                      labelText: 'Heslo',
                      border: OutlineInputBorder(),
                    ),
                    onSubmitted: (_) => _signIn(),
                  ),
                  const SizedBox(height: 16),
                  FilledButton(
                    onPressed: _sending ? null : _signIn,
                    child: Text(_sending ? 'Přihlašuji…' : 'Přihlásit'),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Přihlas kioskový účet — vytvoří ho správce podle '
                    'SETUP.md.',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
