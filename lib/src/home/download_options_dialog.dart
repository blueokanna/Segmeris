import 'package:flutter/material.dart';

import 'package:segmeris/src/app/app_localizations.dart';
import 'package:segmeris/src/home/home_widgets.dart';
import 'package:segmeris/src/rust/api/downloader.dart';

/// Warning code the engine emits when the session can only reach a `试看`
/// preview fragment instead of the whole episode.
const previewOnlyWarningCode = 'bilibili-preview-only';

/// Whether an analysis reported that the server will only hand out a preview
/// fragment for this session (a membership / purchase / region gate).
///
/// The engine decides this from the API's own `is_preview` flag, so the UI can
/// state it plainly instead of leaving the user to wonder why a download came
/// out six minutes long.
bool inspectionOffersPreviewOnly(MediaInspectionResult inspection) =>
    inspection.warnings.any(
      (warning) => warning.contains(previewOnlyWarningCode),
    );

/// Ask which stream to download, returning the choice or `null` when the user
/// backs out.
///
/// The analysis already lists every stream the server is willing to hand this
/// session, so the decision belongs at the moment the download starts:
/// browsing the card can stay exploratory, but starting a download should say
/// what is about to be fetched — and when the only thing on offer is a preview
/// fragment, that must be impossible to miss.
Future<MediaCandidate?> showDownloadOptionsDialog(
  BuildContext context, {
  required MediaInspectionResult inspection,
  MediaCandidate? initial,
  VoidCallback? onOpenAuthBrowser,
  VoidCallback? onQrLogin,
}) {
  if (inspection.candidates.isEmpty) {
    return Future<MediaCandidate?>.value();
  }
  return showDialog<MediaCandidate>(
    context: context,
    builder: (context) => _DownloadOptionsDialog(
      inspection: inspection,
      initial: initial,
      onOpenAuthBrowser: onOpenAuthBrowser,
      onQrLogin: onQrLogin,
    ),
  );
}

class _DownloadOptionsDialog extends StatefulWidget {
  const _DownloadOptionsDialog({
    required this.inspection,
    required this.initial,
    required this.onOpenAuthBrowser,
    required this.onQrLogin,
  });

  final MediaInspectionResult inspection;
  final MediaCandidate? initial;
  final VoidCallback? onOpenAuthBrowser;
  final VoidCallback? onQrLogin;

  @override
  State<_DownloadOptionsDialog> createState() => _DownloadOptionsDialogState();
}

class _DownloadOptionsDialogState extends State<_DownloadOptionsDialog> {
  late MediaCandidate _selected;

  @override
  void initState() {
    super.initState();
    final candidates = widget.inspection.candidates;
    _selected = candidates.firstWhere(
      (candidate) => candidate.id == widget.initial?.id,
      orElse: () => candidates.first,
    );
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final t = Theme.of(context);
    final cs = t.colorScheme;
    final pageTitle = widget.inspection.pageTitle.trim();
    final previewOnly = inspectionOffersPreviewOnly(widget.inspection);

    return AlertDialog(
      title: Text(l.text('quality_dialog_title')),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 460),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (pageTitle.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Text(
                  pageTitle,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: t.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Text(
                l.text('quality_dialog_hint'),
                style: t.textTheme.bodySmall?.copyWith(
                  color: cs.onSurfaceVariant,
                ),
              ),
            ),
            Flexible(
              child: SingleChildScrollView(
                child: Column(
                  children: [
                    for (final candidate in widget.inspection.candidates)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 10),
                        child: CandidateTile(
                          candidate: candidate,
                          selected: candidate.id == _selected.id,
                          onTap: () => setState(() => _selected = candidate),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            if (previewOnly) ...[
              const SizedBox(height: 12),
              InspectionWarningTile(
                warning: widget.inspection.warnings.firstWhere(
                  (warning) => warning.contains(previewOnlyWarningCode),
                ),
              ),
              if (widget.onOpenAuthBrowser != null || widget.onQrLogin != null)
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    // The QR route needs no embedded browser, so it is the
                    // one offered first; the browser stays for sites whose
                    // login is not Bilibili.
                    if (widget.onQrLogin != null)
                      FilledButton.icon(
                        onPressed: () {
                          Navigator.of(context).pop();
                          widget.onQrLogin!();
                        },
                        icon: const Icon(Icons.qr_code_2_rounded, size: 18),
                        label: Text(l.text('qr_login_title')),
                      ),
                    if (widget.onOpenAuthBrowser != null)
                      TextButton.icon(
                        onPressed: () {
                          Navigator.of(context).pop();
                          widget.onOpenAuthBrowser!();
                        },
                        icon: const Icon(Icons.open_in_browser_rounded, size: 18),
                        label: Text(l.text('auth_browser_open')),
                      ),
                  ],
                ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l.text('cancel')),
        ),
        FilledButton.icon(
          onPressed: () => Navigator.of(context).pop(_selected),
          icon: const Icon(Icons.download_rounded, size: 18),
          label: Text(l.text('start_download')),
        ),
      ],
    );
  }
}
