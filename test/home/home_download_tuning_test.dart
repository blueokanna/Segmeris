import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:segmeris/src/app/app_theme.dart';
import 'package:segmeris/src/home/home_download_tuning.dart';

import '../widget_test_harness.dart';

void main() {
  testWidgets('collapsed tuning validates and reveals invalid fields', (
    tester,
  ) async {
    final form = GlobalKey<FormState>();
    final controllers = [
      TextEditingController(text: '4'),
      TextEditingController(text: '3'),
      TextEditingController(text: '0'),
      TextEditingController(text: '0'),
    ];
    addTearDown(() {
      for (final controller in controllers) {
        controller.dispose();
      }
    });
    await tester.pumpWidget(
      buildTestHarness(
        profile: appThemeProfiles.first,
        child: Form(
          key: form,
          child: HomeDownloadTuning(
            concurrencyController: controllers[0],
            retriesController: controllers[1],
            videoBitrateController: controllers[2],
            audioBitrateController: controllers[3],
            enabled: true,
            keepTemp: false,
            onKeepTempChanged: (_) {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(TextFormField), findsNothing);
    expect(form.currentState!.validate(), isTrue);
    controllers[0].text = '64';
    controllers[1].text = '0';
    controllers[2].text = '20001';
    controllers[3].text = '513';
    expect(form.currentState!.validate(), isFalse);
    await tester.pumpAndSettle();
    expect(find.byType(TextFormField), findsNWidgets(4));
    expect(find.text('1–16'), findsOneWidget);
    expect(find.text('1–10'), findsOneWidget);
    expect(find.text('0–20000'), findsOneWidget);
    expect(find.text('0–512'), findsOneWidget);
    controllers[0].text = '8';
    controllers[1].text = '3';
    controllers[2].text = '8000';
    controllers[3].text = '192';
    expect(form.currentState!.validate(), isTrue);
    await tester.tap(find.text('Download options'));
    await tester.pumpAndSettle();
    expect(find.byType(TextFormField), findsNothing);
    await tester.tap(find.text('Download options'));
    await tester.pumpAndSettle();
    expect(find.text('8000'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
