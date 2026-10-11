import 'package:flutter/material.dart';

import '../utils/media_url.dart';
import '../constants/app_constants.dart';
import '../models/shop.dart';
import '../theme/app_colors_extension.dart';
import '../theme/app_spacing.dart';
import '../utils/route_args.dart';
import 'rating_chip.dart';
import 'status_badge.dart';

/// A shop card for horizontal rails (Recommended, Nearby Shops, ...) --
/// shared so every rail on Home renders shops identically instead of each
/// section hand-rolling its own near-duplicate card.
///
/// Everything shown is a real [Shop] field: photo (or a category-tinted
/// fallback), rating, open/closed status, category, and distance when
/// location is available. The one derived value is "New", computed from
/// `createdAt` being within the last 14 days -- there's no separate
/// "popular"/"trending" signal anywhere in shop-service, so that idea from
/// early UI references was left out rather than faked.
class ShopPreviewCard extends StatelessWidget {
  final Shop shop;
  final IconData categoryIconFor;
  final ({Color background, Color foreground}) categoryTint;

  const ShopPreviewCard({
    super.key,
    required this.shop,
    required this.categoryIconFor,
    required this.categoryTint,
  });

  bool get _isNew => DateTime.now().difference(shop.createdAt).inDays <= 14;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return SizedBox(
      width: 190,
      child: Material(
        color: Theme.of(context).colorScheme.surface,
        elevation: 1,
        borderRadius: BorderRadius.circular(AppRadius.card),
        child: InkWell(
          borderRadius: BorderRadius.circular(AppRadius.card),
          onTap: () => Navigator.pushNamed(
            context,
            AppRoutes.shopDetail,
            arguments: ShopDetailArgs(shop.id),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                height: 128,
                child: Stack(
                  children: [
                    ClipRRect(
                      borderRadius: const BorderRadius.vertical(top: Radius.circular(AppRadius.card)),
                      child: shop.imageUrl != null
                          ? Image.network(
                              mediaUrl(shop.imageUrl)!,
                              width: double.infinity,
                              height: 128,
                              fit: BoxFit.cover,
                              errorBuilder: (context, error, stackTrace) => _categoryFallback(),
                            )
                          : _categoryFallback(),
                    ),
                    Positioned(
                      left: 10,
                      top: 10,
                      child: _isNew
                          ? Container(
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                              decoration: BoxDecoration(
                                color: Theme.of(context).colorScheme.secondary,
                                borderRadius: BorderRadius.circular(AppRadius.pill),
                              ),
                              child: Text(
                                'NEW',
                                style: textTheme.labelSmall?.copyWith(
                                  color: Theme.of(context).colorScheme.onSecondary,
                                  fontWeight: FontWeight.w800,
                                  letterSpacing: 0.5,
                                ),
                              ),
                            )
                          : Container(
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                              decoration: BoxDecoration(
                                color: Colors.black.withValues(alpha: 0.6),
                                borderRadius: BorderRadius.circular(AppRadius.pill),
                              ),
                              child: RatingChip(
                                rating: shop.ratingAvg,
                                iconSize: 12,
                                textStyle: textTheme.labelSmall?.copyWith(
                                  color: Colors.white,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.all(AppSpacing.sm),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            shop.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w700),
                          ),
                        ),
                        const SizedBox(width: 4),
                        shop.isOpen ? StatusBadge.open(context) : StatusBadge.closed(context),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Row(
                      children: [
                        Icon(Icons.near_me_outlined, size: 13, color: context.appColors.textSecondary),
                        const SizedBox(width: 4),
                        Expanded(
                          child: Text.rich(
                            TextSpan(
                              children: [
                                TextSpan(
                                  text: '${formatCategoryLabel(shop.category)}: ',
                                  style: textTheme.bodySmall?.copyWith(color: context.appColors.textSecondary),
                                ),
                                TextSpan(
                                  text: shop.distanceKm != null
                                      ? '${shop.distanceKm!.toStringAsFixed(1)} km away'
                                      : shop.address,
                                  style: textTheme.bodySmall?.copyWith(fontWeight: FontWeight.w600),
                                ),
                              ],
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _categoryFallback() {
    return Container(
      color: categoryTint.background,
      alignment: Alignment.center,
      child: Icon(categoryIconFor, color: categoryTint.foreground, size: 32),
    );
  }
}
