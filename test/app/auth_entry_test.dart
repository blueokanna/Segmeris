import 'package:flutter_test/flutter_test.dart';
import 'package:segmeris/src/app/auth_entry.dart';

void main() {
  test('Bilibili pages open at the passport sign-in', () {
    for (final page in const [
      'https://www.bilibili.com/video/BV1GJ411x7h7',
      'https://www.bilibili.com/bangumi/play/ep1994063',
      'https://b23.tv/BV1GJ411x7h7',
      'https://m.bilibili.com/video/BV1GJ411x7h7',
    ]) {
      expect(
        authEntryUrlFor(page),
        'https://passport.bilibili.com/login',
        reason: page,
      );
    }
  });

  test('a host that merely contains the name is not Bilibili', () {
    expect(
      authEntryUrlFor('https://bilibili.com.evil.example/video'),
      'https://bilibili.com.evil.example',
    );
  });

  test('another site opens at its own origin, without the path', () {
    expect(
      authEntryUrlFor('https://www.example.com/watch?v=1&t=2'),
      'https://www.example.com',
    );
    expect(
      authEntryUrlFor('http://localhost:8080/media/1'),
      'http://localhost:8080',
    );
  });

  test('an unparsable input is passed through untouched', () {
    expect(authEntryUrlFor('not a url'), 'not a url');
    expect(authEntryUrlFor(''), '');
  });
}
