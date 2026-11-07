/// User-supplied XMLTV feeds use separate IDs so they cannot overwrite another
/// guide's programmes. The fragment identifies local storage, not the request.
class CustomGuideSource {
  const CustomGuideSource(
      {required this.id,
      required this.name,
      required this.url,
      this.enabled = true});
  final String id, name, url;
  final bool enabled;
  String get sourceUrl =>
      Uri.parse(url).replace(fragment: 'iptv-app-custom-$id').toString();
  String get prefix => 'iptv-custom-$id:';
  CustomGuideSource withEnabled(bool value) =>
      CustomGuideSource(id: id, name: name, url: url, enabled: value);
  Map<String, dynamic> toJson() =>
      {'id': id, 'name': name, 'url': url, 'enabled': enabled};
  static CustomGuideSource? fromJson(Object? value) {
    if (value is! Map ||
        value['id'] is! String ||
        value['name'] is! String ||
        value['url'] is! String) {
      return null;
    }
    if (!RegExp(r'^[a-zA-Z0-9_-]+$').hasMatch(value['id'] as String)) {
      return null;
    }
    try {
      return CustomGuideSource(
          id: value['id'] as String,
          name: value['name'] as String,
          url: validateUrl(value['url'] as String),
          enabled: value['enabled'] != false);
    } on FormatException {
      return null;
    }
  }

  static String validateUrl(String value) {
    const invalid =
        FormatException('Enter a valid http:// or https:// XMLTV URL.');
    try {
      final uri = Uri.parse(value.trim());
      if (!['http', 'https'].contains(uri.scheme) ||
          uri.host.isEmpty ||
          RegExp(r'\s').hasMatch(value.trim()) ||
          uri.port < 1 ||
          uri.port > 65535) {
        throw invalid;
      }
      return uri.removeFragment().toString();
    } on FormatException {
      throw invalid;
    }
  }
}

String customGuideNamespace(String url) {
  final fragment = Uri.tryParse(url)?.fragment ?? '';
  final match =
      RegExp(r'^iptv-app-custom-([a-zA-Z0-9_-]+)$').firstMatch(fragment);
  return match == null ? '' : 'iptv-custom-${match[1]}:';
}
