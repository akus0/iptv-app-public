import '../models/channel.dart';

class GuideEnrichmentSource {
  const GuideEnrichmentSource(this.country, this.label);
  final String country, label;
  String get url =>
      'https://iptv-epg.org/files/epg-$country.xml.gz#iptv-app-fill-$country';
  String get prefix => 'iptv-fill-$country:';
}

const guideEnrichmentSources = [
  GuideEnrichmentSource('au', 'Australia'),
  GuideEnrichmentSource('gb', 'United Kingdom'),
  GuideEnrichmentSource('ca', 'Canada'),
  GuideEnrichmentSource('us', 'United States'),
];
String guideEnrichmentNamespace(String url) {
  for (final source in guideEnrichmentSources) {
    if (source.url == url) return source.prefix;
  }
  return '';
}

class GuideEnrichmentMatch {
  const GuideEnrichmentMatch(this.country, this.primaryId, this.externalId);
  final String country, primaryId, externalId;
  String? get supplementalId =>
      externalId.isEmpty ? null : 'iptv-fill-$country:$externalId';
}

// Audited against the curated playlist and current public XMLTV listings.
// Exact country/name pairs only: never infer a numbered PPV feed, time shift,
// regional variant or unrelated channel from an existing (possibly wrong) ID.
const _matches = <String, GuideEnrichmentMatch>{
  'us:tennischannel':
      GuideEnrichmentMatch('us', 'tennischannel.us', 'tennischannel.us'),
  'us:tennischannel2':
      GuideEnrichmentMatch('us', 'tennischannel2.us', 'tennischannel2.us'),
  'us:tycsports': GuideEnrichmentMatch('us', 'tycsports.us', 'tycsports.us'),
  'us:willowsports':
      GuideEnrichmentMatch('us', 'willowsports.us', 'willowsports.us'),
  'us:glorykickboxing':
      GuideEnrichmentMatch('us', 'glorykickboxing.us', 'glorykickboxing.us'),
  'us:fightnetwork':
      GuideEnrichmentMatch('us', 'fightnetwork.us', 'fightnetwork.us'),
  'us:fueltv': GuideEnrichmentMatch('us', 'fueltv.us', 'fueltv.us'),
  'us:nextlevelsports':
      GuideEnrichmentMatch('us', 'nextlevelsports.us', 'nextlevelsports.us'),
  'us:racingamerica':
      GuideEnrichmentMatch('us', 'racingamerica.us', 'racingamerica.us'),
  'us:nhradragracing': GuideEnrichmentMatch('us', 'nhratv.us', 'nhratv.us'),
  'us:golfpass': GuideEnrichmentMatch('us', 'golfpass.us', 'golfpass.us'),
  'us:beinsportsxtraenespaol': GuideEnrichmentMatch(
      'us', 'beinsportsxtraespanol.us', 'beinsportsxtraespanol.us'),
  'us:pokergo': GuideEnrichmentMatch('us', 'pokergo.us', 'pokergo.us'),
  'us:worldpokertour':
      GuideEnrichmentMatch('us', 'worldpokertour.us', 'worldpokertour.us'),
  'us:tritonpoker':
      GuideEnrichmentMatch('us', 'tritonpoker.us', 'tritonpoker.us'),
  "au:foxcricket": GuideEnrichmentMatch(
      "au", "nsw-sydneyfoxcricket.au", "nsw-sydneyfoxcricket.au"),
  "au:foxcricket501": GuideEnrichmentMatch(
      "au", "nsw-sydneyfoxcricket.au", "nsw-sydneyfoxcricket.au"),
  "au:foxleague502": GuideEnrichmentMatch(
      "au", "nsw-sydneyfoxleague.au", "nsw-sydneyfoxleague.au"),
  "au:foxleague": GuideEnrichmentMatch(
      "au", "nsw-sydneyfoxleague.au", "nsw-sydneyfoxleague.au"),
  "au:foxfooty504": GuideEnrichmentMatch(
      "au", "nsw-sydneyfoxfooty.au", "nsw-sydneyfoxfooty.au"),
  "au:foxsports503": GuideEnrichmentMatch(
      "au", "nsw-sydneyfoxsports503.au", "nsw-sydneyfoxsports503.au"),
  "au:foxsports505": GuideEnrichmentMatch(
      "au", "nsw-sydneyfoxsports505.au", "nsw-sydneyfoxsports505.au"),
  "au:foxsports506": GuideEnrichmentMatch(
      "au", "nsw-sydneyfoxsports506.au", "nsw-sydneyfoxsports506.au"),
  "au:foxsportsmore+507": GuideEnrichmentMatch(
      "au", "nsw-sydneyfoxsportsmore.au", "nsw-sydneyfoxsportsmore.au"),
  "au:beinsports1":
      GuideEnrichmentMatch("au", "beinsports1.au", "beinsports1.au"),
  "au:beinsports2":
      GuideEnrichmentMatch("au", "beinsports2.au", "beinsports2.au"),
  "au:beinsports3":
      GuideEnrichmentMatch("au", "beinsports3.au", "beinsports3.au"),
  "au:skyracing1": GuideEnrichmentMatch("au", "skyracing1.au", "skyracing1.au"),
  "au:skyracing2": GuideEnrichmentMatch("au", "skyracing2.au", "skyracing2.au"),
  "au:skythoroughbredcentral": GuideEnrichmentMatch(
      "au", "skythoroughbredcentral.au", "skythoroughbredcentral.au"),
  "au:mutv": GuideEnrichmentMatch("au", "mutv.au", "mutv.au"),
  "au:7flixbrisbane":
      GuideEnrichmentMatch("au", "7flixbrisbane.au", "7flixbrisbane.au"),
  "au:7flixcanberra":
      GuideEnrichmentMatch("au", "7flixcanberra.au", "7flixcanberra.au"),
  "au:7flixperth": GuideEnrichmentMatch("au", "7flixperth.au", "7flixperth.au"),
  "au:7twomelbourne":
      GuideEnrichmentMatch("au", "7twomelbourne.au", "7twomelbourne.au"),
  "au:sbsfoodmelbourne":
      GuideEnrichmentMatch("au", "sbsfoodmelbourne.au", "sbsfoodmelbourne.au"),
  "au:sbsmelbourne":
      GuideEnrichmentMatch("au", "sbsmelbourne.au", "sbsmelbourne.au"),
  "au:sbsvicelandperth":
      GuideEnrichmentMatch("au", "sbsvicelandperth.au", "sbsvicelandperth.au"),
  "au:sbsworldmoviesperth": GuideEnrichmentMatch(
      "au", "sbsworldmoviesperth.au", "sbsworldmoviesperth.au"),
  "au:abcmelbourne":
      GuideEnrichmentMatch("au", "abcmelbourne.au", "abcmelbourne.au"),
  "au:racingcommelbourne": GuideEnrichmentMatch(
      "au", "racingcommelbourne.au", "racingcommelbourne.au"),
  "au:racingcomperth":
      GuideEnrichmentMatch("au", "racingcomperth.au", "racingcomperth.au"),
  "gb:bbcnews": GuideEnrichmentMatch("gb", "bbcnews.uk", "bbcnewschannel.uk"),
  "gb:skynews": GuideEnrichmentMatch("gb", "skynews.uk", "skynews.uk"),
  "gb:cnbc": GuideEnrichmentMatch("gb", "cnbc.uk", "cnbc.uk"),
  "gb:france24": GuideEnrichmentMatch("gb", "france24.uk", "france24.uk"),
  "gb:trtworld": GuideEnrichmentMatch("gb", "trtworld.uk", "trtworld.uk"),
  "gb:ginxesports":
      GuideEnrichmentMatch("gb", "ginxesportstv.uk", "ginxesportstv.uk"),
  "gb:dmax": GuideEnrichmentMatch("gb", "dmax.uk", "dmax.uk"),
  "gb:skysportspremierleague": GuideEnrichmentMatch(
      "gb", "skysportspremierleague.uk", "skysportspremierleague.uk"),
  "gb:bbctwonorthernireland": GuideEnrichmentMatch(
      "gb", "bbctwonorthernireland.uk", "bbctwonorthernireland.uk"),
  "gb:bbctwoengland":
      GuideEnrichmentMatch("gb", "bbctwoengland.uk", "bbctwoengland.uk"),
  "gb:bbconeeast": GuideEnrichmentMatch("gb", "bbconeeast.uk", "bbconeeast.uk"),
  "gb:bbconescotland":
      GuideEnrichmentMatch("gb", "bbconescotland.uk", "bbconescotland.uk"),
  "gb:bbconeyorkshire":
      GuideEnrichmentMatch("gb", "bbconeyorkshire.uk", "bbconeyorkshire.uk"),
  "gb:bbcredbutton":
      GuideEnrichmentMatch("gb", "bbcredbutton.uk", "bbcredbutton.uk"),
  "gb:racingtv": GuideEnrichmentMatch("gb", "racing.uk", "racingtv.uk"),
  "gb:greatmystery":
      GuideEnrichmentMatch("gb", "great!mystery.uk", "great!mystery.uk"),
  "gb:babytv": GuideEnrichmentMatch("gb", "babytv.uk", "babytv.uk"),
  "gb:disneyjr": GuideEnrichmentMatch("gb", "disneyjr.uk", "disneyjr.uk"),
  "gb:laligatv": GuideEnrichmentMatch("gb", "laligatv.uk", "laligatv.uk"),
  "gb:premiersports1":
      GuideEnrichmentMatch("gb", "premiersports1.uk", "premiersports1.uk"),
  "gb:premiersports2":
      GuideEnrichmentMatch("gb", "premiersports2.uk", "premiersports2.uk"),
  "gb:tntsportsultimate": GuideEnrichmentMatch(
      "gb", "tntsportsultimate.uk", "tntsportsultimate.uk"),
  "gb:tntsports4": GuideEnrichmentMatch("gb", "tntsports4.uk", "tntsports4.uk"),
  "gb:tntsports5": GuideEnrichmentMatch("gb", "tntsports5.uk", "tntsports5.uk"),
  "gb:tntsports6": GuideEnrichmentMatch("gb", "tntsports6.uk", "tntsports6.uk"),
  "gb:tntsports7": GuideEnrichmentMatch("gb", "tntsports7.uk", "tntsports7.uk"),
  "gb:tntsports8": GuideEnrichmentMatch("gb", "tntsports8.uk", "tntsports8.uk"),
  "gb:tntsports9": GuideEnrichmentMatch("gb", "tntsports9.uk", "tntsports9.uk"),
  "gb:tntsports10":
      GuideEnrichmentMatch("gb", "tntsports10.uk", "tntsports10.uk"),
  "ca:ae": GuideEnrichmentMatch("ca", "aande.ca", "aande.ca"),
  "ca:ctvnature": GuideEnrichmentMatch("ca", "ctvnature.ca", "ctvnature.ca"),
  "ca:ctvdrama":
      GuideEnrichmentMatch("ca", "ctvdramachannel.ca", "ctvdramachannel.ca"),
  "ca:hollywoodsuite70s+movies": GuideEnrichmentMatch(
      "ca", "hollywoodsuite70s+movies.ca", "hollywoodsuite70s+movies.ca"),
  "ca:hollywoodsuite2010s+movies": GuideEnrichmentMatch(
      "ca", "hollywoodsuite2010s+movies.ca", "hollywoodsuite2010s+movies.ca"),
  "ca:adultswim": GuideEnrichmentMatch("ca", "adultswim.ca", "adultswim.ca"),
  "ca:amc": GuideEnrichmentMatch("ca", "amccanada.ca", "amc.ca"),
  "ca:cartoonnetwork": GuideEnrichmentMatch(
      "ca", "cartoonnetworkcanada.ca", "cartoonnetwork.ca"),
  "ca:cnninternational":
      GuideEnrichmentMatch("ca", "cnninternational.ca", "cnninternational.ca"),
  "ca:cpacfrench": GuideEnrichmentMatch("ca", "cpacfrench.ca", "cpacfrench.ca"),
  "ca:globalnewsbc":
      GuideEnrichmentMatch("ca", "globalnewsbc1.ca", "globalnewsbc1.ca"),
  "ca:hgtv": GuideEnrichmentMatch("ca", "hgtv.ca", "hgtv.ca"),
  "ca:historia": GuideEnrichmentMatch("ca", "historia.ca", "historia.ca"),
  "ca:investigationdiscovery": GuideEnrichmentMatch(
      "ca", "investigationdiscovery.ca", "investigationdiscovery.ca"),
  "ca:magnolianetwork":
      GuideEnrichmentMatch("ca", "magnolianetwork.ca", "magnolianetwork.ca"),
  "ca:cbccalgary":
      GuideEnrichmentMatch("ca", "cbccalgary-cbrt.ca", "cbccalgary-cbrt.ca"),
  "ca:cbchalifax":
      GuideEnrichmentMatch("ca", "cbchalifax-cbht.ca", "cbchalifax-cbht.ca"),
  "ca:cbcmontreal":
      GuideEnrichmentMatch("ca", "cbcmontreal-cbmt.ca", "cbcmontreal-cbmt.ca"),
  "ca:cbcottawa":
      GuideEnrichmentMatch("ca", "cbcottawa-cbot.ca", "cbcottawa-cbot.ca"),
  "ca:cbctoronto":
      GuideEnrichmentMatch("ca", "cbctoronto-cblt.ca", "cbctoronto-cblt.ca"),
  "ca:cbcwinnipeg":
      GuideEnrichmentMatch("ca", "cbcwinnipeg-cbwt.ca", "cbcwinnipeg-cbwt.ca"),
  "ca:citytvedmonton":
      GuideEnrichmentMatch("ca", "citytvedmonton.ca", "citytvedmonton.ca"),
  "ca:ctvcalgary":
      GuideEnrichmentMatch("ca", "ctvcalgary-cfcn.ca", "ctvcalgary-cfcn.ca"),
  "ca:ctvhalifax":
      GuideEnrichmentMatch("ca", "ctvhalifax-cjch.ca", "ctvhalifax-cjch.ca"),
  "ca:ctvkitchener": GuideEnrichmentMatch(
      "ca", "ctvkitchener-ckco.ca", "ctvkitchener-ckco.ca"),
  "ca:ctvmontreal":
      GuideEnrichmentMatch("ca", "ctvmontreal-cfcf.ca", "ctvmontreal-cfcf.ca"),
  "ca:ctvottawa":
      GuideEnrichmentMatch("ca", "ctvottawa-cjoh.ca", "ctvottawa-cjoh.ca"),
  "us:ae": GuideEnrichmentMatch("us", "a&e.us", ""),
  "us:babytvusa": GuideEnrichmentMatch("us", "babytv.us", ""),
  "us:lawcrime": GuideEnrichmentMatch("us", "lawandcrime.us", ""),
  "us:eentertainment":
      GuideEnrichmentMatch("us", "eentertainmenttelevision.us", ""),
  "us:sportsnetpittsburgh":
      GuideEnrichmentMatch("us", "sportsnetpittsburgh.us", ""),
};
final _region = RegExp(r'\.(us|uk|au|ca)(?:\.plus1)?$', caseSensitive: false);
final _prefix = RegExp(r'^(?:us|uk|au|ca)\s*[-:|]\s*', caseSensitive: false);
final _quality = RegExp(
    r'\b(?:hd|fhd|uhd|4k|raw|720p25|1080p50|1080p25|720p50|hdr|sd)\b',
    caseSensitive: false);
