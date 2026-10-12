import 'package:flutter/material.dart';

import '../constants/app_constants.dart';
import '../l10n/app_strings.dart';
import '../location/delivery_location_store.dart';
import '../network/session_manager.dart';
import '../theme/theme_controller.dart';

/// The app's first screen: a quiet hold while the persisted session loads
/// from disk, then routes to Home (if already logged in) or Login.
///
/// There is deliberately no logo or product name here. A splash screen that
/// exists only to show a mark costs everyone a beat before they can do
/// anything, so this one shows nothing but the app's color and gets out of
/// the way as soon as the session has loaded.
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
    // No artificial minimum any more. The old 500ms floor was there to hold
    // the logo on screen long enough to be read; with the logo gone it would
    // only be a delay.
    await Future.wait([
      SessionManager.instance.loadFromDisk(),
      ThemeController.instance.loadFromDisk(),
      DeliveryLocationStore.instance.loadFromDisk(),
      LanguageController.instance.loadFromDisk(),
    ]);
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
        // Thin and low-contrast on purpose: on a fast device this is gone in
        // a frame or two, and a bold spinner flashing by reads as a glitch.
        child: SizedBox(
          width: 22,
          height: 22,
          child: CircularProgressIndicator(
            strokeWidth: 2,
            color: colorScheme.onPrimary.withValues(alpha: 0.7),
          ),
        ),
      ),
    );
  }
}
