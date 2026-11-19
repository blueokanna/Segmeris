import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:segmeris/src/rust/api/downloader.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'download_engine.dart';

/// Web (WASM) download engine that drives the Segmeris HTTP API instead of
/// the local Rust runtime.
///
/// The API server (see `Dockerfile.api` / `docker-compose.yml`) executes the
/// full native download + hardware-transcode pipeline server-side and exposes:
///   POST /inspect           -> inspect a page / playlist
///   POST /download          -> queue a download, returns { task_id }
///   GET  /status/:task_id   -> poll progress
///
/// Because browsers cannot run the Rust engine, this client translates the
/// REST responses into the same `ProgressUpdate` / `MediaInspectionResult`
/// objects the native UI consumes.
class ApiDownloadEngine
    implements
        DownloadEngine,
        PausableDownloadEngine,
        ReattachableDownloadEngine,
        CompletedDownloadDeletionEngine {
  ApiDownloadEngine({
    required String apiBaseUrl,
    this.apiToken = '',
    http.Client? client,
    this._preferences,
    this._pollInterval = const Duration(seconds: 1),
  }) : apiBaseUrl = _normalizeBaseUrl(apiBaseUrl),
       _client = client ?? http.Client();

  final String apiBaseUrl;

  /// Optional bearer token forwarded to the API server (`FERRISLOAD_API_TOKEN`).
  /// It is never included in the persisted task mapping.
  final String apiToken;
  final http.Client _client;
  SharedPreferences? _preferences;
  final Duration _pollInterval;
  final _activeTasks = <String, String>{};

  // Keep read-modify-write transactions and output ownership consistent across
  // engine instances in this isolate. Other browser tabs require server-side
  // idempotency to provide the same guarantee.
  static Future<void> _mappingTail = Future<void>.value();
  static final _ownedOutputs = <String>{};
  static final _unpersistedTaskIds = <String, String>{};

  String get taskMappingKey =>
      'segmeris.apiDownloadTasks.v1.${Uri.encodeComponent(apiBaseUrl)}';

  String _outputKey(String output) => '$taskMappingKey:${jsonEncode(output)}';

  Future<T> _withMappings<T>(
    Future<T> Function(SharedPreferences preferences, Map<String, String> tasks)
    action,
  ) {
    final result = _mappingTail.then((_) async {
      final preferences = _preferences ??=
          await SharedPreferences.getInstance();
      await preferences.reload();
      final raw = preferences.get(taskMappingKey);
      final tasks = <String, String>{};
      if (raw != null) {
        if (raw is! String) {
          throw ApiEngineException('Stored API task mapping is invalid');
        }
        final decoded = jsonDecode(raw);
        if (decoded is! Map<String, dynamic> ||
            decoded.values.any((id) => id is! String || id.isEmpty)) {
          throw ApiEngineException('Stored API task mapping is invalid');
        }
        tasks.addAll(decoded.cast<String, String>());
      }
      return action(preferences, tasks);
    });
    _mappingTail = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return result;
  }

  Future<String?> _storedTaskId(String output) =>
      _withMappings((_, tasks) async => tasks[output]);

  Future<void> _persistTaskId(String output, String id) =>
      _withMappings((preferences, tasks) async {
        tasks[output] = id;
        if (!await preferences.setString(taskMappingKey, jsonEncode(tasks))) {
          throw ApiEngineException('Could not persist the API task id');
        }
      });

  Future<void> _removeTaskId(String id) => _withMappings((
    preferences,
    tasks,
  ) async {
    tasks.removeWhere((_, value) => value == id);
    if (!await preferences.setString(taskMappingKey, jsonEncode(tasks))) {
      throw ApiEngineException('Could not update the stored API task mapping');
    }
  });

  @override
  Future<bool> canReattach({required String output}) async {
    final id = await _storedTaskId(output);
    if (id == null) return false;
    try {
      final status = await _getJson('/status/${Uri.encodeComponent(id)}');
      return switch (status['status']) {
        'queued' || 'running' || 'paused' || 'completed' => true,
        _ => false,
      };
    } on ApiEngineException catch (error) {
      if (error.statusCode != 404) rethrow;
      // This probe never mutates the mapping. download() confirms staleness
      // again before replacing it, after the caller refreshes signed sources.
      return false;
    }
  }

  @override
  Future<bool> setPaused({required String output, required bool paused}) async {
    final id = _activeTasks[output] ?? await _storedTaskId(output);
    if (id == null || id.isEmpty) return false;
    try {
      await _postJson(
        '/tasks/${Uri.encodeComponent(id)}/${paused ? 'pause' : 'resume'}',
        {},
      );
      return true;
    } on ApiEngineException catch (error) {
      if (error.statusCode != 404) rethrow;
      // Older servers may lack this action even while the task still exists.
      // Only GET /status returning 404 establishes that a mapping is stale.
      return false;
    }
  }

  @override
  Future<bool> deleteDownloadedFile({required String path}) async {
    if (path.isEmpty) return false;
    final payload = await _getJsonValue('/tasks');
    if (payload is! List) throw const FormatException('Unexpected task list');
    final matches = payload
        .whereType<Map<String, dynamic>>()
        .where((task) => task['output_path'] == path)
        .toList();
    if (matches.length != 1 || matches.single['status'] != 'completed') {
      return false;
    }
    final id = matches.single['task_id'];
    if (id is! String || id.isEmpty) return false;
    final deleted = await _postJson(
      '/tasks/${Uri.encodeComponent(id)}/delete',
      {},
    );
    if (deleted['deleted'] != true) {
      throw ApiEngineException('The API did not confirm file deletion');
    }
    await _removeTaskId(id);
    if (_lastOutputPath == path) _lastOutputPath = null;
    return true;
  }

  /// Upper bound for a single queued download. Long transcodes (CPU) can take
  /// hours; this only fires when the server stops making progress forever.
  static const _maxPollDuration = Duration(hours: 8);

  String? _lastOutputPath;

  /// Path on the API server where the finished file was written.
  @override
  String? get lastResultPath => _lastOutputPath;

  Map<String, String> _authHeaders() => {
    'content-type': 'application/json',
    if (apiToken.isNotEmpty) 'authorization': 'Bearer $apiToken',
  };

  /// Strip a trailing slash and reject entirely-empty values.
  static String _normalizeBaseUrl(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) {
      return defaultApiBaseUrl;
    }
    final uri = Uri.tryParse(trimmed);
    if (uri == null || !uri.hasScheme) {
      return defaultApiBaseUrl;
    }
    return uri.toString().replaceFirst(RegExp(r'/$'), '');
  }

  /// The engine forwards the user's authorized headers/cookies to the API
  /// server, so credentials must never travel in plaintext: a non-loopback
  /// URL that is not `https` is refused. Loopback (localhost) HTTP is allowed
  /// because traffic never leaves the machine.
  void _assertTransportSecurity() {
    final uri = Uri.tryParse(apiBaseUrl);
    if (uri == null || !uri.hasScheme) {
      throw ApiEngineException('Invalid Segmeris API base URL: $apiBaseUrl');
    }
    final host = uri.host;
    final isLoopback =
        host.isEmpty ||
        host == 'localhost' ||
        host == '127.0.0.1' ||
        host == '::1';
    if (!isLoopback && uri.scheme != 'https') {
      throw ApiEngineException(
        'Segmeris API base URL must use https for non-local servers '
        '(got $apiBaseUrl); refusing to send your session over plaintext HTTP.',
      );
    }
  }

  Uri _uri(String path) => Uri.parse('$apiBaseUrl$path');

  @override
  Future<void> init() async {}

  @override
  bool get writesLocalFiles => false;

  Future<Map<String, dynamic>> _postJson(
    String path,
    Map<String, dynamic> body,
  ) async {
    _assertTransportSecurity();
    final response = await _client
        .post(_uri(path), headers: _authHeaders(), body: jsonEncode(body))
        .timeout(const Duration(seconds: 60));
    final payload = _decodeResponse(response, path);
    if (payload is! Map<String, dynamic>) {
      throw FormatException('Unexpected response from $path');
    }
    return payload;
  }

  Future<Map<String, dynamic>> _getJson(String path) async {
    final payload = await _getJsonValue(path);
    if (payload is! Map<String, dynamic>) {
      throw FormatException('Unexpected response from $path');
    }
    return payload;
  }

  Future<Object?> _getJsonValue(String path) async {
    _assertTransportSecurity();
    final response = await _client
        .get(_uri(path), headers: _authHeaders())
        .timeout(const Duration(seconds: 30));
    return _decodeResponse(response, path);
  }

  Object? _decodeResponse(http.Response response, String path) {
    if (response.statusCode >= 400) {
      String message = 'API request failed (HTTP ${response.statusCode})';
      try {
        final payload = jsonDecode(utf8.decode(response.bodyBytes));
        if (payload is Map<String, dynamic> && payload['error'] is String) {
          message = payload['error'] as String;
        }
      } on FormatException {
        // Error pages need not be JSON. Preserve the HTTP status either way.
      }
      throw ApiEngineException(message, statusCode: response.statusCode);
    }
    return jsonDecode(utf8.decode(response.bodyBytes));
  }

  @override
  Future<MediaInspectionResult> inspect({
    required String url,
    required RequestContext requestContext,
  }) async {
    final payload = await _postJson('/inspect', {
      'url': url,
      'request_context': _contextToJson(requestContext),
    });
    return MediaInspectionResult(
      pageUrl: payload['page_url'] as String? ?? '',
      pageTitle: payload['page_title'] as String? ?? '',
      extractor: payload['extractor'] as String? ?? '',
      candidates: [
        for (final raw in _asList(payload['candidates']))
          if (raw is Map<String, dynamic>) _candidateFromJson(raw),
      ],
      subtitles: [
        for (final raw in _asList(payload['subtitles']))
          if (raw is Map<String, dynamic>)
            MediaSubtitleTrack(
              language: raw['language'] as String? ?? '',
              label: raw['label'] as String? ?? '',
              url: raw['url'] as String? ?? '',
              selected: raw['selected'] as bool? ?? false,
            ),
      ],
      warnings: _asList(payload['warnings']).whereType<String>().toList(),
      authRequired: payload['auth_required'] as bool? ?? false,
      challengeReason: payload['challenge_reason'] as String? ?? '',
      collection: _collectionFromJson(payload['collection']),
    );
  }

  MediaCollection? _collectionFromJson(Object? raw) {
    if (raw is! Map<String, dynamic>) {
      return null;
    }
    return MediaCollection(
      kind: raw['kind'] as String? ?? '',
      title: raw['title'] as String? ?? '',
      entries: [
        for (final entry in _asList(raw['entries']))
          if (entry is Map<String, dynamic>)
            MediaCollectionEntry(
              id: entry['id'] as String? ?? '',
              index: (entry['index'] as num?)?.toInt() ?? 0,
              title: entry['title'] as String? ?? '',
              durationSeconds:
                  (entry['duration_seconds'] as num?)?.toDouble() ?? 0,
              pageUrl: entry['page_url'] as String? ?? '',
              available: entry['available'] as bool? ?? false,
              unavailableReason: entry['unavailable_reason'] as String? ?? '',
              current: entry['current'] as bool? ?? false,
            ),
      ],
    );
  }

  /// The `mode` strings the HTTP contract accepts; kept beside the
  /// serializer so a new engine mode cannot be forgotten here.
  String _subtitleModeName(SubtitleMode mode) {
    return switch (mode) {
      SubtitleMode.auto => 'auto',
      SubtitleMode.off => 'off',
      SubtitleMode.track => 'track',
      SubtitleMode.language => 'language',
    };
  }

  MediaCandidate _candidateFromJson(Map<String, dynamic> raw) {
    return MediaCandidate(
      id: raw['id'] as String? ?? '',
      title: raw['title'] as String? ?? '',
      extractor: raw['extractor'] as String? ?? '',
      pageUrl: raw['page_url'] as String? ?? '',
      mediaUrl: raw['media_url'] as String? ?? '',
      mediaFallbackUrls: _asList(raw['media_fallback_urls'])
          .whereType<String>()
          .toList(),
      audioUrl: raw['audio_url'] as String?,
      audioFallbackUrls: _asList(raw['audio_fallback_urls'])
          .whereType<String>()
          .toList(),
      container: raw['container'] as String? ?? '',
      protocol: raw['protocol'] as String? ?? '',
      mimeType: raw['mime_type'] as String? ?? '',
      qualityLabel: raw['quality_label'] as String? ?? '',
      qualityBadge: raw['quality_badge'] as String? ?? '',
      codec: raw['codec'] as String? ?? '',
      width: (raw['width'] as num?)?.toInt() ?? 0,
      height: (raw['height'] as num?)?.toInt() ?? 0,
      requiresFfmpeg: raw['requires_ffmpeg'] as bool? ?? false,
      score: (raw['score'] as num?)?.toInt() ?? 0,
      segmentCount: (raw['segment_count'] as num?)?.toInt() ?? 0,
      durationSeconds: (raw['duration_seconds'] as num?)?.toDouble() ?? 0,
      primary: raw['primary'] as bool? ?? false,
      reason: raw['reason'] as String? ?? '',
    );
  }

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
  }) async* {
    final ownershipKey = _outputKey(output);
    if (!_ownedOutputs.add(ownershipKey)) {
      throw ApiEngineException('A download already owns this output path');
    }
    _activeTasks[output] = '';
    _lastOutputPath = null;
    try {
      var taskId = _unpersistedTaskIds[ownershipKey];
      if (taskId != null) {
        // A previous preferences failure must not create another server task.
        await _persistTaskId(output, taskId);
        _unpersistedTaskIds.remove(ownershipKey);
      } else {
        taskId = await _storedTaskId(output);
      }
      Map<String, dynamic>? recoveredStatus;
      if (taskId != null) {
        _activeTasks[output] = taskId;
        try {
          recoveredStatus = await _getJson(
            '/status/${Uri.encodeComponent(taskId)}',
          );
          if (recoveredStatus['status'] == 'failed') {
            // An explicitly failed task can be retried. Keep its mapping until
            // the new task id has been accepted and durably stored.
            taskId = null;
            recoveredStatus = null;
          }
        } on ApiEngineException catch (error) {
          if (error.statusCode != 404) rethrow;
          await _removeTaskId(taskId!);
          taskId = null;
        }
      }
      if (taskId == null) {
        final accepted = await _postJson('/download', {
          'url': pageUrl,
          'media_url': mediaUrl,
          'media_fallback_urls': mediaFallbackUrls,
          'audio_url': audioUrl,
          'audio_fallback_urls': audioFallbackUrls,
          'output_filename': _basename(output),
          'concurrency': options.concurrency,
          'retries': options.retries,
          'video_bitrate': options.videoBitrate,
          'audio_bitrate': options.audioBitrate,
          'keep_temp': options.keepTemp,
          'subtitle': {
            'mode': _subtitleModeName(options.subtitleMode),
            'value': options.subtitleValue,
          },
          'request_context': _contextToJson(requestContext),
        });
        final acceptedId = accepted['task_id'];
        if (acceptedId is! String || acceptedId.isEmpty) {
          throw ApiEngineException('API did not return a task id');
        }
        taskId = acceptedId;
        _unpersistedTaskIds[ownershipKey] = taskId;
        await _persistTaskId(output, taskId);
        _unpersistedTaskIds.remove(ownershipKey);
      }

      _activeTasks[output] = taskId;
      var sawProgress = false;
      var activeElapsed = Duration.zero;
      var lastPoll = DateTime.now();
      var wasPaused = false;
      while (true) {
        // Guard against a server that never progresses: fail instead of
        // polling forever.
        final now = DateTime.now();
        if (!wasPaused) activeElapsed += now.difference(lastPoll);
        lastPoll = now;
        if (activeElapsed > _maxPollDuration) {
          throw ApiEngineException(
            'API server did not finish the task within '
            '${_maxPollDuration.inHours}h; check the server logs.',
          );
        }
        final Map<String, dynamic> status;
        try {
          status =
              recoveredStatus ??
              await _getJson('/status/${Uri.encodeComponent(taskId)}');
          recoveredStatus = null;
        } on ApiEngineException catch (error) {
          if (error.statusCode == 404) await _removeTaskId(taskId);
          rethrow;
        }
        final state = status['status'] as String? ?? 'running';
        wasPaused = state == 'paused';
        final message = status['message'] as String? ?? '';
        final percent = (status['progress_percent'] as num?)?.toDouble();
        final error = status['error'] as String?;
        final serverOutput = status['output_path'] as String?;
        if (serverOutput != null && serverOutput.isNotEmpty) {
          _lastOutputPath = serverOutput;
        }

        switch (state) {
          case 'completed':
            yield ProgressUpdate(
              message: message.isEmpty ? 'All tasks completed' : message,
              progress: 1.0,
            );
            return;
          case 'failed':
            yield ProgressUpdate(
              message: '',
              progress: 0.0,
              error: (error == null || error.isEmpty)
                  ? 'Download failed on the API server'
                  : error,
            );
            return;
          default:
            final progress = (percent ?? 0.0).clamp(0.0, 100.0) / 100.0;
            if (progress > 0 || message.isNotEmpty) {
              sawProgress = true;
              yield ProgressUpdate(
                message: message.isEmpty ? 'Working...' : message,
                progress: progress,
              );
            }
            if (!sawProgress && _pollInterval.inMilliseconds > 0) {
              // Keep emitting an initial progress so the UI never stalls blank.
              yield ProgressUpdate(
                message: 'Waiting for API server...',
                progress: 0.0,
              );
            }
            await Future<void>.delayed(_pollInterval);
        }
      }
    } finally {
      _activeTasks.remove(output);
      _ownedOutputs.remove(ownershipKey);
    }
  }

  static String _basename(String path) {
    final normalized = path.replaceAll('\\', '/');
    final slash = normalized.lastIndexOf('/');
    return slash >= 0 ? normalized.substring(slash + 1) : path;
  }

  static Map<String, dynamic> _contextToJson(RequestContext context) {
    return {
      'user_agent': context.userAgent,
      'referer': context.referer,
      'origin': context.origin,
      'cookie': context.cookie,
      'headers': {for (final entry in context.headers) entry.name: entry.value},
    };
  }

  static List<dynamic> _asList(Object? value) {
    return switch (value) {
      List<dynamic> list => list,
      _ => const [],
    };
  }
}

class ApiEngineException implements Exception {
  ApiEngineException(this.message, {this.statusCode});

  final String message;
  final int? statusCode;

  @override
  String toString() => message;
}
