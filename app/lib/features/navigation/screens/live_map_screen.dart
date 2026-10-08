import 'dart:async';

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
import '../../../core/utils/app_router.dart';
import '../../../core/utils/category_style.dart';
import '../../../core/widgets/status_badge.dart';

/// Fallback center used when device location cannot be resolved (Colombo).
const _fallbackCenter = ll.LatLng(6.9271, 79.8612);

const List<({String label, String value, IconData icon})> _travelModes = [
  (label: 'Driving', value: 'driving', icon: Icons.directions_car),
  (label: 'Walking', value: 'walking', icon: Icons.directions_walk),
  (label: 'Cycling', value: 'cycling', icon: Icons.directions_bike),
];

/// The Live Map screen: shows the device's current location, nearby shops as
/// tappable pins, an optional destination passed in via [LiveMapArgs] (e.g. a
/// shop's "Get Directions" button) or picked by tapping the map or a shop pin,
/// and the driving/walking/cycling road route between them fetched from
/// navigation-service.
class LiveMapScreen extends StatefulWidget {
  final LiveMapArgs args;

  const LiveMapScreen({super.key, required this.args});

  @override
  State<LiveMapScreen> createState() => _LiveMapScreenState();
}

class _LiveMapScreenState extends State<LiveMapScreen> {
  final MapController _mapController = MapController();

  bool _locationLoading = true;
  bool _usedFallbackLocation = false;
  ll.LatLng? _currentLocation;

  ll.LatLng? _destination;
  String? _destinationLabel;
  String _mode = 'driving';

  List<Shop> _shops = const [];

  bool _routeLoading = false;
  String? _routeError;
  List<ll.LatLng> _polylinePoints = const [];
  double? _distanceKm;
  double? _durationMinutes;

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  Future<void> _bootstrap() async {
    await _resolveLocation();
    if (!mounted) return;
    setState(() => _locationLoading = false);

    // Load nearby shops so the map isn't blank -- runs alongside the route.
    unawaited(_fetchShops());

    final destLat = widget.args.destinationLat;
    final destLng = widget.args.destinationLng;
    if (destLat != null && destLng != null) {
      _destination = ll.LatLng(destLat, destLng);
      _destinationLabel = widget.args.destinationLabel;
      await _fetchRoute();
    }
  }

  Future<void> _fetchShops() async {
    final center = _currentLocation ?? _fallbackCenter;
    try {
      final response = await ApiClient.instance.get(
        '/shops',
        query: {'lat': center.latitude, 'lng': center.longitude, 'radius_km': 25, 'limit': 100},
      );
      final shops = (response as List)
          .map((e) => Shop.fromJson(e as Map<String, dynamic>))
          .toList();
      if (!mounted) return;
      setState(() => _shops = shops);
    } catch (_) {
      // A blank map is acceptable if shop-service is briefly unreachable.
    }
  }

  /// Tapping a shop pin routes to it -- same as tapping its "Directions"
  /// button on the shop's detail page.
  void _onShopTapped(Shop shop) {
    setState(() {
      _destination = ll.LatLng(shop.latitude, shop.longitude);
      _destinationLabel = shop.name;
    });
    _fetchRoute();
  }

