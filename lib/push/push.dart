import 'dart:async';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart'
    show debugPrint, kIsWeb, visibleForTesting;
import 'package:flutter_local_notifications/flutter_local_notifications.dart'
    hide Day;
import 'package:supabase_flutter/supabase_flutter.dart';

import '../config.dart';
import '../data/providers.dart';

/// Push notifications via FCM.
///
/// Firebase is initialised from --dart-define values (no google-services.json
/// needed). Without them — or on web — the whole module is a silent no-op, so
/// the app builds and runs before the Firebase project exists.
///
/// This phase delivers the token to the backend so the notify Edge Function
/// has somewhere to send to, and shows a local notification for messages that
/// arrive while the app is in the foreground. There's no in-app routing when a
/// notification is tapped (YAGNI — the OS opens the app, nothing more).
class Push {
  static final _local = FlutterLocalNotificationsPlugin();
  static bool _ready = false;

  static Future<void> init() async {
    if (!AppConfig.hasFirebase || kIsWeb) {
      debugPrint('Push disabled: no FIREBASE_* dart-defines (or web).');
      return;
    }
    try {
      await Firebase.initializeApp(
        options: const FirebaseOptions(
          apiKey: AppConfig.firebaseApiKey,
          appId: AppConfig.firebaseAppId,
          messagingSenderId: AppConfig.firebaseSenderId,
          projectId: AppConfig.firebaseProjectId,
        ),
      );

      await _local.initialize(
        settings: const InitializationSettings(
          android: AndroidInitializationSettings('@mipmap/ic_launcher'),
          iOS: DarwinInitializationSettings(),
        ),
      );

      await FirebaseMessaging.instance.requestPermission();

      // Save the token now (if signed in), on every sign-in, and on refresh;
      // forget it whenever nobody is signed in.
      _ready = true;
      if (Supabase.instance.client.auth.currentUser == null) {
        _forgetToken();
      } else {
        unawaited(_saveToken());
      }
      listenForAuth(Supabase.instance.client.auth.onAuthStateChange,
          onSignedIn: () => unawaited(_saveToken()),
          onSignedOut: _forgetToken);
      FirebaseMessaging.instance.onTokenRefresh.listen((_) => _saveToken());

      // Foreground messages: show them via a local notification.
      FirebaseMessaging.onMessage.listen(_showForeground);
    } catch (e) {
      debugPrint('Push init failed (continuing without push): $e');
    }
  }

  /// Sign-ins save the token, sign-outs forget it — an explicit one or a
  /// session supabase dropped.
  ///
  /// supabase_flutter puts a failed magic link (expired or used —
  /// `otp_expired`) on onAuthStateChange as a stream error. Without an
  /// onError here that error became uncaught and reached Sentry as a fatal
  /// crash (REZERVATOR-7), though the login screen already explains it.
  @visibleForTesting
  static StreamSubscription<AuthState> listenForAuth(
    Stream<AuthState> changes, {
    required void Function() onSignedIn,
    required void Function() onSignedOut,
  }) =>
      changes.listen(
        (state) {
          if (state.event == AuthChangeEvent.signedIn) onSignedIn();
          if (state.event == AuthChangeEvent.signedOut) onSignedOut();
        },
        onError: (Object _) {},
      );

  /// The deletion [_forgetToken] started, until it is done.
  static Future<void>? _forgetting;

  /// A device nobody is signed in on holds no FCM token. The token is the
  /// device's, not the account's: left alive, FCM keeps delivering to it
  /// whatever a profile still holds (a sign-out offline, a session that
  /// expired — nothing could clear the profile then — or a sign-out on an
  /// app from before this), and the next account here would register the
  /// very same token. Deleted, the next sign-in gets a fresh one, and a
  /// profile still holding the old one gets UNREGISTERED from FCM, which
  /// notify answers by clearing it. Runs on every sign-out and on a start
  /// without a session; offline it fails and the next start tries again.
  static void _forgetToken() {
    _forgetting = FirebaseMessaging.instance.deleteToken().catchError(
        (Object e) => debugPrint('FCM token delete failed: $e'));
  }

  static Future<void> _saveToken() async {
    if (!_ready) return;
    try {
      // A sign-in right after a sign-out would otherwise read the token
      // that is being deleted.
      await _forgetting;
      if (Supabase.instance.client.auth.currentUser == null) return;
      final token = await FirebaseMessaging.instance.getToken();
      await Api.updateFcmToken(token);
    } catch (e) {
      debugPrint('FCM token save failed: $e');
    }
  }

  static Future<void> _showForeground(RemoteMessage message) async {
    final notification = message.notification;
    if (notification == null) return;
    await _local.show(
      id: notification.hashCode,
      title: notification.title,
      body: notification.body,
      notificationDetails: const NotificationDetails(
        android: AndroidNotificationDetails(
          'rezervator',
          'Rezervátor',
          channelDescription: 'Upozornění kuželny',
          importance: Importance.high,
          priority: Priority.high,
        ),
      ),
    );
  }
}
