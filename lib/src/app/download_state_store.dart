import 'download_state_store_base.dart';
import 'download_state_store_web.dart'
    if (dart.library.io) 'download_state_store_io.dart'
    as platform;

export 'download_state_store_base.dart'
    show
        DownloadStateStore,
        DownloadStateStoreException,
        DownloadStateCorruptionException,
        MemoryDownloadStateStore;

/// Creates persistent storage without accessing plugins until load/save is used.
DownloadStateStore createDownloadStateStore() =>
    platform.createPlatformDownloadStateStore();
