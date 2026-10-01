import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:segmeris/src/app/app_localizations.dart';
import 'package:segmeris/src/app/app_theme.dart';
import 'package:segmeris/src/app/runtime_capabilities.dart';
import 'package:segmeris/src/home/home_widgets.dart';

void main() {
  testWidgets('renders a completed runtime capability report on narrow screens',
      (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(320, 640);
    addTearDown(tester.view.reset);

    const report = PlatformCapabilitySnapshot(
      platform: 'windows',
      transcoderBackend: 'FFmpeg / NVIDIA NVENC',
      hardwareAccelerated: true,
      videoEncoders: [
        'NVIDIA NVENC',
        'Intel Quick Sync',
        'AMD AMF',
        'CPU libx264',
        'This fifth encoder is intentionally not rendered',
      ],
      videoDecoders: ['H.264 hardware decoder', 'HEVC hardware decoder'],
      ffmpegAvailable: true,
      ytdlpAvailable: true,
      notes: ['Capabilities were verified with runtime probes.'],
    );

    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('en'),
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: const [
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        theme: buildAppTheme(appThemeProfiles.first, Brightness.light),
        home: Scaffold(
          body: SingleChildScrollView(
            padding: const EdgeInsets.all(12),
            child: RuntimeCapabilitiesPanel(
              capabilities: Future.value(report),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('capabilities-ready')), findsOneWidget);
    expect(find.text('Runtime capabilities'), findsOneWidget);
    expect(find.textContaining('FFmpeg / NVIDIA NVENC'), findsOneWidget);
    expect(find.textContaining('FFmpeg'), findsWidgets);
    expect(find.textContaining('yt-dlp'), findsOneWidget);
    expect(find.text('NVIDIA NVENC'), findsOneWidget);
    expect(find.text('This fifth encoder is intentionally not rendered'),
        findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('renders unreported runtime capabilities as unknown',
      (tester) async {
    const report = PlatformCapabilitySnapshot(
      platform: 'web',
      transcoderBackend: 'API server (not reported)',
      hardwareAccelerated: null,
      videoEncoders: [],
      videoDecoders: [],
      ffmpegAvailable: null,
      ytdlpAvailable: null,
      notes: ['The API does not report runtime capabilities.'],
    );

    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('en'),
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: const [
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        theme: buildAppTheme(appThemeProfiles.first, Brightness.light),
        home: Scaffold(
          body: RuntimeCapabilitiesPanel(
            capabilities: Future.value(report),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('FFmpeg · Unknown'), findsOneWidget);
    expect(find.text('yt-dlp · Unknown'), findsOneWidget);
    expect(find.text('Hardware encoder · Unknown'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
