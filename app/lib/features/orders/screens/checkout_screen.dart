import 'package:flutter/material.dart';

import '../../../core/l10n/app_strings.dart';
import '../../../core/constants/app_constants.dart';
import '../../../core/location/delivery_location_store.dart';
import '../../../core/location/location_service.dart';
import '../../../core/models/picked_location.dart';
import '../../../core/models/shop.dart';
import '../../../core/network/api_client.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/theme/app_colors_extension.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/utils/app_router.dart' show DeliveryTrackingArgs;
import '../../../core/widgets/app_button.dart';
import '../../../core/widgets/app_card.dart';
import '../../location/screens/location_picker_screen.dart';
import '../cart_controller.dart';
import '../../../core/widgets/branded_app_bar.dart';

/// Review the cart, choose where it goes, place the order.
///
/// The delivery location is the point of this screen: the customer may be
/// browsing shops in a town they are not standing in, so "deliver to my
/// current GPS position" is the wrong default. They pick it on a map and it
/// is remembered (see [DeliveryLocationStore]) for next time.
class CheckoutScreen extends StatefulWidget {
  const CheckoutScreen({super.key});

  @override
  State<CheckoutScreen> createState() => _CheckoutScreenState();
}

class _CheckoutScreenState extends State<CheckoutScreen> {
  bool _placing = false;
  String? _error;

  Future<void> _pickLocation() async {
    final picked = await Navigator.push<PickedLocation>(
      context,
      MaterialPageRoute(
        builder: (_) => LocationPickerScreen(
          initialPoint: DeliveryLocationStore.instance.location?.latLng,
          title: 'Delivery location',
          confirmLabel: 'Deliver here',
        ),
      ),
    );
    if (picked == null || !mounted) return;
    await DeliveryLocationStore.instance.save(picked);
    if (!mounted) return;
    setState(() => _error = null);
  }

