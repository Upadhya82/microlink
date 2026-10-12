import 'package:flutter/material.dart';

import '../theme/app_motion.dart';

/// The transition every pushed screen uses.
///
/// Flutter's default [MaterialPageRoute] picks a platform transition, which
/// on Android is a vertical slide that reads as heavier than this app wants
/// and on web is no transition at all. Defining it here means a screen never
/// decides how it arrives, the same way screens never pick their own colors.
///
/// The incoming screen fades up over a short distance while the one behind it
/// drifts back slightly: enough to say which way the stack moved without
/// making anyone wait for it. Both halves use [AppMotion] so the timing
/// matches the rest of the app.
class AppPageRoute<T> extends PageRouteBuilder<T> {
  AppPageRoute({required Widget child, required RouteSettings settings})
      : super(
          settings: settings,
          transitionDuration: AppMotion.slow,
          reverseTransitionDuration: AppMotion.medium,
          pageBuilder: (_, _, _) => child,
          transitionsBuilder: (context, animation, secondaryAnimation, child) {
            final enter = CurvedAnimation(
              parent: animation,
              curve: AppMotion.enter,
              reverseCurve: AppMotion.exit,
            );

            // The screen being covered. Moving it a little in the same
            // direction keeps the two from looking like unrelated pages.
            final exit = CurvedAnimation(
              parent: secondaryAnimation,
              curve: AppMotion.standard,
            );

            return FadeTransition(
              opacity: enter,
              child: SlideTransition(
                position: Tween<Offset>(
                  begin: const Offset(0, 0.035),
                  end: Offset.zero,
                ).animate(enter),
                child: SlideTransition(
                  position: Tween<Offset>(
                    begin: Offset.zero,
                    end: const Offset(0, -0.015),
                  ).animate(exit),
                  child: child,
                ),
              ),
            );
          },
        );
}

/// A route for screens that should feel like they rise over the current one
/// rather than replace it -- pickers, document upload, anything modal in
/// spirit but pushed as a page.
class AppModalPageRoute<T> extends PageRouteBuilder<T> {
  AppModalPageRoute({required Widget child, required RouteSettings settings})
      : super(
          settings: settings,
          transitionDuration: AppMotion.slow,
          reverseTransitionDuration: AppMotion.medium,
          pageBuilder: (_, _, _) => child,
          transitionsBuilder: (context, animation, secondaryAnimation, child) {
            final enter = CurvedAnimation(
              parent: animation,
              curve: AppMotion.enter,
              reverseCurve: AppMotion.exit,
            );
            return SlideTransition(
              position: Tween<Offset>(
                begin: const Offset(0, 0.12),
                end: Offset.zero,
              ).animate(enter),
              child: FadeTransition(opacity: enter, child: child),
            );
          },
        );
}
