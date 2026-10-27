import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:frontend/core/theme/app_theme.dart';
import 'package:frontend/features/location/widgets/map_pin.dart';

/// The category legend under the Live Map's shop rail.
///
/// It reads as a row of chips and sits just below the strip over the map
/// that filters, so people tap it expecting the same thing. It used to be a
/// plain Container with no gesture handler, so nothing happened at all and
/// the map looked broken. It now filters too, while still being usable as a
/// passive key where no handler is given.
Widget _host(Widget child) => MaterialApp(
      theme: AppTheme.light,
      home: Scaffold(body: child),
    );

void main() {
  group('as a filter', () {
    testWidgets('tapping a category reports it', (tester) async {
      final taps = <String?>[];
      await tester.pumpWidget(_host(CategoryLegend(
        categories: const ['bakery', 'pharmacy'],
        selected: null,
        onSelected: taps.add,
      )));

      await tester.tap(find.text('Bakery'));
      expect(taps, ['bakery']);
    });

    testWidgets('tapping the selected category clears the filter', (tester) async {
      final taps = <String?>[];
      await tester.pumpWidget(_host(CategoryLegend(
        categories: const ['bakery', 'pharmacy'],
        selected: 'bakery',
        onSelected: taps.add,
      )));

      // Null, not 'bakery' again: there is no separate "All" chip, so the
      // active chip is what clears the filter.
      await tester.tap(find.text('Bakery'));
      expect(taps, [null]);
    });

    testWidgets('a different category replaces the filter', (tester) async {
      final taps = <String?>[];
      await tester.pumpWidget(_host(CategoryLegend(
        categories: const ['bakery', 'pharmacy'],
        selected: 'bakery',
        onSelected: taps.add,
      )));

      await tester.tap(find.text('Pharmacy'));
      expect(taps, ['pharmacy']);
    });

    testWidgets('every category stays tappable while one is selected',
        (tester) async {
      // The trap this guards: built from the FILTERED shop list the legend
      // would collapse to the one chosen category, leaving no way to switch
      // to another. It is given every loaded category instead.
      final taps = <String?>[];
      await tester.pumpWidget(_host(CategoryLegend(
        categories: const ['bakery', 'grocery', 'pharmacy'],
        selected: 'bakery',
        onSelected: taps.add,
      )));

      expect(find.text('Bakery'), findsOneWidget);
      expect(find.text('Grocery'), findsOneWidget);
      expect(find.text('Pharmacy'), findsOneWidget);

      await tester.tap(find.text('Grocery'));
      expect(taps, ['grocery']);
    });
  });

  group('as a passive key', () {
    testWidgets('without a handler it ignores taps instead of crashing',
        (tester) async {
      await tester.pumpWidget(_host(const CategoryLegend(
        categories: ['bakery'],
      )));

      await tester.tap(find.text('Bakery'));
      await tester.pump();
      expect(tester.takeException(), isNull);
    });

    testWidgets('it still shows a chip per category', (tester) async {
      await tester.pumpWidget(_host(const CategoryLegend(
        categories: ['bakery', 'grocery'],
      )));

      expect(find.text('Bakery'), findsOneWidget);
      expect(find.text('Grocery'), findsOneWidget);
    });
  });

  testWidgets('no categories means no legend at all', (tester) async {
    await tester.pumpWidget(_host(const CategoryLegend(categories: [])));
    expect(find.byType(InkWell), findsNothing);
    expect(find.byType(ListView), findsNothing);
  });
}
