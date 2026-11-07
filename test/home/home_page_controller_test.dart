import 'package:flutter_test/flutter_test.dart';
import 'package:segmeris/src/home/home_page_controller.dart';

void main() {
  test('terminal download states ignore late and duplicate events', () {
    final controller = HomePageController();
    addTearDown(controller.dispose);
    var notifications = 0;
    controller.addListener(() => notifications++);
    final id = controller.beginDownloadTask(
      fileName: 'video.mp4',
      sourcePage: 'https://example.com/video',
      status: 'Preparing',
    );
    void complete(String taskId) => controller.completeDownloadTask(
      id: taskId,
      finalPath: '/video.mp4',
      fileName: 'video.mp4',
      sourcePage: 'https://example.com/video',
      completedStatus: 'Completed',
    );
    complete(id);
    final completed = controller.value;
    final count = notifications;
    controller.updateDownloadTask(id, 'Downloading media', 0.5);
    controller.failDownloadTask(id, 'Late failure');
    complete(id);
    controller.updateDownloadTask('unknown', 'Downloading media', 0.1);
    controller.failDownloadTask('unknown', 'Unknown failure');
    complete('unknown');
    expect(identical(controller.value, completed), isTrue);
    expect(controller.value.history, hasLength(1));
    expect(notifications, count);

    final failedId = controller.beginDownloadTask(
      fileName: 'failed.mp4',
      sourcePage: 'https://example.com/failed',
      status: 'Preparing',
    );
    controller.failDownloadTask(failedId, 'Network failure');
    final failed = controller.value;
    controller.updateDownloadTask(failedId, 'Downloading media', 0.9);
    complete(failedId);
    expect(identical(controller.value, failed), isTrue);
    expect(controller.value.history, hasLength(1));
  });

  test(
    'invalid and repeated progress do not corrupt state or notify again',
    () {
      final controller = HomePageController();
      addTearDown(controller.dispose);
      final id = controller.beginDownloadTask(
        fileName: 'video.mp4',
        sourcePage: 'https://example.com/video',
        status: 'Preparing',
      );
      var notifications = 0;
      controller.addListener(() => notifications++);
      controller.updateDownloadTask(id, 'Downloading media', 0.3);
      for (final value in [
        0.3,
        double.nan,
        double.infinity,
        double.negativeInfinity,
      ]) {
        controller.updateDownloadTask(id, 'Downloading media', value);
      }
      expect(notifications, 1);
      expect(controller.value.progress, 0.3);
      expect(controller.value.downloadTasks.single.progress, 0.3);
      controller.updateDownloadTask(id, 'Downloading media', 2);
      expect(controller.value.progress, 1);
      controller.updateDownloadTask(id, 'Downloading media', -1);
      expect(controller.value.progress, 0);
      controller.failDownloadTask(id, 'Failure', progress: double.nan);
      expect(controller.value.downloadTasks.single.progress, 0);
    },
  );

  test('a late pause response cannot change a completed task', () {
    final controller = HomePageController();
    addTearDown(controller.dispose);
    final id = controller.beginDownloadTask(
      fileName: 'video.mp4',
      sourcePage: 'https://example.com/video',
      status: 'Downloading',
    );
    controller.completeDownloadTask(
      id: id,
      finalPath: '/video.mp4',
      fileName: 'video.mp4',
      sourcePage: 'https://example.com/video',
      completedStatus: 'Completed',
    );
    controller.setTaskControl(id, paused: true, busy: true);
    expect(controller.value.downloadTasks.single.paused, isFalse);
    expect(controller.value.downloadTasks.single.controlBusy, isFalse);
  });

  test('records the actual encoder and replaces it after CPU fallback', () {
    final controller = HomePageController();
    addTearDown(controller.dispose);
    final taskId = controller.beginDownloadTask(
      fileName: 'video.mp4',
      sourcePage: 'https://example.com/video.m3u8',
      status: 'Preparing',
    );

    controller.updateDownloadTask(
      taskId,
      'Selected hardware encoder: Android MediaCodec',
      0.02,
    );
    expect(controller.value.downloadTasks.single.backend, 'Android MediaCodec');
    expect(
      controller.value.downloadTasks.single.stage,
      HomeWorkflowStage.backend,
    );

    controller.updateDownloadTask(
      taskId,
      'NVIDIA NVENC unavailable; retrying merge with CPU libx264',
      0.94,
    );
    expect(controller.value.downloadTasks.single.backend, 'CPU libx264');
  });

  test('labels stream copy as remuxing rather than hardware encoding', () {
    final controller = HomePageController();
    addTearDown(controller.dispose);
    final taskId = controller.beginDownloadTask(
      fileName: 'video.mp4',
      sourcePage: 'https://example.com/video.m3u8',
      status: 'Preparing',
    );

    controller.updateDownloadTask(
      taskId,
      'Selected FFmpeg stream copy (no re-encoding)',
      0.02,
    );

    expect(controller.value.downloadTasks.single.backend, 'FFmpeg stream copy');
    expect(
      controller.value.downloadTasks.single.stage,
      HomeWorkflowStage.backend,
    );
  });

  test('shows yt-dlp as a real site engine and tracks its transfer stage', () {
    final controller = HomePageController();
    addTearDown(controller.dispose);
    final taskId = controller.beginDownloadTask(
      fileName: 'video.mp4',
      sourcePage: 'https://www.youtube.com/watch?v=video-id',
      status: 'Preparing',
    );

    controller.updateDownloadTask(taskId, 'Selected site engine: yt-dlp', 0.02);
    expect(controller.value.downloadTasks.single.backend, 'yt-dlp');
    expect(
      controller.value.downloadTasks.single.stage,
      HomeWorkflowStage.backend,
    );

    controller.updateDownloadTask(
      taskId,
      'yt-dlp download 42.0% | 4.2MiB/s | ETA 00:12',
      0.386,
    );
    expect(
      controller.value.downloadTasks.single.stage,
      HomeWorkflowStage.transfer,
    );
    expect(controller.value.downloadTasks.single.backend, 'yt-dlp');
  });

  test('retries a failed task with its existing identity', () {
    final controller = HomePageController();
    addTearDown(controller.dispose);
    final taskId = controller.beginDownloadTask(
      fileName: 'video.mp4',
      sourcePage: 'https://example.com/video.m3u8',
      status: 'Preparing',
    );

    controller.failDownloadTask(taskId, 'Network connection lost');

    expect(controller.retryDownloadTask(taskId, status: 'Preparing'), isTrue);
    final task = controller.value.downloadTasks.single;
    expect(task.id, taskId);
    expect(task.running, isTrue);
    expect(task.error, isNull);
    expect(task.stage, HomeWorkflowStage.preparing);
    expect(controller.retryDownloadTask(taskId, status: 'Preparing'), isFalse);
  });
}
