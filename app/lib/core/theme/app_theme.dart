import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import 'app_colors_extension.dart';
import 'app_motion.dart';
import 'app_spacing.dart';

/// MicroLink's design system: Modern & Minimal. One ThemeData per brightness,
/// built once here and used everywhere -- screens must never hardcode colors
/// or text styles.
class AppTheme {
  AppTheme._();

  /// The brand colour. Everything tinted in the app comes from here -- no
  /// screen defines its own, so changing this one value restyles all of them.
  static const _brand = Color(0xFFFF5724);

  static const _lightBackground = Color(0xFFFAFAF8);
  // A dark navy, not a dimmed version of the light background. It is the
  // complement of the brand orange, so the accent reads as warm against it
  // instead of competing with it.
  static const _darkBackground = Color(0xFF12202F);

  static ThemeData get light => _build(
        colorScheme: ColorScheme.fromSeed(
          seedColor: _brand,
          brightness: Brightness.light,
        ).copyWith(
          primary: _brand,
          onPrimary: const Color(0xFFFFFFFF),
          primaryContainer: const Color(0xFFFFE2D8),
          secondary: const Color(0xFFF2A93B),
          onSecondary: const Color(0xFF1A1C1A),
          secondaryContainer: const Color(0xFFFFE9C7),
          error: const Color(0xFFD14343),
          onError: const Color(0xFFFFFFFF),
          surface: const Color(0xFFFFFFFF),
          onSurface: const Color(0xFF1A1C1A),
        ),
        background: _lightBackground,
        colorsExtension: AppColorsExtension.light,
        brightness: Brightness.light,
      );

  static ThemeData get dark => _build(
        colorScheme: ColorScheme.fromSeed(
          seedColor: _brand,
          brightness: Brightness.dark,
        ).copyWith(
          primary: _brand,
          onPrimary: const Color(0xFFFFFFFF),
          // A deep, desaturated version of the brand rather than a tint of
          // the navy: filled chips and selected states need to read as the
          // same colour family as the accent sitting next to them.
          primaryContainer: const Color(0xFF5C2414),
          secondary: const Color(0xFFF5C270),
          onSecondary: const Color(0xFF4D3300),
          secondaryContainer: const Color(0xFF614413),
          error: const Color(0xFFE57373),
          onError: const Color(0xFF3B0A0A),
          surface: const Color(0xFF1B2B3D),
          onSurface: const Color(0xFFF1F5F9),
        ),
        background: _darkBackground,
        colorsExtension: AppColorsExtension.dark,
        brightness: Brightness.dark,
      );

