import 'dart:io';

import 'capability_snapshot.dart';
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

  if (ffmpeg != null) {
    final encoder = await _detectEncoder(ffmpeg);
    if (encoder != null) {
      backend = 'FFmpeg / ${encoder.label}';
      accelerated = encoder.hardware;
      encoders = [encoder.label];
    } else {
      backend = 'FFmpeg / no usable H.264 encoder';
      notes.add(
          'FFmpeg was found, but every H.264 encoder runtime probe failed.');
    }
  } else {
    notes.add(
        'FFmpeg was not found in the configured, bundled, or system paths.');
  }
  if (!ytdlpAvailable) {
    notes.add(
      'yt-dlp is not installed yet; desktop downloads install the verified official binary on demand.',
    );
  }

  return PlatformCapabilitySnapshot(
    platform: SegmerisPlatform.operatingSystem,
    transcoderBackend: backend,
    hardwareAccelerated: accelerated,
    videoEncoders: encoders,
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
    if (await _commandWorks(candidate, const ['-version'])) {
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
    if (await _commandWorks(
      candidate.program,
      [...candidate.prefix, '--version'],
    )) {
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
  final root = Platform.environment['XDG_DATA_HOME'] ??
      (home == null ? null : '$home/.local/share');
  return root == null ? null : '$root/segmeris/tools/yt-dlp';
}

Future<_EncoderProbe?> _detectEncoder(String ffmpeg) async {
  final probes = <_EncoderProbe>[
    const _EncoderProbe('NVIDIA NVENC', 'h264_nvenc', true),
    const _EncoderProbe('AMD AMF', 'h264_amf', true),
    const _EncoderProbe('Intel Quick Sync', 'h264_qsv', true),
    if (SegmerisPlatform.isLinux)
      const _EncoderProbe(
        'Linux VAAPI',
        'h264_vaapi',
        true,
        extraArguments: [
          '-vaapi_device',
          '/dev/dri/renderD128',
          '-vf',
          'format=nv12,hwupload',
        ],
      ),
    if (SegmerisPlatform.isMacOS)
      const _EncoderProbe('Apple VideoToolbox', 'h264_videotoolbox', true),
    const _EncoderProbe('CPU libx264', 'libx264', false),
  ];
  for (final probe in probes) {
    if (await _commandWorks(ffmpeg, [
      '-hide_banner',
      '-loglevel',
      'error',
      '-f',
      'lavfi',
      '-i',
      'color=c=black:s=64x64:r=1',
      '-frames:v',
      '1',
      '-an',
      '-c:v',
      probe.encoder,
      ...probe.extraArguments,
      '-f',
      'null',
      '-',
    ])) {
      return probe;
    }
  }
  return null;
}

Future<bool> _commandWorks(
  String executable,
  List<String> arguments,
) async {
  try {
    final result = await Process.run(executable, arguments)
        .timeout(const Duration(seconds: 8));
    return result.exitCode == 0;
  } catch (_) {
    return false;
  }
}

List<String> _unique(List<String> values) {
  final seen = <String>{};
  return [
    for (final value in values)
      if (seen.add(
        SegmerisPlatform.isWindows ? value.toLowerCase() : value,
      ))
        value,
  ];
}

class _EncoderProbe {
  const _EncoderProbe(
    this.label,
    this.encoder,
    this.hardware, {
    this.extraArguments = const [],
  });

  final String label;
  final String encoder;
  final bool hardware;
  final List<String> extraArguments;
}
