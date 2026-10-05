import 'package:flutter/material.dart';

class AppLocalizations {
  AppLocalizations(this.locale);

  final Locale locale;

  static const supportedLocales = <Locale>[
    Locale('en'),
    Locale('zh'),
    Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hant'),
    Locale('ja'),
    Locale('ko'),
    Locale('ar'),
    Locale('hi'),
    Locale('ru'),
    Locale('es'),
    Locale('fr'),
    Locale('de'),
    Locale('pt'),
    Locale('tr'),
    Locale('vi'),
    Locale('id'),
    Locale('fa'),
    Locale('ur'),
    Locale('ug'),
    Locale('ku'),
    Locale('uk'),
    Locale('ms'),
    Locale('it'),
    Locale('nl'),
    Locale('sv'),
  ];

  static const delegate = _AppLocalizationsDelegate();

  static const _rtlLanguages = <String>{'ar', 'fa', 'ur', 'ug', 'ku'};

  static AppLocalizations of(BuildContext context) {
    final value = Localizations.of<AppLocalizations>(context, AppLocalizations);
    assert(value != null, 'AppLocalizations not found in context');
    return value!;
  }

  static String localeKeyOf(Locale locale) {
    return locale.scriptCode == null
        ? locale.languageCode
        : '${locale.languageCode}_${locale.scriptCode}';
  }

  static Locale resolveLocale(Locale? locale) {
    if (locale == null) {
      return supportedLocales.firstWhere(
        (item) => item.languageCode == _fallbackLocale,
        orElse: () => supportedLocales.first,
      );
    }

    final exactKey = localeKeyOf(locale);
    for (final item in supportedLocales) {
      if (localeKeyOf(item) == exactKey) {
        return item;
      }
    }

    for (final item in supportedLocales) {
      if (item.languageCode == locale.languageCode) {
        return item;
      }
    }

    return supportedLocales.firstWhere(
      (item) => item.languageCode == _fallbackLocale,
      orElse: () => supportedLocales.first,
    );
  }

  static TextDirection textDirectionOf(Locale locale) {
    return _rtlLanguages.contains(resolveLocale(locale).languageCode)
        ? TextDirection.rtl
        : TextDirection.ltr;
  }

  static const localeLabels = <String, String>{
    'en': 'English',
    'zh': '简体中文',
    'zh_Hant': '繁體中文',
    'ja': '日本語',
    'ko': '한국어',
    'ar': 'العربية',
    'hi': 'हिन्दी',
    'ru': 'Русский',
    'es': 'Español',
    'fr': 'Français',
    'de': 'Deutsch',
    'pt': 'Português',
    'tr': 'Türkçe',
    'vi': 'Tiếng Việt',
    'id': 'Bahasa Indonesia',
    'fa': 'فارسی',
    'ur': 'اردو',
    'ug': 'ئۇيغۇرچە',
    'ku': 'Kurdî',
    'uk': 'Українська',
    'ms': 'Bahasa Melayu',
    'it': 'Italiano',
    'nl': 'Nederlands',
    'sv': 'Svenska',
  };

  static const _fallbackLocale = 'en';

