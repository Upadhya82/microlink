import 'dart:async';

import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';

import '../../../core/constants/app_constants.dart';
import '../../../core/models/ad.dart';
import '../../../core/models/shop.dart';
import '../../../core/models/user.dart';
import '../../../core/network/api_client.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/network/session_manager.dart';
import '../../../core/theme/app_colors_extension.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/theme_controller.dart';
import '../../../core/utils/app_router.dart' show ShopDetailArgs, ShopListArgs;
import '../../../core/utils/category_style.dart';
import '../../../core/widgets/fade_in.dart';
import '../../../core/widgets/shop_preview_card.dart';
import '../../shop_owner/screens/shop_owner_dashboard_screen.dart';

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
  List<Shop> _nearbyShops = const [];

  @override
  void initState() {
    super.initState();
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
    ]);
  }

  /// The "Nearby Shops" rail: plain distance-sorted `/shops`, distinct from
  /// the personalized "Recommended for You" rail above it (which comes from
  /// recommendation-service's interaction-boosted ranking instead). Hidden
  /// entirely without a resolved location, since "nearby" has no meaning
  /// otherwise.
  Future<void> _fetchNearbyShops() async {
    if (_lat == null || _lng == null) {
      setState(() => _loadingNearbyShops = false);
      return;
    }
    try {
      final response = await ApiClient.instance.get(
        '/shops',
        query: {'lat': _lat, 'lng': _lng, 'limit': 10},
      );
      final shops = (response as List).map((e) => Shop.fromJson(e as Map<String, dynamic>)).toList();
      if (!mounted) return;
      setState(() {
        _nearbyShops = shops;
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
  Future<void> _fetchTrustScore() async {
    try {
      final response = await ApiClient.instance.get('/crowdsource/trust-score/me');
      final data = response as Map<String, dynamic>;
      if (!mounted) return;
      setState(() {
        _trustScore = (data['score'] as num).toDouble();
        _totalReports = data['total_reports'] as int;
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
          await ApiClient.instance.get('/shops', query: {'lat': _lat, 'lng': _lng});
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
        ],
      );
    }
    if (session.isShopOwner) {
      // The shop owner's home *is* their dashboard -- status, products, alerts
      // and analytics for their shop, not a menu of links to it.
      return ShopOwnerDashboardScreen(onOpenAccount: _showAccountSheet);
    }
    if (session.isDeliveryAgent) {
      return _StaffHomeBody(
        onOpenAccount: _showAccountSheet,
        actions: const [
          _StaffAction(
            icon: Icons.two_wheeler_outlined,
            title: 'Driver Home',
            subtitle: 'Availability, nearby jobs & performance',
            route: AppRoutes.driverHome,
          ),
          _StaffAction(
            icon: Icons.receipt_long_outlined,
            title: 'My Deliveries',
            subtitle: 'Assigned and past deliveries',
            route: AppRoutes.myOrders,
          ),
        ],
      );
    }
    return null;
  }

  Widget _buildExploreHome(BuildContext context) {
    final session = SessionManager.instance;
    final textTheme = Theme.of(context).textTheme;

    return CustomScrollView(
      slivers: [
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(AppSpacing.lg, AppSpacing.sm, AppSpacing.lg, 0),
          sliver: SliverToBoxAdapter(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                InkWell(
                  customBorder: const CircleBorder(),
                  onTap: () => _showAccountSheet(context),
                  child: CircleAvatar(
                    radius: 22,
                    backgroundColor: Theme.of(context).colorScheme.primaryContainer,
                    child: Icon(Icons.person_outline, color: Theme.of(context).colorScheme.primary),
                  ),
                ),
                const SizedBox(width: AppSpacing.md),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Hi, ${session.userName ?? 'there'}',
                        style: textTheme.bodyMedium?.copyWith(color: context.appColors.textSecondary),
                      ),
                      Text(
                        'Explore',
                        style: textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w800),
                      ),
                    ],
                  ),
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
                          'Recommended for You',
                          style: textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          'Personalised from what you browse, favourite & prefer',
                          style: textTheme.bodySmall?.copyWith(color: context.appColors.textSecondary),
                        ),
                      ],
                    ),
                  ),
                  TextButton(
                    onPressed: () => Navigator.pushNamed(context, AppRoutes.recommendedShops),
                    child: const Text('See all'),
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
                  Text('Nearby Shops', style: textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
                  TextButton(
                    onPressed: () => Navigator.pushNamed(context, AppRoutes.shopList),
                    child: const Text('View All'),
                  ),
                ],
              ),
            ),
          ),
          SliverToBoxAdapter(
            child: SizedBox(
              height: 246,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg, vertical: AppSpacing.md),
                itemCount: _nearbyShops.length,
                separatorBuilder: (_, _) => const SizedBox(width: AppSpacing.md),
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
                Text('Nearby Supply', style: textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
                TextButton(
                  onPressed: () => Navigator.pushNamed(context, AppRoutes.liveMap),
                  child: const Text('View Map'),
                ),
              ],
            ),
          ),
        ),
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(AppSpacing.lg, AppSpacing.md, AppSpacing.lg, 0),
          sliver: SliverToBoxAdapter(
            child: _NearbyMapCard(
              loading: _loadingNearby,
              count: _nearbyCount,
              onTap: () => Navigator.pushNamed(context, AppRoutes.liveMap),
            ),
          ),
        ),
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(AppSpacing.lg, AppSpacing.xl, AppSpacing.lg, 0),
          sliver: SliverToBoxAdapter(
            child: Text(
              'Your Contributions',
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
    return SizedBox(
      height: 246,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg, vertical: AppSpacing.md),
        itemCount: _recommended.length,
        separatorBuilder: (_, _) => const SizedBox(width: AppSpacing.md),
        itemBuilder: (context, index) {
          final shop = _recommended[index];
          return ShopPreviewCard(
            shop: shop,
            categoryIconFor: categoryIcon(shop.category),
            categoryTint: categoryColors(context, shop.category),
          );
        },
      ),
    );
  }

  Widget _staffNavBar(BuildContext context) {
    return NavigationBar(
      selectedIndex: 0,
      onDestinationSelected: (index) {
        if (index == 1) _showAccountSheet(context);
      },
      destinations: const [
        NavigationDestination(icon: Icon(Icons.home_outlined), label: 'Home'),
        NavigationDestination(icon: Icon(Icons.account_circle_outlined), label: 'Account'),
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
      destinations: const [
        NavigationDestination(icon: Icon(Icons.home_outlined), label: 'Home'),
        NavigationDestination(icon: Icon(Icons.map_outlined), label: 'Map'),
        NavigationDestination(icon: Icon(Icons.search), label: 'Search'),
        NavigationDestination(icon: Icon(Icons.person_outline), label: 'Profile'),
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
                    CircleAvatar(
                      radius: 24,
                      backgroundColor: Theme.of(sheetContext).colorScheme.primaryContainer,
                      child: Icon(
                        Icons.person_outline,
                        color: Theme.of(sheetContext).colorScheme.primary,
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
                if (session.isDeliveryAgent)
                  _SheetActionTile(
                    icon: Icons.two_wheeler_outlined,
                    label: 'Driver Home',
                    onTap: () {
                      Navigator.pop(sheetContext);
                      Navigator.pushNamed(context, AppRoutes.driverHome);
                    },
                  ),
                _SheetActionTile(
                  icon: Icons.logout,
                  label: 'Log Out',
                  tint: Theme.of(sheetContext).colorScheme.error,
                  onTap: () async {
                    Navigator.pop(sheetContext);
                    await SessionManager.instance.clearSession();
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
                  'Search shops or essential items...',
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
                  ad.imageUrl,
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

/// The "Nearby Supply" teaser card linking to the real Live Map. The map
/// backdrop is illustrative (flutter_map needs real tiles/markers, which
/// don't render inside a small static preview), but the overlaid count is
/// live: shop-service's actual radius-filtered `/shops` response for the
/// resolved location, not a scripted "N shops restocked" claim.
class _NearbyMapCard extends StatelessWidget {
  final bool loading;
  final int? count;
  final VoidCallback onTap;

  const _NearbyMapCard({required this.loading, required this.count, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final label = loading
        ? 'Finding shops near you…'
        : count != null
            ? '$count shop${count == 1 ? '' : 's'} within 10 km'
            : 'Enable location to see what\'s nearby';

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
                child: CustomPaint(painter: _MiniMapPainter(Theme.of(context).brightness)),
              ),
              Center(
                child: Icon(Icons.location_on, color: colorScheme.primary, size: 36),
              ),
              Positioned(
                left: AppSpacing.md,
                right: AppSpacing.md,
                bottom: AppSpacing.md,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md, vertical: AppSpacing.sm),
                  decoration: BoxDecoration(
                    color: colorScheme.surface.withValues(alpha: 0.92),
                    borderRadius: BorderRadius.circular(AppRadius.card),
                    boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.12), blurRadius: 10)],
                  ),
                  child: Row(
                    children: [
                      Container(
                        width: 8,
                        height: 8,
                        margin: const EdgeInsets.only(right: 8),
                        decoration: BoxDecoration(color: context.appColors.success, shape: BoxShape.circle),
                      ),
                      Expanded(
                        child: Text(
                          label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: textTheme.labelMedium?.copyWith(fontWeight: FontWeight.w700),
                        ),
                      ),
                      Icon(Icons.notifications_none, color: colorScheme.outline, size: 18),
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

/// A stylized street-grid pattern for the Nearby card's backdrop --
/// decorative only, not a real map (the real one is flutter_map on the Live
/// Map screen this card links to).
class _MiniMapPainter extends CustomPainter {
  final Brightness brightness;

  const _MiniMapPainter(this.brightness);

  @override
  void paint(Canvas canvas, Size size) {
    final isDark = brightness == Brightness.dark;
    final bg = isDark ? const Color(0xFF16324A) : const Color(0xFFEAF3EE);
    final block = isDark ? const Color(0xFF1D4467) : const Color(0xFFDDE9E1);
    final road = isDark ? const Color(0xFF0F2438) : const Color(0xFFF6FAF7);
    canvas.drawRect(Offset.zero & size, Paint()..color = bg);

    // A handful of building blocks between the roads, sized/positioned by
    // fraction of the card so it scales with different card widths.
    final blockPaint = Paint()..color = block;
    final blocks = [
      const Rect.fromLTWH(0.06, 0.10, 0.22, 0.28),
      const Rect.fromLTWH(0.34, 0.08, 0.16, 0.18),
      const Rect.fromLTWH(0.60, 0.12, 0.30, 0.24),
      const Rect.fromLTWH(0.08, 0.55, 0.18, 0.30),
      const Rect.fromLTWH(0.62, 0.55, 0.26, 0.32),
      const Rect.fromLTWH(0.34, 0.62, 0.18, 0.22),
    ];
    for (final b in blocks) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(b.left * size.width, b.top * size.height, b.width * size.width,
              b.height * size.height),
          const Radius.circular(3),
        ),
        blockPaint,
      );
    }

    // Straight avenue + cross-street grid, drawn over the blocks.
    final roadPaint = Paint()
      ..color = road
      ..strokeWidth = 10;
    canvas.drawLine(Offset(0, size.height * 0.48), Offset(size.width, size.height * 0.44), roadPaint);
    canvas.drawLine(
      Offset(size.width * 0.5, 0),
      Offset(size.width * 0.46, size.height),
      roadPaint..strokeWidth = 8,
    );
  }

  @override
  bool shouldRepaint(covariant _MiniMapPainter oldDelegate) => oldDelegate.brightness != brightness;
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
                        'Hi, ${session.userName ?? 'there'}',
                        style: textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w800),
                      ),
                      Text(
                        formatRoleLabel(session.userRole ?? roleUser),
                        style: textTheme.bodySmall?.copyWith(color: context.appColors.textSecondary),
                      ),
                    ],
                  ),
                ),
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
