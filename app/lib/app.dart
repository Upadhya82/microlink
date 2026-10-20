import 'package:flutter/material.dart';

import 'core/constants/app_constants.dart';
import 'core/l10n/app_strings.dart';
import 'core/network/connectivity_controller.dart';
import 'core/network/session_manager.dart';
import 'core/theme/app_theme.dart';
import 'core/theme/theme_controller.dart';
import 'core/utils/app_router.dart';
import 'core/widgets/app_entry_screen.dart';
import 'core/widgets/offline_banner.dart';

class MicroLinkApp extends StatefulWidget {
  const MicroLinkApp({super.key});

  @override
  State<MicroLinkApp> createState() => _MicroLinkAppState();
}

class _MicroLinkAppState extends State<MicroLinkApp> {
  @override
  void initState() {
    super.initState();
    // Item 14: start watching the connection once, for the whole app.
    ConnectivityController.instance.start();
  }

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
          // Item 14: one offline banner above every screen, rather than one
          // per Scaffold that somebody will forget.
          builder: (context, child) =>
              OfflineBannerHost(child: child ?? const SizedBox.shrink()),
        );
      },
    );
  }
}
