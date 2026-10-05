import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

/// Hand a URL to the system browser, keeping a copy on the clipboard.
///
/// The embedded browser is a convenience, not a guarantee: on some Android
/// builds a WebView paints nothing at all while reporting no error, and an
/// authorization page that never renders is a dead end inside the app. The
/// system browser is the documented way out, so the URL is copied *before*
/// the launch is attempted — if the platform refuses the intent, or the
/// device has no browser that accepts it, the user still holds the address.
///
/// Returns `true` when a browser took over the URL.
Future<bool> openInSystemBrowser(String url) async {
  final uri = Uri.tryParse(url.trim());
  if (uri == null || uri.host.isEmpty) {
    return false;
  }
  await Clipboard.setData(ClipboardData(text: uri.toString()));
  try {
    return await launchUrl(uri, mode: LaunchMode.externalApplication);
  } on PlatformException {
    return false;
  } on MissingPluginException {
    return false;
  }
}

/// Copy a URL to the clipboard, reporting whether it was usable at all.
Future<bool> copyLink(String url) async {
  final uri = Uri.tryParse(url.trim());
  if (uri == null || uri.host.isEmpty) {
    return false;
  }
  await Clipboard.setData(ClipboardData(text: uri.toString()));
  return true;
}
