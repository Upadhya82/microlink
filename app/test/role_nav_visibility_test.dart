// A kept-alive tab learns when it is shown again, which is what lets the
// driver's Map tab pick up a job accepted on the Jobs tab.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/core/widgets/role_nav_scaffold.dart';

class _Probe extends StatefulWidget {
  final List<bool> seen;
  const _Probe(this.seen);

  @override
  State<_Probe> createState() => _ProbeState();
}

class _ProbeState extends State<_Probe> {
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    widget.seen.add(RoleNavVisibility.isActiveIn(context));
  }

  @override
  Widget build(BuildContext context) => const Text('map');
}

void main() {
  testWidgets('a tab hears when it is hidden and shown again', (tester) async {
    final seen = <bool>[];
    await tester.pumpWidget(
      MaterialApp(
        home: RoleNavScaffold(
          items: [
            RoleNavItem(
              label: 'Map',
              icon: Icons.map_outlined,
              selectedIcon: Icons.map,
              builder: (_) => _Probe(seen),
            ),
            RoleNavItem(
              label: 'Jobs',
              icon: Icons.work_outline,
              selectedIcon: Icons.work,
              builder: (_) => const Text('jobs'),
            ),
          ],
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(seen, [true]);

    await tester.tap(find.text('Jobs'));
    await tester.pumpAndSettle();
    expect(seen, [true, false]);

    await tester.tap(find.text('Map').last);
    await tester.pumpAndSettle();
    // Same State, told it is back on screen -- not rebuilt from scratch.
    expect(seen, [true, false, true]);
  });

  testWidgets('a screen outside the bottom bar counts as shown', (tester) async {
    final seen = <bool>[];
    await tester.pumpWidget(MaterialApp(home: _Probe(seen)));
    expect(seen, [true]);
  });
}
