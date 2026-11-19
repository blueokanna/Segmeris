import 'dart:ui' as ui;

import 'package:material_ui/material_ui.dart';

/// The supplied brand mark, with distinct geometry for each system appearance.
///
/// Defaults to the OS appearance, independently of the application's theme
/// override. Set [brightness] only when a specific presentation needs it.
class BrandLogo extends StatelessWidget {
  const BrandLogo({
    super.key,
    this.size = 48,
    this.brightness,
    this.transparent = false,
    this.semanticLabel = 'Segmeris',
  }) : assert(size > 0);

  final double size;
  final Brightness? brightness;

  /// Opt out of the original solid background only on a known matching surface.
  /// By default the mark stays legible when app and OS themes differ.
  final bool transparent;
  final String semanticLabel;

  @override
  Widget build(BuildContext context) {
    final appearance = brightness ?? MediaQuery.platformBrightnessOf(context);
    return Semantics(
      image: true,
      label: semanticLabel,
      child: RepaintBoundary(
        child: CustomPaint(
          size: Size.square(size),
          painter: BrandLogoPainter(
            brightness: appearance,
            transparent: transparent,
          ),
        ),
      ),
    );
  }
}

/// Static painter shared by in-app branding and reduced-motion startup.
class BrandLogoPainter extends CustomPainter {
  const BrandLogoPainter({required this.brightness, this.transparent = false});

  final Brightness brightness;
  final bool transparent;

  @override
  void paint(Canvas canvas, Size size) {
    if (!transparent) {
      canvas.drawRect(
        Offset.zero & size,
        Paint()..color = BrandArtwork.forBrightness(brightness).background,
      );
    }
    final scale = size.shortestSide / BrandArtwork.viewBox;
    canvas.save();
    canvas.translate(
      (size.width - size.shortestSide) / 2,
      (size.height - size.shortestSide) / 2,
    );
    canvas.scale(scale);
    BrandArtwork.forBrightness(brightness).paint(canvas);
    canvas.restore();
  }

  @override
  bool shouldRepaint(BrandLogoPainter oldDelegate) =>
      oldDelegate.brightness != brightness ||
      oldDelegate.transparent != transparent;
}

/// Cached measured Bézier geometry in the original photograph's proportions.
///
/// The light artwork consists of round-ended strokes; the dark artwork consists
/// of filled ribbons with square ends and tapered tips. No inversion is used.
/// Measurements and previews: assets/brand/{geometry.json,preview.png}.
class BrandArtwork {
  BrandArtwork._({required this.dark, required List<String> shapes})
    : paths = List.unmodifiable(shapes.map(_parsePath)),
      flowPaths = List.unmodifiable(
        (dark ? _darkFlowData : shapes).map(_parsePath),
      ) {
    metrics = List.unmodifiable(
      flowPaths.map((path) => path.computeMetrics().single),
    );
  }

  static const double viewBox = 1000;
  static const double lightStrokeWidth = 23.2;
  static const double darkStrokeWidth = 32;
  static final BrandArtwork _light = BrandArtwork._(
    dark: false,
    shapes: _lightData,
  );
  static final BrandArtwork _dark = BrandArtwork._(
    dark: true,
    shapes: _darkData,
  );

  static BrandArtwork forBrightness(Brightness brightness) =>
      brightness == Brightness.dark ? _dark : _light;

  final bool dark;
  final List<Path> paths;
  final List<Path> flowPaths;
  late final List<ui.PathMetric> metrics;

  Color get foreground => dark ? Colors.white : Colors.black;
  Color get background => dark ? Colors.black : Colors.white;

  void paint(Canvas canvas, {double opacity = 1}) {
    final pen = Paint()
      ..color = foreground.withValues(alpha: opacity)
      ..isAntiAlias = true
      ..style = dark ? PaintingStyle.fill : PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..strokeWidth = lightStrokeWidth;
    for (final path in paths) {
      canvas.drawPath(path, pen);
    }
  }

