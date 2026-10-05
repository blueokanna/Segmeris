import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:segmeris/src/app/app_localizations.dart';
import 'package:segmeris/src/app/app_settings.dart';
import 'package:segmeris/src/app/auth_browser_page.dart';
import 'package:segmeris/src/app/download_engine.dart';
import 'package:segmeris/src/app/local_file_utils.dart';
import 'package:segmeris/src/app/platform_bridge.dart';
import 'package:segmeris/src/app/platform_utils.dart';
import 'package:segmeris/src/home/home_candidates_card.dart';
import 'package:segmeris/src/home/home_download_tasks_card.dart';
import 'package:segmeris/src/home/home_page_controller.dart';
import 'package:segmeris/src/home/home_history_card.dart';
import 'package:segmeris/src/home/home_input_card.dart';
import 'package:segmeris/src/home/home_series_card.dart';
import 'package:segmeris/src/home/home_settings_sheet.dart';
import 'package:segmeris/src/home/home_widgets.dart';
import 'package:segmeris/src/home/source_input.dart';
import 'package:segmeris/src/home/subtitle_preference.dart';
import 'package:segmeris/src/rust/api/downloader.dart';

class _DownloadTaskRequest {
  const _DownloadTaskRequest({
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
  });

  final String pageUrl;
  final String mediaUrl;
  final List<String> mediaFallbackUrls;
  final String? audioUrl;
  final List<String> audioFallbackUrls;
  final String output;
  final String? chosenDir;

  /// Transport options, including the subtitle decision this task was
  /// queued with — a retry must reproduce the same download.
  final DownloadOptions options;
  final RequestContext requestContext;
  final String fileName;
  final String sourcePage;

