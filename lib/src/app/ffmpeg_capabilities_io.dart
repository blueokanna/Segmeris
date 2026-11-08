import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'dart:io';

typedef CommandProbe = Future<CommandProbeResult> Function(
  String executable,
  List<String> arguments,
);

class CommandProbeResult {
  const CommandProbeResult(this.success, {this.diagnostic = ''});

  final bool success;
  final String diagnostic;
}

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
  const FfmpegEncoderReport(this.available, this.unavailable, this.diagnostics);

  final List<FfmpegEncoder> available;
  final List<FfmpegEncoder> unavailable;
  final Map<String, String> diagnostics;
}

Future<FfmpegEncoderReport> probeFfmpegEncoders(
  String executable, {
  required String operatingSystem,
  CommandProbe run = runCommandProbe,
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
      '-vf',
      'format=nv12',
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
      const FfmpegEncoder('Rockchip MPP', 'h264_rkmpp', true, [
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
  final diagnostics = <String, String>{};
  for (final candidate in candidates) {
    final result = await run(executable, [
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
    (result.success ? available : unavailable).add(candidate);
    if (!result.success && result.diagnostic.isNotEmpty) {
      diagnostics[candidate.label] = const LineSplitter()
          .convert(result.diagnostic.trim())
          .take(2)
          .map((line) => line.replaceFirst(RegExp(r'^\[[^\]]+\]\s*'), ''))
          .join('\n');
    }
  }
  return FfmpegEncoderReport(available, unavailable, diagnostics);
}

Future<bool> probeCommand(
  String executable,
  List<String> arguments, {
  Duration timeout = const Duration(seconds: 8),
}) async =>
    (await runCommandProbe(executable, arguments, timeout: timeout)).success;

/// Keeps at most 8 KiB of stderr while draining both pipes and bounding runtime.
Future<CommandProbeResult> runCommandProbe(
  String executable,
  List<String> arguments, {
  Duration timeout = const Duration(seconds: 8),
}) async {
  final captured = BytesBuilder(copy: false);
  final errorDone = Completer<void>();
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
    stderr = process.stderr.listen(
      (chunk) {
        final remaining = 8192 - captured.length;
        if (remaining > 0) {
          captured.add(
            chunk.length <= remaining ? chunk : chunk.sublist(0, remaining),
          );
        }
      },
      onError: (Object _) {},
      onDone: errorDone.complete,
    );
    final code = await process.exitCode.timeout(timeout);
    await errorDone.future.timeout(const Duration(seconds: 2));
    return CommandProbeResult(
      code == 0,
      diagnostic: utf8.decode(captured.takeBytes(), allowMalformed: true),
    );
  } on TimeoutException {
    process?.kill(ProcessSignal.sigkill);
    if (process != null) {
      try {
        await process.exitCode.timeout(const Duration(seconds: 2));
      } on TimeoutException {
        return const CommandProbeResult(
          false,
          diagnostic: 'capability_probe_timeout',
        );
      }
    }
    return const CommandProbeResult(
      false,
      diagnostic: 'capability_probe_timeout',
    );
  } on ProcessException {
    return const CommandProbeResult(
      false,
      diagnostic: 'capability_probe_start_failed',
    );
  } finally {
    await stdout?.cancel();
    await stderr?.cancel();
  }
}