  // Deliberately restricted to our reviewed, embedded path grammar. Parsing and
  // PathMetric allocation happen once per appearance, never in paint().
  static Path _parsePath(String source) {
    final tokens = RegExp(r'[MLCZ]|-?\d+(?:\.\d+)?')
        .allMatches(source)
        .map((match) => match.group(0)!)
        .toList(growable: false);
    final result = Path();
    var i = 0;
    double number() => double.parse(tokens[i++]);
    while (i < tokens.length) {
      switch (tokens[i++]) {
        case 'M':
          result.moveTo(number(), number());
        case 'L':
          result.lineTo(number(), number());
        case 'C':
          result.cubicTo(
            number(),
            number(),
            number(),
            number(),
            number(),
            number(),
          );
        case 'Z':
          result.close();
        default:
          throw StateError('Unsupported embedded brand path');
      }
    }
    return result;
  }

  // Keep these measurements in sync with tools/generate_brand_assets.py.
  static const _lightData = <String>[
    'M674,211.5 L479,211.5 C388.15,211.5 314.5,285.15 314.5,376 C314.5,466.85 388.15,540.5 479,540.5 L520,540.5 C565.56,540.5 602.5,577.44 602.5,623 C602.5,668.56 565.56,705.5 520,705.5 L408.5,705.5',
    'M633,252.7 L479,252.7 C410.91,252.7 355.7,307.91 355.7,376 C355.7,444.09 410.91,499.3 479,499.3 L520,499.3 C588.32,499.3 643.7,554.68 643.7,623 C643.7,691.32 588.32,746.7 520,746.7 L367.3,746.7',
    'M591.8,293.9 L479,293.9 C433.66,293.9 396.9,330.66 396.9,376 C396.9,421.34 433.66,458.1 479,458.1 L520,458.1 C611.07,458.1 684.9,531.93 684.9,623 C684.9,714.07 611.07,787.9 520,787.9 L326.1,787.9',
    'M550.6,335.1 L479,335.1 C456.41,335.1 438.1,353.41 438.1,376 C438.1,394.27 450.08,409.74 466.6,414.99',
    'M449.4,664.1 L520,664.1 C542.7,664.1 561.1,645.7 561.1,623 C561.1,604.72 549.17,589.23 532.7,583.86',
    'M490.9,376 L509.1,376',
    'M490.9,623 L509.1,623',
  ];

  static const _darkData = <String>[
    'M661,282 L472,282 C407.11,282 354.5,334.39 354.5,399 C354.5,463.61 407.11,516 472,516 L528,516 C574.94,516 613,554.06 613,601 C613,647.94 574.94,686 528,686 L338,686 L338,718 L528,718 C592.62,718 645,665.62 645,601 C645,536.38 592.62,484 528,484 L472,484 C424.78,484 386.5,445.94 386.5,399 C386.5,352.06 424.78,314 472,314 L661,314 Z',
    'M661,330.5 L472,330.5 C434.17,330.5 403.5,361.17 403.5,399 C403.5,436.83 434.17,467.5 472,467.5 L526,467.5 C594,467.5 650,520 661,589 C665,508 604,435.5 526,435.5 L472,435.5 C451.84,435.5 435.5,419.16 435.5,399 C435.5,378.84 451.84,362.5 472,362.5 L661,362.5 Z',
    'M338,669.5 L528,669.5 C565.83,669.5 596.5,638.83 596.5,601 C596.5,563.17 565.83,532.5 528,532.5 L474,532.5 C406,532.5 350,480 338,411 C334,492 396,564.5 474,564.5 L528,564.5 C548.16,564.5 564.5,580.84 564.5,601 C564.5,621.16 548.16,637.5 528,637.5 L338,637.5 Z',
  ];

  static const _darkFlowData = <String>[
    'M661,298 L472,298 C415.94,298 370.5,343.22 370.5,399 C370.5,454.78 415.94,500 472,500 L528,500 C583.78,500 629,545.22 629,601 C629,656.78 583.78,702 528,702 L338,702',
    'M661,346.5 L472,346.5 C443,346.5 419.5,370 419.5,399 C419.5,428 443,451.5 472,451.5 L526,451.5 C595,451.5 653,517 661,589',
    'M338,653.5 L528,653.5 C557,653.5 580.5,630 580.5,601 C580.5,572 557,548.5 528,548.5 L474,548.5 C405,548.5 347,483 338,411',
  ];
}
