import 'package:flutter/material.dart';

import '../constants/app_constants.dart';
import '../theme/app_colors_extension.dart';
import '../theme/app_spacing.dart';

/// The wordmark as it appears at the end of a header band.
///
/// Sized and weighted to sit beside icons without competing with the screen's
/// own title: it says which app you are in, it is not the heading.
class BrandMark extends StatelessWidget {
  const BrandMark({super.key});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(right: AppSpacing.lg),
      child: Center(
        child: Text(
          AppConstants.appName,
          style: Theme.of(context).textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w800,
                color: context.appColors.onHeader,
              ),
        ),
      ),
    );
  }
}

/// A drop-in [AppBar] that always ends with the MicroLink wordmark.
///
/// Flutter gives no way to add actions from a theme -- `AppBarTheme` can set
/// colours and text styles but not content -- so putting the brand on every
/// screen means every bar has to carry it. Doing that through one widget
/// rather than by pasting the wordmark into twenty-three files means the
/// spacing and weight can change in one place later.
///
/// Takes the same arguments as the [AppBar]s it replaced. Anything a screen
/// passes in [actions] is kept, with the wordmark appended after it.
class BrandedAppBar extends StatelessWidget implements PreferredSizeWidget {
  final Widget? title;
  final List<Widget>? actions;
  final Widget? leading;
  final PreferredSizeWidget? bottom;
  final Color? backgroundColor;
  final double? elevation;

  /// Elevation once content has scrolled beneath the bar. A screen drawing
  /// its own image behind a transparent bar passes 0 so no shadow appears
  /// over it.
  final double? scrolledUnderElevation;

  final bool automaticallyImplyLeading;

  const BrandedAppBar({
    super.key,
    this.title,
    this.actions,
    this.leading,
    this.bottom,
    this.backgroundColor,
    this.elevation,
    this.scrolledUnderElevation,
    this.automaticallyImplyLeading = true,
  });

  @override
  Size get preferredSize =>
      Size.fromHeight(kToolbarHeight + (bottom?.preferredSize.height ?? 0));

  @override
  Widget build(BuildContext context) {
    return AppBar(
      title: title,
      leading: leading,
      bottom: bottom,
      backgroundColor: backgroundColor,
      elevation: elevation,
      scrolledUnderElevation: scrolledUnderElevation,
      automaticallyImplyLeading: automaticallyImplyLeading,
      actions: [
        ...?actions,
        const BrandMark(),
      ],
    );
  }
}
