import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart' as ll;

import '../../../core/constants/app_constants.dart';
import '../../../core/location/delivery_location_store.dart';
import '../../../core/l10n/app_strings.dart';
import '../../../core/location/location_service.dart';
import '../../../core/models/order.dart';
import '../../../core/models/picked_location.dart';
import '../../../core/models/route_step.dart';
import '../../../core/models/shop.dart';
import '../../../core/network/api_client.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/network/session_manager.dart';
import '../../../core/theme/app_colors_extension.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/utils/app_router.dart' show LiveMapArgs, ShopDetailArgs;
import '../../../core/utils/category_style.dart';
import '../../location/screens/location_picker_screen.dart';
import '../../location/widgets/area_search_field.dart';
import '../../location/widgets/map_pin.dart';
import '../../location/widgets/map_tile_layer.dart';
import '../voice_guidance.dart';
import '../../../core/widgets/branded_app_bar.dart';

const List<({String label, String value, IconData icon})> _travelModes = [
  (label: 'Driving', value: 'driving', icon: Icons.directions_car),
  (label: 'Walking', value: 'walking', icon: Icons.directions_walk),
  (label: 'Cycling', value: 'cycling', icon: Icons.directions_bike),
];

/// Order statuses an agent is actively working. Delivered and cancelled
/// orders are history and would only clutter the map.
const Set<String> _activeAgentStatuses = {'accepted', 'picked_up', 'in_transit'};

/// How far the map must be panned from the point the shops were loaded for
/// before offering to reload. Below this, the existing pins still describe
/// what is on screen.
const double _researchThresholdKm = 2.0;

/// The Live Map.
///
/// One screen, two jobs, chosen by role:
///
/// * **Customer** -- their live position, shops around whatever area they are
///   looking at, a search box for jumping to any town or landmark in Sri
///   Lanka (so they can order from somewhere they are not), and a shortcut
///   into the delivery-location picker.
/// * **Delivery agent** -- their live position plus the pickup and dropoff
///   points of the deliveries they are currently carrying, with a route to
///   whichever one they select.
///
/// Both share the map, the route rendering and the follow-me tracking; only
/// the bottom sheet and the pins differ.
class LiveMapScreen extends StatefulWidget {
  final LiveMapArgs args;

  const LiveMapScreen({super.key, required this.args});

  @override
  State<LiveMapScreen> createState() => _LiveMapScreenState();
}

class _LiveMapScreenState extends State<LiveMapScreen> {
  final MapController _mapController = MapController();

  // --- location -----------------------------------------------------------
  ll.LatLng? _myLocation;
  LocationFailure? _locationFailure;
  bool _booting = true;

  /// While true the map re-centres on every position update. Switched off as
  /// soon as the user pans, so tracking never fights their gesture.
  bool _followMe = true;
  StreamSubscription<ll.LatLng>? _positionSub;

  // --- what the map is showing -------------------------------------------
  /// The point the currently displayed shops were loaded around.
  ll.LatLng? _loadedAround;
  String? _areaLabel;
  ll.LatLng _cameraCenter = kFallbackCenter;
  bool _canSearchThisArea = false;

  List<Shop> _shops = const [];
  bool _shopsLoading = false;

  // --- agent --------------------------------------------------------------
  List<DeliveryOrder> _agentOrders = const [];
  /// Pickup points for the agent's orders, keyed by order id. Looked up from
  /// shop-service because an order only stores its dropoff coordinates.
  final Map<String, ({ll.LatLng point, String name})> _pickups = {};

  // --- route --------------------------------------------------------------
  ll.LatLng? _destination;
  String? _destinationLabel;
  String _mode = 'driving';
  // The map offers a single Navigation action rather than a fastest/shortest
  // pair, so the request always asks for the fastest route. The backend still
  // supports both, so restoring the choice is a UI change only.
  static const String _preference = 'fastest';
  bool _routeLoading = false;
  String? _routeError;
  List<ll.LatLng> _polylinePoints = const [];
  double? _distanceKm;
  double? _durationMinutes;

  // --- voice guidance + live trip readout (REQ-NAV-3, REQ-NAV-5)
  final VoiceGuidance _voice = VoiceGuidance();
  List<RouteStep> _steps = const [];
  RouteStep? _currentStep;
  bool _muted = false;
  double? _speedKmh;
  ll.LatLng? _lastTrackedPoint;
  DateTime? _lastTrackedAt;

  bool get _isAgent => SessionManager.instance.isDeliveryAgent;

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  @override
  void dispose() {
    _voice.dispose();
    _positionSub?.cancel();
    _mapController.dispose();
    super.dispose();
  }

  Future<void> _bootstrap() async {
    final result = await LocationService.instance.currentPosition();
    if (!mounted) return;
    setState(() {
      _myLocation = result.position;
      _cameraCenter = result.position;
      _locationFailure = result.failure;
      _booting = false;
    });

    _startTracking();

    if (_isAgent) {
      unawaited(_loadAgentOrders());
    } else {
      unawaited(_loadShopsAround(result.position));
    }

    final destLat = widget.args.destinationLat;
    final destLng = widget.args.destinationLng;
    if (destLat != null && destLng != null) {
      setState(() {
        _destination = ll.LatLng(destLat, destLng);
        _destinationLabel = widget.args.destinationLabel;
      });
      await _fetchRoute();
    }
  }

