import 'dart:async';

import 'package:dynamic_color/dynamic_color.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:material_ui/material_ui.dart';
import 'package:segmeris/src/app/app_localizations.dart';
import 'package:segmeris/src/app/app_motion.dart';
import 'package:segmeris/src/app/app_settings.dart';
import 'package:segmeris/src/app/app_theme.dart';
import 'package:segmeris/src/app/app_update.dart';
import 'package:segmeris/src/app/startup_motion.dart';
import 'package:segmeris/src/home/home_page.dart';
import 'package:segmeris/src/rust/frb_generated.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  registerAppFontLicenses();
  runApp(const SegmerisBootstrap());
}

Future<AppSettings> _initializeApplication() async {
  // The first Flutter frame is already visible while plugins and Rust load.
  final settings = await AppSettings.load();
  if (!kIsWeb) await RustLib.init();
  return settings;
}

class SegmerisBootstrap extends StatefulWidget {
  const SegmerisBootstrap({
    super.key,
    this.initialize = _initializeApplication,
  });
  final Future<AppSettings> Function() initialize;

  @override
  State<SegmerisBootstrap> createState() => _SegmerisBootstrapState();
}

class _SegmerisBootstrapState extends State<SegmerisBootstrap> {
  late Future<AppSettings> _initialization;
  Timer? _introTimer;
  bool _introPlayed = false;

  @override
  void initState() {
    super.initState();
    _initialization = _startAfterFirstFrame();
  }

