import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../models/sports_feed_issue.dart';
import '../utils/interface_colors.dart';

/// Brief acknowledgement of a manual refresh failure. Diagnostics remain
/// available beside refresh after this notice is dismissed.
void showSportsFeedNotice(BuildContext context,
    {required VoidCallback onDetails}) {
  final scheme = Theme.of(context).colorScheme;
  ScaffoldMessenger.of(context)
    ..clearSnackBars()
    ..showSnackBar(SnackBar(
      key: const ValueKey('sports-feed-notice'),
      persist: false,
      duration: const Duration(seconds: 6),
      showCloseIcon: true,
      closeIconColor: scheme.onSurfaceVariant,
      backgroundColor: scheme.surfaceContainerHighest,
      behavior: SnackBarBehavior.floating,
      elevation: 2,
      margin: const EdgeInsets.all(12),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(4),
          side: BorderSide(color: scheme.outlineVariant)),
      content: Text('Some events couldn’t update.',
          style:
              TextStyle(color: scheme.onSurface, fontSize: 12, height: 1.35)),
      action: SnackBarAction(
          label: 'Details', textColor: scheme.primary, onPressed: onDetails),
    ));
}

class SportsFeedDiagnostics extends StatelessWidget {
  const SportsFeedDiagnostics({super.key, required this.issues});
  final List<SportsFeedIssue> issues;
  @override
  Widget build(BuildContext context) => Dialog(
        insetPadding: const EdgeInsets.all(16),
        backgroundColor: interfaceColor(context, const Color(0xFF171D25)),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 780, maxHeight: 620),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Padding(
                padding: const EdgeInsets.only(left: 16, right: 6),
                child: Row(children: [
                  const Expanded(
                      child: Text('Event feed details',
                          style: TextStyle(
                              fontSize: 16, fontWeight: FontWeight.w600))),
                  IconButton(
                      tooltip: 'Close feed details',
                      onPressed: () => Navigator.pop(context),
                      icon: const Icon(Icons.close, size: 20)),
                ])),
            Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
                child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                        '${issues.length} unavailable feeds · captured responses, no extra requests.\nSaved scores may be out of date. Open a feed for details.',
                        style: TextStyle(
                            fontSize: 11,
                            height: 1.4,
                            color: interfaceColor(context, Colors.white60))))),
            Flexible(
                child: ListView.separated(
              shrinkWrap: issues.length < 4,
              padding: const EdgeInsets.fromLTRB(10, 0, 10, 10),
              itemCount: issues.length,
              separatorBuilder: (_, __) => const SizedBox(height: 6),
              itemBuilder: (context, i) => _FeedIssueCard(issue: issues[i]),
            )),
          ]),
        ),
      );
}

class _FeedIssueCard extends StatelessWidget {
  const _FeedIssueCard({required this.issue});
  final SportsFeedIssue issue;
  @override
  Widget build(BuildContext context) {
    String time(DateTime value) =>
        DateFormat('d MMM HH:mm:ss').format(value.toLocal());
    return Material(
      color: interfaceColor(context, const Color(0xFF232C36)),
      borderRadius: BorderRadius.circular(5),
      child: ExpansionTile(
        expansionAnimationStyle: AnimationStyle.noAnimation,
        key: PageStorageKey(issue.endpoint),
        tilePadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
        childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
        expandedCrossAxisAlignment: CrossAxisAlignment.start,
        title: Text('${issue.league} · ${issue.status}',
            style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
        subtitle: Text(issue.endpoint,
            style: TextStyle(
                fontSize: 10.5,
                height: 1.35,
                color: interfaceColor(context, Colors.white60))),
        children: [
          Text(
              '${issue.reason} · Checked ${time(issue.checkedAt)}\n'
              'Next automatic attempt after ${time(issue.retryAt)}'
              '${issue.lastSuccess == null ? '\nNo saved response for this feed.' : '\nLast successful update: ${time(issue.lastSuccess!)}'}',
              style: TextStyle(
                  fontSize: 11,
                  height: 1.5,
                  color: interfaceColor(context, Colors.white70))),
          const SizedBox(height: 8),
          Text(
              issue.contentType == null
                  ? 'Response body'
                  : 'Response body · ${issue.contentType}',
              style:
                  const TextStyle(fontSize: 11, fontWeight: FontWeight.w600)),
          const SizedBox(height: 4),
          SelectableText(
              issue.responseBody == null
                  ? issue.requested
                      ? 'No HTTP response received.'
                      : 'No new request sent while the source is rate limited.'
                  : issue.responseBody!.isEmpty
                      ? '(Empty response)'
                      : issue.responseBody!,
              key: PageStorageKey('response-body:${issue.endpoint}'),
              style: const TextStyle(
                  fontSize: 10.5, height: 1.4, fontFamily: 'monospace')),
        ],
      ),
    );
  }
}
