import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';

import '../../../core/constants/app_constants.dart';
import '../../../core/models/shop.dart';
import '../../../core/network/api_client.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/theme/app_colors_extension.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/utils/app_router.dart';
import '../../../core/utils/view_state.dart';
import '../../../core/widgets/async_state_view.dart';
import '../../../core/widgets/rating_chip.dart';
import '../../shop_discovery/shop_discovery_support.dart';
import '../../../core/widgets/skeleton_list.dart';
import '../../../core/widgets/branded_app_bar.dart';

/// The Recommended Shops screen: personalized shop suggestions from
/// `GET /recommendations`, swipe-to-dismiss per shop.
class RecommendedShopsScreen extends StatefulWidget {
  const RecommendedShopsScreen({super.key});

  @override
  State<RecommendedShopsScreen> createState() => _RecommendedShopsScreenState();
}

class _RecommendedShopsScreenState extends State<RecommendedShopsScreen> {
  ViewState<List<Shop>> _state = const ViewLoading();
  double? _lat;
  double? _lng;

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  Future<void> _bootstrap() async {
    await _resolveLocation();
    await _fetchRecommendations();
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
      // Location is optional here too -- recommendations still work without it.
    }
  }

  Future<void> _fetchRecommendations() async {
    setState(() => _state = const ViewLoading());
    try {
      final response = await ApiClient.instance.get(
        '/recommendations',
        query: {'lat': _lat, 'lng': _lng},
      );
      final shops = (response as List)
          .map((e) => Shop.fromJson(e as Map<String, dynamic>))
          .toList();
      if (!mounted) return;
      setState(() => _state = ViewData(shops));
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _state = ViewError(e.message));
    } catch (_) {
      if (!mounted) return;
      setState(() => _state = const ViewError('Something went wrong. Please try again.'));
    }
  }

  Future<void> _dismiss(Shop shop) async {
    final current = _state;
    if (current is! ViewData<List<Shop>>) return;

    final index = current.data.indexWhere((s) => s.id == shop.id);
    if (index == -1) return;

    final updated = List<Shop>.from(current.data)..removeAt(index);
    setState(() => _state = ViewData(updated));

    try {
      await ApiClient.instance.post('/recommendations/${shop.id}/dismiss');
    } on ApiException catch (e) {
      if (!mounted) return;
      final restored = List<Shop>.from(updated)..insert(index, shop);
      setState(() => _state = ViewData(restored));
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not dismiss "${shop.name}": ${e.message}')),
      );
    } catch (_) {
      if (!mounted) return;
      final restored = List<Shop>.from(updated)..insert(index, shop);
      setState(() => _state = ViewData(restored));
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not dismiss "${shop.name}". Please try again.')),
      );
    }
  }

  void _openShop(Shop shop) {
    Navigator.pushNamed(context, AppRoutes.shopDetail, arguments: ShopDetailArgs(shop.id));
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.appColors;
    return Scaffold(
      appBar: BrandedAppBar(title: const Text('Recommended For You')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(AppSpacing.lg, 0, AppSpacing.lg, AppSpacing.md),
            child: Text(
              "Picked based on shops you've visited and rated",
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: colors.textSecondary),
            ),
          ),
          Expanded(
            child: RefreshIndicator(
              onRefresh: _fetchRecommendations,
              child: AsyncStateView<List<Shop>>(
                state: _state,
                onRetry: _fetchRecommendations,
                isEmpty: (data) => data.isEmpty,
                emptyTitle: 'No recommendations yet',
                emptyMessage: "Browse some shops and we'll learn what you like.",
                emptyIcon: Icons.recommend_outlined,
                loadingSkeleton: const SkeletonList(itemHeight: 210),
                builder: (context, shops) => ListView.separated(
                  padding: const EdgeInsets.fromLTRB(
                    AppSpacing.lg,
                    0,
                    AppSpacing.lg,
                    AppSpacing.lg,
                  ),
                  itemCount: shops.length,
                  separatorBuilder: (_, _) => const SizedBox(height: AppSpacing.lg),
                  itemBuilder: (context, index) {
                    final shop = shops[index];
                    return Dismissible(
                      key: ValueKey(shop.id),
                      direction: DismissDirection.horizontal,
                      background: _DismissBackground(alignment: Alignment.centerLeft),
                      secondaryBackground: _DismissBackground(alignment: Alignment.centerRight),
                      onDismissed: (_) => _dismiss(shop),
                      child: _RecommendationCard(
                        shop: shop,
                        onTap: () => _openShop(shop),
                      ),
                    );
                  },
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// One recommendation list item: a gradient header band carrying a faded
/// category-icon watermark, then the shop's recommendation reason, name,
/// category/area/distance line, and star rating.
class _RecommendationCard extends StatelessWidget {
  final Shop shop;
  final VoidCallback onTap;

  const _RecommendationCard({required this.shop, required this.onTap});

  ({IconData icon, Color color}) _categoryStyle(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    switch (shop.category) {
      case 'bakery':
        return (icon: Icons.bakery_dining_outlined, color: colorScheme.secondary);
      case 'grocery':
        return (icon: Icons.storefront_outlined, color: colorScheme.primary);
      case 'restaurant':
        return (icon: Icons.restaurant_outlined, color: colorScheme.tertiary);
      case 'pharmacy':
        return (icon: Icons.local_pharmacy_outlined, color: colorScheme.error);
      case 'electronics':
        return (icon: Icons.devices_outlined, color: colorScheme.tertiary);
      case 'clothing':
        return (icon: Icons.checkroom_outlined, color: colorScheme.secondary);
      case 'hardware':
        return (icon: Icons.hardware_outlined, color: colorScheme.primary);
      case 'stationery':
        return (icon: Icons.description_outlined, color: colorScheme.tertiary);
      default:
        return (icon: Icons.storefront_outlined, color: colorScheme.outline);
    }
  }

  Color _darken(Color color, [double amount = 0.16]) {
    final hsl = HSLColor.fromColor(color);
    return hsl.withLightness((hsl.lightness - amount).clamp(0.0, 1.0)).toColor();
  }

  String get _reasonText {
    final reason = shop.reason;
    if (reason == null || reason.trim().isEmpty) return 'Recommended for you';
    return reason;
  }

  String get _subtitle {
    final parts = <String>[
      formatCategoryLabel(shop.category),
      if (shop.address.isNotEmpty) shop.address,
      if (shop.distanceKm != null) '${shop.distanceKm!.toStringAsFixed(1)} km',
    ];
    return parts.join(' · ');
  }

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final style = _categoryStyle(context);

    return Card(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              height: 110,
              width: double.infinity,
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [style.color, _darken(style.color)],
                ),
              ),
              alignment: Alignment.center,
              child: Icon(style.icon, size: 36, color: Colors.white.withValues(alpha: 0.85)),
            ),
            Padding(
              padding: const EdgeInsets.all(AppSpacing.md),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _ReasonPill(text: _reasonText),
                  const SizedBox(height: AppSpacing.sm),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              shop.name,
                              style: textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            const SizedBox(height: 2),
                            Text(
                              _subtitle,
                              style: textTheme.bodySmall?.copyWith(
                                color: context.appColors.textSecondary,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: AppSpacing.sm),
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          RatingChip(rating: shop.ratingAvg),
                          if (shop.showsNotVerifiedChip) ...[
                            const SizedBox(height: 4),
                            const NotVerifiedChip(compact: true),
                          ],
                        ],
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ReasonPill extends StatelessWidget {
  final String text;

  const _ReasonPill({required this.text});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final icon = text.toLowerCase().contains('liked')
        ? Icons.star_rounded
        : Icons.bar_chart_rounded;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm, vertical: 5),
      decoration: BoxDecoration(
        color: colorScheme.secondaryContainer,
        borderRadius: BorderRadius.circular(AppRadius.pill),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: colorScheme.onSecondaryContainer),
          const SizedBox(width: 5),
          Flexible(
            child: Text(
              text,
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: colorScheme.onSecondaryContainer,
                    fontWeight: FontWeight.w700,
                  ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}

class _DismissBackground extends StatelessWidget {
  final Alignment alignment;

  const _DismissBackground({required this.alignment});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      decoration: BoxDecoration(
        color: colorScheme.errorContainer,
        borderRadius: BorderRadius.circular(AppRadius.card),
      ),
      alignment: alignment,
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
      child: Icon(Icons.close, color: colorScheme.onErrorContainer),
    );
  }
}
