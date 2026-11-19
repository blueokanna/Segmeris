import 'dart:async';
import 'dart:convert';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:segmeris/src/app/app_update.dart';
import 'package:segmeris/src/app/app_update_widgets.dart';

class RequestProbeClient extends http.BaseClient {
  RequestProbeClient(this.handler);
  final Future<http.StreamedResponse> Function(http.BaseRequest) handler;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      handler(request);
}

class MemoryUpdateStore implements AppUpdateStore {
  String? value;
  bool failRead = false;
  bool failWrite = false;
  int writes = 0;
  @override
  Future<String?> read() async {
    if (failRead) throw StateError('storage offline');
    return value;
  }

  @override
  Future<void> write(String next) async {
    writes++;
    if (failWrite) throw StateError('storage full');
    value = next;
  }
}

Map<String, dynamic> release({
  String tag = 'v1.2.0',
  bool draft = false,
  bool prerelease = false,
  String body = 'Release notes',
  List<String> suffixes = const ['windows-x64.zip', 'windows-x64-setup.exe'],
}) => {
  'tag_name': tag,
  'draft': draft,
  'prerelease': prerelease,
  'html_url': 'https://github.com/blueokanna/Segmeris/releases/tag/$tag',
  'body': body,
  'assets': [
    for (final suffix in suffixes)
      {
        'name': 'Segmeris-$tag-$suffix',
        'browser_download_url':
            'https://github.com/blueokanna/Segmeris/releases/download/$tag/Segmeris-$tag-$suffix',
        'size': 12000,
        'state': 'uploaded',
      },
    {
      'name': 'SHA256SUMS',
      'browser_download_url':
          'https://github.com/blueokanna/Segmeris/releases/download/$tag/SHA256SUMS',
      'size': 256,
      'state': 'uploaded',
    },
  ],
};

AppUpdateService service({
  required http.Client client,
  MemoryUpdateStore? store,
  String current = '1.1.0+1',
  DateTime Function()? clock,
  Duration timeout = const Duration(seconds: 1),
  AppUpdateTarget target = const AppUpdateTarget('windows', 'x64'),
}) => AppUpdateService(
  currentVersion: AppVersion.tryParse(current)!,
  target: target,
  store: store ?? MemoryUpdateStore(),
  client: client,
  clock: clock,
  timeout: timeout,
);

