import 'dart:async';

import 'package:flutter/services.dart';

import 'capability_snapshot.dart';
import 'platform_utils.dart';
import 'runtime_capabilities_stub.dart'
    if (dart.library.io) 'runtime_capabilities_io.dart' as probe;

export 'capability_snapshot.dart' show PlatformCapabilitySnapshot;

class RuntimeCapabilityProbe {
  RuntimeCapabilityProbe._();

  static const _channel = MethodChannel('com.blue.segmeris/media_store');

  static Future<PlatformCapabilitySnapshot> inspect() async {
    if (SegmerisPlatform.isWeb) {
      return _inspectWeb();
    }
    if (SegmerisPlatform.isAndroid) {
      return _inspectAndroid();
    }
    if (SegmerisPlatform.isIOS) {
      return _inspectIos();
    }
    return probe.probeDesktopCapabilities();
  }

  /// The browser uses the API for media work and cannot inspect its runtime.
  static PlatformCapabilitySnapshot _inspectWeb() {
    return const PlatformCapabilitySnapshot(
      platform: 'web',
      transcoderBackend: 'API server (not reported)',
      hardwareAccelerated: null,
      videoEncoders: [],
      videoDecoders: [],
      ffmpegAvailable: null,
      ytdlpAvailable: null,
      notes: [
        'The web build drives downloads through the Segmeris API server.',
        'The API does not report its encoder, decoder, FFmpeg, or yt-dlp capabilities.',
        'Run the API server locally (docker compose up) and set its URL in Settings.',
      ],
    );
  }

  static Future<PlatformCapabilitySnapshot> _inspectAndroid() async {
    try {
      final raw = await _channel.invokeMapMethod<String, dynamic>(
        'getRuntimeCapabilities',
      );
      if (raw == null) {
        throw const FormatException('Android returned an empty report');
      }
      return PlatformCapabilitySnapshot(
        platform: raw['platform'] as String? ?? 'android',
        transcoderBackend: raw['transcoderBackend'] as String? ?? 'Unavailable',
        hardwareAccelerated: raw['hardwareAccelerated'] as bool?,
        videoEncoders: _stringList(raw['videoEncoders']),
        videoDecoders: _stringList(raw['videoDecoders']),
        ffmpegAvailable: raw['ffmpegAvailable'] as bool?,
        ytdlpAvailable: raw['ytdlpAvailable'] as bool?,
        notes: const [
          'Android reports platform-advertised MediaCodec support; it does not run a test encode.',
          'Unavailable codecs are never simulated.',
          'YouTube uses the native resolver; signature-protected formats may require desktop yt-dlp.',
        ],
      );
    } catch (error) {
      return PlatformCapabilitySnapshot(
        platform: 'android',
        transcoderBackend: 'Capability probe failed',
        hardwareAccelerated: null,
        videoEncoders: const [],
        videoDecoders: const [],
        ffmpegAvailable: null,
        ytdlpAvailable: null,
        notes: ['MediaCodec capability query failed: $error'],
      );
    }
  }

  static Future<PlatformCapabilitySnapshot> _inspectIos() async {
    try {
      final raw = await _channel.invokeMapMethod<String, dynamic>(
        'getRuntimeCapabilities',
      );
      if (raw == null) {
        throw const FormatException('iOS returned an empty report');
      }
      return PlatformCapabilitySnapshot(
        platform: 'ios',
        transcoderBackend: raw['transcoderBackend'] as String? ?? 'Unavailable',
        hardwareAccelerated: raw['hardwareAccelerated'] as bool?,
        videoEncoders: _stringList(raw['videoEncoders']),
        videoDecoders: _stringList(raw['videoDecoders']),
        ffmpegAvailable: raw['ffmpegAvailable'] as bool?,
        ytdlpAvailable: raw['ytdlpAvailable'] as bool?,
        notes: const [
          'iOS AVFoundation and VideoToolbox capabilities are not currently reported by the native bridge.',
          'YouTube uses the native resolver; signature-protected formats may require desktop yt-dlp.',
        ],
      );
    } catch (error) {
      return PlatformCapabilitySnapshot(
        platform: 'ios',
        transcoderBackend: 'Unavailable',
        hardwareAccelerated: null,
        videoEncoders: const [],
        videoDecoders: const [],
        ffmpegAvailable: null,
        ytdlpAvailable: null,
        notes: [
          'iOS native capability query failed; codec availability is unknown: $error',
        ],
      );
    }
  }

  static List<String> _stringList(Object? value) {
    return switch (value) {
      List<Object?> values => values.whereType<String>().toList(),
      _ => const [],
    };
  }
}
