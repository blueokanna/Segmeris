import 'local_file_utils_stub.dart'
    if (dart.library.io) 'local_file_utils_io.dart';

/// Whether a local file exists on native platforms.
///
/// On the web this always returns `false` (the browser has no filesystem and
/// output files are owned by the API server).
Future<bool> localFileExists(String path) => fileExists(path);

/// Byte length of a local file (0 on the web).
Future<int> localFileLength(String path) => fileLength(path);

/// Delete a local file, reporting access and I/O failures to the caller.
Future<void> localFileDelete(String path) => deleteFile(path);

Future<String> localOutputPath(String name, String? directory) =>
    outputPath(name, directory);
