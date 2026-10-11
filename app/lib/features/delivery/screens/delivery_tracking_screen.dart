import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart' as ll;

import '../../location/widgets/map_tile_layer.dart';
import '../../../core/l10n/app_strings.dart';
import '../../../core/models/order.dart';
import '../../../core/network/api_client.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/network/session_manager.dart';
import '../../../core/theme/app_colors_extension.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/utils/view_state.dart';
import '../../../core/widgets/app_button.dart';
import '../../../core/widgets/app_card.dart';
import '../../../core/widgets/async_state_view.dart';
import '../../../core/widgets/rating_chip.dart';

/// Shows the full detail of one delivery order: destination on a map, a
/// vertical status timeline, driver info, and order details. The assigned
/// delivery agent can advance the order to its next status from here.
class DeliveryTrackingScreen extends StatefulWidget {
  final String orderId;

  const DeliveryTrackingScreen({super.key, required this.orderId});

  @override
  State<DeliveryTrackingScreen> createState() => _DeliveryTrackingScreenState();
}

class _DeliveryTrackingScreenState extends State<DeliveryTrackingScreen> {
  ViewState<DeliveryOrder> _state = const ViewLoading();
  bool _updatingStatus = false;

  // Best-effort lookups for the driver-info row -- kept separate from
  // `_state` since they're a minor enhancement, not core order data, and a
  // failure here shouldn't block the whole screen.
  Map<String, dynamic>? _agentPerformance;
  String? _agentName;

  @override
  void initState() {
    super.initState();
    _fetchOrder();
  }

