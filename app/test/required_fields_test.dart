import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:frontend/core/l10n/app_strings.dart';
import 'package:frontend/core/theme/app_theme.dart';
import 'package:frontend/core/widgets/app_text_field.dart';
import 'package:frontend/core/widgets/required_fields_note.dart';

/// Item 5: required fields are marked, and the marking is explained once at
/// the top of the form -- in English and in Sinhala.
void main() {
  // LanguageController writes the choice to disk; without this the plugin
  // call has no implementation under `flutter test`.
  setUp(() => SharedPreferences.setMockInitialValues({}));

  Future<void> pump(WidgetTester tester, Widget child) => tester.pumpWidget(
        MaterialApp(theme: AppTheme.light, home: Scaffold(body: child)),
      );

  group('requiredLabel', () {
    test('marks a required field', () {
      expect(requiredLabel('Full name'), 'Full name *');
    });

    test('leaves an optional field alone', () {
      expect(requiredLabel('Phone number', isRequired: false), 'Phone number');
    });

    test('interpolates rather than printing the variable name', () {
      // A '\$label' slip here would put a literal dollar sign on screen.
      expect(requiredLabel('Email'), isNot(contains(r'$')));
    });
  });

  group('AppTextField', () {
    testWidgets('a required field carries the asterisk', (tester) async {
      final controller = TextEditingController();
      addTearDown(controller.dispose);
      await pump(
        tester,
        AppTextField(
          controller: controller,
          label: 'Full name',
          isRequired: true,
        ),
      );
      expect(find.text('Full name *'), findsOneWidget);
    });

    testWidgets('an optional field does not', (tester) async {
      final controller = TextEditingController();
      addTearDown(controller.dispose);
      await pump(
        tester,
        AppTextField(controller: controller, label: 'Phone number'),
      );
      expect(find.text('Phone number'), findsOneWidget);
      expect(find.text('Phone number *'), findsNothing);
    });

    testWidgets('a screen reader is told "required", not "star"',
        (tester) async {
      final handle = tester.ensureSemantics();
      final controller = TextEditingController();
      addTearDown(controller.dispose);

      await pump(
        tester,
        AppTextField(
          controller: controller,
          label: 'Full name',
          isRequired: true,
        ),
      );

      expect(
        find.bySemanticsLabel('Full name, required'),
        findsOneWidget,
        reason: 'the asterisk must not be the only cue',
      );
      handle.dispose();
    });

    testWidgets('an optional field adds no semantics of its own',
        (tester) async {
      final handle = tester.ensureSemantics();
      final controller = TextEditingController();
      addTearDown(controller.dispose);

      await pump(
        tester,
        AppTextField(controller: controller, label: 'Phone number'),
      );

      expect(find.bySemanticsLabel('Phone number, required'), findsNothing);
      handle.dispose();
    });
  });

  group('RequiredFieldsNote', () {
    tearDown(() => LanguageController.instance.setLanguage(AppLanguage.english));

    testWidgets('says so in English', (tester) async {
      await LanguageController.instance.setLanguage(AppLanguage.english);
      await pump(tester, const RequiredFieldsNote());
      expect(find.text('Fields marked * are required.'), findsOneWidget);
    });

    testWidgets('says so in Sinhala', (tester) async {
      await LanguageController.instance.setLanguage(AppLanguage.sinhala);
      await pump(tester, const RequiredFieldsNote());
      expect(find.text('* ලකුණ ඇති කොටස් අනිවාර්යයි.'), findsOneWidget);
    });
  });

  group('the strings exist in both languages', () {
    test('neither key falls back to English in Sinhala', () {
      final missing = missingKeysFor('si');
      expect(missing, isNot(contains('form.required_note')));
      expect(missing, isNot(contains('form.required_suffix')));
    });
  });
}
