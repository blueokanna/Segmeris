import 'package:flutter/material.dart';
import 'package:segmeris/src/app/app_localizations.dart';
import 'package:segmeris/src/app/app_theme.dart';
import 'package:segmeris/src/home/home_widgets.dart';
import 'package:segmeris/src/home/subtitle_preference.dart';
import 'package:segmeris/src/rust/api/downloader.dart';

class HomeCandidatesCard extends StatelessWidget {
  const HomeCandidatesCard({
    super.key,
    required this.inspection,
    required this.selectedCandidate,
    required this.subtitlePreference,
    required this.running,
    required this.analyzing,
    required this.selectionRevision,
    required this.onCandidateSelected,
    required this.onSubtitlePreferenceChanged,
    required this.onOpenAuthBrowser,
    required this.onQrLogin,
  });

  final MediaInspectionResult? inspection;
  final MediaCandidate? selectedCandidate;
  final SubtitlePreference subtitlePreference;
  final bool running;
  final bool analyzing;
  final int selectionRevision;
  final ValueChanged<MediaCandidate> onCandidateSelected;
  final ValueChanged<SubtitlePreference> onSubtitlePreferenceChanged;
  final VoidCallback onOpenAuthBrowser;
  final VoidCallback onQrLogin;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final t = Theme.of(context);
    final cs = t.colorScheme;

