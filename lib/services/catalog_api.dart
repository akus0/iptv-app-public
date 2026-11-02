import '../models/channel.dart';
import '../models/series_details.dart';
import '../models/vod_details.dart';
import '../models/xtream_category.dart';
import '../models/xtream_series.dart';

/// Category-based providers share local catalogue storage and lazy browsing.
/// Authentication and playback commands remain owned by the provider.
abstract class CatalogApi {
  int? get maxConnections;
  DateTime? get expiryDate;
  Future<void> authenticate();
  Future<List<XtreamCategory>> getLiveCategories();
  Future<List<XtreamCategory>> getVodCategories();
  Future<List<XtreamCategory>> getSeriesCategories();
  Future<List<Channel>> getLiveStreams(
      {required Map<String, String> categoryNames, String? categoryId});
  Future<List<Channel>> getVodStreams(String categoryId, String categoryName);
  Future<List<XtreamSeries>> getSeriesForCategory(String categoryId);
  Future<SeriesEpisodesResult> getSeriesEpisodes(
      int seriesId, String seriesName,
      {bool plotOnly = false});
  Future<String?> getVodDescription(String streamId);
  Future<VodDetails> getVodInfo(String streamId);
  void dispose() {}
}
