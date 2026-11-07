import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:segmeris/src/app/app_theme.dart';
import 'package:segmeris/src/home/home_widgets.dart';

void main() {
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
