import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// Native local-file helpers backed by `dart:io`.
///
/// Selected by the conditional import in `local_file_utils.dart` when
/// `dart.library.io` is available.
//
// References come from the conditional import in `local_file_utils.dart`; see
// `platform_utils_stub.dart` for why this ignore is required.
// ignore_for_file: unused_element
Future<bool> fileExists(String path) async => File(path).exists();

Future<int> fileLength(String path) async => File(path).length();

Future<void> deleteFile(String path) async {
  final file = File(path);
  if (await file.exists()) await file.delete();
}

Future<String> outputPath(String name, String? directory) async {
  final base =
      directory ??
      (await getDownloadsDirectory())?.path ??
      (await getApplicationDocumentsDirectory()).path;
  final dir = await Directory(base).absolute.create(recursive: true);
  return '${dir.path}${Platform.pathSeparator}$name';
}
