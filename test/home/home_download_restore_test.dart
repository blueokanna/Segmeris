import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:segmeris/src/app/app_localizations.dart';
import 'package:segmeris/src/app/app_settings.dart';
import 'package:segmeris/src/app/app_theme.dart';
import 'package:segmeris/src/app/download_engine.dart';
import 'package:segmeris/src/app/download_state_store.dart';
import 'package:segmeris/src/home/download_session.dart';
import 'package:segmeris/src/home/download_task_request.dart';
import 'package:segmeris/src/home/home_download_tasks_card.dart';
import 'package:segmeris/src/home/home_page.dart';
import 'package:segmeris/src/home/home_page_controller.dart';
import 'package:segmeris/src/home/home_widgets.dart';
import 'package:segmeris/src/rust/api/downloader.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/capability_fixture.dart';

const _settings = AppSettings(
  themeProfileId: 'monet_flow',
  themeMode: ThemeMode.light,
  localeTag: 'en',
  autoOpenAuthBrowser: false,
  apiBaseUrl: defaultApiBaseUrl,
  apiToken: '',
);
const _context = RequestContext(
  userAgent: '',
  referer: '',
  origin: '',
  cookie: '',
  headers: [],
);
const _request = DownloadTaskRequest(
  pageUrl: 'https://example.com/video.mp4',
  mediaUrl: 'https://example.com/video.mp4',
  audioUrl: null,
  output: '/durable/video.mp4',
  chosenDir: '/durable',
  options: DownloadOptions(
    concurrency: 6,
    retries: 5,
    videoBitrate: 0,
    audioBitrate: 0,
    keepTemp: false,
    subtitleMode: SubtitleMode.off,
    subtitleValue: '',
  ),
  requestContext: _context,
  fileName: 'video.mp4',
  sourcePage: 'https://example.com/video.mp4',
);

class _Engine extends DownloadEngine {
  final progress = StreamController<ProgressUpdate>();
  final started = <String>[];
  final optionsSeen = <DownloadOptions>[];
  @override
  Future<void> init() async {}
  @override
  bool get writesLocalFiles => false;
  @override
  String? get lastResultPath => '/durable/video.mp4';
  @override
  Future<MediaInspectionResult> inspect({
    required String url,
    required RequestContext requestContext,
  }) async => throw StateError('Direct file must not be reinterpreted');
  @override
  Stream<ProgressUpdate> download({
    required String pageUrl,
    required String mediaUrl,
    List<String> mediaFallbackUrls = const [],
    String? audioUrl,
    List<String> audioFallbackUrls = const [],
    required String output,
    required DownloadOptions options,
    required RequestContext requestContext,
  }) {
    started.add(output);
    optionsSeen.add(options);
    return progress.stream;
  }
}

Widget _app(DownloadStateStore store, _Engine engine) => MaterialApp(
  locale: const Locale('en'),
  localizationsDelegates: const [
    AppLocalizations.delegate,
    ...GlobalMaterialLocalizations.delegates,
  ],
  supportedLocales: AppLocalizations.supportedLocales,
  theme: buildAppTheme(_settings.themeProfile, Brightness.light),
  home: HomePage(
    settings: _settings,
    onSettingsChanged: (_) {},
    capabilityProbe: unknownCapabilities,
    downloadEngine: engine,
    stateStore: store,
  ),
);

Map<String, dynamic> _snapshot({bool paused = false}) => DownloadSession(
  tasks: [
    HomeDownloadTask(
      id: 'durable',
      fileName: 'video.mp4',
      sourcePage: _request.pageUrl,
      status: 'Downloading media',
      progress: .45,
      stage: HomeWorkflowStage.transfer,
      startedAt: DateTime(2026),
      running: true,
      paused: paused,
    ),
  ],
  history: [
    DownloadRecord(
      taskId: 'old',
      name: 'old.mp4',
      source: _request.pageUrl,
      path: '/durable/old.mp4',
      time: DateTime(2026),
    ),
  ],
  requests: const {'durable': _request},
).toJson();

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets(
    'restart resumes original output and parameters, then persists completion',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1440, 900);
      addTearDown(tester.view.reset);
      final store = MemoryDownloadStateStore(initialData: _snapshot());
      final engine = _Engine();
      await _request.saveCredentials('durable');
      await tester.pumpWidget(_app(store, engine));
      await tester.pumpAndSettle();
      expect(engine.started, ['/durable/video.mp4']);
      expect(engine.optionsSeen.single.concurrency, 6);
      engine.progress.add(
        const ProgressUpdate(message: 'Completed', progress: 1),
      );
      await engine.progress.close();
      await tester.pumpAndSettle();
      final restored = await DownloadSession.fromJson((await store.load())!);
      expect(restored.history.map((item) => item.name), [
        'video.mp4',
        'old.mp4',
      ]);
      expect(restored.tasks.single.stage, HomeWorkflowStage.completed);
      expect(restored.requests, isEmpty);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'explicit pause survives restart and resumes only on user action',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1440, 900);
      addTearDown(tester.view.reset);
      final store = MemoryDownloadStateStore(
        initialData: _snapshot(paused: true),
      );
      final engine = _Engine();
      await tester.pumpWidget(_app(store, engine));
      await tester.pumpAndSettle();
      expect(engine.started, isEmpty);
      final card = tester.widget<HomeDownloadTasksCard>(
        find.byType(HomeDownloadTasksCard),
      );
      expect(card.tasks.single.interrupted, isTrue);
      card.onRetry('durable');
      await tester.pumpAndSettle();
      expect(engine.started, ['/durable/video.mp4']);
      engine.progress.add(
        const ProgressUpdate(
          message: 'Failed',
          progress: .45,
          error: 'Network unavailable',
        ),
      );
      unawaited(engine.progress.close());
      await tester.pumpAndSettle();
      final restored = await DownloadSession.fromJson((await store.load())!);
      expect(restored.tasks.single.error, 'Network unavailable');
      expect(restored.requests.keys, ['durable']);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );
}
