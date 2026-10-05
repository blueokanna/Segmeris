/// The page the embedded authorization browser should open.
///
/// Opening the media page itself is the wrong entry point: it is the page the
/// user is already looking at, it needs no session to be useful, and it is
/// built for a real browser — which is why a WebView can render it as a blank
/// document. The sign-in surface is what a session needs, so that is what gets
/// opened, with the address bar and the system-browser action available for
/// anything the mapping does not know.
String authEntryUrlFor(String pageUrl) {
  final uri = Uri.tryParse(pageUrl.trim());
  if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
    return pageUrl;
  }
  if (_isBilibiliHost(uri.host)) {
    // Bilibili's passport app: the sign-in surface for every Bilibili
    // product, and the host the session cookies are issued from.
    return 'https://passport.bilibili.com/login';
  }
  // Unknown site: its own origin is a page the user can navigate from, and
  // guessing a login path would land on a 404 more often than not.
  return Uri(
    scheme: uri.scheme,
    host: uri.host,
    port: uri.hasPort ? uri.port : null,
  ).toString();
}

bool _isBilibiliHost(String host) {
  final normalized = host.toLowerCase();
  for (final domain in const ['bilibili.com', 'b23.tv']) {
    if (normalized == domain || normalized.endsWith('.$domain')) {
      return true;
    }
  }
  return false;
}
