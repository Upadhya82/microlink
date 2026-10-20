import 'package:flutter_test/flutter_test.dart';

import 'package:frontend/core/models/order.dart';

/// Item 8: a cancelled order says who cancelled it and why.
DeliveryOrder _order({
  String status = 'cancelled',
  String? cancelledBy,
  String? reason,
}) =>
    DeliveryOrder.fromJson({
      'id': '0b0093e5-a8f1-433d-a675-eff8fdbcaa02',
      'customer_id': 'c1',
      'shop_id': 's1',
      'agent_id': null,
      'items': const [],
      'delivery_address': '1 Test Rd',
      'delivery_lat': 6.93,
      'delivery_lng': 79.86,
      'status': status,
      'total_amount': 0,
      'created_at': '2026-10-18T10:00:00+00:00',
      'updated_at': '2026-10-18T10:05:00+00:00',
      'cancelled_by': ?cancelledBy,
      'cancel_reason': ?reason,
      if (cancelledBy != null) 'cancelled_at': '2026-10-18T10:05:00+00:00',
    });

void main() {
  group('parsing', () {
    test('the cancellation fields are read from the server', () {
      final order = _order(cancelledBy: 'shop', reason: 'Out of gas');
      expect(order.cancelledBy, 'shop');
      expect(order.cancelReason, 'Out of gas');
      expect(order.cancelledAt, isNotNull);
      expect(order.isCancelled, isTrue);
    });

    test('an order cancelled before the server recorded it still parses', () {
      final order = _order();
      expect(order.cancelledBy, isNull);
      expect(order.cancelReason, isNull);
      expect(order.cancelledAt, isNull);
    });

    test('a live order has no cancellation fields', () {
      final order = _order(status: 'accepted');
      expect(order.isCancelled, isFalse);
      expect(order.cancellationNote, isNull);
    });
  });

  group('cancellationNote', () {
    test('a shop cancellation names the shop and the reason', () {
      expect(
        _order(cancelledBy: 'shop', reason: 'Out of gas').cancellationNote,
        'Cancelled by the shop: Out of gas',
      );
    });

    test('a shop cancellation without a reason still names the shop', () {
      expect(
        _order(cancelledBy: 'shop').cancellationNote,
        'Cancelled by the shop',
      );
    });

    test('a blank reason is treated as no reason', () {
      expect(
        _order(cancelledBy: 'shop', reason: '   ').cancellationNote,
        'Cancelled by the shop',
      );
    });

    test('the customer is reminded it was their own doing', () {
      expect(
        _order(cancelledBy: 'customer').cancellationNote,
        'You cancelled this order',
      );
    });

    test('an admin cancellation is named as such', () {
      expect(
        _order(cancelledBy: 'admin', reason: 'Duplicate').cancellationNote,
        'Cancelled by an administrator: Duplicate',
      );
    });

    test('the five-minute auto-expiry is not blamed on anyone', () {
      expect(
        _order(
          cancelledBy: 'system',
          reason: 'No delivery agent accepted it within 5 minutes',
        ).cancellationNote,
        'Cancelled automatically: No delivery agent accepted it within 5 minutes',
      );
    });

    test('an unknown canceller produces nothing rather than a guess', () {
      expect(_order(cancelledBy: 'somebody-else').cancellationNote, isNull);
      expect(_order().cancellationNote, isNull);
    });
  });
}
