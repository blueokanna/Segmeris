import 'package:flutter/material.dart';
import 'package:segmeris/src/app/app_localizations.dart';
import 'package:segmeris/src/app/app_theme.dart';
import 'package:segmeris/src/home/home_widgets.dart';
import 'package:segmeris/src/rust/api/downloader.dart';

/// Episode picker and "download all" trigger for multi-episode sources:
/// multi-part uploads, uploader collections, bangumi seasons and channel
/// series. Tapping an episode re-analyzes that page; the download-all
/// button queues every available episode as its own task.
class HomeSeriesCard extends StatefulWidget {
  const HomeSeriesCard({
    super.key,
    required this.collection,
    required this.running,
    required this.analyzing,
    required this.onEntrySelected,
    required this.onDownloadAll,
  });

  final MediaCollection collection;
  final bool running;
  final bool analyzing;
  final ValueChanged<MediaCollectionEntry> onEntrySelected;
  final VoidCallback onDownloadAll;

  @override
  State<HomeSeriesCard> createState() => _HomeSeriesCardState();
}

class _HomeSeriesCardState extends State<HomeSeriesCard> {
  bool _listOpen = true;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final t = Theme.of(context);
    final cs = t.colorScheme;
    final shapes = SegmerisShapes.of(context);
    final collection = widget.collection;
    final entries = collection.entries;
    final enabled = !widget.running && !widget.analyzing;
    final downloadable =
        entries.where((entry) => entry.available && entry.pageUrl.isNotEmpty);

    return SectionCard(
      title: _kindLabel(l, collection.kind),
      subtitle:
          '${collection.title} · ${entries.length} ${l.text('episodes_unit')}',
      icon: Icons.playlist_play_rounded,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            borderRadius: shapes.md,
            onTap: entries.isEmpty
                ? null
                : () => setState(() => _listOpen = !_listOpen),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Row(
                children: [
                  Icon(
                    _listOpen
                        ? Icons.expand_less_rounded
                        : Icons.expand_more_rounded,
                    size: 20,
                    color: cs.onSurfaceVariant,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _currentEntryLabel(l, entries),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: t.textTheme.bodyMedium?.copyWith(
                        color: cs.onSurfaceVariant,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          AnimatedSize(
            duration: SegmerisMotion.medium,
            curve: SegmerisMotion.emphasized,
            alignment: Alignment.topCenter,
            child: _listOpen && entries.isNotEmpty
                ? ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 264),
                    child: ListView.builder(
                      shrinkWrap: true,
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      itemCount: entries.length,
                      itemBuilder: (context, index) => _EpisodeRow(
                        entry: entries[index],
                        enabled: enabled,
                        onTap: () => widget.onEntrySelected(entries[index]),
                      ),
                    ),
                  )
                : const SizedBox(width: double.infinity),
          ),
          if (entries.isNotEmpty) const SizedBox(height: 10),
          SizedBox(
            width: double.infinity,
            child: FilledButton.tonalIcon(
              onPressed: enabled && downloadable.isNotEmpty
                  ? widget.onDownloadAll
                  : null,
              icon: const Icon(Icons.download_for_offline_rounded),
              label: Text(
                '${l.text('download_all')} (${downloadable.length})',
              ),
            ),
          ),
        ],
      ),
    );
  }

  String _kindLabel(AppLocalizations l, String kind) {
    return switch (kind) {
      'parts' => l.text('series_kind_parts'),
      'pgc_season' => l.text('series_kind_bangumi'),
      'series' => l.text('series_kind_series'),
      _ => l.text('series_kind_collection'),
    };
  }

  String _currentEntryLabel(
    AppLocalizations l,
    List<MediaCollectionEntry> entries,
  ) {
    for (final entry in entries) {
      if (entry.current) {
        return entry.title.isEmpty ? '${entry.index}' : entry.title;
      }
    }
    return l.text('analysis_results');
  }
}

class _EpisodeRow extends StatelessWidget {
  const _EpisodeRow({
    required this.entry,
    required this.enabled,
    required this.onTap,
  });

  final MediaCollectionEntry entry;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final cs = t.colorScheme;
    final shapes = SegmerisShapes.of(context);
    final disabled = !entry.available || entry.pageUrl.isEmpty;
    final tappable = enabled && !disabled;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Material(
        color: entry.current
            ? cs.primaryContainer.withValues(alpha: 0.6)
            : Colors.transparent,
        borderRadius: shapes.sm,
        child: InkWell(
          borderRadius: shapes.sm,
          onTap: tappable ? onTap : null,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            child: Row(
              children: [
                Container(
                  width: 30,
                  height: 30,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: entry.current
                        ? cs.primary.withValues(alpha: 0.16)
                        : cs.surfaceContainerHigh,
                  ),
                  child: entry.current
                      ? Icon(Icons.play_arrow_rounded,
                          size: 18, color: cs.primary)
                      : Text(
                          '${entry.index}',
                          style: t.textTheme.labelSmall?.copyWith(
                            color: cs.onSurfaceVariant,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        entry.title.isEmpty ? '${entry.index}' : entry.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: t.textTheme.bodyMedium?.copyWith(
                          color: disabled
                              ? cs.onSurfaceVariant.withValues(alpha: 0.55)
                              : cs.onSurface,
                          fontWeight:
                              entry.current ? FontWeight.w700 : FontWeight.w500,
                        ),
                      ),
                      if (entry.durationSeconds > 0 ||
                          entry.unavailableReason.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 2),
                          child: Row(
                            children: [
                              if (entry.durationSeconds > 0)
                                Text(
                                  _formatDuration(entry.durationSeconds),
                                  style: t.textTheme.labelSmall?.copyWith(
                                    color: cs.onSurfaceVariant,
                                  ),
                                ),
                              if (entry.durationSeconds > 0 &&
                                  entry.unavailableReason.isNotEmpty)
                                const SizedBox(width: 8),
                              if (entry.unavailableReason.isNotEmpty)
                                Flexible(
                                  child: Text(
                                    entry.unavailableReason,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: t.textTheme.labelSmall?.copyWith(
                                      color: cs.tertiary,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        ),
                    ],
                  ),
                ),
                if (entry.current)
                  Icon(Icons.check_circle_rounded, size: 16, color: cs.primary),
              ],
            ),
          ),
        ),
      ),
    );
  }

  static String _formatDuration(double seconds) {
    final total = seconds.round();
    final hours = total ~/ 3600;
    final minutes = (total % 3600) ~/ 60;
    final secs = total % 60;
    final mm = minutes.toString().padLeft(2, '0');
    final ss = secs.toString().padLeft(2, '0');
    return hours > 0 ? '$hours:$mm:$ss' : '$minutes:$ss';
  }
}
