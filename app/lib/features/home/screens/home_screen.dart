import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart' as ll;

import '../../../core/l10n/app_strings.dart';
import '../../../core/utils/media_url.dart';
import '../../../core/constants/app_constants.dart';
import '../../../core/models/ad.dart';
import '../../../core/models/shop.dart';
import '../../../core/models/suggested_shop.dart';
import '../../../core/models/user.dart';
import '../../../core/network/api_client.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/network/session_manager.dart';
import '../../../core/theme/app_colors_extension.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/theme_controller.dart';
import '../../../core/utils/app_router.dart' show LiveMapArgs, ShopDetailArgs, ShopListArgs;
import '../../../core/utils/category_style.dart';
import '../../../core/network/multipart_upload.dart';
import '../../../core/network/profile_photo_service.dart';
import '../../../core/widgets/coverflow_carousel.dart';
import '../../../core/widgets/fade_in.dart';
import '../../../core/widgets/profile_avatar.dart';
import '../../../core/widgets/role_nav_scaffold.dart';
import '../../../core/widgets/section_action_button.dart';
import '../../../core/widgets/shop_preview_card.dart';
import '../../../core/location/location_service.dart';
import '../../delivery/screens/driver_home_screen.dart';
import '../../delivery/screens/my_orders_screen.dart';
import '../../location/widgets/map_pin.dart';
import '../../location/widgets/map_tile_layer.dart';
import '../../navigation/screens/live_map_screen.dart';
import '../../notifications/widgets/notification_bell.dart';
import '../../shop_owner/screens/shop_owner_dashboard_screen.dart';
import '../widgets/suggested_shop_card.dart';

