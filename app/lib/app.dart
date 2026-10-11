import 'package:flutter/material.dart';

import 'core/constants/app_constants.dart';
import 'core/l10n/app_strings.dart';
import 'core/network/session_manager.dart';
import 'core/theme/app_theme.dart';
import 'core/theme/theme_controller.dart';
import 'core/utils/app_router.dart';
import 'core/widgets/app_entry_screen.dart';

class MicroLinkApp extends StatelessWidget {
  const MicroLinkApp({super.key});

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: Listenable.merge([
        SessionManager.instance,
        ThemeController.instance,
        LanguageController.instance,
      ]),
      builder: (context, _) {
        return MaterialApp(
          title: AppConstants.appName,
          debugShowCheckedModeBanner: false,
          theme: AppTheme.light,
          darkTheme: AppTheme.dark,
          themeMode: ThemeController.instance.mode,
          onGenerateRoute: AppRouter.onGenerateRoute,
          home: const AppEntryScreen(),
        );
      },
    );
  }
}
