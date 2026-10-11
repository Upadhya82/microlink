import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../../../core/location/location_service.dart';
import '../../../core/models/picked_location.dart';
import '../../../core/network/api_client.dart';
import '../../../core/theme/app_colors_extension.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/widgets/app_button.dart';
import '../widgets/area_search_field.dart';
import '../widgets/map_tile_layer.dart';

/// Full-screen map for choosing a point anywhere in Sri Lanka.
///
/// Used for the delivery location at checkout, and reusable anywhere else a
/// point is needed. The pin is fixed to the centre of the screen and the map
/// moves under it -- easier on a phone than dragging a small marker, and it
/// keeps the chosen point under the user's thumb rather than their finger.
///
/// Pops a [PickedLocation], or null if the user backs out.
class LocationPickerScreen extends StatefulWidget {
  /// Where to open. Falls back to the device's position, then Colombo.
  final LatLng? initialPoint;
  final String title;

  /// Wording for the confirm button, e.g. "Use this delivery location".
  final String confirmLabel;

  const LocationPickerScreen({
    super.key,
    this.initialPoint,
    this.title = 'Choose a location',
    this.confirmLabel = 'Use this location',
  });

  @override
  State<LocationPickerScreen> createState() => _LocationPickerScreenState();
}

class _LocationPickerScreenState extends State<LocationPickerScreen> {
  final MapController _mapController = MapController();

  LatLng? _center;
  bool _booting = true;

  /// The address for [_center]. Null while it is being looked up.
  PickedLocation? _resolved;
  bool _resolving = false;

  /// Debounces the reverse-geocode call: panning fires a stream of camera
  /// events and Nominatim's usage policy (and our own latency) rules out one
  /// request per frame.
  Timer? _resolveDebounce;

  /// Guards against an earlier, slower lookup overwriting a newer one.
  int _resolveToken = 0;

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  @override
  void dispose() {
    _resolveDebounce?.cancel();
    _mapController.dispose();
    super.dispose();
  }

  Future<void> _bootstrap() async {
    var start = widget.initialPoint;
    if (start == null) {
      final result = await LocationService.instance.currentPosition();
      start = result.position;
    }
    if (!mounted) return;
    setState(() {
      _center = start;
      _booting = false;
    });
    _resolveAddress(start, immediate: true);
  }

  void _onMapMoved(MapCamera camera, bool hasGesture) {
    if (!hasGesture) return;
    setState(() {
      _center = camera.center;
      // The old address no longer describes where the pin is.
      _resolved = null;
    });
    _resolveAddress(camera.center);
  }

  void _resolveAddress(LatLng point, {bool immediate = false}) {
    _resolveDebounce?.cancel();
    final token = ++_resolveToken;

    Future<void> run() async {
      if (!mounted) return;
      setState(() => _resolving = true);
      PickedLocation? place;
      try {
        final response = await ApiClient.instance.get(
          '/shops/reverse-geocode',
          query: {'lat': point.latitude, 'lng': point.longitude},
        );
        if (response is Map) {
          place = PickedLocation.fromJson(Map<String, dynamic>.from(response));
        }
      } catch (_) {
        // Unresolvable point or geocoder down -- coordinates still work.
      }
      // A newer pan already started: let that one win.
      if (!mounted || token != _resolveToken) return;
      setState(() {
        _resolved = place ?? PickedLocation.fromCoordinates(point);
        _resolving = false;
      });
    }

    if (immediate) {
      unawaited(run());
    } else {
      _resolveDebounce = Timer(const Duration(milliseconds: 600), run);
    }
  }

  void _moveTo(LatLng point, {double zoom = 16}) {
    setState(() {
      _center = point;
      _resolved = null;
    });
    try {
      _mapController.move(point, zoom);
    } catch (_) {
      // Map not attached yet -- the initial centre already covers this.
    }
    _resolveAddress(point, immediate: true);
  }

