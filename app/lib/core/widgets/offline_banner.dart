import 'package:flutter/material.dart';

import '../l10n/app_strings.dart';
import '../network/connectivity_controller.dart';
import '../theme/app_spacing.dart';

/// "You are offline" — app-wide (item 14).
///
/// Wrapped around the whole navigator rather than added to each Scaffold,
/// so it cannot be forgotten on one screen. Saved data stays readable while
/// it is up; anything that would write is disabled (see
/// [AppButton.requiresConnection]).
class OfflineBannerHost extends StatelessWidget {
  final Widget child;

  const OfflineBannerHost({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: ConnectivityController.instance,
      builder: (context, _) {
        final offline = ConnectivityController.instance.isOffline;
        return Column(
          children: [
            // The banner takes its own strip above the app rather than
            // floating over it, so it never covers a control.
            AnimatedSize(
              duration: const Duration(milliseconds: 220),
              curve: Curves.easeOut,
              alignment: Alignment.bottomCenter,
              child: offline ? const _OfflineBar() : const SizedBox(width: double.infinity),
            ),
            Expanded(child: child),
          ],
        );
      },
    );
  }
}

class _OfflineBar extends StatelessWidget {
  const _OfflineBar();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.errorContainer,
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.lg,
            vertical: AppSpacing.sm,
          ),
          child: Row(
            children: [
              Icon(Icons.wifi_off_rounded, size: 16, color: scheme.onErrorContainer),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: Text(
                  tr('offline.banner'),
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: scheme.onErrorContainer,
                        fontWeight: FontWeight.w600,
                      ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
