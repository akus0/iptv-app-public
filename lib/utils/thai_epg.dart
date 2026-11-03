import '../models/channel.dart';

const thaiEpgUrl = 'https://iptv-epg.org/files/epg-th.xml.gz';
const thaiEpgSourceUrl = '$thaiEpgUrl#iptv-app-thai';
const thaiEpgPrefix = 'iptv-thai:';

const _thaiGuideAliases = {
  'TRUE4UTHAI': 'TRUE4U.th',
  'TRUE4U': 'TRUE4U.th',
  'TNN24THAI': 'TNN24.th',
  'TNN24': 'TNN24.th',
  'THAIRATHTHAI': 'TRATH.th',
  'THAIRATH': 'TRATH.th',
  'THAIRATH32': 'TRATH.th',
  'THAI8': 'CH8.th',
  'CH8THAI': 'CH8.th',
  'CH8': 'CH8.th',
  'GMMONETHAI': 'ONE.th',
  'GMMONE': 'ONE.th',
  'ONE31': 'ONE.th',
  'AMARINTVTHAI': 'AMARIN.th',
  'AMARINTV': 'AMARIN.th',
  'CARTOONNETWORK': 'CARTOONNET.th',
  'CNN': 'CNN.th',
  'TRUESPORTS2': 'TRUESPORT2.th',
  'TRUESPORT2': 'TRUESPORT2.th',
  'TRUESPORTS7': 'TRSP7.th',
  'TRUESPORT7': 'TRSP7.th',
};
final _thaiPrefix = RegExp(r'^TH\s*[:|\-]\s*', caseSensitive: false);
final _quality = RegExp(r'\b(?:HD|FHD|UHD|SD|HEVC|4K)\b', caseSensitive: false);
String? thaiEpgCandidate(Channel channel) {
  if (!_thaiPrefix.hasMatch(channel.name)) return null;
  final name = channel.name
      .replaceFirst(_thaiPrefix, '')
      .replaceAll(_quality, '')
      .toUpperCase()
      .replaceAll(RegExp(r'[^A-Z0-9]'), '');
  final id = _thaiGuideAliases[name];
  return id == null ? null : '$thaiEpgPrefix${id.toLowerCase()}';
}

bool isNonThaiEntryInThaiGroup(Channel channel) {
  final group = channel.group.toUpperCase();
  if (!group.contains('THAILAND') &&
      !group.startsWith('TH|') &&
      !group.startsWith('TH:')) {
    return false;
  }
  final name = channel.name.toUpperCase();
  if (RegExp(r'^(?:KH|LA)\s*[:|\-]').hasMatch(name)) return true;
  if (RegExp(r'\b(?:LAO|LAOS|KHMER|CAMBODIA|CAMBODIAN)\b|MVLAO')
      .hasMatch(name)) {
    return true;
  }
  final clean = name
      .replaceFirst(RegExp(r'^TH\s*[:|\-]\s*'), '')
      .replaceAll(_quality, '')
      .replaceAll(RegExp(r'[^A-Z0-9]'), '');
  return const {'BAYON', 'PNNTV'}.contains(clean);
}
