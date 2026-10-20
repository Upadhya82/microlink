import 'package:flutter_test/flutter_test.dart';

import 'package:frontend/features/delivery/screens/driver_home_screen.dart';

/// Item 13: a driver's job list is filtered against the position they last
/// shared, so an empty list has to say how old that position is. These
/// check the wording that goes into "...where you were X ago".
void main() {
  final now = DateTime(2026, 10, 19, 12, 0);

  group('sharedAgo', () {
    test('a position shared seconds ago reads as just now', () {
      expect(
        sharedAgo(now.subtract(const Duration(seconds: 20)), now: now),
        'just now',
      );
    });

    test('minutes are singular and plural', () {
      expect(
        sharedAgo(now.subtract(const Duration(minutes: 1)), now: now),
        '1 minute ago',
      );
      expect(
        sharedAgo(now.subtract(const Duration(minutes: 25)), now: now),
        '25 minutes ago',
      );
    });

    test('hours are singular and plural', () {
      expect(
        sharedAgo(now.subtract(const Duration(hours: 1)), now: now),
        '1 hour ago',
      );
      expect(
        sharedAgo(now.subtract(const Duration(hours: 5)), now: now),
        '5 hours ago',
      );
    });

    test('59 minutes is still minutes, 60 is an hour', () {
      expect(
        sharedAgo(now.subtract(const Duration(minutes: 59)), now: now),
        '59 minutes ago',
      );
      expect(
        sharedAgo(now.subtract(const Duration(minutes: 60)), now: now),
        '1 hour ago',
      );
    });

    test('a day old reads as yesterday, older counts days', () {
      expect(
        sharedAgo(now.subtract(const Duration(days: 1)), now: now),
        'yesterday',
      );
      expect(
        sharedAgo(now.subtract(const Duration(days: 4)), now: now),
        '4 days ago',
      );
    });

    test('a stale position from days ago is named as such, not hidden', () {
      // This is the Colombo case: the list was matched against a position
      // from days earlier and the driver was told nothing.
      final message =
          'No orders within 15 km of where you were ${sharedAgo(now.subtract(const Duration(days: 3)), now: now)}.';
      expect(message, 'No orders within 15 km of where you were 3 days ago.');
    });

    test('a clock skewed into the future does not produce nonsense', () {
      expect(
        sharedAgo(now.add(const Duration(minutes: 10)), now: now),
        'just now',
      );
    });
  });
}
