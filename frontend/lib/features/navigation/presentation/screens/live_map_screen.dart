import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';

/// Navigation & Route Optimization (SRS 5.5, REQ-NAV-1..5).
///
/// TODO before this is real:
///  1. Add a Google Maps or Mapbox API key (see README in backend/ and
///     the Flutter platform setup docs for google_maps_flutter / mapbox_gl).
///  2. Drop a GoogleMap/MapboxMap widget in place of the placeholder below.
///  3. Call navigation-service (AppConstants.navigationPath) to get the
///     route/ETA, and flutter_tts to speak turn-by-turn instructions in
///     the user's chosen language (English / Sinhala / Tamil).
///
/// What IS wired up already: asking the OS for GPS permission and reading
/// the current position, which every navigation feature needs as a base.
class LiveMapScreen extends StatefulWidget {
  const LiveMapScreen({super.key});

  @override
  State<LiveMapScreen> createState() => _LiveMapScreenState();
}

class _LiveMapScreenState extends State<LiveMapScreen> {
  Position? _position;
  String _status = 'Checking location permission...';

  @override
  void initState() {
    super.initState();
    _getCurrentLocation();
  }

  Future<void> _getCurrentLocation() async {
    if (!await Geolocator.isLocationServiceEnabled()) {
      setState(() => _status = 'Location services are off. Please enable GPS.');
      return;
    }

    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    if (permission == LocationPermission.denied || permission == LocationPermission.deniedForever) {
      setState(() => _status = 'Location permission denied.');
      return;
    }

    final position = await Geolocator.getCurrentPosition();
    setState(() {
      _position = position;
      _status = 'Location found.';
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Navigate')),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.map, size: 64, color: Colors.grey),
              const SizedBox(height: 16),
              Text(_status, textAlign: TextAlign.center),
              if (_position != null) ...[
                const SizedBox(height: 8),
                Text('Lat: ${_position!.latitude.toStringAsFixed(5)}, '
                    'Lng: ${_position!.longitude.toStringAsFixed(5)}'),
              ],
              const SizedBox(height: 16),
              const Text(
                'Map view, route drawing, and voice guidance are not wired up yet.\n'
                'This screen already has GPS permission handling ready to build on.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.grey),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
