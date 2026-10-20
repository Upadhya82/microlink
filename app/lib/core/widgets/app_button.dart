import 'package:flutter/material.dart';

import '../l10n/app_strings.dart';
import '../network/connectivity_controller.dart';

enum AppButtonVariant { primary, secondary, outlined, text }

/// The one button widget every screen should use, so buttons look and behave
/// identically across the app. Pill-shaped per the design system, with a
/// built-in loading spinner state.
class AppButton extends StatelessWidget {
  final String label;
  final VoidCallback? onPressed;
  final AppButtonVariant variant;
  final IconData? icon;
  final bool isLoading;
  final bool expand;

  /// Item 14: this button writes something, so it is disabled while the
  /// phone is offline, with a long-press explaining why. Offline is
  /// read-only: a submit that cannot reach the server either fails in the
  /// user's face or, worse, looks like it worked.
  ///
  /// Opt-in rather than the default, because plenty of buttons are
  /// navigation ("See all reviews", "Keep cart") and must keep working with
  /// no signal.
  final bool requiresConnection;

  const AppButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.variant = AppButtonVariant.primary,
    this.icon,
    this.isLoading = false,
    this.expand = true,
    this.requiresConnection = false,
  });

  @override
  Widget build(BuildContext context) {
    if (!requiresConnection) return _build(context, blocked: false);
    // Rebuilds with the connection, so the button comes back by itself when
    // the signal does.
    return AnimatedBuilder(
      animation: ConnectivityController.instance,
      builder: (context, _) => _build(
        context,
        blocked: ConnectivityController.instance.isOffline,
      ),
    );
  }

  Widget _build(BuildContext context, {required bool blocked}) {
    final colorScheme = Theme.of(context).colorScheme;
    final effectiveOnPressed = (isLoading || blocked) ? null : onPressed;

    final child = isLoading
        ? SizedBox(
            height: 20,
            width: 20,
            child: CircularProgressIndicator(
              strokeWidth: 2.4,
              color: switch (variant) {
                AppButtonVariant.primary => colorScheme.onPrimary,
                AppButtonVariant.secondary => colorScheme.onSecondary,
                _ => colorScheme.primary,
              },
            ),
          )
        : icon != null
            ? Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(icon, size: 20),
                  const SizedBox(width: 8),
                  Text(label),
                ],
              )
            : Text(label);

    final button = switch (variant) {
      AppButtonVariant.primary => ElevatedButton(onPressed: effectiveOnPressed, child: child),
      AppButtonVariant.secondary => ElevatedButton(
          onPressed: effectiveOnPressed,
          style: ElevatedButton.styleFrom(
            backgroundColor: colorScheme.secondary,
            foregroundColor: colorScheme.onSecondary,
          ),
          child: child,
        ),
      AppButtonVariant.outlined => OutlinedButton(onPressed: effectiveOnPressed, child: child),
      AppButtonVariant.text => TextButton(onPressed: effectiveOnPressed, child: child),
    };

    final sized = expand ? SizedBox(width: double.infinity, child: button) : button;
    // Disabled on its own looks like a bug; the reason has to be reachable.
    return blocked
        ? Tooltip(message: tr('offline.action_blocked'), child: sized)
        : sized;
  }
}
