// Test-only. Proves the screenshot pipeline works on the Linux embedder:
// a widget rendered at a chosen surface size, captured to a PNG on disk.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

final GlobalKey shotKey = GlobalKey();

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('captures a png', (t) async {
    t.view.physicalSize = const Size(900, 1600);
    t.view.devicePixelRatio = 1.0;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);

    await t.pumpWidget(RepaintBoundary(
      key: shotKey,
      child: const MaterialApp(
        home: Scaffold(body: Center(child: Text('hello shot'))),
      ),
    ));
    await t.pumpAndSettle();

    final boundary =
        shotKey.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    late final List<int> png;
    await t.runAsync(() async {
      final image = await boundary.toImage(pixelRatio: 1.0);
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      png = data!.buffer.asUint8List();
    });

    final dir = Directory(
        Platform.environment['SHOT_DIR'] ?? '/tmp/shots-smoke');
    dir.createSync(recursive: true);
    File('${dir.path}/00-smoke.png').writeAsBytesSync(png);
    // ignore: avoid_print
    print('WROTE ${dir.path}/00-smoke.png ${png.length} bytes');
  });
}
