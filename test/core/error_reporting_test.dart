import 'dart:io' show SocketException;

import 'package:flutter_test/flutter_test.dart';
import 'package:rezervator/core/error_reporting.dart';

void main() {
  group('isTransientNetworkError — dropped from Sentry', () {
    test('a raw SocketException', () {
      expect(isTransientNetworkError(const SocketException('nope')), isTrue);
    });

    test('gotrue AuthRetryableFetchException wrapping a failed host lookup',
        () {
      // The exact shape seen in Sentry (REZERVATOR-1): a token refresh on a
      // flaky mobile connection.
      const message =
          "AuthRetryableFetchException(message: ClientException with "
          "SocketException: Failed host lookup: "
          "'wgwijvcnslkesyqgaeul.supabase.co' (OS Error: No address "
          "associated with hostname, errno = 7), "
          "uri=https://wgwijvcnslkesyqgaeul.supabase.co/auth/v1/token, "
          "statusCode: null)";
      expect(isTransientNetworkError(_StringError(message)), isTrue);
    });

    test('other connectivity signatures', () {
      for (final m in [
        'Connection refused',
        'Connection reset by peer',
        'Network is unreachable',
        'Connection timed out',
      ]) {
        expect(isTransientNetworkError(_StringError(m)), isTrue, reason: m);
      }
    });
  });

  group('isTransientNetworkError — kept (real bugs)', () {
    test('a plain assertion / logic error', () {
      expect(isTransientNetworkError(ArgumentError('bad input')), isFalse);
      expect(isTransientNetworkError(StateError('nope')), isFalse);
    });

    test('a database RPC error is not a connectivity error', () {
      expect(
        isTransientNetworkError(
            _StringError('PostgrestException: not_allowed')),
        isFalse,
      );
    });

    test('null throwable', () {
      expect(isTransientNetworkError(null), isFalse);
    });
  });
}

/// A throwable whose toString() is a fixed message — mirrors how wrapped
/// exceptions reach Sentry's beforeSend as a string.
class _StringError implements Exception {
  _StringError(this.message);
  final String message;
  @override
  String toString() => message;
}
