import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:segmeris/src/app/app_theme.dart';
import 'package:segmeris/src/home/download_options_dialog.dart';
import 'package:segmeris/src/rust/api/downloader.dart';

import '../widget_test_harness.dart';

/// `ep1994063` in the field: the only stream the session can reach is a
/// six-minute preview fragment, and the engine says so with this warning.
const _previewWarning =
    '[auth:bilibili-preview-only] The playurl API returned the preview fragment (6:01), not the whole episode';

const _page = 'https://www.bilibili.com/bangumi/play/ep1994063';

MediaCandidate _candidate({
  required String id,
  required String label,
  String badge = '',
  String codec = 'AVC',
  int width = 1920,
  int height = 1080,
  bool withAudio = true,
}) {
  return MediaCandidate(
    id: id,
    title: '空中浩劫 第一季',
    extractor: 'bilibili',
    pageUrl: _page,
    mediaUrl: 'https://cdn.example/$id.mp4',
    mediaFallbackUrls: const [],
    audioUrl: withAudio ? 'https://cdn.example/$id.m4a' : null,
    audioFallbackUrls: const [],
    container: 'mp4',
    protocol: 'dash',
    mimeType: 'video/mp4',
    qualityLabel: label,
    qualityBadge: badge,
    codec: codec,
    width: width,
    height: height,
    requiresFfmpeg: false,
    score: 0,
    segmentCount: 0,
    durationSeconds: 0,
    primary: false,
    reason: '',
  );
}

MediaInspectionResult _inspection(
  List<MediaCandidate> candidates, {
  List<String> warnings = const [],
}) {
  return MediaInspectionResult(
    pageUrl: _page,
    pageTitle: '空中浩劫 第一季',
    extractor: 'bilibili',
    candidates: candidates,
    subtitles: const [],
    warnings: warnings,
    authRequired: false,
    challengeReason: '',
  );
}

/// Pumps a button that opens the dialog and records its result.
Future<void> _pumpDialogHost(
  WidgetTester tester, {
  required MediaInspectionResult inspection,
  required ValueNotifier<MediaCandidate?> result,
  required ValueNotifier<int> opened,
  MediaCandidate? initial,
  VoidCallback? onOpenAuthBrowser,
}) async {
  // A quality list plus warnings is taller than the default 800x600 test
  // surface, and a tile scrolled under the modal barrier cannot be tapped.
  tester.view.physicalSize = const Size(1000, 1600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    buildTestHarness(
      profile:
          appThemeProfiles.firstWhere((profile) => profile.id == 'monet_flow'),
      brightness: Brightness.light,
      child: Builder(
        builder: (context) => FilledButton(
          onPressed: () async {
            opened.value += 1;
            result.value = await showDownloadOptionsDialog(
              context,
              inspection: inspection,
              initial: initial,
              onOpenAuthBrowser: onOpenAuthBrowser,
            );
          },
          child: const Text('open'),
        ),
      ),
    ),
  );
  // The localizations delegate resolves a frame after the first pump, so the
  // host button only exists once the tree has settled.
  await tester.pumpAndSettle();
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}
void main() {
  testWidgets('lists every quality and returns the chosen one', (tester) async {
    final candidates = [
      _candidate(id: 'p1080', label: '1080P 高清', badge: '大会员'),
      _candidate(id: 'p720', label: '720P 高清', codec: 'HEVC'),
      _candidate(id: 'p480', label: '480P 标清', width: 852, height: 480),
    ];
    final result = ValueNotifier<MediaCandidate?>(null);
    final opened = ValueNotifier<int>(0);

    await _pumpDialogHost(
      tester,
      inspection: _inspection(candidates),
      initial: candidates[1],
      result: result,
      opened: opened,
    );

    expect(opened.value, 1);
    expect(find.text('Choose the quality'), findsOneWidget);
    for (final candidate in candidates) {
      expect(find.text(candidate.qualityLabel), findsOneWidget);
    }

    await tester.tap(find.text('480P 标清'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Start download'));
    await tester.pumpAndSettle();

    expect(result.value?.id, 'p480');
  });

  testWidgets('cancelling starts nothing', (tester) async {
    final result = ValueNotifier<MediaCandidate?>(null);
    final opened = ValueNotifier<int>(0);

    await _pumpDialogHost(
      tester,
      inspection: _inspection([_candidate(id: 'p480', label: '480P 标清')]),
      result: result,
      opened: opened,
    );

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(result.value, isNull);
  });

  testWidgets('a preview-only analysis says so and offers the auth browser', (
    tester,
  ) async {
    var openedAuthBrowser = false;
    final result = ValueNotifier<MediaCandidate?>(null);
    final opened = ValueNotifier<int>(0);
    final preview = _candidate(
      id: 'preview',
      label: '试看片段 6:01',
      width: 0,
      height: 0,
      withAudio: false,
    );

    await _pumpDialogHost(
      tester,
      inspection: _inspection([preview], warnings: const [_previewWarning]),
      onOpenAuthBrowser: () => openedAuthBrowser = true,
      result: result,
      opened: opened,
    );

    // The engine's warning reaches the dialog verbatim, and the login
    // affordance next to it works.
    expect(find.textContaining('preview fragment'), findsOneWidget);
    await tester.tap(find.text('Open auth browser'));
    await tester.pumpAndSettle();
    expect(openedAuthBrowser, isTrue);
    // Taking the login route closes the dialog without starting a download.
    expect(result.value, isNull);
  });

  testWidgets('detects the preview gate from the engine warning', (
    tester,
  ) async {
    expect(
      inspectionOffersPreviewOnly(
        _inspection(const [], warnings: const [_previewWarning]),
      ),
      isTrue,
    );
    expect(
      inspectionOffersPreviewOnly(
        _inspection([_candidate(id: 'p480', label: '480P 标清')]),
      ),
      isFalse,
    );
  });
}
