import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import '../utils/playlist_user_agent.dart';

/// Redirects create a new native request and may drop its User-Agent header.
/// A client-scoped default preserves the override across every redirect without
/// changing other playlists, global HTTP behaviour or credential-forwarding rules.
http.Client playlistHttpClient(String? userAgent) {
  final agent = normalizePlaylistUserAgent(userAgent);
  if (agent.isEmpty) return http.Client();
  return IOClient(HttpClient()..userAgent = agent);
}
