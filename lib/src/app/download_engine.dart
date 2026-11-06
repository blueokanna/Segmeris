import 'dart:async';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:segmeris/src/rust/api/downloader.dart';

import 'api_download_engine.dart';

/// Default API server base URL used by the web build.
///
/// The web version has no local media engine: downloads are executed by the
/// Segmeris HTTP API (the same server the Docker image ships). Users can
/// override this value in Settings.
const String defaultApiBaseUrl = 'http://localhost:3000';

/// Contract implemented by both download backends so the UI is identical on
/// every platform:
///  - native: Rust engine bridged through flutter_rust_bridge;
///  - web:    the Segmeris HTTP API (Docker) driven over HTTP.
abstract class DownloadEngine {
  Future<void> init();

  Future<MediaInspectionResult> inspect({
    required String url,
    required RequestContext requestContext,
  });

  Stream<ProgressUpdate> download({
    required String pageUrl,
    required String mediaUrl,
    List<String> mediaFallbackUrls = const [],
    String? audioUrl,
    List<String> audioFallbackUrls = const [],
    required String output,
    required DownloadOptions options,
    required RequestContext requestContext,
  });

  bool get writesLocalFiles;
  String? get lastResultPath => null;
}

abstract interface class PausableDownloadEngine {
  Future<bool> setPaused({required String output, required bool paused});
}

/// Native engine backed by the Rust library (`flutter_rust_bridge`).
class FrbDownloadEngine implements DownloadEngine, PausableDownloadEngine {
  const FrbDownloadEngine();

  @override
  Future<bool> setPaused({required String output, required bool paused}) async =>
      setDownloadPaused(output: output, paused: paused);

  @override
  Future<void> init() async {}

  @override
  Future<MediaInspectionResult> inspect({
    required String url,
    required RequestContext requestContext,
  }) {
    return inspectMediaWithContext(url: url, requestContext: requestContext);
  }

  @override
  Stream<ProgressUpdate> download({
    required String pageUrl,
    required String mediaUrl,
    List<String> mediaFallbackUrls = const [],
    String? audioUrl,
    List<String> audioFallbackUrls = const [],
    required String output,
    required DownloadOptions options,
    required RequestContext requestContext,
  }) {
    return downloadMediaWithContext(
      source: MediaSource(
        pageUrl: pageUrl,
        mediaUrl: mediaUrl,
        mediaFallbackUrls: mediaFallbackUrls,
        audioUrl: audioUrl,
        audioFallbackUrls: audioFallbackUrls,
      ),
      output: output,
      options: options,
      requestContext: requestContext,
    );
  }

  @override
  bool get writesLocalFiles => true;

  @override
  String? get lastResultPath => null;
}

/// Build the download engine for the current platform.
///
/// [apiBaseUrl] and [apiToken] are only consulted on the web; native targets
/// always use the Rust engine.
DownloadEngine createDownloadEngine({
  String apiBaseUrl = defaultApiBaseUrl,
  String apiToken = '',
}) {
  if (kIsWeb) {
    return ApiDownloadEngine(apiBaseUrl: apiBaseUrl, apiToken: apiToken);
  }
  return const FrbDownloadEngine();
}