  /// Live position updates. This is what makes the map "live" for both roles:
  /// the customer sees themselves move while browsing, and the agent's dot
  /// tracks them along the delivery.
  void _startTracking() {
    _positionSub?.cancel();
    _positionSub = LocationService.instance.positionStream().listen((point) {
      if (!mounted) return;
      final speed = _speedFrom(point);
      setState(() {
        _myLocation = point;
        // A real fix arrived, so any earlier fallback notice is now wrong.
        _locationFailure = null;
        if (speed != null) _speedKmh = speed;
      });
      if (_followMe) _moveCamera(point, _mapController.camera.zoom);
      _announceNearbyStep(point);
    });
  }

  /// Speed from consecutive fixes. Geolocator exposes a speed field, but it
  /// is unreliable on web and on low-end Android, so this derives it from the
  /// distance and time between updates instead.
  double? _speedFrom(ll.LatLng point) {
    final previous = _lastTrackedPoint;
    final previousAt = _lastTrackedAt;
    final now = DateTime.now();
    _lastTrackedPoint = point;
    _lastTrackedAt = now;
    if (previous == null || previousAt == null) return null;
    final seconds = now.difference(previousAt).inMilliseconds / 1000;
    // Too short a gap makes GPS jitter look like speed.
    if (seconds < 1) return null;
    final metres = LocationService.instance.distanceKm(previous, point) * 1000;
    final kmh = (metres / seconds) * 3.6;
    // Anything above this is a GPS jump, not a delivery rider.
    return kmh > 200 ? null : kmh;
  }

  Future<void> _announceNearbyStep(ll.LatLng point) async {
    if (_steps.isEmpty) return;
    final spoken = await _voice.onPositionChanged(point);
    if (!mounted) return;
    if (spoken != null) setState(() => _currentStep = spoken);
  }

  Future<void> _toggleMute() async {
    final next = !_muted;
    await _voice.setMuted(next);
    if (!mounted) return;
    setState(() => _muted = next);
  }

  /// Start turn-by-turn guidance: lock the camera to the driver, make sure
  /// they can hear the instructions, and jump to where they actually are.
  Future<void> _startNavigation() async {
    if (_muted) await _voice.setMuted(false);
    if (!mounted) return;
    setState(() {
      _muted = false;
      _followMe = true;
    });
    final me = _myLocation;
    if (me != null) _moveCamera(me, 16);
  }

  // ------------------------------------------------------------------ shops

  Future<void> _loadShopsAround(ll.LatLng center, {String? label}) async {
    setState(() {
      _shopsLoading = true;
      _canSearchThisArea = false;
    });
    try {
      final response = await ApiClient.instance.get(
        '/shops',
        query: {
          'lat': center.latitude,
          'lng': center.longitude,
          'radius_km': 25,
          'limit': 100,
        },
      );
      final shops = (response as List)
          .map((e) => Shop.fromJson(e as Map<String, dynamic>))
          .toList();
      if (!mounted) return;
      setState(() {
        _shops = shops;
        _loadedAround = center;
        if (label != null) _areaLabel = label;
        _shopsLoading = false;
      });
    } catch (_) {
      if (!mounted) return;
      // A map with no pins is still a usable map; don't block it on this.
      setState(() => _shopsLoading = false);
    }
  }

  void _onAreaSelected(SearchedArea area) {
    final point = ll.LatLng(area.latitude, area.longitude);
    setState(() {
      _followMe = false;
      _areaLabel = area.name;
    });
    _moveCamera(point, 14);
    _loadShopsAround(point, label: area.name);
  }

  // ------------------------------------------------------------------ agent

  Future<void> _loadAgentOrders() async {
    try {
      final response = await ApiClient.instance.get('/delivery/orders/me');
      final orders = (response as List)
          .map((e) => DeliveryOrder.fromJson(Map<String, dynamic>.from(e as Map)))
          .where((o) => _activeAgentStatuses.contains(o.status))
          .toList();
      if (!mounted) return;
      setState(() => _agentOrders = orders);
      unawaited(_loadPickupPoints(orders));
    } catch (_) {
      // Driver Home remains the authoritative job list; the map just can't
      // decorate itself this time.
    }
  }

  /// An order carries only its dropoff point, so the pickup pin comes from
  /// the shop record. Failures are per-order: one missing shop should not
  /// cost the agent the rest of their pins.
  Future<void> _loadPickupPoints(List<DeliveryOrder> orders) async {
    for (final order in orders) {
      if (_pickups.containsKey(order.id)) continue;
      try {
        final response = await ApiClient.instance.get('/shops/${order.shopId}');
        final shop = Shop.fromJson(Map<String, dynamic>.from(response as Map));
        if (!mounted) return;
        setState(() {
          _pickups[order.id] = (
            point: ll.LatLng(shop.latitude, shop.longitude),
            name: shop.name,
          );
        });
      } catch (_) {
        // Leave this order without a pickup pin.
      }
    }
  }

