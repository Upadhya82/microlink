import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';

import 'package:frontend/core/theme/app_theme.dart';
import 'package:frontend/features/crowdsourcing/widgets/shop_report_details_sheet.dart';

/// "Confirm shops near you" asked people to vouch for a shop they could not
/// see. The card gave a name, a street and two buttons; the reporter's
/// photo -- the one thing that settles whether a small shop is really on
/// that corner -- was a 56px thumbnail, and the category, hours, phone,
/// description and exact spot were not shown at all, although the server
/// sends every one of them.
///
/// A wrong "yes" is worse than no answer, because the shop reaches the map
/// on the strength of it. So the full report now opens before the answer.
Map<String, dynamic> report({
  bool hasPhoto = true,
  String? phone = '0771234567',
  String? opening = '08:00',
  String? closing = '19:00',
  String description = 'Next to the junction, green shutters',
  int responses = 0,
  int confirmations = 0,
}) =>
    {
      'id': 'r1',
      'shop_name': 'Nimal Hardware',
      'category': 'hardware',
      'address': 'Pitipana, Homagama',
      'latitude': 6.8450,
      'longitude': 80.0040,
      'description': description,
      'phone': phone,
      'opening_time': opening,
      'closing_time': closing,
      'has_photo': hasPhoto,
      'photo_path': hasPhoto ? '/crowdsource/shop-reports/r1/photo' : null,
      'responses': responses,
      'confirmations': confirmations,
      'comments_detail': <Map<String, dynamic>>[],
    };

void main() {
  /// Opens the sheet over a throwaway page and settles the first frame.
  /// Image.network is left to fail in tests; the sheet falls back to the
  /// "no photo" panel, which is what a broken upload looks like in the
  /// field too.
  Future<List<bool>> open(
    WidgetTester tester, {
    Map<String, dynamic>? row,
    bool busy = false,
    LatLng? here,
  }) async {
    final answers = <bool>[];
    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.light,
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: ElevatedButton(
              onPressed: () => showShopReportDetails(
                context,
                report: row ?? report(),
                busy: busy,
                here: here,
                onAnswer: answers.add,
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    return answers;
  }

  group('what the sheet shows', () {
    testWidgets('the details the card left out', (tester) async {
      await open(tester);

      expect(find.text('Nimal Hardware'), findsOneWidget);
      expect(find.text('Hardware'), findsOneWidget);
      expect(find.text('Pitipana, Homagama'), findsOneWidget);
      expect(find.text('08:00 – 19:00'), findsOneWidget);
      expect(find.text('0771234567'), findsOneWidget);
      expect(
        find.text('Next to the junction, green shutters'),
        findsOneWidget,
      );
    });

    testWidgets('fields the reporter left blank are not shown as empty rows',
        (tester) async {
      await open(tester, row: report(phone: null, description: ''));

      expect(find.text('Phone'), findsNothing);
      expect(find.text('What the reporter said'), findsNothing);
      // The ones that were filled in are still there.
      expect(find.text('Address'), findsOneWidget);
      expect(find.text('Opening hours'), findsOneWidget);
    });

    testWidgets('half-known hours are not shown as a broken range',
        (tester) async {
      await open(tester, row: report(closing: null));
      expect(find.text('Opening hours'), findsNothing);
    });

    testWidgets('no photo says so rather than leaving a blank box',
        (tester) async {
      // Worth knowing before you vouch for a place: there is nothing to look at.
      await open(tester, row: report(hasPhoto: false));
      expect(find.text('No photo was attached'), findsOneWidget);
    });

    testWidgets('a way to see the spot on the map', (tester) async {
      await open(tester);
      expect(find.text('See where it is on the map'), findsOneWidget);
    });
  });

  group('how far away it is', () {
    testWidgets('worked out on the device, since the server sends no distance',
        (tester) async {
      // Colombo to Pitipana is a long way; far enough to read in kilometres.
      await open(tester, here: const LatLng(6.9271, 79.8612));
      expect(find.textContaining('km away'), findsOneWidget);
    });

    testWidgets('close by is shown in metres, not "0.0 km"', (tester) async {
      // Homagama town to Pitipana is a couple of hundred metres, which
      // rounds to nothing useful in kilometres.
      await open(tester, here: const LatLng(6.8441, 80.0020));
      expect(find.textContaining('m away'), findsOneWidget);
      expect(find.textContaining('km away'), findsNothing);
    });

    testWidgets('no location means no distance, not a wrong one',
        (tester) async {
      await open(tester);
      expect(find.textContaining('away'), findsNothing);
    });
  });

  group('what other neighbours said', () {
    testWidgets('a split vote is given as a count, not a percentage',
        (tester) async {
      await open(tester, row: report(responses: 4, confirmations: 3));
      expect(find.text('3 of 4 neighbours said yes'), findsOneWidget);
    });

    testWidgets('a unanimous vote reads as one', (tester) async {
      await open(tester, row: report(responses: 3, confirmations: 3));
      expect(
        find.text('All 3 neighbours who answered said yes'),
        findsOneWidget,
      );
    });

    testWidgets('nobody has answered yet means nothing is claimed',
        (tester) async {
      await open(tester);
      expect(find.textContaining('said yes'), findsNothing);
    });
  });

  group('answering', () {
    testWidgets('yes is reported once and closes the sheet', (tester) async {
      final answers = await open(tester);

      await tester.tap(find.text('Yes, it is there'));
      await tester.pumpAndSettle();

      expect(answers, [true]);
      expect(find.text('Yes, it is there'), findsNothing);
    });

    testWidgets('no is reported too', (tester) async {
      final answers = await open(tester);

      await tester.tap(find.text('No'));
      await tester.pumpAndSettle();

      expect(answers, [false]);
    });

    testWidgets('an answer already in flight cannot be sent twice',
        (tester) async {
      final answers = await open(tester, busy: true);

      await tester.tap(find.text('Yes, it is there'));
      await tester.pump();

      expect(answers, isEmpty);
    });
  });
}
