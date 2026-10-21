import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:frontend/core/models/order.dart';
import 'package:frontend/core/models/user.dart';
import 'package:frontend/core/network/session_manager.dart';
import 'package:frontend/features/delivery/confirm_receipt.dart';

/// Who may press "I received my order", and when.
///
/// Confirming is what closes a delivery, and because an agent may hold only
/// one order at a time it is also what frees the driver for their next job
/// -- so offering the button to the wrong person, or at the wrong moment,
/// either strands a driver or ends somebody else's delivery for them.

const _customerId = 'c1';

DeliveryOrder _order({required String status, String customerId = _customerId}) =>
    DeliveryOrder.fromJson({
      'id': '0b0093e5-a8f1-433d-a675-eff8fdbcaa02',
      'customer_id': customerId,
      'shop_id': 's1',
      'agent_id': 'a1',
      'items': const [],
      'delivery_address': '1 Test Rd',
      'delivery_lat': 6.93,
      'delivery_lng': 79.86,
      'status': status,
      'total_amount': 450,
      'created_at': '2026-10-18T10:00:00+00:00',
      'updated_at': '2026-10-18T10:05:00+00:00',
    });

Future<void> _signInAs(String userId, String role) =>
    SessionManager.instance.saveSession(
      token: 'test-token',
      userId: userId,
      role: role,
      name: 'Test',
    );

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await _signInAs(_customerId, roleUser);
  });

  group('the customer who placed the order', () {
    test('can confirm once the parcel is with the driver', () {
      expect(canConfirmReceipt(_order(status: 'picked_up')), isTrue);
      expect(canConfirmReceipt(_order(status: 'in_transit')), isTrue);
    });

    test('cannot confirm before the driver has collected it', () {
      expect(canConfirmReceipt(_order(status: 'pending')), isFalse);
      expect(canConfirmReceipt(_order(status: 'accepted')), isFalse);
    });

    test('cannot confirm an order that is already finished', () {
      expect(canConfirmReceipt(_order(status: 'delivered')), isFalse);
      expect(canConfirmReceipt(_order(status: 'cancelled')), isFalse);
    });
  });

  group('anybody else', () {
    test('another customer is not offered the button', () async {
      await _signInAs('someone-else', roleUser);
      expect(canConfirmReceipt(_order(status: 'in_transit')), isFalse);
    });

    test('the driver cannot confirm receipt on the customer behalf', () async {
      await _signInAs('a1', roleDeliveryAgent);
      expect(canConfirmReceipt(_order(status: 'in_transit')), isFalse);
    });
  });
}
