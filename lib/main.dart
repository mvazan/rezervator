import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:sentry_flutter/sentry_flutter.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'config.dart';
import 'core/error_reporting.dart';
import 'core/text_size.dart';
import 'core/theme.dart';
import 'core/theme_choice.dart';
import 'data/local_prefs.dart';
import 'features/auth/auth_gate.dart';
import 'features/kiosk/kiosk_login_screen.dart';
import 'push/push.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Sentry (optional): with a DSN it wraps startup so uncaught Flutter/Dart
  // errors are reported; without one it's a no-op and the app starts normally.
  // One Sentry project covers all build targets — the `environment` tag
  // separates the web build from the Android app/kiosk (same package).
  if (AppConfig.hasSentry) {
    await SentryFlutter.init(
      (options) {
        options.dsn = AppConfig.sentryDsn;
        options.environment = kIsWeb ? 'web' : 'app';
        options.sendDefaultPii = false; // no IP/user data beyond the error
        // Drop transient connectivity errors — the app handles offline
        // gracefully, so these are false alarms, not bugs.
        options.beforeSend = (event, hint) =>
            isTransientNetworkError(event.throwable) ? null : event;
      },
      appRunner: _bootstrap,
    );
  } else {
    await _bootstrap();
  }
}

/// Backend init + runApp — shared so Sentry's appRunner and the no-Sentry
/// path run exactly the same startup.
Future<void> _bootstrap() async {
  if (AppConfig.hasSupabase) {
    await Supabase.initialize(
      url: AppConfig.supabaseUrl,
      publishableKey: AppConfig.supabaseAnonKey,
    );
    await Push.init();
  }

  // Read the persisted theme/text-size choice before the first frame, so a
  // dark-theme user never sees a flash of the light default while
  // ThemeChoiceNotifier/TextSizeNotifier's own async load is still pending
  // (see data/local_prefs.dart).
  final appearanceOverrides = await loadPersistedAppearance();
  runApp(ProviderScope(
    overrides: appearanceOverrides,
    child: const RezervatorApp(),
  ));
}

final _router = GoRouter(
  routes: [
    GoRoute(
      path: '/',
      builder: (_, _) =>
          AppConfig.hasSupabase ? const AuthGate() : const _NotConfigured(),
    ),
    GoRoute(
      path: '/kiosk-login',
      builder: (_, _) => AppConfig.hasSupabase
          ? const KioskLoginScreen()
          : const _NotConfigured(),
    ),
  ],
);

class RezervatorApp extends ConsumerWidget {
  const RezervatorApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Appearance from Settings: theme/darkTheme/themeMode all come from the
    // same plan, so the ThemeMode and each ThemeData's contrastLevel never
    // disagree (see core/theme_choice.dart).
    final plan = themePlanFor(ref.watch(themeChoiceProvider));
    final textSize = ref.watch(textSizeProvider);
    return MaterialApp.router(
      title: 'Rezervátor',
      debugShowCheckedModeBanner: false,
      // Wraps the Router: applies the chosen text size on every screen, on
      // top of whatever the system scale already is.
      builder: (context, child) {
        final mq = MediaQuery.of(context);
        return MediaQuery(
          data:
              mq.copyWith(textScaler: AppTextScaler(mq.textScaler, textSize)),
          child: child!,
        );
      },
      locale: const Locale('cs'),
      supportedLocales: const [Locale('cs')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      theme: buildTheme(Brightness.light, contrastLevel: plan.contrastLevel),
      darkTheme:
          buildTheme(Brightness.dark, contrastLevel: plan.contrastLevel),
      themeMode: plan.mode,
      routerConfig: _router,
    );
  }
}

/// Shown when the app was built without --dart-define backend credentials.
class _NotConfigured extends StatelessWidget {
  const _NotConfigured();

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      body: Padding(
        padding: EdgeInsets.all(24),
        child: Center(
          child: Text(
            'Rezervátor 🎳\n\n'
            'Aplikace není nakonfigurovaná.\n\n'
            'Sestav ji s přístupem k backendu:\n'
            'flutter run --dart-define=SUPABASE_URL=... '
            '--dart-define=SUPABASE_ANON_KEY=...\n\n'
            'Podrobnosti najdeš v SETUP.md.',
            textAlign: TextAlign.center,
          ),
        ),
      ),
    );
  }
}
