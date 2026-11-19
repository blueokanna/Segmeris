import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:segmeris/src/app/app_localizations.dart';
import 'package:segmeris/src/app/app_settings.dart';
import 'package:segmeris/src/app/app_theme.dart';
import 'package:segmeris/src/home/auth_context_editor.dart';
import 'package:segmeris/src/home/home_settings_sheet.dart';
import 'package:segmeris/src/home/home_widgets.dart';

import '../support/capability_fixture.dart';

const _settings = AppSettings(
  themeProfileId: 'monet_flow',
  themeMode: ThemeMode.light,
  localeTag: 'en',
  autoOpenAuthBrowser: true,
  apiBaseUrl: 'http://localhost:3000',
  apiToken: '',
);

void main() {
  testWidgets('appearance applies while downloading and auth stays locked', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1000, 1800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final controllers = List.generate(5, (_) => TextEditingController());
    for (final controller in controllers) {
      addTearDown(controller.dispose);
    }
    final auth = ValueNotifier(0);
    addTearDown(auth.dispose);
    var current = _settings;
    await tester.pumpWidget(
      StatefulBuilder(
        builder: (context, setState) {
          return MaterialApp(
            locale: current.locale,
            supportedLocales: AppLocalizations.supportedLocales,
            localizationsDelegates: const [
              AppLocalizations.delegate,
              ...GlobalMaterialLocalizations.delegates,
            ],
            theme: buildAppTheme(
              current.themeProfile,
              Brightness.light,
              font: current.font,
            ),
            darkTheme: buildAppTheme(
              current.themeProfile,
              Brightness.dark,
              font: current.font,
            ),
            themeMode: current.themeMode,
            home: Scaffold(
              body: HomeSettingsSheet(
                settings: current,
                enabled: false,
                onSettingsChanged: (next) => setState(() => current = next),
                onOpenBrowser: () async {},
                onQrLogin: () async {},
                onClearContext: () {},
                authContextListenable: auth,
                authContextBadges: () => [],
                hasAuthContextOverrides: () => false,
                userAgentController: controllers[0],
                refererController: controllers[1],
                originController: controllers[2],
                cookieController: controllers[3],
                headersController: controllers[4],
                capabilityProbe: unknownCapabilities,
              ),
            ),
          );
        },
      ),
    );
    await tester.pumpAndSettle();
    final mode = find.byType(SegmentedButton<ThemeMode>);
    expect(
      tester.widget<SegmentedButton<ThemeMode>>(mode).onSelectionChanged,
      isNotNull,
    );
    await tester.ensureVisible(mode);
    await tester.tap(find.text('Dark'));
    await tester.pumpAndSettle();
    expect(current.themeMode, ThemeMode.dark);
    expect(
      Theme.of(tester.element(find.byType(HomeSettingsSheet))).brightness,
      Brightness.dark,
    );

    final palettes = tester.widgetList<ThemePaletteCard>(
      find.byType(ThemePaletteCard),
    );
    expect(palettes.every((card) => card.onTap != null), isTrue);
    palettes
        .firstWhere((card) => card.profile.id != current.themeProfileId)
        .onTap!();
    await tester.pumpAndSettle();
    expect(current.themeProfileId, isNot(_settings.themeProfileId));

    final fontFinder = find.byKey(const ValueKey('settings-font'));
    final fonts = tester.widget<DropdownMenu<AppFont>>(fontFinder);
    expect(fonts.enabled, isTrue);
    expect(fonts.dropdownMenuEntries.map((item) => item.value), AppFont.values);
    fonts.onSelected!(AppFont.harmonyGoogle);
    await tester.pumpAndSettle();
    expect(current.font, AppFont.harmonyGoogle);
    final text = Theme.of(tester.element(find.byType(HomeSettingsSheet)))
        .textTheme
        .bodyMedium!;
    expect(text.fontFamily, 'Google Sans Flex');
    expect(text.fontFamilyFallback, ['HarmonyOS Sans SC']);

    final retention = tester.widget<DropdownMenu<int>>(
      find.byKey(const ValueKey('settings-history-retention')),
    );
    expect(retention.enabled, isTrue);
    expect(
      retention.dropdownMenuEntries.map((item) => item.value),
      AppSettings.allowedHistoryRetentionDays,
    );
    retention.onSelected!(365);
    await tester.pumpAndSettle();
    expect(current.historyRetentionDays, 365);
    expect(
      find.text(
        AppLocalizations.of(tester.element(find.byType(HomeSettingsSheet)))
            .text('history_retention_hint'),
      ),
      findsOneWidget,
    );

    final languages = tester.widget<DropdownMenu<Locale>>(
      find.byType(DropdownMenu<Locale>),
    );
    expect(languages.enabled, isTrue);
    languages.onSelected!(const Locale('zh'));
    await tester.pumpAndSettle();
    final localized = AppLocalizations.of(
      tester.element(find.byType(HomeSettingsSheet)),
    );
    final fontText = tester.widget<TextField>(
      find.descendant(of: fontFinder, matching: find.byType(TextField)).first,
    );
    expect(fontText.controller!.text, localized.text('font_harmony_google'));
    final retentionText = tester.widget<TextField>(
      find
          .descendant(
            of: find.byKey(const ValueKey('settings-history-retention')),
            matching: find.byType(TextField),
          )
          .first,
    );
    expect(
      retentionText.controller!.text,
      localized.text('history_retention_days').replaceAll('{days}', '365'),
    );
    final authPanel = tester.widget<AuthorizationSettingsPanel>(
      find.byType(AuthorizationSettingsPanel),
    );
    expect(authPanel.enabled, isFalse);
    expect(authPanel.onAutoOpenChanged, isNull);
    expect(tester.takeException(), isNull);

    tester.view.physicalSize = const Size(320, 740);
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await tester.pumpAndSettle();
    expect(
      tester.widget<SegmentedButton<ThemeMode>>(mode).direction,
      Axis.vertical,
    );
    expect(tester.takeException(), isNull);
  });
}
