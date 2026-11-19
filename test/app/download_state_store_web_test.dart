import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:segmeris/src/app/download_state_store.dart';
import 'package:segmeris/src/app/download_state_store_web.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('SharedPreferencesDownloadStateStore', () {
    late SharedPreferences preferences;
    late SharedPreferencesDownloadStateStore store;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      preferences = await SharedPreferences.getInstance();
      store = SharedPreferencesDownloadStateStore(preferences: preferences);
    });

    test('the browser factory selects SharedPreferences', () {
      expect(
        createDownloadStateStore(),
        isA<SharedPreferencesDownloadStateStore>(),
      );
    }, skip: !kIsWeb);

    test(
      'empty storage loads null; persisted generations survive reopening',
      () async {
        expect(await store.load(), isNull);
        await store.save({'value': '第一代 🎬'});
        await store.save({'value': 'second'});
        await store.save({'value': 'third'});
        final reopened = SharedPreferencesDownloadStateStore();
        expect(await reopened.load(), {'value': 'third'});
        expect(
          jsonDecode(preferences.getString(store.slotKey(0))!)['generation'],
          3,
        );
        expect(
          jsonDecode(preferences.getString(store.slotKey(1))!)['generation'],
          2,
        );
      },
    );

    test(
      'the envelope checksum has identical VM and JavaScript output',
      () async {
        await store.save({'message': '测试 🎬'});
        final envelope = jsonDecode(preferences.getString(store.slotKey(0))!);
        // CRC32 of UTF-8: 1:1:{"message":"测试 🎬"}.
        expect(envelope['checksum'], '00333348');
      },
    );

    test(
      'corrupt latest JSON falls back and the next save repairs its slot',
      () async {
        await store.save({'value': 'old'});
        await store.save({'value': 'new'});
        await preferences.setString(store.slotKey(1), '{broken');
        expect(await SharedPreferencesDownloadStateStore().load(), {
          'value': 'old',
        });
        expect(preferences.getString(store.slotKey(1)), '{broken');
        await store.save({'value': 'repaired'});
        expect(await store.load(), {'value': 'repaired'});
      },
    );

    test('valid JSON with changed payload fails checksum validation', () async {
      await store.save({'value': 'old'});
      await store.save({'value': 'new'});
      final envelope =
          jsonDecode(preferences.getString(store.slotKey(1))!) as Map;
      envelope['payload'] = '{"value":"corrupt"}';
      await preferences.setString(store.slotKey(1), jsonEncode(envelope));
      expect(await store.load(), {'value': 'old'});
    });

    test(
      'all corrupt keys reject load and save without removing data',
      () async {
        await preferences.setString(store.slotKey(0), 'broken zero');
        await preferences.setString(store.slotKey(1), 'broken one');
        await expectLater(
          store.load(),
          throwsA(isA<DownloadStateCorruptionException>()),
        );
        await expectLater(
          store.save({'new': true}),
          throwsA(isA<DownloadStateCorruptionException>()),
        );
        expect(preferences.getString(store.slotKey(0)), 'broken zero');
        expect(preferences.getString(store.slotKey(1)), 'broken one');
      },
    );

    test(
      'wrong preference type is corruption rather than an empty store',
      () async {
        await preferences.setInt(store.slotKey(0), 42);
        await expectLater(
          store.load(),
          throwsA(isA<DownloadStateCorruptionException>()),
        );
        expect(preferences.getInt(store.slotKey(0)), 42);
      },
    );

    test('load and save order is shared across instances', () async {
      final another = SharedPreferencesDownloadStateStore();
      final first = store.save({'sequence': 1});
      final middle = another.load();
      final second = another.save({'sequence': 2});
      final third = store.save({'sequence': 3});
      await Future.wait([first, second, third]);
      expect(await middle, {'sequence': 1});
      expect(await another.load(), {'sequence': 3});
    });

    test('caller and loaded maps cannot mutate a persisted snapshot', () async {
      final data = <String, dynamic>{
        'tasks': ['original'],
      };
      final saving = store.save(data);
      (data['tasks'] as List).add('changed');
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
      'rejected writes preserve backup and failed cache is reloaded',
      () async {
        final rejecting = _RejectingPreferences(preferences);
        final checked = SharedPreferencesDownloadStateStore(
          preferences: rejecting,
        );
        await checked.save({'value': 'old'});
        rejecting.rejectNextWrite = true;
        await expectLater(
          checked.save({'value': 'failed'}),
          throwsA(isA<DownloadStateStoreException>()),
        );
        expect(await checked.load(), {'value': 'old'});
        expect(preferences.getString(checked.slotKey(1)), isNull);
        await checked.save({'value': 'recovered'});
        expect(await checked.load(), {'value': 'recovered'});
      },
    );

    test(
      'serialization and corrupt-read failures do not poison the queue',
      () async {
        await expectLater(store.save({'bad': Object()}), throwsA(anything));
        await store.save({'value': 'old'});
        final original = preferences.getString(store.slotKey(0))!;
        await preferences.setString(store.slotKey(0), 'broken');
        await expectLater(
          store.load(),
          throwsA(isA<DownloadStateCorruptionException>()),
        );
        await preferences.setString(store.slotKey(0), original);
        await store.save({'value': 'recovered'});
        expect(await store.load(), {'value': 'recovered'});
      },
    );
  });
}

/// Simulates a plugin updating its cache before its backend rejects a write.
class _RejectingPreferences implements SharedPreferences {
  _RejectingPreferences(this.delegate);

  final SharedPreferences delegate;
  final _uncommittedCache = <String, Object>{};
  bool rejectNextWrite = false;

  @override
  Object? get(String key) => _uncommittedCache[key] ?? delegate.get(key);

  @override
  Future<void> reload() async {
    await delegate.reload();
    _uncommittedCache.clear();
  }

  @override
  Future<bool> setString(String key, String value) async {
    if (rejectNextWrite) {
      rejectNextWrite = false;
      _uncommittedCache[key] = value;
      return false;
    }
    return delegate.setString(key, value);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
