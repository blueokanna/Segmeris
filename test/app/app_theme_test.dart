import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:segmeris/src/app/app_theme.dart';
import 'package:segmeris/src/home/home_widgets.dart';

void main() {
  testWidgets('long chip labels wrap within narrow large-text layouts', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(appThemeProfiles.first, Brightness.light),
        home: const Scaffold(
          body: MediaQuery(
            data: MediaQueryData(textScaler: TextScaler.linear(2)),
            child: Center(
              child: SizedBox(
                width: 216,
                child: Wrap(
                  children: [
                    MiniChip(label: 'YouTube · Bilibili'),
                    MiniChip(
                      label: 'Long localized hardware decoder capabilities',
                      icon: Icons.memory_rounded,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(MiniChip), findsNWidgets(2));
    expect(tester.takeException(), isNull);
    for (final element in find.byType(MiniChip).evaluate()) {
      expect(
        tester.getSize(find.byWidget(element.widget)).width,
        lessThanOrEqualTo(216),
      );
    }
  });

  test('system typography follows each platform default', () {
    final original = debugDefaultTargetPlatformOverride;
    try {
      for (final platform in TargetPlatform.values) {
        debugDefaultTargetPlatformOverride = platform;
        final theme = buildAppTheme(appThemeProfiles.first, Brightness.light);
        final expected = ThemeData(useMaterial3: true).textTheme.bodyMedium!;
        expect(
          theme.textTheme.bodyMedium!.fontFamily,
          expected.fontFamily,
          reason: platform.name,
        );
        expect(
          theme.primaryTextTheme.bodyMedium!.fontFamily,
          expected.fontFamily,
          reason: platform.name,
        );
      }
    } finally {
      debugDefaultTargetPlatformOverride = original;
    }
  });

  test('mixed font uses Google Latin with genuine Huawei CJK fallback', () {
    final custom = buildAppTheme(
      appThemeProfiles.first,
      Brightness.light,
      font: AppFont.harmonyGoogle,
    );
    for (final style in [
      custom.textTheme.bodyMedium,
      custom.textTheme.titleLarge,
      custom.primaryTextTheme.labelLarge,
    ]) {
      expect(style!.fontFamily, 'Google Sans Flex');
      expect(style.fontFamilyFallback, ['HarmonyOS Sans SC']);
    }
    final system = buildAppTheme(appThemeProfiles.first, Brightness.light);
    expect(system.textTheme.bodyMedium!.fontFamily, isNot('Google Sans Flex'));
    expect(
      system.textTheme.bodyMedium!.fontFamilyFallback,
      isNot(contains('HarmonyOS Sans SC')),
    );
  });

  test('dynamic themes retain supplied system color roles', () {
    final dynamicScheme = ColorScheme.fromSeed(seedColor: Colors.purple)
        .copyWith(secondary: const Color(0xff135799));
    final theme = buildAppTheme(
      appThemeProfiles.first,
      Brightness.light,
      dynamicScheme: dynamicScheme,
    );
    expect(theme.colorScheme.primary, dynamicScheme.primary);
    expect(theme.colorScheme.secondary, dynamicScheme.secondary);
  });

  testWidgets('TickerMode hides no content and schedules no reveal frames', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: TickerMode(
          enabled: false,
          child: RevealMotion(child: Text('Ready')),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Ready'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(RevealMotion),
        matching: find.byType(FadeTransition),
      ),
      findsNothing,
    );
    expect(tester.binding.transientCallbackCount, 0);
  });

  testWidgets(
    'reduced motion freezes indeterminate progress without reporting completion',
    (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: MediaQuery(
            data: MediaQueryData(disableAnimations: true),
            child: SmoothLinearProgressIndicator(value: null),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<LinearProgressIndicator>(
              find.byType(LinearProgressIndicator),
            )
            .value,
        isNull,
      );
      expect(tester.binding.transientCallbackCount, 0);
    },
  );

  testWidgets(
    'status indicators do not maintain decorative repeating tickers',
    (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: StatusPulseDot(color: Colors.green, active: true),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.binding.transientCallbackCount, 0);
    },
  );

  testWidgets('enabling animations does not replay already visible content', (
    tester,
  ) async {
    Widget view(bool reduced) => MaterialApp(
      home: MediaQuery(
        data: MediaQueryData(disableAnimations: reduced),
        child: const RevealMotion(child: Text('Already visible')),
      ),
    );
    await tester.pumpWidget(view(true));
    await tester.pumpAndSettle();
    await tester.pumpWidget(view(false));
    final fade = tester.widget<FadeTransition>(
      find.descendant(
        of: find.byType(RevealMotion),
        matching: find.byType(FadeTransition),
      ),
    );
    expect(fade.opacity.value, 1);
    expect(tester.binding.transientCallbackCount, 0);
  });

  test('every palette keeps readable Material 3 surfaces in both modes', () {
    for (final profile in appThemeProfiles) {
      for (final brightness in Brightness.values) {
        final theme = buildAppTheme(profile, brightness);
        expect(theme.useMaterial3, isTrue);
        final foreground = theme.colorScheme.onSurface.computeLuminance();
        for (final surface in [
          theme.colorScheme.surface,
          theme.colorScheme.surfaceContainerHigh,
          theme.colorScheme.surfaceContainerHighest,
        ]) {
          final background = surface.computeLuminance();
          final ratio = foreground > background
              ? (foreground + 0.05) / (background + 0.05)
              : (background + 0.05) / (foreground + 0.05);
          expect(
            ratio,
            greaterThanOrEqualTo(4.5),
            reason: '${profile.id} / $brightness',
          );
        }
      }
    }
  });

  testWidgets('reduced motion reveals content and stops status pulses', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(appThemeProfiles.first, Brightness.light),
        home: const MediaQuery(
          data: MediaQueryData(
            disableAnimations: true,
            textScaler: TextScaler.linear(2),
          ),
          child: Scaffold(
            body: Column(
              children: [
                RevealMotion(child: Text('下载 Download')),
                StatusPulseDot(color: Colors.green, active: true),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      find.descendant(
        of: find.byType(RevealMotion),
        matching: find.byType(FadeTransition),
      ),
      findsNothing,
    );
    expect(tester.binding.transientCallbackCount, 0);
    expect(tester.takeException(), isNull);
  });

  test('keeps monet and amoled theme profiles available', () {
    final ids = appThemeProfiles.map((profile) => profile.id).toSet();

    expect(ids, contains('monet_flow'));
    expect(ids, contains('amoled_monet'));
    expect(ids, contains('amoled_pantone'));
    expect(
      appThemeProfiles
          .firstWhere((profile) => profile.id == 'monet_flow')
          .supportsDynamicColor,
      isTrue,
    );
    expect(
      appThemeProfiles
          .firstWhere((profile) => profile.id == 'amoled_monet')
          .useAmoledSurface,
      isTrue,
    );
    expect(
      appThemeProfiles
          .firstWhere((profile) => profile.id == 'amoled_pantone')
          .useAmoledSurface,
      isTrue,
    );
  });
}
