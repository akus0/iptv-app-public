/// Optional provider data, fetched only when a viewer opens details.
library;

enum SportsDetailKind {
  table,
  information,
  comparison,
  players,
  lineup,
  record,
  periods
}

class SportsDetailRow {
  const SportsDetailRow(this.label, this.values, {this.detail, this.id});
  final String label;
  final List<String> values;
  final String? detail;
  final String? id;
}

class SportsDetailSection {
  const SportsDetailSection(this.title,
      {this.columns = const [],
      this.rows = const [],
      this.kind = SportsDetailKind.table,
      this.teamId});
  final String title;

  /// Headers for row.values; row.label is the separate leading column.
  final List<String> columns;
  final List<SportsDetailRow> rows;
  final SportsDetailKind kind;
  final String? teamId;
}

class SportsDetails {
  const SportsDetails({
    required this.title,
    required this.source,
    required this.fetchedAt,
    this.subtitle = '',
    this.scoreLine,
    this.scores = const {},
    this.sections = const [],
    this.failed = false,
    this.unsupported = false,
    this.stale = false,
    this.message,
  });
  final String title, subtitle, source;
  final String? scoreLine;
  final Map<String, String> scores;
  final DateTime fetchedAt;
  final List<SportsDetailSection> sections;
  final bool failed, unsupported, stale;
  final String? message;

  SportsDetails withRefreshFailure() => SportsDetails(
      title: title,
      subtitle: subtitle,
      scoreLine: scoreLine,
      scores: scores,
      source: source,
      fetchedAt: fetchedAt,
      sections: sections,
      failed: true,
      stale: true,
      message: 'Could not refresh details. Showing the last available data.');
}
