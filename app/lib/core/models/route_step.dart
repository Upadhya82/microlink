import 'package:latlong2/latlong.dart';

/// Mirrors navigation-service's `RouteStep`: one spoken turn-by-turn
/// instruction, where it happens, and how far the leg before it runs.
class RouteStep {
  final String instruction;
  final double distanceM;
  final LatLng location;
  final String maneuver;
  final String? modifier;

  const RouteStep({
    required this.instruction,
    required this.distanceM,
    required this.location,
    required this.maneuver,
    this.modifier,
  });

  factory RouteStep.fromJson(Map<String, dynamic> json) {
    final location = json['location'] as Map?;
    return RouteStep(
      instruction: json['instruction'] as String? ?? '',
      distanceM: (json['distance_m'] as num?)?.toDouble() ?? 0,
      location: LatLng(
        (location?['lat'] as num?)?.toDouble() ?? 0,
        (location?['lng'] as num?)?.toDouble() ?? 0,
      ),
      maneuver: json['maneuver'] as String? ?? '',
      modifier: json['modifier'] as String?,
    );
  }
}