  Future<void> _useMyLocation() async {
    final result = await LocationService.instance.currentPosition();
    if (!mounted) return;
    if (!result.isReal) {
      final message = LocationService.describeFailure(result.failure);
      if (message != null) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
      }
      return;
    }
    _moveTo(result.position, zoom: 17);
  }

  void _confirm() {
    final chosen = _resolved ??
        (_center == null ? null : PickedLocation.fromCoordinates(_center!));
    if (chosen == null) return;
    Navigator.pop(context, chosen);
  }

  @override
  Widget build(BuildContext context) {
    if (_booting || _center == null) {
      return Scaffold(
        appBar: AppBar(title: Text(widget.title)),
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    return Scaffold(
      appBar: AppBar(title: Text(widget.title)),
      body: Stack(
        children: [
          FlutterMap(
            mapController: _mapController,
            options: MapOptions(
              initialCenter: _center!,
              initialZoom: 16,
              minZoom: 5,
              maxZoom: 18,
              onPositionChanged: _onMapMoved,
              // Dragging the map under the fixed pin works, but tapping the
              // spot you mean is what people reach for first -- keep the
              // current zoom so a tap nudges the pin instead of lurching in.
              onTap: (_, point) => _moveTo(point, zoom: _mapController.camera.zoom),
            ),
            children: const [MapTileLayer()],
          ),

          // Fixed centre pin. IgnorePointer so it never eats a map gesture;
          // the offset lifts the tip of the pin onto the exact centre pixel.
          IgnorePointer(
            child: Center(
              child: Transform.translate(
                offset: const Offset(0, -18),
                child: _CenterPin(isResolving: _resolving),
              ),
            ),
          ),

          Positioned(
            top: AppSpacing.md,
            left: AppSpacing.md,
            right: AppSpacing.md,
            child: AreaSearchField(
              hintText: 'Search a town or landmark',
              onAreaSelected: (area) => _moveTo(LatLng(area.latitude, area.longitude), zoom: 15),
            ),
          ),

          Positioned(
            right: AppSpacing.md,
            bottom: AppSpacing.xxxl * 3,
            child: _RoundMapButton(
              icon: Icons.my_location,
              tooltip: 'Use my current location',
              onPressed: _useMyLocation,
            ),
          ),

          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: _ConfirmSheet(
              resolving: _resolving,
              location: _resolved,
              confirmLabel: widget.confirmLabel,
              onConfirm: _confirm,
            ),
          ),
        ],
      ),
    );
  }
}

/// The pin fixed at the centre of the picker. Pulses while the address for
/// the point underneath it is being looked up.
class _CenterPin extends StatelessWidget {
  final bool isResolving;

  const _CenterPin({required this.isResolving});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        AnimatedOpacity(
          opacity: isResolving ? 0.6 : 1,
          duration: const Duration(milliseconds: 200),
          child: Icon(
            Icons.location_pin,
            size: 44,
            color: colorScheme.error,
            shadows: const [Shadow(blurRadius: 6, color: Colors.black38)],
          ),
        ),
        // Small dot marking the exact point, since the pin graphic is tall.
        Container(
          width: 7,
          height: 7,
          decoration: BoxDecoration(
            color: colorScheme.error,
            shape: BoxShape.circle,
            border: Border.all(color: colorScheme.surface, width: 1.5),
          ),
        ),
      ],
    );
  }
}

class _ConfirmSheet extends StatelessWidget {
  final bool resolving;
  final PickedLocation? location;
  final String confirmLabel;
  final VoidCallback onConfirm;

  const _ConfirmSheet({
    required this.resolving,
    required this.location,
    required this.confirmLabel,
    required this.onConfirm,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final colors = context.appColors;
    final textTheme = Theme.of(context).textTheme;

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
            AppSpacing.lg,
            AppSpacing.lg,
            AppSpacing.lg,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.place_outlined, size: 20, color: colorScheme.primary),
                  const SizedBox(width: AppSpacing.sm),
                  Expanded(
                    child: resolving
                        ? Text(
                            'Finding this place…',
                            style: textTheme.bodyMedium?.copyWith(color: colors.textSecondary),
                          )
                        : Text(
                            location?.address ?? 'Move the map to choose a point',
                            style: textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
                          ),
                  ),
                ],
              ),
              const SizedBox(height: AppSpacing.md),
              AppButton(
                label: confirmLabel,
                onPressed: resolving || location == null ? null : onConfirm,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _RoundMapButton extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;

  const _RoundMapButton({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Tooltip(
      message: tooltip,
      child: Material(
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
      ),
    );
  }
}
