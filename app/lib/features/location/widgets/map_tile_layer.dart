import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';

/// The base maps the app can draw under its own pins and routes.
///
/// Three, for the same reasons a driver would want them: the street map for
/// addresses and shop names, imagery for recognising a place by what it
/// actually looks like from the road, and terrain for the hill country,
/// where a two-kilometre route can be an hour's climb.
enum MapBaseLayer {
  standard,
  satellite,
  terrain;

  String get label => switch (this) {
        MapBaseLayer.standard => 'Map',
        MapBaseLayer.satellite => 'Satellite',
        MapBaseLayer.terrain => 'Terrain',
      };

  IconData get icon => switch (this) {
        MapBaseLayer.standard => Icons.map_outlined,
        MapBaseLayer.satellite => Icons.satellite_alt_outlined,
        MapBaseLayer.terrain => Icons.terrain_outlined,
      };

  /// Who the tiles belong to. Every provider here requires this to be shown,
  /// so it is part of the layer rather than something a screen can forget.
  String get attribution => switch (this) {
        MapBaseLayer.standard => '© OpenStreetMap contributors',
        MapBaseLayer.satellite => 'Imagery © Esri, Maxar, Earthstar Geographics',
        MapBaseLayer.terrain => '© OpenTopoMap, © OpenStreetMap contributors',
      };

  /// Whether labels and controls drawn over this layer need light ink.
  bool get isDark => this == MapBaseLayer.satellite;

  /// The furthest in the map may go on this layer before the tiles would be
  /// upscaled. Past it the view only gets blurrier, never more detailed.
  double get maxZoom => switch (this) {
        MapBaseLayer.standard => 19,
        MapBaseLayer.satellite => 19,
        MapBaseLayer.terrain => 17,
      };
}

/// The tiles for a [MapBaseLayer], in one place so every map in the app uses
/// the same sources and the same user-agent.
///
/// Two things keep these sharp, both learned from a map that went soft as
/// soon as it was zoomed:
///
/// * Retina mode, but only on genuinely high-density screens. A device
///   pixel ratio above 1 means every 256px tile is stretched before it
///   reaches the screen. None of the keyless providers serve `@2x` tiles
///   -- CARTO and Stadia both answer with "API key required" -- so
///   flutter_map simulates it by fetching tiles one zoom level deeper and
///   drawing each at half size. That is real double density, but it is
///   also four times the tile requests, which on OpenStreetMap's free
///   servers means a map that fills in slowly and a usage policy being
///   leant on. At the 1.25 ratio of a Windows laptop at 125% scaling the
///   upscale is barely visible and not worth that; at 2.0 and above, on a
///   phone, it plainly is. Hence the threshold below rather than
///   flutter_map's own `isHighDensity`, which triggers at anything over 1.
/// * Each layer declares [MapBaseLayer.maxZoom], the last level it actually
///   has tiles for, so the map stops where it would otherwise let someone
///   zoom into an upscaled mush.
///
/// The street tiles are deliberately NOT re-tinted in dark mode. An earlier
/// version inverted them, which turned the map almost black and made streets
/// and labels hard to read -- a map is a reference image, and legibility
/// beats matching the surrounding chrome. The app's own overlays carry the
/// theme instead.
class MapTileLayer extends StatelessWidget {
  const MapTileLayer({super.key, this.layer = MapBaseLayer.standard});

  final MapBaseLayer layer;

  static const String _userAgent = 'com.microlink.app';

  /// Device pixel ratio at which simulated retina tiles start to be worth
  /// their fourfold cost in requests. See the note on the class.
  static const double _retinaThreshold = 2.0;

  static const String _streets = 'https://tile.openstreetmap.org/{z}/{x}/{y}.png';

  static const String _imagery =
      'https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}';

  /// Roads and place names as a transparent overlay. This is what turns raw
  /// imagery into the hybrid view people expect from a satellite map -- the
  /// photo on its own is pretty but useless for finding a shop.
  static const String _imageryLabels =
      'https://server.arcgisonline.com/ArcGIS/rest/services/Reference/World_Boundaries_and_Places/MapServer/tile/{z}/{y}/{x}';

  static const String _terrain = 'https://tile.opentopomap.org/{z}/{x}/{y}.png';

  @override
  Widget build(BuildContext context) {
    final retina = MediaQuery.devicePixelRatioOf(context) >= _retinaThreshold;

    return switch (layer) {
      MapBaseLayer.standard => TileLayer(
          urlTemplate: _streets,
          userAgentPackageName: _userAgent,
          retinaMode: retina,
          maxNativeZoom: 19,
          // Holding more tiles around the viewport means a pan or a zoom
          // shows real tiles instead of a grey gap that fills in late.
          keepBuffer: 4,
          panBuffer: 2,
        ),
      MapBaseLayer.terrain => TileLayer(
          urlTemplate: _terrain,
          userAgentPackageName: _userAgent,
          retinaMode: retina,
          // OpenTopoMap renders no further than this and serves blank tiles
          // past it, so the map is capped at 17 to match.
          maxNativeZoom: 17,
          keepBuffer: 4,
          panBuffer: 2,
        ),
      MapBaseLayer.satellite => _SatelliteTiles(retina: retina),
    };
  }
}

/// Imagery with the labels layer stacked on top.
///
/// flutter_map takes a flat list of children, so this returns a [Stack] of
/// two tile layers rather than a single widget -- both have to be positioned
/// by the map, which is why it is written as a full-bleed stack instead.
class _SatelliteTiles extends StatelessWidget {
  const _SatelliteTiles({required this.retina});

  final bool retina;

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        TileLayer(
          urlTemplate: MapTileLayer._imagery,
          userAgentPackageName: MapTileLayer._userAgent,
          retinaMode: retina,
          maxNativeZoom: 19,
          keepBuffer: 4,
          panBuffer: 2,
        ),
        TileLayer(
          urlTemplate: MapTileLayer._imageryLabels,
          userAgentPackageName: MapTileLayer._userAgent,
          retinaMode: retina,
          maxNativeZoom: 19,
          keepBuffer: 4,
          panBuffer: 2,
        ),
      ],
    );
  }
}
