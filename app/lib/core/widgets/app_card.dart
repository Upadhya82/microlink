import 'package:flutter/material.dart';

import '../theme/app_spacing.dart';

/// The one card widget every list item / content block should use, so cards
/// look and behave identically across the app -- includes a tap ripple when
/// [onTap] is given, per the design system's "subtle motion" rule.
class AppCard extends StatelessWidget {
  final Widget child;
  final VoidCallback? onTap;
  final EdgeInsetsGeometry padding;

  const AppCard({
    super.key,
    required this.child,
    this.onTap,
    this.padding = const EdgeInsets.all(AppSpacing.lg),
  });

  @override
  Widget build(BuildContext context) {
    final card = Card(
      child: onTap == null
          ? Padding(padding: padding, child: child)
          : InkWell(
              onTap: onTap,
              borderRadius: BorderRadius.circular(AppRadius.card),
              child: Padding(padding: padding, child: child),
            ),
    );
    return card;
  }
}
