# Rezervátor — Phase 0 (Walking Skeleton) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Standalone Flutter (Android + Web + iOS-scaffold) + Supabase app skeleton: magic-link auth with admin approval (first user = admin), complete DB schema, static week grid, GitHub Pages deploy pipeline, SETUP.md.

**Architecture:** Single Flutter codebase (go_router, Riverpod), Supabase backend (Postgres + RLS + Realtime + Edge Functions later). Patterns are lifted from the sibling app at `/Users/mvazan/Home/terminator` (read files there when a step says "copy"). Spec: `docs/superpowers/specs/2026-07-07-rezervator-design.md`.

**Tech Stack:** Dart ^3.10 / Flutter stable, Material 3, flutter_riverpod, supabase_flutter, go_router, url_launcher.

## Global Constraints

- Repo root: `/Users/mvazan/Home/rezervator` (git already initialized, branch `main`). All paths below are relative to it.
- Project name `rezervator`, org `cz.kuzelky`, Android deep link scheme `cz.kuzelky.rezervator://login-callback`.
- Platforms: `android,web,ios` (iOS is scaffold-only; never run iOS builds).
- **UI language: Czech.** All user-facing strings in Czech, no localization framework beyond `flutter_localizations` locale `cs`.
- Domain code (`lib/domain/`) is pure Dart — no Flutter imports — and unit-tested.
- No `DateTime.now()` inside `lib/domain/` functions; time is always injected (testability).
- Reservations are mutated ONLY via RPCs (`create_reservation`, `cancel_reservation`) — never direct table writes.
- Commit after every task with the given message; end every commit message with `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.
- Verification baseline for every task: `flutter analyze` reports "No issues found!" and `flutter test` passes (once tests exist).

---

### Task 1: Flutter scaffold + dependencies + deep link

**Files:**
- Create: entire Flutter scaffold via `flutter create` (in repo root)
- Modify: `pubspec.yaml`, `android/app/src/main/AndroidManifest.xml`, `.gitignore`
- Delete: `test/widget_test.dart` (counter-app test, replaced by domain tests in Task 3)

**Interfaces:**
- Consumes: nothing
- Produces: compilable empty app; packages `supabase_flutter`, `flutter_riverpod`, `go_router`, `url_launcher`, `flutter_localizations` available to all later tasks

- [ ] **Step 1: Scaffold the project into the existing repo root**

```bash
cd /Users/mvazan/Home/rezervator
flutter create --org cz.kuzelky --project-name rezervator --platforms=android,web,ios .
```
Expected: "All done!" and `lib/main.dart`, `android/`, `web/`, `ios/` exist.

- [ ] **Step 2: Add dependencies (resolves current versions, do not pin by hand)**

```bash
flutter pub add supabase_flutter flutter_riverpod go_router url_launcher
flutter pub add flutter_localizations --sdk=flutter
```

- [ ] **Step 3: Delete the counter test**

```bash
rm test/widget_test.dart
```

- [ ] **Step 4: Register the magic-link deep link on Android**

Open `/Users/mvazan/Home/terminator/android/app/src/main/AndroidManifest.xml`, find the `<intent-filter>` block containing `android:scheme="cz.kuzelky.terminator"` (plus any related `<meta-data>` next to it). Mirror that exact structure into `android/app/src/main/AndroidManifest.xml` inside `<activity android:name=".MainActivity" ...>`, replacing the scheme with `cz.kuzelky.rezervator` and host `login-callback`. The result must contain:

```xml
<intent-filter>
    <action android:name="android.intent.action.VIEW" />
    <category android:name="android.intent.category.DEFAULT" />
    <category android:name="android.intent.category.BROWSABLE" />
    <data android:scheme="cz.kuzelky.rezervator" android:host="login-callback" />
</intent-filter>
```

- [ ] **Step 5: Verify**

```bash
flutter analyze
```
Expected: `No issues found!`

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "chore: scaffold Flutter project (android/web/ios) with deps and deep link"
```

---

### Task 2: Config, shared UI helpers, theme, router, entrypoint

**Files:**
- Create: `lib/config.dart`, `lib/core/ui.dart`
- Modify: `lib/main.dart` (full replace)

**Interfaces:**
- Consumes: nothing
- Produces: `AppConfig.hasSupabase`, `AppConfig.authRedirectUrl` (String getter), `snack(context, msg)`, `tryAction(context, action, {success})`, `confirmDialog(...)`, `dayLabel(Day)`, `dayFull(Day)`, `weekdaysShort`, `today()`, `RezervatorApp` with `GoRouter` route `/` → `AuthGate` (AuthGate itself lands in Task 6 — until then use a temporary placeholder widget declared in main.dart)

- [ ] **Step 1: Write `lib/config.dart`**

Copy `/Users/mvazan/Home/terminator/lib/config.dart` and change ONLY: (a) add `import 'package:flutter/foundation.dart' show kIsWeb;` below the doc comment, (b) replace the `authRedirectUrl` constant with a getter that works for both web (GitHub Pages subpath!) and Android:

```dart
/// Where the magic-link e-mail redirects back to: the current web origin+path
/// on web builds (works on GitHub Pages subpaths), the Android deep link
/// elsewhere. Both must be registered in Supabase dashboard redirect URLs.
static String get authRedirectUrl => kIsWeb
    ? Uri.base.origin + Uri.base.path
    : 'cz.kuzelky.rezervator://login-callback';
```

- [ ] **Step 2: Write `lib/core/ui.dart`**

Copy `/Users/mvazan/Home/terminator/lib/core/ui.dart` and delete the terminator-specific parts: the `export` line, `memberName`, `rosterEntryName`, and `DateBadge`. Keep: `weekdaysShort`, `_weekdaysFull`, `dayLabel`, `dayFull`, `today()`, `snack`, `tryAction`, `confirmDialog`, `promptText`, `launchEmail`, `launchPhone`, `launchWeb`, `_launchExternal`. Keep the import of `../domain/models.dart` (Task 3 provides it; until then `flutter analyze` will flag it — that is fine, Tasks 2+3 are committed together only if you must; otherwise accept one intermediate commit with a TODO-free known-red analyze and fix in Task 3 — preferred: do Task 2 and Task 3 in one working session and commit Task 2 only after models.dart exists).

*Correction for executor:* to keep every commit green, in THIS task create a minimal `lib/domain/models.dart` containing only the `Day` and `HourMinute` classes plus `compareDayTime` copied VERBATIM from `/Users/mvazan/Home/terminator/lib/domain/models.dart` (lines 1–96, i.e. the library doc comment through `compareDayTime`/`rangeLabel`). Task 3 extends this file.

- [ ] **Step 3: Replace `lib/main.dart`**

Base it on `/Users/mvazan/Home/terminator/lib/main.dart` with these changes: app class `RezervatorApp`, title `Rezervátor`, seed color `Color(0xFF00695C)` (teal — distinct from Termínátor bordeaux), locale `cs` only, no `Push` yet (Phase 5), `MaterialApp.router` with go_router instead of `home:`. Full file:

```dart
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'config.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  if (AppConfig.hasSupabase) {
    await Supabase.initialize(
      url: AppConfig.supabaseUrl,
      publishableKey: AppConfig.supabaseAnonKey,
    );
  }

  runApp(const ProviderScope(child: RezervatorApp()));
}

final _router = GoRouter(
  routes: [
    GoRoute(path: '/', builder: (_, __) => const _Home()),
  ],
);

/// Placeholder root — replaced by AuthGate in the auth task.
class _Home extends StatelessWidget {
  const _Home();

  @override
  Widget build(BuildContext context) {
    return AppConfig.hasSupabase
        ? const Scaffold(body: Center(child: Text('Rezervátor 🎳')))
        : const _NotConfigured();
  }
}

class RezervatorApp extends StatelessWidget {
  const RezervatorApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp.router(
      title: 'Rezervátor',
      debugShowCheckedModeBanner: false,
      locale: const Locale('cs'),
      supportedLocales: const [Locale('cs')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      theme: _theme(Brightness.light),
      darkTheme: _theme(Brightness.dark),
      routerConfig: _router,
    );
  }

  ThemeData _theme(Brightness brightness) {
    // Copied from terminator/lib/main.dart _theme() verbatim except seedColor.
    final scheme = ColorScheme.fromSeed(
      seedColor: const Color(0xFF00695C), // rezervátor teal
      brightness: brightness,
    );
    return ThemeData(
      colorScheme: scheme,
      useMaterial3: true,
      scaffoldBackgroundColor: scheme.surfaceContainerLowest,
      appBarTheme: AppBarTheme(
        backgroundColor: scheme.surfaceContainerLowest,
        scrolledUnderElevation: 0,
        titleTextStyle: TextStyle(
          color: scheme.onSurface,
          fontSize: 22,
          fontWeight: FontWeight.w700,
        ),
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        color: scheme.surfaceContainer,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        margin: const EdgeInsets.symmetric(vertical: 6),
      ),
      inputDecorationTheme: InputDecorationTheme(
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
        filled: true,
        fillColor: scheme.surfaceContainer,
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          textStyle: const TextStyle(fontWeight: FontWeight.w600),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        ),
      ),
      chipTheme: ChipThemeData(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        side: BorderSide(color: scheme.outlineVariant),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: scheme.surfaceContainerLowest,
        indicatorColor: scheme.primaryContainer,
      ),
      snackBarTheme: const SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
      ),
      dividerTheme: DividerThemeData(
        color: scheme.outlineVariant.withValues(alpha: 0.4),
      ),
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
```

