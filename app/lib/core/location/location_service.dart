import 'dart:async';

import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';

/// Colombo. Used whenever the device's real position cannot be resolved, so
/// a map always opens somewhere sensible in Sri Lanka rather than at (0, 0).
const LatLng kFallbackCenter = LatLng(6.9271, 79.8612);

/// Why a location request did not return the device's real position.
enum LocationFailure {
  /// The user said no. Asking again is pointless until they change it in
  /// system settings.
  permissionDenied,

  /// Location services are switched off device-wide.
  serviceDisabled,

  /// Timed out, no fix, platform error.
  unavailable,
}

/// The result of asking for the device's position: either a real fix, or the
/// fallback centre plus the reason the real one is missing.
class LocationResult {
  final LatLng position;
  final LocationFailure? failure;

  const LocationResult(this.position, {this.failure});

  bool get isReal => failure == null;
}

/// One place for GPS permission and position handling.
///
/// Before this, the same ~20-line Geolocator block (check permission,
/// request it, check the service, catch, fall back to Colombo) was pasted
/// into every screen that needed a position, each with slightly different
/// error handling. Screens now ask this service instead.
class LocationService {
  LocationService._();
  static final LocationService instance = LocationService._();

  /// Permission state after asking, or null when permission is granted.
  Future<LocationFailure?> _ensurePermission() async {
    try {
      if (!await Geolocator.isLocationServiceEnabled()) {
        return LocationFailure.serviceDisabled;
      }
      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        return LocationFailure.permissionDenied;
      }
      return null;
    } catch (_) {
      return LocationFailure.unavailable;
    }
  }

  /// A single position fix. Never throws: on any failure the fallback centre
  /// comes back with the reason attached, so callers can show the map first
  /// and explain the limitation second.
  Future<LocationResult> currentPosition({
    LocationAccuracy accuracy = LocationAccuracy.medium,
    Duration timeout = const Duration(seconds: 12),
  }) async {
    final failure = await _ensurePermission();
    if (failure != null) return LocationResult(kFallbackCenter, failure: failure);

    try {
      final position = await Geolocator.getCurrentPosition(
        locationSettings: LocationSettings(accuracy: accuracy, timeLimit: timeout),
      );
      return LocationResult(LatLng(position.latitude, position.longitude));
    } catch (_) {
      return const LocationResult(kFallbackCenter, failure: LocationFailure.unavailable);
    }
  }

  /// A live stream of positions for follow-me map tracking.
  ///
  /// Emits nothing (rather than throwing) when permission is refused, so a
  /// caller can always listen and simply never receive updates. Filtered by
  /// [distanceFilterMeters] so a stationary phone doesn't repaint the map or
  /// drain the battery.
  Stream<LatLng> positionStream({int distanceFilterMeters = 10}) async* {
    final failure = await _ensurePermission();
    if (failure != null) return;

    yield* Geolocator.getPositionStream(
      locationSettings: LocationSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: distanceFilterMeters,
      ),
    ).map((p) => LatLng(p.latitude, p.longitude)).handleError((_) {});
  }

  /// Straight-line distance in kilometres.
  double distanceKm(LatLng a, LatLng b) {
    return Geolocator.distanceBetween(
          a.latitude,
          a.longitude,
          b.latitude,
          b.longitude,
        ) /
        1000;
  }

  /// A short, user-facing explanation for a failure, or null when the
  /// position is real.
  static String? describeFailure(LocationFailure? failure) {
    return switch (failure) {
      LocationFailure.permissionDenied =>
        'Location permission is off, so we are showing Colombo. Turn it on in '
            'settings to see what is around you.',
      LocationFailure.serviceDisabled =>
        'Location services are switched off, so we are showing Colombo.',
      LocationFailure.unavailable =>
        "Couldn't get your exact location -- showing Colombo as a default.",
      null => null,
    };
  }
}
