import 'dart:convert';

/// Persists opaque, JSON-serializable task data without depending on task models.
///
/// A null load means no snapshot has ever been stored. Existing but wholly
/// unreadable snapshots throw [DownloadStateCorruptionException]. Operations are
/// ordered by invocation, and a failed operation does not block later work.
abstract class DownloadStateStore {
  Future<Map<String, dynamic>?> load();

  /// Captures a JSON copy at invocation, before waiting for earlier operations.
  Future<void> save(Map<String, dynamic> data);
}

class DownloadStateStoreException implements Exception {
  const DownloadStateStoreException(this.message);

  final String message;

  @override
  String toString() => 'DownloadStateStoreException: $message';
}

class DownloadStateCorruptionException extends DownloadStateStoreException {
  DownloadStateCorruptionException(Iterable<String> locations)
    : locations = List.unmodifiable(locations),
      super('No valid download snapshot remains; existing data was preserved.');

  final List<String> locations;
}

/// An isolated, copying implementation suitable for widget-test injection.
class MemoryDownloadStateStore implements DownloadStateStore {
  MemoryDownloadStateStore({Map<String, dynamic>? initialData})
    : _payload = initialData == null ? null : jsonEncode(initialData);

  final _queue = DownloadStateOperationQueue();
  String? _payload;

  @override
  Future<Map<String, dynamic>?> load() => _queue.run(() async {
    final payload = _payload;
    return payload == null ? null : jsonDecode(payload) as Map<String, dynamic>;
  });

  @override
  Future<void> save(Map<String, dynamic> data) {
    final String payload;
    try {
      payload = jsonEncode(data);
    } catch (error, stack) {
      return Future.error(error, stack);
    }
    return _queue.run(() async {
      _payload = payload;
    });
  }
}

/// Implementation detail shared by the platform backends.
class DownloadStateOperationQueue {
  Future<void> _tail = Future.value();

  Future<T> run<T>(Future<T> Function() operation) {
    final result = _tail.then((_) => operation());
    // Only the private tail absorbs errors. The caller still receives them.
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }
}

/// A physical copy; a native staging file belongs to its destination's slot.
class DownloadStateSlot {
  const DownloadStateSlot({
    required this.index,
    required this.location,
    required this.contents,
  });

  final int index;
  final String location;
  final String? contents;
}

/// Shared schema validation and generation selection for both backends.
abstract class TwoSlotDownloadStateStore implements DownloadStateStore {
  TwoSlotDownloadStateStore({required this._queue});

  static const _version = 1;
  // JavaScript represents every integer exactly only through this value.
  static const _maxGeneration = 9007199254740991;

  final DownloadStateOperationQueue _queue;

  Future<List<DownloadStateSlot>> readSlots();
  Future<void> writeSlot(int index, String contents);

  @override
  Future<Map<String, dynamic>?> load() => _queue.run(() async {
    final latest = await _readLatest();
    return latest?.data;
  });

  @override
  Future<void> save(Map<String, dynamic> data) {
    final String payload;
    try {
      payload = jsonEncode(data);
    } catch (error, stack) {
      return Future.error(error, stack);
    }
    return _queue.run(() async {
      // Reading before saving also refuses to overwrite wholly corrupt data.
      final latest = await _readLatest();
      final generation = (latest?.generation ?? 0) + 1;
      if (generation > _maxGeneration) {
        throw const DownloadStateStoreException(
          'Snapshot generation exhausted.',
        );
      }
      final target = latest == null ? 0 : 1 - latest.slot;
      final contents = jsonEncode({
        'version': _version,
        'generation': generation,
        'payload': payload,
        'checksum': _checksum('$_version:$generation:$payload'),
      });
      await writeSlot(target, contents);
    });
  }

  Future<_Snapshot?> _readLatest() async {
    final slots = await readSlots();
    _Snapshot? latest;
    final existing = <String>[];
    for (final slot in slots) {
      final contents = slot.contents;
      if (contents == null) continue;
      existing.add(slot.location);
      try {
        final snapshot = _decode(slot.index, contents);
        if (latest == null || snapshot.generation > latest.generation) {
          latest = snapshot;
        }
      } on FormatException {
        // Another slot, including a complete staging file, can recover it.
      }
    }
    if (latest == null && existing.isNotEmpty) {
      throw DownloadStateCorruptionException(existing);
    }
    return latest;
  }

  static _Snapshot _decode(int slot, String contents) {
    final envelope = jsonDecode(contents);
    if (envelope is! Map<String, dynamic> ||
        envelope['version'] != _version ||
        envelope['version'] is! int) {
      throw const FormatException('Unsupported snapshot envelope.');
    }
    final generation = envelope['generation'];
    final payload = envelope['payload'];
    if (generation is! int ||
        generation < 1 ||
        generation > _maxGeneration ||
        payload is! String ||
        envelope['checksum'] != _checksum('$_version:$generation:$payload')) {
      throw const FormatException('Invalid snapshot metadata or checksum.');
    }
    final data = jsonDecode(payload);
    if (data is! Map<String, dynamic>) {
      throw const FormatException('Snapshot payload must be a JSON object.');
    }
    return _Snapshot(slot, generation, data);
  }

  // CRC32 detects accidental corruption, including valid-JSON alterations.
  // Bitwise operations produce the same result on the VM and JavaScript.
  static String _checksum(String value) {
    var crc = 0xffffffff;
    for (final byte in utf8.encode(value)) {
      crc ^= byte;
      for (var bit = 0; bit < 8; bit++) {
        crc = (crc >>> 1) ^ ((crc & 1) == 0 ? 0 : 0xedb88320);
      }
    }
    return ((crc ^ 0xffffffff) & 0xffffffff).toRadixString(16).padLeft(8, '0');
  }
}

class _Snapshot {
  const _Snapshot(this.slot, this.generation, this.data);

  final int slot;
  final int generation;
  final Map<String, dynamic> data;
}