  Future<AppSettings> _startAfterFirstFrame() async {
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted) throw StateError('Startup was disposed');
    // Fast initialization still leaves one visible sweep of the logo. Slow
    // devices keep drawing while the real work completes in parallel.
    _introTimer = Timer(SegmerisMotion.slow, () {
      if (mounted) setState(() => _introPlayed = true);
    });
    return widget.initialize();
  }

  @override
  void dispose() {
    _introTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<AppSettings>(
    future: _initialization,
    builder: (context, snapshot) {
      if (snapshot.hasData &&
          (_introPlayed || MediaQuery.disableAnimationsOf(context))) {
        final media = MediaQueryData.fromView(View.of(context));
        return ColoredBox(
          color: media.platformBrightness == Brightness.dark
              ? Colors.black
              : Colors.white,
          child: TweenAnimationBuilder<double>(
            tween: Tween(begin: 0, end: 1),
            duration: media.disableAnimations
                ? Duration.zero
                : SegmerisMotion.medium,
            curve: SegmerisMotion.standard,
            child: SegmerisApp(initialSettings: snapshot.requireData),
            builder: (context, opacity, child) =>
                Opacity(opacity: opacity, child: child),
          ),
        );
      }
      return MaterialApp(
        debugShowCheckedModeBanner: false,
        themeMode: ThemeMode.system,
        theme: buildAppTheme(appThemeProfiles.first, Brightness.light),
        darkTheme: buildAppTheme(appThemeProfiles.first, Brightness.dark),
        home: snapshot.hasError
            ? Scaffold(
                body: SafeArea(
                  child: Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 560),
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(Icons.error_outline_rounded, size: 48),
                            const SizedBox(height: 16),
                            const Text(
                              'Segmeris 初始化失败 / Initialization failed',
                            ),
                            const SizedBox(height: 12),
                            SelectableText('${snapshot.error}'),
                            const SizedBox(height: 24),
                            FilledButton.icon(
                              onPressed: () => setState(
                                () => _initialization = widget.initialize(),
                              ),
                              icon: const Icon(Icons.refresh_rounded),
                              label: const Text('重试 / Retry'),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              )
            : const StartupMotion(ready: false, child: SizedBox.shrink()),
      );
    },
  );
}

class _SegmerisScrollBehavior extends MaterialScrollBehavior {
  const _SegmerisScrollBehavior();

  @override
  ScrollPhysics getScrollPhysics(BuildContext context) {
    return const BouncingScrollPhysics(parent: AlwaysScrollableScrollPhysics());
  }
}

class SegmerisApp extends StatefulWidget {
  const SegmerisApp({super.key, required this.initialSettings});

  final AppSettings initialSettings;

  @override
  State<SegmerisApp> createState() => _SegmerisAppState();
}

class _SegmerisAppState extends State<SegmerisApp> {
  late AppSettings _settings = widget.initialSettings;
  final _settingsWrites = AppSettingsSaveQueue();
  AppUpdateController? _updates;

  @override
  void initState() {
    super.initState();
    unawaited(_initializeUpdates());
  }

  Future<void> _initializeUpdates() async {
    try {
      final updates = await AppUpdateController.create();
      if (!mounted) {
        updates.dispose();
        return;
      }
      setState(() => _updates = updates);
      await updates.check();
    } catch (error) {
      debugPrint('Update checker initialization failed: $error');
    }
  }

  @override
  void dispose() {
    _updates?.dispose();
    super.dispose();
  }

  (String, AppFont, ColorScheme?, ColorScheme?)? _themeInputs;
  late ThemeData _lightTheme;
  late ThemeData _darkTheme;

  Future<void> _updateSettings(AppSettings next) async {
    setState(() => _settings = next);
    try {
      await _settingsWrites.enqueue(next);
    } catch (error, stack) {
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: error,
          stack: stack,
          library: 'Segmeris settings',
          context: ErrorDescription('while persisting application settings'),
        ),
      );
    }
  }

  void _cacheThemes(ColorScheme? lightDynamic, ColorScheme? darkDynamic) {
    final inputs = (
      _settings.themeProfileId,
      _settings.font,
      lightDynamic,
      darkDynamic,
    );
    if (_themeInputs == inputs) return;
    _themeInputs = inputs;
    _lightTheme = buildAppTheme(
      _settings.themeProfile,
      Brightness.light,
      font: _settings.font,
      dynamicScheme: lightDynamic,
    );
    _darkTheme = buildAppTheme(
      _settings.themeProfile,
      Brightness.dark,
      font: _settings.font,
      dynamicScheme: darkDynamic,
    );
  }

  @override
  Widget build(BuildContext context) {
    // Above MaterialApp, explicitly expose the View's accessibility settings so
    // reduced motion also governs the root AnimatedTheme.
    return MediaQuery.fromView(
      view: View.of(context),
      child: Builder(
        builder: (context) {
          return DynamicColorBuilder(
            builder: (lightDynamic, darkDynamic) {
              _cacheThemes(lightDynamic, darkDynamic);
              final locale = AppLocalizations.resolveLocale(_settings.locale);
              return MaterialApp(
                debugShowCheckedModeBanner: false,
                title: 'Segmeris',
                scrollBehavior: const _SegmerisScrollBehavior(),
                locale: locale,
                localeResolutionCallback: (deviceLocale, _) =>
                    AppLocalizations.resolveLocale(deviceLocale),
                supportedLocales: AppLocalizations.supportedLocales,
                localizationsDelegates: const [
                  AppLocalizations.delegate,
                  ...GlobalMaterialLocalizations.delegates,
                ],
                themeMode: _settings.themeMode,
                themeAnimationDuration: SegmerisMotion.duration(
                  context,
                  SegmerisMotion.theme,
                ),
                themeAnimationCurve: SegmerisMotion.standard,
                theme: _lightTheme,
                darkTheme: _darkTheme,
                builder: (context, child) {
                  final activeLocale =
                      Localizations.maybeLocaleOf(context) ?? locale;
                  return Directionality(
                    textDirection: AppLocalizations.textDirectionOf(
                      activeLocale,
                    ),
                    child: child ?? const SizedBox.shrink(),
                  );
                },
                home: HomePage(
                  updateController: _updates,
                  settings: _settings,
                  onSettingsChanged: _updateSettings,
                ),
              );
            },
          );
        },
      ),
    );
  }
}
