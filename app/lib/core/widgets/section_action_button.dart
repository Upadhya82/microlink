import 'package:flutter/material.dart';

import '../theme/app_spacing.dart';

/// The "See all" / "View All" action that sits at the end of a section
/// heading.
///
/// A pill with its own fill and border rather than bare coloured text: on a
/// screen where plain orange text also appears inside cards, a link styled
/// only by its colour does not read as something you can press. The container
/// is what makes it look like a control.
///
/// Deliberately low-contrast against the brand colour -- it is a secondary
/// action next to a heading, and a solid orange button here would pull more
/// attention than the content it points at.
class SectionActionButton extends StatelessWidget {
  final String label;
  final VoidCallback onPressed;

  /// Shown after the label. Null for no icon.
  final IconData? icon;

  const SectionActionButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon = Icons.chevron_right,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Material(
      color: colorScheme.primary.withValues(alpha: 0.10),
      shape: StadiumBorder(
        side: BorderSide(color: colorScheme.primary.withValues(alpha: 0.38)),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onPressed,
        child: Padding(
          // Generous horizontally, tight vertically: a pill reads as a pill
          // when it is wider than it is tall. The whole shape is the tap
          // target, which keeps it comfortably past the 44px minimum.
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.lg,
            AppSpacing.sm,
            AppSpacing.md,
            AppSpacing.sm,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                label,
                style: Theme.of(context).textTheme.labelLarge?.copyWith(
                      color: colorScheme.primary,
                      fontWeight: FontWeight.w700,
                    ),
              ),
              if (icon != null) ...[
                const SizedBox(width: AppSpacing.xs),
                Icon(icon, size: 16, color: colorScheme.primary),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
