import 'package:segmeris/src/home/download_task_request.dart';
import 'package:segmeris/src/home/home_page_controller.dart';
import 'package:segmeris/src/home/home_widgets.dart';

/// Versioned journal codec. A corrupt schema is surfaced instead of silently
/// replacing the user's history with an empty list.
class DownloadSession {
  const DownloadSession({
    required this.tasks,
    required this.history,
    required this.requests,
  });
  final List<HomeDownloadTask> tasks;
  final List<DownloadRecord> history;
  final Map<String, DownloadTaskRequest> requests;

  Map<String, dynamic> toJson() => {
    'version': 1,
    'tasks': [
      for (final task in tasks)
        {
          'id': task.id,
          'fileName': task.fileName,
          'sourcePage': task.sourcePage,
          'status': task.status,
          'progress': task.progress,
          'stage': task.stage.name,
          'startedAt': task.startedAt.toUtc().toIso8601String(),
          'completedAt': task.completedAt?.toUtc().toIso8601String(),
          'interrupted': task.running || task.interrupted,
          'paused': task.paused,
          'error': task.error,
          'resultPath': task.resultPath,
          'backend': task.backend,
        },
    ],
    'history': [
      for (final record in history)
        {
          'taskId': record.taskId,
          'name': record.name,
          'source': record.source,
          'path': record.path,
          'time': record.time.toUtc().toIso8601String(),
        },
    ],
    'requests': {
      for (final entry in requests.entries) entry.key: entry.value.toJson(),
    },
  };

  static Future<DownloadSession> fromJson(Map<String, dynamic> json) async {
    if (json['version'] != 1) {
      throw const FormatException('Unsupported download journal version');
    }
    final tasks = <HomeDownloadTask>[];
    final ids = <String>{};
    for (final raw in json['tasks'] as List) {
      final task = raw as Map<String, dynamic>;
      final id = task['id'] as String;
      if (id.isEmpty || !ids.add(id)) {
        throw const FormatException('Duplicate download task');
      }
      final progress = (task['progress'] as num).toDouble();
      if (!progress.isFinite) {
        throw const FormatException('Invalid download progress');
      }
      tasks.add(
        HomeDownloadTask(
          id: id,
          fileName: task['fileName'] as String,
          sourcePage: task['sourcePage'] as String,
          status: task['status'] as String,
          progress: progress.clamp(0, 1),
          stage: HomeWorkflowStage.values.byName(task['stage'] as String),
          startedAt: DateTime.parse(task['startedAt'] as String).toLocal(),
          completedAt: task['completedAt'] == null
              ? null
              : DateTime.parse(task['completedAt'] as String).toLocal(),
          running: false,
          interrupted: task['interrupted'] as bool,
          paused: task['paused'] as bool,
          error: task['error'] as String?,
          resultPath: task['resultPath'] as String?,
          backend: task['backend'] as String?,
        ),
      );
    }
    final history = <DownloadRecord>[
      for (final record in json['history'] as List)
        DownloadRecord(
          taskId: record['taskId'] as String?,
          name: record['name'] as String,
          source: record['source'] as String,
          path: record['path'] as String,
          time: DateTime.parse(record['time'] as String).toLocal(),
        ),
    ];
    final requests = <String, DownloadTaskRequest>{};
    for (final entry in (json['requests'] as Map<String, dynamic>).entries) {
      if (!ids.contains(entry.key)) continue;
      requests[entry.key] = DownloadTaskRequest.fromJson(
        entry.value as Map<String, dynamic>,
        await DownloadTaskRequest.loadCredentials(entry.key),
      );
    }
    for (final task in tasks) {
      if (task.interrupted && !requests.containsKey(task.id)) {
        throw const FormatException(
          'Interrupted task is missing its download request',
        );
      }
    }
    return DownloadSession(tasks: tasks, history: history, requests: requests);
  }
}
