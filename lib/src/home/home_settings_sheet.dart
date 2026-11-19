import 'package:flutter/gestures.dart';
import 'package:material_ui/material_ui.dart';
import 'package:segmeris/src/app/app_localizations.dart';
import 'package:segmeris/src/app/app_settings.dart';
import 'package:segmeris/src/app/app_theme.dart';
import 'package:segmeris/src/app/app_update.dart';
import 'package:segmeris/src/app/app_update_widgets.dart';
import 'package:segmeris/src/app/platform_utils.dart';
import 'package:segmeris/src/app/runtime_capabilities.dart';
import 'package:segmeris/src/home/auth_context_editor.dart';
import 'package:segmeris/src/home/home_widgets.dart';
import 'package:segmeris/src/rust/api/downloader.dart';

class HomeSettingsSheet extends StatefulWidget {
  const HomeSettingsSheet({
    super.key,
    required this.settings,
    required this.onSettingsChanged,
    required this.onOpenBrowser,
    required this.onQrLogin,
    required this.onClearContext,
    required this.authContextListenable,
    required this.authContextBadges,
    required this.hasAuthContextOverrides,
    required this.userAgentController,
    required this.refererController,
    required this.originController,
    required this.cookieController,
    required this.headersController,
    this.inspection,
    this.enabled = true,
    this.capabilityProbe = RuntimeCapabilityProbe.inspect,
    this.updateController,
  });

  final AppSettings settings;
  final AppUpdateController? updateController;
  final ValueChanged<AppSettings> onSettingsChanged;
  final Future<void> Function() onOpenBrowser;
  final Future<void> Function() onQrLogin;
  final VoidCallback onClearContext;
  final Listenable authContextListenable;
  final List<String> Function() authContextBadges;
  final bool Function() hasAuthContextOverrides;
  final TextEditingController userAgentController;
  final TextEditingController refererController;
  final TextEditingController originController;
  final TextEditingController cookieController;
  final TextEditingController headersController;
  final MediaInspectionResult? inspection;

  /// Locks connection/auth edits during downloads; appearance remains available.
  final bool enabled;
  final Future<PlatformCapabilitySnapshot> Function() capabilityProbe;

  @override
  State<HomeSettingsSheet> createState() => _HomeSettingsSheetState();
}

class _HomeSettingsSheetState extends State<HomeSettingsSheet> {
  final _themeScroll = ScrollController();
  late AppSettings _draft = widget.settings;
  late final Future<PlatformCapabilitySnapshot> _capabilities = widget
      .capabilityProbe();
  late final TextEditingController _apiUrlCtrl = TextEditingController(
    text: widget.settings.apiBaseUrl,
  );
  late final TextEditingController _apiTokenCtrl = TextEditingController(
    text: widget.settings.apiToken,
  );

  @override
  void dispose() {
    _themeScroll.dispose();
    _apiUrlCtrl.dispose();
    _apiTokenCtrl.dispose();
    super.dispose();
  }

  void _pageThemes(int direction) {
    if (!_themeScroll.hasClients) return;
    final position = _themeScroll.position;
    final target =
        (position.pixels + direction * position.viewportDimension * .8).clamp(
          position.minScrollExtent,
          position.maxScrollExtent,
        );
    final duration = SegmerisMotion.duration(context, SegmerisMotion.fast);
    if (duration == Duration.zero) {
      _themeScroll.jumpTo(target);
    } else {
      _themeScroll.animateTo(
        target,
        duration: duration,
        curve: SegmerisMotion.standard,
      );
    }
  }

  void _scrollThemes(PointerSignalEvent event) {
    if (event is! PointerScrollEvent || !_themeScroll.hasClients) return;
    final delta = event.scrollDelta.dx != 0
        ? event.scrollDelta.dx
        : event.scrollDelta.dy;
    final position = _themeScroll.position;
    final target = (position.pixels + delta).clamp(
      position.minScrollExtent,
      position.maxScrollExtent,
    );
    if (target == position.pixels) return;
    GestureBinding.instance.pointerSignalResolver.register(event, (_) {
      if (_themeScroll.hasClients) _themeScroll.jumpTo(target);
    });
  }

