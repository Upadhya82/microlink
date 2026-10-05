import 'dart:async';

import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';

import '../../../core/constants/app_constants.dart';
import '../../../core/models/order.dart';
import '../../../core/network/api_client.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/network/session_manager.dart';
import '../../../core/theme/app_colors_extension.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/utils/app_router.dart';
import '../../../core/utils/view_state.dart';
import '../../../core/widgets/app_button.dart';
import '../../../core/widgets/app_card.dart';
import '../../../core/widgets/app_text_field.dart';
import '../../../core/widgets/async_state_view.dart';
import '../../../core/widgets/rating_chip.dart';
import '../../../core/widgets/skeleton_list.dart';
import '../../../core/widgets/status_badge.dart';

const List<String> _vehicleTypes = ['bike', 'scooter', 'car', 'van'];

enum _ProfileLoadState { loading, needsSetup, error, loaded }

/// The delivery agent's home base: profile setup (if none exists yet),
/// availability toggle, live location update, performance stats, their
/// currently-assigned orders, and nearby unassigned orders they can accept.
class DriverHomeScreen extends StatefulWidget {
  const DriverHomeScreen({super.key});

  @override
  State<DriverHomeScreen> createState() => _DriverHomeScreenState();
}

class _DriverHomeScreenState extends State<DriverHomeScreen> {
  _ProfileLoadState _profileLoadState = _ProfileLoadState.loading;
  String _profileError = '';
  Map<String, dynamic>? _profile;

  final _vehicleTypeController = ValueNotifier<String>('bike');
  final _licensePlateController = TextEditingController();
  bool _submittingProfile = false;

  bool _availabilityBusy = false;
  bool _locationBusy = false;
  DateTime? _lastLocationUpdate;

  ViewState<Map<String, dynamic>> _performanceState = const ViewLoading();
  ViewState<List<DeliveryOrder>> _activeOrdersState = const ViewLoading();
  ViewState<List<DeliveryOrder>> _availableOrdersState = const ViewLoading();

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  @override
  void dispose() {
    _licensePlateController.dispose();
    _vehicleTypeController.dispose();
    super.dispose();
  }

  Future<void> _bootstrap() async {
    await _loadProfile();
  }