- [ ] **Step 4: Verify**

```bash
flutter analyze
```
Expected: `No issues found!`

- [ ] **Step 5: Commit**

```bash
git add lib/ && git commit -m "feat: config, czech ui helpers, theme, router entrypoint"
```

---

### Task 3: Domain models + tests (TDD)

**Files:**
- Modify: `lib/domain/models.dart` (extend the Day/HourMinute base from Task 2)
- Test: `test/domain/models_test.dart`

**Interfaces:**
- Consumes: `Day`, `HourMinute`, `compareDayTime` (already in file)
- Produces (exact names later tasks use):
  - `enum Role { player, admin, kiosk }`, `enum ProfileStatus { pending, approved }`
  - `Profile { String id, String displayName, String club, String email, Role role, ProfileStatus status, String? fcmToken; bool get isApproved; bool get isAdmin; factory fromJson }`
  - `PlayerName { String id, String displayName, String club; factory fromJson }` (rows of the `players` view)
  - `ScheduleSettings { int laneCount, Set<int> trainingWeekdays, int bookingHorizonDays, int maxActiveReservations; factory fromJson; static ScheduleSettings get defaults }` (defaults: 4 lanes, {1,2,4}, 14, 3)
  - `TimeBlock { String id, HourMinute startsAt, HourMinute endsAt, int position, bool active; factory fromJson; String get label }` (`label` = `"16:00–17:00"` style) and top-level `List<TimeBlock> defaultTimeBlocks()` returning six inactive-id (`'default-N'`) hourly blocks 16:00→22:00 used only for the pre-setup static grid
  - `DayOverride { Day date, bool closed, String reason, List<String>? blockIds; factory fromJson }`
  - `Match { String id, Day date, HourMinute startsAt, HourMinute endsAt, String opponent, String description; factory fromJson }`
  - `Rental { String id, String renterName, List<int> lanes, Day? date, int? weekday, HourMinute startsAt, HourMinute endsAt, Day? validFrom, Day? validUntil, String note; factory fromJson; bool occursOn(Day day) }`
  - `Reservation { String id, String playerId, Day date, String blockId, int lane, String createdVia, DateTime createdAt, DateTime? cancelledAt, String? cancelledVia, String cancelNote; factory fromJson; bool get isLive }`

- [ ] **Step 1: Write failing tests** — `test/domain/models_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:rezervator/domain/models.dart';

void main() {
  group('HourMinute', () {
    test('parses HH:MM:SS and compares', () {
      final a = HourMinute.parse('16:00:00');
      final b = HourMinute.parse('17:30');
      expect(a.hour, 16);
      expect(b.minute, 30);
      expect(a.compareTo(b), lessThan(0));
      expect(a.toSql(), '16:00:00');
    });
  });

  group('Day', () {
    test('parses, adds days across DST, knows weekday', () {
      final d = Day.parse('2026-03-28'); // Saturday before EU DST switch
      expect(d.weekday, 6);
      expect(d.addDays(2).toSql(), '2026-03-30');
    });
  });

  group('ScheduleSettings', () {
    test('fromJson reads int[] weekdays', () {
      final s = ScheduleSettings.fromJson({
        'lane_count': 6,
        'training_weekdays': [1, 3],
        'booking_horizon_days': 7,
        'max_active_reservations': 2,
      });
      expect(s.laneCount, 6);
      expect(s.trainingWeekdays, {1, 3});
      expect(s.bookingHorizonDays, 7);
      expect(s.maxActiveReservations, 2);
    });

    test('defaults', () {
      expect(ScheduleSettings.defaults.laneCount, 4);
      expect(ScheduleSettings.defaults.trainingWeekdays, {1, 2, 4});
    });
  });

  group('Profile', () {
    test('parses role and status', () {
      final p = Profile.fromJson({
        'id': 'u1',
        'display_name': 'Ján',
        'club': 'KK Praha',
        'email': 'jan@example.com',
        'role': 'admin',
        'status': 'approved',
        'fcm_token': null,
      });
      expect(p.role, Role.admin);
      expect(p.isAdmin, isTrue);
      expect(p.isApproved, isTrue);
    });
  });

  group('Rental.occursOn', () {
    Rental weekly({Day? from, Day? until}) => Rental(
          id: 'r1',
          renterName: 'Firma X',
          lanes: const [1, 2],
          date: null,
          weekday: 3,
          startsAt: const HourMinute(18, 0),
          endsAt: const HourMinute(20, 0),
          validFrom: from,
          validUntil: until,
          note: '',
        );

    test('one-time matches only its date', () {
      final r = Rental(
        id: 'r2',
        renterName: 'Oslava',
        lanes: const [3],
        date: Day(2026, 7, 15),
        weekday: null,
        startsAt: const HourMinute(18, 0),
        endsAt: const HourMinute(20, 0),
        validFrom: null,
        validUntil: null,
        note: '',
      );
      expect(r.occursOn(Day(2026, 7, 15)), isTrue);
      expect(r.occursOn(Day(2026, 7, 22)), isFalse);
    });

    test('weekly matches weekday inside validity window', () {
      final r = weekly(from: Day(2026, 7, 1), until: Day(2026, 7, 31));
      expect(r.occursOn(Day(2026, 7, 15)), isTrue); // Wednesday
      expect(r.occursOn(Day(2026, 7, 16)), isFalse); // Thursday
      expect(r.occursOn(Day(2026, 8, 5)), isFalse); // Wed after window
      expect(weekly().occursOn(Day(2026, 8, 5)), isTrue); // open-ended
    });
  });

  group('Reservation', () {
    test('isLive false when cancelled', () {
      final json = {
        'id': 'x',
        'player_id': 'u1',
        'date': '2026-07-08',
        'block_id': 'b1',
        'lane': 2,
        'created_via': 'kiosk',
        'created_at': '2026-07-07T10:00:00Z',
        'cancelled_at': null,
        'cancelled_via': null,
        'cancel_note': '',
      };
      expect(Reservation.fromJson(json).isLive, isTrue);
      expect(
        Reservation.fromJson({
          ...json,
          'cancelled_at': '2026-07-07T11:00:00Z',
          'cancelled_via': 'one_click',
        }).isLive,
        isFalse,
      );
    });
  });

  group('defaultTimeBlocks', () {
    test('six hourly blocks 16–22', () {
      final blocks = defaultTimeBlocks();
      expect(blocks, hasLength(6));
      expect(blocks.first.startsAt, const HourMinute(16, 0));
      expect(blocks.last.endsAt, const HourMinute(22, 0));
      expect(blocks.first.label, '16:00–17:00');
    });
  });
}
```

- [ ] **Step 2: Run tests, verify they fail**

```bash
flutter test test/domain/models_test.dart
```
Expected: compile errors — `ScheduleSettings`, `Profile`, `Rental`… not defined.

- [ ] **Step 3: Extend `lib/domain/models.dart`**

Keep the existing header + `HourMinute` + `Day` + `compareDayTime` + `rangeLabel`, make `HourMinute` const-constructible (it already is), then append (style mirrors terminator — plain classes, `fromJson` factories, no codegen):

