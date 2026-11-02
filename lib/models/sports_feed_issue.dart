/// Bounded, session-only diagnostics from an event feed already requested.
/// No playlist credentials, request headers or additional diagnostic requests.
class SportsFeedIssue {
  const SportsFeedIssue(
      {required this.league,
      required this.endpoint,
      required this.reason,
      required this.checkedAt,
      required this.retryAt,
      this.statusCode,
      this.responseBody,
      this.contentType,
      this.lastSuccess,
      this.requested = true});
  final String league, endpoint, reason;
  final int? statusCode;
  final String? responseBody, contentType;
  final DateTime checkedAt, retryAt;
  final DateTime? lastSuccess;
  final bool requested;
  String get status => !requested
      ? 'Retry paused'
      : statusCode == null
          ? reason
          : 'HTTP $statusCode';
}
