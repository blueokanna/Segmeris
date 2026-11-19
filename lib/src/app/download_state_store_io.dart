import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'download_state_store_base.dart';

DownloadStateStore createPlatformDownloadStateStore() =>
    FileDownloadStateStore();

/// Two alternating generations stored under the application's support directory.
///
/// Pass [directory] to use an exact directory, for example a real test temp dir.
/// All instances in this isolate share a queue, including their load operations.
/// Independent isolates/processes must not write the same directory concurrently.
class FileDownloadStateStore extends TwoSlotDownloadStateStore {
  FileDownloadStateStore({this._directory})
    : super(queue: _operations);

  static final _operations = DownloadStateOperationQueue();
  static const slotFileNames = [
    'download_state.0.json',
    'download_state.1.json',
  ];

  Directory? _directory;

  Future<Directory> _resolveDirectory() async =>
      _directory ??= await getApplicationSupportDirectory();

  File _file(Directory directory, int index) =>
      File('${directory.path}${Platform.pathSeparator}${slotFileNames[index]}');

  @override
  Future<List<DownloadStateSlot>> readSlots() async {
    final directory = await _resolveDirectory();
    final slots = <DownloadStateSlot>[];
    for (var index = 0; index < slotFileNames.length; index++) {
      final file = _file(directory, index);
      for (final candidate in [file, File('${file.path}.tmp')]) {
        slots.add(
          DownloadStateSlot(
            index: index,
            location: candidate.path,
            contents: await candidate.exists()
                ? utf8.decode(
                    await candidate.readAsBytes(),
                    allowMalformed: true,
                  )
                : null,
          ),
        );
      }
    }
    return slots;
  }

  @override
  Future<void> writeSlot(int index, String contents) async {
    final directory = await _resolveDirectory();
    await directory.create(recursive: true);
    final destination = _file(directory, index);
    final staging = File('${destination.path}.tmp');
    final handle = await staging.open(mode: FileMode.write);
    try {
      await handle.writeString(contents);
      await handle.flush();
    } finally {
      await handle.close();
    }
    if (await destination.exists()) await destination.delete();
    await staging.rename(destination.path);
  }
}
