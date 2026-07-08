import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rezervator/domain/palette.dart';

void main() {
  group('ClubColors', () {
    test('has 12 colors and 12 names', () {
      expect(ClubColors.count, 12);
      expect(ClubColors.names, hasLength(12));
    });

    test('of(0, dark) returns the first entry bg/fg', () {
      final (bg, fg) = ClubColors.of(0, Brightness.dark)!;
      expect(bg, const Color(0xFF1E3A8A));
      expect(fg, const Color(0xFFBFDBFE));
    });

    test('of(0, light) returns the first entry light bg/fg', () {
      final (bg, fg) = ClubColors.of(0, Brightness.light)!;
      expect(bg, const Color(0xFFDBEAFE));
      expect(fg, const Color(0xFF1E3A8A));
    });

    test('of(11, ...) is in range for both brightnesses', () {
      expect(ClubColors.of(11, Brightness.dark), isNotNull);
      expect(ClubColors.of(11, Brightness.light), isNotNull);
    });

    test('of returns null for out-of-range indices in both brightnesses', () {
      for (final b in Brightness.values) {
        expect(ClubColors.of(-1, b), isNull); // "no club"
        expect(ClubColors.of(-2, b), isNull); // rental default
        expect(ClubColors.of(12, b), isNull); // past end
      }
    });
  });
}
