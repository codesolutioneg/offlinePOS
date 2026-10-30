import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:owner_app/theme.dart';

void main() {
  testWidgets('Dishflow theme builds', (tester) async {
    await tester.pumpWidget(MaterialApp(theme: ownerTheme(), home: const SizedBox()));
    expect(ownerTheme().useMaterial3, isTrue);
  });
}
