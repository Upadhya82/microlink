import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart' as ll;

import '../../../core/constants/app_constants.dart';
import '../../../core/models/shop.dart';
import '../../../core/network/api_client.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/theme/app_colors_extension.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/utils/route_args.dart';
import '../../../core/widgets/app_button.dart';
import '../../../core/widgets/app_card.dart';
import '../../../core/widgets/app_text_field.dart';
import '../../../core/widgets/required_fields_note.dart';
import '../../../core/widgets/branded_app_bar.dart';

enum _PinMode { drop, pickup }

/// SRS 5.6 "Request Delivery Assistance" (REQ-DELIV-1 to REQ-DELIV-4).
///
/// The customer picks a shop, checks the pickup point (pre-filled with the
/// shop, editable), sets the drop address / map pin and may add a short note
/// (max 200 characters). There is NO cart and NO payment: the fee is only an
/// optional offer that the customer settles with the agent directly.
class RequestDeliveryScreen extends StatefulWidget {
  final RequestDeliveryArgs args;

  const RequestDeliveryScreen({super.key, this.args = const RequestDeliveryArgs()});

  @override
  State<RequestDeliveryScreen> createState() => _RequestDeliveryScreenState();
}

class _RequestDeliveryScreenState extends State<RequestDeliveryScreen> {
  static const _defaultCenter = ll.LatLng(6.9271, 79.8612);
  static const _noteLimit = 200;

  final _formKey = GlobalKey<FormState>();
  final _pickupController = TextEditingController();
  final _dropController = TextEditingController();
  final _noteController = TextEditingController();
  final _feeController = TextEditingController();
  final _mapController = MapController();

  String? _shopId;
  String? _shopName;
  ll.LatLng? _pickupPoint;
  ll.LatLng? _dropPoint;
  _PinMode _pinMode = _PinMode.drop;

  List<Shop> _shops = const [];
  bool _loadingShops = false;
  String? _shopsError;
  bool _locating = false;
  bool _submitting = false;

  bool get _shopLocked => widget.args.shopId != null;

  @override
  void initState() {
    super.initState();
    final args = widget.args;
    _shopId = args.shopId;
    _shopName = args.shopName;
    if (args.pickupAddress != null) _pickupController.text = args.pickupAddress!;
    if (args.pickupLat != null && args.pickupLng != null) {
      _pickupPoint = ll.LatLng(args.pickupLat!, args.pickupLng!);
    }
    if (!_shopLocked) _loadShops();
  }

  @override
  void dispose() {
    _pickupController.dispose();
    _dropController.dispose();
    _noteController.dispose();
    _feeController.dispose();
    super.dispose();
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _loadShops() async {
    setState(() {
      _loadingShops = true;
      _shopsError = null;
    });
    try {
      final response = await ApiClient.instance.get('/shops');
      final shops = (response as List)
          .map((e) => Shop.fromJson(Map<String, dynamic>.from(e as Map)))
          .toList();
      if (!mounted) return;
      setState(() => _shops = shops);
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _shopsError = e.message);
    } catch (_) {
      if (!mounted) return;
      setState(() => _shopsError = 'Could not load shops. Please try again.');
    } finally {
      if (mounted) setState(() => _loadingShops = false);
    }
  }

  void _onShopChosen(Shop? shop) {
    if (shop == null) return;
    final point = ll.LatLng(shop.latitude, shop.longitude);
    setState(() {
      _shopId = shop.id;
      _shopName = shop.name;
      _pickupController.text = shop.address;
      _pickupPoint = point;
    });
    _mapController.move(point, 15);
  }

  void _onMapTap(ll.LatLng point) {
    setState(() {
      if (_pinMode == _PinMode.drop) {
        _dropPoint = point;
      } else {
        _pickupPoint = point;
      }
    });
  }

