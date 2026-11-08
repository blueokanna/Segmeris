import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:segmeris/src/app/ffmpeg_capabilities_io.dart';

void main() {
  test('captures bounded diagnostics while draining noisy probes', () async {
    final result = await runCommandProbe(
      Platform.isWindows ? 'powershell.exe' : '/bin/sh',
      Platform.isWindows
          ? [
              '-NoProfile',
              '-NonInteractive',
              '-Command',
              "[Console]::Out.Write(('x' * 100000)); [Console]::Error.Write(('e' * 20000)); exit 3",
            ]
          : ['-c', "printf '%100000s' x; printf '%20000s' e >&2; exit 3"],
    );
    expect(result.success, isFalse);
    expect(result.diagnostic.length, 8192);
  });
  test(
    'keeps every usable encoder and separately reports failed probes',
    () async {
      final tried = <String>[];
      final report = await probeFfmpegEncoders(
        'ffmpeg',
        operatingSystem: 'windows',
        run: (_, args) async {
          final encoder = args[args.indexOf('-c:v') + 1];
          tried.add(encoder);
          return CommandProbeResult(
            encoder != 'h264_amf',
            diagnostic: 'No compatible AMF device',
          );
        },
      );
      expect(tried, ['h264_nvenc', 'h264_amf', 'h264_qsv', 'libx264']);
      expect(report.available.map((encoder) => encoder.label), [
        'NVIDIA NVENC',
        'Intel Quick Sync',
        'CPU libx264',
      ]);
      expect(report.unavailable.single.label, 'AMD AMF');
      expect(report.diagnostics['AMD AMF'], 'No compatible AMF device');
    },
  );

  test(
    'probes Linux SoC encoding and QSV with their device upload arguments',
    () async {
      final arguments = <String, List<String>>{};
      final report = await probeFfmpegEncoders(
        'ffmpeg',
        operatingSystem: 'linux',
        run: (_, args) async {
          final encoder = args[args.indexOf('-c:v') + 1];
          arguments[encoder] = args;
          return CommandProbeResult(encoder == 'h264_v4l2m2m');
        },
      );
      expect(report.available.single.label, 'Linux V4L2 M2M');
      expect(arguments['h264_v4l2m2m'], contains('format=nv12'));
      expect(arguments['h264_rkmpp'], contains('format=nv12'));
      expect(arguments['h264_qsv'], contains('format=nv12'));
      expect(
        arguments['h264_nvenc'],
        contains('color=c=black:s=1280x720:r=30'),
      );
      expect(arguments, isNot(contains('h264_videotoolbox')));
    },
  );

  test(
    'does not classify VideoToolbox software fallback as hardware',
    () async {
      await probeFfmpegEncoders(
        'ffmpeg',
        operatingSystem: 'macos',
        run: (_, args) async {
          if (args.contains('h264_videotoolbox')) {
            expect(args[args.indexOf('-allow_sw') + 1], '0');
          }
          return const CommandProbeResult(false);
        },
      );
    },
  );

  test(
    'timeout kills the probe before it can write a delayed marker',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'segmeris-probe-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final marker = File('${directory.path}/completed');
      final script = File(
        '${directory.path}/probe.${Platform.isWindows ? 'ps1' : 'sh'}',
      );
      await script.writeAsString(
        Platform.isWindows
            ? 'Start-Sleep -Seconds 2\nSet-Content -LiteralPath \$args[0] -Value done\n'
            : 'sleep 2\nprintf done > "\$1"\n',
      );
      final watch = Stopwatch()..start();
      final success = await probeCommand(
        Platform.isWindows ? 'powershell.exe' : '/bin/sh',
        [
          if (Platform.isWindows) ...['-NoProfile', '-NonInteractive', '-File'],
          script.path,
          marker.path,
        ],
        timeout: const Duration(milliseconds: 100),
      );
      expect(success, isFalse);
      expect(watch.elapsed, lessThan(const Duration(seconds: 2)));
      await Future<void>.delayed(const Duration(milliseconds: 2300));
      expect(await marker.exists(), isFalse);
    },
  );
}