  Future<void> _loadProfile() async {
    setState(() => _profileLoadState = _ProfileLoadState.loading);
    try {
      final response = await ApiClient.instance.get('/delivery/agents/me');
      _profile = Map<String, dynamic>.from(response as Map);
      if (!mounted) return;
      setState(() => _profileLoadState = _ProfileLoadState.loaded);
      unawaited(_loadDashboard());
    } on ApiException catch (e) {
      if (!mounted) return;
      if (e.isNotFound) {
        setState(() => _profileLoadState = _ProfileLoadState.needsSetup);
      } else {
        setState(() {
          _profileError = e.message;
          _profileLoadState = _ProfileLoadState.error;
        });
      }
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _profileError = 'Something went wrong. Please try again.';
        _profileLoadState = _ProfileLoadState.error;
      });
    }
  }

  Future<void> _loadDashboard() async {
    await Future.wait([
      _loadPerformance(),
      _loadActiveOrders(),
      _loadAvailableOrders(),
    ]);
  }

  Future<void> _loadPerformance() async {
    setState(() => _performanceState = const ViewLoading());
    final userId = SessionManager.instance.userId;
    if (userId == null) {
      setState(() => _performanceState = const ViewError('No signed-in user.'));
      return;
    }
    try {
      final response = await ApiClient.instance.get('/delivery/agents/$userId/performance');
      if (!mounted) return;
      setState(() => _performanceState = ViewData(Map<String, dynamic>.from(response as Map)));
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _performanceState = ViewError(e.message));
    } catch (_) {
      if (!mounted) return;
      setState(() => _performanceState = const ViewError('Could not load performance stats.'));
    }
  }

  Future<void> _loadActiveOrders() async {
    setState(() => _activeOrdersState = const ViewLoading());
    try {
      final response = await ApiClient.instance.get('/delivery/orders/me');
      final orders = (response as List)
          .map((e) => DeliveryOrder.fromJson(Map<String, dynamic>.from(e as Map)))
          .where((o) => o.status != 'delivered' && o.status != 'cancelled')
          .toList();
      if (!mounted) return;
      setState(() => _activeOrdersState = ViewData(orders));
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _activeOrdersState = ViewError(e.message));
    } catch (_) {
      if (!mounted) return;
      setState(() => _activeOrdersState = const ViewError('Could not load your orders.'));
    }
  }

  Future<void> _loadAvailableOrders() async {
    setState(() => _availableOrdersState = const ViewLoading());
    try {
      final response = await ApiClient.instance.get('/delivery/orders/available');
      final orders = (response as List)
          .map((e) => DeliveryOrder.fromJson(Map<String, dynamic>.from(e as Map)))
          .toList();
      if (!mounted) return;
      setState(() => _availableOrdersState = ViewData(orders));
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _availableOrdersState = ViewError(e.message));
    } catch (_) {
      if (!mounted) return;
      setState(() => _availableOrdersState = const ViewError('Could not load available orders.'));
    }
  }

  Future<void> _submitProfile() async {
    setState(() => _submittingProfile = true);
    try {
      final plate = _licensePlateController.text.trim();
      await ApiClient.instance.post(
        '/delivery/agents/profile',
        body: {
          'vehicle_type': _vehicleTypeController.value,
          if (plate.isNotEmpty) 'license_plate': plate,
        },
      );
      if (!mounted) return;
      await _loadProfile();
    } on ApiException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Could not save your profile.')));
    } finally {
      if (mounted) setState(() => _submittingProfile = false);
    }
  }

  Future<void> _toggleAvailability(bool value) async {
    final previous = _profile?['is_available'] as bool? ?? false;
    setState(() {
      _profile = {...?_profile, 'is_available': value};
      _availabilityBusy = true;
    });
    try {
      await ApiClient.instance.patch(
        '/delivery/agents/me/availability',
        body: {'is_available': value},
      );
      if (!mounted) return;
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _profile = {...?_profile, 'is_available': previous});
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    } catch (_) {
      if (!mounted) return;
      setState(() => _profile = {...?_profile, 'is_available': previous});
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Could not update availability.')));
    } finally {
      if (mounted) setState(() => _availabilityBusy = false);
    }
  }

  Future<void> _updateLocation() async {
    setState(() => _locationBusy = true);
    try {
      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.denied || permission == LocationPermission.deniedForever) {
        throw const ApiException('Location permission was denied.');
      }
      final serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) {
        throw const ApiException('Location services are turned off.');
      }
      final position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(accuracy: LocationAccuracy.high),
      );
      await ApiClient.instance.patch(
        '/delivery/agents/me/location',
        body: {'lat': position.latitude, 'lng': position.longitude},
      );
      if (!mounted) return;
      setState(() => _lastLocationUpdate = DateTime.now());
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Location updated.')));
    } on ApiException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Could not get your location.')));
    } finally {
      if (mounted) setState(() => _locationBusy = false);
    }
  }

  Future<void> _acceptOrder(DeliveryOrder order) async {
    try {
      await ApiClient.instance.patch('/delivery/orders/${order.id}/accept');
      if (!mounted) return;
      final current = _availableOrdersState;
      if (current is ViewData<List<DeliveryOrder>>) {
        setState(() {
          _availableOrdersState =
              ViewData(current.data.where((o) => o.id != order.id).toList());
        });
      }
      Navigator.pushNamed(
        context,
        AppRoutes.deliveryTracking,
        arguments: DeliveryTrackingArgs(order.id),
      );
    } on ApiException catch (e) {
      if (!mounted) return;
      final message = e.statusCode == 409
          ? 'Someone else just accepted this order.'
          : e.message;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
      unawaited(_loadAvailableOrders());
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Could not accept this order.')));
      unawaited(_loadAvailableOrders());
    }
  }

  // There is no decline/reject endpoint on the delivery backend today, so
  // declining an available order is a local-only dismissal: it drops out of
  // this driver's list without altering anything server-side. A later
  // refresh (or another driver accepting it) will reflect the real state.
  void _declineOrder(DeliveryOrder order) {
    final current = _availableOrdersState;
    if (current is ViewData<List<DeliveryOrder>>) {
      setState(() {
        _availableOrdersState =
            ViewData(current.data.where((o) => o.id != order.id).toList());
      });
    }
  }

  void _openOrder(DeliveryOrder order) {
    Navigator.pushNamed(
      context,
      AppRoutes.deliveryTracking,
      arguments: DeliveryTrackingArgs(order.id),
    );
  }

  Future<void> _refreshAll() async {
    if (_profileLoadState == _ProfileLoadState.loaded) {
      await _loadDashboard();
    } else {
      await _loadProfile();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Driver Home')),
      body: RefreshIndicator(
        onRefresh: _refreshAll,
        child: SingleChildScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.all(AppSpacing.lg),
          child: _buildBody(context),
        ),
      ),
    );
  }

  Widget _buildBody(BuildContext context) {
    switch (_profileLoadState) {
      case _ProfileLoadState.loading:
        return const SizedBox(
          height: 400,
          child: Center(child: CircularProgressIndicator()),
        );
      case _ProfileLoadState.error:
        return SizedBox(
          height: 400,
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.cloud_off_rounded, size: 48, color: Theme.of(context).colorScheme.error),
                const SizedBox(height: AppSpacing.md),
                Text(_profileError, textAlign: TextAlign.center),
                const SizedBox(height: AppSpacing.lg),
                AppButton(label: 'Retry', onPressed: _loadProfile, expand: false),
              ],
            ),
          ),
        );
      case _ProfileLoadState.needsSetup:
        return _buildProfileSetupForm(context);
      case _ProfileLoadState.loaded:
        return _buildDashboard(context);
    }
  }

  Widget _buildProfileSetupForm(BuildContext context) {
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Set up your driver profile', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: AppSpacing.xs),
          Text(
            'Tell us how you get around so we can start sending you deliveries.',
            style: Theme.of(context)
                .textTheme
                .bodyMedium
                ?.copyWith(color: context.appColors.textSecondary),
          ),
          const SizedBox(height: AppSpacing.lg),
          ValueListenableBuilder<String>(
            valueListenable: _vehicleTypeController,
            builder: (context, value, _) => DropdownButtonFormField<String>(
              initialValue: value,
              decoration: const InputDecoration(labelText: 'Vehicle type'),
              items: _vehicleTypes
                  .map((v) => DropdownMenuItem(value: v, child: Text(_vehicleLabel(v))))
                  .toList(),
              onChanged: (v) {
                if (v != null) _vehicleTypeController.value = v;
              },
            ),
          ),
          const SizedBox(height: AppSpacing.lg),
          AppTextField(
            controller: _licensePlateController,
            label: 'License plate (optional)',
            hint: 'e.g. ABC-1234',
          ),
          const SizedBox(height: AppSpacing.xl),
          AppButton(
            label: 'Save profile',
            isLoading: _submittingProfile,
            onPressed: _submitProfile,
          ),
        ],
      ),
    );
  }

  Widget _buildDashboard(BuildContext context) {
    final isAvailable = _profile?['is_available'] as bool? ?? false;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Welcome back',
                    style: Theme.of(context)
                        .textTheme
                        .bodySmall
                        ?.copyWith(color: context.appColors.textSecondary),
                  ),
                  Text(
                    SessionManager.instance.userName ?? 'Driver',
                    style: Theme.of(context)
                        .textTheme
                        .titleLarge
                        ?.copyWith(fontWeight: FontWeight.w800),
                  ),
                ],
              ),
            ),
            const SizedBox(width: AppSpacing.md),
            _AvailabilityPill(
              isAvailable: isAvailable,
              busy: _availabilityBusy,
              onTap: () => _toggleAvailability(!isAvailable),
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.md),
        Row(
          children: [
            Icon(Icons.my_location_outlined, size: 14, color: context.appColors.textSecondary),
            const SizedBox(width: AppSpacing.xs),
            Expanded(
              child: Text(
                _lastLocationUpdate == null
                    ? 'Location not shared yet this session'
                    : 'Location last updated ${_formatTime(_lastLocationUpdate!)}',
                style: Theme.of(context)
                    .textTheme
                    .bodySmall
                    ?.copyWith(color: context.appColors.textSecondary),
              ),
            ),
            _locationBusy
                ? const Padding(
                    padding: EdgeInsets.symmetric(horizontal: AppSpacing.sm),
                    child: SizedBox(
                      height: 14,
                      width: 14,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  )
                : TextButton(
                    onPressed: _updateLocation,
                    child: const Text('Update'),
                  ),
          ],
        ),
        const SizedBox(height: AppSpacing.lg),
        AppCard(child: _buildPerformanceRow(context)),
        const SizedBox(height: AppSpacing.xl),
        Text('My active orders', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: AppSpacing.sm),
        SizedBox(
          height: 260,
          child: AsyncStateView<List<DeliveryOrder>>(
            state: _activeOrdersState,
            onRetry: _loadActiveOrders,
            isEmpty: (data) => data.isEmpty,
            emptyTitle: 'No active orders',
            emptyMessage: 'Accept an order below to get started.',
            emptyIcon: Icons.local_shipping_outlined,
            loadingSkeleton: const SkeletonList(itemCount: 2, itemHeight: 80),
            builder: (context, orders) => ListView.separated(
              itemCount: orders.length,
              separatorBuilder: (_, _) => const SizedBox(height: AppSpacing.sm),
              itemBuilder: (context, index) {
                final order = orders[index];
                return _ActiveOrderTile(order: order, onTap: () => _openOrder(order));
              },
            ),
          ),
        ),
        const SizedBox(height: AppSpacing.xl),
        Text('Available deliveries', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: AppSpacing.sm),
        SizedBox(
          height: 360,
          child: AsyncStateView<List<DeliveryOrder>>(
            state: _availableOrdersState,
            onRetry: _loadAvailableOrders,
            isEmpty: (data) => data.isEmpty,
            emptyTitle: 'No orders nearby',
            emptyMessage: 'Check back soon, or make sure you are marked available.',
            emptyIcon: Icons.explore_off_outlined,
            loadingSkeleton: const SkeletonList(itemCount: 3, itemHeight: 96),
            builder: (context, orders) => ListView.separated(
              itemCount: orders.length,
              separatorBuilder: (_, _) => const SizedBox(height: AppSpacing.sm),
              itemBuilder: (context, index) {
                final order = orders[index];
                return _AvailableOrderTile(
                  order: order,
                  onAccept: () => _acceptOrder(order),
                  onDecline: () => _declineOrder(order),
                );
              },
            ),
          ),
        ),
      ],
    );
  }

  // A lighter-weight inline treatment (rather than AsyncStateView, which is
  // sized for full sections) so this compact stats row never risks
  // overflowing a fixed height in its error state.
  Widget _buildPerformanceRow(BuildContext context) {
    final state = _performanceState;
    return switch (state) {
      ViewLoading<Map<String, dynamic>>() => const Padding(
          padding: EdgeInsets.symmetric(vertical: AppSpacing.sm),
          child: SizedBox(
            height: 20,
            width: 20,
            child: CircularProgressIndicator(strokeWidth: 2.4),
          ),
        ),
      ViewError<Map<String, dynamic>>(:final message) => Row(
          children: [
            Expanded(
              child: Text(
                message,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
            TextButton(onPressed: _loadPerformance, child: const Text('Retry')),
          ],
        ),
      ViewData<Map<String, dynamic>>(:final data) => Row(
          children: [
            Expanded(
              child: _StatColumn(
                value: '${data['total_deliveries'] ?? 0}',
                label: 'Deliveries',
              ),
            ),
            Container(
              width: 1,
              height: 34,
              color: Theme.of(context).colorScheme.outlineVariant,
            ),
            Expanded(
              child: _StatColumn(
                ratingValue: (data['rating_avg'] as num?)?.toDouble() ?? 0.0,
                ratingCount: data['rating_count'] as int?,
                label: 'Rating',
              ),
            ),
          ],
        ),
    };
  }
}

/// A tappable pill showing the driver's online/offline state, wired to the
/// same [DriverHomeScreen._toggleAvailability] call as before.
class _AvailabilityPill extends StatelessWidget {
  final bool isAvailable;
  final bool busy;
  final VoidCallback onTap;

  const _AvailabilityPill({required this.isAvailable, required this.busy, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final colors = context.appColors;
    final background = isAvailable ? colorScheme.primaryContainer : colorScheme.surfaceContainerHighest;
    final foreground = isAvailable ? colors.success : colors.textSecondary;
    return InkWell(
      borderRadius: BorderRadius.circular(AppRadius.pill),
      onTap: busy ? null : onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md, vertical: AppSpacing.sm),
        decoration: BoxDecoration(color: background, borderRadius: BorderRadius.circular(AppRadius.pill)),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (busy)
              SizedBox(
                height: 8,
                width: 8,
                child: CircularProgressIndicator(strokeWidth: 1.5, color: foreground),
              )
            else
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(color: foreground, shape: BoxShape.circle),
              ),
            const SizedBox(width: AppSpacing.sm),
            Text(
              isAvailable ? 'Online' : 'Offline',
              style: Theme.of(context).textTheme.labelMedium?.copyWith(
                    color: foreground,
                    fontWeight: FontWeight.w700,
                  ),
            ),
          ],
        ),
      ),
    );
  }
}

