import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:segmeris/src/app/app_theme.dart';
import 'package:segmeris/src/home/home_candidates_card.dart';
import 'package:segmeris/src/home/subtitle_preference.dart';
import 'package:segmeris/src/rust/api/downloader.dart';

import '../widget_test_harness.dart';

void main() {
  const primaryCandidate = MediaCandidate(
    id: 'candidate-a',
    title: 'Primary Stream',
    extractor: 'bilibili',
    pageUrl: 'https://www.bilibili.com/video/BV1fixture',
    mediaUrl: 'https://cdn.example/primary-video.mp4',
    mediaFallbackUrls: [],
    audioUrl: 'https://cdn.example/primary-audio.m4a',
    audioFallbackUrls: [],
    container: 'mp4',
    protocol: 'dash',
    mimeType: 'video/mp4',
    qualityLabel: '1080p · Mandarin',
    qualityBadge: '大会员',
    codec: 'AVC',
    width: 1920,
    height: 1080,
    requiresFfmpeg: false,
    score: 0,
    segmentCount: 0,
    durationSeconds: 0,
    primary: true,
    reason: '',
  );

  const secondaryCandidate = MediaCandidate(
    id: 'candidate-b',
    title: 'Secondary Stream',
    extractor: 'bilibili',
    pageUrl: 'https://www.bilibili.com/video/BV1fixture',
    mediaUrl: 'https://cdn.example/secondary-video.mp4',
    mediaFallbackUrls: [],
    audioUrl: null,
    audioFallbackUrls: [],
    container: 'mp4',
    protocol: 'https',
    mimeType: 'video/mp4',
    qualityLabel: '720p',
    qualityBadge: '',
    codec: 'HEVC',
    width: 1280,
    height: 720,
    requiresFfmpeg: false,
    score: 0,
    segmentCount: 0,
    durationSeconds: 0,
    primary: false,
    reason: '',
  );

  const inspection = MediaInspectionResult(
    pageUrl: 'https://www.bilibili.com/video/BV1fixture',
    pageTitle: 'Fixture Candidate Page',
    extractor: 'bilibili',
    candidates: [primaryCandidate, secondaryCandidate],
    subtitles: [
      MediaSubtitleTrack(
        language: 'zh-CN',
        label: '中文（自动生成）',
        url: 'https://aisubtitle.example/zh.json',
        selected: true,
      ),
      MediaSubtitleTrack(
        language: 'en-US',
        label: 'English',
        url: 'https://aisubtitle.example/en.json',
        selected: false,
      ),
    ],
    warnings: ['[site:test] fixture warning'],
    authRequired: false,
    challengeReason: '',
  );

  testWidgets('renders current selection summary and selection callback', (
    tester,
  ) async {
    MediaCandidate? tappedCandidate;

    await tester.pumpWidget(
      buildTestHarness(
        profile: appThemeProfiles
            .firstWhere((profile) => profile.id == 'monet_flow'),
        brightness: Brightness.light,
        child: HomeCandidatesCard(
          inspection: inspection,
          selectedCandidate: primaryCandidate,
          subtitlePreference: const SubtitleAutoPreference(),
          running: false,
          analyzing: false,
          selectionRevision: 6,
          onCandidateSelected: (candidate) {
            tappedCandidate = candidate;
          },
          onSubtitlePreferenceChanged: (_) {},
          onOpenAuthBrowser: () {},
        ),
      ),
    );

    await tester.pumpAndSettle();

    expect(find.text('Current selection'), findsOneWidget);
    expect(find.text('Separate audio'), findsOneWidget);
    expect(find.text('Primary Stream'), findsWidgets);

    await tester.ensureVisible(find.text('Secondary Stream'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Secondary Stream'));
    await tester.pumpAndSettle();

    expect(tappedCandidate?.id, 'candidate-b');
  });

  testWidgets('shows the official quality name, badge and codec', (
    tester,
  ) async {
    const bilibiliCandidate = MediaCandidate(
      id: 'candidate-c',
      title: '【官方 MV】Never Gonna Give You Up P2',
      extractor: 'bilibili',
      pageUrl: 'https://www.bilibili.com/video/BV1fixture',
      mediaUrl: 'https://cdn.example/video-1080p-plus.m4s',
      mediaFallbackUrls: [],
      audioUrl: 'https://cdn.example/audio-192k.m4s',
      audioFallbackUrls: [],
      container: 'm4s',
      protocol: 'dash',
      mimeType: 'video/mp4',
      qualityLabel: '1080P 高码率',
      qualityBadge: '大会员',
      codec: 'HEVC',
      width: 1920,
      height: 1080,
      requiresFfmpeg: true,
      score: 0,
      segmentCount: 0,
      durationSeconds: 0,
      primary: true,
      reason: '',
    );
    const bilibiliInspection = MediaInspectionResult(
      pageUrl: 'https://www.bilibili.com/video/BV1fixture',
      pageTitle: 'Never Gonna Give You Up',
      extractor: 'bilibili',
      candidates: [bilibiliCandidate],
      subtitles: [],
      warnings: [],
      authRequired: false,
      challengeReason: '',
    );

    await tester.pumpWidget(
      buildTestHarness(
        profile: appThemeProfiles
            .firstWhere((profile) => profile.id == 'monet_flow'),
        brightness: Brightness.dark,
        child: HomeCandidatesCard(
          inspection: bilibiliInspection,
          selectedCandidate: bilibiliCandidate,
          subtitlePreference: const SubtitleAutoPreference(),
          running: false,
          analyzing: false,
          selectionRevision: 1,
          onCandidateSelected: (_) {},
          onSubtitlePreferenceChanged: (_) {},
          onOpenAuthBrowser: () {},
        ),
      ),
    );

    await tester.pumpAndSettle();

    expect(find.text('1080P 高码率'), findsWidgets);
    expect(find.text('大会员'), findsWidgets);
    expect(find.text('HEVC'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('picking a subtitle track reports the preference', (
    tester,
  ) async {
    SubtitlePreference? picked;

    await tester.pumpWidget(
      buildTestHarness(
        profile: appThemeProfiles
            .firstWhere((profile) => profile.id == 'monet_flow'),
        brightness: Brightness.light,
        child: HomeCandidatesCard(
          inspection: inspection,
          selectedCandidate: primaryCandidate,
          subtitlePreference: const SubtitleAutoPreference(),
          running: false,
          analyzing: false,
          selectionRevision: 2,
          onCandidateSelected: (_) {},
          onSubtitlePreferenceChanged: (preference) {
            picked = preference;
          },
          onOpenAuthBrowser: () {},
        ),
      ),
    );

    await tester.pumpAndSettle();

    expect(find.text('Subtitles'), findsOneWidget);
    expect(find.text('中文（自动生成）'), findsOneWidget);
    expect(find.text('English'), findsOneWidget);
    // The episode's default track carries the marker; "auto" is selected.
    expect(find.text('Default'), findsOneWidget);
    expect(picked, isNull);

    await tester.ensureVisible(find.text('English'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('English'));
    await tester.pumpAndSettle();

    expect(picked, isA<SubtitleTrackPreference>());
    expect((picked! as SubtitleTrackPreference).track.url,
        'https://aisubtitle.example/en.json');

    await tester.ensureVisible(find.text('No subtitles'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('No subtitles'));
    await tester.pumpAndSettle();

    expect(picked, isA<SubtitleOffPreference>());
    expect(tester.takeException(), isNull);
  });
}