  void _routeToOrder(DeliveryOrder order, {required bool toPickup}) {
    final pickup = _pickups[order.id];
    if (toPickup && pickup == null) return;
    setState(() {
      _followMe = false;
      _destination =
          toPickup ? pickup!.point : ll.LatLng(order.deliveryLat, order.deliveryLng);
      _destinationLabel = toPickup
          ? 'Pick up at ${pickup!.name}'
          : 'Drop off: ${order.deliveryAddress}';
    });
    _fetchRoute();
  }

  // ------------------------------------------------------------------ route

  Future<void> _fetchRoute() async {
    final origin = _myLocation;
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
          'preference': _preference,
          'language': LanguageController.instance.code,
        },
      );
      final map = response as Map<String, dynamic>;
      final points = (map['polyline'] as List? ?? [])
          .map((p) => ll.LatLng(
                (p['lat'] as num).toDouble(),
                (p['lng'] as num).toDouble(),
              ))
          .toList();
      final steps = (map['steps'] as List? ?? [])
          .map((e) => RouteStep.fromJson(Map<String, dynamic>.from(e as Map)))
          .toList();
      if (!mounted) return;
      setState(() {
        _polylinePoints = points;
        _distanceKm = (map['distance_km'] as num?)?.toDouble();
        _durationMinutes = (map['duration_minutes'] as num?)?.toDouble();
        _steps = steps;
        _currentStep = steps.isEmpty ? null : steps.first;
        _routeLoading = false;
        _followMe = false;
      });
      await _voice.setRoute(
        steps,
        voiceLocale: map['voice_locale'] as String? ?? 'en-US',
      );
      _fitRoute(origin, destination);
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

  void _clearRoute() {
    _voice.setRoute(const [], voiceLocale: 'en-US');
    setState(() {
      _destination = null;
      _destinationLabel = null;
      _polylinePoints = const [];
      _distanceKm = null;
      _durationMinutes = null;
      _steps = const [];
      _currentStep = null;
      _routeError = null;
    });
  }

  /// Frames both ends of the route instead of guessing a zoom from the
  /// midpoint, which used to cut off long routes entirely.
  void _fitRoute(ll.LatLng origin, ll.LatLng destination) {
    final points = [origin, destination, ..._polylinePoints];
    try {
      _mapController.fitCamera(
        CameraFit.bounds(
          bounds: LatLngBounds.fromPoints(points),
          padding: const EdgeInsets.fromLTRB(60, 160, 60, 260),
          maxZoom: 16,
        ),
      );
    } catch (_) {
      // Map not attached yet -- harmless.
    }
  }

  // ------------------------------------------------------------------- map

  void _moveCamera(ll.LatLng point, double zoom) {
    try {
      _mapController.move(point, zoom);
    } catch (_) {
      // Map not attached yet -- the initial centre already covers this.
    }
  }

  void _onMapEvent(MapEvent event) {
    final center = event.camera.center;
    // Only a user gesture should break follow-me; our own programmatic
    // moves must not.
    final byUser = event.source == MapEventSource.onDrag ||
        event.source == MapEventSource.onMultiFinger ||
        event.source == MapEventSource.dragStart ||
        event.source == MapEventSource.multiFingerEnd;

    final loadedAround = _loadedAround;
    final drifted = loadedAround != null &&
        LocationService.instance.distanceKm(center, loadedAround) > _researchThresholdKm;

    if (byUser && _followMe) {
      setState(() => _followMe = false);
    }
    if (center != _cameraCenter || drifted != _canSearchThisArea) {
      setState(() {
        _cameraCenter = center;
        _canSearchThisArea = !_isAgent && drifted;
      });
    }
  }

  void _recenterOnMe() {
    final me = _myLocation;
    if (me == null) return;
    setState(() => _followMe = true);
    _moveCamera(me, 16);
  }

  void _onShopTapped(Shop shop) {
    setState(() {
      _followMe = false;
      _destination = ll.LatLng(shop.latitude, shop.longitude);
      _destinationLabel = shop.name;
    });
    _fetchRoute();
  }

  void _onModeSelected(String mode) {
    if (_mode == mode) return;
    setState(() => _mode = mode);
    if (_destination != null) _fetchRoute();
  }

  Future<void> _pickDeliveryLocation() async {
    final picked = await Navigator.push<PickedLocation>(
      context,
      MaterialPageRoute(
        builder: (_) => LocationPickerScreen(
          initialPoint: DeliveryLocationStore.instance.location?.latLng ?? _myLocation,
          title: 'Delivery location',
          confirmLabel: 'Save as my delivery location',
        ),
      ),
    );
    if (picked == null || !mounted) return;
    await DeliveryLocationStore.instance.save(picked);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Delivery location set to ${picked.address}')),
    );
  }

  // ----------------------------------------------------------------- build

  @override
  Widget build(BuildContext context) {
    if (_booting) {
      return Scaffold(
        appBar: BrandedAppBar(title: const Text('Live Map')),
        body: const Center(child: CircularProgressIndicator()),
      );
    }
    return Scaffold(body: _buildMapStack(context));
  }

  Widget _buildMapStack(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final me = _myLocation;
    final locationNotice = LocationService.describeFailure(_locationFailure);

    return Stack(
      children: [
        FlutterMap(
          mapController: _mapController,
          options: MapOptions(
            initialCenter: _destination ?? me ?? kFallbackCenter,
            initialZoom: 14,
            minZoom: 5,
            maxZoom: 18,
            onMapEvent: _onMapEvent,
          ),
          children: [
            const MapTileLayer(),
            if (_polylinePoints.isNotEmpty)
              PolylineLayer(
                polylines: [
                  // Drawn twice: a thick translucent casing under a solid
                  // line, so the route stays readable over dense map detail.
                  Polyline(
                    points: _polylinePoints,
                    strokeWidth: 9,
                    color: colorScheme.primary.withValues(alpha: 0.25),
                  ),
                  Polyline(
                    points: _polylinePoints,
                    strokeWidth: 4.5,
                    color: colorScheme.primary,
                  ),
                ],
              ),
            MarkerLayer(markers: _buildMarkers(context)),
          ],
        ),

        // --- top controls --------------------------------------------------
        Positioned(
          top: MediaQuery.of(context).padding.top + AppSpacing.sm,
          left: AppSpacing.md,
          right: AppSpacing.md,
          child: Column(
            children: [
              Row(
                children: [
                  _RoundMapButton(
                    icon: Icons.arrow_back,
                    tooltip: 'Back',
                    onPressed: () => Navigator.maybePop(context),
                  ),
                  const SizedBox(width: AppSpacing.sm),
                  Expanded(
                    child: _isAgent
                        ? const _AgentMapTitle()
                        : AreaSearchField(onAreaSelected: _onAreaSelected),
                  ),
                ],
              ),
              if (locationNotice != null)
                Padding(
                  padding: const EdgeInsets.only(top: AppSpacing.sm),
                  child: _InfoBanner(
                    icon: Icons.info_outline,
                    message: locationNotice,
                    onDismiss: () => setState(() => _locationFailure = null),
                  ),
                ),
              if (_routeError != null)
                Padding(
                  padding: const EdgeInsets.only(top: AppSpacing.sm),
                  child: _InfoBanner(
                    icon: Icons.error_outline,
                    message: _routeError!,
                    isError: true,
                    onDismiss: () => setState(() => _routeError = null),
                    onRetry: _destination != null ? _fetchRoute : null,
                  ),
                ),
            ],
          ),
        ),

        // The instruction the driver is heading into, above everything else
        // because it is the one thing that must be readable at a glance.
        if (_currentStep != null)
          Positioned(
            top: MediaQuery.of(context).padding.top + AppSpacing.xxxl + AppSpacing.lg,
            left: AppSpacing.md,
            right: AppSpacing.md,
            child: _TurnBanner(
              step: _currentStep!,
              muted: _muted,
              onRepeat: () => _voice.speak(_currentStep!.instruction),
            ),
          ),

        // "Search this area" after the customer pans somewhere new.
        if (_canSearchThisArea)
          Positioned(
            top: MediaQuery.of(context).padding.top + AppSpacing.xxxl + AppSpacing.lg,
            left: 0,
            right: 0,
            child: Center(
              child: _SearchThisAreaButton(
                loading: _shopsLoading,
                onPressed: () => _loadShopsAround(_cameraCenter, label: 'this area'),
              ),
            ),
          ),

        // --- side controls -------------------------------------------------
        Positioned(
          right: AppSpacing.md,
          bottom: AppSpacing.xxxl * 4,
          child: Column(
            children: [
              if (_routeLoading)
                const _MapSpinner()
              else
                _RoundMapButton(
                  icon: _followMe ? Icons.my_location : Icons.location_searching,
                  tooltip: _followMe ? 'Following your location' : 'Centre on me',
                  highlighted: _followMe,
                  onPressed: _recenterOnMe,
                ),
              const SizedBox(height: AppSpacing.md),
              _RoundMapButton(
                icon: Icons.layers_outlined,
                tooltip: 'Travel mode',
                onPressed: _showTravelModeSheet,
              ),
              // Only meaningful while there is something to announce.
              if (_steps.isNotEmpty) ...[
                const SizedBox(height: AppSpacing.md),
                _RoundMapButton(
                  icon: _muted ? Icons.volume_off_rounded : Icons.volume_up_rounded,
                  tooltip: _muted ? tr('nav.voice_off') : tr('nav.voice_on'),
                  highlighted: !_muted,
                  onPressed: _toggleMute,
                ),
              ],
              if (!_isAgent) ...[
                const SizedBox(height: AppSpacing.md),
                _RoundMapButton(
                  icon: Icons.where_to_vote_outlined,
                  tooltip: 'Set delivery location',
                  onPressed: _pickDeliveryLocation,
                ),
              ],
            ],
          ),
        ),

        // --- bottom sheet --------------------------------------------------
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          child: _destination != null
              ? _RouteSheet(
                  label: _destinationLabel ?? 'Selected destination',
                  mode: _mode,
                  distanceKm: _distanceKm,
                  durationMinutes: _durationMinutes,
                  speedKmh: _speedKmh,
                  loading: _routeLoading,
                  onModeSelected: _onModeSelected,
                  onStartNavigation: _startNavigation,
                  onClear: _clearRoute,
                )
              : _isAgent
                  ? _AgentJobsSheet(
                      orders: _agentOrders,
                      pickups: _pickups,
                      onRouteToPickup: (o) => _routeToOrder(o, toPickup: true),
                      onRouteToDropoff: (o) => _routeToOrder(o, toPickup: false),
                    )
                  : _NearbyShopsSheet(
                      shops: _shops,
                      areaLabel: _areaLabel,
                      loading: _shopsLoading,
                      onShopTapped: _onShopTapped,
                      onOpenShop: (shop) => Navigator.pushNamed(
                        context,
                        AppRoutes.shopDetail,
                        arguments: ShopDetailArgs(shop.id),
                      ),
                      onPickDeliveryLocation: _pickDeliveryLocation,
                    ),
        ),
      ],
    );
  }

  List<Marker> _buildMarkers(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final markers = <Marker>[];

    if (_isAgent) {
      for (final order in _agentOrders) {
        final pickup = _pickups[order.id];
        if (pickup != null) {
          markers.add(
            Marker(
              point: pickup.point,
              width: 38,
              height: 48,
              alignment: Alignment.topCenter,
              child: MapPin(
                icon: Icons.storefront_rounded,
                color: colorScheme.tertiary,
                tooltip: 'Pick up: ${pickup.name}',
                onTap: () => _routeToOrder(order, toPickup: true),
              ),
            ),
          );
        }
        markers.add(
          Marker(
            point: ll.LatLng(order.deliveryLat, order.deliveryLng),
            width: 38,
            height: 48,
            alignment: Alignment.topCenter,
            child: MapPin(
              icon: Icons.flag_rounded,
              color: colorScheme.error,
              tooltip: 'Drop off: ${order.deliveryAddress}',
              onTap: () => _routeToOrder(order, toPickup: false),
            ),
          ),
        );
      }
    } else {
      for (final shop in _shops) {
        final isSelected = _destination != null &&
            _destination!.latitude == shop.latitude &&
            _destination!.longitude == shop.longitude;
        markers.add(
          Marker(
            point: ll.LatLng(shop.latitude, shop.longitude),
            width: 40,
            height: 48,
            // Bottom-centre so the pin's tip sits on the real coordinate.
            alignment: Alignment.topCenter,
            child: MapPin.forCategory(
              context,
              shop.category,
              muted: !shop.isOpen,
              selected: isSelected,
              tooltip: '${shop.name}${shop.isOpen ? '' : ' (closed)'}',
              onTap: () => _onShopTapped(shop),
            ),
          ),
        );
      }
      final delivery = DeliveryLocationStore.instance.location;
      if (delivery != null) {
        markers.add(
          Marker(
            point: delivery.latLng,
            width: 38,
            height: 48,
            alignment: Alignment.topCenter,
            child: MapPin(
              icon: Icons.home_rounded,
              color: colorScheme.tertiary,
              tooltip: 'Delivery location: ${delivery.address}',
              onTap: _pickDeliveryLocation,
            ),
          ),
        );
      }
    }

    if (_destination != null) {
      markers.add(
        Marker(
          point: _destination!,
          width: 40,
          height: 48,
          alignment: Alignment.topCenter,
          child: MapPin(icon: Icons.place_rounded, color: colorScheme.error),
        ),
      );
    }

    final me = _myLocation;
    if (me != null) {
      markers.add(
        Marker(point: me, width: 28, height: 28, child: const MyLocationDot()),
      );
    }
    return markers;
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
}

