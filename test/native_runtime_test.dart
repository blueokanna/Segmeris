import 'dart:io';

import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:segmeris/src/rust/api/downloader.dart';
import 'package:segmeris/src/rust/frb_generated.dart';

void main() {
  const libraryPath = String.fromEnvironment('SEGMERIS_NATIVE_LIBRARY');
  test(
    'release library reports missing media over the real FFI stream',
    () async {
      await RustLib.init(
        externalLibrary: ExternalLibrary.open(File(libraryPath).absolute.path),
      );
      addTearDown(RustLib.dispose);
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      var requests = 0;
      server.listen((request) async {
        requests++;
        request.response.statusCode = HttpStatus.notFound;
        request.response.write('<Error><Code>NoSuchKey</Code></Error>');
        await request.response.close();
      });
      final directory = await Directory.systemTemp.createTemp(
        'segmeris-native-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final output = File('${directory.path}/video.mp4');
      final events = await hls2Mp4Run(
        url: 'http://127.0.0.1:${server.port}/missing.m3u8',
        concurrency: 4,
        output: output.path,
        retries: 3,
        videoBitrate: 0,
        audioBitrate: 0,
        keepTemp: false,
      ).toList().timeout(const Duration(seconds: 15));
      expect(requests, 1);
      expect(events.last.error, contains('HTTP 404: NoSuchKey'));
      expect(
        events.any((event) => event.message.contains('Selected FFmpeg')),
        isFalse,
      );
      expect(output.existsSync(), isFalse);
    },
    skip: libraryPath.isEmpty
        ? 'Requires a built native release library'
        : false,
  );
}