```dart
enum Role { player, admin, kiosk }

enum ProfileStatus { pending, approved }

class Profile {
  const Profile({
    required this.id,
    required this.displayName,
    required this.club,
    required this.email,
    required this.role,
    required this.status,
    this.fcmToken,
  });

  final String id;
  final String displayName;
  final String club;
  final String email;
  final Role role;
  final ProfileStatus status;
  final String? fcmToken;

  bool get isApproved => status == ProfileStatus.approved;
  bool get isAdmin => role == Role.admin && isApproved;

  factory Profile.fromJson(Map<String, dynamic> json) => Profile(
        id: json['id'] as String,
        displayName: json['display_name'] as String,
        club: json['club'] as String? ?? '',
        email: json['email'] as String? ?? '',
        role: Role.values.asNameMap()[json['role']] ?? Role.player,
        status: json['status'] == 'approved'
            ? ProfileStatus.approved
            : ProfileStatus.pending,
        fcmToken: json['fcm_token'] as String?,
      );
}

/// A row of the `players` view — the only profile data the kiosk sees.
class PlayerName {
  const PlayerName({
    required this.id,
    required this.displayName,
    required this.club,
  });

  final String id;
  final String displayName;
  final String club;

  factory PlayerName.fromJson(Map<String, dynamic> json) => PlayerName(
        id: json['id'] as String,
        displayName: json['display_name'] as String,
        club: json['club'] as String? ?? '',
      );
}

class ScheduleSettings {
  const ScheduleSettings({
    required this.laneCount,
    required this.trainingWeekdays,
    required this.bookingHorizonDays,
    required this.maxActiveReservations,
  });

  final int laneCount;

  /// ISO weekdays with regular trainings (1 = Monday … 7 = Sunday).
  final Set<int> trainingWeekdays;
  final int bookingHorizonDays;
  final int maxActiveReservations;

  static const defaults = ScheduleSettings(
    laneCount: 4,
    trainingWeekdays: {1, 2, 4},
    bookingHorizonDays: 14,
    maxActiveReservations: 3,
  );

  factory ScheduleSettings.fromJson(Map<String, dynamic> json) =>
      ScheduleSettings(
        laneCount: json['lane_count'] as int,
        trainingWeekdays: {
          for (final d in json['training_weekdays'] as List) d as int,
        },
        bookingHorizonDays: json['booking_horizon_days'] as int,
        maxActiveReservations: json['max_active_reservations'] as int,
      );
}

class TimeBlock {
  const TimeBlock({
    required this.id,
    required this.startsAt,
    required this.endsAt,
    required this.position,
    required this.active,
  });

  final String id;
  final HourMinute startsAt;
  final HourMinute endsAt;
  final int position;
  final bool active;

  /// "16:00–17:00"
  String get label => '${_pad(startsAt)}–${_pad(endsAt)}';

  static String _pad(HourMinute t) =>
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

  factory TimeBlock.fromJson(Map<String, dynamic> json) => TimeBlock(
        id: json['id'] as String,
        startsAt: HourMinute.parse(json['starts_at'] as String),
        endsAt: HourMinute.parse(json['ends_at'] as String),
        position: json['position'] as int,
        active: json['active'] as bool? ?? true,
      );
}

/// Hourly 16–22 placeholder grid shown before the admin configures blocks.
List<TimeBlock> defaultTimeBlocks() => [
      for (var i = 0; i < 6; i++)
        TimeBlock(
          id: 'default-$i',
          startsAt: HourMinute(16 + i, 0),
          endsAt: HourMinute(17 + i, 0),
          position: i,
          active: true,
        ),
    ];

class DayOverride {
  const DayOverride({
    required this.date,
    required this.closed,
    required this.reason,
    this.blockIds,
  });

  final Day date;
  final bool closed;
  final String reason;

  /// null = the default active block set applies; set = exactly these blocks.
  final List<String>? blockIds;

  factory DayOverride.fromJson(Map<String, dynamic> json) => DayOverride(
        date: Day.parse(json['date'] as String),
        closed: json['closed'] as bool,
        reason: json['reason'] as String? ?? '',
        blockIds: (json['block_ids'] as List?)?.cast<String>(),
      );
}

class Match {
  const Match({
    required this.id,
    required this.date,
    required this.startsAt,
    required this.endsAt,
    required this.opponent,
    required this.description,
  });

  final String id;
  final Day date;
  final HourMinute startsAt;
  final HourMinute endsAt;
  final String opponent;
  final String description;

  factory Match.fromJson(Map<String, dynamic> json) => Match(
        id: json['id'] as String,
        date: Day.parse(json['date'] as String),
        startsAt: HourMinute.parse(json['starts_at'] as String),
        endsAt: HourMinute.parse(json['ends_at'] as String),
        opponent: json['opponent'] as String,
        description: json['description'] as String? ?? '',
      );
}

class Rental {
  const Rental({
    required this.id,
    required this.renterName,
    required this.lanes,
    required this.date,
    required this.weekday,
    required this.startsAt,
    required this.endsAt,
    required this.validFrom,
    required this.validUntil,
    required this.note,
  });

  final String id;
  final String renterName;
  final List<int> lanes;

  /// Exactly one of [date] (one-time) and [weekday] (weekly, ISO) is set —
  /// enforced by a DB check constraint.
  final Day? date;
  final int? weekday;
  final HourMinute startsAt;
  final HourMinute endsAt;
  final Day? validFrom;
  final Day? validUntil;
  final String note;

  bool occursOn(Day day) {
    if (date != null) return date == day;
    if (weekday != day.weekday) return false;
    if (validFrom != null && day.isBefore(validFrom!)) return false;
    if (validUntil != null && day.isAfter(validUntil!)) return false;
    return true;
  }

  factory Rental.fromJson(Map<String, dynamic> json) => Rental(
        id: json['id'] as String,
        renterName: json['renter_name'] as String,
        lanes: (json['lanes'] as List).cast<int>(),
        date: json['date'] == null ? null : Day.parse(json['date'] as String),
        weekday: json['weekday'] as int?,
        startsAt: HourMinute.parse(json['starts_at'] as String),
        endsAt: HourMinute.parse(json['ends_at'] as String),
        validFrom: json['valid_from'] == null
            ? null
            : Day.parse(json['valid_from'] as String),
        validUntil: json['valid_until'] == null
            ? null
            : Day.parse(json['valid_until'] as String),
        note: json['note'] as String? ?? '',
      );
}

class Reservation {
  const Reservation({
    required this.id,
    required this.playerId,
    required this.date,
    required this.blockId,
    required this.lane,
    required this.createdVia,
    required this.createdAt,
    this.cancelledAt,
    this.cancelledVia,
    this.cancelNote = '',
  });

  final String id;
  final String playerId;
  final Day date;
  final String blockId;
  final int lane;
  final String createdVia;
  final DateTime createdAt;
  final DateTime? cancelledAt;
  final String? cancelledVia;
  final String cancelNote;

  bool get isLive => cancelledAt == null;

  factory Reservation.fromJson(Map<String, dynamic> json) => Reservation(
        id: json['id'] as String,
        playerId: json['player_id'] as String,
        date: Day.parse(json['date'] as String),
        blockId: json['block_id'] as String,
        lane: json['lane'] as int,
        createdVia: json['created_via'] as String,
        createdAt: DateTime.parse(json['created_at'] as String),
        cancelledAt: json['cancelled_at'] == null
            ? null
            : DateTime.parse(json['cancelled_at'] as String),
        cancelledVia: json['cancelled_via'] as String?,
        cancelNote: json['cancel_note'] as String? ?? '',
      );
}
```

Note: `ScheduleSettings.defaults` as `static const` requires a `const` Set literal — that compiles (`{1, 2, 4}` is a const set in a const context). If the analyzer complains, switch to `static final`.

- [ ] **Step 4: Run tests, verify they pass**

```bash
flutter test
```
Expected: `All tests passed!`

- [ ] **Step 5: Commit**

```bash
git add lib/domain/ test/ && git commit -m "feat: domain models with tests"
```

---

### Task 4: Complete Supabase schema

**Files:**
- Create: `supabase/migrations/0001_schema.sql`

**Interfaces:**
- Consumes: nothing (SQL only)
- Produces: tables `profiles, schedule_settings, time_blocks, day_overrides, matches, rentals, reservations`; view `players`; helpers `is_approved(), is_admin(), is_kiosk(), is_approved_or_kiosk()`; RPCs `register_profile(p_display_name, p_club), approve_player(p_user_id), set_role(p_user_id, p_role), create_reservation(p_player_id, p_date, p_block_id, p_lane), cancel_reservation(p_id, p_note), set_day_override(p_date, p_closed, p_reason, p_block_ids), monthly_attendance(p_year, p_month)`

- [ ] **Step 1: Write `supabase/migrations/0001_schema.sql`**

Mirror the style of `/Users/mvazan/Home/terminator/supabase/migrations/0001_schema.sql` (sections: extensions → tables → functions → triggers → RLS → realtime). Full content:

```sql
-- Rezervátor — canonical schema. Training reservations for one bowling alley.
-- Access model: magic-link auth + admin approval. Roles: player / admin /
-- kiosk. The virtual schedule = settings + blocks + overrides + matches +
-- rentals + reservations; there are no materialized slot rows.
-- Reservations are mutated ONLY through RPCs (validation lives server-side).

create extension if not exists pgcrypto;
create extension if not exists pg_net;

-- ---------------------------------------------------------------------------
-- Tables
-- ---------------------------------------------------------------------------

create table profiles (
  id uuid primary key references auth.users (id) on delete cascade,
  display_name text not null,
  club text not null default '',
  email text not null default '',
  role text not null default 'player' check (role in ('player', 'admin', 'kiosk')),
  status text not null default 'pending' check (status in ('pending', 'approved')),
  fcm_token text,
  approved_by uuid references profiles (id),
  approved_at timestamptz,
  created_at timestamptz not null default now()
);

-- Singleton alley configuration (readable by players and the kiosk).
create table schedule_settings (
  id boolean primary key default true check (id),
  lane_count smallint not null default 4 check (lane_count between 1 and 12),
  training_weekdays smallint[] not null default '{1,2,4}',  -- ISO: 1=Mon..7=Sun
  booking_horizon_days smallint not null default 14
    check (booking_horizon_days between 1 and 90),
  max_active_reservations smallint not null default 3
    check (max_active_reservations between 1 and 50)
);
insert into schedule_settings default values;

-- Standard training blocks. Deactivate instead of delete once referenced
-- (reservations FK here with on delete restrict). Inactive blocks stay
-- selectable in day overrides ("special" blocks for one date).
create table time_blocks (
  id uuid primary key default gen_random_uuid(),
  starts_at time not null,
  ends_at time not null check (ends_at > starts_at),
  position smallint not null,
  active boolean not null default true
);

-- Per-date exception. Row absent -> weekday rule from settings.
-- closed -> closed with reason. Open -> block_ids (null = default blocks).
create table day_overrides (
  date date primary key,
  closed boolean not null default false,
  reason text not null default '',
  block_ids uuid[],
  created_by uuid not null references profiles (id),
  created_at timestamptz not null default now()
);

-- League matches block ALL lanes and are shown even on closed days
-- (spectators want to see who plays). import_key = idempotency hook for a
-- future federation-file importer.
create table matches (
  id uuid primary key default gen_random_uuid(),
  date date not null,
  starts_at time not null,
  ends_at time not null check (ends_at > starts_at),
  opponent text not null,
  description text not null default '',
  import_key text unique,
  created_by uuid not null references profiles (id),
  created_at timestamptz not null default now()
);
create index matches_date_idx on matches (date);

-- Public renters are not users; the admin books on their behalf.
-- One-time (date) XOR weekly recurring (weekday within valid window).
create table rentals (
  id uuid primary key default gen_random_uuid(),
  renter_name text not null,
  lanes smallint[] not null check (cardinality(lanes) > 0),
  date date,
  weekday smallint check (weekday between 1 and 7),
  starts_at time not null,
  ends_at time not null check (ends_at > starts_at),
  valid_from date,
  valid_until date,
  note text not null default '',
  created_by uuid not null references profiles (id),
  created_at timestamptz not null default now(),
  check ((date is null) <> (weekday is null))
);

create table reservations (
  id uuid primary key default gen_random_uuid(),
  player_id uuid not null references profiles (id),
  date date not null,
  block_id uuid not null references time_blocks (id) on delete restrict,
  lane smallint not null check (lane >= 1),
  created_via text not null check (created_via in ('app', 'kiosk', 'admin')),
  created_by uuid not null references profiles (id),
  created_at timestamptz not null default now(),
  cancelled_at timestamptz,
  cancelled_via text check (cancelled_via in ('app', 'one_click', 'admin')),
  cancel_note text not null default ''
);

-- The airtight double-booking backstop: two players tapping the same free
-- cell race on this index; the loser gets a friendly 'slot_taken' error.
create unique index reservations_slot_live_idx
  on reservations (date, block_id, lane) where cancelled_at is null;
create index reservations_player_idx on reservations (player_id, date);
create index reservations_date_idx on reservations (date);

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

create or replace function is_approved()
returns boolean
language sql stable security definer set search_path = public
as $$
  select exists (
    select 1 from profiles where id = auth.uid() and status = 'approved'
  );
$$;

create or replace function is_admin()
returns boolean
language sql stable security definer set search_path = public
as $$
  select exists (
    select 1 from profiles
    where id = auth.uid() and role = 'admin' and status = 'approved'
  );
$$;

create or replace function is_kiosk()
returns boolean
language sql stable security definer set search_path = public
as $$
  select exists (
    select 1 from profiles where id = auth.uid() and role = 'kiosk'
  );
$$;

create or replace function is_approved_or_kiosk()
returns boolean
language sql stable security definer set search_path = public
as $$
  select exists (
    select 1 from profiles
    where id = auth.uid() and (status = 'approved' or role = 'kiosk')
  );
$$;

-- Name directory safe for every session incl. the kiosk: no emails, no
-- tokens, no kiosk account itself. Owned by postgres -> bypasses profiles RLS.
create view players as
  select id, display_name, club
  from profiles
  where status = 'approved' and role <> 'kiosk';
revoke all on players from anon;
grant select on players to authenticated;

-- ---------------------------------------------------------------------------
-- RPCs
-- ---------------------------------------------------------------------------

-- First sign-in: create the caller's profile. The very first user becomes
-- an auto-approved admin (founder pattern); everyone else waits for approval.
create or replace function register_profile(p_display_name text, p_club text default '')
returns profiles
language plpgsql security definer set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_profile profiles;
  v_first boolean;
begin
  if v_uid is null then
    raise exception 'not_authenticated';
  end if;

  select * into v_profile from profiles where id = v_uid;
  if found then
    return v_profile;
  end if;

  if trim(p_display_name) = '' then
    raise exception 'empty_display_name';
  end if;

  select not exists (select 1 from profiles where status = 'approved')
    into v_first;

  insert into profiles (id, display_name, club, email, role, status, approved_at)
  values (
    v_uid,
    trim(p_display_name),
    trim(coalesce(p_club, '')),
    coalesce(auth.email(), ''),
    case when v_first then 'admin' else 'player' end,
    case when v_first then 'approved' else 'pending' end,
    case when v_first then now() end
  )
  returning * into v_profile;

  return v_profile;
end;
$$;

create or replace function approve_player(p_user_id uuid)
returns void
language plpgsql security definer set search_path = public
as $$
begin
  if not is_admin() then
    raise exception 'not_allowed';
  end if;

  update profiles
  set status = 'approved', approved_by = auth.uid(), approved_at = now()
  where id = p_user_id and status = 'pending';
end;
$$;

-- Promote/demote roles (second admin, the kiosk account). Kiosk accounts are
-- also force-approved so is_approved_or_kiosk() reads stay simple.
create or replace function set_role(p_user_id uuid, p_role text)
returns void
language plpgsql security definer set search_path = public
as $$
begin
  if not is_admin() then
    raise exception 'not_allowed';
  end if;
  if p_role not in ('player', 'admin', 'kiosk') then
    raise exception 'invalid_role';
  end if;
  if p_user_id = auth.uid() and p_role <> 'admin' then
    raise exception 'cannot_demote_self';
  end if;

  update profiles
  set role = p_role,
      status = case when p_role = 'kiosk' then 'approved' else status end
  where id = p_user_id;
end;
$$;

-- The single write path for bookings. Authorization: approved player books
-- SELF; admin books anyone; kiosk books any approved player. Validates the
-- day, block, lane, collisions, horizon and per-player limit in one
-- transaction; the partial unique index catches the tap-race.
create or replace function create_reservation(
  p_player_id uuid, p_date date, p_block_id uuid, p_lane smallint
)
returns reservations
language plpgsql security definer set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_caller profiles;
  v_settings schedule_settings;
  v_block time_blocks;
  v_override day_overrides;
  v_via text;
  v_today date := (now() at time zone 'Europe/Prague')::date;
  v_active_count int;
  v_block_ok boolean;
  v_res reservations;
begin
  if v_uid is null then
    raise exception 'not_authenticated';
  end if;
  select * into v_caller from profiles where id = v_uid;
  if not found then
    raise exception 'no_profile';
  end if;

  if v_caller.role = 'admin' and v_caller.status = 'approved' then
    v_via := case when p_player_id = v_uid then 'app' else 'admin' end;
  elsif v_caller.role = 'kiosk' then
    v_via := 'kiosk';
  elsif v_caller.status = 'approved' and p_player_id = v_uid then
    v_via := 'app';
  else
    raise exception 'not_allowed';
  end if;

  if not exists (
    select 1 from profiles
    where id = p_player_id and status = 'approved' and role <> 'kiosk'
  ) then
    raise exception 'player_not_approved';
  end if;

  select * into v_settings from schedule_settings;
  select * into v_block from time_blocks where id = p_block_id;
  if not found then
    raise exception 'unknown_block';
  end if;
  if p_lane < 1 or p_lane > v_settings.lane_count then
    raise exception 'invalid_lane';
  end if;

  select * into v_override from day_overrides where date = p_date;
  if found then
    if v_override.closed then
      raise exception 'day_closed';
    end if;
    v_block_ok := case
      when v_override.block_ids is null then v_block.active
      else p_block_id = any (v_override.block_ids)
    end;
  else
    if not (extract(isodow from p_date)::smallint = any (v_settings.training_weekdays)) then
      raise exception 'day_closed';
    end if;
    v_block_ok := v_block.active;
  end if;
  if not v_block_ok then
    raise exception 'invalid_block';
  end if;

  if v_caller.role <> 'admin' then
    if p_date < v_today then
      raise exception 'date_past';
    end if;
    if p_date > v_today + v_settings.booking_horizon_days then
      raise exception 'beyond_horizon';
    end if;
    select count(*) into v_active_count
    from reservations
    where player_id = p_player_id and cancelled_at is null and date >= v_today;
    if v_active_count >= v_settings.max_active_reservations then
      raise exception 'limit_reached';
    end if;
  end if;

  if exists (
    select 1 from matches m
    where m.date = p_date
      and m.starts_at < v_block.ends_at and m.ends_at > v_block.starts_at
  ) then
    raise exception 'blocked_by_match';
  end if;

  if exists (
    select 1 from rentals r
    where (
        (r.date is not null and r.date = p_date)
        or (
          r.weekday is not null
          and r.weekday = extract(isodow from p_date)::smallint
          and (r.valid_from is null or p_date >= r.valid_from)
          and (r.valid_until is null or p_date <= r.valid_until)
        )
      )
      and p_lane = any (r.lanes)
      and r.starts_at < v_block.ends_at and r.ends_at > v_block.starts_at
  ) then
    raise exception 'blocked_by_rental';
  end if;

  begin
    insert into reservations (player_id, date, block_id, lane, created_via, created_by)
    values (p_player_id, p_date, p_block_id, p_lane, v_via, v_uid)
    returning * into v_res;
  exception when unique_violation then
    raise exception 'slot_taken';
  end;

  return v_res;
end;
$$;

-- Owner cancels own reservation until the block starts; admin cancels
-- anything anytime (a retro-cancel = marking a no-show, note e.g. 'nepřišel').
-- The kiosk role cannot cancel at all.
create or replace function cancel_reservation(p_id uuid, p_note text default '')
returns void
language plpgsql security definer set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_caller profiles;
  v_res reservations;
  v_block time_blocks;
  v_via text;
  v_now timestamptz := now();
  v_starts timestamptz;
begin
  if v_uid is null then
    raise exception 'not_authenticated';
  end if;
  select * into v_caller from profiles where id = v_uid;
  if not found then
    raise exception 'no_profile';
  end if;

  select * into v_res from reservations where id = p_id;
  if not found then
    raise exception 'not_found';
  end if;
  if v_res.cancelled_at is not null then
    return;  -- already cancelled, idempotent
  end if;

  if v_caller.role = 'admin' and v_caller.status = 'approved' then
    v_via := 'admin';
  elsif v_res.player_id = v_uid and v_caller.status = 'approved' then
    select * into v_block from time_blocks where id = v_res.block_id;
    v_starts := (v_res.date + v_block.starts_at) at time zone 'Europe/Prague';
    if v_now >= v_starts then
      raise exception 'too_late';
    end if;
    v_via := 'app';
  else
    raise exception 'not_allowed';
  end if;

  update reservations
  set cancelled_at = v_now, cancelled_via = v_via, cancel_note = trim(coalesce(p_note, ''))
  where id = p_id;
end;
$$;

-- Upsert a per-date exception and cancel reservations it invalidates, so
-- affected players get notified (via the reservations UPDATE webhook later).
create or replace function set_day_override(
  p_date date, p_closed boolean, p_reason text default '', p_block_ids uuid[] default null
)
returns void
language plpgsql security definer set search_path = public
as $$
begin
  if not is_admin() then
    raise exception 'not_allowed';
  end if;

  insert into day_overrides (date, closed, reason, block_ids, created_by)
  values (p_date, p_closed, trim(coalesce(p_reason, '')), p_block_ids, auth.uid())
  on conflict (date) do update
    set closed = excluded.closed,
        reason = excluded.reason,
        block_ids = excluded.block_ids,
        created_by = excluded.created_by,
        created_at = now();

  update reservations r
  set cancelled_at = now(),
      cancelled_via = 'admin',
      cancel_note = coalesce(nullif(trim(p_reason), ''), 'změna rozvrhu')
  where r.date = p_date
    and r.cancelled_at is null
    and (p_closed or (p_block_ids is not null and not (r.block_id = any (p_block_ids))));
end;
$$;

-- Monthly attendance: uncancelled reservation = attended. Admin-only.
create or replace function monthly_attendance(p_year int, p_month int)
returns table (player_id uuid, display_name text, club text, attended bigint)
language plpgsql stable security definer set search_path = public
as $$
begin
  if not is_admin() then
    raise exception 'not_allowed';
  end if;

  return query
  select p.id, p.display_name, p.club, count(r.id)
  from profiles p
  join reservations r on r.player_id = p.id
  where r.cancelled_at is null
    and extract(year from r.date)::int = p_year
    and extract(month from r.date)::int = p_month
    and r.date <= (now() at time zone 'Europe/Prague')::date
  group by p.id, p.display_name, p.club
  order by count(r.id) desc, p.display_name;
end;
$$;

-- ---------------------------------------------------------------------------
-- Conflict triggers: a new/edited match or rental cancels the live
-- reservations it overlaps, so nobody is silently double-booked.
-- ---------------------------------------------------------------------------

create or replace function cancel_res_for_match()
returns trigger
language plpgsql security definer set search_path = public
as $$
begin
  update reservations r
  set cancelled_at = now(), cancelled_via = 'admin',
      cancel_note = 'zápas: ' || new.opponent
  from time_blocks b
  where r.block_id = b.id
    and r.cancelled_at is null
    and r.date = new.date
    and b.starts_at < new.ends_at and b.ends_at > new.starts_at;
  return new;
end;
$$;

create trigger match_conflicts
  after insert or update on matches
  for each row execute function cancel_res_for_match();

create or replace function cancel_res_for_rental()
returns trigger
language plpgsql security definer set search_path = public
as $$
begin
  update reservations r
  set cancelled_at = now(), cancelled_via = 'admin',
      cancel_note = 'pronájem: ' || new.renter_name
  from time_blocks b
  where r.block_id = b.id
    and r.cancelled_at is null
    and r.lane = any (new.lanes)
    and b.starts_at < new.ends_at and b.ends_at > new.starts_at
    and (
      (new.date is not null and r.date = new.date)
      or (
        new.weekday is not null
        and extract(isodow from r.date)::smallint = new.weekday
        and (new.valid_from is null or r.date >= new.valid_from)
        and (new.valid_until is null or r.date <= new.valid_until)
      )
    );
  return new;
end;
$$;

create trigger rental_conflicts
  after insert or update on rentals
  for each row execute function cancel_res_for_rental();

-- ---------------------------------------------------------------------------
-- Notification webhook (Edge Function `notify` arrives in Phase 3; failing
-- posts are async and never block the write). SETUP.md tells the user to
-- replace <PROJECT_REF> and <WEBHOOK_SECRET> before running this file.
-- ---------------------------------------------------------------------------

create or replace function notify_webhook()
returns trigger
language plpgsql security definer set search_path = public
as $$
begin
  perform net.http_post(
    url := 'https://<PROJECT_REF>.supabase.co/functions/v1/notify',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'x-webhook-secret', '<WEBHOOK_SECRET>'
    ),
    body := jsonb_build_object(
      'type', tg_op,
      'table', tg_table_name,
      'schema', tg_table_schema,
      'record', case when tg_op = 'DELETE' then null else to_jsonb(new) end,
      'old_record', case when tg_op = 'INSERT' then null else to_jsonb(old) end
    )
  );
  return coalesce(new, old);
end;
$$;

create trigger notify_profiles
  after insert on profiles
  for each row execute function notify_webhook();
create trigger notify_reservations
  after insert or update on reservations
  for each row execute function notify_webhook();

-- ---------------------------------------------------------------------------
-- Row Level Security. Reservations have NO write policies on purpose:
-- all mutations flow through the RPCs above.
-- ---------------------------------------------------------------------------

alter table profiles          enable row level security;
alter table schedule_settings enable row level security;
alter table time_blocks       enable row level security;
alter table day_overrides     enable row level security;
alter table matches           enable row level security;
alter table rentals           enable row level security;
alter table reservations      enable row level security;

-- profiles: own row (needed while pending) or admin. Names for everyone else
-- come from the `players` view. Column grants keep role/status/email writes
-- out of reach (those go through RPCs).
revoke update on profiles from authenticated;
grant update (display_name, club, fcm_token) on profiles to authenticated;

create policy profiles_select on profiles for select
  using (id = auth.uid() or is_admin());
create policy profiles_update_own on profiles for update
  using (id = auth.uid()) with check (id = auth.uid());

create policy settings_select on schedule_settings for select
  using (is_approved_or_kiosk());
create policy settings_update on schedule_settings for update
  using (is_admin()) with check (is_admin());

create policy blocks_select on time_blocks for select
  using (is_approved_or_kiosk());
create policy blocks_insert on time_blocks for insert with check (is_admin());
create policy blocks_update on time_blocks for update
  using (is_admin()) with check (is_admin());
create policy blocks_delete on time_blocks for delete using (is_admin());

create policy overrides_select on day_overrides for select
  using (is_approved_or_kiosk());
create policy overrides_insert on day_overrides for insert with check (is_admin());
create policy overrides_update on day_overrides for update
  using (is_admin()) with check (is_admin());
create policy overrides_delete on day_overrides for delete using (is_admin());

create policy matches_select on matches for select
  using (is_approved_or_kiosk());
create policy matches_insert on matches for insert with check (is_admin());
create policy matches_update on matches for update
  using (is_admin()) with check (is_admin());
create policy matches_delete on matches for delete using (is_admin());

create policy rentals_select on rentals for select
  using (is_approved_or_kiosk());
create policy rentals_insert on rentals for insert with check (is_admin());
create policy rentals_update on rentals for update
  using (is_admin()) with check (is_admin());
create policy rentals_delete on rentals for delete using (is_admin());

create policy reservations_select on reservations for select
  using (is_approved_or_kiosk());
-- no insert/update/delete policies: RPC only.

-- ---------------------------------------------------------------------------
-- Realtime
-- ---------------------------------------------------------------------------

alter publication supabase_realtime add table
  profiles, schedule_settings, time_blocks, day_overrides,
  matches, rentals, reservations;
```