  static const _strings = <String, Map<String, String>>{
    'en': {
      'series_kind_parts': 'Multi-part video',
      'series_kind_collection': 'Collection',
      'series_kind_bangumi': 'Bangumi',
      'series_kind_series': 'Series',
      'episodes_unit': 'episodes',
      'download_all': 'Download all',
      'download_series_title': 'Download the entire series?',
      'download_series_body':
          'Episodes are queued in order, one after another; each finished file is exported immediately.',
      'cancel': 'Cancel',
      'app_title': 'Segmeris',
      'app_subtitle':
          'Inspect pages, locate playable media, and download the best exposed stream.',
      'input_source': 'Source URL',
      'source_hint': 'Paste a webpage, m3u8, mp4, YouTube or Bilibili link',
      'source_invalid': 'Paste a valid HTTP link or video sharing text',
      'paste': 'Paste',
      'clear': 'Clear',
      'file_name': 'Output file',
      'save_location': 'Save location',
      'default_location': 'Default output location',
      'choose_directory': 'Choose directory',
      'reset_default': 'Use default',
      'analyze': 'Analyze source',
      'qr_login_title': 'Sign in with Bilibili',
      'qr_login_hint':
          'Scan the code with the Bilibili app, then confirm on your phone. This is the official Bilibili login: the session is yours, and your account decides what can be downloaded.',
      'qr_login_preparing': 'Preparing the QR code...',
      'qr_login_waiting': 'Waiting for a scan...',
      'qr_login_scanned': 'Scanned - confirm on your phone',
      'qr_login_expired': 'The QR code expired',
      'qr_login_failed': 'Sign in failed',
      'qr_login_retry': 'New QR code',
      'download': 'Download selected stream',
      'quality_dialog_title': 'Choose the quality',
      'quality_dialog_hint':
          'These are the streams this session can reach. Pick one, then start the download.',
      'quality_dialog_series_hint':
          'Applies to every episode: each one downloads this quality or the closest tier it still offers.',
      'auth_browser_open_external':
          'Open in system browser',
      'auth_browser_copy_link':
          'Copy link',
      'auth_browser_link_copied':
          'Link copied',
      'qr_login_open_browser':
          'Open in browser',
      'qr_login_browser_hint':
          'Only one phone? Open the link in this phone\'s browser (signed in to Bilibili) and confirm there.',
      'start_download': 'Start download',
      'download_options': 'Download options',
      'concurrency': 'Concurrency',
      'retries': 'Retries',
      'video_bitrate': 'Video bitrate',
      'audio_bitrate': 'Audio bitrate',
      'keep_temp': 'Keep temporary files',
      'keep_temp_hint': 'Useful for diagnostics and manual remuxing',
      'analysis_results': 'Detected media',
      'status': 'Status',
      'active_downloads': 'Active downloads',
      'running_downloads': 'Running',
      'no_active_downloads': 'No active downloads yet.',
      'history': 'History',
      'warnings': 'Warnings',
      'appearance': 'Appearance',
      'runtime_capabilities': 'Runtime capabilities',
      'probing_capabilities': 'Probing real codec and engine availability...',
      'available': 'Available',
      'not_available': 'Unavailable',
      'unknown': 'Unknown',
      'hardware_encoder': 'Hardware encoder',
      'video_encoders': 'Listed video encoders',
      'video_decoders': 'Hardware video decoders',
      'mode': 'Mode',
      'system': 'System',
      'light': 'Light',
      'dark': 'Dark',
      'theme': 'Theme',
      'language': 'Language',
      'api_base_url': 'API server URL (web build)',
      'api_base_url_hint':
          'Base URL of the Segmeris API server, e.g. http://localhost:3000. Non-local servers must use https.',
      'api_token': 'API token (optional)',
      'api_token_hint':
          'Optional bearer token; matches the server FERRISLOAD_API_TOKEN. Leave empty when the server has no token.',
      'battery': 'Battery optimization',
      'battery_hint':
          'Disable restrictions to keep long downloads alive in the background',
      'disable_now': 'Disable now',
      'no_candidates': 'No downloadable media candidates were detected yet.',
      'select_candidate': 'Select a media candidate before downloading.',
      'source_page': 'Source page',
      'extractor': 'Extractor',
      'completed': 'Completed',
      'output_path': 'Saved file',
      'analyzing': 'Analyzing source...',
      'ready': 'Candidate ready',
      'inspector': 'Inspector',
      'stream': 'Stream',
      'authorization': 'Authorized request context',
      'authorization_hint':
          'For owned or authorized sites: Cookie, User-Agent, Referer, Origin, and custom headers',
      'cookie_hint': 'name=value; another=value',
      'headers_hint':
          'Authorization: Bearer ...\nX-Requested-With: XMLHttpRequest',
      'core': 'CORE',
      'score': 'Score',
      'segments': 'segments',
      'subtitles': 'Subtitles',
      'subtitle_auto': 'Auto',
      'subtitle_off': 'No subtitles',
      'subtitle_default': 'Default',
      'auth_browser_open': 'Open auth browser',
      'auth_browser_load_failed': 'The page could not be loaded',
      'auth_browser_qr_fallback':
          'If the embedded browser stays blank, use "Sign in with Bilibili" (the QR code) instead — it needs no browser.',
      'auth_browser_title': 'Authorized session browser',
      'auth_browser_hint':
          'Open the target site here, complete login or human verification yourself, then import the current session back into Segmeris.',
      'auth_browser_hint_inline':
          'Use the auth browser when the site requires login, cookie-bound playback, or a human verification page.',
      'auth_browser_address': 'Browser address',
      'auth_browser_go': 'Go',
      'auth_browser_import': 'Import current session',
      'auth_browser_no_session':
          'No reusable cookies or browser session were found on the current page.',
      'auth_session_imported':
          'Authorized session imported. You can analyze or download again with the updated request context.',
      'auth_challenge_detected': 'Access challenge detected',
      'auth_challenge_help':
          'Segmeris can reuse a session you complete yourself, but it will not bypass Cloudflare, CAPTCHA, bans, DRM, signatures, or preview limits.',
      'auth_auto_open': 'Automatically open auth browser on challenge',
      'auth_auto_open_hint':
          'When inspection or downloading hits login, rate-limit, or human-verification challenges, Segmeris opens the authorized session browser automatically.',
      'auth_redirecting':
          'Authorization challenge detected. Opening auth browser...',
      'clear_auth_context': 'Clear imported session',
      'preparing': 'Preparing download...',
      'current_selection': 'Current selection',
      'candidate_switched': 'Selection updated',
      'recovery_started': 'Recovery in progress',
      'status_phase_inspect': 'Inspect',
      'status_phase_acquire': 'Acquire',
      'status_phase_assemble': 'Assemble',
      'status_phase_deliver': 'Deliver',
      'status_stage_idle': 'Standing by',
      'status_stage_inspecting': 'Inspecting source',
      'status_stage_ready': 'Candidate ready',
      'status_stage_auth': 'Authorizing session',
      'status_stage_preparing': 'Preparing transfer',
      'status_stage_backend': 'Selecting backend',
      'status_stage_playlist': 'Resolving playlist',
      'status_stage_transfer': 'Downloading media',
      'status_stage_segments': 'Fetching segments',
      'status_stage_merge': 'Merging streams',
      'status_stage_transcode': 'Transcoding output',
      'status_stage_exporting': 'Exporting file',
      'status_stage_completed': 'Completed',
      'status_stage_failed': 'Needs attention',
      'output_not_created':
          'The download finished but no output file was produced. Check the source URL, request context, or try again.',
      'export_failed':
          'Failed to export the file to the selected location. Temporary output:',
      'download_hint':
          'You can download directly without analyzing: paste an m3u8 or direct media link and start.',
      'retry': 'Retry',
      'retry_analyze': 'Retry analysis',
      'retry_download': 'Retry download',
      'separate_audio': 'Separate audio',
    },
    'zh': {
      'series_kind_parts': '多 P 视频',
      'series_kind_collection': '合集',
      'series_kind_bangumi': '番剧',
      'series_kind_series': '系列',
      'episodes_unit': '集',
      'download_all': '下载全部',
      'download_series_title': '下载整个系列？',
      'download_series_body': '各集将按顺序逐个下载，完成的文件会立即导出。',
      'cancel': '取消',
      'app_title': 'Segmeris',
      'app_subtitle': '分析网页、定位可播放媒体，并下载当前页面暴露出的最佳核心流。',
      'input_source': '资源地址',
      'source_hint': '粘贴网页、m3u8、mp4、YouTube 或 Bilibili 链接',
      'source_invalid': '请粘贴有效的 HTTP 链接或视频分享文案',
      'paste': '粘贴',
      'clear': '清除',
      'file_name': '输出文件',
      'save_location': '保存位置',
      'default_location': '默认输出位置',
      'choose_directory': '选择目录',
      'reset_default': '恢复默认',
      'analyze': '分析资源',
      'qr_login_title': '登录哔哩哔哩',
      'qr_login_hint':
          '用哔哩哔哩客户端扫描二维码，然后在手机上确认。这是 B 站自己的登录方式：会话属于你自己，能下什么由你账号的权益决定。',
      'qr_login_preparing': '正在准备二维码…',
      'qr_login_waiting': '等待扫码…',
      'qr_login_scanned': '已扫码，请在手机上确认',
      'qr_login_expired': '二维码已过期',
      'qr_login_failed': '登录失败',
      'qr_login_retry': '重新生成二维码',
      'download': '下载已选核心流',
      'quality_dialog_title': '选择清晰度',
      'quality_dialog_hint':
          '这些是当前会话能拿到的流。选一个，然后开始下载。',
      'quality_dialog_series_hint':
          '该清晰度适用于全部剧集：每集按此清晰度下载，若某集未提供则取最接近的一档。',
      'auth_browser_open_external':
          '在系统浏览器中打开',
      'auth_browser_copy_link':
          '复制链接',
      'auth_browser_link_copied':
          '链接已复制',
      'qr_login_open_browser':
          '在浏览器中打开',
      'qr_login_browser_hint':
          '只有一台手机？在本机浏览器打开该链接（已登录 B 站），在那里确认即可。',
      'start_download': '开始下载',
      'download_options': '下载参数',
      'concurrency': '并发',
      'retries': '重试',
      'video_bitrate': '视频码率',
      'audio_bitrate': '音频码率',
      'keep_temp': '保留临时文件',
      'keep_temp_hint': '便于诊断与手动封装',
      'analysis_results': '识别到的媒体',
      'status': '状态',
      'active_downloads': '正在下载',
      'running_downloads': '运行中',
      'no_active_downloads': '当前没有正在下载的任务。',
      'history': '历史记录',
      'warnings': '提示',
      'appearance': '外观',
      'runtime_capabilities': '运行时能力',
      'probing_capabilities': '正在检测真实的编解码器与下载引擎...',
      'available': '可用',
      'not_available': '不可用',
      'unknown': '未知',
      'hardware_encoder': '硬件编码器',
      'video_encoders': '列出的视频编码器',
      'video_decoders': '硬件视频解码器',
      'mode': '模式',
      'system': '跟随系统',
      'light': '浅色',
      'dark': '深色',
      'theme': '主题',
      'language': '语言',
      'battery': '电池优化',
      'battery_hint': '关闭限制可减少后台长任务被系统中断的概率',
      'disable_now': '立即关闭',
      'no_candidates': '当前还没有识别到可下载媒体候选。',
      'select_candidate': '下载前请先选择一个媒体候选。',
      'source_page': '来源页面',
      'extractor': '提取器',
      'completed': '已完成',
      'output_path': '保存文件',
      'analyzing': '正在分析资源…',
      'ready': '候选已就绪',
      'inspector': '资源分析',
      'stream': '流',
      'authorization': '授权请求配置',
      'authorization_hint': '用于自有或已授权站点的 Cookie、User-Agent、Referer 与自定义 Header',
      'cookie_hint': 'name=value; another=value',
      'headers_hint':
          'Authorization: Bearer ...\nX-Requested-With: XMLHttpRequest',
      'core': '核心',
      'score': '评分',
      'segments': '分片',
      'subtitles': '字幕',
      'subtitle_auto': '自动',
      'subtitle_off': '不下载字幕',
      'subtitle_default': '默认',
      'auth_browser_open': '打开授权浏览器',
      'auth_browser_load_failed': '网页加载失败',
      'auth_browser_qr_fallback':
          '如果这里的网页一直空白，请改用「登录哔哩哔哩」扫码登录——它不依赖内置浏览器。',
      'auth_browser_title': '授权会话浏览器',
      'auth_browser_hint': '在这里打开目标站点，由你自己完成登录或真人验证，然后把当前会话导回 Segmeris。',
      'auth_browser_hint_inline':
          '当站点要求登录、绑定 Cookie 的播放权限，或出现真人验证页面时，请使用授权浏览器。',
      'auth_browser_address': '浏览器地址',
      'auth_browser_go': '打开',
      'auth_browser_import': '导入当前会话',
      'auth_browser_no_session': '当前页面没有可复用的 Cookie 或浏览器会话。',
      'auth_session_imported': '授权会话已导入，现在可以使用更新后的请求上下文重新分析或下载。',
      'auth_challenge_detected': '检测到访问挑战',
      'auth_challenge_help':
          'Segmeris 可以复用你自己完成验证后的会话，但不会绕过 Cloudflare、验证码、封禁、DRM、签名校验或试看限制。',
      'auth_auto_open': '检测到挑战时自动打开授权浏览器',
      'auth_auto_open_hint':
          '当分析或下载遇到登录、限流、Cloudflare 或真人验证挑战时，Segmeris 会自动跳转到授权浏览器。',
      'auth_redirecting': '检测到授权挑战，正在打开授权浏览器…',
      'clear_auth_context': '清空已导入会话',
      'preparing': '正在准备下载…',
      'current_selection': '当前选择',
      'candidate_switched': '候选已切换',
      'recovery_started': '正在从上一次失败中恢复',
      'status_phase_inspect': '分析',
      'status_phase_acquire': '获取',
      'status_phase_assemble': '组装',
      'status_phase_deliver': '落盘',
      'status_stage_idle': '等待操作',
      'status_stage_inspecting': '正在分析来源',
      'status_stage_ready': '候选已就绪',
      'status_stage_auth': '正在恢复授权会话',
      'status_stage_preparing': '正在准备传输',
      'status_stage_backend': '正在选择后端',
      'status_stage_playlist': '正在解析播放列表',
      'status_stage_transfer': '正在下载媒体',
      'status_stage_segments': '正在抓取分片',
      'status_stage_merge': '正在合并流',
      'status_stage_transcode': '正在转码输出',
      'status_stage_exporting': '正在导出文件',
      'status_stage_completed': '已完成',
      'status_stage_failed': '需要处理',
      'output_not_created': '下载已结束，但没有生成输出文件。请检查资源地址、请求上下文，或重试。',
      'export_failed': '无法将文件导出到所选位置。临时输出：',
      'download_hint': '无需分析即可直接下载：粘贴 m3u8 或直链地址后直接开始。',
      'retry': '重试',
      'retry_analyze': '重新分析',
      'retry_download': '重新下载',
      'separate_audio': '独立音轨',
    },
    'zh_Hant': {
      'series_kind_parts': '多 P 影片',
      'series_kind_collection': '合集',
      'series_kind_bangumi': '番劇',
      'series_kind_series': '系列',
      'episodes_unit': '集',
      'download_all': '下載全部',
      'download_series_title': '下載整個系列？',
      'download_series_body': '各集會依序逐個下載，完成的檔案會立即匯出。',
      'cancel': '取消',
      'app_title': 'Segmeris',
      'app_subtitle': '分析網頁、定位可播放媒體，並下載目前頁面暴露出的最佳核心流。',
      'input_source': '資源位址',
      'source_hint': '貼上網頁、m3u8、mp4、YouTube 或 Bilibili 連結',
      'file_name': '輸出檔案',
      'save_location': '儲存位置',
      'default_location': '預設輸出位置',
      'choose_directory': '選擇目錄',
      'reset_default': '還原預設',
      'analyze': '分析資源',
      'qr_login_title': '登入嗶哩嗶哩',
      'qr_login_hint':
          '用嗶哩嗶哩用戶端掃描 QR Code，然後在手機上確認。這是 B 站自己的登入方式：工作階段屬於你自己，能下載什麼由你帳號的權益決定。',
      'qr_login_preparing': '正在準備 QR Code…',
      'qr_login_waiting': '等待掃描…',
      'qr_login_scanned': '已掃描，請在手機上確認',
      'qr_login_expired': 'QR Code 已過期',
      'qr_login_failed': '登入失敗',
      'qr_login_retry': '重新產生 QR Code',
      'download': '下載已選核心流',
      'quality_dialog_title': '選擇畫質',
      'quality_dialog_hint':
          '這些是目前工作階段能取得的串流。選一個，然後開始下載。',
      'quality_dialog_series_hint':
          '此畫質適用於全部集數：每集依此畫質下載，若某集未提供則取最接近的一檔。',
      'auth_browser_open_external':
          '在系統瀏覽器中開啟',
      'auth_browser_copy_link':
          '複製連結',
      'auth_browser_link_copied':
          '連結已複製',
      'qr_login_open_browser':
          '在瀏覽器中開啟',
      'qr_login_browser_hint':
          '只有一支手機？在本機瀏覽器開啟該連結（已登入 B 站），在那裡確認即可。',
      'start_download': '開始下載',
      'download_options': '下載參數',
      'concurrency': '並發',
      'retries': '重試',
      'video_bitrate': '視訊碼率',
      'audio_bitrate': '音訊碼率',
      'keep_temp': '保留暫存檔',
      'keep_temp_hint': '方便診斷與手動封裝',
      'analysis_results': '識別到的媒體',
      'status': '狀態',
      'history': '歷史紀錄',
      'warnings': '提示',
      'appearance': '外觀',
      'runtime_capabilities': '執行階段能力',
      'probing_capabilities': '正在偵測真實的編解碼器與下載引擎...',
      'available': '可用',
      'not_available': '不可用',
      'unknown': '未知',
      'hardware_encoder': '硬體編碼器',
      'video_encoders': '列出的影片編碼器',
      'video_decoders': '硬體影片解碼器',
      'mode': '模式',
      'system': '跟隨系統',
      'light': '淺色',
      'dark': '深色',
      'theme': '主題',
      'language': '語言',
      'battery': '電池最佳化',
      'battery_hint': '關閉限制可減少背景長任務被系統中斷的機率',
      'disable_now': '立即關閉',
      'no_candidates': '目前尚未偵測到可下載媒體候選。',
      'select_candidate': '下載前請先選擇一個媒體候選。',
      'source_page': '來源頁面',
      'extractor': '擷取器',
      'completed': '已完成',
      'output_path': '儲存檔案',
      'analyzing': '正在分析資源…',
      'ready': '候選已就緒',
      'inspector': '資源分析',
      'stream': '串流',
      'authorization': '授權請求配置',
      'authorization_hint': '用於自有或已授權站點的 Cookie、User-Agent、Referer 與自訂 Header',
      'cookie_hint': 'name=value; another=value',
      'headers_hint':
          'Authorization: Bearer ...\nX-Requested-With: XMLHttpRequest',
      'core': '核心',
      'score': '評分',
      'segments': '分片',
      'subtitles': '字幕',
      'subtitle_auto': '自動',
      'subtitle_off': '不下載字幕',
      'subtitle_default': '預設',
      'auth_browser_open': '開啟授權瀏覽器',
      'auth_browser_load_failed': '網頁載入失敗',
      'auth_browser_qr_fallback':
          '如果這裡的網頁一直空白，請改用「登入嗶哩嗶哩」掃碼登入——它不依賴內建瀏覽器。',
      'auth_browser_title': '授權會話瀏覽器',
      'auth_browser_hint': '在這裡打開目標站點，由你自行完成登入或真人驗證，然後把目前會話導回 Segmeris。',
      'auth_browser_hint_inline':
          '當站點要求登入、綁定 Cookie 的播放權限，或出現真人驗證頁面時，請使用授權瀏覽器。',
      'auth_browser_address': '瀏覽器位址',
      'auth_browser_go': '開啟',
      'auth_browser_import': '匯入目前會話',
      'auth_browser_no_session': '目前頁面沒有可重用的 Cookie 或瀏覽器會話。',
      'auth_session_imported': '授權會話已匯入，現在可以使用更新後的請求上下文重新分析或下載。',
      'auth_challenge_detected': '偵測到存取挑戰',
      'auth_challenge_help':
          'Segmeris 可以重用你自行完成驗證後的會話，但不會繞過 Cloudflare、驗證碼、封禁、DRM、簽名校驗或試看限制。',
      'auth_auto_open': '偵測到挑戰時自動開啟授權瀏覽器',
      'auth_auto_open_hint':
          '當分析或下載遇到登入、限流、Cloudflare 或真人驗證挑戰時，Segmeris 會自動跳轉到授權瀏覽器。',
      'auth_redirecting': '偵測到授權挑戰，正在開啟授權瀏覽器…',
      'clear_auth_context': '清空已匯入會話',
    },
    'ja': {
      'series_kind_parts': 'マルチパート動画',
      'series_kind_collection': 'コレクション',
      'series_kind_bangumi': 'アニメ',
      'series_kind_series': 'シリーズ',
      'episodes_unit': '話',
      'download_all': 'すべてダウンロード',
      'download_series_title': 'シリーズ全体をダウンロードしますか？',
      'download_series_body': '各話を順番にダウンロードし、完了したファイルから順に書き出します。',
      'cancel': 'キャンセル',
      'app_title': 'Segmeris',
      'app_subtitle': 'ページを解析し、再生可能なメディアを見つけて、公開されている最適なストリームをダウンロードします。',
      'input_source': 'ソース URL',
      'source_hint': 'Web ページ、m3u8、mp4、YouTube、Bilibili のリンクを貼り付けます',
      'file_name': '出力ファイル',
      'save_location': '保存先',
      'default_location': '既定の保存先',
      'choose_directory': 'フォルダーを選択',
      'reset_default': '既定に戻す',
      'analyze': 'ソースを解析',
      'qr_login_title': 'Bilibili にログイン',
      'qr_login_hint':
          'Bilibili アプリで QR コードを読み取り、スマートフォンで確認してください。公式のログイン方法なので、セッションはあなた自身のもので、ダウンロードできる範囲はアカウントの権利で決まります。',
      'qr_login_preparing': 'QR コードを準備しています…',
      'qr_login_waiting': '読み取りを待っています…',
      'qr_login_scanned': '読み取り済み — スマートフォンで確認してください',
      'qr_login_expired': 'QR コードの有効期限が切れました',
      'qr_login_failed': 'ログインに失敗しました',
      'qr_login_retry': 'QR コードを再生成',
      'download': '選択したストリームをダウンロード',
      'quality_dialog_title': '画質を選択',
      'quality_dialog_hint':
          'このセッションで取得できるストリームです。選んでからダウンロードを開始してください。',
      'quality_dialog_series_hint':
          'この画質は全エピソードに適用されます。提供されていない話は最も近い画質で保存します。',
      'auth_browser_open_external':
          'システムブラウザで開く',
      'auth_browser_copy_link':
          'リンクをコピー',
      'auth_browser_link_copied':
          'リンクをコピーしました',
      'qr_login_open_browser':
          'ブラウザで開く',
      'qr_login_browser_hint':
          'スマホが1台だけのときは、この端末のブラウザ（Bilibili にログイン済み）でリンクを開き、そこで確認してください。',
      'start_download': 'ダウンロード開始',
      'download_options': 'ダウンロード設定',
      'concurrency': '並列数',
      'retries': '再試行',
      'video_bitrate': '映像ビットレート',
      'audio_bitrate': '音声ビットレート',
      'keep_temp': '一時ファイルを保持',
      'keep_temp_hint': '診断や手動マージに便利',
      'analysis_results': '検出されたメディア',
      'status': '状態',
      'history': '履歴',
      'warnings': '警告',
      'appearance': '外観',
      'mode': 'モード',
      'system': 'システム',
      'light': 'ライト',
      'dark': 'ダーク',
      'theme': 'テーマ',
      'language': '言語',
      'battery': 'バッテリー最適化',
      'battery_hint': '制限を解除すると長時間のバックグラウンド処理が止まりにくくなります',
      'disable_now': '今すぐ無効化',
      'no_candidates': 'まだダウンロード可能な候補は見つかっていません。',
      'select_candidate': 'ダウンロードする前に候補を選択してください。',
      'source_page': 'ソースページ',
      'extractor': '抽出器',
      'completed': '完了',
      'output_path': '保存済みファイル',
      'analyzing': '解析中…',
      'ready': '候補の準備ができました',
      'inspector': 'インスペクター',
      'stream': 'ストリーム',
      'authorization': '認証済みリクエスト設定',
      'authorization_hint':
          '自分が所有または利用権限を持つサイト向けの Cookie、User-Agent、Referer、Origin、カスタムヘッダー',
      'cookie_hint': 'name=value; another=value',
      'headers_hint':
          'Authorization: Bearer ...\nX-Requested-With: XMLHttpRequest',
      'core': '主要',
      'score': '評価',
      'segments': 'セグメント',
      'auth_browser_open': '認証ブラウザーを開く',
      'auth_browser_load_failed': 'ページを読み込めませんでした',
      'auth_browser_qr_fallback':
          '埋め込みブラウザーが真っ白なままなら、「Bilibili にログイン」（QR コード）を使ってください。ブラウザー不要です。',
      'auth_browser_title': '認証済みセッションブラウザー',
      'auth_browser_hint':
          'ここで対象サイトを開き、自分でログインや本人確認を完了したあと、現在のセッションを Segmeris に取り込みます。',
      'auth_browser_hint_inline':
          'サイト側でログイン、Cookie による再生権限、または人による確認が必要な場合は、認証ブラウザーを使ってください。',
      'auth_browser_address': 'ブラウザーのアドレス',
      'auth_browser_go': '開く',
      'auth_browser_import': '現在のセッションを取り込む',
      'auth_browser_no_session':
          '現在のページには再利用できる Cookie またはブラウザーセッションが見つかりませんでした。',
      'auth_session_imported':
          '認証済みセッションを取り込みました。更新されたリクエスト設定で、もう一度解析またはダウンロードできます。',
      'auth_challenge_detected': 'アクセス制限を検出しました',
      'auth_challenge_help':
          'Segmeris は、自分で認証を完了したあとのセッションを再利用できますが、Cloudflare、CAPTCHA、アクセス制限、DRM、署名検証、試聴制限を回避することはありません。',
      'auth_auto_open': '制限検出時に認証ブラウザーを自動で開く',
      'auth_auto_open_hint':
          '解析やダウンロードでログイン、レート制限、Cloudflare、人による確認が求められた場合、Segmeris が認証ブラウザーを自動で開きます。',
      'auth_redirecting': '認証が必要な状態を検出しました。認証ブラウザーを開いています…',
      'clear_auth_context': '取り込んだセッションを消去',
      'preparing': 'ダウンロードを準備しています…',
      'output_not_created':
          'ダウンロードは終了しましたが、出力ファイルは作成されませんでした。ソース URL やリクエスト設定を確認してから、もう一度お試しください。',
      'export_failed': '選択した保存先へ書き出せませんでした。一時出力:',
      'download_hint': '解析しなくても直接ダウンロードできます。m3u8 や直接のメディア URL を貼り付けて開始してください。',
    },
    'ar': {
      'series_kind_parts': 'فيديو متعدد الأجزاء',
      'series_kind_collection': 'مجموعة',
      'series_kind_bangumi': 'أنمي',
      'series_kind_series': 'سلسلة',
      'episodes_unit': 'حلقة',
      'download_all': 'تنزيل الكل',
      'download_series_title': 'تنزيل السلسلة كاملة؟',
      'download_series_body':
          'يتم تنزيل الحلقات واحدة تلو الأخرى، ويُصدَّر كل ملف فور اكتماله.',
      'cancel': 'إلغاء',
      'app_title': 'Segmeris',
      'app_subtitle':
          'حلّل الصفحة، واعثر على الوسائط القابلة للتشغيل، ثم نزّل أفضل تدفّق مكشوف فيها.',
      'input_source': 'رابط المصدر',
      'source_hint': 'ألصق رابط صفحة أو m3u8 أو mp4 أو YouTube أو Bilibili',
      'file_name': 'ملف الإخراج',
      'save_location': 'مكان الحفظ',
      'default_location': 'الموقع الافتراضي للحفظ',
      'choose_directory': 'اختر المجلد',
      'reset_default': 'استخدم الافتراضي',
      'analyze': 'حلّل المصدر',
      'qr_login_title': 'تسجيل الدخول إلى Bilibili',
      'qr_login_hint':
          'امسح الرمز بتطبيق Bilibili ثم أكّد على هاتفك. هذا تسجيل الدخول الرسمي من Bilibili، لذا تبقى الجلسة لك وحدود التنزيل يحدّدها حسابك.',
      'qr_login_preparing': 'جارٍ تحضير رمز QR…',
      'qr_login_waiting': 'في انتظار المسح…',
      'qr_login_scanned': 'تم المسح — أكّد على هاتفك',
      'qr_login_expired': 'انتهت صلاحية رمز QR',
      'qr_login_failed': 'فشل تسجيل الدخول',
      'qr_login_retry': 'رمز QR جديد',
      'download': 'نزّل التدفّق المحدد',
      'quality_dialog_title': 'اختر الجودة',
      'quality_dialog_hint':
          'هذه هي التدفّقات المتاحة لهذه الجلسة. اختر واحدًا ثم ابدأ التنزيل.',
      'quality_dialog_series_hint':
          'تُطبَّق هذه الجودة على كل الحلقات: تُنزَّل كل حلقة بهذه الجودة أو بأقرب جودة متاحة.',
      'auth_browser_open_external':
          'الفتح في متصفح النظام',
      'auth_browser_copy_link':
          'نسخ الرابط',
      'auth_browser_link_copied':
          'تم نسخ الرابط',
      'qr_login_open_browser':
          'الفتح في المتصفح',
      'qr_login_browser_hint':
          'لديك هاتف واحد فقط؟ افتح الرابط في متصفح هذا الهاتف مع تسجيل الدخول إلى Bilibili وأكّد من هناك.',
      'start_download': 'ابدأ التنزيل',
      'download_options': 'خيارات التنزيل',
      'concurrency': 'التوازي',
      'retries': 'إعادة المحاولة',
      'video_bitrate': 'معدل بت الفيديو',
      'audio_bitrate': 'معدل بت الصوت',
      'keep_temp': 'الاحتفاظ بالملفات المؤقتة',
      'keep_temp_hint': 'يفيد في التشخيص والدمج اليدوي',
      'analysis_results': 'الوسائط المكتشفة',
      'status': 'الحالة',
      'history': 'السجل',
      'warnings': 'تحذيرات',
      'appearance': 'المظهر',
      'mode': 'الوضع',
      'system': 'النظام',
      'light': 'فاتح',
      'dark': 'داكن',
      'theme': 'السمة',
      'language': 'اللغة',
      'battery': 'تحسين البطارية',
      'battery_hint':
          'تعطيل القيود يساعد على استمرار التنزيلات الطويلة في الخلفية',
      'disable_now': 'عطّل الآن',
      'no_candidates': 'لم يتم العثور على وسائط قابلة للتنزيل بعد.',
      'select_candidate': 'اختر وسيطًا مرشحًا قبل التنزيل.',
      'source_page': 'صفحة المصدر',
      'extractor': 'أداة الاستخراج',
      'completed': 'اكتمل',
      'output_path': 'الملف المحفوظ',
      'analyzing': 'جارٍ تحليل المصدر…',
      'ready': 'أصبح المرشح جاهزًا',
      'inspector': 'الفاحص',
      'stream': 'التدفّق',
      'authorization': 'إعدادات الطلب المصرّح بها',
      'authorization_hint':
          'للمواقع التي تملك حق الوصول إليها أو تستخدمها بإذن: Cookie وUser-Agent وReferer وOrigin والرؤوس المخصصة',
      'cookie_hint': 'name=value; another=value',
      'headers_hint':
          'Authorization: Bearer ...\nX-Requested-With: XMLHttpRequest',
      'core': 'أساسي',
      'score': 'التقييم',
      'segments': 'مقاطع',
      'auth_browser_open': 'افتح متصفح التفويض',
      'auth_browser_load_failed': 'تعذّر تحميل الصفحة',
      'auth_browser_qr_fallback':
          'إذا بقي المتصفح المدمج فارغًا، استخدم «تسجيل الدخول إلى Bilibili» عبر رمز QR — فهو لا يحتاج متصفحًا.',
      'auth_browser_title': 'متصفح الجلسة المصرّح بها',
      'auth_browser_hint':
          'افتح الموقع المستهدف هنا، وأكمل تسجيل الدخول أو التحقق البشري بنفسك، ثم استورد الجلسة الحالية مرة أخرى إلى Segmeris.',
      'auth_browser_hint_inline':
          'استخدم متصفح التفويض عندما يتطلب الموقع تسجيل الدخول، أو صلاحية تشغيل مرتبطة بملفات تعريف الارتباط، أو صفحة تحقق بشري.',
      'auth_browser_address': 'عنوان المتصفح',
      'auth_browser_go': 'انتقل',
      'auth_browser_import': 'استورد الجلسة الحالية',
      'auth_browser_no_session':
          'لم يتم العثور على ملفات تعريف ارتباط قابلة لإعادة الاستخدام أو جلسة متصفح قابلة للاستيراد في الصفحة الحالية.',
      'auth_session_imported':
          'تم استيراد الجلسة المصرّح بها. يمكنك الآن إعادة التحليل أو التنزيل باستخدام سياق الطلب المحدّث.',
      'auth_challenge_detected': 'تم اكتشاف تحدي وصول',
      'auth_challenge_help':
          'يمكن لـ Segmeris إعادة استخدام جلسة أكملتها بنفسك، لكنه لا يتجاوز Cloudflare أو CAPTCHA أو الحظر أو DRM أو التواقيع أو قيود المعاينة.',
      'auth_auto_open': 'افتح متصفح التفويض تلقائيًا عند اكتشاف تحدٍ',
      'auth_auto_open_hint':
          'عندما يواجه التحليل أو التنزيل تسجيل دخول أو تقييد معدل أو Cloudflare أو تحققًا بشريًا، يفتح Segmeris متصفح التفويض تلقائيًا.',
      'auth_redirecting':
          'تم اكتشاف حاجة إلى جلسة مصرح بها. جارٍ فتح متصفح التفويض…',
      'clear_auth_context': 'امسح الجلسة المستوردة',
      'preparing': 'جارٍ تجهيز التنزيل…',
      'output_not_created':
          'انتهى التنزيل، لكن لم يتم إنشاء ملف الإخراج. تحقّق من رابط المصدر أو سياق الطلب أو أعد المحاولة.',
      'export_failed': 'تعذّر تصدير الملف إلى الموقع المحدد. المخرج المؤقت:',
      'download_hint':
          'يمكنك التنزيل مباشرة من دون تحليل: ألصق رابط m3u8 أو رابط الوسائط المباشر ثم ابدأ.',
    },
    'fa': {
      'series_kind_parts': 'ویدیوی چند بخشی',
      'series_kind_collection': 'مجموعه',
      'series_kind_bangumi': 'انیمه',
      'series_kind_series': 'سری',
      'episodes_unit': 'قسمت',
      'download_all': 'دانلود همه',
      'download_series_title': 'کل سری دانلود شود؟',
      'download_series_body':
          'قسمت‌ها به ترتیب دانلود می‌شوند و هر فایل کامل‌شده فوراً ذخیره می‌شود.',
      'cancel': 'لغو',
      'app_title': 'Segmeris',
      'app_subtitle':
          'صفحه را بررسی کنید، رسانه قابل پخش را پیدا کنید و بهترین جریان در دسترس را دانلود کنید.',
      'input_source': 'نشانی منبع',
      'source_hint':
          'پیوند صفحه وب، m3u8، mp4، YouTube یا Bilibili را وارد کنید',
      'file_name': 'نام فایل خروجی',
      'save_location': 'محل ذخیره',
      'default_location': 'محل پیش‌فرض ذخیره',
      'choose_directory': 'انتخاب پوشه',
      'reset_default': 'استفاده از پیش‌فرض',
      'analyze': 'تحلیل منبع',
      'qr_login_title': 'ورود به Bilibili',
      'qr_login_hint':
          'کد را با برنامه Bilibili اسکن کنید و روی گوشی تأیید کنید. این ورود رسمی خود Bilibili است؛ نشست متعلق به شماست و دسترسی‌ها را حساب شما تعیین می‌کند.',
      'qr_login_preparing': 'در حال آماده‌سازی کد QR…',
      'qr_login_waiting': 'در انتظار اسکن…',
      'qr_login_scanned': 'اسکن شد — روی گوشی تأیید کنید',
      'qr_login_expired': 'کد QR منقضی شد',
      'qr_login_failed': 'ورود ناموفق بود',
      'qr_login_retry': 'کد QR جدید',
      'download': 'دانلود جریان انتخاب‌شده',
      'quality_dialog_title': 'انتخاب کیفیت',
      'quality_dialog_hint':
          'این‌ها جریان‌های قابل‌دسترسی در این نشست هستند. یکی را انتخاب و دانلود را آغاز کنید.',
      'quality_dialog_series_hint':
          'این کیفیت برای همه قسمت‌ها اعمال می‌شود؛ هر قسمت با همین کیفیت یا نزدیک‌ترین کیفیت موجود ذخیره می‌شود.',
      'auth_browser_open_external':
          'باز کردن در مرورگر سیستم',
      'auth_browser_copy_link':
          'کپی پیوند',
      'auth_browser_link_copied':
          'پیوند کپی شد',
      'qr_login_open_browser':
          'باز کردن در مرورگر',
      'qr_login_browser_hint':
          'فقط یک گوشی دارید؟ پیوند را در مرورگر همین گوشی با ورود به Bilibili باز کنید و همان‌جا تأیید کنید.',
      'start_download': 'شروع دانلود',
      'download_options': 'تنظیمات دانلود',
      'concurrency': 'همزمانی',
      'retries': 'تلاش مجدد',
      'video_bitrate': 'بیت‌ریت ویدیو',
      'audio_bitrate': 'بیت‌ریت صدا',
      'keep_temp': 'نگه‌داشتن فایل‌های موقت',
      'keep_temp_hint': 'برای عیب‌یابی و ترکیب دستی مفید است',
      'analysis_results': 'رسانه‌های شناسایی‌شده',
      'status': 'وضعیت',
      'history': 'تاریخچه',
      'warnings': 'هشدارها',
      'appearance': 'ظاهر',
      'mode': 'حالت',
      'system': 'سیستم',
      'light': 'روشن',
      'dark': 'تیره',
      'theme': 'پوسته',
      'language': 'زبان',
      'battery': 'بهینه‌سازی باتری',
      'battery_hint':
          'غیرفعال کردن محدودیت‌ها کمک می‌کند دانلودهای طولانی در پس‌زمینه قطع نشوند',
      'disable_now': 'اکنون غیرفعال کن',
      'no_candidates': 'هنوز رسانه‌ای برای دانلود شناسایی نشده است.',
      'select_candidate': 'پیش از دانلود، یک گزینه رسانه را انتخاب کنید.',
      'source_page': 'صفحه منبع',
      'extractor': 'استخراج‌کننده',
      'completed': 'تکمیل شد',
      'output_path': 'فایل ذخیره‌شده',
      'analyzing': 'در حال تحلیل منبع…',
      'ready': 'گزینه آماده است',
      'inspector': 'بررسی‌گر',
      'stream': 'جریان',
      'authorization': 'تنظیمات درخواست مجاز',
      'authorization_hint':
          'برای سایت‌هایی که مالک آن هستید یا مجوز استفاده از آن‌ها را دارید: Cookie، User-Agent، Referer، Origin و سرصفحه‌های سفارشی',
      'cookie_hint': 'name=value; another=value',
      'headers_hint':
          'Authorization: Bearer ...\nX-Requested-With: XMLHttpRequest',
      'core': 'اصلی',
      'score': 'امتیاز',
      'segments': 'بخش',
      'auth_browser_open': 'باز کردن مرورگر احراز هویت',
      'auth_browser_load_failed': 'بارگذاری صفحه ناموفق بود',
      'auth_browser_qr_fallback':
          'اگر مرورگر داخلی خالی ماند، از «ورود به Bilibili» با کد QR استفاده کنید؛ به مرورگر نیازی ندارد.',
      'auth_browser_title': 'مرورگر نشست مجاز',
      'auth_browser_hint':
          'سایت هدف را اینجا باز کنید، ورود یا تأیید انسانی را خودتان انجام دهید، سپس نشست فعلی را دوباره به Segmeris وارد کنید.',
      'auth_browser_hint_inline':
          'وقتی سایت به ورود، مجوز پخش وابسته به Cookie یا صفحه تأیید انسانی نیاز دارد، از مرورگر احراز هویت استفاده کنید.',
      'auth_browser_address': 'نشانی مرورگر',
      'auth_browser_go': 'برو',
      'auth_browser_import': 'وارد کردن نشست فعلی',
      'auth_browser_no_session':
          'در صفحه فعلی هیچ Cookie قابل استفاده مجدد یا نشست مرورگر قابل واردکردنی پیدا نشد.',
      'auth_session_imported':
          'نشست مجاز وارد شد. اکنون می‌توانید با زمینه درخواست به‌روزشده دوباره تحلیل یا دانلود کنید.',
      'auth_challenge_detected': 'چالش دسترسی شناسایی شد',
      'auth_challenge_help':
          'Segmeris می‌تواند از نشستی که خودتان تکمیل کرده‌اید دوباره استفاده کند، اما Cloudflare، CAPTCHA، مسدودسازی، DRM، امضاها یا محدودیت پیش‌نمایش را دور نمی‌زند.',
      'auth_auto_open':
          'در صورت تشخیص چالش، مرورگر احراز هویت را خودکار باز کن',
      'auth_auto_open_hint':
          'اگر هنگام تحلیل یا دانلود با ورود، محدودیت نرخ، Cloudflare یا تأیید انسانی روبه‌رو شوید، Segmeris مرورگر احراز هویت را خودکار باز می‌کند.',
      'auth_redirecting':
          'نیاز به نشست مجاز تشخیص داده شد. در حال باز کردن مرورگر احراز هویت…',
      'clear_auth_context': 'پاک کردن نشست واردشده',
      'preparing': 'در حال آماده‌سازی دانلود…',
      'output_not_created':
          'دانلود تمام شد، اما فایل خروجی ساخته نشد. نشانی منبع، زمینه درخواست یا تلاش دوباره را بررسی کنید.',
      'export_failed': 'صدور فایل به محل انتخاب‌شده انجام نشد. خروجی موقت:',
      'download_hint':
          'می‌توانید بدون تحلیل هم مستقیم دانلود کنید: یک پیوند m3u8 یا پیوند مستقیم رسانه را وارد کنید و شروع کنید.',
    },
    'ur': {
      'series_kind_parts': 'کثیر الاجزا ویڈیو',
      'series_kind_collection': 'مجموعہ',
      'series_kind_bangumi': 'انیمی',
      'series_kind_series': 'سیریز',
      'episodes_unit': 'اقساط',
      'download_all': 'سب ڈاؤن لوڈ کریں',
      'download_series_title': 'پوری سیریز ڈاؤن لوڈ کریں؟',
      'download_series_body':
          'اقساط ترتیب سے ڈاؤن لوڈ ہوں گی اور مکمل ہوتے ہی ہر فائل برآمد ہوگی۔',
      'cancel': 'منسوخ کریں',
      'app_title': 'Segmeris',
      'app_subtitle':
          'صفحہ دیکھیں، چلنے کے قابل میڈیا تلاش کریں، اور دستیاب بہترین اسٹریم ڈاؤن لوڈ کریں۔',
      'input_source': 'ماخذ URL',
      'source_hint':
          'ویب صفحہ، m3u8، mp4، YouTube یا Bilibili کا لنک چسپاں کریں',
      'file_name': 'آؤٹ پٹ فائل',
      'save_location': 'محفوظ کرنے کی جگہ',
      'default_location': 'پہلے سے طے شدہ محفوظ کرنے کی جگہ',
      'choose_directory': 'فولڈر منتخب کریں',
      'reset_default': 'ڈیفالٹ استعمال کریں',
      'analyze': 'ماخذ کا تجزیہ کریں',
      'qr_login_title': 'Bilibili میں سائن اِن کریں',
      'qr_login_hint':
          'Bilibili ایپ سے کوڈ اسکین کریں پھر فون پر تصدیق کریں۔ یہ Bilibili کی اپنی لاگ اِن ہے؛ سیشن آپ کا ہے اور دسترس آپ کے اکاؤنٹ سے طے ہوتی ہے۔',
      'qr_login_preparing': 'QR کوڈ تیار ہو رہا ہے…',
      'qr_login_waiting': 'اسکین کا انتظار…',
      'qr_login_scanned': 'اسکین ہو گیا — فون پر تصدیق کریں',
      'qr_login_expired': 'QR کوڈ کی مدت ختم',
      'qr_login_failed': 'سائن اِن ناکام',
      'qr_login_retry': 'نیا QR کوڈ',
      'download': 'منتخب اسٹریم ڈاؤن لوڈ کریں',
      'quality_dialog_title': 'معیار منتخب کریں',
      'quality_dialog_hint':
          'یہ اس سیشن میں دستیاب اسٹریمز ہیں۔ ایک منتخب کریں پھر ڈاؤن لوڈ شروع کریں۔',
      'quality_dialog_series_hint':
          'یہ کوالٹی ہر قسط پر لاگو ہوتی ہے؛ جو قسط اس میں دستیاب نہ ہو وہ قریب ترین کوالٹی میں محفوظ ہو گی۔',
      'auth_browser_open_external':
          'سسٹم براؤزر میں کھولیں',
      'auth_browser_copy_link':
          'لنک کاپی کریں',
      'auth_browser_link_copied':
          'لنک کاپی ہو گیا',
      'qr_login_open_browser':
          'براؤزر میں کھولیں',
      'qr_login_browser_hint':
          'صرف ایک فون ہے؟ لنک اسی فون کے براؤزر میں Bilibili پر لاگ اِن کر کے کھولیں اور وہیں تصدیق کریں۔',
      'start_download': 'ڈاؤن لوڈ شروع کریں',
      'download_options': 'ڈاؤن لوڈ کی ترتیبات',
      'concurrency': 'ہم وقت تعداد',
      'retries': 'دوبارہ کوششیں',
      'video_bitrate': 'ویڈیو بٹ ریٹ',
      'audio_bitrate': 'آڈیو بٹ ریٹ',
      'keep_temp': 'عارضی فائلیں محفوظ رکھیں',
      'keep_temp_hint': 'تشخیص اور دستی مرج کے لیے مفید',
      'analysis_results': 'شناخت شدہ میڈیا',
      'status': 'حالت',
      'history': 'تاریخچہ',
      'warnings': 'انتباہات',
      'appearance': 'ظاہری شکل',
      'mode': 'موڈ',
      'system': 'سسٹم',
      'light': 'روشن',
      'dark': 'تاریک',
      'theme': 'تھیم',
      'language': 'زبان',
      'battery': 'بیٹری کی بہتری',
      'battery_hint':
          'پابندیاں بند کرنے سے لمبے بیک گراؤنڈ ڈاؤن لوڈز کے رکنے کا امکان کم ہوتا ہے',
      'disable_now': 'ابھی بند کریں',
      'no_candidates': 'ابھی تک ڈاؤن لوڈ کے قابل کوئی میڈیا نہیں ملا۔',
      'select_candidate': 'ڈاؤن لوڈ سے پہلے ایک میڈیا امیدوار منتخب کریں۔',
      'source_page': 'ماخذ صفحہ',
      'extractor': 'ایکسٹریکٹر',
      'completed': 'مکمل',
      'output_path': 'محفوظ شدہ فائل',
      'analyzing': 'ماخذ کا تجزیہ ہو رہا ہے…',
      'ready': 'امیدوار تیار ہے',
      'inspector': 'انسپکٹر',
      'stream': 'اسٹریم',
      'authorization': 'مجاز درخواست کی ترتیبات',
      'authorization_hint':
          'ان سائٹس کے لیے جن کی آپ کو ملکیت یا اجازت حاصل ہے: Cookie، User-Agent، Referer، Origin اور حسب ضرورت ہیڈر',
      'cookie_hint': 'name=value; another=value',
      'headers_hint':
          'Authorization: Bearer ...\nX-Requested-With: XMLHttpRequest',
      'core': 'بنیادی',
      'score': 'اسکور',
      'segments': 'حصے',
      'auth_browser_open': 'تصدیقی براؤزر کھولیں',
      'auth_browser_load_failed': 'صفحہ لوڈ نہیں ہو سکا',
      'auth_browser_qr_fallback':
          'اگر اندرونی براؤزر خالی رہے تو «Bilibili میں سائن اِن کریں» (QR کوڈ) استعمال کریں — اسے براؤزر کی ضرورت نہیں۔',
      'auth_browser_title': 'مجاز سیشن براؤزر',
      'auth_browser_hint':
          'ہدف سائٹ یہاں کھولیں، لاگ اِن یا انسانی تصدیق خود مکمل کریں، پھر موجودہ سیشن واپس Segmeris میں درآمد کریں۔',
      'auth_browser_hint_inline':
          'جب سائٹ کو لاگ اِن، Cookie سے منسلک پلے بیک اجازت، یا انسانی تصدیق درکار ہو تو تصدیقی براؤزر استعمال کریں۔',
      'auth_browser_address': 'براؤزر کا پتہ',
      'auth_browser_go': 'کھولیں',
      'auth_browser_import': 'موجودہ سیشن درآمد کریں',
      'auth_browser_no_session':
          'موجودہ صفحے پر دوبارہ استعمال ہونے والی Cookie یا درآمد کے قابل براؤزر سیشن نہیں ملا۔',
      'auth_session_imported':
          'مجاز سیشن درآمد ہو گیا۔ اب آپ تازہ درخواست سیاق کے ساتھ دوبارہ تجزیہ یا ڈاؤن لوڈ کر سکتے ہیں۔',
      'auth_challenge_detected': 'رسائی کا چیلنج معلوم ہوا',
      'auth_challenge_help':
          'Segmeris اس سیشن کو دوبارہ استعمال کر سکتا ہے جسے آپ نے خود مکمل کیا ہو، لیکن یہ Cloudflare، CAPTCHA، پابندی، DRM، دستخط یا پیش نظارہ کی حد کو نظرانداز نہیں کرتا۔',
      'auth_auto_open': 'چیلنج ملنے پر تصدیقی براؤزر خودکار کھولیں',
      'auth_auto_open_hint':
          'اگر تجزیہ یا ڈاؤن لوڈ کے دوران لاگ اِن، ریٹ لمٹ، Cloudflare یا انسانی تصدیق سامنے آئے تو Segmeris تصدیقی براؤزر خودکار کھول دے گا۔',
      'auth_redirecting': 'مجاز سیشن درکار ہے۔ تصدیقی براؤزر کھولا جا رہا ہے…',
      'clear_auth_context': 'درآمد شدہ سیشن صاف کریں',
      'preparing': 'ڈاؤن لوڈ کی تیاری ہو رہی ہے…',
      'output_not_created':
          'ڈاؤن لوڈ مکمل ہوا، لیکن آؤٹ پٹ فائل نہیں بنی۔ ماخذ URL، درخواست سیاق یا دوبارہ کوشش چیک کریں۔',
      'export_failed': 'فائل منتخب مقام پر ایکسپورٹ نہ ہو سکی۔ عارضی آؤٹ پٹ:',
      'download_hint':
          'آپ تجزیہ کے بغیر بھی براہ راست ڈاؤن لوڈ کر سکتے ہیں: m3u8 یا براہ راست میڈیا لنک چسپاں کریں اور شروع کریں۔',
    },
    'es': {
      'series_kind_parts': 'Video de varias partes',
      'series_kind_collection': 'Colección',
      'series_kind_bangumi': 'Anime',
      'series_kind_series': 'Serie',
      'episodes_unit': 'episodios',
      'download_all': 'Descargar todo',
      'download_series_title': '¿Descargar la serie completa?',
      'download_series_body':
          'Los episodios se descargan en orden, uno tras otro; cada archivo terminado se exporta inmediatamente.',
      'cancel': 'Cancelar',
      'app_title': 'Segmeris',
      'app_subtitle':
          'Analiza páginas, encuentra medios reproducibles y descarga el mejor flujo expuesto.',
      'input_source': 'URL de origen',
      'source_hint': 'Pega una página web, m3u8, mp4, YouTube o Bilibili',
      'file_name': 'Archivo de salida',
      'save_location': 'Ubicación de guardado',
      'default_location': 'Ubicación predeterminada',
      'choose_directory': 'Elegir carpeta',
      'reset_default': 'Usar predeterminado',
      'analyze': 'Analizar',
      'auth_browser_load_failed': 'No se pudo cargar la página',
      'auth_browser_qr_fallback':
          'Si el navegador integrado se queda en blanco, usa «Iniciar sesión en Bilibili» (el código QR): no necesita navegador.',
      'qr_login_title': 'Iniciar sesión en Bilibili',
      'qr_login_hint':
          'Escanea el código con la app de Bilibili y confirma en el teléfono. Es el inicio de sesión oficial de Bilibili: la sesión es tuya y tus permisos deciden qué se puede descargar.',
      'qr_login_preparing': 'Preparando el código QR...',
      'qr_login_waiting': 'Esperando el escaneo...',
      'qr_login_scanned': 'Escaneado: confirma en tu teléfono',
      'qr_login_expired': 'El código QR caducó',
      'qr_login_failed': 'No se pudo iniciar sesión',
      'qr_login_retry': 'Nuevo código QR',
      'download': 'Descargar flujo seleccionado',
      'quality_dialog_title': 'Elegir la calidad',
      'quality_dialog_hint':
          'Estos son los flujos accesibles en esta sesión. Elige uno y empieza la descarga.',
      'quality_dialog_series_hint':
          'Se aplica a todos los episodios: cada uno se descarga en esta calidad o en la más cercana disponible.',
      'auth_browser_open_external':
          'Abrir en el navegador del sistema',
      'auth_browser_copy_link':
          'Copiar enlace',
      'auth_browser_link_copied':
          'Enlace copiado',
      'qr_login_open_browser':
          'Abrir en el navegador',
      'qr_login_browser_hint':
          '¿Solo tienes un teléfono? Abre el enlace en el navegador de este teléfono con la sesión de Bilibili iniciada y confirma allí.',
      'start_download': 'Iniciar descarga',
      'download_options': 'Opciones de descarga',
      'concurrency': 'Concurrencia',
      'retries': 'Reintentos',
      'video_bitrate': 'Bitrate de video',
      'audio_bitrate': 'Bitrate de audio',
      'keep_temp': 'Conservar temporales',
      'keep_temp_hint': 'Útil para diagnóstico y remux manual',
      'analysis_results': 'Medios detectados',
      'status': 'Estado',
      'history': 'Historial',
      'warnings': 'Advertencias',
      'appearance': 'Apariencia',
      'mode': 'Modo',
      'system': 'Sistema',
      'light': 'Claro',
      'dark': 'Oscuro',
      'theme': 'Tema',
      'language': 'Idioma',
      'battery': 'Optimización de batería',
      'battery_hint':
          'Desactivar restricciones ayuda a mantener descargas largas en segundo plano',
      'disable_now': 'Desactivar ahora',
      'no_candidates': 'Aún no se detectaron medios descargables.',
      'select_candidate': 'Selecciona un candidato antes de descargar.',
      'source_page': 'Página fuente',
      'extractor': 'Extractor',
      'completed': 'Completado',
      'output_path': 'Archivo guardado',
      'analyzing': 'Analizando...',
      'ready': 'Candidato listo',
      'inspector': 'Inspector',
      'stream': 'Flujo',
    },
    'ru': {
      'series_kind_parts': 'Многочастное видео',
      'series_kind_collection': 'Коллекция',
      'series_kind_bangumi': 'Аниме',
      'series_kind_series': 'Серия',
      'episodes_unit': 'эп.',
      'download_all': 'Скачать всё',
      'download_series_title': 'Скачать всю серию?',
      'download_series_body':
          'Эпизоды скачиваются по порядку; каждый готовый файл сразу экспортируется.',
      'cancel': 'Отмена',
      'app_title': 'Segmeris',
      'app_subtitle':
          'Анализируйте страницу, находите воспроизводимое медиа и сохраняйте лучший открытый поток.',
      'input_source': 'URL источника',
      'source_hint':
          'Вставьте ссылку на страницу, m3u8, mp4, YouTube или Bilibili',
      'file_name': 'Выходной файл',
      'save_location': 'Папка сохранения',
      'default_location': 'Папка по умолчанию',
      'choose_directory': 'Выбрать папку',
      'reset_default': 'По умолчанию',
      'analyze': 'Анализировать',
      'auth_browser_load_failed': 'Не удалось загрузить страницу',
      'auth_browser_qr_fallback':
          'Если встроенный браузер остаётся пустым, используйте «Вход в Bilibili» по QR-коду — браузер не нужен.',
      'qr_login_title': 'Вход в Bilibili',
      'qr_login_hint':
          'Отсканируйте код в приложении Bilibili и подтвердите на телефоне. Это официальный вход Bilibili: сессия принадлежит вам, а доступ определяет ваш аккаунт.',
      'qr_login_preparing': 'Подготовка QR-кода…',
      'qr_login_waiting': 'Ожидание сканирования…',
      'qr_login_scanned': 'Отсканировано — подтвердите на телефоне',
      'qr_login_expired': 'Срок действия QR-кода истёк',
      'qr_login_failed': 'Не удалось войти',
      'qr_login_retry': 'Новый QR-код',
      'download': 'Скачать выбранный поток',
      'quality_dialog_title': 'Выбор качества',
      'quality_dialog_hint':
          'Это потоки, доступные в текущей сессии. Выберите один и начните загрузку.',
      'quality_dialog_series_hint':
          'Это качество применяется ко всем сериям: каждая скачивается в нём или в ближайшем доступном.',
      'auth_browser_open_external':
          'Открыть в системном браузере',
      'auth_browser_copy_link':
          'Скопировать ссылку',
      'auth_browser_link_copied':
          'Ссылка скопирована',
      'qr_login_open_browser':
          'Открыть в браузере',
      'qr_login_browser_hint':
          'Телефон только один? Откройте ссылку в браузере этого телефона с входом в Bilibili и подтвердите там.',
      'start_download': 'Начать загрузку',
      'download_options': 'Параметры загрузки',
      'concurrency': 'Параллельность',
      'retries': 'Повторы',
      'video_bitrate': 'Битрейт видео',
      'audio_bitrate': 'Битрейт аудио',
      'keep_temp': 'Сохранять временные файлы',
      'keep_temp_hint': 'Полезно для диагностики и ручной сборки',
      'analysis_results': 'Обнаруженные медиа',
      'status': 'Состояние',
      'history': 'История',
      'warnings': 'Предупреждения',
      'appearance': 'Оформление',
      'mode': 'Режим',
      'system': 'Система',
      'light': 'Светлый',
      'dark': 'Тёмный',
      'theme': 'Тема',
      'language': 'Язык',
      'battery': 'Оптимизация батареи',
      'battery_hint':
          'Отключение ограничений снижает риск остановки фоновых загрузок',
      'disable_now': 'Отключить',
      'no_candidates': 'Подходящие медиа ещё не найдены.',
      'select_candidate': 'Перед загрузкой выберите один из потоков.',
      'source_page': 'Страница',
      'extractor': 'Извлекатель',
      'completed': 'Готово',
      'output_path': 'Сохранённый файл',
      'analyzing': 'Анализ...',
      'ready': 'Кандидат готов',
      'inspector': 'Инспектор',
      'stream': 'Поток',
    },
    'hi': {
      'series_kind_parts': 'मल्टी-पार्ट वीडियो',
      'series_kind_collection': 'संग्रह',
      'series_kind_bangumi': 'एनीमे',
      'series_kind_series': 'सीरीज़',
      'episodes_unit': 'एपिसोड',
      'download_all': 'सभी डाउनलोड करें',
      'download_series_title': 'पूरी सीरीज़ डाउनलोड करें?',
      'download_series_body':
          'एपिसोड क्रम से डाउनलोड होंगे और पूरा होते ही हर फ़ाइल निर्यात होगी।',
      'cancel': 'रद्द करें',
      'app_title': 'Segmeris',
      'app_subtitle':
          'पेज का विश्लेषण करें, चलने योग्य मीडिया खोजें और सर्वश्रेष्ठ उपलब्ध स्ट्रीम डाउनलोड करें।',
      'input_source': 'स्रोत URL',
      'source_hint': 'वेबपेज, m3u8, mp4, YouTube या Bilibili लिंक चिपकाएँ',
      'file_name': 'आउटपुट फ़ाइल',
      'save_location': 'सेव स्थान',
      'default_location': 'डिफ़ॉल्ट स्थान',
      'choose_directory': 'फ़ोल्डर चुनें',
      'reset_default': 'डिफ़ॉल्ट उपयोग करें',
      'analyze': 'विश्लेषण करें',
      'auth_browser_load_failed': 'पेज लोड नहीं हो सका',
      'auth_browser_qr_fallback':
          'अगर अंदरूनी ब्राउज़र खाली रहे तो «Bilibili में साइन इन करें» (QR कोड) इस्तेमाल करें — इसे ब्राउज़र की ज़रूरत नहीं।',
      'qr_login_title': 'Bilibili में साइन इन करें',
      'qr_login_hint':
          'Bilibili ऐप से कोड स्कैन करें, फिर फ़ोन पर पुष्टि करें। यह Bilibili का ही लॉगिन है: सत्र आपका है और क्या डाउनलोड होगा यह आपका खाता तय करता है।',
      'qr_login_preparing': 'QR कोड तैयार हो रहा है…',
      'qr_login_waiting': 'स्कैन की प्रतीक्षा…',
      'qr_login_scanned': 'स्कैन हो गया — फ़ोन पर पुष्टि करें',
      'qr_login_expired': 'QR कोड की अवधि समाप्त',
      'qr_login_failed': 'साइन इन विफल',
      'qr_login_retry': 'नया QR कोड',
      'download': 'चयनित स्ट्रीम डाउनलोड करें',
      'quality_dialog_title': 'गुणवत्ता चुनें',
      'quality_dialog_hint':
          'ये इस सत्र में उपलब्ध स्ट्रीम हैं। एक चुनें, फिर डाउनलोड शुरू करें।',
      'quality_dialog_series_hint':
          'यह गुणवत्ता हर एपिसोड पर लागू होती है; जिस एपिसोड में यह उपलब्ध नहीं, वह निकटतम गुणवत्ता में सहेजा जाएगा।',
      'auth_browser_open_external':
          'सिस्टम ब्राउज़र में खोलें',
      'auth_browser_copy_link':
          'लिंक कॉपी करें',
      'auth_browser_link_copied':
          'लिंक कॉपी हो गया',
      'qr_login_open_browser':
          'ब्राउज़र में खोलें',
      'qr_login_browser_hint':
          'सिर्फ़ एक फ़ोन है? लिंक को इसी फ़ोन के ब्राउज़र में Bilibili पर साइन-इन कर के खोलें और वहीं पुष्टि करें।',
      'start_download': 'डाउनलोड शुरू करें',
      'download_options': 'डाउनलोड विकल्प',
      'concurrency': 'समांतरता',
      'retries': 'पुनः प्रयास',
      'video_bitrate': 'वीडियो बिटरेट',
      'audio_bitrate': 'ऑडियो बिटरेट',
      'keep_temp': 'अस्थायी फ़ाइलें रखें',
      'keep_temp_hint': 'डायग्नोस्टिक और मैन्युअल रीमिक्स के लिए उपयोगी',
      'analysis_results': 'मिले हुए मीडिया',
      'status': 'स्थिति',
      'history': 'इतिहास',
      'warnings': 'चेतावनी',
      'appearance': 'रूप',
      'mode': 'मोड',
      'system': 'सिस्टम',
      'light': 'लाइट',
      'dark': 'डार्क',
      'theme': 'थीम',
      'language': 'भाषा',
      'battery': 'बैटरी अनुकूलन',
      'battery_hint':
          'प्रतिबंध बंद करने से लंबे बैकग्राउंड डाउनलोड रुकने की संभावना कम होती है',
      'disable_now': 'अभी बंद करें',
      'no_candidates': 'अभी तक कोई डाउनलोड योग्य मीडिया नहीं मिला।',
      'select_candidate': 'डाउनलोड से पहले कोई मीडिया चुनें।',
      'source_page': 'स्रोत पेज',
      'extractor': 'एक्सट्रैक्टर',
      'completed': 'पूर्ण',
      'output_path': 'सहेजी गई फ़ाइल',
      'analyzing': 'विश्लेषण हो रहा है...',
      'ready': 'उम्मीदवार तैयार है',
      'inspector': 'इंस्पेक्टर',
      'stream': 'स्ट्रीम',
    },
    'fr': {
      'series_kind_parts': 'Vidéo en plusieurs parties',
      'series_kind_collection': 'Collection',
      'series_kind_bangumi': 'Anime',
      'series_kind_series': 'Série',
      'episodes_unit': 'épisodes',
      'download_all': 'Tout télécharger',
      'download_series_title': 'Télécharger toute la série ?',
      'download_series_body':
          'Les épisodes sont téléchargés l’un après l’autre ; chaque fichier terminé est exporté immédiatement.',
      'cancel': 'Annuler',
      'app_title': 'Segmeris',
      'app_subtitle':
          'Analysez une page, repérez les médias lisibles et téléchargez le meilleur flux exposé.',
      'input_source': 'URL source',
      'source_hint':
          'Collez un lien de page web, m3u8, mp4, YouTube ou Bilibili',
      'file_name': 'Fichier de sortie',
      'save_location': 'Emplacement d’enregistrement',
      'default_location': 'Emplacement de sortie par défaut',
      'choose_directory': 'Choisir un dossier',
      'reset_default': 'Utiliser l’emplacement par défaut',
      'analyze': 'Analyser la source',
      'qr_login_title': 'Se connecter à Bilibili',
      'qr_login_hint':
          'Scannez le code avec l\'application Bilibili, puis confirmez sur votre téléphone. C\'est la connexion officielle de Bilibili : la session est la vôtre et vos droits décident de ce qui peut être téléchargé.',
      'qr_login_preparing': 'Préparation du QR code...',
      'qr_login_waiting': 'En attente du scan...',
      'qr_login_scanned': 'Scanné — confirmez sur votre téléphone',
      'qr_login_expired': 'Le QR code a expiré',
      'qr_login_failed': 'Échec de la connexion',
      'qr_login_retry': 'Nouveau QR code',
      'download': 'Télécharger le flux sélectionné',
      'quality_dialog_title': 'Choisir la qualité',
      'quality_dialog_hint':
          'Voici les flux accessibles à cette session. Choisissez-en un, puis lancez le téléchargement.',
      'quality_dialog_series_hint':
          'Cette qualité s\'applique à tous les épisodes : chacun est téléchargé dans cette qualité ou la plus proche disponible.',
      'auth_browser_open_external':
          'Ouvrir dans le navigateur du système',
      'auth_browser_copy_link':
          'Copier le lien',
      'auth_browser_link_copied':
          'Lien copié',
      'qr_login_open_browser':
          'Ouvrir dans le navigateur',
      'qr_login_browser_hint':
          'Un seul téléphone ? Ouvrez le lien dans le navigateur de ce téléphone, connecté à Bilibili, et confirmez-y.',
      'start_download': 'Lancer le téléchargement',
      'download_options': 'Options de téléchargement',
      'concurrency': 'Téléchargements parallèles',
      'retries': 'Réessais',
      'video_bitrate': 'Débit vidéo',
      'audio_bitrate': 'Débit audio',
      'keep_temp': 'Conserver les fichiers temporaires',
      'keep_temp_hint': 'Utile pour le diagnostic et le remux manuel',
      'analysis_results': 'Médias détectés',
      'status': 'Statut',
      'history': 'Historique',
      'warnings': 'Avertissements',
      'appearance': 'Apparence',
      'mode': 'Mode',
      'system': 'Système',
      'light': 'Clair',
      'dark': 'Sombre',
      'theme': 'Thème',
      'language': 'Langue',
      'battery': 'Optimisation batterie',
      'battery_hint':
          'Désactiver les restrictions limite l’arrêt des longues tâches en arrière-plan',
      'disable_now': 'Désactiver',
      'no_candidates': 'Aucun média téléchargeable détecté pour le moment.',
      'select_candidate': 'Sélectionnez un média avant de télécharger.',
      'source_page': 'Page source',
      'extractor': 'Extracteur',
      'completed': 'Terminé',
      'output_path': 'Fichier enregistré',
      'analyzing': 'Analyse en cours...',
      'ready': 'Candidat prêt',
      'inspector': 'Inspecteur',
      'stream': 'Flux',
      'authorization': 'Contexte de requête autorisé',
      'authorization_hint':
          'Pour les sites que vous possédez ou que vous êtes autorisé à utiliser : Cookie, User-Agent, Referer, Origin et en-têtes personnalisés',
      'cookie_hint': 'name=value; another=value',
      'headers_hint':
          'Authorization: Bearer ...\nX-Requested-With: XMLHttpRequest',
      'core': 'Principal',
      'score': 'Score',
      'segments': 'segments',
      'auth_browser_open': 'Ouvrir le navigateur d’autorisation',
      'auth_browser_load_failed': 'La page n\'a pas pu être chargée',
      'auth_browser_qr_fallback':
          'Si le navigateur intégré reste vide, utilisez « Se connecter à Bilibili » (le QR code) : aucun navigateur requis.',
      'auth_browser_title': 'Navigateur de session autorisée',
      'auth_browser_hint':
          'Ouvrez le site cible ici, terminez vous-même la connexion ou la vérification humaine, puis réimportez la session actuelle dans Segmeris.',
      'auth_browser_hint_inline':
          'Utilisez le navigateur d’autorisation quand le site exige une connexion, une lecture liée à un Cookie ou une vérification humaine.',
      'auth_browser_address': 'Adresse du navigateur',
      'auth_browser_go': 'Ouvrir',
      'auth_browser_import': 'Importer la session actuelle',
      'auth_browser_no_session':
          'Aucun Cookie réutilisable ni aucune session de navigateur exploitable n’a été trouvé sur la page actuelle.',
      'auth_session_imported':
          'La session autorisée a été importée. Vous pouvez relancer l’analyse ou le téléchargement avec le contexte de requête mis à jour.',
      'auth_challenge_detected': 'Défi d’accès détecté',
      'auth_challenge_help':
          'Segmeris peut réutiliser une session que vous avez validée vous-même, mais ne contourne pas Cloudflare, les CAPTCHA, les blocages, le DRM, les signatures ni les limites d’aperçu.',
      'auth_auto_open':
          'Ouvrir automatiquement le navigateur d’autorisation en cas de défi',
      'auth_auto_open_hint':
          'Quand l’analyse ou le téléchargement rencontre une connexion obligatoire, une limitation, Cloudflare ou une vérification humaine, Segmeris ouvre automatiquement le navigateur d’autorisation.',
      'auth_redirecting':
          'Une session autorisée est nécessaire. Ouverture du navigateur d’autorisation…',
      'clear_auth_context': 'Effacer la session importée',
      'preparing': 'Préparation du téléchargement...',
      'output_not_created':
          'Le téléchargement est terminé, mais aucun fichier de sortie n’a été créé. Vérifiez l’URL source, le contexte de requête ou réessayez.',
      'export_failed':
          'Impossible d’exporter le fichier vers l’emplacement choisi. Fichier temporaire :',
      'download_hint':
          'Vous pouvez télécharger directement sans analyse : collez un lien m3u8 ou un lien média direct, puis lancez le téléchargement.',
    },
    'de': {
      'series_kind_parts': 'Mehrteiliges Video',
      'series_kind_collection': 'Sammlung',
      'series_kind_bangumi': 'Anime',
      'series_kind_series': 'Serie',
      'episodes_unit': 'Folgen',
      'download_all': 'Alle herunterladen',
      'download_series_title': 'Gesamte Serie herunterladen?',
      'download_series_body':
          'Episoden werden nacheinander heruntergeladen; jede fertige Datei wird sofort exportiert.',
      'cancel': 'Abbrechen',
      'app_title': 'Segmeris',
      'app_subtitle':
          'Analysiere Seiten, finde abspielbare Medien und lade den besten freigelegten Stream herunter.',
      'input_source': 'Quell-URL',
      'source_hint':
          'Webseite, m3u8, mp4, YouTube- oder Bilibili-Link einfügen',
      'file_name': 'Ausgabedatei',
      'save_location': 'Speicherort',
      'default_location': 'Standardordner',
      'choose_directory': 'Ordner wählen',
      'reset_default': 'Standard verwenden',
      'analyze': 'Analysieren',
      'qr_login_title': 'Bei Bilibili anmelden',
      'qr_login_hint':
          'Scanne den Code mit der Bilibili-App und bestätige ihn am Telefon. Das ist Bilibilis eigener Login: die Sitzung gehört dir, und was geladen werden kann, entscheidet dein Konto.',
      'qr_login_preparing': 'QR-Code wird vorbereitet…',
      'qr_login_waiting': 'Warte auf Scan…',
      'qr_login_scanned': 'Gescannt – am Telefon bestätigen',
      'qr_login_expired': 'Der QR-Code ist abgelaufen',
      'qr_login_failed': 'Anmeldung fehlgeschlagen',
      'qr_login_retry': 'Neuer QR-Code',
      'download': 'Ausgewählten Stream laden',
      'quality_dialog_title': 'Qualität wählen',
      'quality_dialog_hint':
          'Das sind die in dieser Sitzung erreichbaren Streams. Einen wählen und den Download starten.',
      'quality_dialog_series_hint':
          'Diese Qualität gilt für alle Folgen; fehlt sie bei einer Folge, wird die nächstbeste geladen.',
      'auth_browser_open_external':
          'Im Systembrowser öffnen',
      'auth_browser_copy_link':
          'Link kopieren',
      'auth_browser_link_copied':
          'Link kopiert',
      'qr_login_open_browser':
          'Im Browser öffnen',
      'qr_login_browser_hint':
          'Nur ein Telefon? Öffne den Link im Browser dieses Telefons mit Bilibili-Anmeldung und bestätige dort.',
      'start_download': 'Download starten',
      'download_options': 'Downloadoptionen',
      'concurrency': 'Parallelität',
      'retries': 'Wiederholungen',
      'video_bitrate': 'Video-Bitrate',
      'audio_bitrate': 'Audio-Bitrate',
      'keep_temp': 'Temporäre Dateien behalten',
      'keep_temp_hint': 'Hilfreich für Diagnose und manuelles Remuxen',
      'analysis_results': 'Erkannte Medien',
      'status': 'Status',
      'history': 'Verlauf',
      'warnings': 'Hinweise',
      'appearance': 'Darstellung',
      'mode': 'Modus',
      'system': 'System',
      'light': 'Hell',
      'dark': 'Dunkel',
      'theme': 'Thema',
      'language': 'Sprache',
      'battery': 'Akku-Optimierung',
      'battery_hint':
          'Weniger Einschränkungen verhindern Abbrüche langer Hintergrunddownloads',
      'disable_now': 'Jetzt deaktivieren',
      'no_candidates': 'Noch keine herunterladbaren Medien erkannt.',
      'select_candidate': 'Vor dem Download bitte einen Stream auswählen.',
      'source_page': 'Quellseite',
      'extractor': 'Extraktor',
      'completed': 'Abgeschlossen',
      'output_path': 'Gespeicherte Datei',
      'analyzing': 'Analyse läuft...',
      'ready': 'Kandidat bereit',
      'inspector': 'Inspektor',
      'stream': 'Stream',
      'authorization': 'Autorisierter Anfragekontext',
      'authorization_hint':
          'Für eigene oder berechtigt genutzte Websites: Cookie, User-Agent, Referer, Origin und benutzerdefinierte Header',
      'cookie_hint': 'name=value; another=value',
      'headers_hint':
          'Authorization: Bearer ...\nX-Requested-With: XMLHttpRequest',
      'core': 'Kern',
      'score': 'Bewertung',
      'segments': 'Segmente',
      'auth_browser_open': 'Autorisierungsbrowser öffnen',
      'auth_browser_load_failed': 'Die Seite konnte nicht geladen werden',
      'auth_browser_qr_fallback':
          'Bleibt der eingebettete Browser leer, nutze „Bei Bilibili anmelden“ per QR-Code – dafür ist kein Browser nötig.',
      'auth_browser_title': 'Browser für autorisierte Sitzungen',
      'auth_browser_hint':
          'Öffne die Zielseite hier, erledige Anmeldung oder menschliche Verifikation selbst und importiere danach die aktuelle Sitzung zurück in Segmeris.',
      'auth_browser_hint_inline':
          'Verwende den Autorisierungsbrowser, wenn die Seite eine Anmeldung, Cookie-gebundene Wiedergabe oder eine menschliche Verifikation verlangt.',
      'auth_browser_address': 'Browseradresse',
      'auth_browser_go': 'Öffnen',
      'auth_browser_import': 'Aktuelle Sitzung importieren',
      'auth_browser_no_session':
          'Auf der aktuellen Seite wurde weder ein wiederverwendbares Cookie noch eine nutzbare Browsersitzung gefunden.',
      'auth_session_imported':
          'Die autorisierte Sitzung wurde importiert. Du kannst jetzt mit dem aktualisierten Anfragekontext erneut analysieren oder herunterladen.',
      'auth_challenge_detected': 'Zugriffshürde erkannt',
      'auth_challenge_help':
          'Segmeris kann eine von dir selbst bestätigte Sitzung wiederverwenden, umgeht aber weder Cloudflare noch CAPTCHA, Sperren, DRM, Signaturen oder Vorschaugrenzen.',
      'auth_auto_open':
          'Autorisierungsbrowser bei Zugriffshürde automatisch öffnen',
      'auth_auto_open_hint':
          'Wenn Analyse oder Download auf Anmeldung, Ratenbegrenzung, Cloudflare oder menschliche Verifikation stoßen, öffnet Segmeris automatisch den Autorisierungsbrowser.',
      'auth_redirecting':
          'Eine autorisierte Sitzung wird benötigt. Autorisierungsbrowser wird geöffnet…',
      'clear_auth_context': 'Importierte Sitzung löschen',
      'preparing': 'Download wird vorbereitet…',
      'output_not_created':
          'Der Download ist beendet, aber es wurde keine Ausgabedatei erzeugt. Prüfe Quell-URL, Anfragekontext oder versuche es erneut.',
      'export_failed':
          'Die Datei konnte nicht an den gewählten Speicherort exportiert werden. Temporäre Ausgabe:',
      'download_hint':
          'Du kannst auch ohne Analyse direkt herunterladen: m3u8- oder Direktlink einfügen und starten.',
    },
    'pt': {
      'series_kind_parts': 'Vídeo em várias partes',
      'series_kind_collection': 'Coleção',
      'series_kind_bangumi': 'Anime',
      'series_kind_series': 'Série',
      'episodes_unit': 'episódios',
      'download_all': 'Baixar tudo',
      'download_series_title': 'Baixar a série completa?',
      'download_series_body':
          'Os episódios são baixados em sequência; cada arquivo concluído é exportado imediatamente.',
      'cancel': 'Cancelar',
      'app_title': 'Segmeris',
      'app_subtitle':
          'Analise páginas, localize mídia reproduzível e baixe o melhor fluxo exposto.',
      'input_source': 'URL de origem',
      'source_hint': 'Cole uma página, m3u8, mp4, YouTube ou Bilibili',
      'file_name': 'Arquivo de saída',
      'save_location': 'Local de salvamento',
      'default_location': 'Local padrão',
      'choose_directory': 'Escolher pasta',
      'reset_default': 'Usar padrão',
      'analyze': 'Analisar',
      'auth_browser_load_failed': 'Não foi possível carregar a página',
      'auth_browser_qr_fallback':
          'Se o navegador integrado ficar em branco, use «Entrar no Bilibili» (o código QR): não precisa de navegador.',
      'qr_login_title': 'Entrar no Bilibili',
      'qr_login_hint':
          'Escaneie o código com o app Bilibili e confirme no telefone. É o login oficial do Bilibili: a sessão é sua e o que pode ser baixado depende da sua conta.',
      'qr_login_preparing': 'Preparando o código QR...',
      'qr_login_waiting': 'Aguardando leitura...',
      'qr_login_scanned': 'Lido — confirme no telefone',
      'qr_login_expired': 'O código QR expirou',
      'qr_login_failed': 'Falha ao entrar',
      'qr_login_retry': 'Novo código QR',
      'download': 'Baixar fluxo selecionado',
      'quality_dialog_title': 'Escolher a qualidade',
      'quality_dialog_hint':
          'Estes são os fluxos acessíveis nesta sessão. Escolha um e inicie o download.',
      'quality_dialog_series_hint':
          'Aplica-se a todos os episódios: cada um baixa nesta qualidade ou na mais próxima disponível.',
      'auth_browser_open_external':
          'Abrir no navegador do sistema',
      'auth_browser_copy_link':
          'Copiar link',
      'auth_browser_link_copied':
          'Link copiado',
      'qr_login_open_browser':
          'Abrir no navegador',
      'qr_login_browser_hint':
          'Só tem um telefone? Abra o link no navegador deste telefone com a sessão do Bilibili iniciada e confirme por lá.',
      'start_download': 'Iniciar download',
      'download_options': 'Opções de download',
      'concurrency': 'Concorrência',
      'retries': 'Tentativas',
      'video_bitrate': 'Bitrate de vídeo',
      'audio_bitrate': 'Bitrate de áudio',
      'keep_temp': 'Manter temporários',
      'keep_temp_hint': 'Útil para diagnóstico e remux manual',
      'analysis_results': 'Mídias detectadas',
      'status': 'Status',
      'history': 'Histórico',
      'warnings': 'Avisos',
      'appearance': 'Aparência',
      'mode': 'Modo',
      'system': 'Sistema',
      'light': 'Claro',
      'dark': 'Escuro',
      'theme': 'Tema',
      'language': 'Idioma',
      'battery': 'Otimização de bateria',
      'battery_hint':
          'Desativar restrições ajuda downloads longos em segundo plano',
      'disable_now': 'Desativar agora',
      'no_candidates': 'Nenhuma mídia baixável foi detectada ainda.',
      'select_candidate': 'Selecione uma mídia antes de baixar.',
      'source_page': 'Página de origem',
      'extractor': 'Extrator',
      'completed': 'Concluído',
      'output_path': 'Arquivo salvo',
      'analyzing': 'Analisando...',
      'ready': 'Candidato pronto',
      'inspector': 'Inspetor',
      'stream': 'Fluxo',
    },
    'tr': {
      'series_kind_parts': 'Çok bölümlü video',
      'series_kind_collection': 'Koleksiyon',
      'series_kind_bangumi': 'Anime',
      'series_kind_series': 'Seri',
      'episodes_unit': 'bölüm',
      'download_all': 'Tümünü indir',
      'download_series_title': 'Tüm seri indirilsin mi?',
      'download_series_body':
          'Bölümler sırayla indirilir; tamamlanan her dosya hemen dışa aktarılır.',
      'cancel': 'İptal',
      'app_title': 'Segmeris',
      'app_subtitle':
          'Sayfayı analiz edin, oynatılabilir medyayı bulun ve açıkta olan en iyi akışı indirin.',
      'input_source': 'Kaynak URL',
      'source_hint':
          'Web sayfası, m3u8, mp4, YouTube veya Bilibili bağlantısı yapıştırın',
      'file_name': 'Çıktı dosyası',
      'save_location': 'Kayıt konumu',
      'default_location': 'Varsayılan konum',
      'choose_directory': 'Klasör seç',
      'reset_default': 'Varsayılanı kullan',
      'analyze': 'Analiz et',
      'auth_browser_load_failed': 'Sayfa yüklenemedi',
      'auth_browser_qr_fallback':
          'Gömülü tarayıcı boş kalırsa «Bilibili\'ye giriş yap» (QR kod) seçeneğini kullanın — tarayıcı gerektirmez.',
      'qr_login_title': 'Bilibili\'ye giriş yap',
      'qr_login_hint':
          'Kodu Bilibili uygulamasıyla tarayın ve telefonda onaylayın. Bu Bilibili\'nin kendi girişidir: oturum size aittir ve neyin indirileceğini hesabınız belirler.',
      'qr_login_preparing': 'QR kod hazırlanıyor…',
      'qr_login_waiting': 'Tarama bekleniyor…',
      'qr_login_scanned': 'Tarandı — telefonda onaylayın',
      'qr_login_expired': 'QR kodun süresi doldu',
      'qr_login_failed': 'Giriş başarısız',
      'qr_login_retry': 'Yeni QR kod',
      'download': 'Seçili akışı indir',
      'quality_dialog_title': 'Kalite seç',
      'quality_dialog_hint':
          'Bu oturumda erişilebilen akışlar bunlar. Birini seçip indirmeyi başlatın.',
      'quality_dialog_series_hint':
          'Bu kalite tüm bölümlere uygulanır; bu kaliteyi sunmayan bölüm en yakın kalitede indirilir.',
      'auth_browser_open_external':
          'Sistem tarayıcısında aç',
      'auth_browser_copy_link':
          'Bağlantıyı kopyala',
      'auth_browser_link_copied':
          'Bağlantı kopyalandı',
      'qr_login_open_browser':
          'Tarayıcıda aç',
      'qr_login_browser_hint':
          'Tek telefonunuz mu var? Bağlantıyı bu telefonun tarayıcısında Bilibili oturumu açıkken açıp oradan onaylayın.',
      'start_download': 'İndirmeyi başlat',
      'download_options': 'İndirme seçenekleri',
      'concurrency': 'Eşzamanlılık',
      'retries': 'Yeniden deneme',
      'video_bitrate': 'Video bit hızı',
      'audio_bitrate': 'Ses bit hızı',
      'keep_temp': 'Geçici dosyaları sakla',
      'keep_temp_hint': 'Tanılama ve elle birleştirme için yararlı',
      'analysis_results': 'Bulunan medya',
      'status': 'Durum',
      'history': 'Geçmiş',
      'warnings': 'Uyarılar',
      'appearance': 'Görünüm',
      'mode': 'Mod',
      'system': 'Sistem',
      'light': 'Açık',
      'dark': 'Koyu',
      'theme': 'Tema',
      'language': 'Dil',
      'battery': 'Pil optimizasyonu',
      'battery_hint':
          'Kısıtlamaları kapatmak uzun arka plan indirmelerini korur',
      'disable_now': 'Şimdi kapat',
      'no_candidates': 'Henüz indirilebilir medya bulunamadı.',
      'select_candidate': 'İndirmeden önce bir medya adayı seçin.',
      'source_page': 'Kaynak sayfa',
      'extractor': 'Çıkarıcı',
      'completed': 'Tamamlandı',
      'output_path': 'Kaydedilen dosya',
      'analyzing': 'Analiz ediliyor...',
      'ready': 'Aday hazır',
      'inspector': 'İnceleyici',
      'stream': 'Akış',
    },
    'vi': {
      'series_kind_parts': 'Video nhiều phần',
      'series_kind_collection': 'Bộ sưu tập',
      'series_kind_bangumi': 'Anime',
      'series_kind_series': 'Chuỗi',
      'episodes_unit': 'tập',
      'download_all': 'Tải tất cả',
      'download_series_title': 'Tải toàn bộ chuỗi?',
      'download_series_body':
          'Các tập được tải lần lượt; mỗi tệp hoàn tất được xuất ngay.',
      'cancel': 'Hủy',
      'app_title': 'Segmeris',
      'app_subtitle':
          'Phân tích trang, tìm media có thể phát và tải luồng tốt nhất đang được lộ ra.',
      'input_source': 'URL nguồn',
      'source_hint': 'Dán liên kết web, m3u8, mp4, YouTube hoặc Bilibili',
      'file_name': 'Tệp đầu ra',
      'save_location': 'Nơi lưu',
      'default_location': 'Vị trí mặc định',
      'choose_directory': 'Chọn thư mục',
      'reset_default': 'Dùng mặc định',
      'analyze': 'Phân tích',
      'auth_browser_load_failed': 'Không tải được trang',
      'auth_browser_qr_fallback':
          'Nếu trình duyệt nhúng vẫn trắng, hãy dùng «Đăng nhập Bilibili» (mã QR) — không cần trình duyệt.',
      'qr_login_title': 'Đăng nhập Bilibili',
      'qr_login_hint':
          'Quét mã bằng ứng dụng Bilibili rồi xác nhận trên điện thoại. Đây là cách đăng nhập chính thức của Bilibili: phiên thuộc về bạn và tài khoản quyết định nội dung tải được.',
      'qr_login_preparing': 'Đang chuẩn bị mã QR…',
      'qr_login_waiting': 'Đang chờ quét…',
      'qr_login_scanned': 'Đã quét — xác nhận trên điện thoại',
      'qr_login_expired': 'Mã QR đã hết hạn',
      'qr_login_failed': 'Đăng nhập thất bại',
      'qr_login_retry': 'Tạo mã QR mới',
      'download': 'Tải luồng đã chọn',
      'quality_dialog_title': 'Chọn chất lượng',
      'quality_dialog_hint':
          'Đây là các luồng phiên này truy cập được. Chọn một rồi bắt đầu tải.',
      'quality_dialog_series_hint':
          'Chất lượng này áp dụng cho mọi tập; tập không có chất lượng đó sẽ tải ở mức gần nhất.',
      'auth_browser_open_external':
          'Mở trong trình duyệt hệ thống',
      'auth_browser_copy_link':
          'Sao chép liên kết',
      'auth_browser_link_copied':
          'Đã sao chép liên kết',
      'qr_login_open_browser':
          'Mở trong trình duyệt',
      'qr_login_browser_hint':
          'Chỉ có một điện thoại? Hãy mở liên kết trong trình duyệt của máy này khi đã đăng nhập Bilibili và xác nhận tại đó.',
      'start_download': 'Bắt đầu tải',
      'download_options': 'Tùy chọn tải',
      'concurrency': 'Đồng thời',
      'retries': 'Thử lại',
      'video_bitrate': 'Bitrate video',
      'audio_bitrate': 'Bitrate âm thanh',
      'keep_temp': 'Giữ tệp tạm',
      'keep_temp_hint': 'Hữu ích cho chẩn đoán và ghép tay',
      'analysis_results': 'Media đã phát hiện',
      'status': 'Trạng thái',
      'history': 'Lịch sử',
      'warnings': 'Cảnh báo',
      'appearance': 'Giao diện',
      'mode': 'Chế độ',
      'system': 'Hệ thống',
      'light': 'Sáng',
      'dark': 'Tối',
      'theme': 'Chủ đề',
      'language': 'Ngôn ngữ',
      'battery': 'Tối ưu pin',
      'battery_hint': 'Tắt hạn chế giúp tải nền dài không bị dừng',
      'disable_now': 'Tắt ngay',
      'no_candidates': 'Chưa phát hiện media có thể tải.',
      'select_candidate': 'Hãy chọn một mục trước khi tải.',
      'source_page': 'Trang nguồn',
      'extractor': 'Bộ tách',
      'completed': 'Hoàn tất',
      'output_path': 'Tệp đã lưu',
      'analyzing': 'Đang phân tích...',
      'ready': 'Ứng viên sẵn sàng',
      'inspector': 'Trình phân tích',
      'stream': 'Luồng',
    },
    'id': {
      'series_kind_parts': 'Video multi-bagian',
      'series_kind_collection': 'Koleksi',
      'series_kind_bangumi': 'Anime',
      'series_kind_series': 'Seri',
      'episodes_unit': 'episode',
      'download_all': 'Unduh semua',
      'download_series_title': 'Unduh seluruh seri?',
      'download_series_body':
          'Episode diunduh berurutan; setiap berkas yang selesai langsung diekspor.',
      'cancel': 'Batal',
      'app_title': 'Segmeris',
      'app_subtitle':
          'Analisis halaman, temukan media yang bisa diputar, lalu unduh aliran terbaik yang terlihat.',
      'input_source': 'URL sumber',
      'source_hint': 'Tempel tautan web, m3u8, mp4, YouTube, atau Bilibili',
      'file_name': 'Berkas keluaran',
      'save_location': 'Lokasi simpan',
      'default_location': 'Lokasi bawaan',
      'choose_directory': 'Pilih folder',
      'reset_default': 'Pakai bawaan',
      'analyze': 'Analisis',
      'auth_browser_load_failed': 'Halaman gagal dimuat',
      'auth_browser_qr_fallback':
          'Jika browser tertanam tetap kosong, gunakan «Masuk ke Bilibili» (kode QR) — tidak perlu browser.',
      'qr_login_title': 'Masuk ke Bilibili',
      'qr_login_hint':
          'Pindai kode dengan aplikasi Bilibili lalu konfirmasi di ponsel. Ini login resmi Bilibili: sesinya milik Anda dan akun Anda yang menentukan apa yang bisa diunduh.',
      'qr_login_preparing': 'Menyiapkan kode QR…',
      'qr_login_waiting': 'Menunggu pemindaian…',
      'qr_login_scanned': 'Terpindai — konfirmasi di ponsel',
      'qr_login_expired': 'Kode QR kedaluwarsa',
      'qr_login_failed': 'Gagal masuk',
      'qr_login_retry': 'Kode QR baru',
      'download': 'Unduh aliran terpilih',
      'quality_dialog_title': 'Pilih kualitas',
      'quality_dialog_hint':
          'Ini aliran yang dapat diakses sesi ini. Pilih satu, lalu mulai unduhan.',
      'quality_dialog_series_hint':
          'Kualitas ini berlaku untuk semua episode; episode tanpa kualitas tersebut diunduh pada kualitas terdekat.',
      'auth_browser_open_external':
          'Buka di browser sistem',
      'auth_browser_copy_link':
          'Salin tautan',
      'auth_browser_link_copied':
          'Tautan disalin',
      'qr_login_open_browser':
          'Buka di browser',
      'qr_login_browser_hint':
          'Hanya punya satu ponsel? Buka tautannya di browser ponsel ini dengan Bilibili sudah masuk, lalu konfirmasi di sana.',
      'start_download': 'Mulai unduh',
      'download_options': 'Opsi unduhan',
      'concurrency': 'Konkruensi',
      'retries': 'Ulangi',
      'video_bitrate': 'Bitrate video',
      'audio_bitrate': 'Bitrate audio',
      'keep_temp': 'Simpan berkas sementara',
      'keep_temp_hint': 'Berguna untuk diagnostik dan remux manual',
      'analysis_results': 'Media terdeteksi',
      'status': 'Status',
      'history': 'Riwayat',
      'warnings': 'Peringatan',
      'appearance': 'Tampilan',
      'mode': 'Mode',
      'system': 'Sistem',
      'light': 'Terang',
      'dark': 'Gelap',
      'theme': 'Tema',
      'language': 'Bahasa',
      'battery': 'Optimisasi baterai',
      'battery_hint':
          'Mematikan pembatasan membantu unduhan latar belakang yang panjang',
      'disable_now': 'Matikan sekarang',
      'no_candidates': 'Belum ada media yang dapat diunduh terdeteksi.',
      'select_candidate': 'Pilih kandidat media sebelum mengunduh.',
      'source_page': 'Halaman sumber',
      'extractor': 'Ekstraktor',
      'completed': 'Selesai',
      'output_path': 'Berkas tersimpan',
      'analyzing': 'Menganalisis...',
      'ready': 'Kandidat siap',
      'inspector': 'Inspektur',
      'stream': 'Aliran',
    },
  };

