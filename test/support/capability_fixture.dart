import 'package:segmeris/src/app/capability_snapshot.dart';

Future<PlatformCapabilitySnapshot> unknownCapabilities() async =>
    const PlatformCapabilitySnapshot(
      platform: 'test',
      transcoderBackend: 'Not probed',
      hardwareAccelerated: null,
      videoEncoders: [],
      videoDecoders: [],
      ffmpegAvailable: null,
      ytdlpAvailable: null,
      notes: [],
    );
