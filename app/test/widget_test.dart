import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:frontend/app.dart';

void main() {
  testWidgets('MicroLink boots to a splash then login', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(const MicroLinkApp());
    expect(find.text('MicroLink'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 800));
    await tester.pumpAndSettle(); // let the splash -> login page transition finish
    expect(find.textContaining('Welcome'), findsWidgets);
  });
}