  void _updateDraft(AppSettings next) {
    setState(() => _draft = next);
    widget.onSettingsChanged(next);
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final t = Theme.of(context);
    final mode = _draft.themeMode;
    final profile = _draft.themeProfile;
    final locale = _draft.locale;

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 32),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              l.text('appearance'),
              style: t.textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 18),
            DisplayPreviewCard(
              profile: profile,
              mode: mode,
              localeLabel: l.localeLabel(locale),
              font: _draft.font,
            ),
            const SizedBox(height: 18),
            RuntimeCapabilitiesPanel(capabilities: _capabilities),
            if (widget.updateController case final updates?) ...[
              const SizedBox(height: 16),
              AppUpdateCard(controller: updates, alwaysVisible: true),
            ],
            if (SegmerisPlatform.isWeb) ...[
              const SizedBox(height: 18),
              Text(l.text('api_base_url'), style: t.textTheme.labelLarge),
              const SizedBox(height: 10),
              TextField(
                controller: _apiUrlCtrl,
                enabled: widget.enabled,
                keyboardType: TextInputType.url,
                autocorrect: false,
                decoration: InputDecoration(
                  hintText: 'http://localhost:3000',
                  helperText: l.text('api_base_url_hint'),
                ),
                onChanged: (value) {
                  final trimmed = value.trim();
                  if (trimmed.isNotEmpty && trimmed != _draft.apiBaseUrl) {
                    _updateDraft(_draft.copyWith(apiBaseUrl: trimmed));
                  }
                },
              ),
              const SizedBox(height: 14),
              TextField(
                controller: _apiTokenCtrl,
                enabled: widget.enabled,
                autocorrect: false,
                obscureText: true,
                decoration: InputDecoration(
                  hintText: 'Bearer token',
                  helperText: l.text('api_token_hint'),
                ),
                onChanged: (value) {
                  final trimmed = value.trim();
                  if (trimmed != _draft.apiToken) {
                    _updateDraft(_draft.copyWith(apiToken: trimmed));
                  }
                },
              ),
            ],
            const SizedBox(height: 18),
            Text(l.text('mode'), style: t.textTheme.labelLarge),
            const SizedBox(height: 10),
            LayoutBuilder(
              builder: (context, constraints) => SegmentedButton<ThemeMode>(
                direction:
                    constraints.maxWidth < 320 ||
                        (constraints.maxWidth < 600 &&
                            MediaQuery.textScalerOf(context).scale(14) > 18)
                    ? Axis.vertical
                    : Axis.horizontal,
                selected: {mode},
                onSelectionChanged: (selection) =>
                    _updateDraft(_draft.copyWith(themeMode: selection.first)),
                segments: [
                  ButtonSegment(
                    value: ThemeMode.system,
                    label: Text(l.text('system')),
                    icon: const Icon(Icons.brightness_auto),
                  ),
                  ButtonSegment(
                    value: ThemeMode.light,
                    label: Text(l.text('light')),
                    icon: const Icon(Icons.light_mode),
                  ),
                  ButtonSegment(
                    value: ThemeMode.dark,
                    label: Text(l.text('dark')),
                    icon: const Icon(Icons.dark_mode),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 20),
            Row(
              children: [
                Expanded(
                  child: Text(l.text('theme'), style: t.textTheme.labelLarge),
                ),
                IconButton.filledTonal(
                  key: const ValueKey('theme-previous'),
                  tooltip: MaterialLocalizations.of(context)
                      .previousPageTooltip,
                  onPressed: () => _pageThemes(-1),
                  icon: const Icon(Icons.chevron_left_rounded),
                ),
                const SizedBox(width: 8),
                IconButton.filledTonal(
                  key: const ValueKey('theme-next'),
                  tooltip: MaterialLocalizations.of(context).nextPageTooltip,
                  onPressed: () => _pageThemes(1),
                  icon: const Icon(Icons.chevron_right_rounded),
                ),
              ],
            ),
            const SizedBox(height: 10),
            SizedBox(
              height:
                  186.0 +
                  (MediaQuery.textScalerOf(context).scale(14) - 14).clamp(
                        0,
                        double.infinity,
                      ) *
                      4,
              child: Listener(
                onPointerSignal: _scrollThemes,
                child: ScrollConfiguration(
                  behavior: ScrollConfiguration.of(context).copyWith(
                    dragDevices: PointerDeviceKind.values.toSet(),
                    scrollbars: false,
                  ),
                  child: Scrollbar(
                    controller: _themeScroll,
                    thumbVisibility: true,
                    trackVisibility: true,
                    child: ListView.separated(
                      key: const ValueKey('theme-palette-scroll'),
                      controller: _themeScroll,
                      padding: const EdgeInsets.only(bottom: 14),
                      scrollDirection: Axis.horizontal,
                      itemCount: appThemeProfiles.length,
                      separatorBuilder: (_, _) => const SizedBox(width: 12),
                      itemBuilder: (context, index) {
                        final item = appThemeProfiles[index];
                        return ThemePaletteCard(
                          profile: item,
                          selected: profile.id == item.id,
                          onTap: () => _updateDraft(
                            _draft.copyWith(themeProfileId: item.id),
                          ),
                        );
                      },
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 20),
            KeyedSubtree(
              key: ValueKey(('font-labels', Localizations.localeOf(context))),
              child: DropdownMenu<AppFont>(
                key: const ValueKey('settings-font'),
                initialSelection: _draft.font,
                expandedInsets: EdgeInsets.zero,
                label: Text(l.text('font')),
                onSelected: (value) {
                  if (value != null) _updateDraft(_draft.copyWith(font: value));
                },
                dropdownMenuEntries: [
                  DropdownMenuEntry(
                    value: AppFont.system,
                    label: l.text('font_system'),
                  ),
                  DropdownMenuEntry(
                    value: AppFont.harmonyGoogle,
                    label: l.text('font_harmony_google'),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 10),
            Text(l.text('font_license_notice'), style: t.textTheme.bodySmall),
            TextButton.icon(
              onPressed: () => showLicensePage(
                context: context,
                applicationName: 'Segmeris',
              ),
              icon: const Icon(Icons.info_outline_rounded),
              label: Text(MaterialLocalizations.of(context).licensesPageTitle),
            ),
            const SizedBox(height: 20),
            DropdownMenu<Locale>(
              initialSelection: locale,
              expandedInsets: EdgeInsets.zero,
              label: Text(l.text('language')),
              onSelected: (value) {
                if (value != null) {
                  _updateDraft(
                    _draft.copyWith(
                      localeTag: AppSettings.serializeLocale(value),
                    ),
                  );
                }
              },
              dropdownMenuEntries: [
                for (final item in AppLocalizations.supportedLocales)
                  DropdownMenuEntry(value: item, label: l.localeLabel(item)),
              ],
            ),
            const SizedBox(height: 20),
            KeyedSubtree(
              key: ValueKey((
                'retention-labels',
                Localizations.localeOf(context),
              )),
              child: DropdownMenu<int>(
                key: const ValueKey('settings-history-retention'),
                initialSelection: AppSettings.normalizeHistoryRetentionDays(
                  _draft.historyRetentionDays,
                ),
                expandedInsets: EdgeInsets.zero,
                menuHeight: 320,
                label: Text(l.text('history_retention')),
                onSelected: (value) {
                  if (value != null) {
                    _updateDraft(_draft.copyWith(historyRetentionDays: value));
                  }
                },
                dropdownMenuEntries: [
                  for (final days in AppSettings.allowedHistoryRetentionDays)
                    DropdownMenuEntry(
                      value: days,
                      label: days == 0
                          ? l.text('history_retention_never')
                          : l
                                .text('history_retention_days')
                                .replaceAll('{days}', '$days'),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 10),
            Text(
              l.text('history_retention_hint'),
              style: t.textTheme.bodySmall,
            ),
            const SizedBox(height: 20),
            AuthorizationSettingsPanel(
              enabled: widget.enabled,
              autoOpenAuthBrowser: _draft.autoOpenAuthBrowser,
              onAutoOpenChanged: widget.enabled
                  ? (value) => _updateDraft(
                      _draft.copyWith(autoOpenAuthBrowser: value),
                    )
                  : null,
              onOpenBrowser: widget.onOpenBrowser,
              onQrLogin: widget.onQrLogin,
              onClearContext: widget.onClearContext,
              authContextListenable: widget.authContextListenable,
              authContextBadges: widget.authContextBadges,
              hasAuthContextOverrides: widget.hasAuthContextOverrides,
              userAgentController: widget.userAgentController,
              refererController: widget.refererController,
              originController: widget.originController,
              cookieController: widget.cookieController,
              headersController: widget.headersController,
            ),
            if (widget.inspection?.authRequired ?? false) ...[
              const SizedBox(height: 18),
              InspectionWarningTile(
                warning:
                    '[auth:challenge] ${widget.inspection!.challengeReason}',
              ),
            ],
          ],
        ),
      ),
    );
  }
}
