/// Builds the XMLTV EPG URL for an Xtream Codes ("XC API") panel from a
/// server address, username, and password.
///
/// The playlist itself goes through the real `player_api.php` API
/// ([XtreamApiService]) rather than the `get.php` M3U export — many panels
/// disable that shortcut (it's a common anti-sharing measure) while
/// leaving `player_api.php` and `xmltv.php` active. EPG has no such
/// per-category API equivalent, so `xmltv.php` is still used there.
class XtreamHelper {
  static String buildEpgUrl({
    required String server,
    required String username,
    required String password,
  }) {
    final base = normalizeServer(server);
    final user = Uri.encodeQueryComponent(username);
    final pass = Uri.encodeQueryComponent(password);
    return '$base/xmltv.php?username=$user&password=$pass';
  }

  /// Accept a server or a copied XC endpoint while preserving panel subpaths.
  /// Explicit HTTPS is never downgraded or retried over HTTP.
  static String normalizeServer(String server) {
    const invalid = FormatException(
        'Enter a valid Xtream server URL, including the port if supplied.');
    var address = server.trim();
    if (address.isEmpty || RegExp(r'\s').hasMatch(address)) throw invalid;
    if (address.startsWith('//')) address = 'http:$address';
    if (!address.contains('://')) {
      if (RegExp(r'^https?:', caseSensitive: false).hasMatch(address)) {
        throw invalid;
      }
      address = 'http://$address';
    }
    try {
      final uri = Uri.parse(address);
      if (!const ['http', 'https'].contains(uri.scheme) ||
          uri.host.isEmpty ||
          uri.userInfo.isNotEmpty ||
          uri.port < 1 ||
          uri.port > 65535) {
        throw invalid;
      }
      final segments = uri.pathSegments.toList();
      while (segments.isNotEmpty && segments.last.isEmpty) {
        segments.removeLast();
      }
      if (segments.isNotEmpty &&
          const {'player_api.php', 'panel_api.php', 'get.php', 'xmltv.php'}
              .contains(segments.last.toLowerCase())) {
        segments.removeLast();
      }
      return Uri(
        scheme: uri.scheme,
        host: uri.host,
        port: uri.hasPort ? uri.port : null,
        pathSegments: segments,
      ).toString().replaceFirst(RegExp(r'/$'), '');
    } on FormatException {
      // Do not include the original URL: pasted links can contain credentials.
      throw invalid;
    }
  }
}
