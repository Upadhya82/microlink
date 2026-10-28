// The admin reviews an applicant's profile and documents before deciding,
// so the Verify and Reject buttons live on this screen, not on the list.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/features/admin/screens/admin_applicant_screen.dart';

Map<String, dynamic> _user({
  String role = 'shop_owner',
  bool verified = false,
  String? rejectionReason,
}) =>
    {
      'id': '3f2b8c1e-9d4a-4e6b-8f0c-1a2b3c4d5e6f',
      'full_name': 'Sunil Fernando',
      'email': 'sunil@example.lk',
      'phone': '0771234567',
      'business_name': 'Thusitha Bakers',
      'role': role,
      'is_verified': verified,
      'is_active': true,
      'rejection_reason': rejectionReason,
      'created_at': '2026-10-18T10:00:00+00:00',
    };

Future<void> _open(WidgetTester tester, Map<String, dynamic> user) async {
  await tester.pumpWidget(MaterialApp(home: AdminApplicantScreen(user: user)));
  await tester.pump();
}

void main() {
  testWidgets('shows the profile before any decision', (tester) async {
    await _open(tester, _user());

    expect(find.text('Sunil Fernando'), findsOneWidget);
    expect(find.text('sunil@example.lk'), findsOneWidget);
    expect(find.text('0771234567'), findsOneWidget);
    expect(find.text('Thusitha Bakers'), findsOneWidget);
    expect(find.text('Shop owner'), findsOneWidget);
    expect(find.text('Documents'), findsOneWidget);
  });

  testWidgets('a pending applicant can be verified or rejected', (tester) async {
    await _open(tester, _user());

    expect(find.widgetWithText(FilledButton, 'Verify'), findsOneWidget);
    expect(find.widgetWithText(OutlinedButton, 'Reject'), findsOneWidget);
  });

  testWidgets('a verified account has nothing left to decide', (tester) async {
    await _open(tester, _user(verified: true));

    expect(find.text('Verified'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Verify'), findsNothing);
    expect(find.widgetWithText(OutlinedButton, 'Reject'), findsNothing);
  });

  testWidgets('an earlier rejection reason is shown to the admin', (tester) async {
    await _open(tester, _user(rejectionReason: 'The NIC photo is blurred.'));

    expect(find.textContaining('The NIC photo is blurred.'), findsOneWidget);
  });

  testWidgets('rejecting asks for a reason the applicant will read', (tester) async {
    await _open(tester, _user());

    await tester.tap(find.widgetWithText(OutlinedButton, 'Reject'));
    await tester.pumpAndSettle();
    expect(find.text('Reject Sunil Fernando?'), findsOneWidget);

    // An empty reason is refused before anything is sent.
    await tester.tap(find.widgetWithText(FilledButton, 'Reject'));
    await tester.pump();
    expect(find.text('Please give a reason.'), findsOneWidget);
  });

  testWidgets('a delivery agent applicant has a vehicle section', (tester) async {
    await _open(tester, _user(role: 'delivery_agent'));

    expect(find.text('Vehicle'), findsOneWidget);
    expect(find.text('Delivery agent'), findsOneWidget);
  });
}
