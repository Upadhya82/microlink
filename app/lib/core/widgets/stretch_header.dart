import 'package:flutter/material.dart';

import 'branded_app_bar.dart';
import '../theme/app_colors_extension.dart';
import '../theme/app_spacing.dart';

/// A colored header that stretches when the list under it is pulled down and
/// collapses into a plain app bar as the list scrolls up.
///
/// This is the app's one "big" surface: it gives a screen somewhere to show
/// its identity (title, a line of context, a stat or two) without spending a
/// card on it, and the stretch makes a list feel physical rather than like a
/// page of boxes.
///
/// Use it as the first sliver of a [CustomScrollView]:
///
/// ```dart
/// CustomScrollView(
///   slivers: [
///     AppStretchHeader(title: 'Dashboard', subtitle: '12 shops waiting'),
///     SliverList(...),
///   ],
/// )
/// ```
///
/// The scroll view must stretch for the effect to show, so screens pair this
/// with a [BouncingScrollPhysics]-style physics; [AppStretchScrollPhysics]
/// below is that choice made once so every screen behaves the same.
class AppStretchHeader extends StatelessWidget {
  /// The screen's name. Stays visible when the header is collapsed.
  final String title;

  /// One line of context under the title -- a count, a status, a greeting.
  /// Hidden once the header collapses, so it must never be the only place
  /// something important is said.
  final String? subtitle;

  /// Shown next to the title. Keep it to the screen's own symbol.
  final IconData? icon;

  /// Trailing app-bar actions (notifications, overflow menu).
  final List<Widget> actions;

  /// Content pinned to the bottom of the expanded area, such as a row of
  /// stat chips. It fades out as the header collapses.
  final Widget? footer;

  /// How tall the header is when fully expanded.
  final double expandedHeight;

  const AppStretchHeader({
    super.key,
    required this.title,
    this.subtitle,
    this.icon,
    this.actions = const [],
    this.footer,
    this.expandedHeight = 168,
  });

  @override
  Widget build(BuildContext context) {
    final colors = context.appColors;
    final onHeader = colors.onHeader;

    return SliverAppBar(
      pinned: true,
      // stretch is what makes the colored area grow past its height when the
      // list is pulled down; without it the header simply stops.
      stretch: true,
      expandedHeight: expandedHeight,
      backgroundColor: colors.headerBackground,
      foregroundColor: onHeader,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      // The wordmark closes every header band, the same as it does on a
      // plain app bar.
      actions: [...actions, const BrandMark()],
      flexibleSpace: FlexibleSpaceBar(
        // zoomBackground is the stretch itself; fadeTitle keeps the large
        // title from colliding with the collapsed one mid-scroll.
        stretchModes: const [StretchMode.zoomBackground, StretchMode.fadeTitle],
        titlePadding: const EdgeInsetsDirectional.only(
          start: AppSpacing.lg,
          bottom: AppSpacing.md,
          end: AppSpacing.lg,
        ),
        title: _CollapsedTitle(title: title, icon: icon, color: onHeader),
        background: _HeaderBackground(
          subtitle: subtitle,
          footer: footer,
          color: colors.headerBackground,
          onColor: onHeader,
        ),
      ),
    );
  }
}

/// The title as it appears once the header has collapsed. Deliberately small:
/// at this size it sits on the app bar next to the actions.
class _CollapsedTitle extends StatelessWidget {
  final String title;
  final IconData? icon;
  final Color color;

  const _CollapsedTitle({required this.title, required this.icon, required this.color});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (icon != null) ...[
          Icon(icon, size: 18, color: color),
          const SizedBox(width: AppSpacing.sm),
        ],
        Flexible(
          child: Text(
            title,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context)
                .textTheme
                .titleMedium
                ?.copyWith(color: color, fontWeight: FontWeight.w700),
          ),
        ),
      ],
    );
  }
}

/// The expanded area behind the title: a brand-colored wash with the subtitle
/// and any footer content. A gradient rather than a flat fill so the stretch
/// reads as depth instead of as a growing rectangle.
class _HeaderBackground extends StatelessWidget {
  final String? subtitle;
  final Widget? footer;
  final Color color;
  final Color onColor;

  const _HeaderBackground({
    required this.subtitle,
    required this.footer,
    required this.color,
    required this.onColor,
  });

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            Color.alphaBlend(Colors.white.withValues(alpha: 0.12), color),
            color,
          ],
        ),
      ),
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.lg,
            AppSpacing.xxl,
            AppSpacing.lg,
            // Leaves room for the collapsed title, which is laid out over
            // this background.
            AppSpacing.xxxl,
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.end,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (subtitle != null)
                Text(
                  subtitle!,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: onColor.withValues(alpha: 0.85),
                      ),
                ),
              if (footer != null) ...[
                const SizedBox(height: AppSpacing.md),
                footer!,
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// A small translucent chip for the header's [AppStretchHeader.footer] row --
/// a label and a number, readable against the brand color.
class AppHeaderStat extends StatelessWidget {
  final IconData icon;
  final String label;

  const AppHeaderStat({super.key, required this.icon, required this.label});

  @override
  Widget build(BuildContext context) {
    final onColor = context.appColors.onHeader;
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.md,
        vertical: AppSpacing.xs + 2,
      ),
      decoration: BoxDecoration(
        color: onColor.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(AppRadius.pill),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: onColor),
          const SizedBox(width: AppSpacing.xs + 2),
          Text(
            label,
            style: Theme.of(context)
                .textTheme
                .labelMedium
                ?.copyWith(color: onColor, fontWeight: FontWeight.w700),
          ),
        ],
      ),
    );
  }
}

/// The scroll physics every stretch-header screen uses, so the pull feels the
/// same everywhere. Bouncing physics is what allows the overscroll the header
/// stretches into -- on Android the default clamping physics has none.
class AppStretchScrollPhysics extends BouncingScrollPhysics {
  const AppStretchScrollPhysics({super.parent});

  @override
  AppStretchScrollPhysics applyTo(ScrollPhysics? ancestor) {
    return AppStretchScrollPhysics(parent: buildParent(ancestor));
  }
}

/// Convenience: the physics above, always scrollable so a short list can
/// still be pulled (and so the header can still stretch on a near-empty
/// screen, which is exactly when an app feels dead without it).
const AlwaysScrollableScrollPhysics kStretchParentPhysics =
    AlwaysScrollableScrollPhysics();

/// [AppStretchScrollPhysics] with [kStretchParentPhysics] already applied.
const AppStretchScrollPhysics kAppStretchPhysics =
    AppStretchScrollPhysics(parent: kStretchParentPhysics);
