import 'package:flutter_test/flutter_test.dart';
import 'package:segmeris/src/home/quality_preference.dart';
import 'package:segmeris/src/rust/api/downloader.dart';

const _page = 'https://www.bilibili.com/bangumi/play/ep1994063';

MediaCandidate _candidate({
  required String id,
  required String label,
  String codec = 'AVC',
  String protocol = 'dash',
  int height = 1080,
}) {
  return MediaCandidate(
    id: id,
    title: '空中浩劫 第一季',
    extractor: 'bilibili',
    pageUrl: _page,
    mediaUrl: 'https://cdn.example/$id.mp4',
    mediaFallbackUrls: const [],
    audioUrl: 'https://cdn.example/$id.m4a',
    audioFallbackUrls: const [],
    container: 'mp4',
    protocol: protocol,
    mimeType: 'video/mp4',
    qualityLabel: label,
    qualityBadge: '',
    codec: codec,
    width: (height * 16 / 9).round(),
    height: height,
    requiresFfmpeg: false,
    score: 0,
    segmentCount: 0,
    durationSeconds: 0,
    primary: false,
    reason: '',
  );
}

void main() {
  final hd1080 = _candidate(id: 'v1080', label: '1080P 高清', height: 1080);
  final hd720 = _candidate(id: 'v720', label: '720P 高清', height: 720);
  final sd480 = _candidate(id: 'v480', label: '480P 标清', height: 480);

  test('an exact tier match wins over the best-ranked stream', () {
    final picked = candidateForTier([hd1080, hd720, sd480], sd480);
    expect(picked?.id, 'v480');
  });

  test('the same tier in another codec is preferred when the codec matches', () {
    final hevc480 = _candidate(
      id: 'hevc480',
      label: '480P 标清',
      codec: 'HEVC',
      height: 480,
    );
    final picked = candidateForTier([hd1080, sd480, hevc480], hevc480);
    expect(picked?.id, 'hevc480');
  });

  test('a tier the next episode does not offer falls back to its height', () {
    // A season whose later episodes drop the 60fps label keeps 1080 by height.
    final sixty = _candidate(
      id: 'v1080p60',
      label: '1080P 60帧 高码率',
      codec: 'AVC',
      height: 1080,
    );
    final plain1080 = _candidate(
      id: 'v1080plain',
      label: '1080P 高清',
      height: 1080,
    );
    final picked = candidateForTier([plain1080, hd720], sixty);
    expect(picked?.id, 'v1080plain');
  });

  test('a missing tier falls back to the best stream, never to nothing', () {
    final picked = candidateForTier([hd1080, hd720], sd480);
    expect(picked?.id, 'v1080');
  });

  test('a tier list is empty only when the source published no stream', () {
    expect(candidateForTier(const [], sd480), isNull);
  });

  test('no preference means no filtering', () {
    expect(candidateForTier([hd1080, hd720], null)?.id, 'v1080');
  });

  test('a DASH pick does not silently become an HLS download', () {
    final hls1080 = _candidate(
      id: 'hls1080',
      label: '1080P 高清',
      protocol: 'hls',
      height: 1080,
    );
    final dash1080 = _candidate(id: 'dash1080', label: '1080P 高清', height: 1080);
    final picked = candidateForTier([hls1080, dash1080], dash1080);
    expect(picked?.id, 'dash1080');
  });

  test('a renamed tier with the same height and codec still matches', () {
    final renamed = _candidate(
      id: 'renamed720',
      label: '高清 720P',
      codec: 'AVC',
      height: 720,
    );
    final picked = candidateForTier([hd1080, renamed], hd720);
    expect(picked?.id, 'renamed720');
  });

  test('the preview fragment of another episode matches its own label', () {
    final preview = _candidate(
      id: 'preview',
      label: '试看片段 6:01',
      height: 360,
    );
    final otherPreview = _candidate(
      id: 'preview2',
      label: '试看片段 6:01',
      height: 360,
    );
    final picked = candidateForTier([otherPreview, hd1080], preview);
    expect(picked?.id, 'preview2');
  });
}
