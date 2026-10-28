// The admin reviews an applicant's profile and documents before deciding,
// so the Verify and Reject buttons live on this screen, not on the list.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/features/admin/screens/admin_applicant_screen.dart';
import 'package:frontend/features/admin/widgets/admin_document_preview.dart';

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

  group('documents, one under each heading', () {
    Map<String, dynamic> doc(String type, {String contentType = 'image/jpeg'}) => {
          'id': 'doc-$type',
          'doc_type': type,
          'file_name': '$type.jpg',
          'content_type': contentType,
          'size_bytes': 250000,
          'created_at': '2026-10-18T10:00:00+00:00',
        };

    Future<void> pumpSection(WidgetTester tester, List<Map<String, dynamic>> documents) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: ApplicantDocumentsSection(
              requiredTypes: const ['national_id', 'business_registration', 'profile_photo'],
              documents: documents,
            ),
          ),
        ),
      ));
      await tester.pump();
    }

    testWidgets('each document sits directly under its own heading', (tester) async {
      await pumpSection(tester, [
        doc('profile_photo'),
        doc('national_id'),
        doc('business_registration'),
      ]);

      final previews = find.byType(AdminDocumentPreview);
      expect(previews, findsNWidgets(3));
      // Headings in the role's order, each with its own preview below it
      // and above the next heading.
      final labels = ['National ID', 'Business registration', 'Profile photo'];
      for (var i = 0; i < labels.length; i++) {
        final headingY = tester.getTopLeft(find.text(labels[i])).dy;
        final previewY = tester.getTopLeft(previews.at(i)).dy;
        expect(previewY, greaterThan(headingY), reason: '${labels[i]} preview is under it');
        if (i + 1 < labels.length) {
          expect(previewY, lessThan(tester.getTopLeft(find.text(labels[i + 1])).dy));
        }
      }
      // The preview under National ID is the national ID file, not another.
      expect(
        tester.widget<AdminDocumentPreview>(previews.at(0)).document['doc_type'],
        'national_id',
      );
    });

    testWidgets('a missing document says so in its place', (tester) async {
      await pumpSection(tester, [doc('national_id')]);

      expect(find.byType(AdminDocumentPreview), findsOneWidget);
      expect(find.text('Not uploaded'), findsNWidgets(2));
      expect(find.text('Missing'), findsNWidgets(2));
      expect(find.text('Uploaded'), findsOneWidget);
    });

    testWidgets('a PDF gets an open button instead of a picture', (tester) async {
      await pumpSection(tester, [doc('national_id', contentType: 'application/pdf')]);

      expect(find.text('Open PDF'), findsOneWidget);
    });

    testWidgets('extra uploads appear under Other documents', (tester) async {
      await pumpSection(tester, [doc('national_id'), doc('driving_licence')]);

      expect(find.text('Other documents'), findsOneWidget);
      expect(find.text('Driving licence'), findsOneWidget);
    });
  });
}