- [ ] **Step 2: Verify (static)**

No local Postgres in this phase — verification is (a) careful read-through against the spec's table list, and (b) the schema applies cleanly at the user setup checkpoint (Task 10). Check now: every table in the spec exists here; every RPC named in the Interfaces block exists; `reservations` has no insert/update policy.

- [ ] **Step 3: Commit**

```bash
git add supabase/ && git commit -m "feat: complete supabase schema (tables, rpcs, rls, realtime)"
```

---

### Task 5: Data layer — providers + Api

**Files:**
- Create: `lib/data/providers.dart`

**Interfaces:**
- Consumes: models from Task 3
- Produces: `authStateProvider`, `currentUserId`, `myProfileProvider` (StreamProvider\<Profile?\>), `profilesProvider` (StreamProvider\<List\<Profile\>\> — under RLS non-admins only ever receive their own row; used by the admin players screen), `settingsProvider` (StreamProvider\<ScheduleSettings?\>), `timeBlocksProvider` (StreamProvider\<List\<TimeBlock\>\> sorted by position), `playersProvider` (FutureProvider\<List\<PlayerName\>\>), `Api.sendMagicLink(email, redirectTo)`, `Api.signOut()`, `Api.registerProfile(displayName, club)`, `Api.approvePlayer(userId)`, `Api.updateFcmToken(token)`

