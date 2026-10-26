import 'package:flutter/material.dart';

import '../../../core/constants/app_constants.dart';
import '../../../core/models/shop.dart' show formatCategoryLabel;
import '../../../core/models/suggested_shop.dart';
import '../../../core/theme/app_colors_extension.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/utils/category_style.dart';
import '../../../core/utils/media_url.dart';
import '../../../core/utils/route_args.dart';
import '../../crowdsourcing/widgets/suggestion_comments.dart';

/// A card for the "User Suggestions" rail on Home.
///
/// Same size and layout as [ShopPreviewCard], so it sits in the same
/// carousel and the three rails look alike. A suggestion is not a
/// shop-service listing -- there is no detail page to open -- so tapping it
/// shows what the suggestion says, with directions to it.
class SuggestedShopCard extends StatelessWidget {
  final SuggestedShop shop;

  const SuggestedShopCard({super.key, required this.shop});

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final tint = categoryColors(context, shop.category);
    final photo = mediaUrl(shop.photoPath);

    Widget fallback() => Container(
          color: tint.background,
          alignment: Alignment.center,
          child: Icon(categoryIcon(shop.category), color: tint.foreground, size: 32),
        );

    return SizedBox(
      width: 190,
      child: Material(
        color: Theme.of(context).colorScheme.surface,
        elevation: 1,
        borderRadius: BorderRadius.circular(AppRadius.card),
        child: InkWell(
          borderRadius: BorderRadius.circular(AppRadius.card),
          onTap: () => showSuggestedShopSheet(context, shop),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                height: 128,
                child: Stack(
                  children: [
                    ClipRRect(
                      borderRadius: const BorderRadius.vertical(
                        top: Radius.circular(AppRadius.card),
                      ),
                      child: SizedBox(
                        width: double.infinity,
                        height: 128,
                        child: photo != null
                            ? Image.network(
                                photo,
                                fit: BoxFit.cover,
                                errorBuilder: (context, error, stackTrace) => fallback(),
                              )
                            : fallback(),
                      ),
                    ),
                    Positioned(
                      left: 10,
                      top: 10,
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                        decoration: BoxDecoration(
                          color: Theme.of(context).colorScheme.tertiary,
                          borderRadius: BorderRadius.circular(AppRadius.pill),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.people_alt_outlined,
                              size: 12,
                              color: Theme.of(context).colorScheme.onTertiary,
                            ),
                            const SizedBox(width: 4),
                            Text(
                              'SUGGESTED',
                              style: textTheme.labelSmall?.copyWith(
                                color: Theme.of(context).colorScheme.onTertiary,
                                fontWeight: FontWeight.w800,
                                letterSpacing: 0.5,
                              ),
                            ),
                          ],
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
                        Icon(
                          Icons.verified_rounded,
                          size: 16,
                          color: context.appColors.success,
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Row(
                      children: [
                        Icon(
                          Icons.near_me_outlined,
                          size: 13,
                          color: context.appColors.textSecondary,
                        ),
                        const SizedBox(width: 4),
                        Expanded(
                          child: Text.rich(
                            TextSpan(
                              children: [
                                TextSpan(
                                  text: '${formatCategoryLabel(shop.category)}: ',
                                  style: textTheme.bodySmall?.copyWith(
                                    color: context.appColors.textSecondary,
                                  ),
                                ),
                                TextSpan(
                                  text: shop.distanceKm != null
                                      ? '${shop.distanceKm!.toStringAsFixed(1)} km away'
                                      : shop.address,
                                  style: textTheme.bodySmall?.copyWith(
                                    fontWeight: FontWeight.w600,
                                  ),
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
}

/// The details of a suggested shop, with a button for directions.
Future<void> showSuggestedShopSheet(BuildContext context, SuggestedShop shop) {
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (sheetContext) {
      final textTheme = Theme.of(sheetContext).textTheme;
      final secondary = sheetContext.appColors.textSecondary;

      Widget line(IconData icon, String text) => Padding(
            padding: const EdgeInsets.only(bottom: AppSpacing.sm),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(icon, size: 18, color: secondary),
                const SizedBox(width: AppSpacing.sm),
                Expanded(child: Text(text, style: textTheme.bodyMedium)),
              ],
            ),
          );

      return SafeArea(
        child: SingleChildScrollView(
          padding: EdgeInsets.fromLTRB(
            AppSpacing.lg,
            0,
            AppSpacing.lg,
            AppSpacing.lg + MediaQuery.of(sheetContext).viewInsets.bottom,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                shop.name,
                style: textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 2),
              Text(
                'Suggested by a MicroLink user · approved by our team',
                style: textTheme.bodySmall?.copyWith(color: secondary),
              ),
              const SizedBox(height: AppSpacing.md),
              line(categoryIcon(shop.category), formatCategoryLabel(shop.category)),
              if (shop.address.isNotEmpty) line(Icons.place_outlined, shop.address),
              if (shop.distanceKm != null)
                line(
                  Icons.near_me_outlined,
                  '${shop.distanceKm!.toStringAsFixed(1)} km away',
                ),
              if (shop.hours != null) line(Icons.schedule_outlined, shop.hours!),
              if (shop.phone != null && shop.phone!.trim().isNotEmpty)
                line(Icons.call_outlined, shop.phone!),
              if (shop.description.trim().isNotEmpty)
                line(Icons.notes_outlined, shop.description),
              const SizedBox(height: AppSpacing.sm),
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  icon: const Icon(Icons.directions_outlined),
                  label: const Text('Get directions'),
                  onPressed: () {
                    Navigator.pop(sheetContext);
                    Navigator.pushNamed(
                      context,
                      AppRoutes.liveMap,
                      arguments: LiveMapArgs(
                        destinationLat: shop.latitude,
                        destinationLng: shop.longitude,
                        destinationLabel: shop.name,
                      ),
                    );
                  },
                ),
              ),
              // Neighbours' comments, with names, and replies anyone can add.
              const SizedBox(height: AppSpacing.lg),
              const Divider(height: 1),
              const SizedBox(height: AppSpacing.md),
              SuggestionCommentsSection(reportId: shop.id),
            ],
          ),
        ),
      );
    },
  );
}
