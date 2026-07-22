import 'package:jhentai/src/routes/routes.dart';

import '../../model/search_config.dart';
import '../base/base_page_state.dart';

class FavoritePageState extends BasePageState {
  @override
  String get route => Routes.favorite;

  @override
  SearchConfig searchConfig = SearchConfig(searchType: SearchType.favorite);

  /// batch download progress
  bool isBatchDownloading = false;
  int batchDownloadTotalCount = 0;
  int batchDownloadCurrentCount = 0;

  /// 'loadingFavorites' or 'downloading'
  String batchDownloadPhase = '';

  /// failure countdown: when loading retries are exhausted, record the failure
  /// time so the user can resume within 30 minutes.
  DateTime? batchDownloadFailureTime;

  /// phase in which the failure occurred ('loadingFavorites' or 'downloading'),
  /// used for toast messaging.
  String batchDownloadFailurePhase = '';
}