  Future<void> _useCurrentLocation() async {
    final result = await LocationService.instance.currentPosition();
    if (!mounted) return;
    if (!result.isReal) {
      final message = LocationService.describeFailure(result.failure);
      if (message != null) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
      }
      return;
    }
    PickedLocation location;
    try {
      final response = await ApiClient.instance.get(
        '/shops/reverse-geocode',
        query: {'lat': result.position.latitude, 'lng': result.position.longitude},
      );
      location = PickedLocation.fromJson(Map<String, dynamic>.from(response as Map));
    } catch (_) {
      location = PickedLocation.fromCoordinates(result.position);
    }
    await DeliveryLocationStore.instance.save(location);
    if (!mounted) return;
    setState(() => _error = null);
  }

  Future<void> _placeOrder() async {
    final cart = CartController.instance;
    final destination = DeliveryLocationStore.instance.location;

    if (destination == null) {
      setState(() => _error = 'Choose where this order should be delivered.');
      return;
    }
    if (cart.isEmpty || cart.shopId == null) {
      setState(() => _error = 'Your cart is empty.');
      return;
    }

    setState(() {
      _placing = true;
      _error = null;
    });

    try {
      final response = await ApiClient.instance.post(
        '/delivery/orders',
        body: {
          'shop_id': cart.shopId,
          'items': cart.lines.map((line) => line.toOrderItem()).toList(),
          'delivery_address': destination.address,
          'delivery_lat': destination.latitude,
          'delivery_lng': destination.longitude,
          'total_amount': cart.total,
        },
      );
      final orderId = (response as Map)['id'] as String?;
      cart.clear();
      if (!mounted) return;
      // Replace rather than push: backing out of tracking should not land
      // the customer on a checkout for an order they already placed.
      if (orderId != null) {
        Navigator.pushReplacementNamed(
          context,
          AppRoutes.deliveryTracking,
          arguments: DeliveryTrackingArgs(orderId),
        );
      } else {
        Navigator.pushReplacementNamed(context, AppRoutes.myOrders);
      }
    } on ApiException catch (e) {
      if (!mounted) return;
      // 409: the shop sold out between browsing and paying. Nothing was
      // saved, so the cart is brought back in step with what is really on
      // the shelf and the customer can place it again.
      if (e.statusCode == 409) {
        await _resyncCartWithStock();
        if (!mounted) return;
        setState(() {
          _placing = false;
          _error = e.message;
        });
        return;
      }
      setState(() {
        _placing = false;
        _error = e.message;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _placing = false;
        _error = 'Could not place your order. Please try again.';
      });
    }
  }

  /// Re-read the shop's products and trim the cart to what is left.
  ///
  /// Best effort: if this fails the customer still sees the server's reason,
  /// and the cart is simply left as it was.
  Future<void> _resyncCartWithStock() async {
    final cart = CartController.instance;
    final shopId = cart.shopId;
    if (shopId == null) return;
    try {
      final response = await ApiClient.instance.get('/shops/$shopId/products');
      final products = (response as List)
          .whereType<Map<String, dynamic>>()
          .map(Product.fromJson)
          .toList();
      cart.syncWithStock(products);
    } catch (_) {
      // Leave the cart alone; the error message above is what matters.
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: BrandedAppBar(title: Text(tr('delivery.checkout'))),
      body: AnimatedBuilder(
        animation: Listenable.merge([
          CartController.instance,
          DeliveryLocationStore.instance,
        ]),
        builder: (context, _) {
          final cart = CartController.instance;
          if (cart.isEmpty) return const _EmptyCart();
          return _buildBody(context, cart);
        },
      ),
    );
  }

  Widget _buildBody(BuildContext context, CartController cart) {
    final textTheme = Theme.of(context).textTheme;
    final colors = context.appColors;
    final colorScheme = Theme.of(context).colorScheme;
    final destination = DeliveryLocationStore.instance.location;

    return Column(
      children: [
        Expanded(
          child: ListView(
            padding: const EdgeInsets.all(AppSpacing.lg),
            children: [
              Text(
                cart.shopName ?? 'Your order',
                style: textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: AppSpacing.md),
              AppCard(
                child: Column(
                  children: [
                    for (var i = 0; i < cart.lines.length; i++) ...[
                      if (i > 0) const Divider(height: AppSpacing.lg),
                      _CartLineRow(line: cart.lines[i]),
                    ],
                  ],
                ),
              ),
              const SizedBox(height: AppSpacing.lg),
              Text(
                tr('delivery.deliver_to'),
                style: textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: AppSpacing.sm),
              AppCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(
                          destination == null
                              ? Icons.wrong_location_outlined
                              : Icons.place_outlined,
                          size: 20,
                          color: destination == null
                              ? colorScheme.error
                              : colorScheme.primary,
                        ),
                        const SizedBox(width: AppSpacing.sm),
                        Expanded(
                          child: Text(
                            destination?.address ?? tr('delivery.no_location'),
                            style: textTheme.bodyMedium?.copyWith(
                              color: destination == null ? colors.textSecondary : null,
                              fontWeight:
                                  destination == null ? null : FontWeight.w600,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: AppSpacing.md),
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: _pickLocation,
                            icon: const Icon(Icons.map_outlined, size: 18),
                            label: Text(destination == null ? tr('delivery.pick_on_map') : 'Change'),
                          ),
                        ),
                        const SizedBox(width: AppSpacing.sm),
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: _useCurrentLocation,
                            icon: const Icon(Icons.my_location, size: 18),
                            label: Text(tr('delivery.use_my_location')),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              if (_error != null) ...[
                const SizedBox(height: AppSpacing.lg),
                Material(
                  color: colorScheme.errorContainer,
                  borderRadius: BorderRadius.circular(AppRadius.input),
                  child: Padding(
                    padding: const EdgeInsets.all(AppSpacing.md),
                    child: Row(
                      children: [
                        Icon(Icons.error_outline,
                            size: 18, color: colorScheme.onErrorContainer),
                        const SizedBox(width: AppSpacing.sm),
                        Expanded(
                          child: Text(
                            _error!,
                            style: TextStyle(color: colorScheme.onErrorContainer),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
        _CheckoutBar(
          total: cart.total,
          savings: cart.hasSavings ? cart.totalSavings : null,
          itemCount: cart.itemCount,
          placing: _placing,
          onPlaceOrder: _placing ? null : _placeOrder,
        ),
      ],
    );
  }
}

class _CartLineRow extends StatelessWidget {
  final CartLine line;

  const _CartLineRow({required this.line});

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final colors = context.appColors;
    final cart = CartController.instance;

    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                line.product.name,
                style: textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
              ),
              Row(
                children: [
                  if (line.product.hasDiscount) ...[
                    Text(
                      'Rs. ${line.product.price.toStringAsFixed(2)}',
                      style: textTheme.labelSmall?.copyWith(
                        color: colors.textSecondary,
                        decoration: TextDecoration.lineThrough,
                      ),
                    ),
                    const SizedBox(width: 4),
                  ],
                  Text(
                    'Rs. ${line.product.finalPrice.toStringAsFixed(2)} each',
                    style: textTheme.labelSmall?.copyWith(
                      color: line.product.hasDiscount ? colors.success : colors.textSecondary,
                      fontWeight: line.product.hasDiscount ? FontWeight.w700 : null,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        IconButton(
          visualDensity: VisualDensity.compact,
          onPressed: () => cart.remove(line.product.id),
          icon: const Icon(Icons.remove_circle_outline, size: 20),
          tooltip: 'Remove one',
        ),
        Text('${line.quantity}', style: textTheme.titleSmall),
        IconButton(
          visualDensity: VisualDensity.compact,
          onPressed: () => cart.add(
            line.product,
            shopId: cart.shopId ?? line.product.shopId,
            shopName: cart.shopName ?? '',
          ),
          icon: const Icon(Icons.add_circle_outline, size: 20),
          tooltip: 'Add one',
        ),
        SizedBox(
          width: 76,
          child: Text(
            'Rs. ${line.lineTotal.toStringAsFixed(2)}',
            textAlign: TextAlign.right,
            style: textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w700),
          ),
        ),
      ],
    );
  }
}

class _CheckoutBar extends StatelessWidget {
  final double total;
  final double? savings;
  final int itemCount;
  final bool placing;
  final VoidCallback? onPlaceOrder;

  const _CheckoutBar({
    required this.total,
    required this.savings,
    required this.itemCount,
    required this.placing,
    required this.onPlaceOrder,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final colors = context.appColors;
    final textTheme = Theme.of(context).textTheme;

    return Material(
      color: colorScheme.surface,
      elevation: 8,
      shadowColor: Colors.black.withValues(alpha: 0.15),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.lg),
          child: Row(
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    '$itemCount ${itemCount == 1 ? 'item' : 'items'}',
                    style: textTheme.labelSmall?.copyWith(color: colors.textSecondary),
                  ),
                  Text(
                    'Rs. ${total.toStringAsFixed(2)}',
                    style: textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
                  ),
                  if (savings != null)
                    Text(
                      'You save Rs. ${savings!.toStringAsFixed(2)}',
                      style: textTheme.labelSmall?.copyWith(
                        color: colors.success,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                ],
              ),
              const SizedBox(width: AppSpacing.lg),
              Expanded(
                child: AppButton(
                  label: tr('delivery.place_order'),
                  isLoading: placing,
                  // Item 14: an order placed with no signal would be a
                  // promise the app cannot keep.
                  requiresConnection: true,
                  onPressed: onPlaceOrder,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _EmptyCart extends StatelessWidget {
  const _EmptyCart();

  @override
  Widget build(BuildContext context) {
    final colors = context.appColors;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.xxl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.shopping_cart_outlined, size: 56, color: colors.textSecondary),
            const SizedBox(height: AppSpacing.lg),
            Text('Your cart is empty', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: AppSpacing.xs),
            Text(
              'Add products from a shop to place an order.',
              textAlign: TextAlign.center,
              style: Theme.of(context)
                  .textTheme
                  .bodyMedium
                  ?.copyWith(color: colors.textSecondary),
            ),
          ],
        ),
      ),
    );
  }
}