- [ ] **Step 1: Write `lib/data/providers.dart`**

Mirror the header comment + structure of `/Users/mvazan/Home/terminator/lib/data/providers.dart`. Full content:

```dart
/// Riverpod providers over Supabase.
///
/// Data strategy for a ~50-person alley: stream whole (tiny) tables via
/// Supabase Realtime and filter/join client-side. Reservations will be
/// streamed per-week (Phase 1) so history growth never bloats the stream.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../domain/models.dart';

SupabaseClient get _db => Supabase.instance.client;

final authStateProvider = StreamProvider<AuthState>(
  (ref) => _db.auth.onAuthStateChange,
);

String? get currentUserId => _db.auth.currentUser?.id;

/// The signed-in user's profile row (null before registration).
/// Live — flips when approved or when the role changes.
final myProfileProvider = StreamProvider<Profile?>((ref) {
  final auth = ref.watch(authStateProvider).value;
  final uid = auth?.session?.user.id ?? currentUserId;
  if (uid == null) return Stream.value(null);
  return _db
      .from('profiles')
      .stream(primaryKey: ['id'])
      .eq('id', uid)
      .map((rows) => rows.isEmpty ? null : Profile.fromJson(rows.first));
});

/// All profile rows the caller may see. Admins receive everyone (drives the
/// approval screen); regular players only receive their own row under RLS.
final profilesProvider = StreamProvider<List<Profile>>((ref) {
  return _db.from('profiles').stream(primaryKey: ['id']).map(
      (rows) => rows.map(Profile.fromJson).toList()
        ..sort((a, b) => a.displayName.compareTo(b.displayName)));
});

/// Alley configuration singleton (null until the backend is seeded).
final settingsProvider = StreamProvider<ScheduleSettings?>((ref) {
  return _db.from('schedule_settings').stream(primaryKey: ['id']).map(
      (rows) => rows.isEmpty ? null : ScheduleSettings.fromJson(rows.first));
});

final timeBlocksProvider = StreamProvider<List<TimeBlock>>((ref) {
  return _db.from('time_blocks').stream(primaryKey: ['id']).map(
      (rows) => rows.map(TimeBlock.fromJson).toList()
        ..sort((a, b) => a.position.compareTo(b.position)));
});

/// Approved player names from the `players` view. Views cannot stream —
/// re-read on screen entry (and on kiosk idle reset in Phase 4).
final playersProvider = FutureProvider<List<PlayerName>>((ref) async {
  final rows = await _db.from('players').select();
  return (rows as List)
      .map((r) => PlayerName.fromJson(r as Map<String, dynamic>))
      .toList()
    ..sort((a, b) => a.displayName.compareTo(b.displayName));
});

// ---------------------------------------------------------------------------
// Actions (writes)
// ---------------------------------------------------------------------------

class Api {
  static Future<void> sendMagicLink(String email, String redirectTo) =>
      _db.auth.signInWithOtp(email: email, emailRedirectTo: redirectTo);

  static Future<void> signOut() => _db.auth.signOut();

  static Future<void> registerProfile(String displayName, String club) =>
      _db.rpc('register_profile', params: {
        'p_display_name': displayName,
        'p_club': club,
      });

  static Future<void> approvePlayer(String userId) =>
      _db.rpc('approve_player', params: {'p_user_id': userId});

  static Future<void> updateFcmToken(String? token) async {
    final uid = currentUserId;
    if (uid == null) return;
    await _db.from('profiles').update({'fcm_token': token}).eq('id', uid);
  }
}
```

- [ ] **Step 2: Verify**

```bash
flutter analyze
```
Expected: `No issues found!`

- [ ] **Step 3: Commit**

```bash
git add lib/data/ && git commit -m "feat: riverpod data layer and api actions"
```

---

### Task 6: Auth feature (login → register → waiting → gate)

**Files:**
- Create: `lib/features/auth/login_screen.dart`, `lib/features/auth/register_screen.dart`, `lib/features/auth/waiting_screen.dart`, `lib/features/auth/auth_gate.dart`
- Modify: `lib/main.dart` (route `/` → `AuthGate`, delete `_Home`)

**Interfaces:**
- Consumes: `Api.sendMagicLink/registerProfile/signOut`, `authStateProvider`, `myProfileProvider`, `AppConfig.authRedirectUrl`
- Produces: `AuthGate` widget (used by router); routes users: no session → `LoginScreen`, no profile → `RegisterScreen`, pending → `WaitingScreen`, role kiosk → `_KioskPlaceholder` (inline stub, replaced in Phase 4), else → `HomeShell` (Task 7)

- [ ] **Step 1: `login_screen.dart`**

Copy `/Users/mvazan/Home/terminator/lib/features/auth/login_screen.dart` VERBATIM, then apply exactly these changes:
1. Replace the logo `Center(child: ClipRRect(...Image.asset(...)))` widget with: `const Text('🎳', textAlign: TextAlign.center, style: TextStyle(fontSize: 96)),`
2. `Text('Termínátor', ...)` → `Text('Rezervátor', ...)`
3. Tagline `'Hasta la vista, prázdná dráha.'` → `'Kuželna na klik.'`
4. Keep everything else (error handling of expired magic links is load-bearing).

