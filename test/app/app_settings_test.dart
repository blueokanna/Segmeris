import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:segmeris/src/app/app_settings.dart';
import 'package:segmeris/src/app/app_theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _settings = AppSettings(
  themeProfileId: 'monet_flow',
  themeMode: ThemeMode.system,
  localeTag: 'zh',
  autoOpenAuthBrowser: true,
  apiBaseUrl: 'http://localhost:3000',
  apiToken: '',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  test(
    'legacy constructors and preferences default to system font and no cleanup',
    () async {
      expect(_settings.font, AppFont.system);
      expect(_settings.historyRetentionDays, 0);
      final loaded = await AppSettings.load();
      expect(loaded.font, AppFont.system);
      expect(loaded.historyRetentionDays, 0);
    },
  );

  test(
    'font and every supported retention period survive persistence',
    () async {
      expect(AppSettings.allowedHistoryRetentionDays, [
        0,
        1,
        3,
        5,
        7,
        15,
        30,
        60,
        90,
        180,
        365,
      ]);
      for (final days in AppSettings.allowedHistoryRetentionDays) {
        await _settings
            .copyWith(font: AppFont.harmonyGoogle, historyRetentionDays: days)
            .save();
        final loaded = await AppSettings.load();
        expect(loaded.font, AppFont.harmonyGoogle);
        expect(loaded.historyRetentionDays, days);
      }
    },
  );

  test(
    'invalid persisted values safely disable cleanup and custom typography',
    () async {
      SharedPreferences.setMockInitialValues({
        'font': 'obsolete',
        'historyRetentionDays': -2,
      });
      final loaded = await AppSettings.load();
      expect(loaded.font, AppFont.system);
      expect(loaded.historyRetentionDays, 0);
      expect(
        _settings.copyWith(historyRetentionDays: 2).historyRetentionDays,
        0,
      );
    },
  );

  test(
    'rapid saves preserve request order despite an earlier delayed write',
    () async {
      final firstWrite = Completer<void>();
      final started = <ThemeMode>[];
      AppSettings? persisted;
      final queue = AppSettingsSaveQueue(
        save: (settings) async {
          started.add(settings.themeMode);
          if (started.length == 1) await firstWrite.future;
          persisted = settings;
        },
      );
      final first = queue.enqueue(
        _settings.copyWith(themeMode: ThemeMode.light),
      );
      final second = queue.enqueue(
        _settings.copyWith(
          themeMode: ThemeMode.dark,
          font: AppFont.harmonyGoogle,
        ),
      );
      await Future<void>.delayed(Duration.zero);
      expect(started, [ThemeMode.light]);
      firstWrite.complete();
      await Future.wait([first, second]);
      expect(started, [ThemeMode.light, ThemeMode.dark]);
      expect(persisted!.themeMode, ThemeMode.dark);
      expect(persisted!.font, AppFont.harmonyGoogle);
    },
  );

  test('a failed save is reported without blocking the next save', () async {
    final completed = <ThemeMode>[];
    final queue = AppSettingsSaveQueue(
      save: (settings) async {
        if (settings.themeMode == ThemeMode.light) {
          throw StateError('disk failure');
        }
        completed.add(settings.themeMode);
      },
    );
    final failed = queue.enqueue(
      _settings.copyWith(themeMode: ThemeMode.light),
    );
    final recovered = queue.enqueue(
      _settings.copyWith(themeMode: ThemeMode.dark),
    );
    await expectLater(failed, throwsStateError);
    await recovered;
    expect(completed, [ThemeMode.dark]);
  });
}