class _StatColumn extends StatelessWidget {
  final String? value;
  final double? ratingValue;
  final int? ratingCount;
  final String label;

  const _StatColumn({this.value, this.ratingValue, this.ratingCount, required this.label});

  @override
  Widget build(BuildContext context) {
    final valueStyle =
        Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800);
    return Column(
      children: [
        ratingValue != null
            ? RatingChip(rating: ratingValue!, count: ratingCount, iconSize: 16, textStyle: valueStyle)
            : Text(value ?? '-', style: valueStyle),
        const SizedBox(height: 2),
        Text(
          label,
          style: Theme.of(context)
              .textTheme
              .bodySmall
              ?.copyWith(color: context.appColors.textSecondary),
        ),
      ],
    );
  }
}

class _ActiveOrderTile extends StatelessWidget {
  final DeliveryOrder order;
  final VoidCallback onTap;

  const _ActiveOrderTile({required this.order, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return AppCard(
      onTap: onTap,
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _shortOrderId(order.id),
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: AppSpacing.xs),
                Text(
                  order.deliveryAddress,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context)
                      .textTheme
                      .bodySmall
                      ?.copyWith(color: context.appColors.textSecondary),
                ),
                const SizedBox(height: AppSpacing.sm),
                StatusBadge(
                  label: formatOrderStatusLabel(order.status),
                  background: colorScheme.primaryContainer,
                  foreground: colorScheme.primary,
                ),
              ],
            ),
          ),
          const Icon(Icons.chevron_right),
        ],
      ),
    );
  }
}

