import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';

import 'platform_utils.dart';

class MediaStoreBridge {
  static const MethodChannel _channel = MethodChannel(
    'com.blue.segmeris/media_store',
  );

  static Future<void>? _permissionPrompt;

  static Future<void> _requestDownloadPermissions() async {
    await [Permission.storage, Permission.notification].request();
  }

  static Future<String> getAppPrivateDir() async {
    if (!SegmerisPlatform.isAndroid) {
      return '';
    }
    try {
      return await _channel.invokeMethod<String>('getAppExternalFilesDir') ??
          '';
    } catch (_) {
      return '';
    }
  }

  static Future<String?> saveViaMediaStore(
    String srcPath,
    String fileName, {
    String subDir = 'Segmeris',
    String mimeType = 'video/mp4',
  }) async {
    if (!SegmerisPlatform.isAndroid) {
      return srcPath;
    }
    try {
      return await _channel.invokeMethod<String>('saveToDownloads', {
        'srcPath': srcPath,
        'fileName': fileName,
        'mimeType': mimeType,
        'subDir': subDir,
      });
    } catch (_) {
      return null;
    }
  }

  static Future<String?> saveToPath(
    String srcPath,
    String destDir,
    String fileName,
  ) async {
    if (!SegmerisPlatform.isAndroid) {
      return srcPath;
    }
    try {
      return await _channel.invokeMethod<String>('saveToPath', {
        'srcPath': srcPath,
        'destDir': destDir,
        'fileName': fileName,
      });
    } catch (_) {
      return null;
    }
  }

  static Future<void> deleteDownloadedFile(String path) async {
    final deleted = await _channel.invokeMethod<bool>('deleteDownloadedFile', {
      'path': path,
    });
    if (deleted != true) {
      throw StateError('The platform did not confirm file deletion');
    }
  }

  static Future<void> startForegroundService() async {
    if (!SegmerisPlatform.isAndroid) {
      return;
    }
    try {
      await (_permissionPrompt ??= _requestDownloadPermissions());
    } on PlatformException {
      _permissionPrompt = null;
    }
    try {
      await _channel.invokeMethod('startForegroundService');
    } catch (_) {}
  }

  static Future<void> stopForegroundService() async {
    if (!SegmerisPlatform.isAndroid) {
      return;
    }
    try {
      await _channel.invokeMethod('stopForegroundService');
    } catch (_) {}
  }

  static Future<void> updateForegroundProgress(
    int progress,
    String status,
  ) async {
    if (!SegmerisPlatform.isAndroid) {
      return;
    }
    try {
      await _channel.invokeMethod('updateServiceProgress', {
        'progress': progress,
        'status': status,
      });
    } catch (_) {}
  }

  static Future<bool> isIgnoringBatteryOptimizations() async {
    if (!SegmerisPlatform.isAndroid) {
      return true;
    }
    try {
      return await _channel.invokeMethod<bool>(
            'isIgnoringBatteryOptimizations',
          ) ??
          false;
    } catch (_) {
      return false;
    }
  }

  static Future<void> requestIgnoreBatteryOptimizations() async {
    if (!SegmerisPlatform.isAndroid) {
      return;
    }
    try {
      await _channel.invokeMethod('requestIgnoreBatteryOptimizations');
    } catch (_) {}
  }
}
