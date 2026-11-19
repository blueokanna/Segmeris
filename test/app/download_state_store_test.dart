import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:segmeris/src/app/download_state_store.dart';
import 'package:segmeris/src/app/download_state_store_io.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('FileDownloadStateStore', () {
    late Directory directory;
    late FileDownloadStateStore store;

    File slot(int index) => File(
      '${directory.path}${Platform.pathSeparator}'
      '${FileDownloadStateStore.slotFileNames[index]}',
    );

    setUp(() async {
      directory = await Directory.systemTemp.createTemp('download_state_test_');
      store = FileDownloadStateStore(directory: directory);
    });

    tearDown(() async => directory.delete(recursive: true));

    test('the platform factory is lazy and chooses files on native', () {
      expect(createDownloadStateStore(), isA<FileDownloadStateStore>());
    });

    test('only a directory without snapshots loads null', () async {
      expect(await store.load(), isNull);
      expect(await directory.list().toList(), isEmpty);
    });

    test(
      'real files survive rebuilding the instance and preserve JSON',
      () async {
        final data = <String, dynamic>{
          'tasks': [
            {'id': '测试 🎬', 'progress': 0.25, 'paused': true, 'error': null},
          ],
          'settings': <String, dynamic>{},
        };
        await store.save(data);
        final reopened = FileDownloadStateStore(directory: directory);
        expect(await reopened.load(), data);
        expect(await slot(0).exists(), isTrue);
        expect(await File('${slot(0).path}.tmp').exists(), isFalse);
      },
    );

    test(
      'saves and loads are ordered across instances sharing a path',
      () async {
        final another = FileDownloadStateStore(directory: directory);
        final first = store.save({'sequence': 1});
        final middle = another.load();
        final second = another.save({'sequence': 2});
        final third = store.save({'sequence': 3});
        final last = another.load();
        await Future.wait([first, second, third]);
        expect(await middle, {'sequence': 1});
        expect(await last, {'sequence': 3});
        final snapshots = [
          jsonDecode(await slot(0).readAsString()),
          jsonDecode(await slot(1).readAsString()),
        ];
        expect(snapshots.map((value) => value['generation']), [3, 2]);
      },
    );

    test('save captures caller data before waiting in the queue', () async {
      final data = <String, dynamic>{
        'tasks': ['original'],
      };
      final saving = store.save(data);
      (data['tasks'] as List).add('later mutation');
      await saving;
      final loaded = (await store.load())!;
      expect(loaded, {
        'tasks': ['original'],
      });
      (loaded['tasks'] as List).clear();
      expect(await store.load(), {
        'tasks': ['original'],
      });
    });

    test(
      'corrupt current generation falls back without modifying files',
      () async {
        await store.save({'generation': 'old'});
        await store.save({'generation': 'new'});
        const corrupt = '{"truncated":';
        await slot(1).writeAsString(corrupt, flush: true);
        expect(await FileDownloadStateStore(directory: directory).load(), {
          'generation': 'old',
        });
        expect(await slot(1).readAsString(), corrupt);
        await store.save({'generation': 'repaired'});
        expect(await store.load(), {'generation': 'repaired'});
        expect(jsonDecode(await slot(0).readAsString())['generation'], 1);
      },
    );

    for (final field in ['payload', 'generation', 'version', 'checksum']) {
      test('valid JSON with altered $field falls back to the backup', () async {
        await store.save({'value': 'old'});
        await store.save({'value': 'new'});
        final envelope = jsonDecode(await slot(1).readAsString()) as Map;
        envelope[field] = switch (field) {
          'payload' => '{"value":"altered"}',
          'generation' => 100,
          'version' => 99,
          _ => '00000000',
        };
        await slot(1).writeAsString(jsonEncode(envelope), flush: true);
        expect(await store.load(), {'value': 'old'});
      });
    }

    test('invalid UTF-8 falls back to the previous generation', () async {
      await store.save({'value': 'old'});
      await store.save({'value': 'new'});
      await slot(1).writeAsBytes([0xff, 0xfe], flush: true);
      expect(await store.load(), {'value': 'old'});
    });

    test(
      'all corrupt snapshots throw on load/save and preserve evidence',
      () async {
        await slot(0).writeAsString('broken first', flush: true);
        await slot(1).writeAsString('broken second', flush: true);
        await expectLater(
          store.load(),
          throwsA(isA<DownloadStateCorruptionException>()),
        );
        await expectLater(
          store.save({'new': true}),
          throwsA(isA<DownloadStateCorruptionException>()),
        );
        expect(await slot(0).readAsString(), 'broken first');
        expect(await slot(1).readAsString(), 'broken second');
        expect(await directory.list().length, 2);
      },
    );

    test(
      'failed load does not poison the queue after external recovery',
      () async {
        await store.save({'value': 'old'});
        final preserved = await slot(0).readAsString();
        await slot(0).writeAsString('broken', flush: true);
        await expectLater(
          store.load(),
          throwsA(isA<DownloadStateCorruptionException>()),
        );
        await slot(0).writeAsString(preserved, flush: true);
        await store.save({'value': 'recovered'});
        expect(await store.load(), {'value': 'recovered'});
      },
    );

    test('serialization failure does not poison later operations', () async {
      await expectLater(store.save({'bad': Object()}), throwsA(anything));
      await store.save({'valid': true});
      expect(await store.load(), {'valid': true});
    });

    for (final stage in [
      'partial write',
      'flushed',
      'removed old',
      'renamed',
    ]) {
      test('restart recovers after crash at $stage', () async {
        await store.save({'value': 1});
        final first = await slot(0).readAsString();
        await store.save({'value': 2});
        await store.save({'value': 3});
        final third = await slot(0).readAsString();
        final staging = File('${slot(0).path}.tmp');

        if (stage != 'renamed') {
          await slot(0).writeAsString(first, flush: true);
          await staging.writeAsString(
            stage == 'partial write'
                ? third.substring(0, third.length ~/ 2)
                : third,
            flush: true,
          );
          if (stage == 'removed old') await slot(0).delete();
        }

        final reopened = FileDownloadStateStore(directory: directory);
        expect(await reopened.load(), {
          'value': stage == 'partial write' ? 2 : 3,
        });
        await reopened.save({'value': 4});
        expect(await FileDownloadStateStore(directory: directory).load(), {
          'value': 4,
        });
      });
    }

    test(
      'a complete staging file recovers an interrupted first save',
      () async {
        await store.save({'value': 1});
        await slot(0).rename('${slot(0).path}.tmp');
        expect(await FileDownloadStateStore(directory: directory).load(), {
          'value': 1,
        });
        await store.save({'value': 2});
        expect(await store.load(), {'value': 2});
      },
    );

    test('an incomplete first staging file is corruption, not empty', () async {
      final staging = File('${slot(0).path}.tmp');
      await staging.writeAsString('{"version":', flush: true);
      await expectLater(
        store.load(),
        throwsA(isA<DownloadStateCorruptionException>()),
      );
      await expectLater(
        store.save({'value': 1}),
        throwsA(isA<DownloadStateCorruptionException>()),
      );
      expect(await staging.readAsString(), '{"version":');
    });

    test('a real rename failure preserves data and does not poison queue', () async {
      await store.save({'value': 'old'});
      // A directory at the target path makes File.rename fail on all platforms.
      await Directory(slot(1).path).create();
      await expectLater(
        store.save({'value': 'staged'}),
        throwsA(isA<FileSystemException>()),
      );
      expect(jsonDecode(await slot(0).readAsString())['generation'], 1);
      expect(await store.load(), {'value': 'staged'});
      await store.save({'value': 'recovered'});
      expect(await store.load(), {'value': 'recovered'});
    });
  });

  group('MemoryDownloadStateStore', () {
    test('defaults to no snapshot and returns isolated JSON copies', () async {
      final store = MemoryDownloadStateStore();
      expect(await store.load(), isNull);
      final input = <String, dynamic>{
        'values': [1],
      };
      final saving = store.save(input);
      (input['values'] as List).add(2);
      await saving;
      final loaded = (await store.load())!;
      expect(loaded, {
        'values': [1],
      });
      (loaded['values'] as List).clear();
      expect(await store.load(), {
        'values': [1],
      });
    });

    test('initial data is copied and instances are isolated', () async {
      final input = <String, dynamic>{'value': 'initial'};
      final store = MemoryDownloadStateStore(initialData: input);
      input['value'] = 'mutated';
      expect(await store.load(), {'value': 'initial'});
      expect(await MemoryDownloadStateStore().load(), isNull);
    });

    test('serializes load/save and recovers from invalid payloads', () async {
      final store = MemoryDownloadStateStore();
      final first = store.save({'value': 1});
      final middle = store.load();
      final second = store.save({'value': 2});
      await Future.wait([first, second]);
      expect(await middle, {'value': 1});
      expect(await store.load(), {'value': 2});
      await expectLater(store.save({'invalid': Object()}), throwsA(anything));
      await store.save({'value': 3});
      expect(await store.load(), {'value': 3});
    });
  });
}
