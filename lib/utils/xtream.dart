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
    final base = _normalizeServer(server);
    final user = Uri.encodeQueryComponent(username);
    final pass = Uri.encodeQueryComponent(password);
    return '$base/xmltv.php?username=$user&password=$pass';
  }

  static String _normalizeServer(String server) {
    var s = server.trim();
    while (s.endsWith('/')) {
      s = s.substring(0, s.length - 1);
    }
    return s;
  }
}
