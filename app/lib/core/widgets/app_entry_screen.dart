import 'package:flutter/material.dart';

import '../constants/app_constants.dart';
import '../network/session_manager.dart';
import '../theme/theme_controller.dart';

/// The app's first screen: a branded splash while the persisted session
/// loads from disk, then routes to Home (if already logged in) or Login.
class AppEntryScreen extends StatefulWidget {
  const AppEntryScreen({super.key});

  @override
  State<AppEntryScreen> createState() => _AppEntryScreenState();
}

class _AppEntryScreenState extends State<AppEntryScreen> {
  @override
  void initState() {
    super.initState();
    _resolveSession();
  }

  Future<void> _resolveSession() async {
    final stopwatch = Stopwatch()..start();
    await Future.wait([
      SessionManager.instance.loadFromDisk(),
      ThemeController.instance.loadFromDisk(),
    ]);
    final elapsed = stopwatch.elapsed;
    const minSplash = Duration(milliseconds: 500);
    if (elapsed < minSplash) {
      await Future.delayed(minSplash - elapsed);
    }
    if (!mounted) return;
    Navigator.of(context).pushReplacementNamed(
      SessionManager.instance.isLoggedIn ? AppRoutes.home : AppRoutes.login,
    );
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Scaffold(
      backgroundColor: colorScheme.primary,
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.storefront_rounded, size: 72, color: colorScheme.onPrimary),
            const SizedBox(height: 16),
            Text(
              AppConstants.appName,
              style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                    color: colorScheme.onPrimary,
                    fontWeight: FontWeight.w700,
                  ),
            ),
          ],
        ),
      ),
    );
  }
}
