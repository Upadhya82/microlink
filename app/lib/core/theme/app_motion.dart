import 'package:flutter/animation.dart';

/// The app's motion language, in one place.
///
/// Animation is a design system concern, not a per-screen decision: if every
/// screen picks its own duration and curve the app feels assembled rather
/// than designed. Screens use these constants instead of literals.
///
/// Durations are deliberately short. The SRS asks for initial screens within
/// 2 seconds on 4G (§6.1), and a 600ms flourish on every transition fights
/// that; these are long enough to read as motion and short enough to feel
/// instant.
class AppMotion {
  AppMotion._();

  /// Taps, toggles, colour and icon changes.
  static const Duration fast = Duration(milliseconds: 150);

  /// The default: content appearing, cards expanding, list items settling.
  static const Duration medium = Duration(milliseconds: 260);

  /// Page transitions and larger surfaces such as sheets.
  static const Duration slow = Duration(milliseconds: 380);

  /// Gap between consecutive items in a staggered list.
  static const Duration stagger = Duration(milliseconds: 55);

  /// Cap on stagger depth. Without it the 20th card waits over a second,
  /// which reads as the app being slow rather than as a nice effect.
  static const int maxStaggerIndex = 8;

  /// Decelerating: things entering the screen.
  static const Curve enter = Curves.easeOutCubic;

  /// Accelerating: things leaving.
  static const Curve exit = Curves.easeInCubic;

  /// Both ends eased: things already on screen that change.
  static const Curve standard = Curves.easeInOutCubic;

  /// A slight overshoot for elements that should feel physical, such as a
  /// badge appearing or a FAB growing.
  static const Curve emphasized = Curves.easeOutBack;

  /// The delay for the [index]th item of a staggered list.
  static Duration staggerDelay(int index) {
    final capped = index > maxStaggerIndex ? maxStaggerIndex : index;
    return stagger * capped;
  }
}
