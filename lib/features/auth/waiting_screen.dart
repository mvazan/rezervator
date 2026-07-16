import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/widgets/auth_background.dart';
import '../../data/providers.dart';

/// What the user is waiting for.
enum WaitingReason {
  /// Profile pending — any admin of the kuželna approves. Flips live via
  /// the profile stream.
  profileApproval,

  /// The whole kuželna is pending (its founder waits) — the SUPERADMIN
  /// approves new kuželny (0014). Tenant status is a one-shot fetch, so
  /// this variant re-checks periodically.
  tenantApproval,
}

/// Shown while something needs an approval; the AuthGate swaps the screen
/// away the moment the state flips.
class WaitingScreen extends ConsumerStatefulWidget {
  const WaitingScreen({super.key, this.reason = WaitingReason.profileApproval});

  final WaitingReason reason;

  @override
  ConsumerState<WaitingScreen> createState() => _WaitingScreenState();
}

class _WaitingScreenState extends ConsumerState<WaitingScreen> {
  Timer? _recheck;

  @override
  void initState() {
    super.initState();
    if (widget.reason == WaitingReason.tenantApproval) {
      // The tenant status isn't streamed — poll it so the founder gets in
      // without restarting the app once the superadmin approves.
      _recheck = Timer.periodic(const Duration(seconds: 20), (_) {
        ref.invalidate(myTenantStatusProvider);
      });
    }
  }

  @override
  void dispose() {
    _recheck?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tenant = widget.reason == WaitingReason.tenantApproval;
    return Scaffold(
      body: AuthBackground(
        child: AuthCard(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(tenant ? '🏗️' : '🕰️', style: const TextStyle(fontSize: 48)),
              const SizedBox(height: 16),
              Text(
                tenant ? 'Kuželna čeká na schválení' : 'Čekáš na schválení',
                style: Theme.of(context).textTheme.headlineSmall,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              Text(
                tenant
                    ? 'Nové kuželny aktivuje správce aplikace — přišlo mu '
                        'upozornění.\nJakmile ji schválí, pustíme tě dál — '
                        'obrazovka se přepne sama.'
                    : 'Správci přišlo upozornění, že ses zaregistroval(a).\n'
                        'Jakmile tě schválí, pustíme tě dál — obrazovka se '
                        'přepne sama.',
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 24),
              OutlinedButton(
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
