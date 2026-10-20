import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:frontend/core/l10n/app_strings.dart';
import 'package:frontend/core/network/connectivity_controller.dart';
import 'package:frontend/core/network/offline_cache.dart';
import 'package:frontend/core/theme/app_theme.dart';
import 'package:frontend/core/widgets/app_button.dart';
import 'package:frontend/core/widgets/offline_banner.dart';

/// Item 14: offline is read-only. Saved information stays readable, the
/// banner says so, and anything that would write is disabled.
void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    ConnectivityController.instance.debugSetOffline(false);
  });

  tearDown(() => ConnectivityController.instance.debugSetOffline(false));

  group('OfflineCache', () {
    test('what goes in comes back out', () async {
      await OfflineCache.save(OfflineCache.myOrdersKey, [
        {'id': 'o1', 'status': 'pending'},
      ]);
      final cached = await OfflineCache.loadList(OfflineCache.myOrdersKey);
      expect(cached, isNotNull);
      expect(cached!.rows.single['id'], 'o1');
      expect(cached.savedAt.isAfter(DateTime.now().subtract(const Duration(minutes: 1))), isTrue);
    });

    test('an empty cache reads as nothing, not as an empty list', () async {
      expect(await OfflineCache.load(OfflineCache.myOrdersKey), isNull);
      expect(await OfflineCache.loadList(OfflineCache.myOrdersKey), isNull);
    });

    test('data older than the window is dropped rather than shown', () async {
      final stale = DateTime.now().subtract(OfflineCache.maxAge * 2);
      SharedPreferences.setMockInitialValues({
        OfflineCache.myOrdersKey: jsonEncode({
          'saved': stale.millisecondsSinceEpoch,
          'payload': [
            {'id': 'ancient'},
          ],
        }),
      });
      expect(await OfflineCache.loadList(OfflineCache.myOrdersKey), isNull);
    });

    test('data just inside the window is still shown', () async {
      final recent = DateTime.now().subtract(OfflineCache.maxAge - const Duration(hours: 1));
      SharedPreferences.setMockInitialValues({
        OfflineCache.myOrdersKey: jsonEncode({
          'saved': recent.millisecondsSinceEpoch,
          'payload': [
            {'id': 'o1'},
          ],
        }),
      });
      final cached = await OfflineCache.loadList(OfflineCache.myOrdersKey);
      expect(cached?.rows.single['id'], 'o1');
    });

    test('corrupt data does not throw', () async {
      SharedPreferences.setMockInitialValues({
        OfflineCache.myOrdersKey: 'not json at all',
      });
      expect(await OfflineCache.load(OfflineCache.myOrdersKey), isNull);
    });

    test('a payload of the wrong shape is refused', () async {
      await OfflineCache.save(OfflineCache.myOrdersKey, {'not': 'a list'});
      expect(await OfflineCache.loadList(OfflineCache.myOrdersKey), isNull);
    });

    test('logging out clears every cache', () async {
      await OfflineCache.save(OfflineCache.myOrdersKey, [
        {'id': 'o1'},
      ]);
      await OfflineCache.save(OfflineCache.activeDeliveryKey, [
        {'id': 'o2'},
      ]);
      await OfflineCache.save(OfflineCache.notificationsKey, [
        {'id': 'n1'},
      ]);

      await OfflineCache.clearAll();

      for (final key in OfflineCache.allKeys) {
        expect(await OfflineCache.load(key), isNull, reason: key);
      }
    });

    test('the three caches are kept apart', () async {
      await OfflineCache.save(OfflineCache.myOrdersKey, [
        {'id': 'order'},
      ]);
      await OfflineCache.save(OfflineCache.notificationsKey, [
        {'id': 'notification'},
      ]);
      final orders = await OfflineCache.loadList(OfflineCache.myOrdersKey);
      final notifications =
          await OfflineCache.loadList(OfflineCache.notificationsKey);
      expect(orders!.rows.single['id'], 'order');
      expect(notifications!.rows.single['id'], 'notification');
    });
  });

  group('the banner', () {
    Future<void> pump(WidgetTester tester) => tester.pumpWidget(
          MaterialApp(
            theme: AppTheme.light,
            home: const OfflineBannerHost(
              child: Scaffold(body: Text('a screen')),
            ),
          ),
        );

    testWidgets('is absent while online', (tester) async {
      await pump(tester);
      expect(find.text('You are offline. Showing saved information.'), findsNothing);
      expect(find.text('a screen'), findsOneWidget);
    });

    testWidgets('appears when the connection drops', (tester) async {
      await pump(tester);
      ConnectivityController.instance.debugSetOffline(true);
      await tester.pumpAndSettle();
      expect(find.text('You are offline. Showing saved information.'), findsOneWidget);
      // The screen under it stays readable: offline is read-only, not blank.
      expect(find.text('a screen'), findsOneWidget);
    });

    testWidgets('goes away by itself when the signal returns', (tester) async {
      await pump(tester);
      ConnectivityController.instance.debugSetOffline(true);
      await tester.pumpAndSettle();
      ConnectivityController.instance.debugSetOffline(false);
      await tester.pumpAndSettle();
      expect(find.text('You are offline. Showing saved information.'), findsNothing);
    });

    testWidgets('is translated', (tester) async {
      await LanguageController.instance.setLanguage(AppLanguage.sinhala);
      addTearDown(
        () => LanguageController.instance.setLanguage(AppLanguage.english),
      );
      ConnectivityController.instance.debugSetOffline(true);
      await pump(tester);
      await tester.pumpAndSettle();
      expect(find.text('ඔබ දැන් නොබැඳිය. සුරකින ලද තොරතුරු පෙන්වයි.'), findsOneWidget);
    });
  });

  group('buttons that write', () {
    Future<void> pump(WidgetTester tester, {required bool requiresConnection}) =>
        tester.pumpWidget(
          MaterialApp(
            theme: AppTheme.light,
            home: Scaffold(
              body: AppButton(
                label: 'Place order',
                requiresConnection: requiresConnection,
                onPressed: () {},
              ),
            ),
          ),
        );

    testWidgets('are enabled while online', (tester) async {
      await pump(tester, requiresConnection: true);
      final button = tester.widget<ElevatedButton>(find.byType(ElevatedButton));
      expect(button.onPressed, isNotNull);
    });

    testWidgets('are disabled while offline', (tester) async {
      await pump(tester, requiresConnection: true);
      ConnectivityController.instance.debugSetOffline(true);
      await tester.pumpAndSettle();
      final button = tester.widget<ElevatedButton>(find.byType(ElevatedButton));
      expect(button.onPressed, isNull);
    });

    testWidgets('say why they are disabled', (tester) async {
      await pump(tester, requiresConnection: true);
      ConnectivityController.instance.debugSetOffline(true);
      await tester.pumpAndSettle();
      final tooltip = tester.widget<Tooltip>(find.byType(Tooltip));
      expect(tooltip.message, 'You are offline. Connect to the internet to do this.');
    });

    testWidgets('come back by themselves when the signal returns',
        (tester) async {
      await pump(tester, requiresConnection: true);
      ConnectivityController.instance.debugSetOffline(true);
      await tester.pumpAndSettle();
      ConnectivityController.instance.debugSetOffline(false);
      await tester.pumpAndSettle();
      final button = tester.widget<ElevatedButton>(find.byType(ElevatedButton));
      expect(button.onPressed, isNotNull);
    });

    testWidgets('a button that only navigates keeps working offline',
        (tester) async {
      await pump(tester, requiresConnection: false);
      ConnectivityController.instance.debugSetOffline(true);
      await tester.pumpAndSettle();
      final button = tester.widget<ElevatedButton>(find.byType(ElevatedButton));
      expect(button.onPressed, isNotNull);
    });
  });
}