final _nonName = RegExp(r'[^a-z0-9+]');
final _eventGroup = RegExp(
    r'ppv|24/7|sunday ticket|college|league pass|mlb\.tv|center ice|espn\+|flo |fifa\+|dirtvision',
    caseSensitive: false);
GuideEnrichmentMatch? guideEnrichmentMatch(Channel channel) {
  if (channel.name.startsWith('###') || _eventGroup.hasMatch(channel.group)) {
    return null;
  }
  // Prefer the explicit feed region; a US channel can appear in a UK curated
  // guide. No country inference from a bare international channel name.
  var country = _region
      .firstMatch(channel.epgKey ?? channel.rawId)
      ?.group(1)
      ?.toLowerCase();
  if (country == null) {
    final group = channel.group.toLowerCase();
    for (final code in ['uk', 'au', 'ca', 'us']) {
      if (group.startsWith('$code|')) {
        country = code;
        break;
      }
    }
  }
  if (country == null) return null;
  if (country == 'uk') country = 'gb';
  var name = channel.name;
  for (final tag in ['ᵁᴴᴰ', 'ᴴᴰᴿ', 'ᴴᴰ', 'ᴿᴬᵂ']) {
    name = name.replaceAll(tag, '');
  }
  name = name
      .toLowerCase()
      .replaceFirst(_prefix, '')
      .replaceAll(_quality, '')
      .replaceAll(_nonName, '');
  return _matches['$country:$name'];
}
