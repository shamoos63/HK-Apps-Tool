import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:adbappmanager/main.dart';

void main() {
  testWidgets('App shell loads', (WidgetTester tester) async {
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.binding.setSurfaceSize(const Size(1600, 900));

    await tester.pumpWidget(const HkAppsToolApp());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(NavigationRail), findsOneWidget);
  });
}
