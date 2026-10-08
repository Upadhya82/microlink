import 'package:flutter/material.dart';

/// Brand colors that don't have a home in Material 3's [ColorScheme] roles
/// (e.g. a dedicated "secondary text" tone distinct from [ColorScheme.onSurface]).
/// Access via `Theme.of(context).extension<AppColorsExtension>()!`.
class AppColorsExtension extends ThemeExtension<AppColorsExtension> {
  final Color textSecondary;
  final Color success;
  final Color warning;

  const AppColorsExtension({
    required this.textSecondary,
    required this.success,
    required this.warning,
  });

  static const light = AppColorsExtension(
    textSecondary: Color(0xFF5B615D),
    success: Color(0xFF1E8A6E),
    warning: Color(0xFFF2A93B),
  );

  static const dark = AppColorsExtension(
    textSecondary: Color(0xFF94A3B8),
    success: Color(0xFF4ADE80),
    warning: Color(0xFFF5C270),
  );

  @override
  AppColorsExtension copyWith({Color? textSecondary, Color? success, Color? warning}) {
    return AppColorsExtension(
      textSecondary: textSecondary ?? this.textSecondary,
      success: success ?? this.success,
      warning: warning ?? this.warning,
    );
  }

  @override
  AppColorsExtension lerp(ThemeExtension<AppColorsExtension>? other, double t) {
    if (other is! AppColorsExtension) return this;
    return AppColorsExtension(
      textSecondary: Color.lerp(textSecondary, other.textSecondary, t)!,
      success: Color.lerp(success, other.success, t)!,
      warning: Color.lerp(warning, other.warning, t)!,
    );
  }
}

extension AppColorsContext on BuildContext {
  AppColorsExtension get appColors =>
      Theme.of(this).extension<AppColorsExtension>() ?? AppColorsExtension.light;
}