  Future<void> _resolveLocation() async {
    try {
      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        _currentLocation = _fallbackCenter;
        _usedFallbackLocation = true;
        return;
      }
      final serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) {
        _currentLocation = _fallbackCenter;
        _usedFallbackLocation = true;
        return;
      }
      final position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(accuracy: LocationAccuracy.medium),
      );
      _currentLocation = ll.LatLng(position.latitude, position.longitude);
    } catch (_) {
      _currentLocation = _fallbackCenter;
      _usedFallbackLocation = true;
    }
  }

  Future<void> _fetchRoute() async {
    final origin = _currentLocation;
    final destination = _destination;
    if (origin == null || destination == null) return;

    setState(() {
      _routeLoading = true;
      _routeError = null;
    });

    try {
      final response = await ApiClient.instance.post(
        '/navigation/route',
        body: {
          'origin': {'lat': origin.latitude, 'lng': origin.longitude},
          'destination': {'lat': destination.latitude, 'lng': destination.longitude},
          'waypoints': const [],
          'mode': _mode,
          'language': 'en',
        },
      );
      final map = response as Map<String, dynamic>;
      final points = (map['polyline'] as List? ?? [])
          .map((p) => ll.LatLng(
                (p['lat'] as num).toDouble(),
                (p['lng'] as num).toDouble(),
              ))
          .toList();
      if (!mounted) return;
      setState(() {
        _polylinePoints = points;
        _distanceKm = (map['distance_km'] as num?)?.toDouble();
        _durationMinutes = (map['duration_minutes'] as num?)?.toDouble();
        _routeLoading = false;
      });
      _centerOnRoute(origin, destination);
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _routeLoading = false;
        _routeError = e.message;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _routeLoading = false;
        _routeError = 'Could not load the route. Please try again.';
      });
    }
  }

  /// Centers the map on the midpoint of [origin]/[destination]. Used after a
  /// route loads, and reused by the bottom sheet's "focus route" button.
  void _centerOnRoute(ll.LatLng origin, ll.LatLng destination) {
    final mid = ll.LatLng(
      (origin.latitude + destination.latitude) / 2,
      (origin.longitude + destination.longitude) / 2,
    );
    try {
      _mapController.move(mid, 13);
    } catch (_) {
      // Map may not be attached yet on a very fast response -- harmless.
    }
  }

  void _focusOnRoute() {
    final origin = _currentLocation;
    final destination = _destination;
    if (origin == null || destination == null) return;
    _centerOnRoute(origin, destination);
  }

  void _recenterOnMe() {
    final origin = _currentLocation ?? _fallbackCenter;
    try {
      _mapController.move(origin, 15);
    } catch (_) {
      // Map may not be attached yet -- harmless.
    }
  }

  void _onMapTapped(TapPosition tapPosition, ll.LatLng point) {
    setState(() {
      _destination = point;
      _destinationLabel = null;
    });
    _fetchRoute();
  }

  void _onModeSelected(String mode) {
    if (_mode == mode) return;
    setState(() => _mode = mode);
    if (_destination != null) _fetchRoute();
  }

  void _openSearch() {
    Navigator.pushNamed(context, AppRoutes.shopList);
  }

  void _showTravelModeSheet() {
    showModalBottomSheet<void>(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(AppRadius.card)),
      ),
      builder: (sheetContext) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(height: AppSpacing.sm),
              for (final option in _travelModes)
                ListTile(
                  leading: Icon(option.icon),
                  title: Text(option.label),
                  trailing: _mode == option.value
                      ? Icon(Icons.check_rounded, color: Theme.of(sheetContext).colorScheme.primary)
                      : null,
                  onTap: () {
                    Navigator.pop(sheetContext);
                    _onModeSelected(option.value);
                  },
                ),
              const SizedBox(height: AppSpacing.sm),
            ],
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Live Map')),
      body: _locationLoading
          ? const Center(child: CircularProgressIndicator())
          : _buildMapStack(context),
    );
  }

  Widget _buildMapStack(BuildContext context) {
    final origin = _currentLocation ?? _fallbackCenter;
    final colorScheme = Theme.of(context).colorScheme;

    // Vertical space reserved at the top for the floating search bar so the
    // status banners below it don't overlap it.
    const topBarReserve = AppSpacing.xxxl + AppSpacing.md;

    return Stack(
      children: [
        FlutterMap(
          mapController: _mapController,
          options: MapOptions(
            initialCenter: _destination ?? origin,
            initialZoom: 14,
            onTap: _onMapTapped,
          ),
          children: [
            TileLayer(
              urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
              userAgentPackageName: 'com.microlink.app',
            ),
            if (_polylinePoints.isNotEmpty)
              PolylineLayer(
                polylines: [
                  Polyline(
                    points: _polylinePoints,
                    strokeWidth: 4,
                    color: colorScheme.primary,
                  ),
                ],
              ),
            MarkerLayer(
              markers: [
                // Shop pins -- tap one to route to it.
                for (final shop in _shops)
                  Marker(
                    point: ll.LatLng(shop.latitude, shop.longitude),
                    width: 40,
                    height: 40,
                    child: _ShopPin(
                      shop: shop,
                      onTap: () => _onShopTapped(shop),
                    ),
                  ),
                if (_destination != null)
                  Marker(
                    point: _destination!,
                    width: 36,
                    height: 36,
                    child: Icon(Icons.location_pin, color: colorScheme.error, size: 36),
                  ),
                Marker(
                  point: origin,
                  child: Icon(Icons.my_location, color: colorScheme.primary),
                ),
              ],
            ),
          ],
        ),
        Positioned(
          top: AppSpacing.md,
          left: AppSpacing.md,
          right: AppSpacing.md,
          child: _MapSearchBar(onTap: _openSearch),
        ),
        if (_usedFallbackLocation)
          Positioned(
            top: topBarReserve,
            left: AppSpacing.md,
            right: AppSpacing.md,
            child: _InfoBanner(
              icon: Icons.info_outline,
              message: "Couldn't get your exact location -- showing Colombo as a default.",
              onDismiss: () => setState(() => _usedFallbackLocation = false),
            ),
          ),
        if (_routeError != null)
          Positioned(
            top: _usedFallbackLocation ? topBarReserve + AppSpacing.xxxl : topBarReserve,
            left: AppSpacing.md,
            right: AppSpacing.md,
            child: _InfoBanner(
              icon: Icons.error_outline,
              message: _routeError!,
              isError: true,
              onDismiss: () => setState(() => _routeError = null),
              onRetry: _destination != null ? _fetchRoute : null,
            ),
          ),
        if (_routeLoading)
          Positioned(
            top: topBarReserve,
            right: AppSpacing.md,
            child: Container(
              padding: const EdgeInsets.all(AppSpacing.sm),
              decoration: BoxDecoration(
                color: colorScheme.surface,
                shape: BoxShape.circle,
                boxShadow: const [BoxShadow(blurRadius: 4, color: Colors.black26)],
              ),
              child: const SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2.4),
              ),
            ),
          ),
        Positioned(
          right: AppSpacing.md,
          bottom: AppSpacing.xxxl * 3 + AppSpacing.lg,
          child: Column(
            children: [
              _MapFab(icon: Icons.my_location, onPressed: _recenterOnMe),
              const SizedBox(height: AppSpacing.md),
              _MapFab(icon: Icons.alt_route, onPressed: _showTravelModeSheet),
            ],
          ),
        ),
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          child: _DestinationSheet(
            destination: _destination,
            destinationLabel: _destinationLabel,
            mode: _mode,
            distanceKm: _distanceKm,
            durationMinutes: _durationMinutes,
            onModeSelected: _onModeSelected,
            onFocusRoute: _focusOnRoute,
          ),
        ),
      ],
    );
  }
}

