import 'dart:io' show Platform;

/// Native (non-web) platform helpers backed by `dart:io`.
///
/// Selected by the conditional import in `platform_utils.dart` when
/// `dart.library.io` is available.
//
// References come from the conditional import in `platform_utils.dart`, which
// the standalone analysis of this file cannot see, hence the ignore.
// ignore_for_file: unused_element
bool segmerisHostIsAndroid() => Platform.isAndroid;
bool segmerisHostIsIOS() => Platform.isIOS;
bool segmerisHostIsWindows() => Platform.isWindows;
bool segmerisHostIsMacOS() => Platform.isMacOS;
bool segmerisHostIsLinux() => Platform.isLinux;
String segmerisHostOperatingSystem() => Platform.operatingSystem;
String segmerisHostPathSeparator() => Platform.pathSeparator;
