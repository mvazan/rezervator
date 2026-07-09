import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/widgets/auth_background.dart';
import '../../data/providers.dart';
import '../../domain/models.dart';
import '../kiosk/kiosk_shell.dart';
import '../schedule/home_shell.dart';
import 'login_screen.dart';
import 'register_screen.dart';
import 'waiting_screen.dart';

/// Routes by auth/profile state:
/// no session -> login, no profile -> register, pending -> waiting,
/// kiosk role -> kiosk shell, else -> the app.
/// All transitions are live (streams).
class AuthGate extends ConsumerWidget {
  const AuthGate({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final auth = ref.watch(authStateProvider);
    final session =
        auth.value?.session ?? Supabase.instance.client.auth.currentSession;

    if (auth.isLoading && session == null) {
      return const _Splash();
    }
    if (session == null) {
      return const LoginScreen();
    }

    final profile = ref.watch(myProfileProvider);
    return profile.when(
      loading: () => const _Splash(),
      error: (e, _) => _ErrorScreen(error: '$e'),
      data: (p) {
        if (p == null) return const RegisterScreen();
        if (p.role == Role.kiosk) return const KioskShell();
        if (p.status == ProfileStatus.pending) return const WaitingScreen();
        return const HomeShell();
      },
    );
  }
}

class _Splash extends StatelessWidget {
  const _Splash();

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      body: Center(child: AuthLogo(size: 96)),
    );
  }
}

class _ErrorScreen extends StatelessWidget {
  const _ErrorScreen({required this.error});

  final String error;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('Něco se pokazilo.'),
              const SizedBox(height: 8),
              Text(error, style: Theme.of(context).textTheme.bodySmall),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: Api.signOut,
                child: const Text('Odhlásit se'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
