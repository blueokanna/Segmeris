import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:material_ui/material_ui.dart';

import 'brand_logo.dart';

/// Paints the startup artwork until the caller is ready to show its content.
///
/// The bootstrap owns initialization and the short entrance duration. Setting
/// [ready] swaps in [child] in the same build.
class StartupMotion extends StatefulWidget {
  const StartupMotion({
    super.key,
    required this.ready,
    required this.child,
    this.label = 'Segmeris',
    this.semanticLabel = 'Segmeris',
    this.logoSize = 240,
  }) : assert(logoSize > 0);

  final bool ready;
  final Widget child;
  final String label;
  final String semanticLabel;
  final double logoSize;

  @override
  State<StartupMotion> createState() => _StartupMotionState();
}

class _StartupMotionState extends State<StartupMotion>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  late final AnimationController _controller;
  bool _reduceMotion = false;
  bool _tickerEnabled = true;
  late AppLifecycleState _lifecycle;

  @override
  void initState() {
    super.initState();
    _lifecycle =
        WidgetsBinding.instance.lifecycleState ?? AppLifecycleState.resumed;
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1800),
    );
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reduceMotion = MediaQuery.disableAnimationsOf(context);
    _tickerEnabled = TickerMode.valuesOf(context).enabled;
    _syncTicker();
  }

  @override
  void didUpdateWidget(StartupMotion oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncTicker();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _lifecycle = state;
    _syncTicker();
  }

  void _syncTicker() {
    final run =
        !widget.ready &&
        !_reduceMotion &&
        _tickerEnabled &&
        _lifecycle == AppLifecycleState.resumed;
    if (run) {
      if (!_controller.isAnimating) _controller.repeat();
    } else {
      _controller.stop();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.ready) return widget.child;
    final brightness = MediaQuery.platformBrightnessOf(context);
    final artwork = BrandArtwork.forBrightness(brightness);
    return ColoredBox(
      color: artwork.background,
      child: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final width = constraints.hasBoundedWidth
                ? constraints.maxWidth
                : widget.logoSize;
            final height = constraints.hasBoundedHeight
                ? constraints.maxHeight
                : widget.logoSize * 2;
            final logoSize = math.min(
              widget.logoSize,
              math.min(width, height * 0.65),
            );
            // Large accessibility text remains readable and scrollable even
            // in a short desktop window; never clamp the user's text scale.
            return SingleChildScrollView(
              child: ConstrainedBox(
                constraints: BoxConstraints(minHeight: height),
                child: Center(
                  child: Semantics(
                    label: widget.semanticLabel,
                    image: true,
                    child: ExcludeSemantics(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          RepaintBoundary(
                            child: CustomPaint(
                              size: Size.square(logoSize),
                              painter: StartupLogoPainter(
                                brightness: brightness,
                                progress: _controller,
                                animate: !_reduceMotion,
                              ),
                            ),
                          ),
                          if (widget.label.isNotEmpty)
                            Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 16,
                                vertical: 8,
                              ),
                              child: Text(
                                widget.label,
                                textAlign: TextAlign.center,
                                style: Theme.of(context).textTheme.titleMedium
                                    ?.copyWith(
                                      color: artwork.foreground,
                                      letterSpacing: 1.2,
                                    ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

/// A moving pen along cached Bézier arc lengths, never a sequence of images.
/// Animation notifications invalidate only this painter's repaint boundary.
class StartupLogoPainter extends CustomPainter {
  StartupLogoPainter({
    required this.brightness,
    required this.progress,
    required this.animate,
  }) : super(repaint: animate ? progress : null);

  final Brightness brightness;
  final Animation<double> progress;
  final bool animate;

  @override
  void paint(Canvas canvas, Size size) {
    final artwork = BrandArtwork.forBrightness(brightness);
    canvas.save();
    canvas.translate(
      (size.width - size.shortestSide) / 2,
      (size.height - size.shortestSide) / 2,
    );
    canvas.scale(size.shortestSide / BrandArtwork.viewBox);
    if (!animate) {
      artwork.paint(canvas);
      canvas.restore();
      return;
    }

    final phase = progress.value * 2 * math.pi;
    const center = BrandArtwork.viewBox / 2;
    canvas.translate(center, center + 12 * math.sin(phase));
    canvas.rotate(0.035 * math.sin(phase));
    canvas.translate(-center, -center);
    artwork.paint(canvas, opacity: 0.2);
    final pen = Paint()
      ..isAntiAlias = true
      ..style = PaintingStyle.stroke
      ..strokeCap = artwork.dark ? StrokeCap.butt : StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..strokeWidth = artwork.dark
          ? BrandArtwork.darkStrokeWidth * 1.3
          : BrandArtwork.lightStrokeWidth;
    for (var i = 0; i < artwork.metrics.length; i++) {
      final metric = artwork.metrics[i];
      // Independent phase offsets make the ribbons flow through one another,
      // while a single linear clock keeps every segment continuous at wrap.
      final head = (progress.value + i * 0.105) % 1;
      canvas.save();
      if (artwork.dark) canvas.clipPath(artwork.paths[i]);
      for (var segment = 0; segment < 5; segment++) {
        final tail = head - 0.42 + segment * 0.084;
        pen.color = artwork.foreground.withValues(alpha: 0.16 + segment * 0.21);
        _paintTrim(canvas, metric, tail, tail + 0.084, pen);
      }
      canvas.restore();
    }
    canvas.restore();
  }

  static void _paintTrim(
    Canvas canvas,
    ui.PathMetric metric,
    double start,
    double end,
    Paint pen,
  ) {
    final wrappedStart = start % 1;
    final span = end - start;
    final firstEnd = math.min(1.0, wrappedStart + span);
    canvas.drawPath(
      metric.extractPath(
        wrappedStart * metric.length,
        firstEnd * metric.length,
      ),
      pen,
    );
    if (wrappedStart + span > 1) {
      canvas.drawPath(
        metric.extractPath(0, (wrappedStart + span - 1) * metric.length),
        pen,
      );
    }
  }

  @override
  bool shouldRepaint(StartupLogoPainter oldDelegate) =>
      oldDelegate.brightness != brightness ||
      oldDelegate.progress != progress ||
      oldDelegate.animate != animate;
}
