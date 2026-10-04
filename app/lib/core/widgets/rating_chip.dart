import 'package:flutter/material.dart';

/// A star icon + numeric rating, optionally with a review count, used
/// anywhere a [Shop]'s `ratingAvg`/`ratingCount` is shown inline.
class RatingChip extends StatelessWidget {
  final double rating;
  final int? count;
  final double iconSize;
  final TextStyle? textStyle;

  const RatingChip({
    super.key,
    required this.rating,
    this.count,
    this.iconSize = 14,
    this.textStyle,
  });

  @override
  Widget build(BuildContext context) {
    final style = textStyle ??
        Theme.of(context).textTheme.labelMedium?.copyWith(fontWeight: FontWeight.w700);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.star_rounded, size: iconSize, color: Theme.of(context).colorScheme.secondary),
        const SizedBox(width: 3),
        Text(rating.toStringAsFixed(1), style: style),
        if (count != null) ...[
          const SizedBox(width: 4),
          Text(
            '($count)',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ],
    );
  }
}