  Future<void> _fetchOrder() async {
    setState(() => _state = const ViewLoading());
    try {
      final response = await ApiClient.instance.get('/delivery/orders/${widget.orderId}');
      final order = DeliveryOrder.fromJson(Map<String, dynamic>.from(response as Map));
      if (!mounted) return;
      setState(() => _state = ViewData(order));
      if (order.agentId != null) {
        unawaited(_fetchAgentPerformance(order.agentId!));
        // Only needed when someone other than the agent themself is
        // viewing -- the agent already knows their own name.
        final viewerIsTheAgent =
            SessionManager.instance.isDeliveryAgent && SessionManager.instance.userId == order.agentId;
        if (!viewerIsTheAgent) unawaited(_fetchAgentName(order.agentId!));
      }
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _state = ViewError(e.message));
    } catch (_) {
      if (!mounted) return;
      setState(() => _state = const ViewError('Could not load this order. Please try again.'));
    }
  }

  Future<void> _fetchAgentPerformance(String agentId) async {
    try {
      final response = await ApiClient.instance.get('/delivery/agents/$agentId/performance');
      if (!mounted) return;
      setState(() => _agentPerformance = Map<String, dynamic>.from(response as Map));
    } catch (_) {
      // Silently ignore -- the driver info row just omits the rating.
    }
  }

  Future<void> _fetchAgentName(String agentId) async {
    try {
      final response = await ApiClient.instance.get('/users/$agentId');
      if (!mounted) return;
      setState(() => _agentName = (response as Map<String, dynamic>)['full_name'] as String?);
    } catch (_) {
      // Silently ignore -- the driver info row falls back to a generic label.
    }
  }

  /// Statuses the server will not accept without a handover code, and who
  /// the agent has to get it from.
  static const _codeSources = {
    'picked_up': 'shop owner',
    'delivered': 'customer',
  };

  Future<void> _advanceStatus(String nextStatus) async {
    final source = _codeSources[nextStatus];
    String? code;
    if (source != null) {
      code = await _askForCode(source);
      // Backing out of the dialog is not a failed handover, so say nothing.
      if (code == null) return;
    }

    setState(() => _updatingStatus = true);
    try {
      await ApiClient.instance.patch(
        '/delivery/orders/${widget.orderId}/status',
        body: {
          'status': nextStatus,
          if (code != null) 'code': code,
        },
      );
      if (!mounted) return;
      await _fetchOrder();
    } on ApiException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Could not update the order status.')));
    } finally {
      if (mounted) setState(() => _updatingStatus = false);
    }
  }

  /// Ask the agent for the four digits the other party is holding.
  ///
  /// The agent never sees either code in their own app -- that is the whole
  /// point of the handover -- so this is a plain entry box, not a confirm.
  Future<String?> _askForCode(String source) async {
    final controller = TextEditingController();
    final result = await showDialog<String>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: Text('Enter the code from the $source'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Ask the $source for their 4-digit code and type it in to '
                'confirm the handover.',
                style: Theme.of(dialogContext).textTheme.bodySmall,
              ),
              const SizedBox(height: AppSpacing.md),
              TextField(
                controller: controller,
                autofocus: true,
                keyboardType: TextInputType.number,
                maxLength: 4,
                textAlign: TextAlign.center,
                style: Theme.of(dialogContext).textTheme.headlineSmall?.copyWith(
                      letterSpacing: 8,
                      fontWeight: FontWeight.w700,
                    ),
                decoration: const InputDecoration(
                  counterText: '',
                  hintText: '0000',
                  border: OutlineInputBorder(),
                ),
                onSubmitted: (value) => Navigator.pop(dialogContext, value.trim()),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, controller.text.trim()),
              child: const Text('Confirm'),
            ),
          ],
        );
      },
    );
    controller.dispose();
    if (result == null || result.isEmpty) return null;
    return result;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Order Tracking'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh_rounded),
            onPressed: _fetchOrder,
            tooltip: 'Refresh',
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _fetchOrder,
        child: AsyncStateView<DeliveryOrder>(
          state: _state,
          onRetry: _fetchOrder,
          builder: (context, order) => ListView(
            padding: EdgeInsets.zero,
            children: [
              _buildMap(order),
              Padding(
                padding: const EdgeInsets.all(AppSpacing.lg),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _TrackingHeader(order: order),
                    const SizedBox(height: AppSpacing.lg),
                    // The server only sends the code this viewer is entitled
                    // to, so whichever one arrived is the one to show.
                    if (order.pickupCode != null || order.deliveryCode != null) ...[
                      _HandoverCodeCard(
                        code: (order.pickupCode ?? order.deliveryCode)!,
                        isPickup: order.pickupCode != null,
                        status: order.status,
                      ),
                      const SizedBox(height: AppSpacing.lg),
                    ],
                    if (order.agentId != null)
                      _DriverInfoRow(agentPerformance: _agentPerformance, agentName: _agentName, order: order)
                    else
                      _WaitingForAgentRow(),
                    const SizedBox(height: AppSpacing.xl),
                    if (order.status == 'cancelled')
                      _CancelledBanner()
                    else
                      _StatusTimeline(order: order),
                    const SizedBox(height: AppSpacing.xl),
                    _OrderDetailsCard(order: order),
                    const SizedBox(height: AppSpacing.xl),
                    _buildAgentAction(order),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildMap(DeliveryOrder order) {
    final destination = ll.LatLng(order.deliveryLat, order.deliveryLng);
    return SizedBox(
      height: 220,
      child: FlutterMap(
        options: MapOptions(initialCenter: destination, initialZoom: 15),
        children: [
          MapTileLayer(),
          MarkerLayer(
            markers: [
              Marker(
                point: destination,
                child: Icon(Icons.location_pin, color: Theme.of(context).colorScheme.error, size: 36),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildAgentAction(DeliveryOrder order) {
    final session = SessionManager.instance;
    final isAssignedAgent = session.isDeliveryAgent && session.userId == order.agentId;
    final isTerminal = order.status == 'delivered' || order.status == 'cancelled';
    if (!isAssignedAgent || isTerminal) return const SizedBox.shrink();

    // The agent only ever confirms the two handovers. Leaving the shop puts
    // the order in transit on the server, so there is no button for it here
    // -- pressing one would only repeat what the pickup already said.
    final nextStatus = switch (order.status) {
      'accepted' => 'picked_up',
      'picked_up' || 'in_transit' => 'delivered',
      _ => null,
    };
    if (nextStatus == null) return const SizedBox.shrink();

    return AppButton(
      label: nextStatus == 'picked_up'
          ? 'Confirm pickup with the shop code'
          : 'Confirm delivery with the customer code',
      isLoading: _updatingStatus,
      onPressed: () => _advanceStatus(nextStatus),
    );
  }
}

/// Order id, a friendly one-line status headline, and a small pill showing
/// how recently the status last changed. There's no ETA field anywhere in
/// the order model or backend, so rather than fabricate a delivery estimate
/// this uses the order's real `updatedAt` timestamp.
class _TrackingHeader extends StatelessWidget {
  final DeliveryOrder order;

  const _TrackingHeader({required this.order});

  @override
  Widget build(BuildContext context) {
    final colors = context.appColors;
    final isOngoing = order.status != 'delivered' && order.status != 'cancelled';
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                _shortOrderId(order.id),
                style: Theme.of(context).textTheme.bodySmall?.copyWith(color: colors.textSecondary),
              ),
              const SizedBox(height: 2),
              Text(
                order.status == 'cancelled' ? 'Order cancelled' : _statusHeadline(order.status),
                style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
              ),
            ],
          ),
        ),
        const SizedBox(width: AppSpacing.md),
        if (isOngoing)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md, vertical: AppSpacing.sm),
            decoration: BoxDecoration(
              color: colors.warning.withValues(alpha: 0.16),
              borderRadius: BorderRadius.circular(AppRadius.pill),
            ),
            child: Text(
              'Updated ${_relativeTime(order.updatedAt)}',
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: colors.warning,
                    fontWeight: FontWeight.w700,
                  ),
            ),
          ),
      ],
    );
  }
}

/// The assigned agent's info. This screen is reached both by the agent's
/// own accept/open flow (where the viewer *is* the agent -- shown as "You")
/// and now by the customer viewing their own order (where it must show the
/// real agent's name, fetched separately, not the viewer's own session).
/// Rating comes from a best-effort fetch of the same
/// `/delivery/agents/{id}/performance` endpoint the driver home screen
/// uses; there's no phone number anywhere in the data model, so the call
/// button is a friendly no-op instead of a fabricated call.
class _DriverInfoRow extends StatelessWidget {
  final Map<String, dynamic>? agentPerformance;
  final String? agentName;
  final DeliveryOrder order;

  const _DriverInfoRow({required this.agentPerformance, required this.agentName, required this.order});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final colors = context.appColors;
    final ratingAvg = (agentPerformance?['rating_avg'] as num?)?.toDouble();
    final ratingCount = agentPerformance?['rating_count'] as int?;
    final viewerIsTheAgent =
        SessionManager.instance.isDeliveryAgent && SessionManager.instance.userId == order.agentId;
    final displayName =
        viewerIsTheAgent ? (SessionManager.instance.userName ?? 'You') : (agentName ?? 'Delivery agent');
    final subtitle = viewerIsTheAgent ? 'Assigned to you' : 'Your delivery agent';

    return Container(
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(AppRadius.card),
      ),
      child: Row(
        children: [
          Container(
            width: 42,
            height: 42,
            decoration: BoxDecoration(color: colorScheme.primaryContainer, shape: BoxShape.circle),
            alignment: Alignment.center,
            child: Icon(Icons.two_wheeler_outlined, color: colorScheme.primary),
          ),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  displayName,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w700),
                ),
                Row(
                  children: [
                    Text(
                      subtitle,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(color: colors.textSecondary),
                    ),
                    if (ratingAvg != null) ...[
                      const SizedBox(width: AppSpacing.xs),
                      Text('·', style: TextStyle(color: colors.textSecondary)),
                      const SizedBox(width: AppSpacing.xs),
                      RatingChip(rating: ratingAvg, count: ratingCount, iconSize: 12),
                    ],
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(width: AppSpacing.sm),
          InkWell(
            customBorder: const CircleBorder(),
            onTap: () => ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('No contact number on file for this order.')),
            ),
            child: Container(
              width: 38,
              height: 38,
              decoration: BoxDecoration(color: colorScheme.primary, shape: BoxShape.circle),
              alignment: Alignment.center,
              child: Icon(Icons.call_outlined, size: 18, color: colorScheme.onPrimary),
            ),
          ),
        ],
      ),
    );
  }
}