/// The Home screen. Each role lands on a home built for what they actually do:
/// customers get the "Explore" shopping home (search, a personalized
/// recommendations rail, a nearby-shops teaser); shop owners, delivery agents
/// and admins each get a focused staff home that is just a labelled list of
/// shortcuts into their own tools. The role -> shortcuts mapping lives in one
/// place ([_staffHomeFor]) so it is easy to change.
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  double? _lat;
  double? _lng;

  bool _loadingRecommended = true;
  List<Shop> _recommended = const [];
  String? _recommendedError;

  bool _loadingNearby = true;
  int? _nearbyCount;

  bool _loadingTrust = true;
  double? _trustScore;
  int? _totalReports;

  bool _loadingAds = true;
  List<Ad> _ads = const [];

  bool _loadingNearbyShops = true;
  /// True when the shops shown are not actually near the user.
  bool _nearbyIsNationwide = false;
  List<Shop> _nearbyShops = const [];

  bool _loadingSuggestions = true;
  List<SuggestedShop> _userSuggestions = const [];

  @override
  void initState() {
    super.initState();
    // Every role has an avatar, so this runs whoever is signed in. It fails
    // quietly -- a missing photo is not worth interrupting anyone over.
    ProfilePhotoService.instance.load();
    // Only the shopping home needs shops/recommendations/etc. loaded; the
    // staff homes are just static shortcut lists.
    if (SessionManager.instance.isCustomer) _bootstrap();
  }

  Future<void> _bootstrap() async {
    await _resolveLocation();
    await Future.wait([
      _fetchRecommended(),
      _fetchNearbyCount(),
      _fetchTrustScore(),
      _fetchAds(),
      _fetchNearbyShops(),
      _fetchUserSuggestions(),
    ]);
  }

  /// The "User Suggestions" rail: shops other users suggested that an admin
  /// approved, nearest first when the location is known. Like "Sponsored",
  /// an empty result or a failure just leaves the section out -- it is extra
  /// content, so it never shows an error on Home.
  Future<void> _fetchUserSuggestions() async {
    try {
      final response = await ApiClient.instance.get(
            '/crowdsource/shop-reports/approved',
            query: {
              // Every approved suggestion is for everyone; nearest first.
              'limit': 20,
              if (_lat != null && _lng != null) 'lat': _lat,
              if (_lat != null && _lng != null) 'lng': _lng,
            },
          ) as List;
      final suggestions = response
          .map((e) => SuggestedShop.fromJson(e as Map<String, dynamic>))
          .toList();
      if (!mounted) return;
      setState(() {
        _userSuggestions = suggestions;
        _loadingSuggestions = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _loadingSuggestions = false);
    }
  }

  /// The "Nearby Shops" rail and map: plain distance-sorted `/shops`,
  /// distinct from the personalized "Recommended for You" rail above it
  /// (which comes from recommendation-service's interaction-boosted ranking).
  ///
  /// Falls back twice so the section is never just an empty map. If nothing
  /// is within the default radius -- very possible in a country where the
  /// nearest listed shop may be two towns away -- it widens the search, and
  /// with no GPS fix at all it shows shops nationwide. [_nearbyIsNationwide]
  /// drives the caption so the user is never told that a shop in Jaffna is
  /// near them.
  Future<void> _fetchNearbyShops() async {
    try {
      List<dynamic> response;
      var nationwide = false;

      if (_lat != null && _lng != null) {
        response = await ApiClient.instance.get(
              '/shops',
              query: {'lat': _lat, 'lng': _lng, 'radius_km': 10, 'limit': 10},
            ) as List;
        if (response.isEmpty) {
          // Nothing close by: widen rather than show an empty map.
          response = await ApiClient.instance.get(
                '/shops',
                query: {'lat': _lat, 'lng': _lng, 'limit': 10},
              ) as List;
          nationwide = response.isNotEmpty;
        }
      } else {
        response = await ApiClient.instance.get('/shops', query: {'limit': 10}) as List;
        nationwide = true;
      }

      final shops = response.map((e) => Shop.fromJson(e as Map<String, dynamic>)).toList();
      if (!mounted) return;
      setState(() {
        _nearbyShops = shops;
        _nearbyIsNationwide = nationwide;
        _loadingNearbyShops = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _loadingNearbyShops = false);
    }
  }

  /// Approved sponsor banners for the "Sponsored" section -- an empty result
  /// (no ads yet, or the endpoint failing) just hides the section rather
  /// than showing an error, since it's promotional, not core content.
  Future<void> _fetchAds() async {
    try {
      final response = await ApiClient.instance.get('/ads/active');
      final ads = (response as List).map((e) => Ad.fromJson(e as Map<String, dynamic>)).toList();
      if (!mounted) return;
      setState(() {
        _ads = ads;
        _loadingAds = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _loadingAds = false);
    }
  }

  /// Real per-user crowdsourcing standing from `/crowdsource/trust-score/me`
  /// -- there's no cross-user "community" aggregate a regular user can see,
  /// so this reflects the signed-in user's own contributions, not neighbors'.
  /// Item 7: whether this account may confirm crowd-reported shops.
  bool _canConfirmShops = false;

  Future<void> _fetchTrustScore() async {
    try {
      final response = await ApiClient.instance.get('/crowdsource/trust-score/me');
      final data = response as Map<String, dynamic>;
      if (!mounted) return;
      setState(() {
        _trustScore = (data['score'] as num).toDouble();
        _totalReports = data['total_reports'] as int;
        // Items 6 and 7: the server decides who may confirm a neighbour's
        // shop report, so the entry point is only offered when it says yes.
        // Absent (an older server) stays false rather than offering a
        // screen whose every answer would come back 403.
        _canConfirmShops = data['can_confirm_shops'] as bool? ?? false;
        _loadingTrust = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _loadingTrust = false);
    }
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
      if (!await Geolocator.isLocationServiceEnabled()) return;
      final position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(accuracy: LocationAccuracy.medium),
      );
      _lat = position.latitude;
      _lng = position.longitude;
    } catch (_) {
      // Non-fatal: the sections below degrade gracefully without location.
    }
  }

  Future<void> _fetchRecommended() async {
    setState(() {
      _loadingRecommended = true;
      _recommendedError = null;
    });
    try {
      final response = await ApiClient.instance.get(
        '/recommendations',
        query: {'lat': _lat, 'lng': _lng},
      );
      final shops =
          (response as List).map((e) => Shop.fromJson(e as Map<String, dynamic>)).toList();
      if (!mounted) return;
      setState(() {
        _recommended = shops.take(6).toList();
        _loadingRecommended = false;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _recommendedError = e.message;
        _loadingRecommended = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _recommendedError = 'Could not load recommendations.';
        _loadingRecommended = false;
      });
    }
  }

  /// Real count of shops shop-service returns within its default 10km radius
  /// for the resolved location -- not shown at all if location is
  /// unavailable, rather than guessing a number.
  Future<void> _fetchNearbyCount() async {
    if (_lat == null || _lng == null) {
      setState(() => _loadingNearby = false);
      return;
    }
    try {
      final response =
          await ApiClient.instance.get(
        '/shops',
        query: {'lat': _lat, 'lng': _lng, 'radius_km': 10},
      );
      if (!mounted) return;
      setState(() {
        _nearbyCount = (response as List).length;
        _loadingNearby = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _loadingNearby = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final session = SessionManager.instance;

    // A role with its own bottom navigation brings its whole scaffold with
    // it, bar included, so it replaces this screen rather than sitting
    // inside it -- nesting the two would stack two bottom bars.
    final roleNav = _roleNavFor(session);
    if (roleNav != null) return roleNav;

    final staffHome = _staffHomeFor(session);
    return Scaffold(
      body: SafeArea(
        child: FadeIn(
          child: staffHome ?? _buildExploreHome(context),
        ),
      ),
      bottomNavigationBar: staffHome != null ? _staffNavBar(context) : _exploreNavBar(context),
    );
  }

  /// Roles whose tools belong in a bottom bar rather than behind a menu.
  ///
  /// A delivery agent used to land on four cards that each pushed a screen,
  /// so every switch between "what can I pick up" and "what am I carrying"
  /// cost a tap in and a tap back. As destinations they are one tap apart and
  /// keep their state, which matters most while actually driving.
  Widget? _roleNavFor(SessionManager session) {
    if (!session.isDeliveryAgent) return null;

    return RoleNavScaffold(
      items: [
        RoleNavItem(
          label: 'Jobs',
          icon: Icons.two_wheeler_outlined,
          selectedIcon: Icons.two_wheeler,
          builder: (_) => const DriverHomeScreen(),
        ),
        RoleNavItem(
          label: 'Deliveries',
          icon: Icons.receipt_long_outlined,
          selectedIcon: Icons.receipt_long,
          builder: (_) => const MyOrdersScreen(),
        ),
        RoleNavItem(
          label: 'Map',
          icon: Icons.map_outlined,
          selectedIcon: Icons.map,
          // No destination: the map opens on the driver's own position
          // rather than routing to a particular drop-off.
          builder: (_) => const LiveMapScreen(args: LiveMapArgs()),
        ),
      ],
      trailingAction: RoleNavAction(
        label: tr('nav.account'),
        icon: Icons.account_circle_outlined,
        onTap: () => _showAccountSheet(context),
      ),
    );
  }

  /// The single place that maps a non-customer role to its home: a title and a
  /// list of shortcut cards into that role's tools. Returns `null` for a
  /// customer, who gets the shopping home instead. Add or reorder a role's
  /// shortcuts here.
  Widget? _staffHomeFor(SessionManager session) {
    if (session.isAdmin) {
      return _StaffHomeBody(
        onOpenAccount: _showAccountSheet,
        actions: const [
          _StaffAction(
            icon: Icons.admin_panel_settings_outlined,
            title: 'Admin Dashboard',
            subtitle: 'Analytics, activity log, complaints, ads & plans',
            route: AppRoutes.adminDashboard,
          ),
          _StaffAction(
            icon: Icons.fact_check_outlined,
            title: 'Review & Monitor',
            subtitle: 'Shop and agent approvals, corrections, live system health',
            route: AppRoutes.adminReview,
          ),
        ],
      );
    }
    if (session.isShopOwner) {
      // The shop owner's home *is* their dashboard -- status, products, alerts
      // and analytics for their shop, not a menu of links to it.
      return ShopOwnerDashboardScreen(onOpenAccount: _showAccountSheet);
    }
    // A delivery agent has no entry here: those same four tools are the
    // destinations of the bottom bar built in [_roleNavFor], which runs
    // first.
    return null;
  }

  Widget _buildExploreHome(BuildContext context) {
    final session = SessionManager.instance;
    final textTheme = Theme.of(context).textTheme;

    return CustomScrollView(
      slivers: [
        // The greeting row is this screen's header, so it wears the same
        // burnt-orange band every other screen's app bar does. Edge to edge:
        // the colour runs to the screen's sides, the padding is inside it.
        SliverToBoxAdapter(
          child: Container(
            color: context.appColors.headerBackground,
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.lg,
              AppSpacing.sm,
              AppSpacing.lg,
              AppSpacing.md,
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                InkWell(
                  customBorder: const CircleBorder(),
                  onTap: () => _showAccountSheet(context),
                  child: ProfileAvatar(
                    radius: 22,
                    // A translucent white disc rather than the peach one:
                    // on the band, primaryContainer all but disappears.
                    backgroundColor: context.appColors.onHeader.withValues(alpha: 0.18),
                    foregroundColor: context.appColors.onHeader,
                  ),
                ),
                const SizedBox(width: AppSpacing.md),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '${tr('home.greeting')}, ${session.userName ?? ''}',
                        style: textTheme.bodyMedium?.copyWith(
                          color: context.appColors.onHeader.withValues(alpha: 0.82),
                        ),
                      ),
                      // Secondary to the wordmark on the right: it names the
                      // tab, the wordmark names the app. Ellipsis because
                      // this column is the part that gives way when the
                      // header runs out of width.
                      Text(
                        tr('home.explore'),
                        overflow: TextOverflow.ellipsis,
                        style: textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                          color: context.appColors.onHeader,
                        ),
                      ),
                    ],
                  ),
                ),
                // The brand label, grouped with the icons on the right. Kept
                // out of the Expanded above so it holds its full size and the
                // greeting column shrinks instead on a narrow screen. White
                // here, not brand orange -- orange on orange is unreadable.
                Padding(
                  padding: const EdgeInsets.only(right: AppSpacing.sm),
                  child: Text(
                    AppConstants.appName,
                    style: textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.w800,
                      color: context.appColors.onHeader,
                    ),
                  ),
                ),
                // The bell takes its colour from the ambient IconTheme, which
                // is tuned for the page background, not for this band.
                IconTheme.merge(
                  data: IconThemeData(color: context.appColors.onHeader),
                  child: const NotificationBell(),
                ),
                // Voice search isn't implemented anywhere in the app yet --
                // this says so plainly rather than being a silent dead button.
                _CircleIconButton(
                  icon: Icons.mic_none_outlined,
                  tooltip: 'Voice search',
                  onPressed: () => ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Voice search is coming soon.')),
                  ),
                ),
              ],
            ),
          ),
        ),
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(AppSpacing.lg, AppSpacing.lg, AppSpacing.lg, 0),
          sliver: SliverToBoxAdapter(
            child: _SearchBar(onTap: () => Navigator.pushNamed(context, AppRoutes.shopList)),
          ),
        ),
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(0, AppSpacing.lg, 0, 0),
          sliver: SliverToBoxAdapter(
            child: SizedBox(
              height: 84,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
                itemCount: shopCategories.length,
                separatorBuilder: (_, _) => const SizedBox(width: AppSpacing.md),
                itemBuilder: (context, index) {
                  final category = shopCategories[index];
                  return _CategoryQuickNavItem(
                    category: category,
                    onTap: () => Navigator.pushNamed(
                      context,
                      AppRoutes.shopList,
                      arguments: ShopListArgs(initialCategory: category),
                    ),
                  );
                },
              ),
            ),
          ),
        ),
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(AppSpacing.lg, AppSpacing.xl, 0, 0),
          sliver: SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.only(right: AppSpacing.lg),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          tr('home.recommended'),
                          style: textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          tr('home.recommended_sub'),
                          style: textTheme.bodySmall?.copyWith(color: context.appColors.textSecondary),
                        ),
                      ],
                    ),
                  ),
                  SectionActionButton(
                    label: tr('home.see_all'),
                    onPressed: () => Navigator.pushNamed(context, AppRoutes.recommendedShops),
                  ),
                ],
              ),
            ),
          ),
        ),
        SliverToBoxAdapter(child: _recommendedRail(context)),
        if (!_loadingNearbyShops && _nearbyShops.isNotEmpty) ...[
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(AppSpacing.lg, AppSpacing.xl, AppSpacing.lg, 0),
            sliver: SliverToBoxAdapter(
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(tr('home.nearby_shops'), style: textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
                  SectionActionButton(
                    label: tr('home.view_all'),
                    onPressed: () => Navigator.pushNamed(context, AppRoutes.shopList),
                  ),
                ],
              ),
            ),
          ),
          SliverToBoxAdapter(
            // The same carousel as the recommendations above, so the two
            // rails on this screen behave alike. Slightly slower: these are
            // ordered by distance, so the first few are the ones that
            // matter and there is no hurry to get past them.
            child: CoverflowCarousel(
              itemCount: _nearbyShops.length,
              step: const Duration(milliseconds: 4800),
              itemBuilder: (context, index) {
                final shop = _nearbyShops[index];
                return ShopPreviewCard(
                  shop: shop,
                  categoryIconFor: categoryIcon(shop.category),
                  categoryTint: categoryColors(context, shop.category),
                );
              },
            ),
          ),
        ],
        if (!_loadingSuggestions && _userSuggestions.isNotEmpty) ...[
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(AppSpacing.lg, AppSpacing.xl, AppSpacing.lg, 0),
            sliver: SliverToBoxAdapter(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    tr('home.user_suggestions'),
                    style: textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    tr('home.user_suggestions_sub'),
                    style: textTheme.bodySmall?.copyWith(color: context.appColors.textSecondary),
                  ),
                ],
              ),
            ),
          ),
          SliverToBoxAdapter(
            // The same moving carousel as the two rails above it.
            child: CoverflowCarousel(
              itemCount: _userSuggestions.length,
              // Taller than the other rails: these cards also show who
              // suggested the shop and the newest comment.
              height: 300,
              step: const Duration(milliseconds: 4600),
              itemBuilder: (context, index) =>
                  SuggestedShopCard(shop: _userSuggestions[index]),
            ),
          ),
        ],
        if (!_loadingAds && _ads.isNotEmpty) ...[
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(AppSpacing.lg, AppSpacing.xl, AppSpacing.lg, 0),
            sliver: SliverToBoxAdapter(
              child: Text('Sponsored', style: textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
            ),
          ),
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(AppSpacing.lg, AppSpacing.md, AppSpacing.lg, 0),
            sliver: SliverToBoxAdapter(child: _SponsoredCarousel(ads: _ads)),
          ),
        ],
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(AppSpacing.lg, AppSpacing.xl, AppSpacing.lg, 0),
          sliver: SliverToBoxAdapter(
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(tr('home.on_the_map'), style: textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
                TextButton(
                  onPressed: () => Navigator.pushNamed(context, AppRoutes.liveMap),
                  child: Text(tr('home.view_map')),
                ),
              ],
            ),
          ),
        ),
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(AppSpacing.lg, AppSpacing.md, AppSpacing.lg, 0),
          sliver: SliverToBoxAdapter(
            child: _NearbyMapCard(
              loading: _loadingNearby || _loadingNearbyShops,
              count: _nearbyCount,
              shops: _nearbyShops,
              nationwide: _nearbyIsNationwide,
              centre: _lat == null || _lng == null ? null : ll.LatLng(_lat!, _lng!),
              onTap: () => Navigator.pushNamed(context, AppRoutes.liveMap),
            ),
          ),
        ),
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(AppSpacing.lg, AppSpacing.xl, AppSpacing.lg, 0),
          sliver: SliverToBoxAdapter(
            child: Text(
              tr('home.contributions'),
              style: textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
            ),
          ),
        ),
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(AppSpacing.lg, AppSpacing.md, AppSpacing.lg, 0),
          sliver: SliverToBoxAdapter(
            child: _ContributionsRow(
              loading: _loadingTrust,
              totalReports: _totalReports,
              trustScore: _trustScore,
              onTap: () => _showContributeSheet(context),
            ),
          ),
        ),
        const SliverToBoxAdapter(child: SizedBox(height: AppSpacing.xxl)),
      ],
    );
  }

  Widget _recommendedRail(BuildContext context) {
    if (_loadingRecommended) {
      return const SizedBox(
        height: 246,
        child: Center(child: CircularProgressIndicator()),
      );
    }
    if (_recommendedError != null) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(AppSpacing.lg, AppSpacing.lg, AppSpacing.lg, 0),
        child: Text(_recommendedError!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
      );
    }
    if (_recommended.isEmpty) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(AppSpacing.lg, AppSpacing.lg, AppSpacing.lg, 0),
        child: Text(
          'Browse a few shops and recommendations will appear here.',
          style: TextStyle(color: context.appColors.textSecondary),
        ),
      );
    }
    // A carousel rather than a row: these are a handful of suggestions to
    // look at one at a time, not a list to scan. It brings each one to the
    // front in turn, so a recommendation further down the ranking is seen
    // without anyone having to swipe for it -- and a drag still works for
    // anyone who wants to go back to one.
    return CoverflowCarousel(
      itemCount: _recommended.length,
      itemBuilder: (context, index) {
        final shop = _recommended[index];
        return ShopPreviewCard(
          shop: shop,
          categoryIconFor: categoryIcon(shop.category),
          categoryTint: categoryColors(context, shop.category),
        );
      },
    );
  }

  Widget _staffNavBar(BuildContext context) {
    return NavigationBar(
      selectedIndex: 0,
      onDestinationSelected: (index) {
        if (index == 1) _showAccountSheet(context);
      },
      destinations: [
        NavigationDestination(icon: Icon(Icons.home_outlined), label: tr('nav.home')),
        NavigationDestination(icon: Icon(Icons.account_circle_outlined), label: tr('nav.account')),
      ],
    );
  }

  Widget _exploreNavBar(BuildContext context) {
    return NavigationBar(
      selectedIndex: 0,
      onDestinationSelected: (index) {
        switch (index) {
          case 0:
            break;
          case 1:
            Navigator.pushNamed(context, AppRoutes.liveMap);
            break;
          case 2:
            Navigator.pushNamed(context, AppRoutes.shopList);
            break;
          case 3:
            _showAccountSheet(context);
            break;
        }
      },
      destinations: [
        NavigationDestination(icon: Icon(Icons.home_outlined), label: tr('nav.home')),
        NavigationDestination(icon: Icon(Icons.map_outlined), label: tr('nav.map')),
        NavigationDestination(icon: Icon(Icons.search), label: tr('nav.search')),
        NavigationDestination(icon: Icon(Icons.person_outline), label: tr('nav.profile')),
      ],
    );
  }

  void _showContributeSheet(BuildContext context) {
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
              Text(
                'Contribute',
                style: Theme.of(sheetContext)
                    .textTheme
                    .titleMedium
                    ?.copyWith(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: AppSpacing.sm),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.add_business_outlined),
                title: const Text('Suggest a New Shop'),
                subtitle: const Text('Help grow the MicroLink map'),
                onTap: () {
                  Navigator.pop(sheetContext);
                  Navigator.pushNamed(context, AppRoutes.addNewShop);
                },
              ),
              if (_canConfirmShops)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.how_to_reg_outlined),
                  title: const Text('Confirm Shops Near You'),
                  subtitle: const Text('Say whether reported shops are really there'),
                  onTap: () {
                    Navigator.pop(sheetContext);
                    Navigator.pushNamed(context, AppRoutes.confirmShops);
                  },
                ),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.report_gmailerrorred_outlined),
                title: const Text('Report an Issue'),
                subtitle: const Text('Flag a road or delivery problem'),
                onTap: () {
                  Navigator.pop(sheetContext);
                  Navigator.pushNamed(context, AppRoutes.reportRoadIssue);
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Picks an image and uploads it as the profile photo, replacing any
  /// previous one.
  ///
  /// Nothing is stored locally: the avatar everywhere in the app watches
  /// [ProfilePhotoService], so it updates on its own once this finishes.
  Future<void> _changeProfilePhoto(BuildContext sheetContext) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final picked = await MultipartUpload.pick();
      // They opened the file picker and closed it again.
      if (picked == null) return;
      await ProfilePhotoService.instance.upload(picked);
      messenger.showSnackBar(
        const SnackBar(content: Text('Profile photo updated.')),
      );
    } on ApiException catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  void _showAccountSheet(BuildContext context) {
    final session = SessionManager.instance;
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.85),
      builder: (sheetContext) {
        return SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(AppSpacing.lg, 0, AppSpacing.lg, AppSpacing.lg),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    // Tapping the avatar changes the photo -- the same place
                    // people look for it on every other app.
                    InkWell(
                      customBorder: const CircleBorder(),
                      onTap: () => _changeProfilePhoto(sheetContext),
                      child: Stack(
                        alignment: Alignment.bottomRight,
                        children: [
                          const ProfileAvatar(radius: 24),
                          // A small camera badge, so it is visible that the
                          // avatar does something rather than just being a
                          // picture of you.
                          Container(
                            padding: const EdgeInsets.all(3),
                            decoration: BoxDecoration(
                              color: Theme.of(sheetContext).colorScheme.primary,
                              shape: BoxShape.circle,
                              border: Border.all(
                                color: Theme.of(sheetContext).colorScheme.surface,
                                width: 1.5,
                              ),
                            ),
                            child: Icon(
                              Icons.photo_camera_outlined,
                              size: 11,
                              color: Theme.of(sheetContext).colorScheme.onPrimary,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: AppSpacing.md),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            session.userName ?? 'MicroLink User',
                            style: Theme.of(sheetContext)
                                .textTheme
                                .titleMedium
                                ?.copyWith(fontWeight: FontWeight.w600),
                          ),
                          Text(
                            formatRoleLabel(session.userRole ?? roleUser),
                            style: Theme.of(sheetContext)
                                .textTheme
                                .bodyMedium
                                ?.copyWith(color: sheetContext.appColors.textSecondary),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: AppSpacing.lg),
                const Divider(),
                const SizedBox(height: AppSpacing.sm),
                AnimatedBuilder(
                  animation: ThemeController.instance,
                  builder: (context, _) {
                    final isDark = Theme.of(sheetContext).brightness == Brightness.dark;
                    return SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      secondary: Icon(isDark ? Icons.dark_mode_outlined : Icons.light_mode_outlined),
                      title: const Text('Dark mode'),
                      value: isDark,
                      onChanged: (_) => ThemeController.instance.toggle(Theme.of(sheetContext).brightness),
                    );
                  },
                ),
                const SizedBox(height: AppSpacing.sm),
                NotificationBell(
                  asListTile: true,
                  onBeforeOpen: () => Navigator.pop(sheetContext),
                ),
                if (!session.isAdmin) ...[
                  _SheetActionTile(
                    icon: Icons.receipt_long_outlined,
                    label: 'My Orders',
                    onTap: () {
                      Navigator.pop(sheetContext);
                      Navigator.pushNamed(context, AppRoutes.myOrders);
                    },
                  ),
                  _SheetActionTile(
                    icon: Icons.favorite_border,
                    label: 'My Favorites',
                    onTap: () {
                      Navigator.pop(sheetContext);
                      Navigator.pushNamed(context, AppRoutes.myFavorites);
                    },
                  ),
                  if (session.isCustomer)
                    _SheetActionTile(
                      icon: Icons.tune,
                      label: 'My Interests',
                      onTap: () async {
                        Navigator.pop(sheetContext);
                        final changed = await Navigator.pushNamed(context, AppRoutes.interests);
                        // Re-rank the home rail against the new preferences.
                        if (changed == true) _fetchRecommended();
                      },
                    ),
                  _SheetActionTile(
                    icon: Icons.add_business_outlined,
                    label: 'Suggest a New Shop',
                    onTap: () {
                      Navigator.pop(sheetContext);
                      Navigator.pushNamed(context, AppRoutes.addNewShop);
                    },
                  ),
                  if (_canConfirmShops)
                    _SheetActionTile(
                      icon: Icons.how_to_reg_outlined,
                      label: 'Confirm Shops Near You',
                      onTap: () {
                        Navigator.pop(sheetContext);
                        Navigator.pushNamed(context, AppRoutes.confirmShops);
                      },
                    ),
                  _SheetActionTile(
                    icon: Icons.report_gmailerrorred_outlined,
                    label: 'Report an Issue',
                    onTap: () {
                      Navigator.pop(sheetContext);
                      Navigator.pushNamed(context, AppRoutes.reportRoadIssue);
                    },
                  ),
                ],
                if (session.isShopOwner)
                  _SheetActionTile(
                    icon: Icons.campaign_outlined,
                    label: 'Promote My Shop',
                    onTap: () {
                      Navigator.pop(sheetContext);
                      Navigator.pushNamed(context, AppRoutes.submitAd);
                    },
                  ),
                // Documents belong here rather than in the bottom bar: they
                // are set up once and then only revisited if an admin asks
                // for something, which is not what a top-level destination
                // is for. Shop owners need them too and had no way in at all.
                if (session.isDeliveryAgent || session.isShopOwner)
                  _SheetActionTile(
                    icon: Icons.verified_user_outlined,
                    label: 'Verification Documents',
                    onTap: () {
                      Navigator.pop(sheetContext);
                      Navigator.pushNamed(context, AppRoutes.verificationDocuments);
                    },
                  ),
                _SheetActionTile(
                  icon: Icons.settings_outlined,
                  label: 'Settings',
                  onTap: () {
                    Navigator.pop(sheetContext);
                    Navigator.pushNamed(context, AppRoutes.settings);
                  },
                ),
                _SheetActionTile(
                  icon: Icons.logout,
                  label: 'Log Out',
                  tint: Theme.of(sheetContext).colorScheme.error,
                  onTap: () async {
                    Navigator.pop(sheetContext);
                    await SessionManager.instance.clearSession();
                    // Otherwise the next person to sign in on this device
                    // sees the last one's face until their own photo loads.
                    ProfilePhotoService.instance.clear();
                    if (!context.mounted) return;
                    Navigator.pushNamedAndRemoveUntil(context, AppRoutes.login, (route) => false);
                  },
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// One row in the Profile sheet: an icon in a tinted rounded box (the same
/// "highlight" treatment Home's own list tiles use elsewhere), a label, and
/// a trailing chevron. [tint] overrides both the icon-box color and label
/// color for a distinct action like "Log Out".
class _SheetActionTile extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final Color? tint;

  const _SheetActionTile({required this.icon, required this.label, required this.onTap, this.tint});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final iconColor = tint ?? colorScheme.primary;
    final iconBackground = tint != null ? tint!.withValues(alpha: 0.12) : colorScheme.primaryContainer;
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(color: iconBackground, borderRadius: BorderRadius.circular(AppRadius.input)),
        alignment: Alignment.center,
        child: Icon(icon, color: iconColor, size: 20),
      ),
      title: Text(
        label,
        style: Theme.of(context).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600, color: tint),
      ),
      trailing: Icon(Icons.chevron_right, size: 18, color: colorScheme.outline),
      onTap: onTap,
    );
  }
}

