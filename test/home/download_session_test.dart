import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:segmeris/src/home/download_session.dart';
import 'package:segmeris/src/home/download_task_request.dart';
import 'package:segmeris/src/home/home_page_controller.dart';
import 'package:segmeris/src/home/home_widgets.dart';
import 'package:segmeris/src/rust/api/downloader.dart';
import 'package:shared_preferences/shared_preferences.dart';

const context = RequestContext(
  userAgent: 'agent',
  referer: 'https://example.com/',
  origin: '',
  cookie: 'session=private',
  headers: [HeaderEntry(name: 'Authorization', value: 'Bearer private')],
);
const request = DownloadTaskRequest(
  pageUrl: 'https://example.com/video',
  mediaUrl: 'https://cdn.example.com/video.mp4',
  audioUrl: null,
  output: '/stable/video.mp4',
  chosenDir: '/stable',
  options: DownloadOptions(
    concurrency: 6,
    retries: 5,
    videoBitrate: 0,
    audioBitrate: 0,
    keepTemp: false,
    subtitleMode: SubtitleMode.off,
    subtitleValue: '',
  ),
  requestContext: context,
  fileName: 'video.mp4',
  sourcePage: 'https://example.com/video',
);

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test(
    'journal round trip preserves unfinished work and vault credentials',
    () async {
      final controller = HomePageController();
      addTearDown(controller.dispose);
      final id = controller.beginDownloadTask(
        fileName: 'video.mp4',
        sourcePage: request.pageUrl,
        status: 'Preparing',
      );
      controller.updateDownloadTask(id, 'Downloading media', 0.45);
      controller.setTaskControl(id, paused: true, busy: true);
      await request.saveCredentials(id);
      final snapshot = DownloadSession(
        tasks: controller.value.downloadTasks,
        history: const [],
        requests: {id: request},
      ).toJson();
      final text = jsonEncode(snapshot);
      expect(text, isNot(contains('session=private')));
      expect(text, isNot(contains('Bearer private')));
      final restored = await DownloadSession.fromJson(
        jsonDecode(text) as Map<String, dynamic>,
      );
      expect(restored.tasks.single.running, isFalse);
      expect(restored.tasks.single.interrupted, isTrue);
      expect(restored.tasks.single.paused, isTrue);
      expect(restored.tasks.single.controlBusy, isFalse);
      expect(restored.tasks.single.progress, 0.45);
      expect(restored.requests[id]!.output, request.output);
      expect(restored.requests[id]!.options.concurrency, 6);
      expect(restored.requests[id]!.requestContext.cookie, context.cookie);
      controller.restoreDownloads(
        tasks: restored.tasks,
        history: restored.history,
      );
      expect(controller.retryDownloadTask(id, status: 'Restoring'), isTrue);
      expect(controller.value.downloadTasks.single.interrupted, isFalse);
    },
  );

  test(
    'completed history survives restart and its removal removes completed tile',
    () async {
      final controller = HomePageController();
      addTearDown(controller.dispose);
      final id = controller.beginDownloadTask(
        fileName: 'video.mp4',
        sourcePage: request.pageUrl,
        status: 'Preparing',
      );
      controller.completeDownloadTask(
        id: id,
        finalPath: request.output,
        fileName: request.fileName,
        sourcePage: request.pageUrl,
        completedStatus: 'Completed',
      );
      final restored = await DownloadSession.fromJson(
        DownloadSession(
          tasks: controller.value.downloadTasks,
          history: controller.value.history,
          requests: const {},
        ).toJson(),
      );
      expect(restored.tasks.single.completedAt, isNotNull);
      expect(restored.history.single.taskId, id);
      controller.restoreDownloads(
        tasks: restored.tasks,
        history: restored.history,
      );
      controller.removeHistory(restored.history.single.id);
      expect(controller.value.history, isEmpty);
      expect(controller.value.downloadTasks, isEmpty);
    },
  );

  test('retention keeps boundary, future and unfinished records, and never deletes for zero', () {
    final now = DateTime.utc(2026, 1, 20);
    final old = now.subtract(const Duration(days: 8));
    final boundary = now.subtract(const Duration(days: 7));
    final controller = HomePageController();
    addTearDown(controller.dispose);
    HomeDownloadTask task(String id, DateTime at, bool completed) =>
        HomeDownloadTask(
          id: id,
          fileName: '$id.mp4',
          sourcePage: request.pageUrl,
          status: '',
          progress: 1,
          stage: completed
              ? HomeWorkflowStage.completed
              : HomeWorkflowStage.failed,
          startedAt: at,
          completedAt: completed ? at : null,
          running: false,
          interrupted: !completed,
        );
    controller.restoreDownloads(
      tasks: [
        task('old', old, true),
        task('boundary', boundary, true),
        task('unfinished', old, false),
      ],
      history: [
        for (final pair in [
          ('old', old),
          ('boundary', boundary),
          ('future', now.add(const Duration(days: 1))),
        ])
          DownloadRecord(
            taskId: pair.$1,
            name: pair.$1,
            source: request.pageUrl,
            path: '/${pair.$1}.mp4',
            time: pair.$2,
          ),
      ],
    );
    expect(controller.pruneHistory(0, now: now), isFalse);
    expect(controller.pruneHistory(7, now: now), isTrue);
    expect(controller.value.history.map((record) => record.id), [
      'boundary',
      'future',
    ]);
    expect(controller.value.downloadTasks.map((task) => task.id), [
      'boundary',
      'unfinished',
    ]);
  });

  test(
    'adding many tasks never truncates paused or failed recoverable work',
    () {
      final controller = HomePageController();
      addTearDown(controller.dispose);
      for (var index = 0; index < 30; index++) {
        final id = controller.beginDownloadTask(
          fileName: '$index.mp4',
          sourcePage: request.pageUrl,
          status: 'Preparing',
        );
        controller.failDownloadTask(id, 'Offline');
      }
      expect(controller.value.downloadTasks, hasLength(30));
    },
  );

  test('corrupt schema and missing requests cannot silently erase interrupted work', () async {
    await expectLater(
      DownloadSession.fromJson({'version': 2}),
      throwsFormatException,
    );
    final controller = HomePageController();
    addTearDown(controller.dispose);
    controller.beginDownloadTask(
      fileName: 'video.mp4',
      sourcePage: request.pageUrl,
      status: 'Preparing',
    );
    await expectLater(
      DownloadSession.fromJson(
        DownloadSession(
          tasks: controller.value.downloadTasks,
          history: const [],
          requests: const {},
        ).toJson(),
      ),
      throwsFormatException,
    );
  });
}
