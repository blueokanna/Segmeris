import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:segmeris/src/app/app_localizations.dart';
import 'package:segmeris/src/app/app_settings.dart';
import 'package:segmeris/src/app/app_theme.dart';
import 'package:segmeris/src/app/download_engine.dart';
import 'package:segmeris/src/home/home_page.dart';
import 'package:segmeris/src/home/home_settings_sheet.dart';

import '../support/capability_fixture.dart';

const _settings = AppSettings(
  themeProfileId: 'monet_flow',
  themeMode: ThemeMode.light,
  localeTag: 'zh',
  autoOpenAuthBrowser: true,
  apiBaseUrl: defaultApiBaseUrl,
  apiToken: '',
);

ThemeData _captureTheme() {
  final theme = buildAppTheme(_settings.themeProfile, Brightness.light);
  if (!Platform.environment.containsKey('SEGMERIS_CAPTURE_FONT')) {
    return theme;
  }
  TextStyle? withFont(TextStyle? style) =>
      style?.copyWith(fontFamily: 'SegmerisCapture');
  ButtonStyle? buttonFont(ButtonStyle? style) => style?.copyWith(
    textStyle: WidgetStateProperty.resolveWith(
      (states) => withFont(style.textStyle?.resolve(states)),
    ),
  );
  return theme.copyWith(
    textTheme: theme.textTheme.apply(fontFamily: 'SegmerisCapture'),
    primaryTextTheme: theme.primaryTextTheme.apply(
      fontFamily: 'SegmerisCapture',
    ),
    appBarTheme: theme.appBarTheme.copyWith(
      titleTextStyle: withFont(theme.appBarTheme.titleTextStyle),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: buttonFont(theme.filledButtonTheme.style),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: buttonFont(theme.outlinedButtonTheme.style),
    ),
    textButtonTheme: TextButtonThemeData(
      style: buttonFont(theme.textButtonTheme.style),
    ),
  );
}

Widget _buildApp(Key captureKey) {
  return RepaintBoundary(
    key: captureKey,
    child: MaterialApp(
      debugShowCheckedModeBanner: false,
      locale: _settings.locale,
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      theme: _captureTheme(),
      home: HomePage(
        settings: _settings,
        onSettingsChanged: (_) {},
        capabilityProbe: unknownCapabilities,
      ),
    ),
  );
}

Future<void> _capture(Finder finder, String fileName) async {
  if (Platform.environment['SEGMERIS_CAPTURE_UI'] != '1' &&
      Platform.environment['FERRIS_CAPTURE_UI'] != '1') {
    return;
  }
  await expectLater(
    finder,
    matchesGoldenFile('../../.dart_cli_state/$fileName'),
  );
}

void main() {
  setUpAll(() async {
    for (final entry in {
      'SEGMERIS_CAPTURE_FONT': 'SegmerisCapture',
      'SEGMERIS_CAPTURE_ICONS': 'MaterialIcons',
    }.entries) {
      final path = Platform.environment[entry.key];
      if (path != null) {
        final loader = FontLoader(entry.value)
          ..addFont(File(path).readAsBytes().then(ByteData.sublistView));
        await loader.load();
      }
    }
  });

  for (final viewport in <(String, Size)>[
    ('narrow', const Size(320, 740)),
    ('mobile', const Size(390, 844)),
    ('desktop', const Size(1440, 900)),
    ('ultrawide', const Size(2560, 1440)),
  ]) {
    testWidgets('home page has no overflow at ${viewport.$1} size', (
      tester,
    ) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = viewport.$2;
      addTearDown(tester.view.reset);

      final captureKey = GlobalKey();
      await tester.pumpWidget(_buildApp(captureKey));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.byType(HomePage), findsOneWidget);
      await _capture(find.byKey(captureKey), 'home_${viewport.$1}.png');
    });
  }

  testWidgets('home supports large accessibility text on mobile', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 844);
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.view.reset);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await tester.pumpWidget(_buildApp(GlobalKey()));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.drag(find.byType(ListView).first, const Offset(0, -600));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('mobile source actions and settings sheet have no overflow', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.reset);

    final captureKey = GlobalKey();
    await tester.pumpWidget(_buildApp(captureKey));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byType(TextFormField).first,
      '【哔哩哔哩】一个很长的分享标题 https://b23.tv/fixture?share_source=copy_web',
    );
    await tester.pump();
    expect(find.byIcon(Icons.close_rounded), findsOneWidget);
    expect(find.byIcon(Icons.content_paste_rounded), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.tap(find.widgetWithIcon(IconButton, Icons.tune_rounded));
    await tester.pumpAndSettle();
    expect(find.byType(HomeSettingsSheet), findsOneWidget);
    final palette = find.byKey(const ValueKey('theme-palette-scroll'));
    await tester.ensureVisible(palette);
    await tester.pumpAndSettle();
    final list = tester.widget<ListView>(palette);
    expect(list.controller!.offset, 0);
    await tester.drag(
      palette,
      const Offset(-180, 0),
      kind: PointerDeviceKind.mouse,
    );
    await tester.pumpAndSettle();
    expect(list.controller!.offset, greaterThan(0));
    final beforeWheel = list.controller!.offset;
    await tester.sendEventToBinding(
      PointerScrollEvent(
        position: tester.getCenter(palette),
        scrollDelta: const Offset(0, 80),
      ),
    );
    await tester.pumpAndSettle();
    expect(list.controller!.offset, greaterThan(beforeWheel));
    expect(tester.takeException(), isNull);
    await _capture(find.byKey(captureKey), 'home_settings_mobile.png');
  });
}
