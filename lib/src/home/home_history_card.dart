import 'package:material_ui/material_ui.dart';
import 'package:segmeris/src/app/app_localizations.dart';
import 'package:segmeris/src/home/home_widgets.dart';

class HomeHistoryCard extends StatefulWidget {
  const HomeHistoryCard({super.key, required this.history, this.onDelete});
  final List<DownloadRecord> history;
  final ValueChanged<DownloadRecord>? onDelete;

  @override
  State<HomeHistoryCard> createState() => _HomeHistoryCardState();
}

class _HomeHistoryCardState extends State<HomeHistoryCard> {
  static const _pageSize = 8;
  int _page = 0;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final pageCount = (widget.history.length / _pageSize).ceil().clamp(
      1,
      1 << 30,
    );
    final page = _page.clamp(0, pageCount - 1);
    final records = widget.history.skip(page * _pageSize).take(_pageSize);
    return SectionCard(
      title: l.text('history'),
      subtitle: '${widget.history.length}',
      icon: Icons.history_rounded,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (widget.history.isEmpty)
            Text(l.text('no_history'), style: theme.textTheme.bodyMedium),
          for (final record in records)
            Padding(
              key: ValueKey(record.id),
              padding: const EdgeInsets.only(bottom: 8),
              child: ListTile(
                title: Text(
                  record.name,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: Text(
                  '${MaterialLocalizations.of(context).formatMediumDate(record.time)}\n${record.path}',
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                ),
                trailing: widget.onDelete == null
                    ? null
                    : IconButton(
                        tooltip: l.text('delete_download_title'),
                        onPressed: () => widget.onDelete!(record),
                        icon: const Icon(Icons.delete_outline_rounded),
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
                Text(
                  '${page + 1} / $pageCount',
                  style: theme.textTheme.labelLarge,
                ),
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
    );
  }
}
