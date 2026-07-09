# Push fix report — align rezervator FCM with terminator

Branch: `fix-push-foreground`. Symptom: server-side FCM accepted the token but
push never displayed on device.

## Root cause A — competing Firebase init (REVERTED)

rezervator had added a stub `android/app/google-services.json` (685 B,
incomplete) plus the `com.google.gms.google-services` Gradle plugin. Terminator
has neither — it initialises Firebase purely from `--dart-define`s
(`FirebaseOptions` in `push.dart`). The stub + plugin created a conflicting
native init path. Reverted to terminator's approach:

- `android/settings.gradle.kts`: removed
  `id("com.google.gms.google-services") version "4.4.2" apply false`.
- `android/app/build.gradle.kts`: removed the
  `id("com.google.gms.google-services")` plugin line.
- Deleted `android/app/google-services.json` and
  `android/app/google-services.json.example` (both were gitignored, not tracked).
- `.gitignore`: removed the now-unneeded `android/app/google-services.json` line.

## Root cause B — no foreground display (ADDED)

rezervator's `push.dart` had no `FirebaseMessaging.onMessage` listener and no
`flutter_local_notifications`, so a received push showed nothing while the app
was foreground. Added terminator's foreground-display path:

- `pubspec.yaml`: `flutter_local_notifications: ^22.0.1` (matches terminator).
- `android/app/build.gradle.kts`: `isCoreLibraryDesugaringEnabled = true` in
  `compileOptions`, and a `dependencies { coreLibraryDesugaring(
  "com.android.tools:desugar_jdk_libs:2.1.4") }` block (mirrors terminator).
- `lib/push/push.dart`: added the `FlutterLocalNotificationsPlugin` field,
  `_local.initialize(...)` with `AndroidInitializationSettings(
  '@mipmap/ic_launcher')`, `FirebaseMessaging.onMessage.listen(_showForeground)`,
  and `_showForeground()` using an `AndroidNotificationDetails('rezervator',
  'Rezervátor', channelDescription: 'Upozornění kuželny', importance high,
  priority high)`.

### Deliberate deviations from terminator

- Kept rezervator's `hasFirebase && !kIsWeb` guard and existing token-save logic.
- Dropped terminator's tap-routing (`_route`, `_routeFromPayload`,
  `_pendingRoute`, `onMessageOpenedApp`, `getInitialMessage`, `navigatorKey`) —
  rezervator intentionally has no in-app routing (YAGNI). Foreground DISPLAY only.
- `initialize` omits `onDidReceiveNotificationResponse` (no routing needed).
- Omitted terminator's `tag` de-dup: rezervator's `supabase/functions/notify/
  index.ts` sets no `android.notification.tag` (verified — zero matches).
- Kept the `hide Day` on the flutter_local_notifications import: rezervator has a
  `Day` class in `lib/domain/models.dart`, so the name would clash.

## Verification

- `flutter pub get`: flutter_local_notifications 22.x resolved.
- `flutter analyze`: No issues found!
- `flutter build apk --debug`: succeeded (desugaring + local notifications compile).
- `flutter test`: 102 pass, 7 fail. The 7 failures are PRE-EXISTING and
  time-dependent (verified by stashing all changes and re-running on the clean
  base commit — the same 7 fail identically). They are unrelated to push (club
  banner / week / login / settings / kiosk date-sensitive widget tests) and this
  change touches no tested code (push.dart has no unit tests).

## API-version notes

flutter_local_notifications v22 API matched terminator's usage exactly — named
params `id:`, `title:`, `body:`, `notificationDetails:` on `show()`, and
`initialize(settings:)` — no signature adaptations were needed (analyze clean).