/// A tappable shop pin on the map: a round category-tinted badge, dimmed when
/// the shop is currently closed. Tapping it routes there.
class _ShopPin extends StatelessWidget {
  final Shop shop;
  final VoidCallback onTap;

  const _ShopPin({required this.shop, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final tint = categoryColors(context, shop.category);
    return GestureDetector(
      onTap: onTap,
      child: Tooltip(
        message: '${shop.name}${shop.isOpen ? '' : ' (closed)'}',
        child: Opacity(
          opacity: shop.isOpen ? 1 : 0.45,
          child: Container(
            decoration: BoxDecoration(
              color: tint.background,
              shape: BoxShape.circle,
              border: Border.all(color: colorScheme.surface, width: 2),
              boxShadow: const [BoxShadow(blurRadius: 3, color: Colors.black26)],
            ),
            alignment: Alignment.center,
            child: Icon(categoryIcon(shop.category), size: 18, color: tint.foreground),
          ),
        ),
      ),
    );
  }
}

/// The pill-shaped floating search bar overlaid at the top of the map.
/// Hands off to the full shop search screen rather than duplicating search
/// logic here.
class _MapSearchBar extends StatelessWidget {
  final VoidCallback onTap;

  const _MapSearchBar({required this.onTap});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final colors = context.appColors;
    return Material(
      color: colorScheme.surface,
      borderRadius: BorderRadius.circular(AppRadius.pill),
      elevation: 3,
      shadowColor: Colors.black.withValues(alpha: 0.15),
      child: InkWell(
        borderRadius: BorderRadius.circular(AppRadius.pill),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg, vertical: AppSpacing.md),
          child: Row(
            children: [
              Icon(Icons.search, size: 18, color: colors.textSecondary),
              const SizedBox(width: AppSpacing.sm),
              Text(
                'Search this area…',
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: colors.textSecondary),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A small circular white floating action button used for the map's
/// "my location" and "travel mode" controls.
class _MapFab extends StatelessWidget {
  final IconData icon;
  final VoidCallback onPressed;

  const _MapFab({required this.icon, required this.onPressed});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Material(
      color: colorScheme.surface,
      shape: const CircleBorder(),
      elevation: 3,
      shadowColor: Colors.black.withValues(alpha: 0.15),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onPressed,
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.md),
          child: Icon(icon, color: colorScheme.onSurface, size: 20),
        ),
      ),
    );
  }
}

/// The bottom sheet-style card anchored to the bottom of the map: either a
/// prompt to pick a destination, or the selected destination's distance,
/// ETA and travel mode, with a button to re-center the map on the route.
class _DestinationSheet extends StatelessWidget {
  final ll.LatLng? destination;
  final String? destinationLabel;
  final String mode;
  final double? distanceKm;
  final double? durationMinutes;
  final void Function(String mode) onModeSelected;
  final VoidCallback onFocusRoute;

  const _DestinationSheet({
    required this.destination,
    required this.destinationLabel,
    required this.mode,
    required this.distanceKm,
    required this.durationMinutes,
    required this.onModeSelected,
    required this.onFocusRoute,
  });

