import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:segmeris/src/app/app_theme.dart';
import 'package:segmeris/src/home/home_download_tasks_card.dart';
import 'package:segmeris/src/home/home_page_controller.dart';

import '../widget_test_harness.dart';

void main() {
  testWidgets('renders concurrent download task snapshots', (tester) async {
    final startedAt = DateTime(2025, 1, 1, 12);
    String? retriedTaskId;

    await tester.pumpWidget(
      buildTestHarness(
        profile: appThemeProfiles.firstWhere(
          (profile) => profile.id == 'monet_flow',
        ),
        child: HomeDownloadTasksCard(
          tasks: [
            HomeDownloadTask(
              id: 'task-1',
              fileName: 'first.mp4',
              sourcePage: 'https://example.com/first.m3u8',
              status: 'Downloading segments 42/100',
              progress: 0.42,
              stage: HomeWorkflowStage.segments,
              startedAt: startedAt,
              running: true,
            ),
            HomeDownloadTask(
              id: 'task-2',
              fileName: 'second.mp4',
              sourcePage: 'https://example.com/second.m3u8',
              status: 'Completed',
              progress: 1,
              stage: HomeWorkflowStage.completed,
              startedAt: startedAt,
              running: false,
              resultPath: 'D:/Videos/second.mp4',
            ),
            HomeDownloadTask(
              id: 'task-3',
              fileName: 'failed.mp4',
              sourcePage: 'https://example.com/failed.m3u8',
              status: 'Network connection lost',
              progress: 0.4,
              stage: HomeWorkflowStage.failed,
              startedAt: startedAt,
              running: false,
              error: 'Network connection lost',
            ),
          ],
          onRetry: (taskId) => retriedTaskId = taskId,
        ),
      ),
    );

    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('Active downloads'), findsOneWidget);
    expect(find.text('Running: 1'), findsOneWidget);
    expect(find.text('first.mp4'), findsOneWidget);
    expect(find.text('42%'), findsOneWidget);
    expect(find.text('second.mp4'), findsOneWidget);
    expect(find.text('D:/Videos/second.mp4'), findsOneWidget);
    expect(find.byTooltip('Retry'), findsOneWidget);
    await tester.tap(find.byTooltip('Retry'));
    expect(retriedTaskId, 'task-3');
  });
  testWidgets('transfer controls pause, resume and copy both stream URLs',
      (tester) async {
    String? toggled;
    String? copied;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        copied = (call.arguments as Map)['text'] as String;
      }
      return null;
    });
    addTearDown(() => TestDefaultBinaryMessengerBinding
        .instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null));
    final task = HomeDownloadTask(
        id: 'task',
        fileName: 'video.mp4',
        sourcePage: 'https://example.com/page',
        status: 'Downloading media',
        progress: .4,
        stage: HomeWorkflowStage.transfer,
        startedAt: DateTime.now(),
        running: true,
        downloadUrls: const [
          'https://cdn.example/video',
          'https://cdn.example/audio'
        ]);
    await tester.pumpWidget(buildTestHarness(
        profile: appThemeProfiles.first,
        child: HomeDownloadTasksCard(
            tasks: [task],
            onRetry: (_) {},
            onTogglePause: (id) => toggled = id)));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('Pause'));
    expect(toggled, 'task');
    await tester.tap(find.text('Copy download links'));
    await tester.pump();
    expect(copied, 'https://cdn.example/video\nhttps://cdn.example/audio');
    await tester.pumpWidget(buildTestHarness(
        profile: appThemeProfiles.first,
        child: HomeDownloadTasksCard(
            tasks: [task.copyWith(paused: true)],
            onRetry: (_) {},
            onTogglePause: (_) {})));
    await tester.pumpAndSettle();
    expect(find.text('Resume'), findsOneWidget);
    expect(find.text('Download paused'), findsOneWidget);
  });
}
