import 'package:latlong2/latlong.dart';

/// A place the user chose: either by dropping a pin on the map, searching for
/// an area, or tapping "use my location".
///
/// [address] is what the backend's reverse geocoder made of the point, and is
/// what a delivery agent actually reads, so it is never empty -- when the
/// geocoder cannot resolve a point the caller falls back to formatted
/// coordinates rather than leaving it blank.
class PickedLocation {
  final double latitude;
  final double longitude;
  final String address;

  /// A short label for the place ("Galle Road"), used in compact UI where the
  /// full address would wrap.
  final String name;

  const PickedLocation({
    required this.latitude,
    required this.longitude,
    required this.address,
    required this.name,
  });

  LatLng get latLng => LatLng(latitude, longitude);

  /// Used when the geocoder cannot name a point.
  factory PickedLocation.fromCoordinates(LatLng point) {
    final text =
        '${point.latitude.toStringAsFixed(5)}, ${point.longitude.toStringAsFixed(5)}';
    return PickedLocation(
      latitude: point.latitude,
      longitude: point.longitude,
      address: text,
      name: 'Dropped pin',
    );
  }

  /// Mirrors shop-service's `ReverseGeocodeResponse`.
  factory PickedLocation.fromJson(Map<String, dynamic> json) {
    return PickedLocation(
      latitude: (json['latitude'] as num).toDouble(),
      longitude: (json['longitude'] as num).toDouble(),
      address: json['address'] as String? ?? '',
      name: json['name'] as String? ?? '',
    );
  }

  Map<String, dynamic> toJson() => {
        'latitude': latitude,
        'longitude': longitude,
        'address': address,
        'name': name,
      };
}
