import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:material_ui/material_ui.dart';
import 'package:segmeris/src/app/app_localizations.dart';
import 'package:segmeris/src/app/app_settings.dart';
import 'package:segmeris/src/app/brand_logo.dart';
import 'package:segmeris/src/app/app_update.dart';
import 'package:segmeris/src/app/app_update_widgets.dart';
import 'package:segmeris/src/app/auth_context_store.dart';
import 'package:segmeris/src/app/auth_entry.dart';
import 'package:segmeris/src/app/bilibili_qr_login.dart';
import 'package:segmeris/src/app/auth_browser_page.dart';
import 'package:segmeris/src/app/download_engine.dart';
import 'package:segmeris/src/app/download_state_store.dart';
import 'package:segmeris/src/home/download_session.dart';
import 'package:segmeris/src/home/download_task_request.dart';
import 'package:segmeris/src/app/local_file_utils.dart';
import 'package:segmeris/src/app/platform_bridge.dart';
import 'package:segmeris/src/app/platform_utils.dart';
import 'package:segmeris/src/app/runtime_capabilities.dart';
import 'package:segmeris/src/home/home_candidates_card.dart';
import 'package:segmeris/src/home/download_options_dialog.dart';
import 'package:segmeris/src/home/home_download_tasks_card.dart';
import 'package:segmeris/src/home/home_page_controller.dart';
import 'package:segmeris/src/home/home_history_card.dart';
import 'package:segmeris/src/home/home_input_card.dart';
import 'package:segmeris/src/home/home_series_card.dart';
import 'package:segmeris/src/home/home_settings_sheet.dart';
import 'package:segmeris/src/home/home_widgets.dart';
import 'package:segmeris/src/home/quality_preference.dart';
import 'package:segmeris/src/home/source_input.dart';
import 'package:segmeris/src/home/subtitle_preference.dart';
import 'package:segmeris/src/rust/api/downloader.dart';

class HomePage extends StatefulWidget {
  const HomePage({
    super.key,
    required this.settings,
    required this.onSettingsChanged,
    this.capabilityProbe = RuntimeCapabilityProbe.inspect,
    this.downloadEngine,
    this.stateStore,
    this.updateController,
  });

  final AppSettings settings;
  final ValueChanged<AppSettings> onSettingsChanged;
  final Future<PlatformCapabilitySnapshot> Function() capabilityProbe;
  final DownloadEngine? downloadEngine;
  final DownloadStateStore? stateStore;
  final AppUpdateController? updateController;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> with WidgetsBindingObserver {
  // Not `final`: recreated in `didUpdateWidget` when the web API settings
  // change, so it must be reassignable.
  late DownloadEngine _engine;
  final _formKey = GlobalKey<FormState>();
  final _urlCtrl = TextEditingController();
  final _fileNameCtrl = TextEditingController(text: 'video.mp4');
  final _concurrencyCtrl = TextEditingController(text: '6');
  final _retriesCtrl = TextEditingController(text: '5');
  final _vBitrateCtrl = TextEditingController(text: '0');
  final _aBitrateCtrl = TextEditingController(text: '0');
  final _userAgentCtrl = TextEditingController();
  final _refererCtrl = TextEditingController();
  final _originCtrl = TextEditingController();
  final _cookieCtrl = TextEditingController();
  final _headersCtrl = TextEditingController();
  final _pageController = HomePageController();
  final Map<String, DownloadTaskRequest> _retryRequests = {};
  late final DownloadStateStore _stateStore =
      widget.stateStore ?? createDownloadStateStore();
  bool _sessionReady = false;
  String? _sessionError;
  Timer? _checkpointTimer;
  Timer? _retentionTimer;
  final Set<String> _activeTaskIds = {};
  final Set<String> _removingRecords = {};

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
    _engine =
        widget.downloadEngine ??
        createDownloadEngine(
          apiBaseUrl: widget.settings.apiBaseUrl,
          apiToken: widget.settings.apiToken,
        );
    WidgetsBinding.instance.addObserver(this);
    _checkBattery();
    unawaited(_restoreSession());
  }

