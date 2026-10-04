import 'package:flutter/material.dart';

import '../theme/theme_controller.dart';

/// A round, softly-shadowed icon button that flips between light and dark
/// mode via [ThemeController]. Shared so every screen that offers a manual
/// theme toggle (not just Home) looks and behaves identically.
class ThemeToggleButton extends StatelessWidget {
  const ThemeToggleButton({super.key});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Material(
      color: colorScheme.surface,
      shape: const CircleBorder(),
      elevation: 1,
      shadowColor: colorScheme.shadow.withValues(alpha: 0.2),
      child: IconButton(
        icon: Icon(
          isDark ? Icons.light_mode_outlined : Icons.dark_mode_outlined,
          color: colorScheme.onSurface,
        ),
        tooltip: 'Switch to ${isDark ? 'light' : 'dark'} mode',
        onPressed: () => ThemeController.instance.toggle(Theme.of(context).brightness),
      ),
    );
  }
}
