import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart' as ll;

import '../../../core/l10n/app_strings.dart';
import '../../../core/utils/media_url.dart';
import '../../location/widgets/map_tile_layer.dart';
import '../../../core/constants/app_constants.dart';
import '../../../core/models/external_place.dart';
import '../../../core/models/shop.dart';
import '../../../core/network/api_client.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/theme/app_colors_extension.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/utils/app_router.dart';
import '../../../core/utils/category_style.dart';
import '../../../core/utils/view_state.dart';
import '../../../core/widgets/app_card.dart';
import '../../../core/widgets/app_text_field.dart';
import '../../../core/widgets/async_state_view.dart';
import '../../../core/widgets/rating_chip.dart';
import '../../../core/widgets/skeleton_list.dart';
import '../shop_discovery_support.dart';
import '../../../core/widgets/branded_app_bar.dart';

/// Smart Shop Discovery (SRS 5.3, REQ-SEARCH-1 to REQ-SEARCH-5).
///
/// * REQ-SEARCH-1  search box: shop names, categories and product names
/// * REQ-SEARCH-2  filters: category, open now, minimum trust score, delivery
/// * REQ-SEARCH-3  "Search near a landmark" (default radius 2 km)
/// * REQ-SEARCH-4  each card shows status, trust score and product availability
/// * REQ-SEARCH-5  works offline from a 7-day cache, with an offline banner
/// Results can be shown as a list or on a map.
class ShopListScreen extends StatefulWidget {
  final String? initialCategory;

  const ShopListScreen({super.key, this.initialCategory});

  @override
  State<ShopListScreen> createState() => _ShopListScreenState();
}

class _ShopListScreenState extends State<ShopListScreen> {
  static const double _defaultLandmarkRadiusKm = 2;
  static final ll.LatLng _fallbackCenter = ll.LatLng(6.9271, 79.8612); // Colombo

  final _searchController = TextEditingController();
  Timer? _debounce;

  ViewState<List<ShopEntry>> _state = const ViewLoading();

  // filters
  String? _selectedCategory;
  bool _openNowOnly = false;
  bool _deliveryOnly = false;
  int _minTrust = 0; // 0 = any, otherwise 1 to 5
  double _radiusKm = 10;

  /// Whether to restrict results to [_radiusKm] of the search origin.
  ///
  /// Off means "anywhere in Sri Lanka": someone in Colombo ordering from a
  /// Kandy shop for a Kandy address is a normal case, and a distance filter
  /// anchored on where they happen to be standing hides exactly those shops.
  ///
  /// Off by default, because on it the screen looks broken rather than
  /// filtered: shops are spread across the country, so anyone further than
  /// [_radiusKm] from a town centre opened a category and saw nothing at all.
  /// Results are sorted nearest-first regardless, so the closest shops are
  /// still the ones at the top.
  bool _radiusEnabled = false;
  String _sort = 'smart'; // smart | rating | newest

  // device location (optional)
  double? _lat;
  double? _lng;

  // landmark search (optional)
  String? _landmarkQuery;
  String? _landmarkName;
  double? _landmarkLat;
  double? _landmarkLng;
  double _landmarkRadiusKm = _defaultLandmarkRadiusKm;

  // offline mode
  bool _offline = false;
  DateTime? _cacheSavedAt;

  // list / map
  bool _showMap = false;

  // Real places from OpenStreetMap, shown below our own shops when a
  // category is picked and a location is known.
  bool _loadingExternal = false;
  List<ExternalPlace> _externalPlaces = const [];