/// One "available deliveries" card: order id + fee, a two-point pickup ->
/// dropoff route, then Decline/Accept actions wired to the existing accept
/// call (and a local-only decline, since the backend has no reject endpoint).
class _AvailableOrderTile extends StatelessWidget {
  final DeliveryOrder order;
  final VoidCallback onAccept;
  final VoidCallback onDecline;

  const _AvailableOrderTile({
    required this.order,
    required this.onAccept,
    required this.onDecline,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Text(
                  _shortOrderId(order.id),
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w700),
                ),
              ),
              Text(
                'Rs. ${order.totalAmount.toStringAsFixed(2)}',
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w800,
                      color: colorScheme.primary,
                    ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.md),
          Row(
            children: [
              _RouteDot(color: colorScheme.primary),
              const SizedBox(width: AppSpacing.sm),
              Text('Pickup', style: Theme.of(context).textTheme.bodyMedium),
            ],
          ),
          Padding(
            padding: const EdgeInsets.only(left: 3.75),
            child: _DashedConnector(color: colorScheme.outlineVariant),
          ),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _RouteDot(color: colorScheme.error),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: Text.rich(
                  TextSpan(
                    text: order.deliveryAddress,
                    style: Theme.of(context).textTheme.bodyMedium,
                    children: order.distanceKm != null
                        ? [
                            TextSpan(
                              text: ' · ${order.distanceKm!.toStringAsFixed(1)} km',
                              style: TextStyle(color: context.appColors.textSecondary),
                            ),
                          ]
                        : const [],
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.lg),
          Row(
            children: [
              Expanded(
                child: AppButton(
                  label: 'Decline',
                  variant: AppButtonVariant.outlined,
                  expand: false,
                  onPressed: onDecline,
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: AppButton(
                  label: 'Accept',
                  expand: false,
                  onPressed: onAccept,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// A small filled circle marking one end of the pickup/dropoff route.
class _RouteDot extends StatelessWidget {
  final Color color;

  const _RouteDot({required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 9,
      height: 9,
      margin: const EdgeInsets.symmetric(vertical: 2),
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
    );
  }
}

/// The short dashed vertical line connecting the pickup and dropoff dots.
class _DashedConnector extends StatelessWidget {
  final Color color;

  const _DashedConnector({required this.color});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 16,
      width: 1.5,
      child: CustomPaint(painter: _DashedLinePainter(color: color)),
    );
  }
}

class _DashedLinePainter extends CustomPainter {
  final Color color;

  const _DashedLinePainter({required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = size.width;
    const dashHeight = 3.0;
    const dashSpace = 3.0;
    var y = 0.0;
    while (y < size.height) {
      canvas.drawLine(Offset(size.width / 2, y), Offset(size.width / 2, y + dashHeight), paint);
      y += dashHeight + dashSpace;
    }
  }

  @override
  bool shouldRepaint(covariant _DashedLinePainter oldDelegate) => oldDelegate.color != color;
}

/// Shortens a UUID order id into a compact, display-friendly reference (the
/// backend has no separate human-readable order number).
String _shortOrderId(String id) {
  final cleaned = id.replaceAll('-', '').toUpperCase();
  final tail = cleaned.length > 6 ? cleaned.substring(cleaned.length - 6) : cleaned;
  return 'Order #$tail';
}

String _vehicleLabel(String value) {
  return switch (value) {
    'bike' => 'Bike',
    'scooter' => 'Scooter',
    'car' => 'Car',
    'van' => 'Van',
    _ => value,
  };
}

String _formatTime(DateTime dt) {
  final h = dt.hour.toString().padLeft(2, '0');
  final m = dt.minute.toString().padLeft(2, '0');
  return '$h:$m';
}