/// A round, white, softly-shadowed icon button used for the header actions
/// (theme toggle, notifications).
class _CircleIconButton extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;

  const _CircleIconButton({required this.icon, required this.tooltip, required this.onPressed});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Material(
      color: colorScheme.surface,
      shape: const CircleBorder(),
      elevation: 1,
      shadowColor: colorScheme.shadow.withValues(alpha: 0.2),
      child: IconButton(
        icon: Icon(icon, color: colorScheme.onSurface),
        tooltip: tooltip,
        onPressed: onPressed,
      ),
    );
  }
}

/// The pill-shaped search field on the Explore home -- a shortcut into the
/// full Discover Shops screen (which owns the real search/filter state)
/// rather than duplicating that logic here.
class _SearchBar extends StatelessWidget {
  final VoidCallback onTap;

  const _SearchBar({required this.onTap});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Material(
      color: colorScheme.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(AppRadius.pill),
      child: InkWell(
        borderRadius: BorderRadius.circular(AppRadius.pill),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg, vertical: AppSpacing.md),
          child: Row(
            children: [
              Icon(Icons.search, color: context.appColors.textSecondary),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: Text(
                  tr('home.search_hint'),
                  style: TextStyle(color: context.appColors.textSecondary),
                ),
              ),
              Icon(Icons.tune, color: context.appColors.textSecondary, size: 20),
            ],
          ),
        ),
      ),
    );
  }
}

