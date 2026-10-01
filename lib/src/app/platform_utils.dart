import 'package:flutter/foundation.dart' show kIsWeb;

import 'platform_utils_stub.dart' if (dart.library.io) 'platform_utils_io.dart';

/// Platform helpers that compile on every Flutter target, including the web.
///
/// On native targets this reports the real host OS via `dart:io` (which also
/// matches the widget-test environment, where `defaultTargetPlatform` would
/// incorrectly report Android). On the web there is no `dart:io`, so the stub
/// returns web defaults and every native check is short-circuited by [isWeb].
abstract final class SegmerisPlatform {
  /// Whether the app is running inside a browser (web / WASM build).
  static bool get isWeb => kIsWeb;

  /// Whether the app is running on Android.
  static bool get isAndroid => !isWeb && segmerisHostIsAndroid();

  /// Whether the app is running on iOS.
  static bool get isIOS => !isWeb && segmerisHostIsIOS();

  /// Whether the app is running on Windows.
  static bool get isWindows => !isWeb && segmerisHostIsWindows();

  /// Whether the app is running on macOS.
  static bool get isMacOS => !isWeb && segmerisHostIsMacOS();

  /// Whether the app is running on Linux.
  static bool get isLinux => !isWeb && segmerisHostIsLinux();

  /// Operating-system name for display purposes (`'web'` on the web).
  static String get operatingSystem =>
      isWeb ? 'web' : segmerisHostOperatingSystem();

  /// Path separator used by the host platform (`/` on the web and POSIX,
  /// `\` on Windows).
  static String get pathSeparator => isWeb ? '/' : segmerisHostPathSeparator();
}
