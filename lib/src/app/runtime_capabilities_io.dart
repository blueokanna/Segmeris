import 'dart:io';

import 'capability_snapshot.dart';
import 'ffmpeg_capabilities_io.dart';
import 'platform_utils.dart';

// References come from the conditional import in `runtime_capabilities.dart`;
// see `platform_utils_stub.dart` for why this ignore is required.
// ignore_for_file: unused_element

Future<PlatformCapabilitySnapshot> probeDesktopCapabilities() async {
  final notes = <String>[];
  final ffmpeg = await _resolveFfmpeg();
  final ytdlpAvailable = await _resolveYtdlp();
  var backend = 'Unavailable';
  var accelerated = false;
  var encoders = <String>[];
  var unavailableEncoders = <String>[];
  var diagnostics = <String, String>{};

  if (ffmpeg != null) {
    final report = await probeFfmpegEncoders(
      ffmpeg,
      operatingSystem: SegmerisPlatform.operatingSystem,
    );
    encoders = report.available.map((encoder) => encoder.label).toList();
    unavailableEncoders = report.unavailable
        .map((encoder) => encoder.label)
        .toList();
    diagnostics = report.diagnostics;
    if (diagnostics['NVIDIA NVENC']?.contains(
          'Driver does not support the required nvenc API version',
        ) ??
        false) {
      notes.add('capability_nvenc_driver');
    }
    notes.add('capability_desktop_probe');
    if (report.available.isNotEmpty) {
      final encoder = report.available.first;
      backend = 'FFmpeg / ${encoder.label}';
      accelerated = encoder.hardware;
    } else {
      backend = 'FFmpeg / no usable H.264 encoder';
      notes.add('capability_no_encoder');
    }
  } else {
    notes.add('capability_no_ffmpeg');
  }
  if (!ytdlpAvailable) {
    notes.add('capability_ytdlp_on_demand');
  }

  return PlatformCapabilitySnapshot(
    platform: SegmerisPlatform.operatingSystem,
    transcoderBackend: backend,
    hardwareAccelerated: accelerated,
    videoEncoders: encoders,
    unavailableVideoEncoders: unavailableEncoders,
    encoderDiagnostics: diagnostics,
    videoDecoders: const [],
    ffmpegAvailable: ffmpeg != null,
    ytdlpAvailable: ytdlpAvailable,
    notes: notes,
  );
}

Future<String?> _resolveFfmpeg() async {
  final executable = SegmerisPlatform.isWindows ? 'ffmpeg.exe' : 'ffmpeg';
  final appDirectory = File(Platform.resolvedExecutable).parent;
  final candidates = <String>[
    if ((Platform.environment['FERRISLOAD_FFMPEG_PATH'] ?? '').isNotEmpty)
      Platform.environment['FERRISLOAD_FFMPEG_PATH']!,
    '${appDirectory.path}${SegmerisPlatform.pathSeparator}tools${SegmerisPlatform.pathSeparator}$executable',
    '${appDirectory.path}${SegmerisPlatform.pathSeparator}$executable',
    executable,
  ];
  for (final candidate in _unique(candidates)) {
    if (await probeCommand(candidate, const ['-version'])) {
      return candidate;
    }
  }
  return null;
}

Future<bool> _resolveYtdlp() async {
  final executable = SegmerisPlatform.isWindows ? 'yt-dlp.exe' : 'yt-dlp';
  final appDirectory = File(Platform.resolvedExecutable).parent;
  final cachePath = _ytdlpCachePath();
  final candidates = <({String program, List<String> prefix})>[
    if ((Platform.environment['FERRISLOAD_YTDLP_PATH'] ?? '').isNotEmpty)
      (
        program: Platform.environment['FERRISLOAD_YTDLP_PATH']!,
        prefix: const [],
      ),
    (
      program:
          '${appDirectory.path}${SegmerisPlatform.pathSeparator}tools${SegmerisPlatform.pathSeparator}$executable',
      prefix: const [],
    ),
    (
      program:
          '${appDirectory.path}${SegmerisPlatform.pathSeparator}$executable',
      prefix: const [],
    ),
    if (cachePath != null) (program: cachePath, prefix: const []),
    (program: executable, prefix: const []),
    if (SegmerisPlatform.isWindows)
      (program: 'py', prefix: const ['-m', 'yt_dlp']),
    (
      program: SegmerisPlatform.isWindows ? 'python' : 'python3',
      prefix: const ['-m', 'yt_dlp'],
    ),
    if (!SegmerisPlatform.isWindows)
      (program: 'python', prefix: const ['-m', 'yt_dlp']),
  ];
  for (final candidate in candidates) {
    if (await probeCommand(candidate.program, [
      ...candidate.prefix,
      '--version',
    ])) {
      return true;
    }
  }
  return false;
}

String? _ytdlpCachePath() {
  if (SegmerisPlatform.isWindows) {
    final root = Platform.environment['LOCALAPPDATA'];
    return root == null
        ? null
        : '$root${SegmerisPlatform.pathSeparator}Segmeris${SegmerisPlatform.pathSeparator}tools${SegmerisPlatform.pathSeparator}yt-dlp.exe';
  }
  final home = Platform.environment['HOME'];
  if (SegmerisPlatform.isMacOS && home != null) {
    return '$home/Library/Application Support/Segmeris/tools/yt-dlp';
  }
  final root =
      Platform.environment['XDG_DATA_HOME'] ??
      (home == null ? null : '$home/.local/share');
  return root == null ? null : '$root/segmeris/tools/yt-dlp';
}

List<String> _unique(List<String> values) {
  final seen = <String>{};
  return [
    for (final value in values)
      if (seen.add(SegmerisPlatform.isWindows ? value.toLowerCase() : value))
        value,
  ];
}
