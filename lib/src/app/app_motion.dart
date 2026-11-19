import 'package:material_ui/material_ui.dart';

abstract final class SegmerisMotion {
  static const Duration fast = Duration(milliseconds: 200);
  static const Duration medium = Duration(milliseconds: 300);
  static const Duration slow = Duration(milliseconds: 500);
  static const Duration theme = medium;
  static const Curve linear = Curves.linear;
  static const Curve standard = Cubic(0.2, 0, 0, 1);
  static const Curve standardDecelerate = Cubic(0, 0, 0, 1);
  static const Curve standardAccelerate = Cubic(0.3, 0, 1, 1);
  static const Curve emphasized = Curves.easeInOutCubicEmphasized;
  static const Curve emphasizedDecelerate = Cubic(0.05, 0.7, 0.1, 1);
  static const Curve emphasizedAccelerate = Cubic(0.3, 0, 0.8, 0.15);
  static const Curve decelerate = emphasizedDecelerate;
  static const Curve accelerate = emphasizedAccelerate;

  static bool enabled(BuildContext context) =>
      !MediaQuery.disableAnimationsOf(context) &&
      TickerMode.valuesOf(context).enabled;

  static Duration duration(BuildContext context, Duration value) =>
      enabled(context) ? value : Duration.zero;
}
