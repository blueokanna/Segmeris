import 'package:dynamic_color/dynamic_color.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:segmeris/src/app/app_localizations.dart';
import 'package:segmeris/src/app/app_settings.dart';
import 'package:segmeris/src/app/app_theme.dart';
import 'package:segmeris/src/app/platform_bridge.dart';
import 'package:segmeris/src/home/home_page.dart';
import 'package:segmeris/src/rust/frb_generated.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await MediaStoreBridge.requestPermissions();
  final settings = await AppSettings.load();
  if (!kIsWeb) {
    try {
      await RustLib.init();
    } catch (error) {
      debugPrint('RustLib.init() failed: $error');
    }
  }
  runApp(SegmerisApp(initialSettings: settings));
}

class _SegmerisScrollBehavior extends MaterialScrollBehavior {
  const _SegmerisScrollBehavior();

  @override
  ScrollPhysics getScrollPhysics(BuildContext context) {
    return const BouncingScrollPhysics(
      parent: AlwaysScrollableScrollPhysics(),
    );
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

  Future<void> _updateSettings(AppSettings next) async {
    setState(() => _settings = next);
    await next.save();
  }

  @override
  Widget build(BuildContext context) {
    return DynamicColorBuilder(
      builder: (lightDynamic, darkDynamic) {
        final locale = AppLocalizations.resolveLocale(_settings.locale);
        return MaterialApp(
          debugShowCheckedModeBanner: false,
          title: 'Segmeris',
          scrollBehavior: const _SegmerisScrollBehavior(),
          locale: locale,
          localeResolutionCallback: (deviceLocale, _) {
            return AppLocalizations.resolveLocale(deviceLocale);
          },
          supportedLocales: AppLocalizations.supportedLocales,
          localizationsDelegates: const [
            AppLocalizations.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          themeMode: _settings.themeMode,
          themeAnimationDuration: const Duration(milliseconds: 420),
          themeAnimationCurve: Curves.easeInOutCubicEmphasized,
          theme: buildAppTheme(
            _settings.themeProfile,
            Brightness.light,
            dynamicScheme: lightDynamic,
          ),
          darkTheme: buildAppTheme(
            _settings.themeProfile,
            Brightness.dark,
            dynamicScheme: darkDynamic,
          ),
          builder: (context, child) {
            final activeLocale = Localizations.maybeLocaleOf(context) ?? locale;
            return Directionality(
              textDirection: AppLocalizations.textDirectionOf(activeLocale),
              child: child ?? const SizedBox.shrink(),
            );
          },
          home: HomePage(
            settings: _settings,
            onSettingsChanged: _updateSettings,
          ),
        );
      },
    );
  }
}
