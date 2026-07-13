# Rezervátor — Phase 5 (Reports + Hardening) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:subagent-driven-development. Checkbox steps.

**Goal:** Monthly attendance report with CSV export, stranded-reservation warnings on config shrink (deferred P2 Important), FCM push client (dormant without Firebase config), keepalive workflow, final SETUP.md/README pass.

**Tech:** + `file_saver` package (web download + Android share). FCM: `firebase_core` + `firebase_messaging` (guarded by AppConfig.hasFirebase, no-op on web). Patterns from /Users/mvazan/Home/terminator (push/push.dart, .github/workflows/keepalive.yml).

## Global Constraints

- Repo `/Users/mvazan/Home/rezervator`, branch `phase-1-reservations`. Czech UI. TDD for domain. Analyze "No issues found!" + all tests green each task. Commits end `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.
- Attendance = uncancelled reservation (RPC `monthly_attendance(p_year, p_month)`, admin-only, returns player_id/display_name/club/attended).
- CSV: UTF-8 **BOM** + `;` separator (CZ Excel); fields quoted when containing `;`, `"` (doubled) or newline.

---

### Task 1: Domain — AttendanceRow + CSV (TDD)

**Files:** modify `lib/domain/models.dart`; create `lib/domain/csv.dart`; tests `test/domain/csv_test.dart` (+ extend models_test.dart)

**Interfaces:**
- `AttendanceRow { String playerId, displayName, club; int attended; factory fromJson }` (json keys: player_id, display_name, club, attended)
- `String toCsv(List<List<String>> rows)` — returns `﻿` + rows joined by `\r\n`, fields joined by `;`, a field is wrapped in `"` (inner `"` doubled) iff it contains `;`, `"`, `\n` or `\r`.

- [ ] Tests first (RED):

```dart
// test/domain/csv_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:rezervator/domain/csv.dart';

void main() {
  test('starts with BOM, joins with ; and CRLF', () {
    final csv = toCsv([
      ['Hráč', 'Klub', 'Počet'],
      ['Ján Novák', 'KK Praha', '4'],
    ]);
    expect(csv.startsWith('﻿'), isTrue);
    expect(csv, '﻿Hráč;Klub;Počet\r\nJán Novák;KK Praha;4');
  });

  test('quotes fields with separators and doubles quotes', () {
    expect(toCsv([
      ['a;b', 'say "hi"', 'line\nbreak', 'plain'],
    ]), '﻿"a;b";"say ""hi""";"line\nbreak";plain');
  });
}
```

models_test addition:

```dart
  test('AttendanceRow parses rpc row', () {
    final row = AttendanceRow.fromJson(
        {'player_id': 'p1', 'display_name': 'Ján', 'club': 'KK', 'attended': 3});
    expect(row.attended, 3);
    expect(row.club, 'KK');
  });
```

- [ ] Implement:

```dart
// lib/domain/csv.dart
/// Minimal CSV writer tuned for Czech Excel: UTF-8 BOM + semicolons.
library;

String toCsv(List<List<String>> rows) {
  String field(String value) {
    if (value.contains(';') ||
        value.contains('"') ||
        value.contains('\n') ||
        value.contains('\r')) {
      return '"${value.replaceAll('"', '""')}"';
    }
    return value;
  }

  return '﻿${rows.map((r) => r.map(field).join(';')).join('\r\n')}';
}
```

models.dart append:

```dart
/// One row of the monthly_attendance RPC result.
class AttendanceRow {
  const AttendanceRow({
    required this.playerId,
    required this.displayName,
    required this.club,
    required this.attended,
  });

  final String playerId;
  final String displayName;
  final String club;
  final int attended;

  factory AttendanceRow.fromJson(Map<String, dynamic> json) => AttendanceRow(
        playerId: json['player_id'] as String,
        displayName: json['display_name'] as String,
        club: json['club'] as String? ?? '',
        attended: json['attended'] as int,
      );
}
```

- [ ] GREEN, analyze clean. Commit `feat: attendance row and czech csv writer`.

---

### Task 2: Attendance report screen + CSV export

**Files:** modify `lib/data/providers.dart`, `lib/features/admin/admin_screen.dart`, `pubspec.yaml` (`flutter pub add file_saver`); create `lib/features/admin/report_screen.dart`

