/// Provider overrides are opt-in and bounded before reaching either HTTP stack.
const playlistUserAgentPresets = {
  'TiviMate': 'TiviMate',
  'IPTV Smarters Pro': 'IPTVSmartersPro',
  'VLC': 'VLC',
  'GSE Smart IPTV': 'GSESMARTIPTV',
};

String? playlistUserAgentError(String value) {
  if (value.length > 512) return 'Use 512 characters or fewer.';
  if (value.codeUnits.any((c) => c < 32 || c > 126)) {
    return 'Use a single line of plain text, without special control characters.';
  }
  return null;
}

String normalizePlaylistUserAgent(String? value) =>
    value == null || playlistUserAgentError(value) != null ? '' : value.trim();

Map<String, String> playlistUserAgentHeaders(String? value) {
  final agent = normalizePlaylistUserAgent(value);
  return agent.isEmpty ? const {} : Map.unmodifiable({'User-Agent': agent});
}

/// Apply only at request/player creation, never across the channel catalogue.
/// Preserve referer, portal cookies and other source-specific headers.
Map<String, String> withPlaylistUserAgent(
    Map<String, String> original, String agent) {
  if (agent.isEmpty) return original;
  return {
    for (final entry in original.entries)
      if (entry.key.toLowerCase() != 'user-agent') entry.key: entry.value,
    'User-Agent': agent,
  };
}
