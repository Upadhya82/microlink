import 'package:flutter_test/flutter_test.dart';

import 'package:frontend/core/constants/app_constants.dart';
import 'package:frontend/core/models/shop.dart';

/// Item 10: a shop needs [AppConstants.minProductsToVerify] listable
/// products before an admin can verify it, and both the owner and the admin
/// are shown how far off it is.
Shop _shop({int? listableProductCount}) => Shop.fromJson({
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
      'listable_product_count': ?listableProductCount,
    });

void main() {
  test('the threshold matches the one shop-service enforces', () {
    expect(AppConstants.minProductsToVerify, 5);
  });

  group('hasEnoughProductsToVerify', () {
    test('exactly the threshold is enough', () {
      expect(
        _shop(listableProductCount: AppConstants.minProductsToVerify)
            .hasEnoughProductsToVerify,
        isTrue,
      );
    });

    test('one short is not', () {
      expect(
        _shop(listableProductCount: AppConstants.minProductsToVerify - 1)
            .hasEnoughProductsToVerify,
        isFalse,
      );
    });

    test('more than enough is enough', () {
      expect(_shop(listableProductCount: 40).hasEnoughProductsToVerify, isTrue);
    });

    test('a shop with nothing listed is not', () {
      expect(_shop(listableProductCount: 0).hasEnoughProductsToVerify, isFalse);
    });

    test('an older response with no count reads as zero, not as ready', () {
      final shop = _shop();
      expect(shop.listableProductCount, 0);
      expect(shop.hasEnoughProductsToVerify, isFalse);
    });
  });

  group('productProgressLabel', () {
    test('counts towards the threshold', () {
      expect(
        _shop(listableProductCount: 3).productProgressLabel,
        '3 of 5 products listed',
      );
    });

    test('reads sensibly at zero and when complete', () {
      expect(
        _shop(listableProductCount: 0).productProgressLabel,
        '0 of 5 products listed',
      );
      expect(
        _shop(listableProductCount: 5).productProgressLabel,
        '5 of 5 products listed',
      );
    });

    test('does not cap the count, so an owner sees their real total', () {
      expect(
        _shop(listableProductCount: 12).productProgressLabel,
        '12 of 5 products listed',
      );
    });
  });
}
