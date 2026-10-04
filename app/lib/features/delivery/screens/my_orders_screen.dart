import 'package:flutter/material.dart';

import '../../../core/constants/app_constants.dart';
import '../../../core/models/order.dart';
import '../../../core/network/api_client.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/theme/app_colors_extension.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/utils/app_router.dart';
import '../../../core/utils/view_state.dart';
import '../../../core/widgets/app_card.dart';
import '../../../core/widgets/async_state_view.dart';
import '../../../core/widgets/skeleton_list.dart';
import '../../../core/widgets/status_badge.dart';

/// The customer's own delivery order history. `GET /delivery/orders/me`
/// already branches by role server-side (customers get orders filtered by
/// `customer_id`, delivery agents get theirs by `agent_id`) -- this screen
/// is the customer-facing half that was previously never called from the
/// app; only the driver's own active-orders list used it.
class MyOrdersScreen extends StatefulWidget {
  const MyOrdersScreen({super.key});

  @override
  State<MyOrdersScreen> createState() => _MyOrdersScreenState();
}

class _MyOrdersScreenState extends State<MyOrdersScreen> {
  ViewState<List<DeliveryOrder>> _state = const ViewLoading();

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _state = const ViewLoading());
    try {
      final response = await ApiClient.instance.get('/delivery/orders/me');
      final orders =
          (response as List).map((e) => DeliveryOrder.fromJson(Map<String, dynamic>.from(e as Map))).toList();
      if (!mounted) return;
      setState(() => _state = ViewData(orders));
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _state = ViewError(e.message));
    } catch (_) {
      if (!mounted) return;
      setState(() => _state = const ViewError('Could not load your orders.'));
    }
  }

  (Color, Color) _statusColors(BuildContext context, String status) {
    final colorScheme = Theme.of(context).colorScheme;
    final colors = context.appColors;
    return switch (status) {
      'delivered' => (colors.success.withValues(alpha: 0.18), colors.success),
      'cancelled' => (colorScheme.errorContainer, colorScheme.onErrorContainer),
      'pending' => (colorScheme.surfaceContainerHighest, colors.textSecondary),
      _ => (colorScheme.secondaryContainer, colorScheme.onSecondaryContainer),
    };
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('My Orders')),
      body: RefreshIndicator(
        onRefresh: _load,
        child: AsyncStateView<List<DeliveryOrder>>(
          state: _state,
          onRetry: _load,
          isEmpty: (data) => data.isEmpty,
          emptyTitle: 'No orders yet',
          emptyMessage: 'Orders you place with shops will show up here.',
          emptyIcon: Icons.receipt_long_outlined,
          loadingSkeleton: const SkeletonList(),
          builder: (context, orders) => ListView.separated(
            padding: const EdgeInsets.all(AppSpacing.lg),
            itemCount: orders.length,
            separatorBuilder: (_, _) => const SizedBox(height: AppSpacing.md),
            itemBuilder: (context, index) {
              final order = orders[index];
              final (bg, fg) = _statusColors(context, order.status);
              return AppCard(
                onTap: () => Navigator.pushNamed(
                  context,
                  AppRoutes.deliveryTracking,
                  arguments: DeliveryTrackingArgs(order.id),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            _shortOrderId(order.id),
                            style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            _formatDate(order.createdAt),
                            style: Theme.of(context)
                                .textTheme
                                .bodySmall
                                ?.copyWith(color: context.appColors.textSecondary),
                          ),
                          const SizedBox(height: AppSpacing.sm),
                          Text(
                            'Rs. ${order.totalAmount.toStringAsFixed(2)}',
                            style: Theme.of(context).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
                          ),
                        ],
                      ),
                    ),
                    StatusBadge(label: formatOrderStatusLabel(order.status), background: bg, foreground: fg),
                    const SizedBox(width: AppSpacing.sm),
                    Icon(Icons.chevron_right, color: Theme.of(context).colorScheme.outline),
                  ],
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}

String _shortOrderId(String id) {
  final cleaned = id.replaceAll('-', '').toUpperCase();
  final tail = cleaned.length > 6 ? cleaned.substring(cleaned.length - 6) : cleaned;
  return 'Order #$tail';
}

String _formatDate(DateTime dt) {
  final local = dt.toLocal();
  const months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];
  return '${months[local.month - 1]} ${local.day}, ${local.year}';
}