- [ ] **Step 2: `register_screen.dart`**

Adapted from terminator's `join_screen.dart` — no invite code, instead name + optional club:

```dart
import 'package:flutter/material.dart';

import '../../core/ui.dart';
import '../../data/providers.dart';

/// First sign-in: pick a display name (and optionally a club). The very
/// first user becomes an auto-approved admin; everyone else waits for
/// admin approval.
class RegisterScreen extends StatefulWidget {
  const RegisterScreen({super.key});

  @override
  State<RegisterScreen> createState() => _RegisterScreenState();
}

class _RegisterScreenState extends State<RegisterScreen> {
  final _name = TextEditingController();
  final _club = TextEditingController();
  bool _saving = false;

  @override
  void dispose() {
    _name.dispose();
    _club.dispose();
    super.dispose();
  }

  Future<void> _register() async {
    final name = _name.text.trim();
    if (name.isEmpty) {
      snack(context, 'Vyplň své jméno.');
      return;
    }
    setState(() => _saving = true);
    await tryAction(
        context, () => Api.registerProfile(name, _club.text.trim()));
    // AuthGate re-routes automatically via the profile stream.
    if (mounted) setState(() => _saving = false);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Vítej v Rezervátoru'),
        actions: [
          TextButton(onPressed: Api.signOut, child: const Text('Odhlásit')),
        ],
      ),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 400),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  'Ještě tě neznáme. Napiš své jméno — pod ním tě uvidí '
                  'ostatní v rozvrhu i na kiosku.',
                  style: Theme.of(context).textTheme.bodyLarge,
                ),
                const SizedBox(height: 24),
                TextField(
                  controller: _name,
                  textCapitalization: TextCapitalization.words,
                  decoration: const InputDecoration(
                    labelText: 'Jméno a příjmení',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: _club,
                  textCapitalization: TextCapitalization.words,
                  decoration: const InputDecoration(
                    labelText: 'Oddíl / klub (nepovinné)',
                    border: OutlineInputBorder(),
                  ),
                  onSubmitted: (_) => _register(),
                ),
                const SizedBox(height: 24),
                FilledButton(
                  onPressed: _saving ? null : _register,
                  child: Text(_saving ? 'Ukládám…' : 'Zaregistrovat se'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
```

- [ ] **Step 3: `waiting_screen.dart`**

Copy terminator's `waiting_screen.dart` verbatim, change only the message text to:

```dart
'Správci přišlo upozornění, že ses zaregistroval(a).\n'
'Jakmile tě schválí, pustíme tě dál — obrazovka se přepne sama.',
```

- [ ] **Step 4: `auth_gate.dart`**

Adapted from terminator's `auth_gate.dart` (same live-stream routing), with the role branch:

```dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../data/providers.dart';
import '../../domain/models.dart';
import '../schedule/home_shell.dart';
import 'login_screen.dart';
import 'register_screen.dart';
import 'waiting_screen.dart';

/// Routes by auth/profile state:
/// no session -> login, no profile -> register, pending -> waiting,
/// kiosk role -> kiosk shell (Phase 4 placeholder), else -> the app.
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
        if (p.role == Role.kiosk) return const _KioskPlaceholder();
        if (p.status == ProfileStatus.pending) return const WaitingScreen();
        return const HomeShell();
      },
    );
  }
}

/// Replaced by the real KioskShell in Phase 4.
class _KioskPlaceholder extends StatelessWidget {
  const _KioskPlaceholder();

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      body: Center(child: Text('Kiosk režim přijde ve Fázi 4. 🎳')),
    );
  }
}

class _Splash extends StatelessWidget {
  const _Splash();

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      body: Center(child: Text('🎳', style: TextStyle(fontSize: 64))),
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
```

- [ ] **Step 5: Point the router at AuthGate**

In `lib/main.dart`: delete `_Home`, import `features/auth/auth_gate.dart`, and change the route to:

```dart
GoRoute(
  path: '/',
  builder: (_, __) =>
      AppConfig.hasSupabase ? const AuthGate() : const _NotConfigured(),
),
```

- [ ] **Step 6: Verify** — `flutter analyze` (will fail on missing `home_shell.dart` until Task 7 — implement Tasks 6+7 in one session and commit them separately only once both analyze clean, or create a one-line `HomeShell` stub now and replace it in Task 7).

- [ ] **Step 7: Commit**

```bash
git add lib/ && git commit -m "feat: magic-link auth flow with admin approval gate"
```

---

### Task 7: Static week grid (HomeShell + WeekScreen)

**Files:**
- Create: `lib/features/schedule/home_shell.dart`, `lib/features/schedule/week_screen.dart`

**Interfaces:**
- Consumes: `settingsProvider`, `timeBlocksProvider`, `myProfileProvider`, `defaultTimeBlocks()`, `ScheduleSettings.defaults`, `dayFull`, `today`
- Produces: `HomeShell` (Scaffold: AppBar „Rezervátor", admin-only people icon → `PlayersScreen` (Task 8), logout action, body `WeekScreen`), `WeekScreen` (stateful week navigation ← dnes →; per-day section: open training day → bordered grid rows=blocks × columns=lanes with tappable-looking but inert cells; other days → „Zavřeno" card)

- [ ] **Step 1: `home_shell.dart`**

```dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/providers.dart';
import '../admin/players_screen.dart';
import 'week_screen.dart';

class HomeShell extends ConsumerWidget {
  const HomeShell({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final profile = ref.watch(myProfileProvider).value;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Rezervátor'),
        actions: [
          if (profile?.isAdmin ?? false)
            IconButton(
              icon: const Icon(Icons.group_outlined),
              tooltip: 'Hráči',
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const PlayersScreen()),
              ),
            ),
          IconButton(
            icon: const Icon(Icons.logout),
            tooltip: 'Odhlásit se',
            onPressed: Api.signOut,
          ),
        ],
      ),
      body: const WeekScreen(),
    );
  }
}
```

- [ ] **Step 2: `week_screen.dart`**

```dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/ui.dart';
import '../../data/providers.dart';
import '../../domain/models.dart';

/// Static week view (Phase 0): the grid renders from settings + blocks but
/// cells are inert. Booking arrives in Phase 1, matches/rentals in Phase 2.
class WeekScreen extends ConsumerStatefulWidget {
  const WeekScreen({super.key});

  @override
  ConsumerState<WeekScreen> createState() => _WeekScreenState();
}

class _WeekScreenState extends ConsumerState<WeekScreen> {
  int _weekOffset = 0;

  Day get _monday {
    final t = today();
    return t.addDays(1 - t.weekday + 7 * _weekOffset);
  }

  @override
  Widget build(BuildContext context) {
    final settings =
        ref.watch(settingsProvider).value ?? ScheduleSettings.defaults;
    final dbBlocks = ref.watch(timeBlocksProvider).value ?? const [];
    final blocks = dbBlocks.where((b) => b.active).toList();
    final effectiveBlocks = blocks.isEmpty ? defaultTimeBlocks() : blocks;
    final monday = _monday;

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Row(
            children: [
              IconButton(
                icon: const Icon(Icons.chevron_left),
                onPressed: () => setState(() => _weekOffset--),
              ),
              Expanded(
                child: Text(
                  rangeLabel(monday, monday.addDays(6)),
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              if (_weekOffset != 0)
                TextButton(
                  onPressed: () => setState(() => _weekOffset = 0),
                  child: const Text('dnes'),
                ),
              IconButton(
                icon: const Icon(Icons.chevron_right),
                onPressed: () => setState(() => _weekOffset++),
              ),
            ],
          ),
        ),
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 24),
            itemCount: 7,
            itemBuilder: (context, i) => _DaySection(
              date: monday.addDays(i),
              open: settings.trainingWeekdays.contains(monday.addDays(i).weekday),
              laneCount: settings.laneCount,
              blocks: effectiveBlocks,
            ),
          ),
        ),
      ],
    );
  }
}

class _DaySection extends StatelessWidget {
  const _DaySection({
    required this.date,
    required this.open,
    required this.laneCount,
    required this.blocks,
  });

  final Day date;
  final bool open;
  final int laneCount;
  final List<TimeBlock> blocks;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(dayFull(date),
                style: Theme.of(context)
                    .textTheme
                    .titleSmall
                    ?.copyWith(fontWeight: FontWeight.w700)),
            const SizedBox(height: 8),
            if (!open)
              Text('Zavřeno',
                  style: TextStyle(color: scheme.onSurfaceVariant))
            else
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Table(
                  defaultColumnWidth: const FixedColumnWidth(72),
                  columnWidths: const {0: FixedColumnWidth(100)},
                  border: TableBorder.all(
                      color: scheme.outlineVariant.withValues(alpha: 0.5)),
                  children: [
                    TableRow(
                      children: [
                        const SizedBox.shrink(),
                        for (var lane = 1; lane <= laneCount; lane++)
                          Padding(
                            padding: const EdgeInsets.all(6),
                            child: Text('Dráha $lane',
                                textAlign: TextAlign.center,
                                style: const TextStyle(
                                    fontWeight: FontWeight.w600)),
                          ),
                      ],
                    ),
                    for (final block in blocks)
                      TableRow(
                        children: [
                          Padding(
                            padding: const EdgeInsets.all(6),
                            child: Text(block.label,
                                style: const TextStyle(fontSize: 12)),
                          ),
                          for (var lane = 1; lane <= laneCount; lane++)
                            const SizedBox(height: 40),
                        ],
                      ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}
```