    return SectionCard(
      title: l.text('analysis_results'),
      subtitle: inspection == null
          ? l.text('no_candidates')
          : '${inspection!.pageTitle} · ${inspection!.candidates.length}',
      icon: Icons.video_collection_outlined,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (inspection?.warnings.isNotEmpty ?? false)
            Padding(
              padding: const EdgeInsets.only(bottom: 14),
              child: Column(
                children: [
                  for (final warning in inspection!.warnings) ...[
                    InspectionWarningTile(warning: warning),
                    const SizedBox(height: 10),
                  ],
                ],
              ),
            ),
          if (inspection?.subtitles.isNotEmpty ?? false)
            Padding(
              padding: const EdgeInsets.only(bottom: 14),
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  borderRadius: SegmerisShapes.of(context).md,
                  color: cs.surfaceContainerHigh.withValues(alpha: 0.55),
                  border: Border.all(
                    color: cs.outlineVariant.withValues(alpha: 0.4),
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(
                          Icons.subtitles_outlined,
                          size: 18,
                          color: cs.onSurfaceVariant,
                        ),
                        const SizedBox(width: 8),
                        Text(
                          l.text('subtitles'),
                          style: t.textTheme.labelLarge?.copyWith(
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        _SubtitleChoicePill(
                          label: l.text('subtitle_auto'),
                          selected:
                              subtitlePreference is SubtitleAutoPreference,
                          onTap: () => onSubtitlePreferenceChanged(
                            const SubtitleAutoPreference(),
                          ),
                        ),
                        for (final track in inspection!.subtitles)
                          _SubtitleChoicePill(
                            label: track.label.isNotEmpty
                                ? track.label
                                : (track.language.isNotEmpty
                                    ? track.language
                                    : l.text('subtitles')),
                            tag: track.selected && track.label.isNotEmpty
                                ? l.text('subtitle_default')
                                : null,
                            selected:
                                subtitlePreference is SubtitleTrackPreference &&
                                    subtitlePreference ==
                                        SubtitleTrackPreference(track),
                            onTap: () => onSubtitlePreferenceChanged(
                              SubtitleTrackPreference(track),
                            ),
                          ),
                        _SubtitleChoicePill(
                          label: l.text('subtitle_off'),
                          selected: subtitlePreference is SubtitleOffPreference,
                          onTap: () => onSubtitlePreferenceChanged(
                            const SubtitleOffPreference(),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          if (inspection?.authRequired ?? false)
            Padding(
              padding: const EdgeInsets.only(bottom: 14),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 280),
                curve: Curves.easeOutCubic,
                width: double.infinity,
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  borderRadius: SegmerisShapes.of(context).md,
                  color: cs.errorContainer,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      l.text('auth_challenge_detected'),
                      style: t.textTheme.titleSmall?.copyWith(
                        color: cs.onErrorContainer,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      inspection!.challengeReason,
                      style: t.textTheme.bodyMedium?.copyWith(
                        color: cs.onErrorContainer,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      l.text('auth_challenge_help'),
                      style: t.textTheme.bodySmall?.copyWith(
                        color: cs.onErrorContainer,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 10,
                      runSpacing: 10,
                      children: [
                        FilledButton.icon(
                          onPressed: running || analyzing ? null : onQrLogin,
                          icon: const Icon(Icons.qr_code_2_rounded),
                          label: Text(l.text('qr_login_title')),
                        ),
                        FilledButton.tonalIcon(
                          onPressed:
                              running || analyzing ? null : onOpenAuthBrowser,
                          icon: const Icon(Icons.open_in_browser_rounded),
                          label: Text(l.text('auth_browser_open')),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          AnimatedSwitcher(
            duration: SegmerisMotion.slow,
            switchInCurve: SegmerisMotion.decelerate,
            switchOutCurve: SegmerisMotion.accelerate,
            transitionBuilder: segmerisFadeScaleTransition,
            child: selectedCandidate == null
                ? const SizedBox.shrink()
                : Container(
                    key: ValueKey(
                      'selection-$selectionRevision-${selectedCandidate!.id}',
                    ),
                    width: double.infinity,
                    margin: const EdgeInsets.only(bottom: 14),
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      borderRadius: SegmerisShapes.of(context).md,
                      color: cs.primaryContainer,
                      border: Border.all(
                        color: cs.primary.withValues(alpha: 0.35),
                      ),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          l.text('current_selection'),
                          style: t.textTheme.labelLarge?.copyWith(
                            color: cs.onPrimaryContainer,
                            fontWeight: FontWeight.w800,
                            letterSpacing: 0.2,
                          ),
                        ),
                        const SizedBox(height: 10),
                        Text(
                          selectedCandidate!.title,
                          style: t.textTheme.titleMedium?.copyWith(
                            color: cs.onPrimaryContainer,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        const SizedBox(height: 10),
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            StatusBadge(
                              label: selectedCandidate!.extractor,
                              color: cs.onPrimaryContainer,
                            ),
                            if (selectedCandidate!.qualityLabel.isNotEmpty)
                              StatusBadge(
                                label: selectedCandidate!.qualityLabel,
                                color: cs.onPrimaryContainer,
                              ),
                            if (selectedCandidate!.qualityBadge.isNotEmpty)
                              QualityBadgePill(
                                label: selectedCandidate!.qualityBadge,
                              ),
                            if (selectedCandidate!.codec.isNotEmpty)
                              StatusBadge(
                                label: selectedCandidate!.codec,
                                color: cs.onPrimaryContainer,
                              ),
                            if (selectedCandidate!.audioUrl != null)
                              StatusBadge(
                                label: l.text('separate_audio'),
                                color: cs.onPrimaryContainer,
                              ),
                          ],
                        ),
                      ],
                    ),
                  ),
          ),
          AnimatedSwitcher(
            duration: SegmerisMotion.slow,
            switchInCurve: SegmerisMotion.decelerate,
            switchOutCurve: SegmerisMotion.accelerate,
            transitionBuilder: segmerisFadeScaleTransition,
            child: inspection == null || inspection!.candidates.isEmpty
                ? Container(
                    key: const ValueKey('empty-candidates'),
                    width: double.infinity,
                    padding: const EdgeInsets.all(20),
                    decoration: BoxDecoration(
                      borderRadius: SegmerisShapes.of(context).md,
                      color: cs.surfaceContainerHigh.withValues(alpha: 0.55),
                    ),
                    child: Text(
                      l.text('no_candidates'),
                      style: t.textTheme.bodyMedium?.copyWith(
                        color: cs.onSurfaceVariant,
                      ),
                    ),
                  )
                : Column(
                    key: ValueKey(
                      'candidate-list-${inspection!.candidates.length}',
                    ),
                    children: [
                      for (final entry in inspection!.candidates.indexed)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 10),
                          child: RevealMotion(
                            key: ValueKey(entry.$2.id),
                            delay: Duration(milliseconds: 28 * entry.$1),
                            child: CandidateTile(
                              candidate: entry.$2,
                              selected: selectedCandidate?.id == entry.$2.id,
                              onTap: () => onCandidateSelected(entry.$2),
                            ),
                          ),
                        ),
                    ],
                  ),
          ),
        ],
      ),
    );
  }
}

/// One selectable subtitle option: the episode default, a concrete track,
/// or "no subtitles". A pill group instead of a dropdown — the track count
/// is tiny and the current choice is worth showing at a glance.
class _SubtitleChoicePill extends StatelessWidget {
  const _SubtitleChoicePill({
    required this.label,
    required this.selected,
    required this.onTap,
    this.tag,
  });

  final String label;
  final String? tag;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final cs = t.colorScheme;
    final shapes = SegmerisShapes.of(context);
    return Semantics(
      selected: selected,
      button: true,
      child: Material(
        color: Colors.transparent,
        borderRadius: shapes.pill,
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: AnimatedContainer(
            duration: SegmerisMotion.fast,
            curve: SegmerisMotion.emphasized,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
            decoration: BoxDecoration(
              borderRadius: shapes.pill,
              color:
                  selected ? cs.primaryContainer : cs.surfaceContainerHighest,
              border: Border.all(
                color: selected
                    ? cs.primary.withValues(alpha: 0.45)
                    : cs.outlineVariant.withValues(alpha: 0.3),
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                AnimatedSwitcher(
                  duration: SegmerisMotion.fast,
                  transitionBuilder: segmerisFadeScaleTransition,
                  child: selected
                      ? Icon(
                          Icons.check_circle_rounded,
                          key: const ValueKey('subtitle-selected'),
                          size: 14,
                          color: cs.onPrimaryContainer,
                        )
                      : const SizedBox(
                          key: ValueKey('subtitle-unselected'),
                          width: 0,
                        ),
                ),
                if (selected) const SizedBox(width: 6),
                Text(
                  label,
                  style: t.textTheme.labelMedium?.copyWith(
                    color: selected ? cs.onPrimaryContainer : cs.onSurface,
                    fontWeight: selected ? FontWeight.w800 : FontWeight.w600,
                  ),
                ),
                if (tag != null) ...[
                  const SizedBox(width: 6),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 1,
                    ),
                    decoration: BoxDecoration(
                      borderRadius: shapes.xs,
                      color: cs.surfaceContainerHighest,
                    ),
                    child: Text(
                      tag!,
                      style: t.textTheme.labelSmall?.copyWith(
                        color: cs.onSurfaceVariant,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