  _DownloadTaskRequest withRequestContext(RequestContext value) {
    return _DownloadTaskRequest(
      pageUrl: pageUrl,
      mediaUrl: mediaUrl,
      mediaFallbackUrls: mediaFallbackUrls,
      audioUrl: audioUrl,
      audioFallbackUrls: audioFallbackUrls,
      output: output,
      chosenDir: chosenDir,
      options: options,
      requestContext: value,
      fileName: fileName,
      sourcePage: sourcePage,
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({
    super.key,
    required this.settings,
    required this.onSettingsChanged,
  });

  final AppSettings settings;
  final ValueChanged<AppSettings> onSettingsChanged;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  // Not `final`: recreated in `didUpdateWidget` when the web API settings
  // change, so it must be reassignable.
  late DownloadEngine _engine;
  final _formKey = GlobalKey<FormState>();
  final _urlCtrl = TextEditingController();
  final _fileNameCtrl = TextEditingController(text: 'video.mp4');
  final _concurrencyCtrl = TextEditingController(text: '4');
  final _retriesCtrl = TextEditingController(text: '5');
  final _vBitrateCtrl = TextEditingController(text: '0');
  final _aBitrateCtrl = TextEditingController(text: '0');
  final _userAgentCtrl = TextEditingController();
  final _refererCtrl = TextEditingController();
  final _originCtrl = TextEditingController();
  final _cookieCtrl = TextEditingController();
  final _headersCtrl = TextEditingController();
  final _pageController = HomePageController();
  final Map<String, _DownloadTaskRequest> _retryRequests = {};

  /// Subtitle pick of the current inspection; reset to the episode default
  /// whenever a new analysis replaces it.
  SubtitlePreference _subtitlePreference = const SubtitleAutoPreference();

  /// True while the series queue is walking through its episode loop;
  /// keeps the single-download button and a second series run disabled
  /// even during the gaps between two queued episodes.
  bool _seriesQueueActive = false;

  late final Listenable _authContextListenable = Listenable.merge([
    _userAgentCtrl,
    _refererCtrl,
    _originCtrl,
    _cookieCtrl,
    _headersCtrl,
  ]);

  @override
  void initState() {
    super.initState();
    _engine = createDownloadEngine(
      apiBaseUrl: widget.settings.apiBaseUrl,
      apiToken: widget.settings.apiToken,
    );
    _checkBattery();
  }

  @override
  void didUpdateWidget(HomePage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.settings.apiBaseUrl != widget.settings.apiBaseUrl ||
        oldWidget.settings.apiToken != widget.settings.apiToken) {
      _engine = createDownloadEngine(
        apiBaseUrl: widget.settings.apiBaseUrl,
        apiToken: widget.settings.apiToken,
      );
    }
  }

  @override
  void dispose() {
    _urlCtrl.dispose();
    _fileNameCtrl.dispose();
    _concurrencyCtrl.dispose();
    _retriesCtrl.dispose();
    _vBitrateCtrl.dispose();
    _aBitrateCtrl.dispose();
    _userAgentCtrl.dispose();
    _refererCtrl.dispose();
    _originCtrl.dispose();
    _cookieCtrl.dispose();
    _headersCtrl.dispose();
    _retryRequests.clear();
    _pageController.dispose();
    super.dispose();
  }

  Future<void> _checkBattery() async {
    final value = await MediaStoreBridge.isIgnoringBatteryOptimizations();
    _pageController.setIgnoringBattery(value);
  }

  Future<void> _pickDir() async {
    if (_pageController.value.analyzing || SegmerisPlatform.isWeb) {
      return;
    }
    final dir = await FilePicker.getDirectoryPath();
    if (dir != null) {
      _pageController.setChosenDir(dir);
    }
  }

  Future<String> _tempOutputPathFor(String name, String? chosenDir) async {
    if (SegmerisPlatform.isWeb) {
      return name;
    }
    if (SegmerisPlatform.isAndroid) {
      final safe = await MediaStoreBridge.getAppPrivateDir();
      return safe.isNotEmpty
          ? '$safe${SegmerisPlatform.pathSeparator}$name'
          : name;
    }
    if (chosenDir != null && chosenDir.isNotEmpty) {
      final separator = SegmerisPlatform.pathSeparator;
      return chosenDir.endsWith(separator)
          ? '$chosenDir$name'
          : '$chosenDir$separator$name';
    }
    return name;
  }

  String _normalizeOutputName(String value) {
    final trimmed = value.trim().isEmpty ? 'video.mp4' : value.trim();
    final basename = trimmed.split(RegExp(r'[\\/]')).last.trim();
    final sanitized = basename.replaceAll(
      RegExp(r'[\\/:*?"<>|\x00-\x1f]'),
      '_',
    );
    final cleaned = (sanitized.isEmpty || sanitized == '.' || sanitized == '..')
        ? 'video'
        : sanitized;
    return cleaned.toLowerCase().endsWith('.mp4') ? cleaned : '$cleaned.mp4';
  }

  String _suggestFileName(MediaCandidate candidate) {
    final raw =
        candidate.title.trim().isEmpty ? 'video' : candidate.title.trim();
    final sanitized = raw.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
    final quality =
        candidate.qualityLabel.trim().replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
    final withQuality = quality.isEmpty || sanitized.contains(quality)
        ? sanitized
        : '$sanitized [$quality]';
    return _normalizeOutputName(withQuality);
  }

  String _sanitizeHeaderValue(String value) {
    return value.replaceAll(RegExp(r'[\x00-\x08\x0A-\x1F\x7F]'), '');
  }

  RequestContext _requestContext() {
    return RequestContext(
      userAgent: _sanitizeHeaderValue(_userAgentCtrl.text.trim()),
      referer: _sanitizeHeaderValue(_refererCtrl.text.trim()),
      origin: _sanitizeHeaderValue(_originCtrl.text.trim()),
      cookie: _sanitizeHeaderValue(_cookieCtrl.text.trim()),
      headers: _parseHeaderEntries(_headersCtrl.text),
    );
  }

  List<HeaderEntry> _parseHeaderEntries(String text) {
    final entries = <HeaderEntry>[];
    for (final line in text.split('\n')) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) {
        continue;
      }
      final index = trimmed.indexOf(':');
      if (index <= 0) {
        continue;
      }
      final name = trimmed.substring(0, index).trim();
      final value = _sanitizeHeaderValue(trimmed.substring(index + 1).trim());
      if (name.isEmpty || value.isEmpty) {
        continue;
      }
      entries.add(HeaderEntry(name: name, value: value));
    }
    return entries;
  }

  bool get _hasAuthContextOverrides {
    return _userAgentCtrl.text.trim().isNotEmpty ||
        _refererCtrl.text.trim().isNotEmpty ||
        _originCtrl.text.trim().isNotEmpty ||
        _cookieCtrl.text.trim().isNotEmpty ||
        _parseHeaderEntries(_headersCtrl.text).isNotEmpty;
  }

  List<String> _authContextBadges() {
    final badges = <String>[];
    if (_userAgentCtrl.text.trim().isNotEmpty) {
      badges.add('User-Agent');
    }
    if (_refererCtrl.text.trim().isNotEmpty) {
      badges.add('Referer');
    }
    if (_originCtrl.text.trim().isNotEmpty) {
      badges.add('Origin');
    }
    if (_cookieCtrl.text.trim().isNotEmpty) {
      badges.add('Cookie');
    }
    final headerCount = _parseHeaderEntries(_headersCtrl.text).length;
    if (headerCount > 0) {
      badges.add('Headers x$headerCount');
    }
    return badges;
  }

  void _clearAuthContext() {
    _userAgentCtrl.clear();
    _refererCtrl.clear();
    _originCtrl.clear();
    _cookieCtrl.clear();
    _headersCtrl.clear();
  }

  bool _looksLikeAuthChallenge(String message) {
    final lower = message.toLowerCase();
    return lower.contains('authorization required') ||
        lower.contains('access challenge') ||
        lower.contains('cloudflare') ||
        lower.contains('captcha') ||
        lower.contains('checking your browser') ||
        lower.contains('checking if the site connection is secure') ||
        lower.contains('cf-chl-') ||
        lower.contains('forbidden') ||
        lower.contains('too many requests') ||
        lower.contains('http 401') ||
        lower.contains('http 403') ||
        lower.contains('http 429');
  }

  bool _shouldAutoOpenAuthBrowser({
    required bool skipAutoAuth,
    MediaInspectionResult? inspection,
    String? errorText,
  }) {
    final vm = _pageController.value;
    if (skipAutoAuth ||
        vm.autoOpeningAuthBrowser ||
        !widget.settings.autoOpenAuthBrowser) {
      return false;
    }
    if (inspection?.authRequired ?? false) {
      return true;
    }
    return errorText != null && _looksLikeAuthChallenge(errorText);
  }

  Future<void> _openAuthBrowser({bool reanalyzeAfterImport = false}) async {
    if (_pageController.value.autoOpeningAuthBrowser) {
      return;
    }
    final l = AppLocalizations.of(context);
    final targetUrl = extractSourceUrl(_urlCtrl.text)!;
    _replaceSourceText(targetUrl);
    if (targetUrl.isEmpty) {
      _pageController.setError(l.text('input_source'));
      return;
    }

    _pageController.setAutoOpeningAuthBrowser(true);
    try {
      final session = await Navigator.of(context).push<AuthSessionBundle>(
        MaterialPageRoute(
          builder: (context) => AuthBrowserPage(
            initialUrl: targetUrl,
            seedContext: _requestContext(),
          ),
          fullscreenDialog: true,
        ),
      );

      if (!mounted || session == null) {
        return;
      }

      if (session.userAgent.isNotEmpty) {
        _userAgentCtrl.text = session.userAgent;
      }
      if (session.referer.isNotEmpty) {
        _refererCtrl.text = session.referer;
      }
      if (session.origin.isNotEmpty) {
        _originCtrl.text = session.origin;
      }
      if (session.cookie.isNotEmpty) {
        _cookieCtrl.text = session.cookie;
      }
      _pageController.importAuthSession(l.text('auth_session_imported'));

      if (reanalyzeAfterImport) {
        await _analyze(skipAutoAuth: true);
      }
    } finally {
      _pageController.setAutoOpeningAuthBrowser(false);
    }
  }

  Future<void> _analyze({bool skipAutoAuth = false}) async {
    if (!_formKey.currentState!.validate()) {
      return;
    }
    final l = AppLocalizations.of(context);
    final targetUrl = _urlCtrl.text.trim();
    final requestContext = _requestContext();
    var shouldAutoOpenAuthBrowser = false;

    _pageController.beginAnalyze(l.text('analyzing'));

    try {
      final inspection = await _engine.inspect(
        url: targetUrl,
        requestContext: requestContext,
      );
      if (!mounted) {
        return;
      }
      if (inspection.pageUrl.isNotEmpty) {
        _replaceSourceText(inspection.pageUrl);
      }
      final selectedCandidate =
          inspection.candidates.isNotEmpty ? inspection.candidates.first : null;
      _pageController.completeAnalyze(
        inspection,
        selectedCandidate: selectedCandidate,
        readyStatus: l.text('ready'),
        emptyStatus: l.text('no_candidates'),
      );
      // A new inspection describes a different episode, whose tracks are
      // its own: a pick made on the previous one must not leak into it.
      setState(() => _subtitlePreference = const SubtitleAutoPreference());
      if (selectedCandidate != null) {
        _fileNameCtrl.text = _suggestFileName(selectedCandidate);
      }
      shouldAutoOpenAuthBrowser = _shouldAutoOpenAuthBrowser(
        skipAutoAuth: skipAutoAuth,
        inspection: inspection,
      );
      if (shouldAutoOpenAuthBrowser && mounted) {
        _pageController.markAuthRedirecting(l.text('auth_redirecting'));
      }
    } catch (error) {
      if (!mounted) {
        return;
      }
      final errorText = '$error';
      shouldAutoOpenAuthBrowser = _shouldAutoOpenAuthBrowser(
        skipAutoAuth: skipAutoAuth,
        errorText: errorText,
      );
      _pageController.setError(
        errorText,
        status: shouldAutoOpenAuthBrowser ? l.text('auth_redirecting') : null,
        progress: 0,
      );
    } finally {
      _pageController.finishAnalyze();
    }

    if (shouldAutoOpenAuthBrowser && mounted) {
      await _openAuthBrowser(reanalyzeAfterImport: true);
    }
  }

  Future<void> _download() async {
    if (!_formKey.currentState!.validate()) {
      return;
    }
    // A series queue owns the download pipeline while it runs; a manual
    // click would interleave a second task with the queue.
    if (_seriesQueueActive) {
      return;
    }
    final l = AppLocalizations.of(context);
    final requestContext = _requestContext();

    var vm = _pageController.value;
    final enteredUrl = extractSourceUrl(_urlCtrl.text)!;
    _replaceSourceText(enteredUrl);
    final selectedCandidate = vm.selectedCandidate;
    final candidateMatchesInput = selectedCandidate != null &&
        (selectedCandidate.pageUrl == enteredUrl ||
            selectedCandidate.mediaUrl == enteredUrl);
    final pageUrl =
        candidateMatchesInput ? selectedCandidate.pageUrl : enteredUrl;
    final mediaUrl =
        candidateMatchesInput ? selectedCandidate.mediaUrl : enteredUrl;
    final mediaFallbackUrls = candidateMatchesInput
        ? selectedCandidate.mediaFallbackUrls
        : const <String>[];
    final audioUrl = candidateMatchesInput ? selectedCandidate.audioUrl : null;
    final audioFallbackUrls = candidateMatchesInput
        ? selectedCandidate.audioFallbackUrls
        : const <String>[];
    final sourcePage = pageUrl;

    final fileName = _normalizeOutputName(_fileNameCtrl.text.trim());
    final chosenDir = vm.chosenDir;
    final keepTemp = vm.keepTemp;
    final output = await _tempOutputPathFor(fileName, chosenDir);
    // Sanity-clamp the numeric knobs before they reach the native engine so a
    // stray/typoed value can never cause pathological resource use. The Rust
    // downloader shares one connection pool of 4 per host, so a concurrency
    // above 4 only adds worker contention and timeouts, never more speed.
    final concurrency =
        int.parse(_concurrencyCtrl.text.trim()).clamp(1, 16).toInt();
    final retries = int.parse(_retriesCtrl.text.trim()).clamp(1, 10).toInt();
    final vBitrate =
        int.parse(_vBitrateCtrl.text.trim()).clamp(0, 20000).toInt();
    final aBitrate = int.parse(_aBitrateCtrl.text.trim()).clamp(0, 512).toInt();

    final (subtitleMode, subtitleValue) =
        subtitleChoiceForSingle(_subtitlePreference);
    final request = _DownloadTaskRequest(
      pageUrl: pageUrl,
      mediaUrl: mediaUrl,
      mediaFallbackUrls: mediaFallbackUrls,
      audioUrl: audioUrl,
      audioFallbackUrls: audioFallbackUrls,
      output: output,
      chosenDir: chosenDir,
      options: DownloadOptions(
        concurrency: concurrency,
        retries: retries,
        videoBitrate: vBitrate,
        audioBitrate: aBitrate,
        keepTemp: keepTemp,
        subtitleMode: subtitleMode,
        subtitleValue: subtitleValue,
      ),
      requestContext: requestContext,
      fileName: fileName,
      sourcePage: sourcePage,
    );
    final taskId = _pageController.beginDownloadTask(
      fileName: fileName,
      sourcePage: sourcePage,
      status: l.text('preparing'),
    );
    _retryRequests[taskId] = request;
    final visibleTaskIds =
        _pageController.value.downloadTasks.map((task) => task.id).toSet();
    _retryRequests.removeWhere((id, _) => !visibleTaskIds.contains(id));

    await _runDownloadTask(taskId, request);
  }

  Future<void> _retryDownloadTask(String taskId) async {
    final request = _retryRequests[taskId];
    if (request == null || !mounted) {
      return;
    }
    final l = AppLocalizations.of(context);
    if (!_pageController.retryDownloadTask(
      taskId,
      status: l.text('preparing'),
    )) {
      return;
    }
    final refreshedRequest = request.withRequestContext(_requestContext());
    _retryRequests[taskId] = refreshedRequest;
    await _runDownloadTask(taskId, refreshedRequest);
  }

  /// Re-analyze the page for one episode of the active series.
  Future<void> _switchToEntry(MediaCollectionEntry entry) async {
    if (entry.current || entry.pageUrl.isEmpty) {
      return;
    }
    final vm = _pageController.value;
    if (vm.busy || _seriesQueueActive) {
      return;
    }
    _replaceSourceText(entry.pageUrl);
    await _analyze();
  }

  /// Queue every available episode of the active series as its own task,
  /// running one at a time. Each task re-resolves its stream at download
  /// time, which keeps the signed CDN URLs fresh no matter how long the
  /// queue takes.
  Future<void> _downloadSeries() async {
    final vm = _pageController.value;
    final collection = vm.inspection?.collection;
    if (collection == null ||
        vm.running ||
        vm.analyzing ||
        _seriesQueueActive) {
      return;
    }
    final entries = [
      for (final entry in collection.entries)
        if (entry.available && entry.pageUrl.isNotEmpty) entry,
    ];
    if (entries.isEmpty) {
      return;
    }

    final l = AppLocalizations.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l.text('download_series_title')),
        content: Text(
          '${collection.title}\n'
          '${entries.length} ${l.text('episodes_unit')}\n\n'
          '${l.text('download_series_body')}',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(l.text('cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(l.text('download_all')),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) {
      return;
    }

    final concurrency =
        int.parse(_concurrencyCtrl.text.trim()).clamp(1, 16).toInt();
    final retries = int.parse(_retriesCtrl.text.trim()).clamp(1, 10).toInt();
    final vBitrate =
        int.parse(_vBitrateCtrl.text.trim()).clamp(0, 20000).toInt();
    final aBitrate = int.parse(_aBitrateCtrl.text.trim()).clamp(0, 512).toInt();
    // One queue, many episodes: an exact track URL would only be valid for
    // the episode the pick was made on, so the language tag travels.
    final (seriesSubtitleMode, seriesSubtitleValue) =
        subtitleChoiceForSeries(_subtitlePreference);
    final requestContext = _requestContext();
    final chosenDir = vm.chosenDir;
    final keepTemp = vm.keepTemp;

    setState(() => _seriesQueueActive = true);
    try {
      for (final entry in entries) {
        if (!mounted) {
          return;
        }
        final fileName = _seriesFileName(collection, entry);
        final output = await _tempOutputPathFor(fileName, chosenDir);
        final taskId = _pageController.beginDownloadTask(
          fileName: fileName,
          sourcePage: entry.pageUrl,
          status: l.text('preparing'),
        );
        final request = _DownloadTaskRequest(
          pageUrl: entry.pageUrl,
          mediaUrl: entry.pageUrl,
          audioUrl: null,
          output: output,
          chosenDir: chosenDir,
          options: DownloadOptions(
            concurrency: concurrency,
            retries: retries,
            videoBitrate: vBitrate,
            audioBitrate: aBitrate,
            keepTemp: keepTemp,
            subtitleMode: seriesSubtitleMode,
            subtitleValue: seriesSubtitleValue,
          ),
          requestContext: requestContext,
          fileName: fileName,
          sourcePage: entry.pageUrl,
        );
        _retryRequests[taskId] = request;
        // Auto-opening the auth browser mid-queue would interrupt every
        // following episode; failures stay per-task and retryable instead.
        await _runDownloadTask(taskId, request, allowAutoAuth: false);
      }
    } finally {
      if (mounted) {
        setState(() => _seriesQueueActive = false);
      }
    }
  }

  /// Export the SRT the engine wrote next to its output, so the subtitle is
  /// visible in the same Downloads folder as the video. Best effort: a
  /// finished download must not fail because a sidecar copy did.
  Future<void> _exportSubtitleSidecar(_DownloadTaskRequest request) async {
    try {
      final subtitlePath = _siblingSrtPath(request.output);
      if (!await localFileExists(subtitlePath)) {
        return;
      }
      final subtitleName = _srtFileName(request.fileName);
      final chosenDir = request.chosenDir;
      if (chosenDir != null && chosenDir.isNotEmpty) {
        await MediaStoreBridge.saveToPath(
          subtitlePath,
          chosenDir,
          subtitleName,
        );
      } else {
        await MediaStoreBridge.saveViaMediaStore(
          subtitlePath,
          subtitleName,
          mimeType: 'application/x-subrip',
        );
      }
      await localFileDelete(subtitlePath);
    } catch (error) {
      debugPrint('Subtitle export failed: $error');
    }
  }

  String _siblingSrtPath(String output) {
    final dot = output.lastIndexOf('.');
    final base = dot <= 0 ? output : output.substring(0, dot);
    return '$base.srt';
  }

  String _srtFileName(String fileName) {
    final dot = fileName.lastIndexOf('.');
    final base = dot <= 0 ? fileName : fileName.substring(0, dot);
    return '$base.srt';
  }

  /// Compose the output name for one episode: `{series} - {episode}`,
  /// dropping the series prefix when the episode title already carries it.
  String _seriesFileName(
    MediaCollection collection,
    MediaCollectionEntry entry,
  ) {
    final series = collection.title.trim();
    final episode = entry.title.trim();
    final combined = episode.isEmpty
        ? series
        : (series.isEmpty || episode.startsWith(series))
            ? episode
            : '$series - $episode';
    final runes = combined.runes.toList();
    final capped =
        runes.length > 100 ? String.fromCharCodes(runes.take(100)) : combined;
    return _normalizeOutputName(capped.isEmpty ? 'video' : capped);
  }

  Future<void> _runDownloadTask(
    String taskId,
    _DownloadTaskRequest request, {
    bool allowAutoAuth = true,
  }) async {
    final l = AppLocalizations.of(context);
    var shouldAutoOpenAuthBrowser = false;
    var downloadStreamFailed = false;
    await MediaStoreBridge.startForegroundService();
    var lastNotifiedPercent = -1;
    var lastNotifiedMessage = <String>{};

    try {
      await for (final event in _engine.download(
        pageUrl: request.pageUrl,
        mediaUrl: request.mediaUrl,
        mediaFallbackUrls: request.mediaFallbackUrls,
        audioUrl: request.audioUrl,
        audioFallbackUrls: request.audioFallbackUrls,
        output: request.output,
        options: request.options,
        requestContext: request.requestContext,
      )) {
        if (!mounted) {
          return;
        }
        final terminalError = event.error;
        if (terminalError != null && terminalError.isNotEmpty) {
          _pageController.failDownloadTask(
            taskId,
            terminalError,
            status: null,
            progress: 0,
          );
          downloadStreamFailed = true;
          shouldAutoOpenAuthBrowser = allowAutoAuth &&
              _shouldAutoOpenAuthBrowser(
                skipAutoAuth: false,
                errorText: terminalError,
              );
          break;
        }
        _pageController.updateDownloadTask(
          taskId,
          event.message,
          event.progress,
        );
        final percent = (event.progress * 100).round();
        final isNewMessage = !lastNotifiedMessage.contains(event.message);
        if (isNewMessage || percent - lastNotifiedPercent >= 1) {
          lastNotifiedPercent = percent;
          lastNotifiedMessage = {event.message};
          await MediaStoreBridge.updateForegroundProgress(
            percent,
            event.message,
          );
        }
      }

      if (!mounted) {
        return;
      }

      if (!downloadStreamFailed) {
        String finalPath;
        if (_engine.writesLocalFiles) {
          if (!await localFileExists(request.output) ||
              await localFileLength(request.output) == 0) {
            _pageController.failDownloadTask(
              taskId,
              l.text('output_not_created'),
              status: null,
              progress: 0,
            );
            return;
          }
          finalPath = request.output;
          if (SegmerisPlatform.isAndroid) {
            String? savedPath;
            final chosenDir = request.chosenDir;
            if (chosenDir != null && chosenDir.isNotEmpty) {
              savedPath = await MediaStoreBridge.saveToPath(
                request.output,
                chosenDir,
                request.fileName,
              );
            } else {
              savedPath = await MediaStoreBridge.saveViaMediaStore(
                request.output,
                request.fileName,
              );
            }
            if (savedPath == null) {
              _pageController.failDownloadTask(
                taskId,
                '${l.text('export_failed')} ${request.output}',
                status: null,
              );
              return;
            }
            finalPath = savedPath;
            // The engine writes subtitles as a sidecar next to its output;
            // app-private storage is invisible to the user, so the SRT has
            // to make the same trip the video does. Best effort: a failed
            // subtitle copy must not fail a finished download.
            await _exportSubtitleSidecar(request);
            await localFileDelete(request.output);
          }
        } else {
          // Web: the file lives on the API server; surface its path.
          finalPath = _engine.lastResultPath ?? request.output;
        }

        _retryRequests.remove(taskId);
        _pageController.completeDownloadTask(
          id: taskId,
          finalPath: finalPath,
          fileName: request.fileName,
          sourcePage: request.sourcePage,
          completedStatus: l.text('completed'),
        );
      }
    } catch (error) {
      if (!mounted) {
        return;
      }
      final errorText = '$error';
      shouldAutoOpenAuthBrowser = allowAutoAuth &&
          _shouldAutoOpenAuthBrowser(
            skipAutoAuth: false,
            errorText: errorText,
          );
      _pageController.failDownloadTask(
        taskId,
        errorText,
        status: shouldAutoOpenAuthBrowser ? l.text('auth_redirecting') : null,
        progress: 0,
      );
    } finally {
      if (!_pageController.value.running) {
        await MediaStoreBridge.stopForegroundService();
      }
    }

    if (shouldAutoOpenAuthBrowser && mounted) {
      await _openAuthBrowser(reanalyzeAfterImport: true);
    }
  }

  Future<void> _showSettingsSheet() async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      useSafeArea: true,
      builder: (context) => HomeSettingsSheet(
        settings: widget.settings,
        enabled: !_pageController.value.busy,
        inspection: _pageController.value.inspection,
        onSettingsChanged: widget.onSettingsChanged,
        onOpenBrowser: () => _openAuthBrowser(
          reanalyzeAfterImport:
              _pageController.value.inspection?.authRequired ?? false,
        ),
        onClearContext: _clearAuthContext,
        authContextListenable: _authContextListenable,
        authContextBadges: _authContextBadges,
        hasAuthContextOverrides: () => _hasAuthContextOverrides,
        userAgentController: _userAgentCtrl,
        refererController: _refererCtrl,
        originController: _originCtrl,
        cookieController: _cookieCtrl,
        headersController: _headersCtrl,
      ),
    );
  }

  void _replaceSourceText(String source) {
    if (_urlCtrl.text == source) {
      return;
    }
    _urlCtrl.value = TextEditingValue(
      text: source,
      selection: TextSelection.collapsed(offset: source.length),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _pageController,
      builder: (context, _) {
        final vm = _pageController.value;
        final l = AppLocalizations.of(context);
        final t = Theme.of(context);
        final cs = t.colorScheme;

        return Scaffold(
          appBar: AppBar(
            title: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(l.text('app_title')),
                Text(
                  l.text('app_subtitle'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: t.textTheme.bodySmall?.copyWith(
                    color: cs.onSurfaceVariant,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
            actions: [
              IconButton(
                onPressed: _showSettingsSheet,
                icon: const Icon(Icons.tune_rounded),
                tooltip: l.text('appearance'),
              ),
            ],
          ),
          body: ColoredBox(
            color: cs.surface,
            child: SafeArea(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  if (constraints.maxWidth >= 1080) {
                    return Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          flex: 7,
                          child: RevealMotion(
                            delay: const Duration(milliseconds: 40),
                            child: _buildPrimaryPane(
                              context,
                              vm: vm,
                              scrollable: true,
                              padding: const EdgeInsets.fromLTRB(
                                16,
                                10,
                                16,
                                28,
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 12),
                        SizedBox(
                          width: 360,
                          child: RevealMotion(
                            delay: const Duration(milliseconds: 120),
                            offset: const Offset(0.06, 0),
                            child: _buildSidePane(
                              context,
                              vm: vm,
                              scrollable: true,
                              padding: const EdgeInsets.fromLTRB(0, 10, 16, 28),
                            ),
                          ),
                        ),
                      ],
                    );
                  }
                  return ListView(
                    physics: const BouncingScrollPhysics(
                      parent: AlwaysScrollableScrollPhysics(),
                    ),
                    padding: const EdgeInsets.fromLTRB(16, 10, 16, 28),
                    children: [
                      RevealMotion(
                        delay: const Duration(milliseconds: 40),
                        child: _buildPrimaryPane(
                          context,
                          vm: vm,
                          scrollable: false,
                        ),
                      ),
                      const SizedBox(height: 12),
                      RevealMotion(
                        delay: const Duration(milliseconds: 120),
                        child: _buildSidePane(
                          context,
                          vm: vm,
                          scrollable: false,
                        ),
                      ),
                    ],
                  );
                },
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildPrimaryPane(
    BuildContext context, {
    required HomePageViewModel vm,
    required bool scrollable,
    EdgeInsetsGeometry padding = EdgeInsets.zero,
  }) {
    final l = AppLocalizations.of(context);
    final children = <Widget>[
      if (SegmerisPlatform.isAndroid && !vm.ignoringBattery)
        Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: BatteryBanner(
            title: l.text('battery'),
            body: l.text('battery_hint'),
            buttonLabel: l.text('disable_now'),
            onRequest: () async {
              await MediaStoreBridge.requestIgnoreBatteryOptimizations();
              Future.delayed(const Duration(seconds: 2), _checkBattery);
            },
          ),
        ),
      HomeInputCard(
        formKey: _formKey,
        urlController: _urlCtrl,
        fileNameController: _fileNameCtrl,
        concurrencyController: _concurrencyCtrl,
        retriesController: _retriesCtrl,
        videoBitrateController: _vBitrateCtrl,
        audioBitrateController: _aBitrateCtrl,
        running: vm.running || _seriesQueueActive,
        analyzing: vm.analyzing,
        keepTemp: vm.keepTemp,
        chosenDir: vm.chosenDir,
        onPickDir: _pickDir,
        onResetDir: () => _pageController.setChosenDir(null),
        onAnalyze: _analyze,
        onDownload: _download,
        onKeepTempChanged: _pageController.setKeepTemp,
      ),
      const SizedBox(height: 12),
      if (vm.inspection?.collection != null)
        Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: HomeSeriesCard(
            collection: vm.inspection!.collection!,
            running: vm.running || _seriesQueueActive,
            analyzing: vm.analyzing,
            onEntrySelected: _switchToEntry,
            onDownloadAll: _downloadSeries,
          ),
        ),
      HomeCandidatesCard(
        inspection: vm.inspection,
        selectedCandidate: vm.selectedCandidate,
        subtitlePreference: _subtitlePreference,
        running: vm.running,
        analyzing: vm.analyzing,
        selectionRevision: vm.selectionRevision,
        onCandidateSelected: (candidate) {
          _pageController.selectCandidate(
            candidate,
            status: l.text('candidate_switched'),
          );
          _fileNameCtrl.text = _suggestFileName(candidate);
        },
        onSubtitlePreferenceChanged: (preference) {
          setState(() => _subtitlePreference = preference);
        },
        onOpenAuthBrowser: () => _openAuthBrowser(reanalyzeAfterImport: true),
      ),
    ];

    if (scrollable) {
      return ListView(
        physics: const BouncingScrollPhysics(
          parent: AlwaysScrollableScrollPhysics(),
        ),
        padding: padding,
        children: children,
      );
    }

    return Padding(
      padding: padding,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: children,
      ),
    );
  }

  Widget _buildSidePane(
    BuildContext context, {
    required HomePageViewModel vm,
    required bool scrollable,
    EdgeInsetsGeometry padding = EdgeInsets.zero,
  }) {
    final children = <Widget>[
      HomeDownloadTasksCard(
        tasks: vm.downloadTasks,
        onRetry: (taskId) => _retryDownloadTask(taskId),
      ),
      const SizedBox(height: 12),
      HomeHistoryCard(history: vm.history),
    ];

    if (scrollable) {
      return ListView(
        physics: const BouncingScrollPhysics(
          parent: AlwaysScrollableScrollPhysics(),
        ),
        padding: padding,
        children: children,
      );
    }

    return Padding(
      padding: padding,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: children,
      ),
    );
  }
}
