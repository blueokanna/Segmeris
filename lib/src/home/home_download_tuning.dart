import 'package:flutter/material.dart';
import 'package:segmeris/src/app/app_localizations.dart';
import 'package:segmeris/src/app/app_theme.dart';
import 'package:segmeris/src/home/home_widgets.dart';

class HomeDownloadTuning extends StatefulWidget {
  const HomeDownloadTuning({
    super.key,
    required this.concurrencyController,
    required this.retriesController,
    required this.videoBitrateController,
    required this.audioBitrateController,
    required this.enabled,
    required this.keepTemp,
    required this.onKeepTempChanged,
  });

  final TextEditingController concurrencyController;
  final TextEditingController retriesController;
  final TextEditingController videoBitrateController;
  final TextEditingController audioBitrateController;
  final bool enabled;
  final bool keepTemp;
  final ValueChanged<bool> onKeepTempChanged;

  @override
  State<HomeDownloadTuning> createState() => _HomeDownloadTuningState();
}

class _HomeDownloadTuningState extends State<HomeDownloadTuning> {
  final _expansion = ExpansibleController();

  @override
  void dispose() {
    _expansion.dispose();
    super.dispose();
  }

  Widget _numberField({
    required TextEditingController controller,
    required String label,
    required int minimum,
    required int maximum,
    String? unit,
  }) {
    return TextFormField(
      controller: controller,
      enabled: widget.enabled,
      keyboardType: TextInputType.number,
      textInputAction: TextInputAction.next,
      decoration: InputDecoration(labelText: label, suffixText: unit),
      validator: (value) {
        final number = int.tryParse(value?.trim() ?? '');
        if (number != null && number >= minimum && number <= maximum) {
          return null;
        }
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && !_expansion.isExpanded) {
            _expansion.expand();
          }
        });
        return '$minimum–$maximum';
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final shape = RoundedRectangleBorder(
      borderRadius: SegmerisShapes.of(context).md,
    );
    return ExpansionTile(
      controller: _expansion,
      maintainState: true,
      backgroundColor: cs.surfaceContainer,
      collapsedBackgroundColor: cs.surfaceContainer,
      shape: shape,
      collapsedShape: shape,
      clipBehavior: Clip.antiAlias,
      leading: const Icon(Icons.tune_rounded),
      title: Text(
        l.text('download_options'),
        style: theme.textTheme.titleSmall,
      ),
      tilePadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      childrenPadding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      expansionAnimationStyle: AnimationStyle(
        duration: SegmerisMotion.duration(context, SegmerisMotion.medium),
        curve: SegmerisMotion.emphasized,
      ),
      children: [
        LayoutBuilder(
          builder: (context, constraints) {
            final columns =
                constraints.maxWidth >=
                    420 * (MediaQuery.textScalerOf(context).scale(14) / 14)
                ? 2
                : 1;
            final width = (constraints.maxWidth - (columns - 1) * 12) / columns;
            final fields = [
              _numberField(
                controller: widget.concurrencyController,
                label: l.text('concurrency'),
                minimum: 1,
                maximum: 16,
              ),
              _numberField(
                controller: widget.retriesController,
                label: l.text('retries'),
                minimum: 1,
                maximum: 10,
              ),
              _numberField(
                controller: widget.videoBitrateController,
                label: l.text('video_bitrate'),
                minimum: 0,
                maximum: 20000,
                unit: 'kbps',
              ),
              _numberField(
                controller: widget.audioBitrateController,
                label: l.text('audio_bitrate'),
                minimum: 0,
                maximum: 512,
                unit: 'kbps',
              ),
            ];
            return Wrap(
              spacing: 12,
              runSpacing: 16,
              children: [
                for (final field in fields)
                  SizedBox(width: width, child: field),
              ],
            );
          },
        ),
        const SizedBox(height: 8),
        SwitchListTile(
          value: widget.keepTemp,
          contentPadding: EdgeInsets.zero,
          title: Text(l.text('keep_temp')),
          subtitle: Text(l.text('keep_temp_hint')),
          onChanged: widget.enabled ? widget.onKeepTempChanged : null,
        ),
      ],
    );
  }
}