**Spec:**
- `Api.monthlyAttendance(int year, int month)` → `_db.rpc('monthly_attendance', params: {'p_year': year, 'p_month': month})` mapped to `List<AttendanceRow>`.
- `ReportScreen` (admin gate `Jen pro správce.` like siblings): AppBar `Docházka`; month navigation row (chevrons + label `„červenec 2026“` — Czech month names const list, state = year+month, init = current month); body = FutureBuilder/async load per month via Api (loading spinner; error Czech + retry): table/ListView rows `pořadí. jméno (klub) — N×`, sorted as returned (RPC sorts by attended desc); empty → `Žádné rezervace v tomto měsíci.`.
- `Export CSV` FilledButton (disabled while loading/empty): builds rows `[['Hráč','Klub','Tréninků'], ...data]` via `toCsv`, saves through `file_saver` (`FileSaver.instance.saveFile(name: 'dochazka-YYYY-MM', bytes: utf8.encode(csv), fileExtension: 'csv', mimeType: MimeType.csv)` — adapt to the package's current API by reading its source in ~/.pub-cache; record exact call in report) → snack `Uloženo.` / error via tryAction pattern.
- AdminScreen menu: add `Docházka` (Icons.fact_check_outlined) → ReportScreen (place after Hráči).

- [ ] Implement; analyze+tests green (no new widget tests mandated). Commit `feat: monthly attendance report with csv export`.

---

### Task 3: Stranded-reservation warnings (deferred P2 Important)

**Files:** modify `lib/data/providers.dart`, `lib/features/admin/settings_screen.dart`, `lib/features/admin/blocks_screen.dart`

**Spec:**
- `Api.futureLiveReservations()` → `_db.from('reservations').select('date, lane, block_id').gte('date', <today sql>).isFilter('cancelled_at', null)` mapped to a light record list (date Day, lane int, blockId String). (Admin RLS allows the read; today = `Day.fromDateTime(DateTime.now()).toSql()` computed at call site — UI layer owns time.)
- `SettingsScreen._save`: after validation, if `laneCount` decreased vs current settings OR any weekday removed → fetch futureLiveReservations, count those with `lane > newLaneCount` OR `!newWeekdays.contains(date.weekday)`; if N > 0 → `confirmDialog(title: 'Pozor — osiřelé rezervace', message: 'N budoucích rezervací zůstane mimo rozvrh (nezobrazí se a nepůjdou zrušit z mřížky). Opravdu uložit?', confirmLabel: 'Uložit i tak')`; abort on decline. (Overrides with custom blocks may keep some visible — the count is a conservative upper bound; say so in a code comment.)
- `BlocksScreen` deactivate toggle (active → false) and the delete-fallback path: fetch futureLiveReservations filtered `blockId == id`; if N > 0 → same warning dialog (`'N budoucích rezervací na tomto bloku zůstane mimo rozvrh. Opravdu deaktivovat?'`). Delete path unaffected when FK already blocks (has any reservations ever).

- [ ] Implement; analyze+tests green. Commit `feat: warn before orphaning reservations`.

---

### Task 4: FCM push client (dormant without config)

**Files:** create `lib/push/push.dart`; modify `lib/main.dart`, `pubspec.yaml` (`flutter pub add firebase_core firebase_messaging`), `android/app/src/main/AndroidManifest.xml` if terminator's needed any push-related entries (mirror check)

**Spec:** Adapt /Users/mvazan/Home/terminator/lib/push/push.dart (READ it): `Push.init()` no-ops unless `AppConfig.hasFirebase && !kIsWeb`; initializes Firebase from the four dart-defines, requests permission, obtains FCM token → `Api.updateFcmToken`, listens to token refresh; on sign-out token clearing already handled? (check terminator — if it clears on logout, mirror by calling `Api.updateFcmToken(null)` in `Api.signOut` BEFORE auth.signOut, guarded hasFirebase && !kIsWeb). Foreground/message-tap routing: SKIP (YAGNI — notification opens app; no deep-link routing this phase; drop terminator's navigatorKey machinery if separable — record what was dropped). `main.dart`: `await Push.init()` after Supabase.initialize (mirrors terminator).

- [ ] Implement; analyze+tests green; `flutter build apk --debug` must still pass (FCM deps affect Android build — verify). Commit `feat: fcm push client (optional via dart-defines)`.

---

### Task 5: Keepalive workflow + SETUP §Fáze 5 + README

**Files:** create `.github/workflows/keepalive.yml`; modify `SETUP.md`, `README.md`

**Spec:**
- keepalive.yml: adapt terminator's (READ /Users/mvazan/Home/terminator/.github/workflows/keepalive.yml) — weekly cron ping keeping the Supabase free-tier project awake; document required secret(s) it uses.
- SETUP.md §Fáze 5: report usage note (Správa → Docházka, export CSV); optional FCM: Firebase project + 4 dart-defines (build args + Pages repo secrets note) + `FIREBASE_SERVICE_ACCOUNT` supabase secret (`supabase secrets set`) enabling push in notify; keepalive workflow enable note; retro no-show how-to (admin tapne obsazenou buňku v minulosti → poznámka `nepřišel` → nepočítá se do docházky). Final pass: 'Co zatím nefunguje' section → replace with 'Hotovo — všechny fáze nasazené' summary or remove.
- README.md: replace scaffold README with a short Czech project intro (co to je, dva režimy, stack, odkaz na SETUP.md a docs/superpowers/specs).

- [ ] Implement; analyze+tests green. Commit `feat: keepalive workflow, final setup guide and readme`.

---

### Task 6: Phase + branch verification

- [ ] `flutter analyze` clean; `flutter test` all green; `flutter build web --release --base-href /rezervator/`; `flutter build apk --debug`.
- [ ] Controller: final whole-branch review, push, PR update.
