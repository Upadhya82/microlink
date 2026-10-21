import 'package:flutter/material.dart';

import '../../core/models/order.dart';
import '../../core/network/api_client.dart';
import '../../core/network/api_exception.dart';
import '../../core/network/session_manager.dart';
import '../../core/theme/app_spacing.dart';

/// The customer's "I have it" confirmation, shared by the order list and the
/// tracking screen.
///
/// It is the moment the delivery closes: the order becomes `delivered`, and
/// because an agent may hold only one active order at a time, confirming is
/// also what frees the driver to take their next job. Living in one place
/// keeps the wording -- and the warning about the fee -- identical wherever
/// the customer happens to press it.

/// Only the customer who placed the order, and only once the parcel is
/// actually with a driver. Before pickup there is nothing in anyone's hands
/// to receive, and the server refuses it too.
bool canConfirmReceipt(DeliveryOrder order) =>
    SessionManager.instance.userId == order.customerId &&
    (order.status == 'picked_up' || order.status == 'in_transit');

/// Asks the customer to confirm, then records the delivery.
///
/// Returns true when the order was confirmed, so the caller can refresh.
/// Any failure is reported to the customer here and returns false.
Future<bool> confirmOrderReceipt(BuildContext context, DeliveryOrder order) async {
  final messenger = ScaffoldMessenger.of(context);
  final agreed = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text('Got your order?'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            order.totalAmount > 0
                // The fee is cash, hand to hand -- the app never charges it
                // -- so the confirmation has to name it, or a driver can be
                // closed off as done before any money changes hands.
                ? 'Confirm once the order is in your hands and you have paid the '
                    'driver Rs. ${order.totalAmount.toStringAsFixed(2)}.'
                : 'Confirm once the order is in your hands and you have settled '
                    'the agreed fee with the driver.',
          ),
          const SizedBox(height: AppSpacing.sm),
          const Text('This closes the delivery and cannot be undone.'),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogContext, false),
          child: const Text('Not yet'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(dialogContext, true),
          child: const Text('Yes, I have it'),
        ),
      ],
    ),
  );
  if (agreed != true) return false;

  try {
    await ApiClient.instance.post('/delivery/orders/${order.id}/confirm-delivery');
    messenger.showSnackBar(
      const SnackBar(
        content: Text('Delivery confirmed. Your driver is free for their next job.'),
      ),
    );
    return true;
  } on ApiException catch (e) {
    messenger.showSnackBar(SnackBar(content: Text(e.message)));
    return false;
  } catch (_) {
    messenger.showSnackBar(
      const SnackBar(content: Text('Could not confirm your delivery.')),
    );
    return false;
  }
}