  Future<void> _useMyLocation() async {
    setState(() => _locating = true);
    try {
      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        throw const ApiException('Location permission was denied.');
      }
      if (!await Geolocator.isLocationServiceEnabled()) {
        throw const ApiException('Location services are turned off.');
      }
      final position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(accuracy: LocationAccuracy.high),
      );
      final point = ll.LatLng(position.latitude, position.longitude);
      if (!mounted) return;
      setState(() => _dropPoint = point);
      _mapController.move(point, 16);
    } on ApiException catch (e) {
      if (!mounted) return;
      _showMessage(e.message);
    } catch (_) {
      if (!mounted) return;
      _showMessage('Could not get your location.');
    } finally {
      if (mounted) setState(() => _locating = false);
    }
  }

  Future<void> _submit() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    if (_shopId == null) {
      _showMessage('Please choose a shop.');
      return;
    }
    final drop = _dropPoint;
    if (drop == null) {
      _showMessage('Tap the map or use your current location to set the drop pin.');
      return;
    }
    final pickup = _pickupPoint;
    final note = _noteController.text.trim();
    final fee = double.tryParse(_feeController.text.trim());

    setState(() => _submitting = true);
    try {
      final response = await ApiClient.instance.post(
        '/delivery/orders',
        body: {
          'shop_id': _shopId,
          'pickup_address': _pickupController.text.trim(),
          if (pickup != null) 'pickup_lat': pickup.latitude,
          if (pickup != null) 'pickup_lng': pickup.longitude,
          'delivery_address': _dropController.text.trim(),
          'delivery_lat': drop.latitude,
          'delivery_lng': drop.longitude,
          if (note.isNotEmpty) 'item_description': note,
          'total_amount': fee ?? 0,
        },
      );
      if (!mounted) return;
      final orderId = (response as Map)['id'] as String;
      _showMessage('Delivery request sent. Nearby agents have been notified.');
      Navigator.pushReplacementNamed(
        context,
        AppRoutes.deliveryTracking,
        arguments: DeliveryTrackingArgs(orderId),
      );
    } on ApiException catch (e) {
      if (!mounted) return;
      _showMessage(e.message);
    } catch (_) {
      if (!mounted) return;
      _showMessage('Could not send your request. Please try again.');
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  Widget _buildShopField(BuildContext context) {
    if (_shopLocked) {
      return AppCard(
        child: Row(
          children: [
            Icon(Icons.storefront_outlined, color: Theme.of(context).colorScheme.primary),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              child: Text(
                _shopName ?? 'Selected shop',
                style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
              ),
            ),
          ],
        ),
      );
    }
    if (_loadingShops) return const LinearProgressIndicator();
    if (_shopsError != null) {
      return Row(
        children: [
          Expanded(
            child: Text(_shopsError!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
          ),
          TextButton(onPressed: _loadShops, child: const Text('Retry')),
        ],
      );
    }
    return DropdownButtonFormField<Shop>(
      isExpanded: true,
      decoration: const InputDecoration(labelText: 'Shop to collect from'),
      items: _shops
          .map((shop) => DropdownMenuItem<Shop>(
                value: shop,
                child: Text(shop.name, overflow: TextOverflow.ellipsis),
              ))
          .toList(),
      onChanged: _onShopChosen,
      validator: (value) => value == null ? 'Choose a shop' : null,
    );
  }

  Widget _buildMap(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final center = _pickupPoint ?? _dropPoint ?? _defaultCenter;
    return SizedBox(
      height: 240,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(AppRadius.card),
        child: FlutterMap(
          mapController: _mapController,
          options: MapOptions(
            initialCenter: center,
            initialZoom: 14,
            onTap: (_, point) => _onMapTap(point),
          ),
          children: [
            TileLayer(
              urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
              userAgentPackageName: 'com.microlink.app',
            ),
            MarkerLayer(
              markers: [
                if (_pickupPoint != null)
                  Marker(
                    point: _pickupPoint!,
                    width: 40,
                    height: 40,
                    child: Icon(Icons.storefront, color: colorScheme.primary, size: 32),
                  ),
                if (_dropPoint != null)
                  Marker(
                    point: _dropPoint!,
                    width: 40,
                    height: 40,
                    child: Icon(Icons.location_pin, color: colorScheme.error, size: 36),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.appColors;
    final smallMuted =
        Theme.of(context).textTheme.bodySmall?.copyWith(color: colors.textSecondary);

    return Scaffold(
      appBar: BrandedAppBar(title: const Text('Request delivery')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(AppSpacing.lg),
        child: Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'A delivery agent near the pickup point will collect your item and bring it to you.',
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: colors.textSecondary),
              ),
              const SizedBox(height: AppSpacing.lg),
              const RequiredFieldsNote(),
              _buildShopField(context),
              const SizedBox(height: AppSpacing.lg),
              AppTextField(
                controller: _pickupController,
                label: 'Pickup address',
                isRequired: true,
                hint: 'Filled in from the shop. You can edit it.',
                prefixIcon: Icons.storefront_outlined,
                validator: (v) => (v == null || v.trim().isEmpty) ? 'Enter the pickup address' : null,
              ),
              const SizedBox(height: AppSpacing.lg),
              AppTextField(
                controller: _dropController,
                label: 'Drop address',
                isRequired: true,
                hint: 'Where should we deliver?',
                prefixIcon: Icons.home_outlined,
                validator: (v) => (v == null || v.trim().isEmpty) ? 'Enter the drop address' : null,
              ),
              const SizedBox(height: AppSpacing.lg),
              Text('Set the pins on the map', style: Theme.of(context).textTheme.titleSmall),
              const SizedBox(height: AppSpacing.sm),
              Wrap(
                spacing: AppSpacing.sm,
                children: [
                  ChoiceChip(
                    label: const Text('Drop pin'),
                    selected: _pinMode == _PinMode.drop,
                    onSelected: (_) => setState(() => _pinMode = _PinMode.drop),
                  ),
                  ChoiceChip(
                    label: const Text('Pickup pin'),
                    selected: _pinMode == _PinMode.pickup,
                    onSelected: (_) => setState(() => _pinMode = _PinMode.pickup),
                  ),
                ],
              ),
              const SizedBox(height: AppSpacing.sm),
              _buildMap(context),
              const SizedBox(height: AppSpacing.sm),
              Text('Pick a chip above, then tap the map to place that pin.', style: smallMuted),
              const SizedBox(height: AppSpacing.sm),
              AppButton(
                label: 'Use my current location as the drop pin',
                variant: AppButtonVariant.outlined,
                icon: Icons.my_location_outlined,
                isLoading: _locating,
                onPressed: _useMyLocation,
              ),
              const SizedBox(height: AppSpacing.xl),
              AppTextField(
                controller: _noteController,
                label: 'What should the agent bring? (optional)',
                hint: 'e.g. 2 bags of rice',
                maxLines: 3,
                onChanged: (_) => setState(() {}),
                validator: (v) =>
                    (v != null && v.trim().length > _noteLimit) ? 'Keep it under $_noteLimit characters' : null,
              ),
              Align(
                alignment: Alignment.centerRight,
                child: Text('${_noteController.text.length}/$_noteLimit', style: smallMuted),
              ),
              const SizedBox(height: AppSpacing.md),
              AppTextField(
                controller: _feeController,
                label: 'Fee you offer the agent, Rs. (optional)',
                hint: 'Leave empty to agree it with the agent',
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                prefixIcon: Icons.payments_outlined,
                validator: (v) {
                  final text = v?.trim() ?? '';
                  if (text.isEmpty) return null;
                  final value = double.tryParse(text);
                  return (value == null || value < 0) ? 'Enter a valid amount' : null;
                },
              ),
              const SizedBox(height: AppSpacing.sm),
              Text(
                'MicroLink does not take any payment. You pay the agent directly.',
                style: smallMuted,
              ),
              const SizedBox(height: AppSpacing.xl),
              AppButton(
                label: 'Send delivery request',
                isLoading: _submitting,
                onPressed: _submit,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
