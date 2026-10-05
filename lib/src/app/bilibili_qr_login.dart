import 'dart:async';

import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:segmeris/src/app/app_localizations.dart';
import 'package:segmeris/src/rust/api/downloader.dart';

/// How often the login attempt is checked for a scan. Bilibili's own page
/// polls at about this rate; faster would only add requests, slower would make
/// the confirmation feel stuck.
const _pollInterval = Duration(seconds: 2);

/// What one poll means to the dialog. This is the contract between the engine's
/// `state` string (`waiting` / `scanned` / `confirmed` / `expired` / `failed`)
/// and the UI, so it lives outside the widget where it can be tested without a
/// running engine.
enum QrLoginOutcome { waiting, scanned, confirmed, expired, failed }

/// Map the engine's state string onto the dialog's outcome.
///
/// Anything unrecognised counts as a failure: silently ignoring a state this
/// build does not know is how a user ends up watching a spinner forever.
QrLoginOutcome qrLoginOutcomeFor(String state) => switch (state) {
  'waiting' => QrLoginOutcome.waiting,
  'scanned' => QrLoginOutcome.scanned,
  'confirmed' => QrLoginOutcome.confirmed,
  'expired' => QrLoginOutcome.expired,
  _ => QrLoginOutcome.failed,
};

/// Bilibili's own web login, rendered as a QR code and polled until the user
/// confirms it in the Bilibili app.
///
/// This exists because the session belongs to the account holder: the honest
/// way to reach a membership episode or a 4K tier is for the owner of that
/// account to log in, and the QR flow is exactly what the website itself
/// offers. Returns the session Cookie header on success, or `null` when the
/// user backs out or the attempt expires.
Future<String?> showBilibiliQrLoginDialog(
  BuildContext context, {
  required RequestContext requestContext,
}) {
  return showDialog<String>(
    context: context,
    barrierDismissible: false,
    builder: (context) =>
        _BilibiliQrLoginDialog(requestContext: requestContext),
  );
}

enum _QrPhase { loading, waiting, scanned, expired, failed }

class _BilibiliQrLoginDialog extends StatefulWidget {
  const _BilibiliQrLoginDialog({required this.requestContext});

  final RequestContext requestContext;

  @override
  State<_BilibiliQrLoginDialog> createState() => _BilibiliQrLoginDialogState();
}

class _BilibiliQrLoginDialogState extends State<_BilibiliQrLoginDialog> {
  Timer? _timer;
  _QrPhase _phase = _QrPhase.loading;
  String _scanUrl = '';
  String _message = '';
  String _key = '';
  String _attemptCookie = '';

  @override
  void initState() {
    super.initState();
    unawaited(_start());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _start() async {
    _timer?.cancel();
    setState(() {
      _phase = _QrPhase.loading;
      _scanUrl = '';
      _message = '';
    });
    try {
      final session = await bilibiliQrLoginStart(
        requestContext: widget.requestContext,
      );
      if (!mounted) return;
      setState(() {
        _scanUrl = session.url;
        _key = session.key;
        _attemptCookie = session.cookie;
        _phase = _QrPhase.waiting;
      });
      _timer = Timer.periodic(_pollInterval, (_) => unawaited(_poll()));
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _phase = _QrPhase.failed;
        _message = '$error';
      });
    }
  }

  Future<void> _poll() async {
    if (!mounted || _key.isEmpty) return;
    try {
      final result = await bilibiliQrLoginPoll(
        key: _key,
        cookie: _attemptCookie,
        requestContext: widget.requestContext,
      );
      if (!mounted) return;
      switch (qrLoginOutcomeFor(result.state)) {
        case QrLoginOutcome.waiting:
          setState(() => _phase = _QrPhase.waiting);
        case QrLoginOutcome.scanned:
          setState(() => _phase = _QrPhase.scanned);
        case QrLoginOutcome.confirmed:
          _timer?.cancel();
          Navigator.of(context).pop(result.cookie);
        case QrLoginOutcome.expired:
          _timer?.cancel();
          setState(() {
            _phase = _QrPhase.expired;
            _message = result.message;
          });
        case QrLoginOutcome.failed:
          _timer?.cancel();
          setState(() {
            _phase = _QrPhase.failed;
            _message = result.message.isEmpty
                ? AppLocalizations.of(context).text('qr_login_failed')
                : result.message;
          });
      }
    } catch (error) {
      if (!mounted) return;
      // A single poll failing is not a failed login: the network may blink.
      // The timer keeps running, and the dialog stays usable.
      setState(() => _message = '$error');
    }
  }

  String _statusText(AppLocalizations l) {
    switch (_phase) {
      case _QrPhase.loading:
        return l.text('qr_login_preparing');
      case _QrPhase.waiting:
        return l.text('qr_login_waiting');
      case _QrPhase.scanned:
        return l.text('qr_login_scanned');
      case _QrPhase.expired:
        return l.text('qr_login_expired');
      case _QrPhase.failed:
        return _message.isEmpty ? l.text('qr_login_failed') : _message;
    }
  }

  bool get _failed =>
      _phase == _QrPhase.failed || _phase == _QrPhase.expired;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final t = Theme.of(context);
    final cs = t.colorScheme;
    return AlertDialog(
      title: Text(l.text('qr_login_title')),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Text(
              l.text('qr_login_hint'),
              style: t.textTheme.bodySmall?.copyWith(
                color: cs.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(16),
              ),
              child: SizedBox(
                width: 220,
                height: 220,
                child: _scanUrl.isEmpty
                    ? Center(
                        child: _phase == _QrPhase.failed
                            ? Icon(Icons.error_outline, color: cs.error)
                            : const CircularProgressIndicator(),
                      )
                    : QrImageView(
                        key: const ValueKey('bilibili-qr'),
                        data: _scanUrl,
                        version: QrVersions.auto,
                        size: 220,
                        backgroundColor: Colors.white,
                        // A scan target on a phone screen is worthless if the
                        // quiet zone is cropped, so the error level stays high
                        // and the module stays centred.
                        errorCorrectionLevel: QrErrorCorrectLevel.M,
                      ),
              ),
            ),
            const SizedBox(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  _phase == _QrPhase.scanned
                      ? Icons.phone_iphone_rounded
                      : Icons.hourglass_empty_rounded,
                  size: 18,
                  color: cs.onSurfaceVariant,
                ),
                const SizedBox(width: 8),
                Flexible(
                  child: Text(
                    _statusText(l),
                    key: const ValueKey('bilibili-qr-status'),
                    textAlign: TextAlign.center,
                    style: t.textTheme.bodyMedium?.copyWith(
                      fontWeight: _phase == _QrPhase.scanned
                          ? FontWeight.w700
                          : FontWeight.w500,
                    ),
                  ),
                ),
              ],
            ),
            if (_message.isNotEmpty && !_failed) ...[
              const SizedBox(height: 8),
              Text(
                _message,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: t.textTheme.bodySmall?.copyWith(color: cs.error),
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
        if (_failed)
          FilledButton.tonalIcon(
            onPressed: _start,
            icon: const Icon(Icons.refresh_rounded, size: 18),
            label: Text(l.text('qr_login_retry')),
          ),
      ],
    );
  }
}