  @override
  void didUpdateWidget(HomePage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.settings.historyRetentionDays !=
            widget.settings.historyRetentionDays &&
        _sessionReady) {
      _pruneHistory();
    }
    if (widget.downloadEngine == null &&
        (oldWidget.settings.apiBaseUrl != widget.settings.apiBaseUrl ||
            oldWidget.settings.apiToken != widget.settings.apiToken)) {
      _engine = createDownloadEngine(
        apiBaseUrl: widget.settings.apiBaseUrl,
        apiToken: widget.settings.apiToken,
      );
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _checkpointTimer?.cancel();
    _retentionTimer?.cancel();
    _pageController.removeListener(_scheduleCheckpoint);
    if (_sessionReady) unawaited(_checkpointQuietly());
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

  Future<void> _restoreSession() async {
    try {
      await _restoreAuthContext();
      final json = await _stateStore.load();
      final session = json == null
          ? null
          : await DownloadSession.fromJson(json);
      if (!mounted) return;
      if (session != null) {
        _retryRequests.addAll(session.requests);
        _pageController.restoreDownloads(
          tasks: session.tasks,
          history: session.history,
        );
      }
      setState(() => _sessionReady = true);
      _pageController.addListener(_scheduleCheckpoint);
      _pruneHistory();
      _retentionTimer = Timer.periodic(
        const Duration(hours: 1),
        (_) => _pruneHistory(),
      );
      // Resume serially: reopening a large queue must not start hundreds of
      // independent connection pools at once. Explicitly paused tasks stay paused.
      final resumeIds = _pageController.value.downloadTasks.reversed
          .where((task) => task.interrupted && !task.paused)
          .map((task) => task.id)
          .toList();
      if (resumeIds.isNotEmpty) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) unawaited(_resumeInterrupted(resumeIds));
        });
      }
    } catch (error) {
      if (mounted) setState(() => _sessionError = '$error');
    }
  }

  Future<void> _resumeInterrupted(List<String> ids) async {
    setState(() => _seriesQueueActive = true);
    try {
      for (final id in ids) {
        if (!mounted) return;
        final request = _retryRequests[id];
        if (request == null) continue;
        if (!_pageController.retryDownloadTask(
          id,
          status: AppLocalizations.of(context).text('restoring_download'),
        )) {
          continue;
        }
        await _runDownloadTask(id, request, allowAutoAuth: false);
      }
    } finally {
      if (mounted) setState(() => _seriesQueueActive = false);
    }
  }

  void _scheduleCheckpoint() {
    if (!_sessionReady || _checkpointTimer != null) return;
    _checkpointTimer = Timer(const Duration(seconds: 1), () {
      _checkpointTimer = null;
      unawaited(_checkpointQuietly());
    });
  }

  Future<void> _checkpoint() {
    _checkpointTimer?.cancel();
    _checkpointTimer = null;
    if (!_sessionReady) {
      return Future.error(StateError('Download journal is not available'));
    }
    final vm = _pageController.value;
    return _stateStore.save(
      DownloadSession(
        tasks: vm.downloadTasks,
        history: vm.history,
        requests: _retryRequests,
      ).toJson(),
    );
  }

  Future<void> _checkpointQuietly() async {
    try {
      await _checkpoint();
      if (mounted && _sessionError != null) {
        setState(() => _sessionError = null);
      }
    } catch (error) {
      if (mounted) setState(() => _sessionError = '$error');
    }
  }

  void _pruneHistory() {
    if (_pageController.pruneHistory(widget.settings.historyRetentionDays)) {
      unawaited(_checkpointQuietly());
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!_sessionReady) return;
    if (state == AppLifecycleState.resumed) _pruneHistory();
    unawaited(_checkpointQuietly());
  }

  Future<void> _checkBattery() async {
    final value = await MediaStoreBridge.isIgnoringBatteryOptimizations();
    if (mounted) _pageController.setIgnoringBattery(value);
  }

  Future<void> _pickDir() async {
    if (_pageController.value.analyzing || SegmerisPlatform.isWeb) {
      return;
    }
    final uri = await FilePicker.pickDirectory();
    if (uri != null && mounted) {
      _pageController.setChosenDir(
        uri.scheme == 'file' ? uri.toFilePath() : uri.toString(),
      );
    }
  }

  Future<String> _tempOutputPathFor(String name, String? chosenDir) async {
    String path;
    if (!_engine.writesLocalFiles) {
      path = name;
    } else {
      final privateDir = SegmerisPlatform.isAndroid
          ? await MediaStoreBridge.getAppPrivateDir()
          : null;
      if (SegmerisPlatform.isAndroid &&
          (privateDir == null || privateDir.isEmpty)) {
        throw StateError('Application download directory is unavailable');
      }
      path = await localOutputPath(name, privateDir ?? chosenDir);
    }
    final reserved = _retryRequests.values
        .map((request) => request.output.toLowerCase())
        .toSet();
    final dot = path.lastIndexOf('.');
    final base = dot < 0 ? path : path.substring(0, dot);
    final extension = dot < 0 ? '' : path.substring(dot);
    var candidate = path;
    var suffix = 1;
    while (reserved.contains(candidate.toLowerCase()) ||
        (_engine.writesLocalFiles && await localFileExists(candidate))) {
      candidate = '$base (${suffix++})$extension';
    }
    return candidate;
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
    final raw = candidate.title.trim().isEmpty
        ? 'video'
        : candidate.title.trim();
    final sanitized = raw.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
    final quality = candidate.qualityLabel.trim().replaceAll(
      RegExp(r'[\\/:*?"<>|]'),
      '_',
    );
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

  /// Put the stored session back into the fields on startup.
  ///
  /// A signed-in session is meant to survive the app being closed; asking for
  /// the login again on every launch is exactly the defect this repairs.
  Future<void> _restoreAuthContext() async {
    final stored = await AuthContextStore.load();
    // Never overwrite something the user has already put on screen.
    if (!mounted || stored == null || _hasAuthContextOverrides) {
      return;
    }
    setState(() {
      _userAgentCtrl.text = stored.userAgent;
      _refererCtrl.text = stored.referer;
      _originCtrl.text = stored.origin;
      _cookieCtrl.text = stored.cookie;
      _headersCtrl.text = _serializeHeaderEntries(stored.headers);
    });
  }

  Future<void> _persistAuthContext() =>
      AuthContextStore.save(_requestContext());

  /// The inverse of [_parseHeaderEntries], so a restored session re-enters the
  /// editor in the format it is edited in.
  String _serializeHeaderEntries(List<HeaderEntry> headers) =>
      [for (final header in headers) '${header.name}: ${header.value}']
          .join('\n');

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

  Future<void> _clearAuthContext() async {
    try {
      await AuthContextStore.clear();
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(error.toString())));
      }
      return;
    }
    if (!mounted) return;
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

  /// Log in to Bilibili with the account holder's own phone, then hand the
  /// resulting session to the request context.
  ///
  /// This is the dependable half of the two login routes: it needs no
  /// embedded browser, so it works even where a WebView renders nothing, and
  /// what it produces is the account's own session — the server still decides
  /// what that account may download.
  Future<void> _qrLogin({bool reanalyzeAfterImport = false}) async {
    final l = AppLocalizations.of(context);
    final cookie = await showBilibiliQrLoginDialog(
      context,
      requestContext: _requestContext(),
    );
    if (!mounted || cookie == null || cookie.isEmpty) {
      return;
    }
    _cookieCtrl.text = cookie;
    _pageController.importAuthSession(l.text('auth_session_imported'));
    await _persistAuthContext();
    if (reanalyzeAfterImport) {
      await _analyze(skipAutoAuth: true);
    }
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
            initialUrl: authEntryUrlFor(targetUrl),
            sourceUrl: targetUrl,
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
      await _persistAuthContext();

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
      final selectedCandidate = inspection.candidates.isNotEmpty
          ? inspection.candidates.first
          : null;
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
    if (_seriesQueueActive || !_sessionReady || _sessionError != null) {
      return;
    }
    final l = AppLocalizations.of(context);
    final requestContext = _requestContext();

    var vm = _pageController.value;
    final enteredUrl = extractSourceUrl(_urlCtrl.text)!;
    _replaceSourceText(enteredUrl);

    final inspection = vm.inspection;
    var selection = vm.selectedCandidate;
    final candidates = inspection?.candidates ?? const <MediaCandidate>[];
    if (candidates.isNotEmpty &&
        (inspection!.pageUrl == enteredUrl ||
            selection?.mediaUrl == enteredUrl)) {
      selection = await showDownloadOptionsDialog(
        context,
        inspection: inspection,
        initial: selection,
        onOpenAuthBrowser: () => _openAuthBrowser(reanalyzeAfterImport: true),
        onQrLogin: () => _qrLogin(reanalyzeAfterImport: true),
      );
      if (!mounted || selection == null) {
        return;
      }
      _pageController.selectCandidate(selection);
      _fileNameCtrl.text = _suggestFileName(selection);
      vm = _pageController.value;
    }

    final selectedCandidate = selection ?? vm.selectedCandidate;
    final candidateMatchesInput =
        selectedCandidate != null &&
        (selectedCandidate.pageUrl == enteredUrl ||
            selectedCandidate.mediaUrl == enteredUrl);
    final pageUrl = candidateMatchesInput
        ? selectedCandidate.pageUrl
        : enteredUrl;
    final mediaUrl = candidateMatchesInput
        ? selectedCandidate.mediaUrl
        : enteredUrl;
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
    final concurrency = int.parse(_concurrencyCtrl.text.trim())
        .clamp(1, 16)
        .toInt();
    final retries = int.parse(_retriesCtrl.text.trim()).clamp(1, 10).toInt();
    final vBitrate = int.parse(_vBitrateCtrl.text.trim())
        .clamp(0, 20000)
        .toInt();
    final aBitrate = int.parse(_aBitrateCtrl.text.trim()).clamp(0, 512).toInt();

    final (subtitleMode, subtitleValue) = subtitleChoiceForSingle(
      _subtitlePreference,
    );
    final request = DownloadTaskRequest(
      preferredTier: candidateMatchesInput ? selectedCandidate : null,
      strictTier: true,
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
    final visibleTaskIds = _pageController.value.downloadTasks
        .map((task) => task.id)
        .toSet();
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

    final tier = await showDownloadOptionsDialog(
      context,
      inspection: vm.inspection!,
      initial: vm.selectedCandidate,
      hintKey: 'quality_dialog_series_hint',
      onOpenAuthBrowser: () => _openAuthBrowser(reanalyzeAfterImport: true),
      onQrLogin: () => _qrLogin(reanalyzeAfterImport: true),
    );
    if (!mounted || tier == null) {
      return;
    }

    final concurrency = int.parse(_concurrencyCtrl.text.trim())
        .clamp(1, 16)
        .toInt();
    final retries = int.parse(_retriesCtrl.text.trim()).clamp(1, 10).toInt();
    final vBitrate = int.parse(_vBitrateCtrl.text.trim())
        .clamp(0, 20000)
        .toInt();
    final aBitrate = int.parse(_aBitrateCtrl.text.trim()).clamp(0, 512).toInt();
    final (seriesSubtitleMode, seriesSubtitleValue) = subtitleChoiceForSeries(
      _subtitlePreference,
    );
    final requestContext = _requestContext();
    final chosenDir = vm.chosenDir;
    final keepTemp = vm.keepTemp;

    setState(() => _seriesQueueActive = true);
    try {
      final queued = <String>[];
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
          queued: true,
        );
        final request = DownloadTaskRequest(
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
          preferredTier: tier,
        );
        _retryRequests[taskId] = request;
        await request.saveCredentials(taskId);
        queued.add(taskId);
      }
      await _checkpoint();
      for (final taskId in queued) {
        if (!mounted) return;
        final request = _retryRequests[taskId];
        if (request == null ||
            !_pageController.retryDownloadTask(
              taskId,
              status: l.text('preparing'),
            )) {
          continue;
        }
        await _runDownloadTask(taskId, request, allowAutoAuth: false);
      }
    } catch (error) {
      if (mounted) setState(() => _sessionError = '$error');
    } finally {
      if (mounted) {
        setState(() => _seriesQueueActive = false);
      }
    }
  }

  /// Export the SRT the engine wrote next to its output, so the subtitle is
  /// visible in the same Downloads folder as the video. Best effort: a
  /// finished download must not fail because a sidecar copy did.
  Future<void> _exportSubtitleSidecar(DownloadTaskRequest request) async {
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
    final capped = runes.length > 100
        ? String.fromCharCodes(runes.take(100))
        : combined;
    return _normalizeOutputName(capped.isEmpty ? 'video' : capped);
  }

  /// Resolve the tier a queued episode should download right now.
  ///
  /// Returns `null` — and fails the task with the reason — when the episode
  /// has no stream this session may fetch. The queue keeps going: one gated
  /// episode must not stall the rest.
  Future<MediaCandidate?> _resolveQueuedSource(
    String taskId,
    DownloadTaskRequest request,
    AppLocalizations l,
  ) async {
    try {
      final inspection = await _engine.inspect(
        url: request.pageUrl,
        requestContext: request.requestContext,
      );
      if (!mounted) return null;
      final source = request.strictTier && request.preferredTier != null
          ? candidateForResumeTier(
              inspection.candidates,
              request.preferredTier!,
            )
          : candidateForTier(inspection.candidates, request.preferredTier);
      if (source == null) {
        _pageController.failDownloadTask(
          taskId,
          l.text(request.strictTier ? 'quality_unavailable' : 'no_candidates'),
          status: null,
          progress: 0,
        );
        return null;
      }
      return source;
    } catch (error) {
      _pageController.failDownloadTask(
        taskId,
        '$error',
        status: null,
        progress: 0,
      );
      return null;
    }
  }

  Future<void> _toggleDownloadPause(String taskId) async {
    final engine = _engine;
    if (engine is! PausableDownloadEngine) return;
    final tasks = _pageController.value.downloadTasks.where(
      (task) => task.id == taskId,
    );
    final request = _retryRequests[taskId];
    if (tasks.isEmpty || request == null) return;
    final task = tasks.first;
    if (!task.canPause || task.controlBusy) return;
    _pageController.setTaskControl(taskId, busy: true);
    try {
      final accepted = await (engine as PausableDownloadEngine).setPaused(
        output: request.output,
        paused: !task.paused,
      );
      if (mounted && accepted) {
        _pageController.setTaskControl(taskId, paused: !task.paused);
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              '${AppLocalizations.of(context).text("download_control_failed")}: $error',
            ),
          ),
        );
      }
    } finally {
      if (mounted) _pageController.setTaskControl(taskId, busy: false);
    }
  }

  Future<void> _runDownloadTask(
    String taskId,
    DownloadTaskRequest request, {
    bool allowAutoAuth = true,
  }) async {
    if (!_activeTaskIds.add(taskId)) return;
    final l = AppLocalizations.of(context);
    final engine = _engine;
    var shouldAutoOpenAuthBrowser = false;
    var downloadStreamFailed = false;
    var lastNotifiedPercent = -1;
    final notificationClock = Stopwatch()..start();
    var lastNotificationMs = -1000;

    try {
      // Commit the request before starting any network or file work.
      await request.saveCredentials(taskId);
      await _checkpoint();
      if (!mounted) return;
      var effective = request;
      if (request.preferredTier != null) {
        final resolved = await _resolveQueuedSource(taskId, request, l);
        if (!mounted || resolved == null) return;
        effective = request.withResolvedSource(resolved);
        _retryRequests[taskId] = effective;
        await _checkpoint();
      }
      if (!mounted) return;
      _pageController.setTaskControl(
        taskId,
        paused: false,
        urls: [
          effective.mediaUrl,
          if (effective.audioUrl != null) effective.audioUrl!,
        ],
      );
      await MediaStoreBridge.startForegroundService();
      await for (final event in engine.download(
        pageUrl: effective.pageUrl,
        mediaUrl: effective.mediaUrl,
        mediaFallbackUrls: effective.mediaFallbackUrls,
        audioUrl: effective.audioUrl,
        audioFallbackUrls: effective.audioFallbackUrls,
        output: effective.output,
        options: effective.options,
        requestContext: effective.requestContext,
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
          shouldAutoOpenAuthBrowser =
              allowAutoAuth &&
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
        final progress = event.progress;
        final percent = progress.isFinite
            ? (progress.clamp(0.0, 1.0) * 100).round()
            : lastNotifiedPercent.clamp(0, 100);
        if (notificationClock.elapsedMilliseconds - lastNotificationMs >=
                1000 ||
            percent == 100) {
          lastNotifiedPercent = percent;
          lastNotificationMs = notificationClock.elapsedMilliseconds;
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
        if (engine.writesLocalFiles) {
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
            await _exportSubtitleSidecar(request);
          }
        } else {
          // Web: the file lives on the API server; surface its path.
          finalPath = engine.lastResultPath ?? request.output;
        }

        _retryRequests.remove(taskId);
        _pageController.completeDownloadTask(
          id: taskId,
          finalPath: finalPath,
          fileName: request.fileName,
          sourcePage: request.sourcePage,
          completedStatus: l.text('completed'),
        );
        // Publish history durably before removing the recoverable private copy.
        await _checkpoint();
        await DownloadTaskRequest.deleteCredentials(taskId);
        if (SegmerisPlatform.isAndroid && engine.writesLocalFiles) {
          try {
            await localFileDelete(request.output);
          } catch (error) {
            debugPrint('Completed private copy cleanup failed: $error');
          }
        }
      }
    } catch (error) {
      if (!mounted) {
        return;
      }
      final errorText = '$error';
      shouldAutoOpenAuthBrowser =
          allowAutoAuth &&
          _shouldAutoOpenAuthBrowser(skipAutoAuth: false, errorText: errorText);
      _pageController.failDownloadTask(
        taskId,
        errorText,
        status: shouldAutoOpenAuthBrowser ? l.text('auth_redirecting') : null,
        progress: 0,
      );
    } finally {
      _activeTaskIds.remove(taskId);
      if (mounted) await _checkpointQuietly();
      if (_activeTaskIds.isEmpty) {
        await MediaStoreBridge.stopForegroundService();
      }
    }

    if (shouldAutoOpenAuthBrowser && mounted) {
      await _openAuthBrowser(reanalyzeAfterImport: true);
    }
  }

  Future<void> _deleteRecord(DownloadRecord record) async {
    if (!_removingRecords.add(record.id)) return;
    try {
      final l = AppLocalizations.of(context);
      final deleteFile = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(l.text('delete_download_title')),
          content: Text('${record.name}\n\n${l.text('delete_download_hint')}'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(l.text('cancel')),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(l.text('remove_record')),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(l.text('delete_file')),
            ),
          ],
        ),
      );
      if (deleteFile == null || !mounted) return;
      if (deleteFile) {
        if (_retryRequests.values.any(
          (request) => request.output == record.path,
        )) {
          throw StateError('An unfinished task still uses this output');
        }
        final engine = _engine;
        if (!engine.writesLocalFiles) {
          if (engine is! CompletedDownloadDeletionEngine ||
              !await (engine as CompletedDownloadDeletionEngine)
                  .deleteDownloadedFile(path: record.path)) {
            throw StateError(
              'The server could not identify this completed file',
            );
          }
        } else if (SegmerisPlatform.isAndroid) {
          await MediaStoreBridge.deleteDownloadedFile(record.path);
        } else {
          await localFileDelete(record.path);
        }
      }
      if (!mounted) return;
      final before = _pageController.value;
      _pageController.removeHistory(record.id);
      try {
        await _checkpoint();
      } catch (_) {
        _pageController.restoreDownloads(
          tasks: before.downloadTasks,
          history: before.history,
        );
        rethrow;
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              '${AppLocalizations.of(context).text('delete_failed')}: $error',
            ),
          ),
        );
      }
    } finally {
      _removingRecords.remove(record.id);
    }
  }

  Future<void> _removeTask(String id) async {
    if (_activeTaskIds.contains(id)) return;
    final records = _pageController.value.history.where(
      (record) => record.taskId == id,
    );
    if (records.isNotEmpty) {
      await _deleteRecord(records.first);
      return;
    }
    final before = _pageController.value;
    final request = _retryRequests[id];
    if (!_pageController.removeDownloadTask(id)) return;
    _retryRequests.remove(id);
    try {
      await _checkpoint();
      await DownloadTaskRequest.deleteCredentials(id);
    } catch (error) {
      if (request != null) _retryRequests[id] = request;
      if (mounted) {
        _pageController.restoreDownloads(
          tasks: before.downloadTasks,
          history: before.history,
        );
        setState(() => _sessionError = '$error');
      }
    }
  }

  Future<void> _showSettingsSheet() async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      useSafeArea: true,
      builder: (context) => HomeSettingsSheet(
        updateController: widget.updateController,
        settings: widget.settings,
        capabilityProbe: widget.capabilityProbe,
        enabled: !_pageController.value.busy,
        inspection: _pageController.value.inspection,
        onSettingsChanged: widget.onSettingsChanged,
        onOpenBrowser: () => _openAuthBrowser(
          reanalyzeAfterImport:
              _pageController.value.inspection?.authRequired ?? false,
        ),
        onQrLogin: () => _qrLogin(
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
    // The sheet is where the session is edited by hand; storing it once it
    // closes keeps a hand-entered cookie as durable as a scanned one.
    await _persistAuthContext();
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
            toolbarHeight: 72,
            title: Row(
              children: [
                ExcludeSemantics(
                  child: ClipPath(
                    clipper: ShapeBorderClipper(
                      shape: MaterialShapeBorder(
                        shape: MaterialShapes.cookie9Sided,
                      ),
                    ),
                    child: const BrandLogo(size: 44),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        l.text('app_title'),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      if (MediaQuery.textScalerOf(context).scale(14) <= 20)
                        Text(
                          l.text('app_subtitle'),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: t.textTheme.bodySmall?.copyWith(
                            color: cs.onSurfaceVariant,
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
            actions: [
              Semantics(
                identifier: 'segmeris.settings',
                child: IconButton(
                  onPressed: _showSettingsSheet,
                  icon: const Icon(Icons.tune_rounded),
                  tooltip: l.text('appearance'),
                ),
              ),
            ],
          ),
          body: ColoredBox(
            color: cs.surface,
            child: SafeArea(
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 1560),
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      final textScale =
                          MediaQuery.textScalerOf(context).scale(14) / 14;
                      final sideWidth = 380 * textScale.clamp(1.0, 1.5);
                      if (constraints.maxWidth >= 720 + sideWidth) {
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
                                    24,
                                    16,
                                    0,
                                    28,
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(width: 20),
                            SizedBox(
                              width: sideWidth,
                              child: RevealMotion(
                                delay: const Duration(milliseconds: 120),
                                offset: const Offset(0.06, 0),
                                child: _buildSidePane(
                                  context,
                                  vm: vm,
                                  scrollable: true,
                                  padding: const EdgeInsets.fromLTRB(
                                    0,
                                    16,
                                    24,
                                    28,
                                  ),
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
                        padding: EdgeInsets.fromLTRB(
                          constraints.maxWidth < 600 ? 16 : 24,
                          12,
                          constraints.maxWidth < 600 ? 16 : 24,
                          28,
                        ),
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
      if (_sessionError != null)
        Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: MaterialBanner(
            content: Text('${l.text('journal_error')}: $_sessionError'),
            actions: [
              TextButton(
                onPressed: () async {
                  if (_sessionReady) {
                    await _checkpointQuietly();
                  } else {
                    setState(() => _sessionError = null);
                    await _restoreSession();
                  }
                },
                child: Text(l.text('retry')),
              ),
            ],
          ),
        ),
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
        running:
            vm.running ||
            _seriesQueueActive ||
            !_sessionReady ||
            _sessionError != null,
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
        onQrLogin: () => _qrLogin(reanalyzeAfterImport: true),
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
      if (widget.updateController case final updates?)
        ListenableBuilder(
          listenable: updates,
          builder: (context, _) => updates.hasUpdate
              ? Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: AppUpdateCard(controller: updates),
                )
              : const SizedBox.shrink(),
        ),
      HomeDownloadTasksCard(
        tasks: vm.downloadTasks,
        onRetry: (taskId) => _retryDownloadTask(taskId),
        onRemove: _removeTask,
        onTogglePause: _engine is PausableDownloadEngine
            ? _toggleDownloadPause
            : null,
      ),
      const SizedBox(height: 12),
      HomeHistoryCard(history: vm.history, onDelete: _deleteRecord),
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