// ===========================================================================
// Map furniture
// ===========================================================================




class _AgentMapTitle extends StatelessWidget {
  const _AgentMapTitle();

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Material(
      color: colorScheme.surface,
      borderRadius: BorderRadius.circular(AppRadius.pill),
      elevation: 3,
      shadowColor: Colors.black.withValues(alpha: 0.15),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.lg,
          vertical: AppSpacing.md,
        ),
        child: Row(
          children: [
            Icon(Icons.two_wheeler_outlined, size: 18, color: colorScheme.primary),
            const SizedBox(width: AppSpacing.sm),
            Text(
              'My deliveries',
              style: Theme.of(context)
                  .textTheme
                  .bodyMedium
                  ?.copyWith(fontWeight: FontWeight.w600),
            ),
          ],
        ),
      ),
    );
  }
}

class _SearchThisAreaButton extends StatelessWidget {
  final bool loading;
  final VoidCallback onPressed;

  const _SearchThisAreaButton({required this.loading, required this.onPressed});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Material(
      color: colorScheme.primary,
      borderRadius: BorderRadius.circular(AppRadius.pill),
      elevation: 4,
      child: InkWell(
        borderRadius: BorderRadius.circular(AppRadius.pill),
        onTap: loading ? null : onPressed,
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.lg,
            vertical: AppSpacing.sm,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (loading)
                SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: colorScheme.onPrimary,
                  ),
                )
              else
                Icon(Icons.refresh, size: 16, color: colorScheme.onPrimary),
              const SizedBox(width: AppSpacing.sm),
              Text(
                'Search this area',
                style: TextStyle(
                  color: colorScheme.onPrimary,
                  fontWeight: FontWeight.w600,
                  fontSize: 13,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MapSpinner extends StatelessWidget {
  const _MapSpinner();

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(AppSpacing.md),
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
    );
  }
}

class _RoundMapButton extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;
  final bool highlighted;