  @override
  void initState() {
    super.initState();
    _selectedCategory = widget.initialCategory;
    _bootstrap();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _bootstrap() async {
    await _resolveLocation();
    await _fetchShops();
  }

  Future<void> _resolveLocation() async {
    try {
      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        return;
      }
      final serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) return;

      final position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(accuracy: LocationAccuracy.medium),
      );
      _lat = position.latitude;
      _lng = position.longitude;
    } catch (_) {
      // Location is a nice-to-have for distance sorting - ignore failures.
    }
  }

  /// The point results are measured from: the landmark if one is set,
  /// otherwise the device location (which may be unknown).
  ({double? lat, double? lng}) get _searchOrigin {
    if (_landmarkQuery != null && _landmarkLat != null && _landmarkLng != null) {
      return (lat: _landmarkLat, lng: _landmarkLng);
    }
    return (lat: _lat, lng: _lng);
  }

  /// What to say when nothing matched.
  ///
  /// The generic line tells people to widen the radius, which is wrong advice
  /// when no radius is being applied and useless when they cannot tell that
  /// one is. Naming the actual limit is the difference between "this app is
  /// broken" and "ah, that filter is on".
  String get _emptyMessage {
    final origin = _searchOrigin;
    if (_radiusEnabled && origin.lat != null && origin.lng != null) {
      final km = _radiusKm == _radiusKm.roundToDouble()
          ? _radiusKm.round().toString()
          : _radiusKm.toStringAsFixed(1);
      return 'No shops within $km km of you. Open Filters and turn off the '
          'distance limit to search anywhere in Sri Lanka.';
    }
    return tr('shops.none_body');
  }

  Future<void> _fetchShops() async {
    setState(() => _state = const ViewLoading());

    final text = _searchController.text.trim();
    final filters = <String, dynamic>{
      'q': text.isEmpty ? null : text,
      'category': _selectedCategory,
      'is_open': _openNowOnly ? true : null,
      'min_rating': _minTrust > 0 ? _minTrust : null,
      'delivery_available': _deliveryOnly ? true : null,
      'sort': _sort == 'smart' ? null : _sort,
    };

    try {
      List<Map<String, dynamic>> rawShops;
      if (_landmarkQuery != null) {
        final response = await ApiClient.instance.get(
          '/shops/landmark',
          query: {...filters, 'landmark': _landmarkQuery, 'radius_km': _landmarkRadiusKm},
        );
        final body = response as Map<String, dynamic>;
        final place = body['landmark'] as Map<String, dynamic>;
        _landmarkName = place['name'] as String?;
        _landmarkLat = (place['latitude'] as num).toDouble();
        _landmarkLng = (place['longitude'] as num).toDouble();
        rawShops = (body['shops'] as List).map((e) => e as Map<String, dynamic>).toList();
      } else {
        final response = await ApiClient.instance.get(
          '/shops',
          query: {
            ...filters,
            'lat': _lat,
            'lng': _lng,
            if (_radiusEnabled && _lat != null && _lng != null)
              'radius_km': _radiusKm,
            // Without this the server's default of 50 quietly cuts the list
            // short, which looks exactly like shops being missing.
            'limit': 200,
          },
        );
        rawShops = (response as List).map((e) => e as Map<String, dynamic>).toList();
      }

      final entries = rawShops.map(ShopEntry.fromJson).toList();
      unawaited(ShopCache.saveShops(rawShops));
      if (!mounted) return;
      setState(() {
        _offline = false;
        _cacheSavedAt = null;
        _state = ViewData(entries);
      });
    } on ApiException catch (e) {
      if (e.isNetworkError) {
        await _loadFromCache();
      } else {
        if (!mounted) return;
        setState(() => _state = ViewError(e.message));
      }
    } catch (_) {
      if (!mounted) return;
      setState(() => _state = const ViewError('Something went wrong. Please try again.'));
    }
    unawaited(_fetchExternalPlaces());
  }

  // ----------------------------------------------------------- offline mode

  bool _matchesFilters(ShopEntry entry) {
    final text = _searchController.text.trim().toLowerCase();
    if (text.isNotEmpty) {
      final haystack =
          '${entry.shop.name} ${entry.shop.address} ${entry.shop.category}'.toLowerCase();
      if (!haystack.contains(text)) return false;
    }
    if (_selectedCategory != null && entry.shop.category != _selectedCategory) return false;
    if (_openNowOnly && entry.extras.status != 'open') return false;
    if (_minTrust > 0 && entry.extras.trustScore < _minTrust) return false;
    if (_deliveryOnly && !entry.extras.deliveryAvailable) return false;
    return true;
  }

  Future<void> _loadFromCache() async {
    final cached = await ShopCache.loadShops();
    if (!mounted) return;

    if (cached.entries.isEmpty) {
      setState(() {
        _offline = true;
        _cacheSavedAt = null;
        _state = const ViewError(
          'You are offline and no shops are saved on this phone yet. '
          'Connect to the internet once and your results will be saved for offline use.',
        );
      });
      return;
    }

    final origin = _searchOrigin;
    final radius = _landmarkQuery != null ? _landmarkRadiusKm : _radiusKm;
    // A landmark search is a radius search by definition, so the toggle only
    // governs the plain "shops near me" case.
    final limitByRadius = _landmarkQuery != null || _radiusEnabled;
    var entries = cached.entries.where(_matchesFilters).toList();

    if (origin.lat != null && origin.lng != null) {
      entries = entries
          .map((e) => e.withDistance(
                distanceBetweenKm(origin.lat!, origin.lng!, e.shop.latitude, e.shop.longitude),
              ))
          .where((e) => !limitByRadius || e.distanceKm! <= radius)
          .toList();
      entries.sort((a, b) {
        final byDistance = a.distanceKm!.compareTo(b.distanceKm!);
        return byDistance != 0 ? byDistance : b.extras.trustScore.compareTo(a.extras.trustScore);
      });
    } else {
      entries.sort((a, b) => b.extras.trustScore.compareTo(a.extras.trustScore));
    }

    setState(() {
      _offline = true;
      _cacheSavedAt = cached.newestSave;
      _showMap = false; // map tiles need internet
      _state = ViewData(entries);
    });
  }

  // ------------------------------------------------------- OpenStreetMap

  Future<void> _fetchExternalPlaces() async {
    if (!mounted) return;
    final origin = _searchOrigin;
    if (_offline || _selectedCategory == null || origin.lat == null || origin.lng == null) {
      setState(() => _externalPlaces = const []);
      return;
    }
    setState(() => _loadingExternal = true);
    try {
      final response = await ApiClient.instance.get(
        '/shops/external',
        query: {
          'category': _selectedCategory,
          'lat': origin.lat,
          'lng': origin.lng,
          'radius_km': _landmarkQuery != null ? _landmarkRadiusKm : _radiusKm,
        },
      );
      final places = (response as List)
          .map((e) => ExternalPlace.fromJson(e as Map<String, dynamic>))
          .toList();
      if (!mounted) return;
      setState(() {
        _externalPlaces = places;
        _loadingExternal = false;
      });
    } catch (_) {
      // Non-fatal: this is a bonus section, our own results above are unaffected.
      if (!mounted) return;
      setState(() {
        _externalPlaces = const [];
        _loadingExternal = false;
      });
    }
  }

  // --------------------------------------------------------------- actions

  void _onSearchChanged(String value) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 400), _fetchShops);
  }

  void _onCategorySelected(String? category) {
    setState(() => _selectedCategory = category);
    _fetchShops();
  }

  void _openShop(Shop shop) {
    Navigator.pushNamed(context, AppRoutes.shopDetail, arguments: ShopDetailArgs(shop.id));
  }

  Future<void> _askLandmark() async {
    final typed = await showDialog<String>(
      context: context,
      builder: (_) => const _LandmarkDialog(),
    );
    if (typed == null || typed.isEmpty) return;
    setState(() {
      _landmarkQuery = typed;
      _landmarkName = null;
      _landmarkLat = null;
      _landmarkLng = null;
      _landmarkRadiusKm = _defaultLandmarkRadiusKm;
    });
    await _fetchShops();
  }

  void _clearLandmark() {
    setState(() {
      _landmarkQuery = null;
      _landmarkName = null;
      _landmarkLat = null;
      _landmarkLng = null;
    });
    _fetchShops();
  }

  /// External places have no MicroLink record behind them, so tapping one
  /// shows a small info sheet with a "Get Directions" action only.
  void _showExternalPlaceSheet(ExternalPlace place) {
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(AppSpacing.lg, 0, AppSpacing.lg, AppSpacing.lg),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(Icons.public, color: Theme.of(sheetContext).colorScheme.primary),
                  const SizedBox(width: AppSpacing.sm),
                  Expanded(
                    child: Text(
                      place.name,
                      style: Theme.of(sheetContext)
                          .textTheme
                          .titleMedium
                          ?.copyWith(fontWeight: FontWeight.w700),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: AppSpacing.xs),
              Text(
                'From OpenStreetMap - not a registered MicroLink shop',
                style: Theme.of(sheetContext)
                    .textTheme
                    .bodySmall
                    ?.copyWith(color: sheetContext.appColors.textSecondary),
              ),
              const SizedBox(height: AppSpacing.lg),
              if (place.address.isNotEmpty) _InfoRow(icon: Icons.place_outlined, text: place.address),
              if (place.openingHours != null)
                _InfoRow(icon: Icons.access_time, text: place.openingHours!),
              if (place.phone != null) _InfoRow(icon: Icons.call_outlined, text: place.phone!),
              const SizedBox(height: AppSpacing.lg),
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: () {
                    Navigator.pop(sheetContext);
                    Navigator.pushNamed(
                      context,
                      AppRoutes.liveMap,
                      arguments: LiveMapArgs(
                        destinationLat: place.latitude,
                        destinationLng: place.longitude,
                        destinationLabel: place.name,
                      ),
                    );
                  },
                  icon: const Icon(Icons.directions_outlined),
                  label: const Text('Get Directions'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showFilterSheet() {
    // Staged copies: nothing touches the real screen state until "Apply".
    String? tempCategory = _selectedCategory;
    bool tempOpenNow = _openNowOnly;
    bool tempDelivery = _deliveryOnly;
    int tempMinTrust = _minTrust;
    String tempSort = _sort;
    double tempRadius = _landmarkQuery != null ? _landmarkRadiusKm : _radiusKm;
    bool tempRadiusEnabled = _radiusEnabled;
    final landmarkMode = _landmarkQuery != null;
    final hasLocation = landmarkMode || _lat != null;

    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) {
        return StatefulBuilder(
          builder: (sheetContext, setSheetState) {
            final colorScheme = Theme.of(sheetContext).colorScheme;
            final textTheme = Theme.of(sheetContext).textTheme;
            return SafeArea(
              child: Padding(
                padding: EdgeInsets.only(bottom: MediaQuery.of(sheetContext).viewInsets.bottom),
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(AppSpacing.lg),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          IconButton(
                            icon: const Icon(Icons.close),
                            onPressed: () => Navigator.pop(sheetContext),
                          ),
                          Expanded(
                            child: Text(
                              'Filter Results',
                              textAlign: TextAlign.center,
                              style: textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
                            ),
                          ),
                          TextButton(
                            onPressed: () => setSheetState(() {
                              tempCategory = null;
                              tempOpenNow = false;
                              tempDelivery = false;
                              tempMinTrust = 0;
                              tempSort = 'smart';
                              tempRadius = landmarkMode ? _defaultLandmarkRadiusKm : 10;
                            }),
                            child: const Text('Reset'),
                          ),
                        ],
                      ),
                      const SizedBox(height: AppSpacing.md),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(
                            landmarkMode ? 'Radius around landmark' : 'Select radius',
                            style: textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
                          ),
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              if (landmarkMode || tempRadiusEnabled)
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: AppSpacing.sm,
                                    vertical: 2,
                                  ),
                                  decoration: BoxDecoration(
                                    color: colorScheme.primaryContainer,
                                    borderRadius: BorderRadius.circular(AppRadius.pill),
                                  ),
                                  child: Text(
                                    '${tempRadius.toStringAsFixed(1)} km',
                                    style: textTheme.labelMedium?.copyWith(
                                      color: colorScheme.primary,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                ),
                              // A landmark search is a radius search, so the
                              // switch would be a lie in that mode.
                              if (!landmarkMode)
                                Switch(
                                  value: tempRadiusEnabled,
                                  onChanged: hasLocation
                                      ? (value) =>
                                          setSheetState(() => tempRadiusEnabled = value)
                                      : null,
                                ),
                            ],
                          ),
                        ],
                      ),
                      Slider(
                        value: tempRadius,
                        min: 0.5,
                        // 50, not 10: the nearest shop to a user outside a
                        // town can easily be 15-20km away, and a ceiling
                        // below that made "widen the radius" impossible to
                        // act on -- the slider ran out before it reached
                        // anything.
                        max: 50,
                        divisions: 99,
                        onChanged: hasLocation && (landmarkMode || tempRadiusEnabled)
                            ? (value) => setSheetState(() => tempRadius = value)
                            : null,
                      ),
                      if (!landmarkMode && !tempRadiusEnabled)
                        Padding(
                          padding: const EdgeInsets.only(bottom: AppSpacing.sm),
                          child: Text(
                            'Showing shops anywhere in Sri Lanka.',
                            style: textTheme.labelSmall
                                ?.copyWith(color: sheetContext.appColors.textSecondary),
                          ),
                        ),
                      if (!hasLocation)
                        Padding(
                          padding: const EdgeInsets.only(bottom: AppSpacing.sm),
                          child: Text(
                            'Turn on location, or search near a landmark, to filter by distance.',
                            style: textTheme.bodySmall
                                ?.copyWith(color: sheetContext.appColors.textSecondary),
                          ),
                        ),
                      const SizedBox(height: AppSpacing.md),
                      Text('Categories',
                          style: textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
                      const SizedBox(height: AppSpacing.sm),
                      Wrap(
                        spacing: AppSpacing.sm,
                        runSpacing: AppSpacing.sm,
                        children: shopCategories.map((category) {
                          final selected = tempCategory == category;
                          return _CategoryTile(
                            label: formatCategoryLabel(category),
                            icon: categoryIcon(category),
                            selected: selected,
                            onTap: () =>
                                setSheetState(() => tempCategory = selected ? null : category),
                          );
                        }).toList(),
                      ),
                      const SizedBox(height: AppSpacing.md),
                      SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        title: const Text('Open Now Only'),
                        value: tempOpenNow,
                        onChanged: (value) => setSheetState(() => tempOpenNow = value),
                      ),
                      SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        title: const Text('Delivery available'),
                        value: tempDelivery,
                        onChanged: (value) => setSheetState(() => tempDelivery = value),
                      ),
                      const SizedBox(height: AppSpacing.sm),
                      Text('Minimum trust score',
                          style: textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
                      const SizedBox(height: AppSpacing.sm),
                      Wrap(
                        spacing: AppSpacing.sm,
                        children: [
                          for (var score = 0; score <= 5; score++)
                            ChoiceChip(
                              label: Text(score == 0 ? 'Any' : (score == 5 ? '5 only' : '$score+')),
                              selected: tempMinTrust == score,
                              onSelected: (_) => setSheetState(() => tempMinTrust = score),
                            ),
                        ],
                      ),
                      const SizedBox(height: AppSpacing.md),
                      Text('Sort by',
                          style: textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
                      const SizedBox(height: AppSpacing.sm),
                      Wrap(
                        spacing: AppSpacing.sm,
                        children: [
                          ChoiceChip(
                            label: const Text('Nearest'),
                            selected: tempSort == 'smart',
                            onSelected: (_) => setSheetState(() => tempSort = 'smart'),
                          ),
                          ChoiceChip(
                            label: const Text('Top rated'),
                            selected: tempSort == 'rating',
                            onSelected: (_) => setSheetState(() => tempSort = 'rating'),
                          ),
                          ChoiceChip(
                            label: const Text('Newest'),
                            selected: tempSort == 'newest',
                            onSelected: (_) => setSheetState(() => tempSort = 'newest'),
                          ),
                        ],
                      ),
                      const SizedBox(height: AppSpacing.lg),
                      SizedBox(
                        width: double.infinity,
                        child: FilledButton(
                          onPressed: () {
                            Navigator.pop(sheetContext);
                            setState(() {
                              _selectedCategory = tempCategory;
                              _openNowOnly = tempOpenNow;
                              _deliveryOnly = tempDelivery;
                              _minTrust = tempMinTrust;
                              _sort = tempSort;
                              if (landmarkMode) {
                                _landmarkRadiusKm = tempRadius;
                              } else {
                                _radiusKm = tempRadius;
                                _radiusEnabled = tempRadiusEnabled;
                              }
                            });
                            _fetchShops();
                          },
                          child: const Text('Apply Filters'),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }

  // ----------------------------------------------------------------- build

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final colors = context.appColors;

    return Scaffold(
      appBar: BrandedAppBar(title: Text(tr('shops.title'))),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.lg,
              AppSpacing.lg,
              AppSpacing.lg,
              AppSpacing.sm,
            ),
            child: Row(
              children: [
                Expanded(
                  child: AppTextField(
                    controller: _searchController,
                    label: tr('shops.search_hint'),
                    hint: 'Shop, category or product...',
                    prefixIcon: Icons.search,
                    onChanged: _onSearchChanged,
                  ),
                ),
                const SizedBox(width: AppSpacing.sm),
                // Item 1: landmark search already worked, but the chip sat
                // under the search box among the category chips and the
                // reporter never found it. It belongs next to the box it
                // modifies.
                IconButton.filledTonal(
                  onPressed: _askLandmark,
                  icon: Icon(
                    _landmarkQuery == null ? Icons.place_outlined : Icons.place,
                  ),
                  tooltip: tr('shops.near_landmark'),
                  isSelected: _landmarkQuery != null,
                ),
                const SizedBox(width: AppSpacing.sm),
                IconButton.filled(
                  onPressed: _showFilterSheet,
                  icon: const Icon(Icons.tune),
                  tooltip: 'Filters',
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(AppSpacing.lg, 0, AppSpacing.lg, AppSpacing.sm),
            child: Align(
              alignment: Alignment.centerLeft,
              child: _landmarkQuery == null
                  // Still labelled as well as placed in the row: an icon on
                  // its own would trade one discoverability problem for
                  // another.
                  ? ActionChip(
                      avatar: const Icon(Icons.place_outlined, size: 18),
                      label: Text(tr('shops.near_landmark')),
                      onPressed: _askLandmark,
                    )
                  : InputChip(
                      avatar: const Icon(Icons.place, size: 18),
                      label: Text(
                        'Near ${_landmarkName ?? _landmarkQuery} · '
                        '${_landmarkRadiusKm.toStringAsFixed(1)} km',
                      ),
                      onDeleted: _clearLandmark,
                    ),
            ),
          ),
          SizedBox(
            height: 40,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
              children: [
                _CategoryChip(
                  label: 'All',
                  selected: _selectedCategory == null,
                  onTap: () => _onCategorySelected(null),
                ),
                ...shopCategories.map(
                  (category) => Padding(
                    padding: const EdgeInsets.only(left: AppSpacing.sm),
                    child: _CategoryChip(
                      label: formatCategoryLabel(category),
                      selected: _selectedCategory == category,
                      onTap: () => _onCategorySelected(category),
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: AppSpacing.sm),
          if (_offline) OfflineBanner(savedAt: _cacheSavedAt),
          Expanded(
            child: RefreshIndicator(
              onRefresh: _fetchShops,
              child: AsyncStateView<List<ShopEntry>>(
                state: _state,
                onRetry: _fetchShops,
                isEmpty: (data) => data.isEmpty,
                emptyTitle: tr('shops.none_title'),
                emptyMessage: _emptyMessage,
                emptyIcon: Icons.storefront_outlined,
                loadingSkeleton: const SkeletonList(),
                builder: (context, shops) {
                  final origin = _searchOrigin;
                  final hasOrigin = origin.lat != null && origin.lng != null;
                  return Column(
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(
                          AppSpacing.lg,
                          0,
                          AppSpacing.lg,
                          AppSpacing.sm,
                        ),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Flexible(
                              child: Text(
                                '${shops.length} ${shops.length == 1 ? 'shop' : 'shops'}'
                                '${_sort == 'rating' ? ' · top rated first' : (hasOrigin && _sort == 'smart' ? ' · nearest first' : '')}',
                                style: textTheme.bodySmall?.copyWith(color: colors.textSecondary),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            _ListMapToggle(
                              showMap: _showMap,
                              mapEnabled: !_offline,
                              onChanged: (value) => setState(() => _showMap = value),
                            ),
                          ],
                        ),
                      ),
                      Expanded(
                        child: _showMap && !_offline
                            ? _ShopMapView(
                                shops: shops,
                                center: hasOrigin
                                    ? ll.LatLng(origin.lat!, origin.lng!)
                                    : (shops.isNotEmpty
                                        ? ll.LatLng(shops.first.shop.latitude, shops.first.shop.longitude)
                                        : _fallbackCenter),
                                landmark: (_landmarkQuery != null && hasOrigin)
                                    ? ll.LatLng(origin.lat!, origin.lng!)
                                    : null,
                                onShopTap: (entry) => _openShop(entry.shop),
                              )
                            : _buildList(shops, colors, textTheme),
                      ),
                    ],
                  );
                },
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildList(List<ShopEntry> shops, AppColorsExtension colors, TextTheme textTheme) {
    final externalCount =
        (_externalPlaces.isEmpty && !_loadingExternal) ? 0 : 1 + _externalPlaces.length;
    return ListView.builder(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(AppSpacing.lg, 0, AppSpacing.lg, AppSpacing.lg),
      itemCount: shops.length + externalCount,
      itemBuilder: (context, index) {
        if (index < shops.length) {
          final entry = shops[index];
          return Padding(
            padding: const EdgeInsets.only(bottom: AppSpacing.md),
            child: _ShopTile(entry: entry, onTap: () => _openShop(entry.shop)),
          );
        }
        final externalIndex = index - shops.length;
        if (externalIndex == 0) {
          return Padding(
            padding: const EdgeInsets.only(top: AppSpacing.sm, bottom: AppSpacing.sm),
            child: Row(
              children: [
                Icon(Icons.public, size: 16, color: colors.textSecondary),
                const SizedBox(width: AppSpacing.xs),
                Text(
                  'More nearby, via OpenStreetMap',
                  style: textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
                ),
                if (_loadingExternal) ...[
                  const SizedBox(width: AppSpacing.sm),
                  SizedBox(
                    width: 12,
                    height: 12,
                    child: CircularProgressIndicator(strokeWidth: 2, color: colors.textSecondary),
                  ),
                ],
              ],
            ),
          );
        }
        final place = _externalPlaces[externalIndex - 1];
        return Padding(
          padding: const EdgeInsets.only(bottom: AppSpacing.md),
          child: _ExternalPlaceTile(place: place, onTap: () => _showExternalPlaceSheet(place)),
        );
      },
    );
  }
}

// ==========================================================================
// Widgets
// ==========================================================================

/// Asks for a landmark name. Owns its own text controller so it is disposed
/// together with the dialog.
class _LandmarkDialog extends StatefulWidget {
  const _LandmarkDialog();

  @override
  State<_LandmarkDialog> createState() => _LandmarkDialogState();
}

class _LandmarkDialogState extends State<_LandmarkDialog> {
  final _controller = TextEditingController();

  /// Item 1: landmarks to offer, from shop-service's built-in table. An
  /// empty box gives no clue what it accepts, which is half the reason the
  /// feature went unused.
  List<String> _suggestions = const [];

  @override
  void initState() {
    super.initState();
    _loadSuggestions();
  }

  Future<void> _loadSuggestions() async {
    try {
      final response =
          await ApiClient.instance.get('/shops/landmark/suggestions');
      final names = (response as List)
          .whereType<Map>()
          .map((item) => item['name'] as String? ?? '')
          .where((name) => name.isNotEmpty)
          .toList();
      if (!mounted || names.isEmpty) return;
      setState(() => _suggestions = names);
    } catch (_) {
      // Offline, or an older server: these are the names shop-service
      // resolves without the online geocoder, so they are safe to offer
      // from here as well.
      if (!mounted) return;
      setState(() => _suggestions = _fallbackLandmarks);
    }
  }

  /// Mirrors the shortest name per place in shop-service's LANDMARKS table,
  /// for when the suggestions endpoint cannot be reached.
  static const List<String> _fallbackLandmarks = [
    'Colombo Fort',
    'Pettah, Colombo',
    'Nugegoda',
    'Maharagama',
    'Kottawa',
    'Homagama',
    'Negombo',
    'Kandy',
    'Galle',
  ];

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(tr('shops.near_landmark')),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: _controller,
            autofocus: true,
            textInputAction: TextInputAction.search,
            decoration: const InputDecoration(hintText: 'e.g. Central Bus Stand'),
            onSubmitted: (value) => Navigator.pop(context, value.trim()),
          ),
          if (_suggestions.isNotEmpty) ...[
            const SizedBox(height: AppSpacing.md),
            Text(
              'Or pick one',
              style: Theme.of(context).textTheme.labelMedium?.copyWith(
                    color: context.appColors.textSecondary,
                  ),
            ),
            const SizedBox(height: AppSpacing.xs),
            Wrap(
              spacing: AppSpacing.sm,
              runSpacing: AppSpacing.xs,
              children: [
                for (final name in _suggestions)
                  ActionChip(
                    label: Text(name),
                    onPressed: () => Navigator.pop(context, name),
                  ),
              ],
            ),
          ],
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(
          onPressed: () => Navigator.pop(context, _controller.text.trim()),
          child: const Text('Search'),
        ),
      ],
    );
  }
}

/// The icon-in-box category tile used inside the filter sheet.
class _CategoryTile extends StatelessWidget {
  final String label;
  final IconData icon;
  final bool selected;
  final VoidCallback onTap;

  const _CategoryTile({
    required this.label,
    required this.icon,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Material(
      color: selected ? colorScheme.primary : colorScheme.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(AppRadius.input),
      child: InkWell(
        borderRadius: BorderRadius.circular(AppRadius.input),
        onTap: onTap,
        child: Container(
          width: 96,
          padding: const EdgeInsets.symmetric(vertical: AppSpacing.md, horizontal: AppSpacing.sm),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, color: selected ? colorScheme.onPrimary : colorScheme.onSurfaceVariant),
              const SizedBox(height: AppSpacing.xs),
              Text(
                label,
                textAlign: TextAlign.center,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.labelMedium?.copyWith(
                      color: selected ? colorScheme.onPrimary : colorScheme.onSurfaceVariant,
                      fontWeight: FontWeight.w600,
                    ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A pill-shaped category chip (filled when selected, outlined otherwise).
class _CategoryChip extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _CategoryChip({required this.label, required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final colors = context.appColors;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppRadius.pill),
        child: Container(
          alignment: Alignment.center,
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md, vertical: AppSpacing.sm),
          decoration: BoxDecoration(
            color: selected ? colorScheme.primary : colorScheme.surface,
            borderRadius: BorderRadius.circular(AppRadius.pill),
            border: selected ? null : Border.all(color: colorScheme.outlineVariant),
          ),
          child: Text(
            label,
            style: Theme.of(context).textTheme.labelMedium?.copyWith(
                  color: selected ? colorScheme.onPrimary : colors.textSecondary,
                  fontWeight: FontWeight.w600,
                ),
          ),
        ),
      ),
    );
  }
}

/// List / Map segmented control. "Map" is disabled while offline because map
/// tiles need the internet.
class _ListMapToggle extends StatelessWidget {
  final bool showMap;
  final bool mapEnabled;
  final ValueChanged<bool> onChanged;

  const _ListMapToggle({
    required this.showMap,
    required this.mapEnabled,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final colors = context.appColors;
    final textTheme = Theme.of(context).textTheme;

    Widget segment(String label, {required bool active, required VoidCallback? onTap}) {
      return InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppRadius.pill),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md, vertical: AppSpacing.xs),
          decoration: BoxDecoration(
            color: active ? colorScheme.surface : Colors.transparent,
            borderRadius: BorderRadius.circular(AppRadius.pill),
            boxShadow: active
                ? [
                    BoxShadow(
                      color: colorScheme.shadow.withValues(alpha: 0.08),
                      blurRadius: 2,
                      offset: const Offset(0, 1),
                    ),
                  ]
                : null,
          ),
          child: Text(
            label,
            style: textTheme.labelSmall?.copyWith(
              color: active ? colorScheme.onSurface : colors.textSecondary,
              fontWeight: active ? FontWeight.w700 : FontWeight.w600,
            ),
          ),
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(AppRadius.pill),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          segment('List', active: !showMap, onTap: () => onChanged(false)),
          segment('Map', active: showMap, onTap: mapEnabled ? () => onChanged(true) : null),
        ],
      ),
    );
  }
}

/// Shops as pins on an OpenStreetMap map (SRS: "show them on map and list").
class _ShopMapView extends StatelessWidget {
  final List<ShopEntry> shops;
  final ll.LatLng center;
  final ll.LatLng? landmark;
  final ValueChanged<ShopEntry> onShopTap;

  const _ShopMapView({
    required this.shops,
    required this.center,
    required this.landmark,
    required this.onShopTap,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Stack(
      children: [
        FlutterMap(
          options: MapOptions(initialCenter: center, initialZoom: 14),
          children: [
            MapTileLayer(),
            MarkerLayer(
              markers: [
                for (final entry in shops)
                  Marker(
                    point: ll.LatLng(entry.shop.latitude, entry.shop.longitude),
                    width: 44,
                    height: 44,
                    child: GestureDetector(
                      onTap: () => onShopTap(entry),
                      child: Icon(
                        Icons.location_pin,
                        size: 40,
                        color: entry.extras.status == 'open'
                            ? colorScheme.primary
                            : colorScheme.outline,
                      ),
                    ),
                  ),
                if (landmark != null)
                  Marker(
                    point: landmark!,
                    width: 36,
                    height: 36,
                    child: Icon(Icons.flag_rounded, color: colorScheme.error, size: 32),
                  ),
              ],
            ),
          ],
        ),
        Positioned(
          right: 6,
          bottom: 4,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            color: colorScheme.surface.withValues(alpha: 0.8),
            child: Text(
              '© OpenStreetMap contributors',
              style: Theme.of(context).textTheme.labelSmall,
            ),
          ),
        ),
      ],
    );
  }
}

class _InfoRow extends StatelessWidget {
  final IconData icon;
  final String text;

  const _InfoRow({required this.icon, required this.text});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.sm),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: context.appColors.textSecondary),
          const SizedBox(width: AppSpacing.sm),
          Expanded(child: Text(text)),
        ],
      ),
    );
  }
}

