import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:segmeris/src/app/app_localizations.dart';
import 'package:segmeris/src/app/app_theme.dart';
import 'package:segmeris/src/home/home_page_controller.dart';
import 'package:segmeris/src/home/home_widgets.dart';

class HomeDownloadTasksCard extends StatefulWidget {
  const HomeDownloadTasksCard({
    super.key,
    required this.tasks,
    required this.onRetry,
    this.onTogglePause,
    this.onRemove,
  });

  final List<HomeDownloadTask> tasks;
  final ValueChanged<String> onRetry;
  final ValueChanged<String>? onTogglePause;
  final ValueChanged<String>? onRemove;

  @override
  State<HomeDownloadTasksCard> createState() => _HomeDownloadTasksCardState();
}

class _HomeDownloadTasksCardState extends State<HomeDownloadTasksCard> {
  int _page = 0;

  @override
  Widget build(BuildContext context) {
    final tasks = widget.tasks;
    final pageCount = (tasks.length / 8).ceil().clamp(1, 1 << 30);
    final page = _page.clamp(0, pageCount - 1);
    final visibleTasks = tasks.skip(page * 8).take(8).toList();
    final l = AppLocalizations.of(context);
    final runningCount = tasks.where((task) => task.running).length;

    return SectionCard(
      title: l.text('active_downloads'),
      subtitle: '${l.text('running_downloads')}: $runningCount',
      icon: Icons.downloading_rounded,
      child: AnimatedSwitcher(
        duration: SegmerisMotion.duration(context, SegmerisMotion.slow),
        switchInCurve: SegmerisMotion.decelerate,
        switchOutCurve: SegmerisMotion.accelerate,
        transitionBuilder: segmerisFadeScaleTransition,
        child: tasks.isEmpty
            ? _EmptyDownloadTasks(key: const ValueKey('empty-download-tasks'))
            : Column(
                key: const ValueKey('download-tasks'),
                children: [
                  for (final entry in visibleTasks.indexed)
                    Padding(
                      key: ValueKey(entry.$2.id),
                      padding: EdgeInsets.only(
                        bottom: entry.$1 == tasks.length - 1 ? 0 : 10,
                      ),
                      child: RepaintBoundary(
                        child: _DownloadTaskTile(
                          task: entry.$2,
                          onRetry: widget.onRetry,
                          onTogglePause: widget.onTogglePause,
                          onRemove: widget.onRemove,
                        ),
                      ),
                    ),
                  if (pageCount > 1)
                    Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        IconButton(
                          tooltip: l.text('previous_page'),
                          onPressed: page == 0
                              ? null
                              : () => setState(() => _page = page - 1),
                          icon: const Icon(Icons.chevron_left_rounded),
                        ),
                        Text('${page + 1} / $pageCount'),
                        IconButton(
                          tooltip: l.text('next_page'),
                          onPressed: page + 1 >= pageCount
                              ? null
                              : () => setState(() => _page = page + 1),
                          icon: const Icon(Icons.chevron_right_rounded),
                        ),
                      ],
                    ),
                ],
              ),
      ),
    );
  }
}

