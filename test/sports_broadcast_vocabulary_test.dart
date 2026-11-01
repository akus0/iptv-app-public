import 'package:flutter_test/flutter_test.dart';
import 'package:nox_iptv/models/epg_program.dart';
import 'package:nox_iptv/services/sports_replay_service.dart';
import 'package:nox_iptv/utils/extended_sports.dart';

EpgProgram programme(String title,
        {String description = '', bool live = false}) =>
    EpgProgram(
      channelId: 'sport',
      title: title,
      description: description,
      isLive: live,
      start: DateTime.utc(2026, 10, 30, 11),
      stop: DateTime.utc(2026, 10, 30, 14),
    );

void main() {
  test('named competitions are recognised without broadening unrelated sports',
      () {
    for (final (title, sport, league) in [
      ('EuroLeague: Red vs Blue', 'basketball', 'euroleague'),
      ('BKT EuroCup: Red vs Blue', 'basketball', 'eurocup'),
      ('Košarka - Eurocup: Red - Blue', 'basketball', 'eurocup'),
      ('FIBA 3x3 World Tour', 'basketball', 'basketball'),
      ('American Hockey League: Red at Blue', 'hockey', 'ahl'),
      ('AFLW: Red v Blue', 'australian-football', 'aflw'),
      ('Ekstraklasa: Red v Blue', 'soccer', 'ekstraklasa'),
      ('Cyclo-cross: Superprestige Overijse', 'cycling', 'cyclocross'),
      ('WWE Raw', 'wrestling', 'wwe'),
      ('AEW Collision', 'wrestling', 'aew'),
      ('Total Nonstop Action', 'wrestling', 'tna'),
    ]) {
      expect(extendedGuideSport(title, ''), sport, reason: title);
      expect(additionalGuideCompetition(sport, title, 'EuroLeague Basketball'),
          league,
          reason: title);
    }
    expect(
        extendedGuideSport('Live AFLW: Brisbane v Sydney',
            'Action from the A-League Women, the top football division in Australia.'),
        isNull);
    expect(extendedGuideSport('Live Skiing Eurocup', ''), isNull);
    expect(extendedGuideSport('Live EuroLeague Football', ''), isNull);
    expect(extendedGuideSport('WWE Kickoff LIVE', ''), isNull);
    expect(extendedGuideSport('FloWrestling Radio Live', ''), isNull);
    expect(extendedGuideSport('Climbing a corporate ladder', ''), isNull);
    expect(
        extendedGuideSport(
            'A gymnastics adventure', 'A documentary about gymnasts.'),
        isNull);
  });

  test('new competition vocabulary is shared with replay and highlight tabs',
      () {
    for (final (title, sport) in [
      ('World Championship Artistic Gymnastics', 'gymnastics'),
      ('IFSC Climbing World Series', 'climbing'),
      ('Cyclocross: Overijse', 'cycling'),
      ('Košarka Eurocup: Red v Blue', 'basketball'),
      ('Ekstraklasa: Red v Blue', 'soccer'),
      ('TNA iMPACT!', 'wrestling'),
      ('AHL: Red at Blue', 'hockey'),
      ('AFLW: Red v Blue', 'australian-football'),
    ]) {
      expect(classifySportsReplay(programme('$title Replay'))?.sport, sport,
          reason: title);
      expect(classifySportsHighlights(programme('$title Highlights'))?.sport,
          sport,
          reason: title);
    }
  });

  test('promotion names and translations identify the sport, not live state',
      () {
    for (final title in [
      'Muaythai',
      'Muay-Thai',
      'Thai Fight League',
      'RWS',
      'Rajadamnern World Series',
      'Rajadamnoen World Series',
      'Suek Kiatpetch Tor Nam Thai TKO',
      'Kiatpecht Super Fight',
      'Kp Sunday Fight',
      'Muay Man Sanan Muang',
      'Muay Dee Witeethai',
      'Suek Muay Thai Phanthamit',
      'Suek Muay Thai Phalang Mai',
      'Petchyindee',
      'มวยไทย 7 สี',
      'ศึกจ้าวมวยไทย',
      'ศึกจิตรเมืองนนท์',
      'มวยมันส์ช่อง 8',
      'ไทยไฟท์',
      'ไทยไฟต์',
      'ศึกเพชรยินดี',
      'ทรูโฟร์ยู ศึกเกียรติเพชร ซุปเปอร์ไฟท์',
    ]) {
      expect(extendedGuideSport(title, ''), 'mma', reason: title);
      expect(combatGuideLeague(title, ''), 'muay-thai', reason: title);
      expect(isLiveSportsProgramme(programme(title)), false, reason: title);
    }
    for (final title in [
      'ONE Lumpini 200',
      'ONE Lumpinee 200',
      'ONE ลุมพินี 200',
      'วันลุมพินี 200'
    ]) {
      expect(extendedGuideSport(title, ''), 'mma', reason: title);
      expect(combatGuideLeague(title, ''), 'one', reason: title);
    }
    expect(
        extendedGuideSport('Fight card', 'ถ่ายทอดสดการแข่งขันชกมวยไทย'), 'mma');
  });

  test('local live labels do not revive recorded fights or highlights', () {
    for (final title in ['ถ่ายทอดสด มวยไทย', 'มวยไทย [สด]', 'สด: มวยไทย']) {
      expect(isLiveSportsProgramme(programme(title)), true, reason: title);
    }
    expect(
        isLiveSportsProgramme(programme('ศึกจ้าวมวยไทย',
            description: 'ถ่ายทอดสดการแข่งขันชกมวยศึกจ้าวมวยไทย.')),
        true);
    expect(
        isLiveSportsProgramme(programme('มวยไทย',
            description: 'ถ่ายทอดสดมวยไทย รับชมย้อนหลังได้ภายหลัง')),
        true);
    expect(
        isLiveSportsProgramme(programme('มวยไทย', description: 'สดใสทุกวัน')),
        false);
    for (final marker in ['ย้อนหลัง', 'รีรัน', 'เทปบันทึกการแข่งขัน']) {
      final p = programme('ถ่ายทอดสด มวยไทย $marker', live: true);
      expect(isLiveSportsProgramme(p), false);
      expect(classifySportsReplay(p)?.sport, 'mma');
      expect(classifySportsHighlights(p), isNull);
      final intro =
          programme('มวยไทย', description: '$marker มวยไทย', live: true);
      expect(isLiveSportsProgramme(intro), false);
      expect(classifySportsReplay(intro)?.sport, 'mma');
    }
    for (final marker in ['ไฮไลท์', 'ไฮไลต์']) {
      final p = programme('$marker มวยไทย ถ่ายทอดสด', live: true);
      expect(isLiveSportsProgramme(p), false);
      expect(classifySportsHighlights(p)?.sport, 'mma');
      expect(classifySportsReplay(p), isNull);
      expect(
          classifySportsHighlights(programme('มวยไทย',
                  description: '$marker มวยไทย', live: true))
              ?.sport,
          'mma');
    }
  });

  test('specific sports win over ambiguous names across all tabs', () {
    for (final (title, sport) in [
      ('World Pool Championship', 'billiards'),
      ('World Bowling', 'bowling'),
      ('World Rally Championship', 'racing'),
      ('World Superbike', 'racing'),
      ('World Supersport', 'racing'),
      ('International GT Open', 'racing'),
    ]) {
      expect(extendedGuideSport(title, ''), sport, reason: title);
    }
    expect(extendedGuideSport('The Ashes', ''), 'cricket');
    expect(extendedGuideSport('The Rugby Championship', ''), 'rugby');
    expect(extendedGuideSport('Premier Pádel Tennis: Final LIVE', ''), 'padel');
    expect(
        classifySportsReplay(programme('Premier Padel Tennis: Final Replay'))
            ?.sport,
        'padel');
    expect(
        classifySportsHighlights(
                programme('Premier Padel Tennis: Final Highlights'))
            ?.sport,
        'padel');
    for (final (sport, title) in [
      ('taekwondo', 'World Taekwondo Grand Prix: Paris Final'),
      ('sailing', 'SailGP: Sydney Day 2'),
      ('sailing', 'America’s Cup: Preliminary Regatta Final Day'),
      ('pickleball', 'APP Tour Pickleball: Columbus Open'),
      ('triathlon', 'IRONMAN World Championship'),
      ('triathlon', 'T100 Triathlon World Tour'),
    ]) {
      expect(extendedGuideSport(title, ''), sport, reason: title);
      expect(classifySportsReplay(programme('$title Replay'))?.sport, sport);
      expect(classifySportsHighlights(programme('$title Highlights'))?.sport,
          sport);
    }
  });

  test('films, portraits and magazine shows remain excluded', () {
    for (final (title, description) in [
      ('One Lumpinee Heroes', ''),
      ('SailGP Racing On The Edge', ''),
      ('Beyond Triathlon', ''),
      ('Taiwan Spirit: Taekwondo', 'สารคดีที่จะพาไปสัมผัสกับชัยชนะ'),
      ('คนเดือดซัดนรก', 'ผู้เชี่ยวชาญมวยไทยออกปฏิบัติภารกิจล้างแค้น'),
      ('The Karate Kid', 'A boy learns karate.'),
      ('Ironman', 'A superhero film.'),
      ('Postcards', 'Visit a padel club in Brighton.'),
      ('Sailing Adventures', 'A documentary about championship sailing.'),
      ('ข่าวมวยไทย', 'ข่าวกีฬาประจำวัน'),
    ]) {
      expect(extendedGuideSport(title, description), isNull, reason: title);
    }
  });
}
