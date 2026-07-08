import 'dart:async';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart' show debugPrint, kIsWeb;
import 'package:supabase_flutter/supabase_flutter.dart';

import '../config.dart';
import '../data/providers.dart';

/// Push notifications via FCM.
///
/// Firebase is initialised from --dart-define values (no google-services.json
/// needed). Without them — or on web — the whole module is a silent no-op, so
/// the app builds and runs before the Firebase project exists.
///
/// This phase only delivers the token to the backend so the notify Edge
/// Function has somewhere to send to; there's no in-app routing when a
/// notification is tapped (YAGNI — the OS opens the app, nothing more).
class Push {
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

      await FirebaseMessaging.instance.requestPermission();

      // Save the token now (if signed in), on every sign-in, and on refresh.
      _ready = true;
      unawaited(_saveToken());
      Supabase.instance.client.auth.onAuthStateChange.listen((state) {
        if (state.event == AuthChangeEvent.signedIn) unawaited(_saveToken());
      });
      FirebaseMessaging.instance.onTokenRefresh.listen((_) => _saveToken());
    } catch (e) {
      debugPrint('Push init failed (continuing without push): $e');
    }
  }

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
}