  @override
  Widget build(BuildContext context) {
    final colors = context.appColors;
    final colorScheme = Theme.of(context).colorScheme;
    final modeInfo = _travelModes.firstWhere((m) => m.value == mode);

    return Material(
      color: colorScheme.surface,
      borderRadius: const BorderRadius.vertical(top: Radius.circular(AppRadius.card + 6)),
      elevation: 8,
      shadowColor: Colors.black.withValues(alpha: 0.15),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(AppSpacing.lg, AppSpacing.sm, AppSpacing.lg, AppSpacing.lg),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 38,
                  height: 4,
                  margin: const EdgeInsets.only(bottom: AppSpacing.md),
                  decoration: BoxDecoration(
                    color: colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(AppRadius.pill),
                  ),
                ),
              ),
              if (destination == null)
                Text(
                  'Tap a shop pin, or anywhere on the map, to get directions.',
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: colors.textSecondary),
                )
              else
                Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Container(
                      width: 44,
                      height: 44,
                      decoration: BoxDecoration(
                        color: colorScheme.primaryContainer,
                        borderRadius: BorderRadius.circular(AppRadius.input),
                      ),
                      alignment: Alignment.center,
                      child: Icon(Icons.directions_outlined, color: colorScheme.primary),
                    ),
                    const SizedBox(width: AppSpacing.md),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            destinationLabel ?? 'Selected destination',
                            style: Theme.of(context)
                                .textTheme
                                .titleSmall
                                ?.copyWith(fontWeight: FontWeight.w700),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          const SizedBox(height: AppSpacing.xs),
                          Wrap(
                            spacing: AppSpacing.sm,
                            runSpacing: AppSpacing.xs,
                            crossAxisAlignment: WrapCrossAlignment.center,
                            children: [
                              if (distanceKm != null)
                                Text(
                                  '${distanceKm!.toStringAsFixed(1)} km',
                                  style: Theme.of(context)
                                      .textTheme
                                      .bodySmall
                                      ?.copyWith(color: colors.textSecondary),
                                ),
                              if (durationMinutes != null)
                                Text(
                                  '${durationMinutes!.round()} min',
                                  style: Theme.of(context)
                                      .textTheme
                                      .bodySmall
                                      ?.copyWith(color: colors.textSecondary),
                                ),
                              StatusBadge(
                                label: modeInfo.label,
                                background: colorScheme.secondaryContainer,
                                foreground: colorScheme.onSecondaryContainer,
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: AppSpacing.sm),
                    Material(
                      color: colorScheme.primary,
                      shape: const CircleBorder(),
                      child: InkWell(
                        customBorder: const CircleBorder(),
                        onTap: onFocusRoute,
                        child: Padding(
                          padding: const EdgeInsets.all(AppSpacing.sm),
                          child: Icon(Icons.arrow_forward_rounded, color: colorScheme.onPrimary, size: 18),
                        ),
                      ),
                    ),
                  ],
                ),
              const SizedBox(height: AppSpacing.md),
              SizedBox(
                height: 36,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  itemCount: _travelModes.length,
                  separatorBuilder: (_, _) => const SizedBox(width: AppSpacing.sm),
                  itemBuilder: (context, index) {
                    final option = _travelModes[index];
                    return ChoiceChip(
                      label: Text(option.label),
                      avatar: Icon(option.icon, size: 16),
                      selected: mode == option.value,
                      onSelected: (_) => onModeSelected(option.value),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _InfoBanner extends StatelessWidget {
  final IconData icon;
  final String message;
  final bool isError;
  final VoidCallback onDismiss;
  final VoidCallback? onRetry;

  const _InfoBanner({
    required this.icon,
    required this.message,
    required this.onDismiss,
    this.isError = false,
    this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final background = isError ? colorScheme.errorContainer : colorScheme.secondaryContainer;
    final foreground = isError ? colorScheme.onErrorContainer : colorScheme.onSecondaryContainer;
    return Material(
      color: background,
      borderRadius: BorderRadius.circular(AppRadius.input),
      elevation: 2,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md, vertical: AppSpacing.sm),
        child: Row(
          children: [
            Icon(icon, size: 18, color: foreground),
            const SizedBox(width: AppSpacing.sm),
            Expanded(
              child: Text(message, style: TextStyle(color: foreground, fontSize: 13)),
            ),
            if (onRetry != null)
              TextButton(
                onPressed: onRetry,
                style: TextButton.styleFrom(foregroundColor: foreground, minimumSize: Size.zero),
                child: const Text('Retry'),
              ),
            InkWell(
              onTap: onDismiss,
              child: Icon(Icons.close, size: 18, color: foreground),
            ),
          ],
        ),
      ),
    );
  }
}
