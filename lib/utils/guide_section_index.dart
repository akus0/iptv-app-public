import '../models/channel.dart';
import 'live_guide_search.dart';

typedef GuideSectionSpan = ({int start, int end, Channel header});
typedef PinnedGuideSection = ({int section, double displacement});

/// Built once per displayed channel list; scrolling only searches header indices.
class GuideSectionIndex {
  GuideSectionIndex(List<Channel> channels) {
    (int start, Channel header)? active;
    Channel? previous;
    for (var i = 0; i < channels.length; i++) {
      final channel = channels[i];
      final boundary = previous != null &&
          (channel.playlistId != previous.playlistId ||
              channel.group != previous.group);
      final header = isGuideSection(channel);
      if (active != null && (header || boundary)) {
        sections.add((start: active.$1, end: i, header: active.$2));
        active = null;
      }
      if (header) active = (i, channel);
      previous = channel;
    }
    if (active != null) {
      sections.add((start: active.$1, end: channels.length, header: active.$2));
    }
  }

  final List<GuideSectionSpan> sections = [];

  int _at(double row) {
    var low = 0;
    var high = sections.length;
    while (low < high) {
      final mid = (low + high) >> 1;
      if (sections[mid].start <= row) {
        low = mid + 1;
      } else {
        high = mid;
      }
    }
    return low - 1;
  }

  PinnedGuideSection? pinned(double offset, double rowHeight) {
    if (offset <= 0 || rowHeight <= 0) return null;
    final index = _at(offset / rowHeight);
    if (index < 0) return null;
    final span = sections[index];
    if (span.end <= span.start + 1 ||
        offset <= span.start * rowHeight ||
        offset >= span.end * rowHeight) {
      return null;
    }
    final remaining = span.end * rowHeight - offset - rowHeight;
    return (section: index, displacement: remaining < 0 ? remaining : 0);
  }

  /// Leave room for the pinned heading when the remote focuses an upper row.
  double focusTop(int row, double rowHeight) {
    final index = _at(row.toDouble());
    final covered =
        index >= 0 && row > sections[index].start && row < sections[index].end;
    return (row - (covered ? 1 : 0)) * rowHeight;
  }
}