  static ThemeData _build({
    required ColorScheme colorScheme,
    required Color background,
    required AppColorsExtension colorsExtension,
    required Brightness brightness,
  }) {
    final baseTextTheme = brightness == Brightness.dark
        ? Typography.material2021().white
        : Typography.material2021().black;
    final textTheme = GoogleFonts.interTextTheme(baseTextTheme).apply(
      bodyColor: colorScheme.onSurface,
      displayColor: colorScheme.onSurface,
    );

    return ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: colorScheme,
      scaffoldBackgroundColor: background,
      canvasColor: background,
      textTheme: textTheme,
      fontFamily: GoogleFonts.inter().fontFamily,
      extensions: [colorsExtension],
      splashFactory: InkRipple.splashFactory,
      visualDensity: VisualDensity.standard,
      // Every screen's top bar is the burnt-orange band, so the app has one
      // consistent header whichever role is looking at it.
      appBarTheme: AppBarTheme(
        backgroundColor: colorsExtension.headerBackground,
        foregroundColor: colorsExtension.onHeader,
        elevation: 0,
        scrolledUnderElevation: 0,
        // Material would otherwise tint the bar towards the surface colour as
        // content scrolls under it, which turns the band muddy.
        surfaceTintColor: Colors.transparent,
        centerTitle: false,
        titleTextStyle: textTheme.titleLarge?.copyWith(
          fontWeight: FontWeight.w600,
          color: colorsExtension.onHeader,
        ),
        iconTheme: IconThemeData(color: colorsExtension.onHeader),
      ),
      cardTheme: CardThemeData(
        color: colorScheme.surface,
        elevation: 1,
        surfaceTintColor: Colors.transparent,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.card),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: colorScheme.surface,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.lg,
          vertical: AppSpacing.md,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadius.input),
          borderSide: BorderSide(color: colorScheme.outlineVariant),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadius.input),
          borderSide: BorderSide(color: colorScheme.outlineVariant),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadius.input),
          borderSide: BorderSide(color: colorScheme.primary, width: 1.5),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadius.input),
          borderSide: BorderSide(color: colorScheme.error),
        ),
        focusedErrorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadius.input),
          borderSide: BorderSide(color: colorScheme.error, width: 1.5),
        ),
        labelStyle: textTheme.bodyMedium?.copyWith(color: colorsExtension.textSecondary),
        hintStyle: textTheme.bodyMedium?.copyWith(color: colorsExtension.textSecondary),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: colorScheme.primary,
          foregroundColor: colorScheme.onPrimary,
          disabledBackgroundColor: colorScheme.onSurface.withValues(alpha: 0.12),
          disabledForegroundColor: colorScheme.onSurface.withValues(alpha: 0.38),
          elevation: 0,
          minimumSize: const Size.fromHeight(52),
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xl),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadius.pill),
          ),
          textStyle: textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w600),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: colorScheme.primary,
          side: BorderSide(color: colorScheme.outline),
          minimumSize: const Size.fromHeight(52),
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xl),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadius.pill),
          ),
          textStyle: textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w600),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: colorScheme.primary,
          textStyle: textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w600),
        ),
      ),
      chipTheme: ChipThemeData(
        backgroundColor: colorScheme.surfaceContainerHighest,
        selectedColor: colorScheme.primaryContainer,
        labelStyle: textTheme.labelMedium?.copyWith(color: colorScheme.onSurface),
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm, vertical: AppSpacing.xs),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadius.pill)),
        side: BorderSide.none,
      ),
      dividerTheme: DividerThemeData(color: colorScheme.outlineVariant, thickness: 1),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: colorScheme.surface,
        indicatorColor: colorScheme.primaryContainer,
        elevation: 1,
        surfaceTintColor: Colors.transparent,
        labelTextStyle: WidgetStateProperty.resolveWith((states) {
          final selected = states.contains(WidgetState.selected);
          return textTheme.labelMedium?.copyWith(
            color: selected ? colorScheme.primary : colorsExtension.textSecondary,
            fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
          );
        }),
        iconTheme: WidgetStateProperty.resolveWith((states) {
          final selected = states.contains(WidgetState.selected);
          return IconThemeData(
            color: selected ? colorScheme.primary : colorsExtension.textSecondary,
          );
        }),
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: colorScheme.inverseSurface,
        contentTextStyle: textTheme.bodyMedium?.copyWith(color: colorScheme.onInverseSurface),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadius.input)),
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(color: colorScheme.primary),
      // Every platform gets the same transition -- previously only
      // android/iOS were listed, so testing on web/desktop (where
      // defaultTargetPlatform resolves to something else entirely) silently
      // fell back to Flutter's generic default and no custom motion ever ran.
      pageTransitionsTheme: const PageTransitionsTheme(
        builders: {
          TargetPlatform.android: _FadeSlideTransitionsBuilder(),
          TargetPlatform.iOS: _FadeSlideTransitionsBuilder(),
          TargetPlatform.macOS: _FadeSlideTransitionsBuilder(),
          TargetPlatform.linux: _FadeSlideTransitionsBuilder(),
          TargetPlatform.windows: _FadeSlideTransitionsBuilder(),
          TargetPlatform.fuchsia: _FadeSlideTransitionsBuilder(),
        },
      ),
    );
  }
}

/// A subtle fade + upward-slide page transition used across the whole app.
class _FadeSlideTransitionsBuilder extends PageTransitionsBuilder {
  const _FadeSlideTransitionsBuilder();

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    final curved = CurvedAnimation(
      parent: animation,
      curve: AppMotion.enter,
      reverseCurve: AppMotion.exit,
    );
    return FadeTransition(
      opacity: curved,
      child: SlideTransition(
        position: Tween<Offset>(
          begin: const Offset(0, 0.03),
          end: Offset.zero,
        ).animate(curved),
        child: child,
      ),
    );
  }
}
