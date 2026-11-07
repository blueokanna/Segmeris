import 'dart:async';
import 'dart:io';

typedef CommandProbe = Future<bool> Function(
  String executable,
  List<String> arguments,
);

class FfmpegEncoder {
  const FfmpegEncoder(
    this.label,
    this.encoder,
    this.hardware, [
    this.arguments = const [],
  ]);

  final String label;
  final String encoder;
  final bool hardware;
  final List<String> arguments;
}

class FfmpegEncoderReport {
  const FfmpegEncoderReport(this.available, this.unavailable);

  final List<FfmpegEncoder> available;
  final List<FfmpegEncoder> unavailable;
}

Future<FfmpegEncoderReport> probeFfmpegEncoders(
  String executable, {
  required String operatingSystem,
  CommandProbe run = probeCommand,
}) async {
  final candidates = [
    const FfmpegEncoder('NVIDIA NVENC', 'h264_nvenc', true, [
      '-preset',
      'p4',
      '-rc',
      'vbr',
    ]),
    const FfmpegEncoder('AMD AMF', 'h264_amf', true),
    const FfmpegEncoder('Intel Quick Sync', 'h264_qsv', true, [
      '-init_hw_device',
      'qsv=hw',
      '-filter_hw_device',
      'hw',
      '-vf',
      'format=nv12,hwupload=extra_hw_frames=64',
    ]),
    if (operatingSystem == 'linux') ...[
      const FfmpegEncoder('Linux VAAPI', 'h264_vaapi', true, [
        '-vaapi_device',
        '/dev/dri/renderD128',
        '-vf',
        'format=nv12,hwupload',
      ]),
      const FfmpegEncoder('Linux V4L2 M2M', 'h264_v4l2m2m', true, [
        '-vf',
        'format=nv12',
      ]),
    ],
    if (operatingSystem == 'macos')
      const FfmpegEncoder('Apple VideoToolbox', 'h264_videotoolbox', true, [
        '-allow_sw',
        '0',
      ]),
    const FfmpegEncoder('CPU libx264', 'libx264', false, ['-preset', 'medium']),
  ];
  final available = <FfmpegEncoder>[];
  final unavailable = <FfmpegEncoder>[];
  for (final candidate in candidates) {
    final works = await run(executable, [
      '-hide_banner',
      '-loglevel',
      'error',
      '-nostdin',
      '-f',
      'lavfi',
      '-i',
      'color=c=black:s=1280x720:r=30',
      '-frames:v',
      '3',
      '-an',
      '-c:v',
      candidate.encoder,
      ...candidate.arguments,
      '-f',
      'null',
      '-',
    ]);
    (works ? available : unavailable).add(candidate);
  }
  return FfmpegEncoderReport(available, unavailable);
}

/// Discards output while draining both pipes; a timed-out probe is killed.
Future<bool> probeCommand(
  String executable,
  List<String> arguments, {
  Duration timeout = const Duration(seconds: 8),
}) async {
  Process? process;
  StreamSubscription<List<int>>? stdout;
  StreamSubscription<List<int>>? stderr;
  try {
    final starting = Process.start(executable, arguments);
    process = await starting.timeout(
      timeout,
      onTimeout: () {
        // Process creation can complete after the caller's deadline.
        unawaited(
          starting.then<void>((lateProcess) async {
            lateProcess.kill(ProcessSignal.sigkill);
            final output = lateProcess.stdout.listen(
              (_) {},
              onError: (Object _) {},
            );
            final errors = lateProcess.stderr.listen(
              (_) {},
              onError: (Object _) {},
            );
            try {
              await lateProcess.exitCode.timeout(const Duration(seconds: 2));
            } on TimeoutException {
              lateProcess.kill(ProcessSignal.sigkill);
            } finally {
              await output.cancel();
              await errors.cancel();
            }
          }, onError: (Object _) {}),
        );
        throw TimeoutException('Process creation timed out', timeout);
      },
    );
    stdout = process.stdout.listen((_) {}, onError: (Object _) {});
    stderr = process.stderr.listen((_) {}, onError: (Object _) {});
    final code = await process.exitCode.timeout(timeout);
    return code == 0;
  } on TimeoutException {
    process?.kill(ProcessSignal.sigkill);
    if (process != null) {
      try {
        await process.exitCode.timeout(const Duration(seconds: 2));
      } on TimeoutException {
        return false;
      }
    }
    return false;
  } on ProcessException {
    return false;
  } finally {
    await stdout?.cancel();
    await stderr?.cancel();
  }
}
