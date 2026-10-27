import 'package:flutter_test/flutter_test.dart';

import 'package:frontend/core/models/order.dart';

/// Which shop an order came from.
///
/// The customer's order list showed an order reference, a date, a fee and a
/// status, and nothing about the shop at all -- so with two orders open
/// there was no way to tell which was which. delivery-service only ever
/// sent `shop_id`, a UUID, so the app had nothing to show even if it had
/// wanted to. The shop's name is now copied onto the order when it is
/// placed and comes back with it.
Map<String, dynamic> order({
  Object? shopName = 'Thusitha Bakers',
  Object? pickupAddress = 'Diyagama, Homagama',
}) =>
    {
      'id': '9ca3e111-2222-3333-4444-555555555555',
      'customer_id': 'c1',
      'shop_id': '66666666-6666-6666-6666-666666666666',
      'shop_name': shopName,
      'agent_id': null,
      'items': <Map<String, dynamic>>[],
      'pickup_address': pickupAddress,
      'delivery_address': 'No. 11, Diyagama',
      'delivery_lat': 6.83,
      'delivery_lng': 80.01,
      'status': 'pending',
      'total_amount': 100.0,
      'created_at': '2026-10-27T08:00:00Z',
      'updated_at': '2026-10-27T08:00:00Z',
    };

void main() {
  group('parsing', () {
    test('the shop name comes back with the order', () {
      final parsed = DeliveryOrder.fromJson(order());
      expect(parsed.shopName, 'Thusitha Bakers');
    });

    test('an older order with no name still parses', () {
      // Orders placed before the server recorded it send shop_name: null.
      final parsed = DeliveryOrder.fromJson(order(shopName: null));
      expect(parsed.shopName, isNull);
      expect(parsed.shopId, '66666666-6666-6666-6666-666666666666');
    });
  });

  group('what the customer is shown', () {
    test('the name, when there is one', () {
      expect(DeliveryOrder.fromJson(order()).shopLabel, 'Thusitha Bakers');
    });

    test('an older order falls back to the street it was collected from', () {
      // Not the name, but better than a UUID or an empty line.
      final parsed = DeliveryOrder.fromJson(order(shopName: null));
      expect(parsed.shopLabel, 'Diyagama, Homagama');
    });

    test('a blank name is not shown as an empty label', () {
      final parsed = DeliveryOrder.fromJson(order(shopName: '   '));
      expect(parsed.shopLabel, 'Diyagama, Homagama');
    });

    test('nothing to say means no line at all', () {
      final parsed = DeliveryOrder.fromJson(
        order(shopName: null, pickupAddress: null),
      );
      expect(parsed.shopLabel, isNull);
    });

    test('a blank address is nothing to say either', () {
      final parsed = DeliveryOrder.fromJson(
        order(shopName: null, pickupAddress: '  '),
      );
      expect(parsed.shopLabel, isNull);
    });
  });
}
