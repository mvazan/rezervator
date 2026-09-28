import 'dart:async';
import 'dart:convert' show jsonDecode, jsonEncode;

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart'
    show debugPrint, kIsWeb, visibleForTesting;
import 'package:flutter_local_notifications/flutter_local_notifications.dart'
    hide Day;
import 'package:supabase_flutter/supabase_flutter.dart';

import '../config.dart';
import '../data/providers.dart';
import 'pending_link.dart';

/// Push notifications via FCM.
///
/// Firebase is initialised from --dart-define values (no google-services.json
/// needed). Without them — or on web — the whole module is a silent no-op, so
/// the app builds and runs before the Firebase project exists.
///
/// This phase delivers the token to the backend so the notify Edge Function
/// has somewhere to send to, and shows a local notification for messages that
/// arrive while the app is in the foreground. A tap on a message/notice/
/// reaction push deep-links via [PendingLinkSource] (0051); every other kind
/// still just opens the app, unchanged.
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
        onDidReceiveNotificationResponse: _onLocalNotificationTapped,
      );

      await FirebaseMessaging.instance.requestPermission();

      // Save the token now (if signed in), on every sign-in, and on refresh.
      _ready = true;
      unawaited(_saveToken());
      listenForSignIn(Supabase.instance.client.auth.onAuthStateChange,
          () => unawaited(_saveToken()));
      FirebaseMessaging.instance.onTokenRefresh.listen((_) => _saveToken());

      // Foreground messages: show them via a local notification.
      FirebaseMessaging.onMessage.listen(_showForeground);
      // Taps (0051): on a push while backgrounded (warm), and the one that
      // launched the app from terminated (cold).
      FirebaseMessaging.onMessageOpenedApp.listen(_onMessageTapped);
      unawaited(FirebaseMessaging.instance.getInitialMessage().then(
        (message) {
          if (message != null) _onMessageTapped(message);
        },
        onError: (Object e) => debugPrint('Initial push read failed: $e'),
      ));
      // …and a foreground push's local notification tapped after the app
      // was closed: that launch skips onDidReceiveNotificationResponse.
      unawaited(_local.getNotificationAppLaunchDetails().then(
        (launch) {
          final response = launch?.notificationResponse;
          if ((launch?.didNotificationLaunchApp ?? false) &&
              response != null) {
            _onLocalNotificationTapped(response);
          }
        },
        onError: (Object e) => debugPrint('Launch details read failed: $e'),
      ));
    } catch (e) {
      debugPrint('Push init failed (continuing without push): $e');
    }
  }

  /// supabase_flutter puts a failed magic link (expired or used —
  /// `otp_expired`) on onAuthStateChange as a stream error. Without an
  /// onError here that error became uncaught and reached Sentry as a fatal
  /// crash (REZERVATOR-7), though the login screen already explains it.
  @visibleForTesting
  static StreamSubscription<AuthState> listenForSignIn(
    Stream<AuthState> changes,
    void Function() onSignedIn,
  ) =>
      changes.listen(
        (state) {
          if (state.event == AuthChangeEvent.signedIn) onSignedIn();
        },
        onError: (Object _) {},
      );

  static Future<void> _saveToken() async {
    if (!_ready) return;
    try {
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
      // The push's data rides along, so a tap on this local notification
      // deep-links like a tap on a background push does.
      payload: jsonEncode(message.data),
    );
  }

  /// A tap on an OS-shown push: its data may name a message or notice.
  static void _onMessageTapped(RemoteMessage message) {
    final link = pendingLinkFromData(message.data);
    if (link != null) PendingLinkSource.publish(link);
  }

  /// A tap on a foreground push's local notification: [_showForeground]
  /// put the push's data into the payload as JSON.
  static void _onLocalNotificationTapped(NotificationResponse response) {
    final payload = response.payload;
    if (payload == null) return;
    try {
      final data = jsonDecode(payload) as Map<String, dynamic>;
      final link = pendingLinkFromData(data);
      if (link != null) PendingLinkSource.publish(link);
    } catch (_) {}
  }
}