/// One card in the horizontal "Recommended for You" rail: real category
/// image area, real Open/Closed status, real rating, real distance --
/// nothing fabricated (no "trust score" or "AI ETA" fields exist on [Shop]).
/// A single sponsor banner card. Tapping it opens the advertised shop's
/// detail page when the ad is tied to a real shop; ads for an outside
/// company with no `shop_id` are display-only (there's nowhere in the app
/// to send that tap).
/// One circular category icon + label in Home's quick-nav row -- a shortcut
/// straight into Discover Shops pre-filtered to that category, using the
/// real `shopCategories` list (not an invented, unrelated set of labels).
class _CategoryQuickNavItem extends StatelessWidget {
  final String category;
  final VoidCallback onTap;

  const _CategoryQuickNavItem({required this.category, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final tint = categoryColors(context, category);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppRadius.pill),
      child: SizedBox(
        width: 68,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 52,
              height: 52,
              decoration: BoxDecoration(color: tint.background, shape: BoxShape.circle),
              child: Icon(categoryIcon(category), color: tint.foreground),
            ),
            const SizedBox(height: 6),
            Text(
              formatCategoryLabel(category),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.labelSmall?.copyWith(fontWeight: FontWeight.w600),
            ),
          ],
        ),
      ),
    );
  }
}