class _EmptyDownloadTasks extends StatelessWidget {
  const _EmptyDownloadTasks({super.key});

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final t = Theme.of(context);
    final cs = t.colorScheme;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        borderRadius: SegmerisShapes.of(context).md,
        color: cs.surfaceContainerHigh.withValues(alpha: 0.48),
      ),
      child: Row(
        children: [
          Icon(Icons.download_for_offline_outlined, color: cs.onSurfaceVariant),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              l.text('no_active_downloads'),
              style: t.textTheme.bodyMedium?.copyWith(
                color: cs.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _DownloadTaskTile extends StatelessWidget {
  const _DownloadTaskTile({
    required this.task,
    required this.onRetry,
    this.onTogglePause,
    this.onRemove,
  });

  final HomeDownloadTask task;
  final ValueChanged<String> onRetry;
  final ValueChanged<String>? onTogglePause;
  final ValueChanged<String>? onRemove;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final t = Theme.of(context);
    final cs = t.colorScheme;
    final shapes = SegmerisShapes.of(context);
    final failed = task.error != null;
    final completed = task.resultPath != null && !failed;
    final (tone, foreground, icon) = failed
        ? (cs.errorContainer, cs.onErrorContainer, Icons.error_outline_rounded)
        : completed
        ? (
            cs.secondaryContainer,
            cs.onSecondaryContainer,
            Icons.check_circle_outline_rounded,
          )
        : (
            cs.primaryContainer.withValues(alpha: 0.74),
            cs.onPrimaryContainer,
            Icons.downloading_rounded,
          );

    return AnimatedContainer(
      duration: SegmerisMotion.duration(context, SegmerisMotion.medium),
      curve: SegmerisMotion.emphasized,
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        borderRadius: shapes.md,
        color: tone,
        border: Border.all(color: foreground.withValues(alpha: 0.08)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              StatusPulseDot(
                active: task.running && !task.paused,
                color: foreground,
                size: 10,
              ),
              const SizedBox(width: 10),
              Icon(icon, size: 18, color: foreground),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  task.fileName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: t.textTheme.titleSmall?.copyWith(
                    color: foreground,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 4,
                ),
                decoration: BoxDecoration(
                  borderRadius: shapes.pill,
                  color: foreground.withValues(alpha: 0.12),
                ),
                child: Text(
                  '${(task.progress.clamp(0.0, 1.0) * 100).round()}%',
                  style: t.textTheme.labelMedium?.copyWith(
                    color: foreground,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              if ((failed || task.interrupted) && !task.running)
                IconButton(
                  onPressed: () => onRetry(task.id),
                  icon: const Icon(Icons.refresh_rounded),
                  tooltip: l.text(
                    task.interrupted ? 'resume_download' : 'retry',
                  ),
                  visualDensity: VisualDensity.compact,
                  color: foreground,
                ),
            ],
          ),
          const SizedBox(height: 10),
          SmoothLinearProgressIndicator(
            value: task.progress,
            color: foreground,
            backgroundColor: foreground.withValues(alpha: 0.16),
          ),
          const SizedBox(height: 10),
          Text(
            task.interrupted
                ? l.text('download_interrupted')
                : task.paused
                ? l.text('download_paused')
                : task.status,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: t.textTheme.bodySmall?.copyWith(
              color: foreground.withValues(alpha: 0.9),
              height: 1.35,
            ),
          ),
          if (task.backend != null) ...[
            const SizedBox(height: 8),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  task.backend == 'yt-dlp'
                      ? Icons.hub_rounded
                      : Icons.memory_rounded,
                  size: 16,
                  color: foreground,
                ),
                const SizedBox(width: 6),
                Flexible(
                  child: Text(
                    task.backend!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: t.textTheme.labelMedium?.copyWith(
                      color: foreground,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
          ],
          Wrap(
            spacing: 8,
            children: [
              if (onRemove != null && !task.running)
                TextButton.icon(
                  onPressed: () => onRemove!(task.id),
                  icon: const Icon(Icons.delete_outline_rounded),
                  label: Text(
                    l.text(
                      completed ? 'delete_download_title' : 'remove_record',
                    ),
                  ),
                ),
              if (onTogglePause != null && task.canPause)
                TextButton.icon(
                  onPressed: task.controlBusy
                      ? null
                      : () => onTogglePause!(task.id),
                  icon: Icon(
                    task.paused
                        ? Icons.play_arrow_rounded
                        : Icons.pause_rounded,
                  ),
                  label: Text(
                    l.text(task.paused ? 'resume_download' : 'pause_download'),
                  ),
                ),
              TextButton.icon(
                onPressed: () async {
                  final urls = task.downloadUrls.isEmpty
                      ? [task.sourcePage]
                      : task.downloadUrls;
                  await Clipboard.setData(ClipboardData(text: urls.join('\n')));
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text(l.text('download_links_copied'))),
                    );
                  }
                },
                icon: const Icon(Icons.link_rounded),
                label: Text(l.text('copy_download_links')),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            task.resultPath ?? task.sourcePage,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: t.textTheme.bodySmall?.copyWith(
              color: foreground.withValues(alpha: 0.72),
            ),
          ),
        ],
      ),
    );
  }
}
