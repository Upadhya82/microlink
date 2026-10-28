import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:frontend/core/models/shop.dart';
import 'package:frontend/core/theme/app_theme.dart';
import 'package:frontend/features/shop_discovery/shop_discovery_support.dart';

/// Item 6: a shop nobody has verified says so, and a shop we know nothing
/// about says nothing.
Map<String, dynamic> _json({
  Object? isVerified = _absent,
  Object? delayProne = _absent,
  Object? medianWait = _absent,
}) => {
      'id': 's1',
      'owner_id': 'o1',
      'name': 'Corner Shop',
      'description': '',
      'category': 'grocery',
      'address': '1 Test Rd',
      'latitude': 6.9271,
      'longitude': 79.8612,
      'opening_time': '09:00',
      'closing_time': '18:00',
      'is_open': true,
      'rating_avg': 0,
      'rating_count': 0,
      'created_at': '2026-10-18T10:00:00+00:00',
      'updated_at': '2026-10-18T10:00:00+00:00',
      if (isVerified != _absent) 'is_verified': isVerified,
      if (delayProne != _absent) 'delay_prone': delayProne,
      if (medianWait != _absent) 'median_pickup_wait_min': medianWait,
    };

/// Stands in for "the key is not in the response at all", which is what a
/// page cached before the app read this field looks like.
const Object _absent = Object();

void main() {
  group('Shop.isVerified', () {
    test('a verified shop is parsed as verified', () {
      final shop = Shop.fromJson(_json(isVerified: true));
      expect(shop.isVerified, isTrue);
      expect(shop.showsNotVerifiedChip, isFalse);
      expect(shop.awaitingVerification, isFalse);
    });

    test('an unverified shop shows the chip', () {
      final shop = Shop.fromJson(_json(isVerified: false));
      expect(shop.isVerified, isFalse);
      expect(shop.showsNotVerifiedChip, isTrue);
      expect(shop.awaitingVerification, isTrue);
    });

    test('a missing value is unknown, not unverified', () {
      final shop = Shop.fromJson(_json());
      expect(shop.isVerified, isNull);
      // The important part: a page cached before this shipped must not brand
      // every shop on it.
      expect(shop.showsNotVerifiedChip, isFalse);
      expect(shop.awaitingVerification, isFalse);
    });

    test('a null value is also unknown', () {
      final shop = Shop.fromJson(_json(isVerified: null));
      expect(shop.isVerified, isNull);
      expect(shop.showsNotVerifiedChip, isFalse);
    });
  });

  group('ShopExtras.isVerified', () {
    ShopExtras extras({Object? isVerified = _absent}) =>
        ShopExtras.fromJson(_json(isVerified: isVerified));

    test('the flag is read from the shop response', () {
      expect(extras(isVerified: false).isVerified, isFalse);
      expect(extras(isVerified: true).isVerified, isTrue);
    });

    test('only a definite false shows the chip', () {
      expect(extras(isVerified: false).showsNotVerifiedChip, isTrue);
      expect(extras(isVerified: true).showsNotVerifiedChip, isFalse);
      expect(extras().showsNotVerifiedChip, isFalse);
    });
  });


  group('Item 4: the often-delayed marker', () {
    test('a shop the server marked is flagged, with its wait', () {
      final extras = ShopExtras.fromJson(
        _json(delayProne: true, medianWait: 22.5),
      );
      expect(extras.delayProne, isTrue);
      expect(extras.medianPickupWaitMin, 22.5);
    });

    test('a prompt shop is not flagged', () {
      expect(ShopExtras.fromJson(_json(delayProne: false)).delayProne, isFalse);
    });

    test('an older response with no verdict is not flagged', () {
      // Never mark a shop on a guess: no field means the server has not
      // judged it.
      final extras = ShopExtras.fromJson(_json());
      expect(extras.delayProne, isFalse);
      expect(extras.medianPickupWaitMin, isNull);
    });

    testWidgets('the chip names the wait when there is one', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light,
          home: const Scaffold(
            body: OftenDelayedChip(medianPickupWaitMin: 22.4),
          ),
        ),
      );
      expect(find.text('Often delayed'), findsOneWidget);
      final tooltip = tester.widget<Tooltip>(find.byType(Tooltip));
      expect(tooltip.message, 'Drivers usually wait about 22 minutes for this shop.');
    });

    testWidgets('and says something sensible without one', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light,
          home: const Scaffold(body: OftenDelayedChip()),
        ),
      );
      final tooltip = tester.widget<Tooltip>(find.byType(Tooltip));
      expect(tooltip.message, 'Orders from this shop are often late.');
    });
  });
}
