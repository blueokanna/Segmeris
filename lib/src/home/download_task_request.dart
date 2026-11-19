import 'dart:convert';

import 'package:segmeris/src/app/credential_store.dart';
import 'package:segmeris/src/rust/api/downloader.dart';

/// Immutable input for a durable task. Credentials live in the platform vault;
/// the journal contains only their task key, never cookies or custom headers.
class DownloadTaskRequest {
  const DownloadTaskRequest({
    required this.pageUrl,
    required this.mediaUrl,
    this.mediaFallbackUrls = const [],
    required this.audioUrl,
    this.audioFallbackUrls = const [],
    required this.output,
    required this.chosenDir,
    required this.options,
    required this.requestContext,
    required this.fileName,
    required this.sourcePage,
    this.preferredTier,
    this.strictTier = false,
  });

  final String pageUrl;
  final String mediaUrl;
  final List<String> mediaFallbackUrls;
  final String? audioUrl;
  final List<String> audioFallbackUrls;
  final String output;
  final String? chosenDir;
  final DownloadOptions options;
  final RequestContext requestContext;
  final String fileName;
  final String sourcePage;
  final MediaCandidate? preferredTier;
  final bool strictTier;

  DownloadTaskRequest withRequestContext(RequestContext value) =>
      _copy(requestContext: value);

  DownloadTaskRequest withResolvedSource(MediaCandidate source) =>
      _copy(source: source);

  DownloadTaskRequest _copy({
    RequestContext? requestContext,
    MediaCandidate? source,
  }) => DownloadTaskRequest(
    pageUrl: pageUrl,
    mediaUrl: source?.mediaUrl ?? mediaUrl,
    mediaFallbackUrls: source?.mediaFallbackUrls ?? mediaFallbackUrls,
    audioUrl: source == null ? audioUrl : source.audioUrl,
    audioFallbackUrls: source?.audioFallbackUrls ?? audioFallbackUrls,
    output: output,
    chosenDir: chosenDir,
    options: options,
    requestContext: requestContext ?? this.requestContext,
    fileName: fileName,
    sourcePage: sourcePage,
    preferredTier: source ?? preferredTier,
    strictTier: source != null || strictTier,
  );

  Map<String, dynamic> toJson() => {
    'pageUrl': pageUrl,
    'mediaUrl': mediaUrl,
    'mediaFallbackUrls': mediaFallbackUrls,
    'audioUrl': audioUrl,
    'audioFallbackUrls': audioFallbackUrls,
    'output': output,
    'chosenDir': chosenDir,
    'fileName': fileName,
    'sourcePage': sourcePage,
    'strictTier': strictTier,
    'options': {
      'concurrency': options.concurrency,
      'retries': options.retries,
      'videoBitrate': options.videoBitrate,
      'audioBitrate': options.audioBitrate,
      'keepTemp': options.keepTemp,
      'subtitleMode': options.subtitleMode.name,
      'subtitleValue': options.subtitleValue,
    },
    if (preferredTier case final tier?)
      'tier': {
        'id': tier.id,
        'extractor': tier.extractor,
        'container': tier.container,
        'protocol': tier.protocol,
        'qualityLabel': tier.qualityLabel,
        'codec': tier.codec,
        'width': tier.width,
        'height': tier.height,
        'hasAudio': tier.audioUrl != null,
      },
  };

  factory DownloadTaskRequest.fromJson(
    Map<String, dynamic> json,
    RequestContext context,
  ) {
    final opts = json['options'] as Map<String, dynamic>;
    final rawTier = json['tier'] as Map<String, dynamic>?;
    final page = json['pageUrl'] as String;
    final output = json['output'] as String;
    if (page.isEmpty || output.isEmpty) {
      throw const FormatException('Task has no source or output');
    }
    return DownloadTaskRequest(
      pageUrl: page,
      mediaUrl: json['mediaUrl'] as String,
      mediaFallbackUrls: (json['mediaFallbackUrls'] as List).cast<String>(),
      audioUrl: json['audioUrl'] as String?,
      audioFallbackUrls: (json['audioFallbackUrls'] as List).cast<String>(),
      output: output,
      chosenDir: json['chosenDir'] as String?,
      fileName: json['fileName'] as String,
      sourcePage: json['sourcePage'] as String,
      strictTier: json['strictTier'] as bool? ?? false,
      requestContext: context,
      options: DownloadOptions(
        concurrency: (opts['concurrency'] as int).clamp(1, 16),
        retries: (opts['retries'] as int).clamp(1, 10),
        videoBitrate: (opts['videoBitrate'] as int).clamp(0, 20000),
        audioBitrate: (opts['audioBitrate'] as int).clamp(0, 512),
        keepTemp: opts['keepTemp'] as bool,
        subtitleMode: SubtitleMode.values.byName(
          opts['subtitleMode'] as String,
        ),
        subtitleValue: opts['subtitleValue'] as String,
      ),
      preferredTier: rawTier == null
          ? null
          : MediaCandidate(
              id: rawTier['id'] as String,
              title: '',
              extractor: rawTier['extractor'] as String,
              pageUrl: page,
              mediaUrl: '',
              mediaFallbackUrls: const [],
              audioUrl: rawTier['hasAudio'] == true ? '' : null,
              audioFallbackUrls: const [],
              container: rawTier['container'] as String,
              protocol: rawTier['protocol'] as String,
              mimeType: '',
              qualityLabel: rawTier['qualityLabel'] as String,
              qualityBadge: '',
              codec: rawTier['codec'] as String,
              width: rawTier['width'] as int,
              height: rawTier['height'] as int,
              requiresFfmpeg: false,
              score: 0,
              segmentCount: 0,
              durationSeconds: 0,
              primary: false,
              reason: '',
            ),
    );
  }

  Future<void> saveCredentials(String id) => CredentialStore.write(
    'download-context-$id',
    jsonEncode({
      'userAgent': requestContext.userAgent,
      'referer': requestContext.referer,
      'origin': requestContext.origin,
      'cookie': requestContext.cookie,
      'headers': [
        for (final h in requestContext.headers)
          {'name': h.name, 'value': h.value},
      ],
    }),
  );

  static Future<RequestContext> loadCredentials(String id) async {
    final value = await CredentialStore.read('download-context-$id');
    if (value == null) {
      return const RequestContext(
        userAgent: '',
        referer: '',
        origin: '',
        cookie: '',
        headers: [],
      );
    }
    final json = jsonDecode(value) as Map<String, dynamic>;
    return RequestContext(
      userAgent: json['userAgent'] as String,
      referer: json['referer'] as String,
      origin: json['origin'] as String,
      cookie: json['cookie'] as String,
      headers: [
        for (final h in json['headers'] as List)
          HeaderEntry(name: h['name'] as String, value: h['value'] as String),
      ],
    );
  }

  static Future<void> deleteCredentials(String id) =>
      CredentialStore.write('download-context-$id', null);
}
