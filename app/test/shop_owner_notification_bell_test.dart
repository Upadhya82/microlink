// The shop owner's Home has no bottom-bar tab for notifications, so the
// bell in its header is the only one-tap way into the notification centre.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/features/notifications/unread_count_controller.dart';
import 'package:frontend/features/notifications/widgets/notification_bell.dart';
import 'package:frontend/features/shop_owner/screens/shop_owner_dashboard_screen.dart';

void main() {
  testWidgets('the shop owner Home header shows the notification bell', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: ShopOwnerDashboardScreen(onOpenAccount: (_) {})),
      ),
    );
    await tester.pump();

    expect(find.byType(NotificationBell), findsOneWidget);
    expect(find.byTooltip('Notifications'), findsOneWidget);

    // The bell polls the unread count every 30 s; end it before the test
    // does, or the test framework reports the timer as leaked.
    UnreadCountController.instance.stop();
  });

  testWidgets('the standalone dashboard route has no second bell', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: ShopOwnerDashboardScreen()),
    );
    await tester.pump();

    expect(find.byType(NotificationBell), findsNothing);
  });
}