void main() {
  group('merged transport and release safeguards', () {
    test('SemVer handles huge numbers and strict identifier rules', () {
      final versions = [
        '1.0.0-alpha',
        '1.0.0-alpha.1',
        '1.0.0-alpha.beta',
        '1.0.0-beta',
        '1.0.0-beta.2',
        '1.0.0-beta.11',
        '1.0.0-rc.1',
        '1.0.0',
      ];
      for (var i = 1; i < versions.length; i++) {
        expect(
          AppVersion.tryParse(versions[i - 1])!
              .compareTo(AppVersion.tryParse(versions[i])!),
          lessThan(0),
        );
      }
      expect(
        AppVersion.tryParse('999999999999999999999.0.0')!
            .compareTo(AppVersion.tryParse('2.0.0')!),
        greaterThan(0),
      );
      expect(AppVersion.tryParse('1.0.0\n'), isNull);
      expect(
        AppVersion.tryParse('1.0.0-0x10')!
            .compareTo(AppVersion.tryParse('1.0.0-20')!),
        greaterThan(0),
      );
    });

    test(
      'old macOS filenames match and missing checksums disable direct asset',
      () {
        final item = release(suffixes: ['macos-arm64.zip']);
        expect(
          AppUpdateRelease.fromJson(
            item,
            const AppUpdateTarget('macos', 'arm64'),
          )!.asset,
          isNotNull,
        );
        (item['assets'] as List).removeWhere(
          (dynamic asset) => asset['name'] == 'SHA256SUMS',
        );
        expect(
          AppUpdateRelease.fromJson(
            item,
            const AppUpdateTarget('macos', 'arm64'),
          )!.asset,
          isNull,
        );
        final duplicate = release();
        (duplicate['assets'] as List).add((duplicate['assets'] as List).first);
        expect(
          AppUpdateRelease.fromJson(
            duplicate,
            const AppUpdateTarget('windows', 'x64'),
          ),
          isNull,
        );
      },
    );

    test('manual revalidation uses persisted ETag and accepts 304', () async {
      var requests = 0;
      var now = DateTime.utc(2026);
      final store = MemoryUpdateStore();
      http.Client client() => MockClient((request) async {
        requests++;
        if (requests == 1) {
          return http.Response(
            jsonEncode([release()]),
            200,
            headers: {'etag': '"release-1"'},
          );
        }
        expect(request.headers['if-none-match'], '"release-1"');
        return http.Response('', 304);
      });
      final first = service(client: client(), store: store, clock: () => now);
      addTearDown(first.dispose);
      await first.check();
      now = now.add(const Duration(minutes: 5));
      final second = service(client: client(), store: store, clock: () => now);
      addTearDown(second.dispose);
      final result = await second.check(manual: true);
      expect(result.release!.tag, 'v1.2.0');
      expect(result.checkedAt, now);
      expect(requests, 2);
    });

    for (final status in [403, 429]) {
      test(
        'HTTP $status persists retry deadline and manual cannot bypass it',
        () async {
          var now = DateTime.utc(2026);
          var requests = 0;
          final store = MemoryUpdateStore();
          final reset = now.add(const Duration(minutes: 5));
          http.Client client() => MockClient((_) async {
            requests++;
            return requests == 1
                ? http.Response(
                    '',
                    status,
                    headers: {
                      'retry-after': '120',
                      'x-ratelimit-reset':
                          '${reset.millisecondsSinceEpoch ~/ 1000}',
                    },
                  )
                : http.Response('[]', 200);
          });
          final checker = service(
            client: client(),
            store: store,
            clock: () => now,
          );
          addTearDown(checker.dispose);
          await expectLater(
            checker.check(),
            throwsA(
              isA<AppUpdateException>().having(
                (e) => e.retryAt,
                'deadline',
                reset,
              ),
            ),
          );
          expect(jsonDecode(store.value!)['checked_at'], isNull);
          final restarted = service(
            client: client(),
            store: store,
            clock: () => now,
          );
          addTearDown(restarted.dispose);
          now = now.add(const Duration(minutes: 3));
          await expectLater(
            restarted.check(manual: true),
            throwsA(isA<AppUpdateException>()),
          );
          expect(requests, 1);
          now = now.add(const Duration(minutes: 3));
          expect((await restarted.check(manual: true)).cached, isFalse);
          expect(requests, 2);
        },
      );
    }

    test(
      'HTTP date and successful exhausted quota respect server reset',
      () async {
        var now = DateTime.utc(2026);
        var requests = 0;
        final checker = service(
          clock: () => now,
          client: MockClient((_) async {
            requests++;
            return http.Response(
              '[]',
              200,
              headers: {
                'x-ratelimit-remaining': '0',
                'retry-after': 'Thu, 01 Jan 2026 00:10:00 GMT',
              },
            );
          }),
        );
        addTearDown(checker.dispose);
        await checker.check();
        expect(checker.retryAt, DateTime.utc(2026, 1, 1, 0, 10));
        now = now.add(const Duration(minutes: 2));
        await expectLater(
          checker.check(manual: true),
          throwsA(isA<AppUpdateException>()),
        );
        expect(requests, 1);
      },
    );

    test(
      'timeout aborts transport before headers and during streamed body',
      () async {
        for (final bodyStarted in [false, true]) {
          var aborted = false;
          final headers = Completer<http.StreamedResponse>();
          final body = StreamController<List<int>>();
          final client = RequestProbeClient((request) {
            expect(request, isA<http.Abortable>());
            unawaited(
              (request as http.Abortable).abortTrigger!.then((_) {
                aborted = true;
                if (!bodyStarted) {
                  headers.completeError(http.RequestAbortedException());
                }
                if (bodyStarted) body.addError(http.RequestAbortedException());
                unawaited(body.close());
              }),
            );
            return bodyStarted
                ? Future.value(http.StreamedResponse(body.stream, 200))
                : headers.future;
          });
          final checker = service(
            client: client,
            timeout: const Duration(milliseconds: 10),
          );
          await expectLater(
            checker.check(),
            throwsA(
              isA<AppUpdateException>().having(
                (e) => e.message,
                'timeout',
                contains('timed out'),
              ),
            ),
          );
          await Future<void>.delayed(Duration.zero);
          expect(aborted, isTrue);
          checker.dispose();
        }
      },
    );

    test('oversized response is rejected without persisting success', () async {
      final store = MemoryUpdateStore();
      final checker = service(
        store: store,
        client: MockClient(
          (_) async => http.Response(' ' * (4 * 1024 * 1024 + 1), 200),
        ),
      );
      addTearDown(checker.dispose);
      await expectLater(checker.check(), throwsA(isA<AppUpdateException>()));
      expect(store.value, isNull);
    });

    test(
      'dispose aborts an active request without late notifier callbacks',
      () async {
        final entered = Completer<void>();
        final response = Completer<http.StreamedResponse>();
        var aborted = false;
        final controller = AppUpdateController(
          service(
            client: RequestProbeClient((request) {
              entered.complete();
              unawaited(
                (request as http.Abortable).abortTrigger!.then((_) {
                  aborted = true;
                  response.completeError(http.RequestAbortedException());
                }),
              );
              return response.future;
            }),
          ),
        );
        var notifications = 0;
        controller.addListener(() => notifications++);
        final pending = controller.check();
        await entered.future;
        controller.dispose();
        final before = notifications;
        await pending;
        expect(aborted, isTrue);
        expect(notifications, before);
      },
    );
  });

  group('version precedence', () {
    test('SemVer numeric, prerelease and build rules', () {
      expect(
        AppVersion.tryParse('v1.10.0')!
            .isNewerThan(AppVersion.tryParse('1.9.9')!),
        isTrue,
      );
      expect(
        AppVersion.tryParse('1.0.0')!
            .isNewerThan(AppVersion.tryParse('1.0.0-rc.10')!),
        isTrue,
      );
      expect(
        AppVersion.tryParse('1.0.0-rc.10')!
            .compareTo(AppVersion.tryParse('1.0.0-rc.2')!),
        greaterThan(0),
      );
      expect(
        AppVersion.tryParse('1.0.0-alpha.1')!
            .compareTo(AppVersion.tryParse('1.0.0-alpha.beta')!),
        lessThan(0),
      );
      expect(
        AppVersion.tryParse('1.0.0+9')!
            .compareTo(AppVersion.tryParse('1.0.0+2')!),
        0,
      );
      expect(
        AppVersion.tryParse('1.0.0+9')!
            .isNewerThan(AppVersion.tryParse('1.0.0+2')!),
        isTrue,
      );
      expect(
        AppVersion.tryParse('1.0.0')!
            .isNewerThan(AppVersion.tryParse('1.0.0+2')!),
        isFalse,
      );
      for (final value in [
        '01.2.3',
        '1.02.3',
        '1.2.03',
        '1.2',
        '1.2.3-01',
        '1.2.3 garbage',
        'v1.2.3/path',
      ]) {
        expect(AppVersion.tryParse(value), isNull, reason: value);
      }
    });
  });

  group('public release selection', () {
    test('uses only official API without auth; skips drafts and prereleases; sorts versions', () async {
      final checker = service(
        client: MockClient((request) async {
          expect(request.url, appUpdateApi);
          expect(request.url.scheme, 'https');
          expect(request.url.host, 'api.github.com');
          expect(
            request.headers.keys.map((key) => key.toLowerCase()),
            isNot(contains('authorization')),
          );
          expect(
            request.headers.keys.map((key) => key.toLowerCase()),
            isNot(contains('cookie')),
          );
          expect(request.followRedirects, isFalse);
          return http.Response(
            jsonEncode([
              release(tag: 'v9.0.0', draft: true),
              release(tag: 'v8.0.0', prerelease: true),
              release(tag: 'v7.0.0-beta.1'),
              release(tag: 'v1.9.0'),
              release(tag: 'v1.10.0'),
              release(tag: 'v1.3.0'),
            ]),
            200,
          );
        }),
      );
      addTearDown(checker.dispose);
      final result = await checker.check();
      expect(result.release!.tag, 'v1.10.0');
      expect(
        result.release!.asset!.name,
        'Segmeris-v1.10.0-windows-x64-setup.exe',
      );
    });

    test(
      'compares official release build marker to package build number',
      () async {
        final checker = service(
          current: '1.2.0+3',
          client: MockClient(
            (_) async => http.Response(
              jsonEncode([
                release(
                  body: '<!-- segmeris-release {"version":"1.2.0","build_number":4} -->\nFixes',
                ),
              ]),
              200,
            ),
          ),
        );
        addTearDown(checker.dispose);
        final result = await checker.check();
        expect(result.release!.version.build, 4);
        expect(result.release!.notes, 'Fixes');
      },
    );

    test(
      'does not invent a build upgrade when metadata is absent or mismatched',
      () async {
        final checker = service(
          current: '1.2.0+3',
          client: MockClient(
            (_) async => http.Response(
              jsonEncode([
                release(
                  body: '<!-- segmeris-release {"version":"1.9.0","build_number":9} -->',
                ),
                release(),
              ]),
              200,
            ),
          ),
        );
        addTearDown(checker.dispose);
        expect((await checker.check()).release, isNull);
      },
    );

    test('rejects unofficial, credential-bearing and redirected release URLs', () async {
      for (final url in [
        'http://github.com/blueokanna/Segmeris/releases/tag/v1.2.0',
        'https://github.com.evil.test/blueokanna/Segmeris/releases/tag/v1.2.0',
        'https://github.com/other/Segmeris/releases/tag/v1.2.0',
        'https://token@github.com/blueokanna/Segmeris/releases/tag/v1.2.0',
        'https://github.com:8443/blueokanna/Segmeris/releases/tag/v1.2.0',
        'https://github.com/blueokanna/Segmeris/releases/tag/v1.2.0?redirect=evil',
        'https://github.com/blueokanna/Segmeris/releases/tag/v1.2.0#evil',
        'file:///etc/passwd',
      ]) {
        final item = release()..['html_url'] = url;
        expect(
          AppUpdateRelease.fromJson(
            item,
            const AppUpdateTarget('windows', 'x64'),
          ),
          isNull,
          reason: url,
        );
      }
    });

    test(
      'ignores unsafe asset and falls back to the official release page',
      () {
        final item = release();
        for (final asset in item['assets'] as List) {
          asset['browser_download_url'] = 'https://evil.test/install.exe';
        }
        final parsed = AppUpdateRelease.fromJson(
          item,
          const AppUpdateTarget('windows', 'x64'),
        )!;
        expect(parsed.asset, isNull);
        expect(parsed.pageUrl.host, 'github.com');
      },
    );

    test(
      'maps every supported process ABI without cross-architecture fallback',
      () {
        const mappings = {
          ('android', 'arm64'): 'android-arm64-v8a.apk',
          ('android', 'arm'): 'android-armeabi-v7a.apk',
          ('android', 'x64'): 'android-x86_64.apk',
          ('windows', 'x64'): 'windows-x64-setup.exe',
          ('linux', 'x64'): 'linux-x64.tar.gz',
          ('macos', 'arm64'): 'macos-arm64-unsigned.zip',
          ('macos', 'x64'): 'macos-x64-unsigned.zip',
        };
        final item = release(suffixes: mappings.values.toList());
        for (final entry in mappings.entries) {
          final parsed = AppUpdateRelease.fromJson(
            item,
            AppUpdateTarget(entry.key.$1, entry.key.$2),
          )!;
          expect(parsed.asset!.name, endsWith(entry.value));
        }
        for (final target in [
          const AppUpdateTarget('windows', 'arm64'),
          const AppUpdateTarget('linux', 'arm64'),
          const AppUpdateTarget('android', 'x86'),
          const AppUpdateTarget('ios', 'arm64'),
          const AppUpdateTarget('web', 'unknown'),
        ]) {
          expect(AppUpdateRelease.fromJson(item, target)!.asset, isNull);
        }
      },
    );

    test(
      'empty asset, wrong tag and extra script suffix cannot be selected',
      () {
        final item = release(
          suffixes: ['windows-x64-setup.exe.sh', 'windows-arm64-setup.exe'],
        );
        expect(
          AppUpdateRelease.fromJson(
            item,
            const AppUpdateTarget('windows', 'x64'),
          )!.asset,
          isNull,
        );
        final bad = release(suffixes: ['windows-x64.zip']);
        (bad['assets'] as List).first['browser_download_url'] = 'https://github.com/blueokanna/Segmeris/releases/download/v9.9.9/Segmeris-v1.2.0-windows-x64.zip';
        expect(
          AppUpdateRelease.fromJson(
            bad,
            const AppUpdateTarget('windows', 'x64'),
          )!.asset,
          isNull,
        );
        (bad['assets'] as List).first['size'] = 0;
        expect(
          AppUpdateRelease.fromJson(
            bad,
            const AppUpdateTarget('windows', 'x64'),
          )!.asset,
          isNull,
        );
      },
    );
  });

  group('error handling and 24 hour cache', () {
    test('successful checks persist, survive restart, expire and manual checks bypass', () async {
      var calls = 0;
      var now = DateTime.utc(2026, 1, 1);
      final store = MemoryUpdateStore();
      http.Client client() => MockClient((_) async {
        calls++;
        return http.Response(jsonEncode([release()]), 200);
      });
      final checker = service(client: client(), store: store, clock: () => now);
      addTearDown(checker.dispose);
      expect((await checker.check()).cached, isFalse);
      expect((await checker.check()).cached, isTrue);
      expect(calls, 1);
      final restarted = service(
        client: client(),
        store: store,
        clock: () => now,
      );
      addTearDown(restarted.dispose);
      expect((await restarted.check()).release!.tag, 'v1.2.0');
      expect(calls, 1);
      await restarted.check(manual: true);
      expect(calls, 2);
      now = now.add(const Duration(hours: 24));
      expect((await restarted.check()).cached, isFalse);
      expect(calls, 3);
    });

    test(
      'HTTP, JSON and network failures do not persist a successful check',
      () async {
        for (final status in [302, 404, 500]) {
          var calls = 0;
          final store = MemoryUpdateStore();
          final checker = service(
            store: store,
            client: MockClient((_) async {
              calls++;
              return calls == 1
                  ? http.Response('secret upstream diagnostic', status)
                  : http.Response('[]', 200);
            }),
          );
          addTearDown(checker.dispose);
          await expectLater(
            checker.check(),
            throwsA(
              isA<AppUpdateException>().having(
                (e) => e.message,
                'safe message',
                isNot(contains('secret')),
              ),
            ),
          );
          expect(store.value, isNull);
          expect((await checker.check()).cached, isFalse);
          expect(calls, 2);
        }
        for (final response in ['not json', '{}']) {
          final store = MemoryUpdateStore();
          final checker = service(
            store: store,
            client: MockClient((_) async => http.Response(response, 200)),
          );
          addTearDown(checker.dispose);
          await expectLater(
            checker.check(),
            throwsA(isA<AppUpdateException>()),
          );
          expect(store.writes, 0);
        }
        final checker = service(
          client: MockClient(
            (_) async => throw http.ClientException('private-token'),
          ),
        );
        addTearDown(checker.dispose);
        await expectLater(
          checker.check(),
          throwsA(
            isA<AppUpdateException>().having(
              (e) => e.message,
              'redacted error',
              isNot(contains('private-token')),
            ),
          ),
        );
      },
    );

    test(
      'timeout permits retry, storage failures do not break checking',
      () async {
        var calls = 0;
        final hanging = Completer<http.Response>();
        final store = MemoryUpdateStore()
          ..failRead = true
          ..failWrite = true;
        final checker = service(
          store: store,
          timeout: const Duration(milliseconds: 5),
          client: MockClient((_) {
            calls++;
            return calls == 1
                ? hanging.future
                : Future.value(http.Response('[]', 200));
          }),
        );
        addTearDown(checker.dispose);
        await expectLater(checker.check(), throwsA(isA<AppUpdateException>()));
        expect((await checker.check()).cached, isFalse);
        expect((await checker.check()).cached, isTrue);
        expect(calls, 2);
        hanging.complete(http.Response('[]', 200));
      },
    );

    test(
      'corrupt or future cache timestamps cannot suppress checks forever',
      () async {
        for (final value in [
          'broken',
          jsonEncode({'checked_at': '2099-01-01T00:00:00Z', 'releases': []}),
        ]) {
          var calls = 0;
          final store = MemoryUpdateStore()..value = value;
          final checker = service(
            store: store,
            clock: () => DateTime.utc(2026),
            client: MockClient((_) async {
              calls++;
              return http.Response('[]', 200);
            }),
          );
          addTearDown(checker.dispose);
          await checker.check();
          expect(calls, 1);
        }
      },
    );

    test('concurrent checks share a request', () async {
      var calls = 0;
      final response = Completer<http.Response>();
      final checker = service(
        client: MockClient((_) {
          calls++;
          return response.future;
        }),
      );
      addTearDown(checker.dispose);
      final one = checker.check();
      final two = checker.check();
      response.complete(http.Response('[]', 200));
      await Future.wait([one, two]);
      expect(calls, 1);
    });
  });

  testWidgets('update UI opens nothing until a click, can dismiss and retry', (
    tester,
  ) async {
    final opened = <Uri>[];
    final controller = AppUpdateController(
      service(
        client: MockClient(
          (_) async => http.Response(jsonEncode([release()]), 200),
        ),
      ),
      opener: (uri) async {
        opened.add(uri);
        return true;
      },
    );
    addTearDown(controller.dispose);
    await controller.check();
    expect(opened, isEmpty);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: AppUpdateCard(controller: controller)),
      ),
    );
    expect(find.textContaining('v1.2.0'), findsOneWidget);
    await tester.tap(find.text('View update'));
    await tester.pumpAndSettle();
    expect(opened.single.path, '/blueokanna/Segmeris/releases/tag/v1.2.0');
    await tester.tap(find.text('Download update'));
    await tester.pumpAndSettle();
    expect(opened, hasLength(2));
    expect(
      opened.last.path,
      '/blueokanna/Segmeris/releases/download/v1.2.0/Segmeris-v1.2.0-windows-x64-setup.exe',
    );
    await tester.tap(find.text('Later'));
    await tester.pumpAndSettle();
    expect(find.textContaining('v1.2.0'), findsNothing);
    await controller.check(manual: true);
    await tester.pumpAndSettle();
    expect(find.textContaining('v1.2.0'), findsOneWidget);
  });

  testWidgets('unknown ABI offers release notes without a download button', (
    tester,
  ) async {
    final controller = AppUpdateController(
      service(
        target: const AppUpdateTarget('windows', 'arm64'),
        client: MockClient(
          (_) async => http.Response(jsonEncode([release()]), 200),
        ),
      ),
    );
    addTearDown(controller.dispose);
    await controller.check();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: AppUpdateCard(controller: controller)),
      ),
    );
    expect(find.text('View update'), findsOneWidget);
    expect(find.text('Download update'), findsNothing);
  });

  testWidgets('offline stays quiet at home and settings exposes retry', (
    tester,
  ) async {
    var calls = 0;
    final controller = AppUpdateController(
      service(
        client: MockClient((_) async {
          calls++;
          return http.Response(
            calls == 1 ? 'offline' : '[]',
            calls == 1 ? 503 : 200,
          );
        }),
      ),
    );
    addTearDown(controller.dispose);
    await controller.check();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: AppUpdateCard(controller: controller)),
      ),
    );
    expect(find.byType(Card), findsNothing);
    expect(find.text('Retry'), findsNothing);
    expect(find.byType(AlertDialog), findsNothing);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AppUpdateCard(controller: controller, alwaysVisible: true),
        ),
      ),
    );
    expect(find.text('Retry'), findsOneWidget);
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(calls, 2);
    expect(find.text('You have the latest stable version.'), findsOneWidget);
  });
}