  const _RoundMapButton({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    this.highlighted = false,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Tooltip(
      message: tooltip,
      child: Material(
        color: highlighted ? colorScheme.primary : colorScheme.surface,
        shape: const CircleBorder(),
        elevation: 3,
        shadowColor: Colors.black.withValues(alpha: 0.15),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onPressed,
          child: Padding(
            padding: const EdgeInsets.all(AppSpacing.md),
            child: Icon(
              icon,
              color: highlighted ? colorScheme.onPrimary : colorScheme.onSurface,
              size: 20,
            ),
          ),
        ),
      ),
    );
  }
}

// ===========================================================================
// Bottom sheets
// ===========================================================================

class _SheetShell extends StatelessWidget {
  final Widget child;

  const _SheetShell({required this.child});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Material(
      color: colorScheme.surface,
      borderRadius: const BorderRadius.vertical(top: Radius.circular(AppRadius.card + 6)),
      elevation: 8,
      shadowColor: Colors.black.withValues(alpha: 0.15),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.lg,
            AppSpacing.sm,
            AppSpacing.lg,
            AppSpacing.lg,
          ),
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
              child,
            ],
          ),
        ),
      ),
    );
  }
}

/// Shops around whatever the customer is looking at, as a horizontal rail so
/// the map stays visible behind it.
class _NearbyShopsSheet extends StatelessWidget {
  final List<Shop> shops;
  final String? areaLabel;
  final bool loading;
  final void Function(Shop) onShopTapped;
  final void Function(Shop) onOpenShop;
  final VoidCallback onPickDeliveryLocation;

