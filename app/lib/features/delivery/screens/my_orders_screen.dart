import 'dart:async';

import 'package:flutter/material.dart';

import '../../../core/l10n/app_strings.dart';
import '../../../core/constants/app_constants.dart';
import '../../../core/models/order.dart';
import '../../../core/network/api_client.dart';
import '../../../core/network/offline_cache.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/network/session_manager.dart';
import '../../../core/theme/app_colors_extension.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/utils/app_router.dart';
import '../confirm_receipt.dart';
import '../../../core/utils/view_state.dart';
import '../../../core/widgets/app_button.dart';
import '../../../core/widgets/app_card.dart';
import '../../../core/widgets/async_state_view.dart';
import '../../../core/widgets/skeleton_list.dart';
import '../../../core/widgets/status_badge.dart';
import '../../../core/widgets/branded_app_bar.dart';

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

  /// When the shown orders were saved, if they came from the cache.
  DateTime? _cachedAt;

  /// The order whose "I received it" button is mid-flight, so only that one
  /// card shows a spinner.
  String? _confirmingId;

  Future<void> _load() async {
    setState(() => _state = const ViewLoading());
    try {
      final response = await ApiClient.instance.get('/delivery/orders/me');
      final rows = (response as List)
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();
      final orders = rows.map(DeliveryOrder.fromJson).toList();
      if (!mounted) return;
      setState(() {
        _state = ViewData(orders);
        _cachedAt = null;
      });
      // Item 14: keep them for the next time there is no signal.
      unawaited(OfflineCache.save(OfflineCache.myOrdersKey, rows));
    } on ApiException catch (e) {
      if (!mounted) return;
      if (!await _showCached()) {
        if (mounted) setState(() => _state = ViewError(e.message));
      }
    } catch (_) {
      if (!mounted) return;
      if (!await _showCached()) {
        if (mounted) {
          setState(() => _state = const ViewError('Could not load your orders.'));
        }
      }
    }
  }

  /// Item 14: fall back to the last orders this phone saw. True when there
  /// was something to show, so the caller leaves the error alone.
  Future<bool> _showCached() async {
    final cached = await OfflineCache.loadList(OfflineCache.myOrdersKey);
    if (cached == null || cached.rows.isEmpty || !mounted) return false;
    setState(() {
      _state = ViewData(cached.rows.map(DeliveryOrder.fromJson).toList());
      _cachedAt = cached.savedAt;
    });
    return true;
  }

  /// The customer confirms the parcel arrived, right from the list.
  ///
  /// This is the moment the delivery closes and the driver is freed for
  /// their next job, so it belongs where the customer already is -- not
  /// only behind a tap into the tracking screen, where it was easy to miss.
  Future<void> _confirmReceipt(DeliveryOrder order) async {
    setState(() => _confirmingId = order.id);
    try {
      if (await confirmOrderReceipt(context, order) && mounted) {
        await _load();
      }
    } finally {
      if (mounted) setState(() => _confirmingId = null);
    }
  }

  Future<void> _openRequestDelivery() async {
    await Navigator.pushNamed(context, AppRoutes.requestDelivery);
    if (mounted) _load();
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
      appBar: BrandedAppBar(title: Text(tr('orders.my_orders'))),
      // SRS REQ-DELIV-1: customers can start a delivery request from here.
      floatingActionButton: SessionManager.instance.isCustomer
          ? FloatingActionButton.extended(
              onPressed: _openRequestDelivery,
              icon: const Icon(Icons.add_location_alt_outlined),
              label: Text(tr('orders.request_delivery')),
            )
          : null,
      body: RefreshIndicator(
        onRefresh: _load,
        child: AsyncStateView<List<DeliveryOrder>>(
          state: _state,
          onRetry: _load,
          isEmpty: (data) => data.isEmpty,
          emptyTitle: tr('orders.none_title'),
          emptyMessage: tr('orders.none_body'),
          emptyIcon: Icons.receipt_long_outlined,
          loadingSkeleton: const SkeletonList(),
          builder: (context, orders) => ListView.separated(
            padding: const EdgeInsets.all(AppSpacing.lg),
            // One extra row for the "saved information from ..." line, so
            // nobody mistakes a cached list for a live one (item 14).
            itemCount: orders.length + (_cachedAt == null ? 0 : 1),
            separatorBuilder: (_, _) => const SizedBox(height: AppSpacing.md),
            itemBuilder: (context, position) {
              if (_cachedAt != null && position == 0) {
                return Text(
                  '${tr('offline.saved_at')} ${_formatDate(_cachedAt!)}',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: context.appColors.textSecondary,
                      ),
                );
              }
              final index = _cachedAt == null ? position : position - 1;
              final order = orders[index];
              final (bg, fg) = _statusColors(context, order.status);
              return AppCard(
                onTap: () => Navigator.pushNamed(
                  context,
                  AppRoutes.deliveryTracking,
                  arguments: DeliveryTrackingArgs(order.id),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
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
                                order.totalAmount > 0
                                    ? 'Offered fee: Rs. ${order.totalAmount.toStringAsFixed(2)}'
                                    : 'Fee to be agreed with the agent',
                                style: Theme.of(context).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
                              ),
                              // Item 8: a cancelled order used to say only
                              // "Cancelled", leaving the customer to guess.
                              if (order.cancellationNote != null) ...[
                                const SizedBox(height: AppSpacing.xs),
                                Text(
                                  order.cancellationNote!,
                                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                        color: Theme.of(context).colorScheme.error,
                                      ),
                                ),
                              ],
                            ],
                          ),
                        ),
                        StatusBadge(label: formatOrderStatusLabel(order.status), background: bg, foreground: fg),
                        const SizedBox(width: AppSpacing.sm),
                        Icon(Icons.chevron_right, color: Theme.of(context).colorScheme.outline),
                      ],
                    ),
                    // The driver is standing at the door: confirming here
                    // closes the delivery and releases them for the next
                    // job, without having to open the order first.
                    if (canConfirmReceipt(order)) ...[
                      const SizedBox(height: AppSpacing.md),
                      AppButton(
                        label: 'I received my order',
                        icon: Icons.check_circle_outline,
                        isLoading: _confirmingId == order.id,
                        requiresConnection: true,
                        onPressed: () => _confirmReceipt(order),
                      ),
                    ],
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
