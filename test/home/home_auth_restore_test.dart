import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:segmeris/src/app/app_localizations.dart';
import 'package:segmeris/src/app/app_settings.dart';
import 'package:segmeris/src/app/app_theme.dart';
import 'package:segmeris/src/app/auth_context_store.dart';
import 'package:segmeris/src/app/download_engine.dart';
import 'package:segmeris/src/home/home_page.dart';
import 'package:segmeris/src/home/home_settings_sheet.dart';
import 'package:segmeris/src/rust/api/downloader.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _settings = AppSettings(
  themeProfileId: 'monet_flow',
  themeMode: ThemeMode.light,
  localeTag: 'zh',
  autoOpenAuthBrowser: true,
  apiBaseUrl: defaultApiBaseUrl,
  apiToken: '',
);

Widget _buildApp() {
  return MaterialApp(
    debugShowCheckedModeBanner: false,
    locale: _settings.locale,
    supportedLocales: AppLocalizations.supportedLocales,
    localizationsDelegates: const [
      AppLocalizations.delegate,
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
    ],
    theme: buildAppTheme(_settings.themeProfile, Brightness.light),
    home: HomePage(settings: _settings, onSettingsChanged: (_) {}),
  );
}

/// Open the settings sheet, which is where the authorization context lives.
Future<void> _openSettings(WidgetTester tester) async {
  await tester.tap(find.widgetWithIcon(IconButton, Icons.tune_rounded));
  await tester.pumpAndSettle();
  expect(find.byType(HomeSettingsSheet), findsOneWidget);
}

void main() {
  testWidgets('a stored session is back in the editor on the next launch', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'authContext':
          '{"v":1,"ua":"SegmerisTest/1","referer":"https://www.bilibili.com/",'
          '"origin":"https://www.bilibili.com","cookie":"SESSDATA=stored",'
          '"headers":[{"name":"X-Trace","value":"1"}]}',
    });
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(420, 900);
    addTearDown(tester.view.reset);

    await tester.pumpWidget(_buildApp());
    await tester.pumpAndSettle();
    await _openSettings(tester);

    // Restored into the very fields the engine reads the context from.
    expect(find.text('SESSDATA=stored'), findsOneWidget);
    expect(find.text('SegmerisTest/1'), findsOneWidget);
    // Headers come back in the format they are edited in.
    expect(find.text('X-Trace: 1'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('nothing is restored when no session was stored', (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(420, 900);
    addTearDown(tester.view.reset);

    await tester.pumpWidget(_buildApp());
    await tester.pumpAndSettle();
    await _openSettings(tester);

    expect(find.text('SESSDATA=stored'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('clearing the session also drops the stored copy', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await AuthContextStore.save(
      const RequestContext(
        userAgent: 'SegmerisTest/1',
        referer: 'https://www.bilibili.com/',
        origin: 'https://www.bilibili.com',
        cookie: 'SESSDATA=stored',
        headers: [],
      ),
    );
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(420, 900);
    addTearDown(tester.view.reset);

    await tester.pumpWidget(_buildApp());
    await tester.pumpAndSettle();
    await _openSettings(tester);

    final clearButton = find.text('清空已导入会话');
    await tester.ensureVisible(clearButton);
    await tester.pumpAndSettle();
    await tester.tap(clearButton);
    await tester.pumpAndSettle();
    expect(await AuthContextStore.load(), isNull);
  });
}