Note: `rangeLabel` comes from `domain/models.dart` (kept from terminator copy); `core/ui.dart` must NOT re-export it (deleted in Task 2), so import both files as shown.

- [ ] **Step 3: Verify** — `flutter analyze` clean (needs Task 8's `players_screen.dart`; as with Task 6, stub or same-session).

- [ ] **Step 4: Commit**

```bash
git add lib/features/schedule/ && git commit -m "feat: static week grid with week navigation"
```

---

### Task 8: Minimal admin players screen (approval)

**Files:**
- Create: `lib/features/admin/players_screen.dart`

**Interfaces:**
- Consumes: `profilesProvider`, `Api.approvePlayer`, `tryAction`
- Produces: `PlayersScreen` — "Čekají na schválení" section (approve button per row) + "Hráči" list (name, club, admin chip)

- [ ] **Step 1: Write `lib/features/admin/players_screen.dart`**

```dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/ui.dart';
import '../../data/providers.dart';
import '../../domain/models.dart';

/// Admin: approve pending registrations, see the member list.
/// (Role management and richer admin tools arrive in Phase 2.)
class PlayersScreen extends ConsumerWidget {
  const PlayersScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final profiles = ref.watch(profilesProvider).value ?? const <Profile>[];
    final pending =
        profiles.where((p) => p.status == ProfileStatus.pending).toList();
    final approved = profiles
        .where((p) =>
            p.status == ProfileStatus.approved && p.role != Role.kiosk)
        .toList();

    return Scaffold(
      appBar: AppBar(title: const Text('Hráči')),
      body: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          if (pending.isNotEmpty) ...[
            Text('Čekají na schválení',
                style: Theme.of(context).textTheme.titleMedium),
            for (final p in pending)
              Card(
                child: ListTile(
                  title: Text(p.displayName),
                  subtitle: p.club.isEmpty ? null : Text(p.club),
                  trailing: FilledButton(
                    onPressed: () => tryAction(
                        context, () => Api.approvePlayer(p.id),
                        success: 'Schváleno.'),
                    child: const Text('Schválit'),
                  ),
                ),
              ),
            const SizedBox(height: 16),
          ],
          Text('Hráči (${approved.length})',
              style: Theme.of(context).textTheme.titleMedium),
          for (final p in approved)
            ListTile(
              title: Text(p.displayName),
              subtitle: p.club.isEmpty ? null : Text(p.club),
              trailing: p.role == Role.admin ? const Chip(label: Text('admin')) : null,
            ),
        ],
      ),
    );
  }
}
```

- [ ] **Step 2: Verify**

```bash
flutter analyze && flutter test
```
Expected: clean + all tests pass. This closes the Task 6/7 stub loop — everything compiles now.

- [ ] **Step 3: Commit**

```bash
git add lib/ && git commit -m "feat: admin approval screen"
```

---

### Task 9: Web/PWA polish, deploy workflow, SETUP.md

**Files:**
- Modify: `web/manifest.json`, `web/index.html`
- Create: `.github/workflows/deploy-web.yml`, `SETUP.md`

**Interfaces:**
- Consumes: nothing new
- Produces: deployable web build; user-facing setup guide

- [ ] **Step 1: `web/manifest.json`** — set `"name": "Rezervátor"`, `"short_name": "Rezervátor"`, `"description": "Rezervace tréninků na kuželně."`, `"theme_color": "#00695C"`, `"background_color": "#ffffff"`. Leave icons as generated.

- [ ] **Step 2: `web/index.html`** — set `<html lang="cs">`, `<title>Rezervátor</title>`, and the meta description to `Rezervace tréninků na kuželně.`

- [ ] **Step 3: `.github/workflows/deploy-web.yml`**

```yaml
name: Deploy web

on:
  push:
    branches: [main]
  workflow_dispatch:

permissions:
  contents: read
  pages: write
  id-token: write

concurrency:
  group: pages
  cancel-in-progress: true

jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: subosito/flutter-action@v2
        with:
          channel: stable
          cache: true
      - run: >
          flutter build web --release
          --base-href /rezervator/
          --dart-define=SUPABASE_URL=${{ secrets.SUPABASE_URL }}
          --dart-define=SUPABASE_ANON_KEY=${{ secrets.SUPABASE_ANON_KEY }}
      - uses: actions/upload-pages-artifact@v3
        with:
          path: build/web

  deploy:
    needs: build
    runs-on: ubuntu-latest
    environment:
      name: github-pages
      url: ${{ steps.deployment.outputs.page_url }}
    steps:
      - id: deployment
        uses: actions/deploy-pages@v4
```

- [ ] **Step 4: `SETUP.md`**

Write in the numbered-clicks style of `/Users/mvazan/Home/terminator/SETUP.md` (read it for tone/format). Sections for Phase 0 (later phases will append):

1. **Supabase projekt** — create project (region Central EU), copy Project URL + anon/publishable key.
2. **Schéma** — in `supabase/migrations/0001_schema.sql` replace `<PROJECT_REF>` with the project ref and `<WEBHOOK_SECRET>` with a random secret (`openssl rand -hex 24` — note it down for Phase 3); paste the whole file into SQL Editor and run. Then seed the initial time blocks with an example INSERT the user edits to their real times:
   ```sql
   insert into time_blocks (starts_at, ends_at, position) values
     ('16:00', '17:00', 0), ('17:00', '18:00', 1), ('18:00', '19:00', 2),
     ('19:00', '20:00', 3), ('20:00', '21:00', 4), ('21:00', '22:00', 5);
   ```
3. **Auth** — Authentication → URL Configuration: add redirect URLs `cz.kuzelky.rezervator://login-callback` and the web origin(s) (e.g. `https://<user>.github.io/rezervator/` and `http://localhost:*` for dev); set up custom SMTP (Gmail app password) for magic-link e-mails; Czech e-mail template.
4. **První spuštění** — `flutter run --dart-define=SUPABASE_URL=… --dart-define=SUPABASE_ANON_KEY=…`; the first signed-in user becomes the admin automatically.
5. **Web na GitHub Pages** — create GitHub repo `rezervator`, push, add repo secrets `SUPABASE_URL` + `SUPABASE_ANON_KEY`, Settings → Pages → Source: GitHub Actions; the workflow deploys on push to main.
6. **Co zatím nefunguje** — notifications (Phase 3), kiosk (Phase 4), reports (Phase 5).

- [ ] **Step 5: Verify + Commit**

```bash
flutter analyze && flutter test
git add -A && git commit -m "feat: pwa manifest, pages deploy workflow, setup guide"
```

---

### Task 10: Final verification + user setup checkpoint

**Files:** none (verification only)

- [ ] **Step 1: Full local verification**

```bash
flutter analyze          # No issues found!
flutter test             # All tests passed!
flutter build web --release --base-href /rezervator/   # Succeeds
flutter build apk --debug                              # Succeeds
```

- [ ] **Step 2: Run the app unconfigured**

```bash
flutter run -d chrome
```
Expected: the `_NotConfigured` screen (no dart-defines) — proves the guard works.

- [ ] **Step 3: USER CHECKPOINT (blocking)**

Ask the user to perform SETUP.md §1–4 (Supabase project + schema + auth config + first run with real dart-defines). Then demo together:
- Sign in with magic link on web (`flutter run -d chrome --dart-define=…`) → register → lands in the app as admin (first user).
- Sign in with a second e-mail (other browser/incognito) → register → waiting screen.
- Admin opens Hráči → Schválit → the second session switches to the grid **by itself** (live stream).

Phase 0 demo complete. Phase 1 (reservations core: `domain/schedule.dart` TDD + booking + realtime) gets its own plan.
