import '../models/channel.dart';

/// Only explicit on-demand IDs/routes identify VOD. A live channel or group
/// called Movies, Series or Game Shows must remain in the live guide.
bool isOnDemandChannel(Channel channel) {
  if (!Channel.isLiveId(channel.rawId)) return true;
  final path = Uri.tryParse(channel.url)?.pathSegments;
  if (path == null || path.length < 4) return false;
  return path.first == 'movie' || path.first == 'series';
}