/// A vertical progress timeline over the same `orderStatusFlow` /
/// `order.status` that already drives the "Mark as ..." action: a filled
/// checked dot for each completed step, a highlighted dot for the current
/// step, and a greyed-out dot for steps still ahead. Per-step timestamps
/// come from the order's real event history when available.
/// Shown in place of [_DriverInfoRow] when `order.agentId` is still null --
/// no driver has accepted the order yet.
class _WaitingForAgentRow extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final colors = context.appColors;
    return Container(
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(AppRadius.card),
      ),
      child: Row(
        children: [
          Container(
            width: 42,
            height: 42,
            decoration: BoxDecoration(color: colorScheme.surfaceContainerHighest, shape: BoxShape.circle),
            alignment: Alignment.center,
            child: Icon(Icons.hourglass_empty, color: colors.textSecondary),
          ),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Text(
              'Waiting for a delivery agent to accept this order',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: colors.textSecondary),
            ),
          ),
        ],
      ),
    );
  }
}

class _StatusTimeline extends StatelessWidget {
  final DeliveryOrder order;

  const _StatusTimeline({required this.order});

  @override
  Widget build(BuildContext context) {
    final currentIndex = orderStatusFlow.indexOf(order.status);
    final colorScheme = Theme.of(context).colorScheme;
    final colors = context.appColors;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: List.generate(orderStatusFlow.length, (index) {
        final status = orderStatusFlow[index];
        final isDone = currentIndex >= 0 && index < currentIndex;
        final isCurrent = index == currentIndex;
        final isFuture = !isDone && !isCurrent;
        final isLast = index == orderStatusFlow.length - 1;

        OrderEvent? matchingEvent;
        for (final e in order.events) {
          if (e.status == status) {
            matchingEvent = e;
            break;
          }
        }

        final dotColor = isFuture ? colorScheme.surfaceContainerHighest : colorScheme.primary;
        final iconColor = isFuture ? colors.textSecondary : colorScheme.onPrimary;
        final leadingIcon = isDone
            ? Icon(Icons.check, size: 13, color: iconColor)
            : isCurrent
                ? Icon(Icons.more_horiz_rounded, size: 16, color: iconColor)
                : Icon(Icons.circle, size: 8, color: iconColor);

        return IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Column(
                children: [
                  Container(
                    width: 22,
                    height: 22,
                    decoration: BoxDecoration(color: dotColor, shape: BoxShape.circle),
                    alignment: Alignment.center,
                    child: leadingIcon,
                  ),
                  if (!isLast)
                    Expanded(
                      child: Container(
                        width: 1.5,
                        color: isDone ? colorScheme.primary : colorScheme.outlineVariant,
                      ),
                    ),
                ],
              ),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: Padding(
                  padding: EdgeInsets.only(bottom: isLast ? 0 : AppSpacing.lg),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        formatOrderStatusLabel(status),
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                              fontWeight: FontWeight.w700,
                              color: isFuture ? colors.textSecondary : null,
                            ),
                      ),
                      if (matchingEvent != null)
                        Text(
                          _formatTimestamp(matchingEvent.createdAt),
                          style: Theme.of(context)
                              .textTheme
                              .bodySmall
                              ?.copyWith(color: colors.textSecondary),
                        )
                      else if (isCurrent)
                        Text(
                          'In progress',
                          style: Theme.of(context)
                              .textTheme
                              .bodySmall
                              ?.copyWith(color: colors.textSecondary),
                        ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        );
      }),
    );
  }
}

