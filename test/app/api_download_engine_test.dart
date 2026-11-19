import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:segmeris/src/app/api_download_engine.dart';
import 'package:segmeris/src/app/download_engine.dart';
import 'package:segmeris/src/rust/api/downloader.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _baseUrl = 'https://api.example.test';
const _output = 'videos/clip.mp4';
const _serverPath = '/app/downloads/clip.mp4';

http.Response _json(Object data, [int status = 200]) => http.Response(
  jsonEncode(data),
  status,
  headers: {'content-type': 'application/json'},
);

Map<String, Object> _completed([String id = 'existing']) => {
  'task_id': id,
  'status': 'completed',
  'output_path': _serverPath,
  'progress_percent': 100,
};

Stream<ProgressUpdate> _download(
  ApiDownloadEngine engine, [
  String output = _output,
]) => engine.download(
  pageUrl: 'https://media.example.test/watch/1',
  mediaUrl: 'https://media.example.test/clip.mp4',
  output: output,
  options: const DownloadOptions(
    concurrency: 4,
    retries: 3,
    videoBitrate: 0,
    audioBitrate: 0,
    keepTemp: false,
    subtitleMode: SubtitleMode.off,
    subtitleValue: '',
  ),
  requestContext: const RequestContext(
    userAgent: '',
    referer: '',
    origin: '',
    cookie: '',
    headers: [],
  ),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late SharedPreferences preferences;

  ApiDownloadEngine engine(
    Future<http.Response> Function(http.Request) handler, {
    String baseUrl = _baseUrl,
    SharedPreferences? injectedPreferences,
  }) => ApiDownloadEngine(
    apiBaseUrl: baseUrl,
    apiToken: 'private-token',
    client: MockClient(handler),
    preferences: injectedPreferences ?? preferences,
    pollInterval: Duration.zero,
  );

  Future<void> seed(ApiDownloadEngine engine, Map<String, String> tasks) =>
      preferences.setString(engine.taskMappingKey, jsonEncode(tasks));

  Map<String, dynamic> mapping(ApiDownloadEngine engine) =>
      jsonDecode(preferences.getString(engine.taskMappingKey) ?? '{}')
          as Map<String, dynamic>;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    preferences = await SharedPreferences.getInstance();
  });

  test(
    'reattachment accepts only live or completed server task states',
    () async {
      var state = 'queued';
      var polls = 0;
      final api = engine((request) async {
        polls++;
        expect(request.method, 'GET');
        expect(request.url.path, '/status/existing');
        return _json({'status': state});
      });
      expect(api, isA<ReattachableDownloadEngine>());
      expect(await api.canReattach(output: _output), isFalse);
      expect(polls, 0);
      await seed(api, {_output: 'existing'});
      for (final candidate in [
        'queued',
        'running',
        'paused',
        'completed',
        'failed',
        'unknown',
      ]) {
        state = candidate;
        expect(
          await api.canReattach(output: _output),
          candidate != 'failed' && candidate != 'unknown',
          reason: candidate,
        );
        expect(mapping(api), {_output: 'existing'});
      }
    },
  );

  test(
    'reattachment and completion never re-inspect expired media authentication',
    () async {
      final calls = <String>[];
      final api = engine((request) async {
        calls.add('${request.method} ${request.url.path}');
        if (request.url.path == '/inspect') {
          return _json({'error': 'Bilibili login expired'}, 401);
        }
        if (request.method == 'POST') {
          fail('An existing task must not be recreated');
        }
        return _json(_completed());
      });
      await seed(api, {_output: 'existing'});
      expect(await api.canReattach(output: _output), isTrue);
      expect((await _download(api).toList()).single.progress, 1);
      expect(api.lastResultPath, _serverPath);
      expect(calls, ['GET /status/existing', 'GET /status/existing']);
    },
  );

  test(
    'reattachment 404 allows source refresh before replacing the task',
    () async {
      final calls = <String>[];
      final api = engine((request) async {
        calls.add('${request.method} ${request.url.path}');
        if (request.url.path == '/status/missing') {
          return _json({'error': 'Not found'}, 404);
        }
        if (request.url.path == '/inspect') {
          return _json({'auth_required': false});
        }
        if (request.url.path == '/download') {
          return _json({'task_id': 'refreshed'}, 202);
        }
        return _json(_completed('refreshed'));
      });
      await seed(api, {_output: 'missing'});
      expect(await api.canReattach(output: _output), isFalse);
      expect(mapping(api), {_output: 'missing'});
      await api.inspect(
        url: 'https://media.example.test/watch/1',
        requestContext: const RequestContext(
          userAgent: '',
          referer: '',
          origin: '',
          cookie: '',
          headers: [],
        ),
      );
      await _download(api).toList();
      expect(calls, [
        'GET /status/missing',
        'POST /inspect',
        'GET /status/missing',
        'POST /download',
        'GET /status/refreshed',
      ]);
      expect(mapping(api), {_output: 'refreshed'});
    },
  );

  test(
    'reattachment auth and transport failures throw without losing the mapping',
    () async {
      for (final code in [401, 500, 503]) {
        final api = engine((request) async {
          expect(request.method, 'GET');
          return http.Response('upstream error', code);
        });
        await seed(api, {_output: 'existing'});
        await expectLater(
          api.canReattach(output: _output),
          throwsA(
            isA<ApiEngineException>().having(
              (error) => error.statusCode,
              'statusCode',
              code,
            ),
          ),
        );
        expect(mapping(api), {_output: 'existing'});
      }
      final offline = engine(
        (_) async => throw http.ClientException('offline'),
      );
      await expectLater(
        offline.canReattach(output: _output),
        throwsA(isA<http.ClientException>()),
      );
      expect(mapping(offline), {_output: 'existing'});
    },
  );

  test(
    'accepted task id is persisted before first poll and excludes tokens',
    () async {
      final requests = <String>[];
      late ApiDownloadEngine api;
      api = engine((request) async {
        requests.add('${request.method} ${request.url.path}');
        expect(request.headers['authorization'], 'Bearer private-token');
        if (request.url.path == '/download') {
          return _json({'task_id': 'new'}, 202);
        }
        expect(mapping(api), {_output: 'new'});
        return _json(_completed('new'));
      });
      expect((await _download(api).toList()).single.progress, 1);
      expect(requests, ['POST /download', 'GET /status/new']);
      expect(api.lastResultPath, _serverPath);
      expect(mapping(api), {_output: 'new'});
      expect(preferences.getKeys().join(), isNot(contains('private-token')));
      expect(
        preferences.getKeys().map(preferences.get).join(),
        isNot(contains('private-token')),
      );
    },
  );

  test(
    'recreated engine polls persisted running task without another POST',
    () async {
      var posts = 0;
      final first = engine((request) async {
        if (request.method == 'POST') {
          posts++;
          return _json({'task_id': 'existing'}, 202);
        }
        return _json({'status': 'running', 'progress_percent': 25});
      });
      expect((await _download(first).take(1).toList()).single.progress, .25);
      final restarted = engine((request) async {
        expect(request.method, 'GET');
        expect(request.url.path, '/status/existing');
        return _json(_completed());
      });
      expect((await _download(restarted).toList()).single.progress, 1);
      expect(posts, 1);
      expect(restarted.lastResultPath, _serverPath);
    },
  );

  test(
    'completed mapping returns existing output and is retained for deletion',
    () async {
      final api = engine((request) async {
        expect(request.method, 'GET');
        return _json(_completed());
      });
      await seed(api, {_output: 'existing'});
      await _download(api).toList();
      expect(api.lastResultPath, _serverPath);
      expect(mapping(api), {_output: 'existing'});
    },
  );

  for (final status in [401, 403, 500, 503]) {
    test(
      'HTTP $status retains mapping and never creates a replacement',
      () async {
        var calls = 0;
        final api = engine((request) async {
          calls++;
          expect(request.method, 'GET');
          return http.Response('upstream unavailable', status);
        });
        await seed(api, {_output: 'existing'});
        await expectLater(
          _download(api).toList(),
          throwsA(
            isA<ApiEngineException>().having(
              (error) => error.statusCode,
              'statusCode',
              status,
            ),
          ),
        );
        expect(mapping(api), {_output: 'existing'});
        expect(calls, 1);
      },
    );
  }

  test(
    'network failure and malformed status retain the existing mapping',
    () async {
      final offline = engine(
        (request) async => throw http.ClientException('offline'),
      );
      await seed(offline, {_output: 'existing'});
      await expectLater(
        _download(offline).toList(),
        throwsA(isA<http.ClientException>()),
      );
      final malformed = engine((request) async {
        expect(request.method, 'GET');
        return http.Response('{truncated', 200);
      });
      await expectLater(
        _download(malformed).toList(),
        throwsA(isA<FormatException>()),
      );
      expect(mapping(malformed), {_output: 'existing'});
    },
  );

  test(
    'a confirmed 404 clears old mapping before creating a replacement',
    () async {
      final calls = <String>[];
      late ApiDownloadEngine api;
      api = engine((request) async {
        calls.add('${request.method} ${request.url.path}');
        if (request.url.path == '/status/missing') {
          return http.Response('not found', 404);
        }
        if (request.url.path == '/download') {
          expect(mapping(api), isEmpty);
          return _json({'task_id': 'replacement'}, 202);
        }
        expect(mapping(api), {_output: 'replacement'});
        return _json(_completed('replacement'));
      });
      await seed(api, {_output: 'missing'});
      await _download(api).toList();
      expect(calls, [
        'GET /status/missing',
        'POST /download',
        'GET /status/replacement',
      ]);
    },
  );

  test(
    'failed server task retries once with the same output filename',
    () async {
      var posts = 0;
      late ApiDownloadEngine api;
      api = engine((request) async {
        if (request.url.path == '/status/failed') {
          return _json({'status': 'failed'});
        }
        if (request.url.path == '/download') {
          posts++;
          expect(mapping(api), {_output: 'failed'});
          expect(jsonDecode(request.body)['output_filename'], 'clip.mp4');
          return _json({'task_id': 'retry'}, 202);
        }
        return _json({'status': 'failed', 'error': 'source unavailable'});
      });
      await seed(api, {_output: 'failed'});
      expect(
        (await _download(api).toList()).single.error,
        'source unavailable',
      );
      expect(posts, 1);
      expect(mapping(api), {_output: 'retry'});
    },
  );

  test(
    'failed replacement POST preserves the old failed task mapping',
    () async {
      final api = engine(
        (request) async => request.method == 'GET'
            ? _json({'status': 'failed'})
            : _json({'error': 'Unauthorized'}, 401),
      );
      await seed(api, {_output: 'failed'});
      await expectLater(
        _download(api).toList(),
        throwsA(isA<ApiEngineException>()),
      );
      expect(mapping(api), {_output: 'failed'});
    },
  );

  test(
    'persistence failure prevents polling and retry reuses accepted id',
    () async {
      var posts = 0;
      var polls = 0;
      final failing = _RejectingPreferences(preferences)
        ..rejectNextWrite = true;
      Future<http.Response> handler(http.Request request) async {
        if (request.method == 'POST') {
          posts++;
          return _json({'task_id': 'accepted-once'}, 202);
        }
        polls++;
        return _json(_completed('accepted-once'));
      }

      final first = engine(handler, injectedPreferences: failing);
      await expectLater(
        _download(first).toList(),
        throwsA(isA<ApiEngineException>()),
      );
      expect(posts, 1);
      expect(polls, 0);
      final second = engine(handler);
      await _download(second).toList();
      expect(posts, 1);
      expect(polls, 1);
      expect(mapping(second), {_output: 'accepted-once'});
    },
  );

  test(
    'mapping updates for concurrent outputs cannot overwrite each other',
    () async {
      Future<http.Response> handler(http.Request request) async {
        if (request.method == 'POST') {
          return _json({
            'task_id': jsonDecode(request.body)['output_filename'],
          }, 202);
        }
        return _json(_completed());
      }

      final first = engine(handler);
      final second = engine(handler);
      await Future.wait([
        _download(first, 'first.mp4').toList(),
        _download(second, 'second.mp4').toList(),
      ]);
      expect(mapping(first), {
        'first.mp4': 'first.mp4',
        'second.mp4': 'second.mp4',
      });
    },
  );

  test(
    'two engine instances cannot create concurrent tasks for one output',
    () async {
      final entered = Completer<void>();
      final accepted = Completer<http.Response>();
      var posts = 0;
      Future<http.Response> handler(http.Request request) async {
        if (request.method == 'POST') {
          posts++;
          entered.complete();
          return accepted.future;
        }
        return _json(_completed());
      }

      final first = _download(engine(handler)).toList();
      await entered.future;
      await expectLater(
        _download(engine(handler)).toList(),
        throwsA(isA<ApiEngineException>()),
      );
      accepted.complete(_json({'task_id': 'existing'}, 202));
      await first;
      expect(posts, 1);
    },
  );

  test('mapping is scoped to normalized server URL', () async {
    final first = engine((_) async => _json(_completed()));
    await seed(first, {_output: 'existing'});
    final same = engine((request) async {
      expect(request.method, 'GET');
      return _json(_completed());
    }, baseUrl: '$_baseUrl/');
    await _download(same).toList();
    var otherPosted = false;
    final other = engine((request) async {
      if (request.method == 'POST') {
        otherPosted = true;
        return _json({'task_id': 'other-server'}, 202);
      }
      return _json(_completed('other-server'));
    }, baseUrl: 'https://other.example.test');
    await _download(other).toList();
    expect(otherPosted, isTrue);
    expect(mapping(first), {_output: 'existing'});
    expect(mapping(other), {_output: 'other-server'});
  });

  test(
    'corrupt mappings are preserved and prevent duplicate HTTP creation',
    () async {
      final api = engine((_) async => fail('No HTTP request expected'));
      await preferences.setString(api.taskMappingKey, '{broken');
      await expectLater(
        _download(api).toList(),
        throwsA(isA<FormatException>()),
      );
      expect(preferences.getString(api.taskMappingKey), '{broken');
    },
  );

  test('pause restores a task id without starting a download stream', () async {
    final api = engine((request) async {
      expect(request.url.path, '/tasks/existing/pause');
      return _json({'status': 'paused'});
    });
    await seed(api, {_output: 'existing'});
    expect(await api.setPaused(output: _output, paused: true), isTrue);
  });

  test(
    'missing pause endpoint does not discard a potentially active task',
    () async {
      final api = engine((request) async => _json({'error': 'Not found'}, 404));
      await seed(api, {_output: 'existing'});
      expect(await api.setPaused(output: _output, paused: true), isFalse);
      expect(mapping(api), {_output: 'existing'});
    },
  );

  test(
    'deletion resolves a unique completed path and removes only its mapping',
    () async {
      final calls = <String>[];
      final api = engine((request) async {
        calls.add('${request.method} ${request.url.path}');
        if (request.method == 'GET') return _json([_completed()]);
        expect(request.body, '{}');
        return _json({'deleted': true, 'task_id': 'existing'});
      });
      expect(api, isA<CompletedDownloadDeletionEngine>());
      await seed(api, {_output: 'existing', 'other.mp4': 'other'});
      expect(await api.deleteDownloadedFile(path: _serverPath), isTrue);
      expect(calls, ['GET /tasks', 'POST /tasks/existing/delete']);
      expect(mapping(api), {'other.mp4': 'other'});
    },
  );

  for (final scenario in ['missing', 'ambiguous', 'running']) {
    test(
      'deletion rejects $scenario paths without sending a delete request',
      () async {
        final api = engine((request) async {
          expect(request.method, 'GET');
          return _json(switch (scenario) {
            'missing' => <Object>[],
            'ambiguous' => [_completed(), _completed('second')],
            _ => [
              {..._completed(), 'status': 'running'},
            ],
          });
        });
        expect(await api.deleteDownloadedFile(path: _serverPath), isFalse);
      },
    );
  }

  for (final status in [404, 500]) {
    test(
      'deletion HTTP $status does not report success or clear the mapping',
      () async {
        final api = engine(
          (request) async => request.method == 'GET'
              ? _json([_completed()])
              : _json({'error': 'not deleted'}, status),
        );
        await seed(api, {_output: 'existing'});
        await expectLater(
          api.deleteDownloadedFile(path: _serverPath),
          throwsA(isA<ApiEngineException>()),
        );
        expect(mapping(api), {_output: 'existing'});
      },
    );
  }

  test('deletion requires explicit server confirmation', () async {
    final api = engine(
      (request) async => request.method == 'GET'
          ? _json([_completed()])
          : _json({'deleted': false}),
    );
    await seed(api, {_output: 'existing'});
    await expectLater(
      api.deleteDownloadedFile(path: _serverPath),
      throwsA(isA<ApiEngineException>()),
    );
    expect(mapping(api), {_output: 'existing'});
  });
}

class _RejectingPreferences implements SharedPreferences {
  _RejectingPreferences(this.delegate);
  final SharedPreferences delegate;
  bool rejectNextWrite = false;

  @override
  Object? get(String key) => delegate.get(key);

  @override
  Future<void> reload() => delegate.reload();

  @override
  Future<bool> setString(String key, String value) async {
    if (rejectNextWrite) {
      rejectNextWrite = false;
      return false;
    }
    return delegate.setString(key, value);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
