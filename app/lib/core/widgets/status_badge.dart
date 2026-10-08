import 'package:flutter/material.dart';

import '../theme/app_colors_extension.dart';
import '../theme/app_spacing.dart';

/// A small colored pill for status/category labels (Open/Closed, issue
/// types, moderation state, ...). Use the named constructors for the two
/// recurring open/closed states so every screen renders them identically.
class StatusBadge extends StatelessWidget {
  final String label;
  final Color background;
  final Color foreground;

  const StatusBadge({
    super.key,
    required this.label,
    required this.background,
    required this.foreground,
  });

  factory StatusBadge.open(BuildContext context, {String label = 'Open'}) {
    return StatusBadge(
      label: label,
      background: Theme.of(context).colorScheme.primaryContainer,
      foreground: context.appColors.success,
    );
  }

  factory StatusBadge.closed(BuildContext context, {String label = 'Closed'}) {
    return StatusBadge(
      label: label,
      background: Theme.of(context).colorScheme.error.withValues(alpha: 0.12),
      foreground: Theme.of(context).colorScheme.error,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm, vertical: 3),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(AppRadius.pill),
      ),
      child: Text(
        label,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: foreground,
              fontWeight: FontWeight.w700,
            ),
      ),
    );
  }
}
