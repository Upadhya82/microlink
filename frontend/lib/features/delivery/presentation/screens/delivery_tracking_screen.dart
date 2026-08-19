import 'dart:async';

import 'package:flutter/material.dart';

import '../../../../core/constants/app_constants.dart';
import '../../../../core/network/api_client.dart';

/// Customer-facing order tracking (SRS REQ-DELIV-5 / 5.6.2).
/// Polls delivery-service for status every 10s. TODO: swap polling for a
/// WebSocket or the Redis pub/sub event stream once that's set up, and
/// show the agent's live position on a map (needs navigation-service).
class DeliveryTrackingScreen extends StatefulWidget {
  final String? orderId;
  const DeliveryTrackingScreen({super.key, this.orderId});

  @override
  State<DeliveryTrackingScreen> createState() => _DeliveryTrackingScreenState();
}

class _DeliveryTrackingScreenState extends State<DeliveryTrackingScreen> {
  Map<String, dynamic>? _order;
  Timer? _pollTimer;

  @override
  void initState() {
    super.initState();
    if (widget.orderId != null) {
      _fetchStatus();
      _pollTimer = Timer.periodic(const Duration(seconds: 10), (_) => _fetchStatus());
    }
  }

  Future<void> _fetchStatus() async {
    try {
      final response = await ApiClient.instance.get('${AppConstants.deliveryPath}/orders/${widget.orderId}');
      if (mounted) setState(() => _order = response.data as Map<String, dynamic>?);
    } catch (_) {}
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final status = _order?['status']?.toString() ?? 'Pending';
    const steps = ['Pending', 'Accepted', 'Picked Up', 'Delivered'];
    final currentStep = steps.indexOf(status).clamp(0, steps.length - 1);

    return Scaffold(
      appBar: AppBar(title: const Text('Track Order')),
      body: Padding(
        padding: const EdgeInsets.all(20),
        child: widget.orderId == null
            ? const Center(child: Text('No active order to track.'))
            : Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Order #${widget.orderId}', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 20),
                  ...List.generate(steps.length, (i) {
                    final done = i <= currentStep;
                    return Row(
                      children: [
                        Icon(done ? Icons.check_circle : Icons.radio_button_unchecked,
                            color: done ? Colors.green : Colors.grey),
                        const SizedBox(width: 12),
                        Text(steps[i]),
                      ],
                    );
                  }),
                ],
              ),
      ),
    );
  }
}
