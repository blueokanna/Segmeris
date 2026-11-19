import 'dart:ui' as ui;

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:segmeris/main.dart';
import 'package:segmeris/src/app/app_settings.dart';
import 'package:segmeris/src/app/startup_motion.dart';

Widget host({
  bool ready = false,
  bool disabled = false,
  bool ticker = true,
  double textScale = 1,
  String label = 'Segmeris',
}) => MaterialApp(
  home: MediaQuery(
    data: MediaQueryData(
      disableAnimations: disabled,
      textScaler: TextScaler.linear(textScale),
    ),
    child: TickerMode(
      enabled: ticker,
      child: StartupMotion(
        ready: ready,
        label: label,
        child: const Text('initialized'),
      ),
    ),
  ),
);

StartupLogoPainter motionPainter(WidgetTester tester) =>
    tester
            .widget<CustomPaint>(
              find.byWidgetPredicate(
                (widget) =>
                    widget is CustomPaint &&
                    widget.painter is StartupLogoPainter,
              ),
            )
            .painter!
        as StartupLogoPainter;

void main() {
  testWidgets('fast bootstrap draws the moving system mark before handoff', (
    tester,
  ) async {
    const settings = AppSettings(
      themeProfileId: 'monet_flow',
      themeMode: ThemeMode.light,
      localeTag: 'en',
      autoOpenAuthBrowser: false,
      apiBaseUrl: '',
      apiToken: '',
    );
    var initialized = false;
    await tester.pumpWidget(
      SegmerisBootstrap(
        initialize: () async {
          initialized = true;
          return settings;
        },
      ),
    );
    await tester.pump();
    expect(initialized, isTrue);
    final first = motionPainter(tester).progress.value;
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
    addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
    await tester.pump(const Duration(milliseconds: 150));
    expect(motionPainter(tester).brightness, Brightness.dark);
    expect(motionPainter(tester).progress.value, greaterThan(first));
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('clock repaints without rebuilding the widget tree', (
    tester,
  ) async {
    await tester.pumpWidget(host());
    final first = motionPainter(tester);
    final before = first.progress.value;
    await tester.pump(const Duration(milliseconds: 91));
    expect(identical(first, motionPainter(tester)), isTrue);
    expect(first.progress.value, greaterThan(before));
    await tester.pumpWidget(const SizedBox.shrink());
    expect(tester.binding.transientCallbackCount, 0);
  });

  testWidgets('ready hands off immediately, without minimum animation time', (
    tester,
  ) async {
    await tester.pumpWidget(host());
    await tester.pump(const Duration(milliseconds: 7));
    await tester.pumpWidget(host(ready: true));
    expect(find.text('initialized'), findsOneWidget);
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is CustomPaint && widget.painter is StartupLogoPainter,
      ),
      findsNothing,
    );
    expect(tester.binding.transientCallbackCount, 0);
  });

  testWidgets('reduced motion is static immediately, including mid-animation', (
    tester,
  ) async {
    await tester.pumpWidget(host());
    await tester.pump(const Duration(milliseconds: 143));
    await tester.pumpWidget(host(disabled: true));
    final painter = motionPainter(tester);
    expect(painter.animate, isFalse);
    final value = painter.progress.value;
    await tester.pump(const Duration(seconds: 5));
    expect(painter.progress.value, value);
    expect(tester.binding.transientCallbackCount, 0);
    await tester.pumpWidget(host(ready: true, disabled: true));
    expect(find.text('initialized'), findsOneWidget);
  });

  testWidgets('hidden and background startup consumes no animation frames', (
    tester,
  ) async {
    await tester.pumpWidget(host());
    await tester.pump(const Duration(milliseconds: 120));
    await tester.pumpWidget(host(ticker: false));
    var painter = motionPainter(tester);
    final hidden = painter.progress.value;
    await tester.pump(const Duration(seconds: 2));
    expect(painter.progress.value, hidden);
    expect(tester.binding.transientCallbackCount, 0);
    await tester.pumpWidget(host());
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    final paused = motionPainter(tester).progress.value;
    await tester.pump(const Duration(seconds: 2));
    expect(motionPainter(tester).progress.value, paused);
    expect(tester.binding.transientCallbackCount, 0);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 55));
    painter = motionPainter(tester);
    expect(painter.progress.value, isNot(paused));
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('short windows retain enlarged text without overflow', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(260, 130);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      host(disabled: true, textScale: 4, label: 'Segmeris 初始化正在进行'),
    );
    expect(tester.takeException(), isNull);
    expect(find.byType(SingleChildScrollView), findsOneWidget);
    expect(find.text('Segmeris 初始化正在进行'), findsOneWidget);
  });

  test(
    'nearby clock values produce different continuously trimmed vector frames',
    () async {
      Future<List<int>> pixels(double value, Brightness brightness) async {
        final recorder = ui.PictureRecorder();
        StartupLogoPainter(
          brightness: brightness,
          progress: AlwaysStoppedAnimation(value),
          animate: true,
        ).paint(Canvas(recorder), const Size.square(240));
        final picture = recorder.endRecording();
        final image = await picture.toImage(240, 240);
        final result = (await image.toByteData())!.buffer
            .asUint8List()
            .toList();
        image.dispose();
        picture.dispose();
        return result;
      }

      for (final brightness in Brightness.values) {
        final a = await pixels(0.31, brightness);
        final b = await pixels(0.315, brightness);
        expect(a, isNot(orderedEquals(b)));
        final changed = Iterable<int>.generate(a.length)
            .where((index) => a[index] != b[index])
            .length;
        expect(changed, greaterThan(20));
        expect(changed, lessThan(a.length ~/ 3));
      }
    },
  );
}
