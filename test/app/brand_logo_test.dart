import 'dart:ui' as ui;

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:segmeris/src/app/brand_logo.dart';

void main() {
  test('light and dark preserve different source geometry', () {
    final light = BrandArtwork.forBrightness(Brightness.light);
    final dark = BrandArtwork.forBrightness(Brightness.dark);
    expect(light.paths, hasLength(7));
    expect(dark.paths, hasLength(3));
    expect(light.metrics, hasLength(7));
    expect(dark.metrics, hasLength(3));
    expect(light.paths.first.getBounds(), isNot(dark.paths.first.getBounds()));
    expect(
      identical(light, BrandArtwork.forBrightness(Brightness.light)),
      isTrue,
    );
  });

  testWidgets('responds to system brightness despite manual app theme', (
    tester,
  ) async {
    final dispatcher = tester.binding.platformDispatcher;
    dispatcher.platformBrightnessTestValue = Brightness.light;
    addTearDown(dispatcher.clearPlatformBrightnessTestValue);
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(),
        home: const Center(child: BrandLogo()),
      ),
    );
    BrandLogoPainter painter() =>
        tester
                .widget<CustomPaint>(
                  find.descendant(
                    of: find.byType(BrandLogo),
                    matching: find.byType(CustomPaint),
                  ),
                )
                .painter!
            as BrandLogoPainter;
    expect(painter().brightness, Brightness.light);
    expect(painter().transparent, isFalse);
    dispatcher.platformBrightnessTestValue = Brightness.dark;
    await tester.pump();
    expect(painter().brightness, Brightness.dark);
  });

  test(
    'default surface preserves contrast when app and system themes differ',
    () async {
      for (final brightness in Brightness.values) {
        final recorder = ui.PictureRecorder();
        const size = Size.square(32);
        BrandLogoPainter(brightness: brightness).paint(Canvas(recorder), size);
        final picture = recorder.endRecording();
        final image = await picture.toImage(32, 32);
        final bytes = (await image.toByteData())!.buffer.asUint8List();
        // The untouched corner is the source's opaque background.
        expect(bytes[0], brightness == Brightness.dark ? 0 : 255);
        expect(bytes[3], 255);
        image.dispose();
        picture.dispose();
      }
    },
  );
}
