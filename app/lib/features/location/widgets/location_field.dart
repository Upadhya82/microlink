import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../../../core/location/location_service.dart';
import '../../../core/models/picked_location.dart';
import '../../../core/theme/app_colors_extension.dart';
import '../../../core/theme/app_spacing.dart';
import '../screens/location_picker_screen.dart';
import 'map_pin.dart';
import 'map_tile_layer.dart';

/// A form field for choosing a point, with both ways of doing it.
///
/// "Use my location" only works when the user is standing at the place they
/// are describing -- which is wrong for reporting a road you have just
/// driven past, or registering a shop you are not currently inside. Every
/// place-picking form therefore offers the map picker as well, and this
/// widget is that pair so no screen has to re-implement it.
class LocationField extends StatelessWidget {
  final double? latitude;
  final double? longitude;

  /// Reverse-geocoded address, when the caller has one.
  final String? address;

  final bool isLocating;

  /// Title for the full-screen picker.
  final String pickerTitle;
  final String confirmLabel;

  final ValueChanged<PickedLocation> onPicked;
  final VoidCallback onUseMyLocation;

  const LocationField({
    super.key,
    required this.latitude,
    required this.longitude,
    required this.onPicked,
    required this.onUseMyLocation,
    this.address,
    this.isLocating = false,
    this.pickerTitle = 'Choose a location',
    this.confirmLabel = 'Use this location',
  });

  bool get _hasLocation => latitude != null && longitude != null;

  Future<void> _openPicker(BuildContext context) async {
    final picked = await Navigator.push<PickedLocation>(
      context,
      MaterialPageRoute(
        builder: (_) => LocationPickerScreen(
          initialPoint: _hasLocation ? LatLng(latitude!, longitude!) : null,
          title: pickerTitle,
          confirmLabel: confirmLabel,
        ),
      ),
    );
    if (picked != null) onPicked(picked);
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final colors = context.appColors;
    final point = _hasLocation ? LatLng(latitude!, longitude!) : null;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(AppRadius.card),
          child: SizedBox(
            height: 160,
            child: Stack(
              children: [
                Positioned.fill(
                  // Frozen preview: tapping opens the real picker rather
                  // than letting the user fight a tiny map inside a form.
                  child: IgnorePointer(
                    child: FlutterMap(
                      options: MapOptions(
                        initialCenter: point ?? kFallbackCenter,
                        initialZoom: point == null ? 8 : 16,
                        interactionOptions:
                            const InteractionOptions(flags: InteractiveFlag.none),
                      ),
                      children: [
                        const MapTileLayer(),
                        if (point != null)
                          MarkerLayer(
                            markers: [
                              Marker(
                                point: point,
                                width: 34,
                                height: 44,
                                alignment: Alignment.topCenter,
                                child: MapPin(
                                  icon: Icons.place_rounded,
                                  color: colorScheme.error,
                                ),
                              ),
                            ],
                          ),
                      ],
                    ),
                  ),
                ),
                if (!_hasLocation)
                  Positioned.fill(
                    child: ColoredBox(
                      color: colorScheme.surface.withValues(alpha: 0.72),
                      child: Center(
                        child: Text(
                          'No location set yet',
                          style: Theme.of(context)
                              .textTheme
                              .bodyMedium
                              ?.copyWith(color: colors.textSecondary),
                        ),
                      ),
                    ),
                  ),
                if (isLocating)
                  const Positioned.fill(
                    child: Center(child: CircularProgressIndicator()),
                  ),
              ],
            ),
          ),
        ),
        const SizedBox(height: AppSpacing.sm),
        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: isLocating ? null : onUseMyLocation,
                icon: const Icon(Icons.my_location, size: 18),
                label: const Text('Use my location'),
              ),
            ),
            const SizedBox(width: AppSpacing.sm),
            Expanded(
              child: FilledButton.tonalIcon(
                onPressed: () => _openPicker(context),
                icon: const Icon(Icons.map_outlined, size: 18),
                label: Text(_hasLocation ? 'Change on map' : 'Pick on map'),
              ),
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.xs),
        Text(
          address?.isNotEmpty == true
              ? address!
              : _hasLocation
                  ? 'Lat: ${latitude!.toStringAsFixed(5)}, '
                      'Lng: ${longitude!.toStringAsFixed(5)}'
                  : 'Pick a point on the map, or use your current location.',
          style: Theme.of(context)
              .textTheme
              .bodySmall
              ?.copyWith(color: colors.textSecondary),
        ),
      ],
    );
  }
}
