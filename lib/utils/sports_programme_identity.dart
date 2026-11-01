import '../models/epg_program.dart';

final _raisedLive = RegExp('ᴸ[ᶦⁱ]ᵛᵉ|ᶫ[ᶦⁱ]ᵛᵉ', caseSensitive: false);
final _punctuation = RegExp(r'[^\p{L}\p{N}]+', unicode: true);
final _liveEdges = RegExp(r'^live\s+|\s+live$');

/// Presentation identity only. Broadcast labels and punctuation do not justify
/// showing the same programme twice; fixture scoring still uses original data.
String sportsProgrammeTitleKey(String title) => title
    .replaceAll(_raisedLive, ' ')
    .toLowerCase()
    .replaceAll(_punctuation, ' ')
    .trim()
    .replaceAll(_liveEdges, '')
    .trim();

bool sameSportsProgramme(EpgProgram? a, EpgProgram? b) =>
    a != null &&
    b != null &&
    a.start.isAtSameMomentAs(b.start) &&
    a.stop.isAtSameMomentAs(b.stop) &&
    (a.title == b.title ||
        (sportsProgrammeTitleKey(a.title).isNotEmpty &&
            sportsProgrammeTitleKey(a.title) ==
                sportsProgrammeTitleKey(b.title)));
