import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

int _tableOffset(ByteData font, String tag) {
  final tables = font.getUint16(4);
  for (var i = 0; i < tables; i++) {
    final entry = 12 + i * 16;
    final name = String.fromCharCodes(
      List.generate(4, (n) => font.getUint8(entry + n)),
    );
    if (name == tag) return font.getUint32(entry + 8);
  }
  throw StateError('Missing font table: $tag');
}

Set<String> _familyNames(ByteData font) {
  final base = _tableOffset(font, 'name');
  final count = font.getUint16(base + 2);
  final strings = base + font.getUint16(base + 4);
  final names = <String>{};
  for (var i = 0; i < count; i++) {
    final entry = base + 6 + i * 12;
    if (font.getUint16(entry) != 3 || font.getUint16(entry + 6) != 1) continue;
    final length = font.getUint16(entry + 8);
    final start = strings + font.getUint16(entry + 10);
    names.add(
      String.fromCharCodes(
        List.generate(length ~/ 2, (n) => font.getUint16(start + n * 2)),
      ),
    );
  }
  return names;
}

bool _containsGlyph(ByteData font, int codepoint) {
  final cmap = _tableOffset(font, 'cmap');
  final count = font.getUint16(cmap + 2);
  for (var i = 0; i < count; i++) {
    final entry = cmap + 4 + i * 8;
    final platform = font.getUint16(entry);
    if (platform != 0 && platform != 3) continue;
    final subtable = cmap + font.getUint32(entry + 4);
    final format = font.getUint16(subtable);
    if (format == 12) {
      final groups = font.getUint32(subtable + 12);
      for (var group = 0; group < groups; group++) {
        final start = subtable + 16 + group * 12;
        final first = font.getUint32(start);
        final last = font.getUint32(start + 4);
        if (first <= codepoint && codepoint <= last) {
          return font.getUint32(start + 8) + codepoint - first != 0;
        }
      }
    } else if (format == 4 && codepoint <= 0xffff) {
      final segments = font.getUint16(subtable + 6) ~/ 2;
      final ends = subtable + 14;
      final starts = ends + 2 * segments + 2;
      final deltas = starts + 2 * segments;
      final offsets = deltas + 2 * segments;
      for (var segment = 0; segment < segments; segment++) {
        final first = font.getUint16(starts + segment * 2);
        final last = font.getUint16(ends + segment * 2);
        if (first > codepoint || last < codepoint) continue;
        final delta = font.getInt16(deltas + segment * 2);
        final offsetAddress = offsets + segment * 2;
        final rangeOffset = font.getUint16(offsetAddress);
        if (rangeOffset == 0) return ((codepoint + delta) & 0xffff) != 0;
        final glyph = font.getUint16(
          offsetAddress + rangeOffset + 2 * (codepoint - first),
        );
        return glyph != 0 && ((glyph + delta) & 0xffff) != 0;
      }
    }
  }
  return false;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'bundled binaries identify Google Latin and original Huawei Chinese glyphs',
    () async {
      final latin = await rootBundle.load(
        'assets/fonts/google/GoogleSansFlex.ttf',
      );
      expect(latin.lengthInBytes, 3910784);
      expect(_familyNames(latin), contains('Google Sans Flex'));
      expect(_containsGlyph(latin, 'A'.codeUnitAt(0)), isTrue);
      expect(_containsGlyph(latin, '中'.codeUnitAt(0)), isFalse);
      for (final (weight, bytes) in [
        ('Regular', 8261128),
        ('Medium', 8227312),
        ('Bold', 8158996),
      ]) {
        final chinese = await rootBundle.load(
          'assets/fonts/huawei/HarmonyOS_Sans_SC_$weight.ttf',
        );
        expect(chinese.lengthInBytes, bytes);
        expect(
          _familyNames(chinese)
              .any((name) => name.startsWith('HarmonyOS Sans SC')),
          isTrue,
        );
        for (final glyph in '中文下载'.codeUnits) {
          expect(
            _containsGlyph(chinese, glyph),
            isTrue,
            reason: '$weight U+${glyph.toRadixString(16)}',
          );
        }
      }
    },
  );

  test(
    'both complete font licenses are accessible as packaged assets',
    () async {
      final huawei = await rootBundle.loadString(
        'assets/fonts/huawei/LICENSE.txt',
      );
      final google = await rootBundle.loadString('assets/fonts/google/OFL.txt');
      expect(huawei, contains('HarmonyOS Sans Fonts License Agreement'));
      expect(huawei, contains('Huawei Device Co., Ltd.'));
      expect(google, contains('SIL OPEN FONT LICENSE Version 1.1'));
    },
  );
}
