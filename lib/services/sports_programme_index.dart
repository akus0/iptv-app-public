part of 'sports_channel_matcher.dart';

// Programme postings are derived evidence, never match decisions. Keep their
// representation, exact reuse checks and incremental preparation together.

class _PreparedProgrammes {
  _PreparedProgrammes(this.generation, this.tennisIds);
  final Object generation;
  final Set<String> tennisIds;
  final rows = <EpgProgram>[];
  final titles = <String>[], identities = <String>[];
  final byChannel = <String, List<EpgProgram>>{};
  final words = <String, List<int>>{}, courts = <String, List<int>>{};
  final times = SportsProgrammeTimeIndex();

  bool isPrefixOf(List<EpgProgram> programmes, Set<String> tennis) {
    if (rows.length > programmes.length ||
        tennis.length != tennisIds.length ||
        !tennisIds.containsAll(tennis)) {
      return false;
    }
    for (var i = 0; i < rows.length; i++) {
      final a = rows[i], b = programmes[i];
      if (!identical(a, b) &&
          (a.channelId != b.channelId ||
              a.start != b.start ||
              a.stop != b.stop ||
              a.title != b.title ||
              a.description != b.description ||
              a.isLive != b.isLive)) {
        return false;
      }
    }
    return true;
  }
}

class _ProgrammeTextFacts {
  _ProgrammeTextFacts(this.title, this.identity)
      : court = _MatchTerms._court(identity),
        words = identity
            .trim()
            .split(' ')
            .where((word) => word.length >= 2)
            .toSet();
  final String title, identity;
  final String? court;
  final Set<String> words;
}

extension _ProgrammePreparation on SportsChannelMatcher {
  /// Null asks the caller to retry against a changed channel catalogue. The
  /// caller retains a prepared index only after scoring completes successfully.
  Future<_PreparedProgrammes?> _prepareProgrammes(
      List<EpgProgram> programmes, String? indexVersion,
      {required SportsProgressReporter progress,
      required bool reuseText}) async {
    final programmeGeneration =
        (indexVersion, _guideQueryRevision, _epg.lastUpdated);
    final tennisIds = _tennisGuideCoverage.keys.toSet();
    final prepared = _programmeIndexes.largestWhere((index) =>
            index.generation == programmeGeneration &&
            index.isPrefixOf(programmes, tennisIds)) ??
        _PreparedProgrammes(programmeGeneration, tennisIds);
    final indexAudit = const bool.fromEnvironment('IPTV_PROFILE_SPORTS')
        ? (Stopwatch()..start())
        : null;
    final reusedRows = prepared.rows.length;
    // Fully prepared windows need no temporary text dictionary. Corrections
    // still borrow pure text from older generations, never scoring decisions.
    final reusableText = <(String, String, bool), (String, String)>{};
    if (reuseText && prepared.rows.length < programmes.length) {
      final reuseSlice = Stopwatch()..start();
      for (final previous in _programmeIndexes.values) {
        for (var i = 0; i < previous.rows.length; i++) {
          final p = previous.rows[i];
          reusableText[(
            p.title,
            _guideDescription(p),
            previous.tennisIds.contains(p.channelId)
          )] = (previous.titles[i], previous.identities[i]);
          if (reuseSlice.elapsedMilliseconds >= _workSliceMs) {
            await Future<void>.delayed(Duration.zero);
            reuseSlice.reset();
          }
        }
      }
    }
    _programmeIndexes
        .removeWhere((index) => index.generation != programmeGeneration);
    // Release older postings before allocating a different large window, not
    // afterwards, so a refresh does not briefly retain two full-day indexes.
    _programmeIndexes.reserve(prepared, programmes.length);

    final titles = prepared.titles;
    final guideIdentities = prepared.identities;
    final programmesByChannel = prepared.byChannel;
    final titleIndex = prepared.words;
    final courtIndex = prepared.courts;
    final slice = Stopwatch()..start();
    progress.report(SportsWorkStage.programmes, total: programmes.length);
    for (var i = prepared.rows.length; i < programmes.length; i++) {
      final programme = programmes[i];
      if (i % 128 == 0) {
        progress.report(SportsWorkStage.programmes,
            completed: i, total: programmes.length);
      }
      (programmesByChannel[normalizeEpgId(programme.channelId)] ??= [])
          .add(programme);
      final facts = _programmeText(programme, normalized: reusableText);
      titles.add(facts.title);
      guideIdentities.add(facts.identity);
      final court = facts.court;
      if (court != null) (courtIndex[court] ??= []).add(i);
      for (final word in facts.words) {
        (titleIndex[word] ??= []).add(i);
      }
      prepared.times.add(programme.start, programme.stop);
      prepared.rows.add(programme);
      if (slice.elapsedMilliseconds >= _workSliceMs) {
        await Future<void>.delayed(Duration.zero);
        if (indexVersion != _preparedFor) {
          return null;
        }
        slice.reset();
      }
    }
    if (indexAudit != null) {
      debugPrint('IPTV_SPORTS programme_index rows=${programmes.length} '
          'reused=$reusedRows ms=${indexAudit.elapsedMilliseconds}');
    }
    return prepared;
  }

  _ProgrammeTextFacts _programmeText(EpgProgram programme,
      {Map<(String, String, bool), (String, String)>? normalized}) {
    final tennis = _tennisGuideCoverage.containsKey(programme.channelId);
    final description = _guideDescription(programme);
    final key = (programme.title, description, tennis);
    final cached = _programmeTexts[key];
    if (cached != null) return cached;
    final prior = normalized?[key];
    final title = prior?.$1 ?? _fixtureText(programme.title);
    final identity = prior?.$2 ??
        (tennis && !_otherFixture(title)
            ? '$title${_fixtureText(description)}'
            : _guideIdentity(programme, title));
    final result = _ProgrammeTextFacts(title, identity);
    if (programme.title.length <= 1024) {
      _programmeTexts.put(
          key,
          result,
          programme.title.length +
              description.length +
              title.length +
              identity.length +
              result.words.fold(0, (sum, word) => sum + word.length));
    }
    return result;
  }
}
