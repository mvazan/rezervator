import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rezervator/domain/duties.dart';
import 'package:rezervator/domain/models.dart';
import 'package:rezervator/features/schedule/widgets/week_header.dart';

/// The Kalendář week header's duty line (0050): one `labelSmall` line under
/// the range, ellipsised, tinted when it is my duty, opening Služby on tap —
/// in the stacked portrait strip and the one-line landscape strip alike.
void main() {
  // [tappable] false: no onDutyTap at all.
  Widget app(DutyHeader? duty, {VoidCallback? onTap, bool tappable = true}) =>
      MaterialApp(
    home: Scaffold(
      body: WeekHeader(
        monday: Day(2026, 10, 5),
        weekOffset: 0,
        onGo: (_) {},
        trailing: const [],
        duty: duty,
        onDutyTap: tappable ? onTap ?? () {} : null,
      ),
    ),
  );

  void size(WidgetTester tester, Size size) {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  Text line(WidgetTester tester, String text) =>
      tester.widget<Text>(find.text(text));

  testWidgets('no one serves: no line', (tester) async {
    await tester.pumpWidget(app(null));
    expect(find.textContaining('Služba'), findsNothing);
    expect(find.textContaining('Sloužíš'), findsNothing);
  });

  for (final (label, screen) in [
    ('portrait, stacked', const Size(400, 800)),
    ('landscape, one line', const Size(1000, 500)),
  ]) {
    testWidgets('$label: the line under the range, small and ellipsised, '
        'opening Služby', (tester) async {
      size(tester, screen);
      var taps = 0;
      await tester.pumpWidget(
        app(
          const DutyHeader('Služba: Jan Novák a Petr Svoboda'),
          onTap: () => taps++,
        ),
      );

      final text = line(tester, 'Služba: Jan Novák a Petr Svoboda');
      final theme = Theme.of(tester.element(find.byType(WeekHeader)));
      expect(text.maxLines, 1);
      expect(text.overflow, TextOverflow.ellipsis);
      expect(text.style!.fontSize, theme.textTheme.labelSmall!.fontSize);
      expect(text.style!.color, theme.colorScheme.onSurfaceVariant);
      // Under the range, not beside it.
      expect(
        tester.getTopLeft(find.text('Služba: Jan Novák a Petr Svoboda')).dy,
        greaterThan(tester.getBottomLeft(find.textContaining('10.')).dy - 1),
      );

      await tester.tap(find.text('Služba: Jan Novák a Petr Svoboda'));
      expect(taps, 1);
    });

    testWidgets('$label: the line is a button with a roomy hit area across '
        'the nav', (tester) async {
      size(tester, screen);
      var taps = 0;
      await tester.pumpWidget(
        app(const DutyHeader('Služba: Jan Novák'), onTap: () => taps++),
      );

      final text = find.text('Služba: Jan Novák');
      expect(
        find.ancestor(
          of: text,
          matching: find.byWidgetPredicate(
            (w) => w is Semantics && w.properties.button == true,
          ),
        ),
        findsOneWidget,
      );
      final hit = find.ancestor(of: text, matching: find.byType(InkWell));
      final box = tester.getRect(hit);
      expect(box.height, greaterThanOrEqualTo(32));
      // Wider than the glyphs: the whole nav width, not just the text.
      expect(box.width, greaterThan(tester.getSize(text).width + 100));
      // The text itself stays one small line.
      expect(tester.getSize(text).height, lessThan(20));

      await tester.tapAt(box.bottomLeft + const Offset(4, -2));
      await tester.tapAt(box.topRight + const Offset(-4, 2));
      expect(taps, 2);
    });
  }

  testWidgets('without onDutyTap the line is no button to a screen reader',
      (tester) async {
    await tester.pumpWidget(
      app(const DutyHeader('Služba: Jan Novák'), tappable: false),
    );
    expect(find.text('Služba: Jan Novák'), findsOneWidget);
    expect(
      find.ancestor(
        of: find.text('Služba: Jan Novák'),
        matching: find.byWidgetPredicate(
          (w) => w is Semantics && w.properties.button == true,
        ),
      ),
      findsNothing,
    );
  });

  testWidgets('my duty this week is tinted', (tester) async {
    await tester.pumpWidget(
      app(const DutyHeader('Sloužíš ty · do ne 11. 10.', mine: true)),
    );
    final text = line(tester, 'Sloužíš ty · do ne 11. 10.');
    final theme = Theme.of(tester.element(find.byType(WeekHeader)));
    expect(text.style!.color, theme.colorScheme.primary);
    expect(text.style!.fontWeight, FontWeight.w700);
  });

  group('swiping the strip turns the week', () {
    // A host that keeps the week it is told to, like the calendar does.
    Widget host(List<int> moves, {DutyHeader? duty}) => MaterialApp(
          home: Scaffold(
            body: StatefulBuilder(
              builder: (context, setState) => _Calendar(moves: moves, duty: duty),
            ),
          ),
        );

    testWidgets('left: the next week, right: the previous one',
        (tester) async {
      final moves = <int>[];
      await tester.pumpWidget(host(moves));
      await tester.pumpAndSettle();
      expect(find.text('5.10.–11.10.'), findsOneWidget);

      await tester.fling(find.text('5.10.–11.10.'), const Offset(-200, 0), 800);
      await tester.pumpAndSettle();
      expect(moves, [1]);
      expect(find.text('12.10.–18.10.'), findsOneWidget);
      expect(find.text('5.10.–11.10.'), findsNothing);

      await tester.fling(find.text('12.10.–18.10.'), const Offset(200, 0), 800);
      await tester.pumpAndSettle();
      expect(moves, [1, -1]);
      expect(find.text('5.10.–11.10.'), findsOneWidget);
    });

    testWidgets('a swipe on the duty line turns the week too',
        (tester) async {
      final moves = <int>[];
      await tester.pumpWidget(
        host(moves, duty: const DutyHeader('Služba: Jan Novák')),
      );
      await tester.pumpAndSettle();
      await tester.fling(find.text('Služba: Jan Novák'), const Offset(-200, 0), 800);
      await tester.pumpAndSettle();
      expect(moves, [1]);
    });

    testWidgets('a slow drag turns nothing', (tester) async {
      final moves = <int>[];
      await tester.pumpWidget(host(moves));
      await tester.pumpAndSettle();
      final gesture = await tester.startGesture(
        tester.getCenter(find.text('5.10.–11.10.')),
      );
      await gesture.moveBy(const Offset(-40, 0));
      await tester.pump(const Duration(seconds: 2));
      await gesture.up();
      await tester.pumpAndSettle();
      expect(moves, isEmpty);
    });

    testWidgets('the arrows still work', (tester) async {
      final moves = <int>[];
      await tester.pumpWidget(host(moves));
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.chevron_right));
      await tester.pumpAndSettle();
      expect(moves, [1]);
    });
  });
}

class _Calendar extends StatefulWidget {
  const _Calendar({required this.moves, this.duty});

  final List<int> moves;
  final DutyHeader? duty;

  @override
  State<_Calendar> createState() => _CalendarState();
}

class _CalendarState extends State<_Calendar> {
  int _offset = 0;

  @override
  Widget build(BuildContext context) => WeekHeader(
        monday: Day(2026, 10, 5).addDays(7 * _offset),
        weekOffset: _offset,
        onGo: (d) => setState(() {
          widget.moves.add(d);
          _offset += d;
        }),
        trailing: const [],
        duty: widget.duty,
      );
}