/// A real OpenStreetMap place - similar to [_ShopTile] but with a globe icon,
/// since it has no rating, status or products.
class _ExternalPlaceTile extends StatelessWidget {
  final ExternalPlace place;
  final VoidCallback onTap;

  const _ExternalPlaceTile({required this.place, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final colors = context.appColors;
    final colorScheme = Theme.of(context).colorScheme;

    return AppCard(
      onTap: onTap,
      padding: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.md),
        child: Row(
          children: [
            Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(
                color: colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(AppRadius.input),
              ),
              alignment: Alignment.center,
              child: Icon(Icons.public, color: colors.textSecondary),
            ),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    place.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    place.address.isEmpty ? 'OpenStreetMap listing' : place.address,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: textTheme.bodySmall?.copyWith(color: colors.textSecondary),
                  ),
                ],
              ),
            ),
            Icon(Icons.chevron_right, color: colorScheme.outline),
          ],
        ),
      ),
    );
  }
}

/// One shop in the results: photo, name, status, category/address, trust
/// score, distance, delivery flag and the product availability indicator.
class _ShopTile extends StatelessWidget {
  final ShopEntry entry;
  final VoidCallback onTap;

  const _ShopTile({required this.entry, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final shop = entry.shop;
    final extras = entry.extras;
    final textTheme = Theme.of(context).textTheme;
    final colors = context.appColors;
    final distance = entry.distanceKm;

    return AppCard(
      onTap: onTap,
      padding: EdgeInsets.zero,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(AppRadius.card),
        child: IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _ShopThumbnail(shop: shop, photoUrl: extras.photos.isNotEmpty ? extras.photos.first : null),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.all(AppSpacing.md),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                            child: Text(
                              shop.name,
                              style: textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          const SizedBox(width: AppSpacing.sm),
                          ShopStatusBadge(status: extras.status),
                        ],
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '${formatCategoryLabel(shop.category)} · ${shop.address.isEmpty ? 'No address on file' : shop.address}',
                        style: textTheme.bodySmall?.copyWith(color: colors.textSecondary),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      if (extras.matchedProduct != null) ...[
                        const SizedBox(height: 2),
                        Text(
                          'Sells: ${extras.matchedProduct}',
                          style: textTheme.bodySmall?.copyWith(
                            color: Theme.of(context).colorScheme.primary,
                            fontWeight: FontWeight.w600,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                      const SizedBox(height: AppSpacing.sm),
                      Wrap(
                        spacing: AppSpacing.md,
                        runSpacing: 2,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          if (shop.ratingCount > 0)
                            RatingChip(rating: extras.trustScore, count: shop.ratingCount)
                          else
                            Text(
                              'No ratings yet',
                              style: textTheme.bodySmall?.copyWith(color: colors.textSecondary),
                            ),
                          if (extras.delayProne)
                            OftenDelayedChip(
                              medianPickupWaitMin: extras.medianPickupWaitMin,
                            ),
                          if (distance != null)
                            Text(
                              '${distance.toStringAsFixed(1)} km away',
                              style: textTheme.bodySmall?.copyWith(color: colors.textSecondary),
                            ),
                          if (extras.deliveryAvailable)
                            Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(Icons.delivery_dining_outlined, size: 14, color: colors.textSecondary),
                                const SizedBox(width: 3),
                                Text(
                                  'Delivery',
                                  style: textTheme.bodySmall?.copyWith(color: colors.textSecondary),
                                ),
                              ],
                            ),
                        ],
                      ),
                      const SizedBox(height: 6),
                      AvailabilityIndicator(extras: extras),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ShopThumbnail extends StatelessWidget {
  final Shop shop;
  final String? photoUrl;

  const _ShopThumbnail({required this.shop, required this.photoUrl});

  static const double _size = 96;

  @override
  Widget build(BuildContext context) {
    final url = photoUrl ?? shop.imageUrl;
    if (url != null && url.isNotEmpty) {
      return Image.network(
        mediaUrl(url) ?? url,
        width: _size,
        fit: BoxFit.cover,
        errorBuilder: (context, error, stackTrace) => _fallback(context),
      );
    }
    return _fallback(context);
  }

  Widget _fallback(BuildContext context) {
    final tint = categoryColors(context, shop.category);
    return Container(
      width: _size,
      color: tint.background,
      alignment: Alignment.center,
      child: Icon(categoryIcon(shop.category), size: 30, color: tint.foreground),
    );
  }
}
