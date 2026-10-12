import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';

/// The OpenStreetMap tile layer, in one place so every map in the app uses
/// the same tiles and the same user-agent.
///
/// The tiles are deliberately NOT re-tinted in dark mode. An earlier version
/// inverted them to match the dark theme, which turned the map almost black
/// and made streets and labels hard to read -- a map is a reference image,
/// and legibility beats matching the surrounding chrome. The app's own
/// overlays (pins, routes, sheets) carry the theme instead.
class MapTileLayer extends StatelessWidget {
  const MapTileLayer({super.key});

  static const String _urlTemplate = 'https://tile.openstreetmap.org/{z}/{x}/{y}.png';
  static const String _userAgent = 'com.microlink.app';

  @override
  Widget build(BuildContext context) {
    return TileLayer(urlTemplate: _urlTemplate, userAgentPackageName: _userAgent);
  }
}
