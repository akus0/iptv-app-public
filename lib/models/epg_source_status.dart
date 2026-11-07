enum EpgSourceState { updating, updated, failed, cached, empty }

/// Session-only diagnostics. No response body, URL or exception text is exposed.
class EpgSourceStatus {
  const EpgSourceStatus(this.state, this.at,
      {this.programmes, this.httpStatus});
  final EpgSourceState state;
  final DateTime at;
  final int? programmes;
  final int? httpStatus;
}