  String text(String key) {
    final bundle = _strings[_lookupKey] ?? _strings[_fallbackLocale]!;
    return bundle[key] ?? _strings[_fallbackLocale]![key] ?? key;
  }

  String localeLabel(Locale locale) {
    final key = localeKeyOf(locale);
    return localeLabels[key] ?? localeLabels[locale.languageCode] ?? key;
  }

  String get _lookupKey {
    if (locale.scriptCode != null) {
      final composite = '${locale.languageCode}_${locale.scriptCode}';
      if (_strings.containsKey(composite)) {
        return composite;
      }
    }
    if (_strings.containsKey(locale.languageCode)) {
      return locale.languageCode;
    }
    return _fallbackLocale;
  }
}

class _AppLocalizationsDelegate
    extends LocalizationsDelegate<AppLocalizations> {
  const _AppLocalizationsDelegate();

  @override
  bool isSupported(Locale locale) {
    return AppLocalizations.supportedLocales.any(
      (item) => item.languageCode == locale.languageCode,
    );
  }

  @override
  Future<AppLocalizations> load(Locale locale) async {
    return AppLocalizations(AppLocalizations.resolveLocale(locale));
  }

  @override
  bool shouldReload(covariant LocalizationsDelegate<AppLocalizations> old) {
    return false;
  }
}
