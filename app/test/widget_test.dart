import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:frontend/app.dart';

void main() {
  testWidgets('MicroLink boots through the splash to login', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(const MicroLinkApp());

    // The splash deliberately shows nothing but the brand colour: it used to
    // hold a logo and a 500ms delay to make it readable, and both are gone.
    expect(find.text('MicroLink'), findsNothing);

    // Not pumpAndSettle: the login screen animates forever -- the mark spins
    // and the greeting ripples on a loop -- so settling never happens and the
    // test would time out. Pump a fixed amount instead, enough to cover the
    // session load and the page transition.
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 600));

    // The login button is the stable thing to assert on. The screen's own
    // "MicroLink" and "Welcome back" are drawn one letter per Text widget by
    // the wordmark and wave animations, so neither matches as a whole string.
    expect(find.text('Log In'), findsOneWidget);
    // Item 5: required fields carry a " *", so the label is "Email *".
    expect(find.text('Email *'), findsOneWidget);
    expect(find.text('Fields marked * are required.'), findsOneWidget);
  });
}