/// An auto-advancing carousel for the Sponsored rail -- one banner at a
/// time, sliding to the next every few seconds (looping back to the start),
/// with dot indicators showing position. Still fully swipeable by hand;
/// a manual swipe just moves [_page] and the timer picks up from there.
class _SponsoredCarousel extends StatefulWidget {
  final List<Ad> ads;

  const _SponsoredCarousel({required this.ads});

  @override
  State<_SponsoredCarousel> createState() => _SponsoredCarouselState();
}

class _SponsoredCarouselState extends State<_SponsoredCarousel> {
  late final PageController _controller = PageController();
  Timer? _timer;
  int _page = 0;

  @override
  void initState() {
    super.initState();
    if (widget.ads.length > 1) {
      _timer = Timer.periodic(const Duration(seconds: 4), (_) {
        if (!mounted) return;
        final next = (_page + 1) % widget.ads.length;
        _controller.animateToPage(
          next,
          duration: const Duration(milliseconds: 450),
          curve: Curves.easeInOutCubic,
        );
      });
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        SizedBox(
          height: 132,
          child: PageView.builder(
            controller: _controller,
            itemCount: widget.ads.length,
            onPageChanged: (index) => setState(() => _page = index),
            itemBuilder: (context, index) => Padding(
              padding: const EdgeInsets.symmetric(horizontal: 2),
              child: _AdBannerCard(ad: widget.ads[index]),
            ),
          ),
        ),
        if (widget.ads.length > 1) ...[
          const SizedBox(height: AppSpacing.sm),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: List.generate(widget.ads.length, (index) {
              final active = index == _page;
              return AnimatedContainer(
                duration: const Duration(milliseconds: 250),
                margin: const EdgeInsets.symmetric(horizontal: 3),
                width: active ? 18 : 6,
                height: 6,
                decoration: BoxDecoration(
                  color: active
                      ? Theme.of(context).colorScheme.primary
                      : Theme.of(context).colorScheme.outlineVariant,
                  borderRadius: BorderRadius.circular(AppRadius.pill),
                ),
              );
            }),
          ),
        ],
      ],
    );
  }
}

