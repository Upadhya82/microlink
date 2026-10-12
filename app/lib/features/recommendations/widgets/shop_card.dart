import 'package:flutter/material.dart';

import '../../../core/utils/media_url.dart';
import '../../../core/models/shop.dart';
import '../../../core/theme/app_colors_extension.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/widgets/app_card.dart';

/// The single shop list-item look used everywhere in the app: image (or a
/// storefront-icon fallback), name, category, open/closed status, rating,
/// distance (when known), and -- for recommendation contexts -- a short
/// "why we're showing you this" reason caption.
class ShopCard extends StatelessWidget {
  final Shop shop;
  final VoidCallback onTap;
  final bool showReason;

  const ShopCard({
    super.key,
    required this.shop,
    required this.onTap,
    this.showReason = false,
  });

  @override
  Widget build(BuildContext context) {
    final colors = context.appColors;
    final textTheme = Theme.of(context).textTheme;
    final colorScheme = Theme.of(context).colorScheme;

    return AppCard(
      onTap: onTap,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _ShopImage(imageUrl: shop.imageUrl),
          const SizedBox(width: AppSpacing.lg),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Text(
                        shop.name,
                        style: textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(width: AppSpacing.sm),
                    _StatusPill(isOpen: shop.isOpen),
                  ],
                ),
                const SizedBox(height: AppSpacing.xs),
                Wrap(
                  spacing: AppSpacing.sm,
                  runSpacing: AppSpacing.xs,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    _CategoryChip(category: shop.category),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.star_rounded, size: 16, color: colorScheme.secondary),
                        const SizedBox(width: 2),
                        Text(
                          shop.ratingAvg.toStringAsFixed(1),
                          style: textTheme.bodySmall?.copyWith(fontWeight: FontWeight.w600),
                        ),
                        const SizedBox(width: 2),
                        Text(
                          '(${shop.ratingCount})',
                          style: textTheme.bodySmall?.copyWith(color: colors.textSecondary),
                        ),
                      ],
                    ),
                  ],
                ),
                if (shop.distanceKm != null) ...[
                  const SizedBox(height: AppSpacing.xs),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.place_outlined, size: 14, color: colors.textSecondary),
                      const SizedBox(width: 2),
                      Text(
                        '${shop.distanceKm!.toStringAsFixed(1)} km away',
                        style: textTheme.bodySmall?.copyWith(color: colors.textSecondary),
                      ),
                    ],
                  ),
                ],
                if (showReason && shop.reason != null) ...[
                  const SizedBox(height: AppSpacing.xs),
                  Text(
                    shop.reason!,
                    style: textTheme.bodySmall?.copyWith(
                      color: colors.textSecondary,
                      fontStyle: FontStyle.italic,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ShopImage extends StatelessWidget {
  final String? imageUrl;

  const _ShopImage({required this.imageUrl});

  @override
  Widget build(BuildContext context) {
    const size = 72.0;
    final url = imageUrl;
    if (url == null || url.isEmpty) {
      return _FallbackIcon(size: size);
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(AppRadius.card - 4),
      child: Image.network(
        mediaUrl(url) ?? url,
        width: size,
        height: size,
        fit: BoxFit.cover,
        errorBuilder: (context, error, stackTrace) => _FallbackIcon(size: size),
        loadingBuilder: (context, child, progress) {
          if (progress == null) return child;
          return _FallbackIcon(size: size, loading: true);
        },
      ),
    );
  }
}

class _FallbackIcon extends StatelessWidget {
  final double size;
  final bool loading;

  const _FallbackIcon({required this.size, this.loading = false});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(AppRadius.card - 4),
      ),
      alignment: Alignment.center,
      child: loading
          ? SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2, color: colorScheme.primary),
            )
          : Icon(Icons.storefront, color: colorScheme.onSurfaceVariant, size: size * 0.45),
    );
  }
}

class _StatusPill extends StatelessWidget {
  final bool isOpen;

  const _StatusPill({required this.isOpen});

  @override
  Widget build(BuildContext context) {
    final colors = context.appColors;
    final colorScheme = Theme.of(context).colorScheme;
    final color = isOpen ? colors.success : colorScheme.error;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(AppRadius.pill),
      ),
      child: Text(
        isOpen ? 'Open' : 'Closed',
        style: Theme.of(context)
            .textTheme
            .labelSmall
            ?.copyWith(color: color, fontWeight: FontWeight.w600),
      ),
    );
  }
}

class _CategoryChip extends StatelessWidget {
  final String category;

  const _CategoryChip({required this.category});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm, vertical: 2),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(AppRadius.pill),
      ),
      child: Text(
        formatCategoryLabel(category),
        style: Theme.of(context).textTheme.labelSmall,
      ),
    );
  }
}
