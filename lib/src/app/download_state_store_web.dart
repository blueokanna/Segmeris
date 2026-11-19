import 'package:shared_preferences/shared_preferences.dart';

import 'download_state_store_base.dart';

DownloadStateStore createPlatformDownloadStateStore() =>
    SharedPreferencesDownloadStateStore();

/// Web persistence using two independently validated SharedPreferences keys.
///
/// A single browser-storage key is replaced at a time, always preserving the
/// newest valid generation in the other slot. All instances in this isolate
/// share a queue; concurrent writers in other tabs are outside this contract.
class SharedPreferencesDownloadStateStore extends TwoSlotDownloadStateStore {
  SharedPreferencesDownloadStateStore({
    this._preferences,
    this.keyPrefix = 'segmeris.downloadState',
  }) : super(queue: _operations);

  static final _operations = DownloadStateOperationQueue();

  final String keyPrefix;
  SharedPreferences? _preferences;

  String slotKey(int index) => '$keyPrefix.$index';

  Future<SharedPreferences> _resolvePreferences() async =>
      _preferences ??= await SharedPreferences.getInstance();

  @override
  Future<List<DownloadStateSlot>> readSlots() async {
    final preferences = await _resolvePreferences();
    // Reload even after a failed write: the plugin may have updated its cache
    // before the platform rejected the write, or another instance may save.
    await preferences.reload();
    return List.generate(2, (index) {
      final key = slotKey(index);
      final value = preferences.get(key);
      return DownloadStateSlot(
        index: index,
        location: key,
        // A wrong stored type is corruption, not an absent snapshot.
        contents: value == null
            ? null
            : value is String
            ? value
            : '',
      );
    });
  }

  @override
  Future<void> writeSlot(int index, String contents) async {
    final preferences = await _resolvePreferences();
    if (!await preferences.setString(slotKey(index), contents)) {
      throw const DownloadStateStoreException(
        'The browser rejected the download snapshot write.',
      );
    }
  }
}