class _AdBannerCard extends StatelessWidget {
  final Ad ad;

  const _AdBannerCard({required this.ad});

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Material(
        color: Theme.of(context).colorScheme.surface,
        elevation: 1,
        borderRadius: BorderRadius.circular(AppRadius.card),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: ad.shopId == null
              ? null
              : () => Navigator.pushNamed(
                    context,
                    AppRoutes.shopDetail,
                    arguments: ShopDetailArgs(ad.shopId!),
                  ),
          child: Row(
            children: [
              SizedBox(
                width: 100,
                height: 132,
                child: Image.network(
                  mediaUrl(ad.imageUrl) ?? ad.imageUrl,
                  fit: BoxFit.cover,
                  errorBuilder: (context, error, stackTrace) => Container(
                    color: Theme.of(context).colorScheme.surfaceContainerHighest,
                    alignment: Alignment.center,
                    child: Icon(Icons.campaign_outlined, color: Theme.of(context).colorScheme.outline),
                  ),
                ),
              ),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.all(AppSpacing.md),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        ad.advertiserName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: textTheme.labelSmall?.copyWith(
                          color: context.appColors.textSecondary,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0.4,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        ad.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
                      ),
                      if (ad.subtitle.isNotEmpty) ...[
                        const SizedBox(height: 4),
                        Text(
                          ad.subtitle,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: textTheme.bodySmall?.copyWith(color: context.appColors.textSecondary),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      );
  }
}

/// A real mini map of the shops around the user, linking to the full Live
/// Map.
///
/// This used to be a hand-painted fake street grid with a live count
/// overlaid, which looked like a map but told the user nothing about where
/// anything actually was. It now renders the same tiles and the same
/// category pins as the Live Map, just frozen: all gestures are off so a
/// scroll of the home feed never gets captured by the map, and tapping
/// anywhere opens the real thing.
class _NearbyMapCard extends StatelessWidget {
  final bool loading;
  final int? count;
  final List<Shop> shops;
  final bool nationwide;
  final ll.LatLng? centre;
  final VoidCallback onTap;

  const _NearbyMapCard({
    required this.loading,
    required this.count,
    required this.shops,
    required this.nationwide,
    required this.centre,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final me = centre;
    final label = loading
        ? 'Finding shops near you…'
        : nationwide
            // Honest: these are the closest we have, not shops near you.
            ? '${shops.length} shop${shops.length == 1 ? '' : 's'} elsewhere in Sri Lanka'
            : count != null
                ? '$count shop${count == 1 ? '' : 's'} within 10 km'
                : "Enable location to see what's nearby";

    return Material(
      color: colorScheme.surface,
      elevation: 1,
      borderRadius: BorderRadius.circular(AppRadius.card),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: SizedBox(
          height: 180,
          child: Stack(
            children: [
              Positioned.fill(
                  // Swallows gestures so the map cannot steal a vertical
                  // scroll from the home feed behind it.
                  child: IgnorePointer(
                    child: FlutterMap(
                      options: MapOptions(
                        // No GPS fix yet: still show a map of the country's
                        // default area rather than a blank grey panel. The
                        // caption below says location is off, so the user is
                        // not misled into thinking these are near them.
                        initialCenter: centre ?? kFallbackCenter,
                        initialZoom: (centre == null || nationwide) ? 8 : 13,
                        interactionOptions: const InteractionOptions(
                          flags: InteractiveFlag.none,
                        ),
                      ),
                      children: [
                        const MapTileLayer(),
                        MarkerLayer(
                          markers: [
                            // Capped: a dense town would otherwise stack
                            // dozens of pins into an unreadable blob at
                            // this size.
                            for (final shop in shops.take(12))
                              Marker(
                                point: ll.LatLng(shop.latitude, shop.longitude),
                                width: 32,
                                height: 40,
                                alignment: Alignment.topCenter,
                                child: MapPin.forCategory(
                                  context,
                                  shop.category,
                                  muted: !shop.isOpen,
                                ),
                              ),
                            if (me != null)
                              Marker(
                                point: me,
                                width: 24,
                                height: 24,
                                child: const MyLocationDot(),
                              ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              Positioned(
                left: AppSpacing.md,
                right: AppSpacing.md,
                bottom: AppSpacing.md,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: AppSpacing.md,
                    vertical: AppSpacing.sm,
                  ),
                  decoration: BoxDecoration(
                    color: colorScheme.surface.withValues(alpha: 0.92),
                    borderRadius: BorderRadius.circular(AppRadius.card),
                    boxShadow: [
                      BoxShadow(color: Colors.black.withValues(alpha: 0.12), blurRadius: 10),
                    ],
                  ),
                  child: Row(
                    children: [
                      Container(
                        width: 8,
                        height: 8,
                        margin: const EdgeInsets.only(right: 8),
                        decoration: BoxDecoration(
                          color: context.appColors.success,
                          shape: BoxShape.circle,
                        ),
                      ),
                      Expanded(
                        child: Text(
                          label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: textTheme.labelMedium?.copyWith(fontWeight: FontWeight.w700),
                        ),
                      ),
                      Icon(Icons.chevron_right, color: colorScheme.outline, size: 18),
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


/// The "Your Contributions" row: two cards backed by the real, per-user
/// `/crowdsource/trust-score/me` endpoint -- there's no cross-user
/// "community" aggregate a regular user can query, so this is honestly
/// scoped to the signed-in user rather than claiming a neighborhood-wide
/// figure.
class _ContributionsRow extends StatelessWidget {
  final bool loading;
  final int? totalReports;
  final double? trustScore;
  final VoidCallback onTap;

  const _ContributionsRow({
    required this.loading,
    required this.totalReports,
    required this.trustScore,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return Row(
      children: [
        Expanded(
          child: Material(
            color: colorScheme.surface,
            elevation: 1,
            borderRadius: BorderRadius.circular(AppRadius.card),
            child: InkWell(
              borderRadius: BorderRadius.circular(AppRadius.card),
              onTap: onTap,
              child: Padding(
                padding: const EdgeInsets.all(AppSpacing.md),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.volunteer_activism_outlined, color: context.appColors.success),
                    const SizedBox(height: AppSpacing.sm),
                    Text(
                      loading ? '—' : '${totalReports ?? 0}',
                      style: textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w800),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'Reports you\'ve submitted',
                      style: textTheme.bodySmall?.copyWith(color: context.appColors.textSecondary),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
        const SizedBox(width: AppSpacing.md),
        Expanded(
          child: Material(
            color: colorScheme.primary,
            elevation: 1,
            borderRadius: BorderRadius.circular(AppRadius.card),
            child: InkWell(
              borderRadius: BorderRadius.circular(AppRadius.card),
              onTap: onTap,
              child: Padding(
                padding: const EdgeInsets.all(AppSpacing.md),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.stars_outlined, color: colorScheme.onPrimary),
                    const SizedBox(height: AppSpacing.sm),
                    Text(
                      loading ? '—' : (trustScore ?? 0).toStringAsFixed(0),
                      style: textTheme.headlineSmall
                          ?.copyWith(fontWeight: FontWeight.w800, color: colorScheme.onPrimary),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'Your trust score',
                      style: textTheme.bodySmall?.copyWith(color: colorScheme.onPrimary.withValues(alpha: 0.85)),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// One shortcut on a staff home: an icon, a title, a one-line description and
/// the named route it opens.
class _StaffAction {
  final IconData icon;
  final String title;
  final String subtitle;
  final String route;

  const _StaffAction({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.route,
  });
}

/// The shared home body for every non-customer role (shop owner, delivery
/// agent, admin): a greeting header with theme/account buttons, then a plain
/// list of [_StaffAction] shortcut cards into that role's tools. No shopping
/// rails -- those roles don't shop from here.
class _StaffHomeBody extends StatelessWidget {
  final void Function(BuildContext) onOpenAccount;
  final List<_StaffAction> actions;

  const _StaffHomeBody({required this.onOpenAccount, required this.actions});

  @override
  Widget build(BuildContext context) {
    final session = SessionManager.instance;
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return CustomScrollView(
      slivers: [
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(AppSpacing.lg, AppSpacing.sm, AppSpacing.lg, 0),
          sliver: SliverToBoxAdapter(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _greeting(),
                        style: textTheme.bodyMedium?.copyWith(color: context.appColors.textSecondary),
                      ),
                      const SizedBox(height: AppSpacing.xs),
                      Text(
                        '${tr('home.greeting')}, ${session.userName ?? ''}',
                        style: textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w800),
                      ),
                      Text(
                        formatRoleLabel(session.userRole ?? roleUser),
                        style: textTheme.bodySmall?.copyWith(color: context.appColors.textSecondary),
                      ),
                    ],
                  ),
                ),
                const NotificationBell(),
                const SizedBox(width: AppSpacing.sm),
                _CircleIconButton(
                  icon: Theme.of(context).brightness == Brightness.dark
                      ? Icons.light_mode_outlined
                      : Icons.dark_mode_outlined,
                  tooltip: 'Switch to '
                      '${Theme.of(context).brightness == Brightness.dark ? 'light' : 'dark'} mode',
                  onPressed: () => ThemeController.instance.toggle(Theme.of(context).brightness),
                ),
                const SizedBox(width: AppSpacing.sm),
                _CircleIconButton(
                  icon: Icons.account_circle_outlined,
                  tooltip: 'Account',
                  onPressed: () => onOpenAccount(context),
                ),
              ],
            ),
          ),
        ),
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(AppSpacing.lg, AppSpacing.lg, AppSpacing.lg, 0),
          sliver: SliverList.separated(
            itemCount: actions.length,
            separatorBuilder: (_, _) => const SizedBox(height: AppSpacing.md),
            itemBuilder: (context, index) {
              final action = actions[index];
              return Material(
                color: colorScheme.surface,
                elevation: 1,
                borderRadius: BorderRadius.circular(AppRadius.card),
                child: InkWell(
                  borderRadius: BorderRadius.circular(AppRadius.card),
                  onTap: () => Navigator.pushNamed(context, action.route),
                  child: Padding(
                    padding: const EdgeInsets.all(AppSpacing.lg),
                    child: Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.all(AppSpacing.sm),
                          decoration: BoxDecoration(
                            color: colorScheme.primaryContainer,
                            borderRadius: BorderRadius.circular(AppRadius.input),
                          ),
                          child: Icon(action.icon, color: colorScheme.primary),
                        ),
                        const SizedBox(width: AppSpacing.md),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                action.title,
                                style: textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
                              ),
                              const SizedBox(height: AppSpacing.xs),
                              Text(
                                action.subtitle,
                                style: textTheme.bodySmall?.copyWith(color: context.appColors.textSecondary),
                              ),
                            ],
                          ),
                        ),
                        Icon(Icons.chevron_right, color: colorScheme.outline),
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  String _greeting() {
    final hour = DateTime.now().hour;
    if (hour < 12) return 'Good morning';
    if (hour < 17) return 'Good afternoon';
    return 'Good evening';
  }
}
