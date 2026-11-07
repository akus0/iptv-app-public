/// Deliberately stricter than the manual channel-linking search: regional,
/// language, punctuation and quality qualifiers remain part of the identity.
String guideChannelNameKey(String name) =>
    name.trim().toLowerCase().replaceAll(_spaces, ' ');

final _spaces = RegExp(r'\s+');

/// Only requested, unambiguous directory names may extend an XMLTV ID filter.
/// Built in the parser worker, once per directory entry, not per programme.
class GuideChannelNameIndex {
  GuideChannelNameIndex(this.requested);
  final Set<String> requested;
  final Map<String, String?> _matches = {};
  final Set<String> ids = {};

  void add(String id, String name) {
    if (requested.isEmpty) return;
    final key = guideChannelNameKey(name);
    if (key.isEmpty || !requested.contains(key)) return;
    if (!_matches.containsKey(key)) {
      _matches[key] = id;
      ids.add(id);
    } else if (_matches[key] != id) {
      ids.remove(_matches[key]);
      _matches[key] = null;
    }
  }

  Map<String, String> get matches => {
        for (final entry in _matches.entries)
          if (entry.value != null) entry.key: entry.value!,
      };
}