  const _NearbyShopsSheet({
    required this.shops,
    required this.areaLabel,
    required this.loading,
    required this.onShopTapped,
    required this.onOpenShop,
    required this.onPickDeliveryLocation,
  });

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final colors = context.appColors;

    final noun = shops.length == 1 ? 'shop' : 'shops';
    final title = areaLabel == null
        ? '${shops.length} $noun near you'
        : '${shops.length} $noun near ${areaLabel!}';

    return _SheetShell(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  loading ? 'Looking for shops…' : title,
                  style: textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
                ),
              ),
              TextButton.icon(
                onPressed: onPickDeliveryLocation,
                icon: const Icon(Icons.where_to_vote_outlined, size: 18),
                label: const Text('Delivery to'),
                style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm),
                  minimumSize: Size.zero,
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          // Legend for the pin colours actually on screen, so they decode to
          // something instead of being decoration.
          CategoryLegend(
            categories: {for (final s in shops) s.category}.toList()..sort(),
          ),
          const SizedBox(height: AppSpacing.sm),
          if (!loading && shops.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: AppSpacing.md),
              child: Text(
                'No shops registered around here yet. Try searching another town.',
                style: textTheme.bodyMedium?.copyWith(color: colors.textSecondary),
              ),
            )
          else
            SizedBox(
              height: 104,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: shops.length,
                separatorBuilder: (_, _) => const SizedBox(width: AppSpacing.md),
                itemBuilder: (context, index) => _ShopRailCard(
                  shop: shops[index],
                  onDirections: () => onShopTapped(shops[index]),
                  onOpen: () => onOpenShop(shops[index]),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _ShopRailCard extends StatelessWidget {
  final Shop shop;
  final VoidCallback onDirections;
  final VoidCallback onOpen;

  const _ShopRailCard({
    required this.shop,
    required this.onDirections,
    required this.onOpen,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final colors = context.appColors;
    final textTheme = Theme.of(context).textTheme;
    final tint = categoryColors(context, shop.category);

    return SizedBox(
      width: 230,
      child: Material(
        color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(AppRadius.input),
        child: InkWell(
          borderRadius: BorderRadius.circular(AppRadius.input),
          onTap: onOpen,
          child: Padding(
            padding: const EdgeInsets.all(AppSpacing.md),
            child: Row(
              children: [
                Container(
                  width: 38,
                  height: 38,
                  decoration: BoxDecoration(
                    color: tint.background,
                    borderRadius: BorderRadius.circular(AppRadius.input),
                  ),
                  alignment: Alignment.center,
                  child: Icon(categoryIcon(shop.category), size: 20, color: tint.foreground),
                ),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        shop.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w700),
                      ),
                      Text(
                        shop.isOpen ? 'Open now' : 'Closed',
                        style: textTheme.labelSmall?.copyWith(
                          color: shop.isOpen ? colors.success : colors.textSecondary,
                        ),
                      ),
                      if (shop.distanceKm != null)
                        Text(
                          '${shop.distanceKm!.toStringAsFixed(1)} km away',
                          style: textTheme.labelSmall?.copyWith(color: colors.textSecondary),
                        ),
                    ],
                  ),
                ),
                IconButton(
                  tooltip: 'Directions',
                  visualDensity: VisualDensity.compact,
                  onPressed: onDirections,
                  icon: Icon(Icons.directions, color: colorScheme.primary, size: 20),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The agent's active deliveries, each offering a route to its pickup or its
/// dropoff.
class _AgentJobsSheet extends StatelessWidget {
  final List<DeliveryOrder> orders;
  final Map<String, ({ll.LatLng point, String name})> pickups;
  final void Function(DeliveryOrder) onRouteToPickup;
  final void Function(DeliveryOrder) onRouteToDropoff;

  const _AgentJobsSheet({
    required this.orders,
    required this.pickups,
    required this.onRouteToPickup,
    required this.onRouteToDropoff,
  });

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final colors = context.appColors;

    return _SheetShell(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            orders.isEmpty
                ? 'No active deliveries'
                : '${orders.length} active ${orders.length == 1 ? 'delivery' : 'deliveries'}',
            style: textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: AppSpacing.xs),
          if (orders.isEmpty)
            Text(
              'Accept a job from Driver Home and it will appear on this map.',
              style: textTheme.bodyMedium?.copyWith(color: colors.textSecondary),
            )
          else
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 190),
              child: ListView.separated(
                shrinkWrap: true,
                itemCount: orders.length,
                separatorBuilder: (_, _) => const Divider(height: AppSpacing.lg),
                itemBuilder: (context, index) {
                  final order = orders[index];
                  final pickup = pickups[order.id];
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        order.deliveryAddress,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
                      ),
                      Text(
                        order.status.replaceAll('_', ' '),
                        style: textTheme.labelSmall?.copyWith(color: colors.textSecondary),
                      ),
                      const SizedBox(height: AppSpacing.xs),
                      // Expanded, not intrinsic width: inside a shrink-wrapped
                      // ListView the Row hands its children an unbounded main
                      // axis, which a Material button cannot lay out against.
                      Row(
                        children: [
                          if (pickup != null) ...[
                            Expanded(
                              child: OutlinedButton.icon(
                                onPressed: () => onRouteToPickup(order),
                                icon: const Icon(Icons.storefront, size: 16),
                                label: const Text('To pickup'),
                                style: OutlinedButton.styleFrom(
                                  visualDensity: VisualDensity.compact,
                                ),
                              ),
                            ),
                            const SizedBox(width: AppSpacing.sm),
                          ],
                          Expanded(
                            child: FilledButton.icon(
                              onPressed: () => onRouteToDropoff(order),
                              icon: const Icon(Icons.flag, size: 16),
                              label: const Text('To dropoff'),
                              style: FilledButton.styleFrom(
                                visualDensity: VisualDensity.compact,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  );
                },
              ),
            ),
        ],
      ),
    );
  }
}

/// Distance, ETA and travel mode for the active route.
class _RouteSheet extends StatelessWidget {
  final String label;
  final String mode;
  final double? distanceKm;
  final double? durationMinutes;
  final double? speedKmh;
  final bool loading;
  final void Function(String mode) onModeSelected;
  final VoidCallback onStartNavigation;
  final VoidCallback onClear;

  const _RouteSheet({
    required this.label,
    required this.mode,
    required this.distanceKm,
    required this.durationMinutes,
    required this.speedKmh,
    required this.loading,
    required this.onModeSelected,
    required this.onStartNavigation,
    required this.onClear,
  });

  /// Clock time of arrival, which is easier to act on than "131 min".
  String _etaClock() {
    if (durationMinutes == null) return '--:--';
    final arrival = DateTime.now().add(Duration(minutes: durationMinutes!.round()));
    return '${arrival.hour.toString().padLeft(2, '0')}:'
        '${arrival.minute.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final colors = context.appColors;
    final textTheme = Theme.of(context).textTheme;

    return _SheetShell(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
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
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(height: AppSpacing.xs),
                    Text(
                      loading ? 'Finding the best route…' : 'Arriving ${_etaClock()}',
                      style: textTheme.bodySmall?.copyWith(color: colors.textSecondary),
                    ),
                  ],
                ),
              ),
              IconButton(
                tooltip: 'Clear route',
                onPressed: onClear,
                icon: const Icon(Icons.close),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.md),
          // REQ-NAV-5: remaining distance, ETA and current speed, read as one
          // strip so the driver takes it in with a single glance.
          Row(
            children: [
              Expanded(
                child: _TripStat(
                  icon: Icons.straighten_rounded,
                  label: 'Distance',
                  value: distanceKm == null ? '--' : '${distanceKm!.toStringAsFixed(1)} km',
                ),
              ),
              Expanded(
                child: _TripStat(
                  icon: Icons.schedule_rounded,
                  label: 'Time left',
                  value: durationMinutes == null ? '--' : '${durationMinutes!.round()} min',
                ),
              ),
              Expanded(
                child: _TripStat(
                  icon: Icons.speed_rounded,
                  label: 'Speed',
                  value: speedKmh == null ? '--' : '${speedKmh!.round()} km/h',
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.md),
          SizedBox(
            height: 36,
            child: ListView(
              scrollDirection: Axis.horizontal,
              children: [
                for (final option in _travelModes) ...[
                  ChoiceChip(
                    label: Text(option.label),
                    avatar: Icon(option.icon, size: 16),
                    selected: mode == option.value,
                    onSelected: (_) => onModeSelected(option.value),
                  ),
                  const SizedBox(width: AppSpacing.sm),
                ],
              ],
            ),
          ),
          const SizedBox(height: AppSpacing.md),
          // One action rather than a fastest/shortest pair: the two routes
          // differ by a minute or two on most local trips, so asking the
          // driver to choose cost more attention than it saved them.
          FilledButton.icon(
            onPressed: loading ? null : onStartNavigation,
            icon: const Icon(Icons.navigation_rounded, size: 18),
            label: const Text('Navigation'),
            style: FilledButton.styleFrom(
              minimumSize: const Size.fromHeight(48),
            ),
          ),
        ],
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

/// The instruction the driver is heading into: a large maneuver arrow, the
/// sentence, and how far away it is. Tapping it repeats the spoken version.
class _TurnBanner extends StatelessWidget {
  final RouteStep step;
  final bool muted;
  final VoidCallback onRepeat;

  const _TurnBanner({
    required this.step,
    required this.muted,
    required this.onRepeat,
  });

  /// Maps an OSRM maneuver/modifier pair onto an arrow the driver can read
  /// without parsing the sentence.
  IconData get _icon {
    switch (step.maneuver) {
      case 'depart':
        return Icons.trip_origin_rounded;
      case 'arrive':
        return Icons.flag_rounded;
      case 'roundabout':
      case 'rotary':
        return Icons.roundabout_right_rounded;
      case 'merge':
        return Icons.merge_rounded;
      case 'on ramp':
      case 'off ramp':
        return Icons.ramp_right_rounded;
    }
    return switch (step.modifier) {
      'left' => Icons.turn_left_rounded,
      'right' => Icons.turn_right_rounded,
      'sharp left' => Icons.turn_sharp_left_rounded,
      'sharp right' => Icons.turn_sharp_right_rounded,
      'slight left' => Icons.turn_slight_left_rounded,
      'slight right' => Icons.turn_slight_right_rounded,
      'uturn' => Icons.u_turn_left_rounded,
      _ => Icons.straight_rounded,
    };
  }

  String get _distanceLabel {
    if (step.distanceM >= 1000) return '${(step.distanceM / 1000).toStringAsFixed(1)} km';
    final step10 = step.distanceM < 100 ? 10 : 50;
    final rounded = (step.distanceM / step10).round() * step10;
    return '${rounded < step10 ? step10 : rounded} m';
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Material(
      color: colorScheme.primary,
      borderRadius: BorderRadius.circular(AppRadius.card),
      elevation: 6,
      shadowColor: Colors.black.withValues(alpha: 0.3),
      child: InkWell(
        borderRadius: BorderRadius.circular(AppRadius.card),
        onTap: onRepeat,
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.md,
            vertical: AppSpacing.md,
          ),
          child: Row(
            children: [
              Icon(_icon, color: colorScheme.onPrimary, size: 30),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      _distanceLabel,
                      style: Theme.of(context).textTheme.labelSmall?.copyWith(
                            color: colorScheme.onPrimary.withValues(alpha: 0.85),
                            fontWeight: FontWeight.w700,
                          ),
                    ),
                    Text(
                      step.instruction,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                            color: colorScheme.onPrimary,
                            fontWeight: FontWeight.w700,
                          ),
                    ),
                  ],
                ),
              ),
              Icon(
                muted ? Icons.volume_off_rounded : Icons.replay_rounded,
                color: colorScheme.onPrimary.withValues(alpha: 0.8),
                size: 18,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// One figure in the route sheet's distance / time / speed strip.
class _TripStat extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;

  const _TripStat({required this.icon, required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    final colors = context.appColors;
    final textTheme = Theme.of(context).textTheme;
    return Column(
      children: [
        Icon(icon, size: 16, color: colors.textSecondary),
        const SizedBox(height: 2),
        Text(
          value,
          style: textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w800),
        ),
        Text(label, style: textTheme.labelSmall?.copyWith(color: colors.textSecondary)),
      ],
    );
  }
}