class _CancelledBanner extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(AppSpacing.lg),
      decoration: BoxDecoration(
        color: colorScheme.errorContainer,
        borderRadius: BorderRadius.circular(AppRadius.card),
      ),
      child: Row(
        children: [
          Icon(Icons.cancel_outlined, color: colorScheme.onErrorContainer),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Text(
              'This order was cancelled.',
              style: TextStyle(color: colorScheme.onErrorContainer, fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }
}

class _OrderDetailsCard extends StatelessWidget {
  final DeliveryOrder order;

  const _OrderDetailsCard({required this.order});

  @override
  Widget build(BuildContext context) {
    final colors = context.appColors;
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Order details', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: AppSpacing.md),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.place_outlined, size: 18, color: colors.textSecondary),
              const SizedBox(width: AppSpacing.sm),
              Expanded(child: Text(order.deliveryAddress)),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          Row(
            children: [
              Icon(Icons.payments_outlined, size: 18, color: colors.textSecondary),
              const SizedBox(width: AppSpacing.sm),
              Text('Rs. ${order.totalAmount.toStringAsFixed(2)}'),
            ],
          ),
          if (order.items.isNotEmpty) ...[
            const SizedBox(height: AppSpacing.lg),
            Text(
              'Items',
              style: Theme.of(context).textTheme.labelLarge?.copyWith(color: colors.textSecondary),
            ),
            const SizedBox(height: AppSpacing.xs),
            ...order.items.map(
              (item) => Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Text('${item['name'] ?? 'Item'} x${item['quantity'] ?? 1}'),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

String _formatTimestamp(DateTime dt) {
  final local = dt.toLocal();
  final y = local.year.toString().padLeft(4, '0');
  final mo = local.month.toString().padLeft(2, '0');
  final d = local.day.toString().padLeft(2, '0');
  final h = local.hour.toString().padLeft(2, '0');
  final mi = local.minute.toString().padLeft(2, '0');
  return '$y-$mo-$d $h:$mi';
}

/// Shortens a UUID order id into a compact, display-friendly reference (the
/// backend has no separate human-readable order number).
String _shortOrderId(String id) {
  final cleaned = id.replaceAll('-', '').toUpperCase();
  final tail = cleaned.length > 6 ? cleaned.substring(cleaned.length - 6) : cleaned;
  return 'Order #$tail';
}

/// A friendlier one-line phrase for each real order status, in place of the
/// terser label used elsewhere (e.g. in [_StatusTimeline]'s step labels).
String _statusHeadline(String status) {
  return switch (status) {
    'pending' => 'Waiting for pickup',
    'accepted' => 'Heading to the shop',
    'picked_up' => 'Picked up, heading out',
    'in_transit' => 'On the way to the customer',
    'delivered' => 'Delivered',
    _ => formatOrderStatusLabel(status),
  };
}

String _relativeTime(DateTime dt) {
  final diff = DateTime.now().difference(dt.toLocal());
  if (diff.inMinutes < 1) return 'just now';
  if (diff.inMinutes < 60) return '${diff.inMinutes} min ago';
  if (diff.inHours < 24) return '${diff.inHours} hr ago';
  return '${diff.inDays} d ago';
}


/// The four digits this viewer has to read out to the delivery agent.
///
/// Shown to the shop owner (pickup) and the customer (delivery); the agent
/// is sent neither by the server, so this card never appears for them.
class _HandoverCodeCard extends StatelessWidget {
  final String code;
  final bool isPickup;
  final String status;

  const _HandoverCodeCard({
    required this.code,
    required this.isPickup,
    required this.status,
  });

  /// Whether this code is the one being asked for right now. A delivery code
  /// shown while the order is still sitting at the shop is just noise.
  bool get _isDue => isPickup
      ? status == 'accepted'
      : status == 'picked_up' || status == 'in_transit';

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final done = isPickup
        ? status != 'accepted'
        : status == 'delivered' || status == 'cancelled';

    return AppCard(
      child: Row(
        children: [
          Icon(
            done ? Icons.check_circle_rounded : Icons.pin_rounded,
            color: done ? Colors.green : colorScheme.primary,
            size: 32,
          ),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  isPickup ? tr('orders.pickup_code') : tr('orders.delivery_code'),
                  style: textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
                ),
                Text(
                  done
                      ? 'Already used.'
                      : _isDue
                          ? 'Read this out to the delivery agent.'
                          : isPickup
                              ? 'Give this to the agent when they collect the order.'
                              : 'Give this to the agent when your order arrives.',
                  style: textTheme.labelSmall
                      ?.copyWith(color: context.appColors.textSecondary),
                ),
              ],
            ),
          ),
          const SizedBox(width: AppSpacing.md),
          Text(
            code,
            style: textTheme.headlineSmall?.copyWith(
              fontWeight: FontWeight.w800,
              letterSpacing: 4,
              color: done ? context.appColors.textSecondary : colorScheme.primary,
            ),
          ),
        ],
      ),
    );
  }
}
