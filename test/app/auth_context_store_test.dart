import 'package:flutter_test/flutter_test.dart';
import 'package:segmeris/src/app/auth_context_store.dart';
import 'package:segmeris/src/rust/api/downloader.dart';
import 'package:shared_preferences/shared_preferences.dart';

RequestContext _context({
  String cookie = 'SESSDATA=abc; bili_jct=def',
  String userAgent = 'Mozilla/5.0',
  String referer = 'https://www.bilibili.com/',
  String origin = '',
  List<HeaderEntry> headers = const [],
}) {
  return RequestContext(
    userAgent: userAgent,
    referer: referer,
    origin: origin,
    cookie: cookie,
    headers: headers,
  );
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  test('a saved session comes back field for field', () async {
    final stored = _context(
      origin: 'https://www.bilibili.com',
      headers: const [
        HeaderEntry(name: 'X-Requested-With', value: 'XMLHttpRequest'),
        HeaderEntry(name: 'Accept-Language', value: 'zh-CN,zh;q=0.9'),
      ],
    );

    await AuthContextStore.save(stored);
    final restored = await AuthContextStore.load();

    expect(restored, isNotNull);
    expect(restored!.cookie, stored.cookie);
    expect(restored.userAgent, stored.userAgent);
    expect(restored.referer, stored.referer);
    expect(restored.origin, stored.origin);
    expect(restored.headers.length, 2);
    expect(restored.headers.first.name, 'X-Requested-With');
    expect(restored.headers.last.value, 'zh-CN,zh;q=0.9');
  });

  test('an empty context stores nothing', () async {
    await AuthContextStore.save(
      _context(cookie: '', userAgent: '', referer: '', origin: ''),
    );

    expect(await AuthContextStore.load(), isNull);
  });

  test('saving an empty context removes a previous one', () async {
    await AuthContextStore.save(_context());
    expect(await AuthContextStore.load(), isNotNull);

    await AuthContextStore.save(
      _context(cookie: '', userAgent: '', referer: '', origin: ''),
    );

    expect(await AuthContextStore.load(), isNull);
  });

  test('clearing removes the session', () async {
    await AuthContextStore.save(_context());
    await AuthContextStore.clear();

    expect(await AuthContextStore.load(), isNull);
  });

  test('an unreadable payload is treated as no session, not a crash', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'authContext': '{not json',
    });

    expect(await AuthContextStore.load(), isNull);
  });

  test('a payload from a future version is ignored', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'authContext': '{"v": 99, "cookie": "SESSDATA=abc"}',
    });

    expect(await AuthContextStore.load(), isNull);
  });

  test('header entries without a name or value are dropped', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'authContext':
          '{"v": 1, "cookie": "SESSDATA=abc", "ua": "", "referer": "", '
          '"origin": "", "headers": [{"name": "", "value": "x"}, '
          '{"name": "X-Trace", "value": ""}, {"name": "Ok", "value": "1"}, 7]}',
    });

    final restored = await AuthContextStore.load();

    expect(restored, isNotNull);
    expect(restored!.headers.length, 1);
    expect(restored.headers.single.name, 'Ok');
  });

  test('a context carrying only a user agent still counts as a session', () {
    expect(hasAuthOverrides(_context(cookie: '', referer: '')), isTrue);
    expect(
      hasAuthOverrides(
        _context(
          cookie: '',
          userAgent: '',
          referer: '',
          headers: const [HeaderEntry(name: 'X-Token', value: '1')],
        ),
      ),
      isTrue,
    );
    expect(
      hasAuthOverrides(
        _context(cookie: '', userAgent: '', referer: '', origin: ''),
      ),
      isFalse,
    );
  });
}
