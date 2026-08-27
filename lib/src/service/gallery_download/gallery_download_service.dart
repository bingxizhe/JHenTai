import 'dart:async';
import 'dart:convert';
import 'dart:core';
import 'dart:io' as io;

import 'package:collection/collection.dart';
import 'package:dio/dio.dart';
import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:executor/executor.dart';
import 'package:extended_image/extended_image.dart';
import 'package:flutter/material.dart';
import 'package:get/get_core/src/get_main.dart';
import 'package:get/get_instance/src/extension_instance.dart';
import 'package:get/get_rx/get_rx.dart';
import 'package:get/get_state_manager/src/simple/get_controllers.dart';
import 'package:get/get_utils/get_utils.dart';
import 'package:intl/intl.dart';
import 'package:jhentai/src/database/dao/gallery_dao.dart';
import 'package:jhentai/src/database/dao/gallery_group_dao.dart';
import 'package:jhentai/src/database/database.dart';
import 'package:jhentai/src/enum/config_enum.dart';
import 'package:jhentai/src/exception/eh_image_exception.dart';
import 'package:jhentai/src/exception/eh_parse_exception.dart';
import 'package:jhentai/src/extension/dio_exception_extension.dart';
import 'package:jhentai/src/extension/list_extension.dart';
import 'package:jhentai/src/model/gallery_thumbnail.dart';
import 'package:jhentai/src/model/gallery_url.dart';
import 'package:jhentai/src/model/jh_response/fetch_image_hashes_vo.dart';
import 'package:jhentai/src/model/jh_response/jh_response.dart';
import 'package:jhentai/src/network/jh_request.dart';
import 'package:jhentai/src/service/local_config_service.dart';
import 'package:jhentai/src/service/log.dart';
import 'package:jhentai/src/service/super_resolution_service.dart';
import 'package:jhentai/src/setting/download_setting.dart';
import 'package:jhentai/src/setting/site_setting.dart';
import 'package:jhentai/src/utils/convert_util.dart';
import 'package:jhentai/src/utils/jh_response_parser.dart';
import 'package:jhentai/src/utils/speed_computer.dart';
import 'package:jhentai/src/utils/toast_util.dart';
import 'package:path/path.dart' as path;
import 'package:retry/retry.dart';

import '../../consts/locale_consts.dart';
import '../../database/dao/gallery_image_dao.dart';
import '../../exception/cancel_exception.dart';
import '../../exception/eh_site_exception.dart';
import '../../model/comic_info.dart';
import '../../model/detail_page_info.dart';
import '../../model/gallery_detail.dart';
import '../../model/gallery_image.dart';
import '../../network/eh_request.dart';
import '../../pages/download/grid/mixin/grid_download_page_service_mixin.dart';
import '../../utils/eh_executor.dart';
import '../../utils/eh_spider_parser.dart';
import '../../utils/snack_util.dart';
import '../jh_service.dart';
import '../path_service.dart';
import 'download_path_resolver.dart';
import 'eh_image_exception_matcher.dart';

part 'gallery_download_task_runner.dart';
part 'gallery_upgrade_migrator.dart';
part 'gallery_metadata_store.dart';

/// Responsible for local images meta-data and download all images of a gallery
GalleryDownloadService galleryDownloadService = GalleryDownloadService();

class GalleryDownloadService extends GetxController with GridBasePageServiceMixin, JHLifeCircleBeanErrorCatch implements JHLifeCircleBean {
  final String downloadImageId = 'downloadImageId';
  final String downloadImageUrlId = 'downloadImageUrlId';
  final String galleryDownloadProgressId = 'galleryDownloadProgressId';
  final String galleryDownloadSpeedComputerId = 'galleryDownloadSpeedComputerId';
  final String galleryDownloadSuccessId = 'galleryDownloadSuccessId';

  late EHExecutor executor;

  List<String> allGroups = [];
  Map<int, GalleryDownloadInfo> galleryDownloadInfos = {};

  /// Cached sorted snapshot of [galleryDownloadInfos]. Invalidated on any
  /// mutation that affects order (add / delete / group rename / group change
  /// / priority change). Re-sorted on next read. Avoids O(N log N) per UI
  /// rebuild — critical for thousands-of-galleries scenarios.
  List<GalleryDownloadInfo>? _galleriesCache;

  /// Sorted view synthesized from [galleryDownloadInfos]. Single source of
  /// truth — the map holds the data; this getter returns a cached sorted
  /// snapshot, rebuilt only when the set or order-affecting fields change.
  List<GalleryDownloadInfo> get galleries {
    return _galleriesCache ??= _rebuildGalleriesCache();
  }

  List<GalleryDownloadInfo> _rebuildGalleriesCache() {
    final List<GalleryDownloadInfo> list = galleryDownloadInfos.values.toList();
    list.sort();
    return list;
  }

  /// Invalidate the sorted cache. Call after any mutation that could affect
  /// order or membership: add, delete, group change, group rename, priority
  /// change. (sortOrder/insertTime are immutable post-creation.)
  void _invalidateGalleriesCache() {
    _galleriesCache = null;
  }

  /// Filter galleries by group from the cached sorted [galleries] list —
  /// result preserves the canonical sort order. O(N) walk of the cache,
  /// no extra sort.
  List<GalleryDownloadInfo> galleriesWithGroup(String group) {
    return galleries.where((g) => g.group == group).toList();
  }

  static const int _maxRetryTimes = 3;
  static const int defaultDownloadGalleryPriority = 4;

  /// Backward-compat alias — external callers read this const to locate the
  /// metadata file. The canonical home is now [_GalleryMetadataStore].
  static const String metadataFileName = _GalleryMetadataStore.metadataFileName;
  static const int _priorityBase = 100000000;

  final Completer<bool> _completer = Completer();

  Future<bool> get completed => _completer.future;

  Worker? _downloadSettingListener;

  @override
  Future<void> doInitBean() async {
    Get.put(this, permanent: true);

    try {
      await _instantiateFromDB();
      log.debug('Gallery download task count: ${galleries.length}');
    } catch (e, st) {
      log.error('Failed to instantiate galleries from DB', e, st);
    } finally {
      /// Ensure [completed] is always resolved so [restoreTasks] never hangs
      /// at `await completed` even if DB initialisation fails.
      if (!_completer.isCompleted) {
        _completer.complete(true);
      }
    }

    _startExecutor();

    _downloadSettingListener = everAll(
      [downloadSetting.downloadTaskConcurrency, downloadSetting.maximum, downloadSetting.period],
      (_) {
        updateExecutor();
      },
    );

    /// Restore is deferred to first entry of the download page via
    /// [ensureRestored], matching upstream behavior. Running it at startup
    /// blocks app launch when the download directory is large (thousands
    /// of galleries). See [ensureRestored] / [download_base_page.dart].
  }

  @override
  Future<void> doAfterBeanReady() async {}

  @override
  void onClose() {
    super.onClose();

    _downloadSettingListener?.dispose();
  }

  bool containGallery(int gid) => galleryDownloadInfos.containsKey(gid);

  Future<void> downloadGallery(GalleryDownloadRequest request) async {
    if (containGallery(request.gid)) {
      return;
    }

    _ensureDownloadDirExists();

    GalleryDownloadedData gallery = _toGalleryDownloadedData(request, DownloadStatus.downloading);

    if (!await _initGalleryInfo(gallery)) {
      return;
    }

    _generateComicInfoInDisk(galleryDownloadInfos[gallery.gid]!);

    await _startDownloadTask(galleryDownloadInfos[gallery.gid]!);

    log.info('Begin to download gallery: ${gallery.title}, original: ${gallery.downloadOriginalImage}');

    /// If the caller didn't supply [oldVersionGalleryUrl] (i.e. this isn't an
    /// "Update gallery" action), fetch the parent gallery URL from the EH
    /// detail page so the "Delete history versions" feature can discover
    /// version relationships without a network deep-scan.
    if (gallery.oldVersionGalleryUrl == null) {
      _fetchAndSetOldVersionGalleryUrl(gallery).catchError((e, st) {
        log.warning('Failed to fetch parentGalleryUrl for ${gallery.gid}', e, st);
      });
    }
  }

  /// Fetch the gallery's complete ancestor chain (parent, grandparent, …)
  /// from the EH detail page and persist it as [oldVersionGalleryUrl]. Runs
  /// in the background — callers don't await it so download start isn't
  /// delayed. Used on fresh downloads (when the caller didn't supply a chain)
  /// so the "Delete history versions" feature can discover cross-version
  /// relationships without a network deep-scan, even if intermediate versions
  /// are later deleted.
  Future<void> _fetchAndSetOldVersionGalleryUrl(GalleryDownloadedData gallery) async {
    final GalleryUrl? startUrl = GalleryUrl.tryParse(gallery.galleryUrl);
    if (startUrl == null) {
      return;
    }

    final List<String> chain = await _fetchFullAncestorChain(startUrl);
    if (chain.isEmpty) {
      return;
    }

    await updateOldVersionChain(gallery.gid, chain);
    log.info('Fetched ancestor chain (length ${chain.length}) for gallery ${gallery.gid}');
  }

  /// Recursively crawl `parentGalleryUrl` links up the version tree starting
  /// from [startUrl], returning the ordered ancestor chain (direct parent
  /// first, oldest root last). Each hop requests the EH detail page with
  /// retries + site fallback. Stops when: no parent is found, max depth is
  /// reached, a cycle is detected, or a hop fails on both sites. If a
  /// discovered parent is itself a locally-downloaded gallery with a recorded
  /// chain, that chain is appended and the network crawl stops (short-circuit
  /// to reuse previously fetched ancestry and avoid redundant requests).
  ///
  /// A partial chain (collected before a mid-way network failure) is returned
  /// so the caller can persist whatever ancestry was discovered.
  Future<List<String>> _fetchFullAncestorChain(GalleryUrl startUrl) async {
    const int maxDepth = 20;
    final List<String> chain = <String>[];
    final Set<String> visited = <String>{startUrl.url};

    /// Once a hop succeeds only on the fallback site, all subsequent hops
    /// skip the original site and go straight to the site that worked.
    /// null = use the URL's own site first; true = force e-hentai; false = force exhentai.
    bool? forceIsEH;

    GalleryUrl? current = startUrl;
    for (int depth = 0; depth < maxDepth; depth++) {
      if (current == null) {
        break;
      }

      final ({String? parentUrl, bool? usedIsEH}) result =
          await _fetchParentUrlWithFallback(current, forceIsEH: forceIsEH);
      final String? parentUrl = result.parentUrl;
      if (parentUrl == null || parentUrl.isEmpty) {
        break;
      }

      /// Lock to the fallback site if this hop only succeeded there,
      /// so later hops skip the dead site entirely.
      if (forceIsEH == null && result.usedIsEH != null && result.usedIsEH != current.isEH) {
        forceIsEH = result.usedIsEH;
        log.info('version chain crawl: locking subsequent hops to ${forceIsEH! ? "e-hentai" : "exhentai"} for gallery ${startUrl.url}');
      }

      if (visited.contains(parentUrl)) {
        log.warning('version chain crawl: cycle detected at $parentUrl, stopping');
        break;
      }

      chain.add(parentUrl);
      visited.add(parentUrl);

      /// Short-circuit: if the parent is local and already has a recorded
      /// chain, append it and stop the network crawl.
      ///
      /// Match by gid+token ignoring domain: the parent URL may be an
      /// exhentai.org URL (when the fallback site was used) while the local
      /// gallery was downloaded from e-hentai.org, or vice versa.
      final GalleryUrl? parentParsed = GalleryUrl.tryParse(parentUrl);
      final GalleryDownloadInfo? parentLocal = parentParsed == null
          ? null
          : galleries.firstWhereOrNull((g) {
              GalleryUrl? gp = GalleryUrl.tryParse(g.galleryUrl);
              return gp != null &&
                  gp.gid == parentParsed.gid &&
                  gp.token == parentParsed.token;
            });
      if (parentLocal != null && parentLocal.hasVersionChain) {
        for (final String ancestor in parentLocal.oldVersionChain) {
          if (!visited.contains(ancestor)) {
            chain.add(ancestor);
            visited.add(ancestor);
          }
        }
        break;
      }

      current = GalleryUrl.tryParse(parentUrl);
    }

    return chain;
  }

  /// Fetch a single gallery's parent URL from the EH detail page, with retries
  /// on the original site then retries on the opposite site. Returns the
  /// parent URL string (or null on failure / no-parent) and the site that
  /// actually responded ([usedIsEH], null when no site responded).
  ///
  /// [forceIsEH] skips the original-site attempt and goes straight to the
  /// specified site. Set by the caller after an earlier hop only succeeded
  /// on the fallback site, to avoid wasting a round-trip on the dead site.
  Future<({String? parentUrl, bool? usedIsEH})> _fetchParentUrlWithFallback(
    GalleryUrl galleryUrl, {
    bool? forceIsEH,
  }) async {
    if (forceIsEH != null) {
      final GalleryUrl forcedUrl = galleryUrl.copyWith(isEH: forceIsEH);
      final String? parent = await _tryFetchParentUrl(forcedUrl.url);
      return (parentUrl: parent, usedIsEH: parent != null ? forceIsEH : null);
    }

    final String? parent = await _tryFetchParentUrl(galleryUrl.url);
    if (parent != null) {
      return (parentUrl: parent, usedIsEH: galleryUrl.isEH);
    }

    final GalleryUrl altUrl = galleryUrl.copyWith(isEH: !galleryUrl.isEH);
    final String? parent2 = await _tryFetchParentUrl(altUrl.url);
    return (parentUrl: parent2, usedIsEH: parent2 != null ? altUrl.isEH : null);
  }

  /// Request one detail page and extract parentGalleryUrl. Returns null on
  /// network failure after retries or when the gallery has no parent.
  Future<String?> _tryFetchParentUrl(String url) async {
    try {
      final ({GalleryDetail galleryDetails, String apikey}) result = await retry(
        () => ehRequest.requestDetailPage(
          galleryUrl: url,
          useCacheIfAvailable: true,
          parser: EHSpiderParser.detailPage2GalleryAndDetailAndApikey,
        ),
        retryIf: (e) => e is DioException,
        maxAttempts: 3,
      );
      return result.galleryDetails.parentGalleryUrl?.url;
    } catch (e) {
      return null;
    }
  }

  /// Public API for backfilling a single-hop parent URL as
  /// [oldVersionGalleryUrl] on an already-downloaded gallery. Updates the DB
  /// row, the in-memory [GalleryDownloadInfo], and the on-disk metadata file.
  /// Used by [_fetchAndSetOldVersionGalleryUrl] on fresh downloads.
  ///
  /// The parent URL is stored as a single-element chain `["parentUrl"]` so the
  /// storage format is uniform. To record a multi-hop ancestor chain (e.g.
  /// discovered by the batch-fetch dialog's recursive crawl), use
  /// [updateOldVersionChain] instead.
  Future<void> updateOldVersionGalleryUrl(int gid, String parentUrl) async {
    return updateOldVersionChain(gid, <String>[parentUrl]);
  }

  /// Public API for backfilling a complete ancestor chain (ordered from direct
  /// parent at index 0 to the oldest known root at the last index) as
  /// [oldVersionGalleryUrl]. Updates the DB row, the in-memory
  /// [GalleryDownloadInfo], and the on-disk metadata file. Used by the
  /// batch-fetch dialog when it recursively crawls parent links.
  ///
  /// Passing an empty chain clears the recorded relationship (stores null).
  Future<void> updateOldVersionChain(int gid, List<String> chain) async {
    final String? encoded = GalleryDownloadInfo.encodeVersionChain(chain);
    await _updateGalleryInDatabase(
      GalleryDownloadedCompanion(gid: Value(gid), oldVersionGalleryUrl: Value(encoded)),
    );
    final GalleryDownloadInfo? info = galleryDownloadInfos[gid];
    if (info != null) {
      info.oldVersionGalleryUrl = encoded;
      _saveGalleryMetadataInDisk(info);
    }
  }

  Future<void> _startDownloadTask(GalleryDownloadInfo info) async {
    info.speedComputer.start();

    /// Pre-load full images so synchronous reads during download (e.g.
    /// `_downloadImageTask` reading `image.url`) work without per-call awaits.
    await info.ensureImagesLoaded();

    _submitTask(
      gid: info.gid,
      priority: _computeGalleryTaskPriority(info),
      task: _GalleryDownloadTaskRunner(this, info).downloadGalleryTask(),
    );
  }

  /// Convert a [GalleryDownloadRequest] BO to the DB-row shape for internal
  /// persistence. Status, sortOrder, insertTime, and priority are service-
  /// owned — callers cannot set them.
  GalleryDownloadedData _toGalleryDownloadedData(GalleryDownloadRequest request, DownloadStatus status) {
    /// Compute sanitizedTitle up-front so the row is born with the path that
    /// will be frozen for the lifetime of this download task.
    final int reservedBytes = utf8.encode('${request.gid} - ').length;
    return GalleryDownloadedData(
      gid: request.gid,
      token: request.token,
      title: request.title,
      category: request.category,
      pageCount: request.pageCount,
      galleryUrl: request.galleryUrl,
      oldVersionGalleryUrl: request.oldVersionGalleryUrl,
      uploader: request.uploader,
      publishTime: request.publishTime,
      downloadStatusIndex: status.index,
      insertTime: request.insertTime ?? DateTime.now().toString(),
      downloadOriginalImage: request.downloadOriginalImage,
      priority: request.priority ?? defaultDownloadGalleryPriority,
      sortOrder: request.sortOrder ?? 0,
      groupName: request.group,
      tags: request.tags,
      tagRefreshTime: request.tagRefreshTime,
      sanitizedTitle: DownloadPathResolver.computeSanitizedGalleryTitle(request.title, reservedBytes),
    );
  }

  Future<void> pauseAllDownloadGallery() async {
    /// Snapshot the downloading galleries — pauseDownloadGallery mutates
    /// `downloadProgress.downloadStatus` mid-iteration, so we can't filter
    /// lazily against the live map.
    final List<GalleryDownloadInfo> downloading = galleryDownloadInfos.values.where((g) => g.downloadProgress.downloadStatus == DownloadStatus.downloading).toList();
    if (downloading.isEmpty) {
      return;
    }

    /// Single transaction: bulk gallery status + bulk image status.
    /// Avoids N per-gallery DB round-trips (one UPDATE + one image-batch
    /// UPDATE per gallery × thousands of galleries).
    ///
    /// CAS guard: pass `fromStatusIndex: downloading` so a gallery already
    /// flipped to `downloaded` by a concurrent `_updateProgressAfterImageDownloaded`
    /// is NOT overwritten back to `paused` — its WHERE clause won't match.
    /// The image-side UPDATE carries the same condition implicitly via
    /// `WHERE downloadStatusIndex = downloading`. Memory-side re-check at
    /// line 262 (`_liveInfoOrSkip`) catches any concurrent winner.
    await appDb.transaction(() async {
      await GalleryDao.batchUpdateGallery(
        downloading
            .map((g) => GalleryDownloadedCompanion(
                  gid: Value(g.gid),
                  downloadStatusIndex: Value(DownloadStatus.paused.index),
                ))
            .toList(),
        fromStatusIndex: DownloadStatus.downloading.index,
      );
      await GalleryImageDao.updateImageStatusByGids(
        downloading.map((g) => g.gid),
        DownloadStatus.downloading.index,
        DownloadStatus.paused.index,
      );
    });

    /// In-memory + UI updates per gallery. No further DB writes here.
    for (final gallery in downloading) {
      /// Re-check status after the transaction's await. A concurrent path
      /// (deleteGallery → _clearGalleryInfoInMemory, or a download completing
      /// → _updateProgressAfterImageDownloaded flipping status to downloaded)
      /// may have already mutated or removed this entry. Skip the in-memory
      /// mutation if so — the winning path's state should be honored, and
      /// the DB writes from the transaction above remain authoritative.
      final GalleryDownloadInfo? info = _liveInfoOrSkip(gallery.gid, DownloadStatus.downloading);
      if (info == null) {
        continue;
      }
      info.downloadProgress.downloadStatus = DownloadStatus.paused;

      for (AsyncTask task in info.tasks) {
        executor.cancelTask(task);
      }
      info.tasks.clear();
      info.cancelToken.cancel();
      info.speedComputer.pause();

      for (GalleryImage? img in info.images ?? <GalleryImage?>[]) {
        if (img?.downloadStatus == DownloadStatus.downloading) {
          img?.downloadStatus = DownloadStatus.paused;
          update(['$downloadImageId::${gallery.gid}']);
        }
      }

      await _flushMetadataSave(gallery);
      update(['$galleryDownloadProgressId::${gallery.gid}']);
    }
  }

  GalleryDownloadInfo? _findGalleryByGid(int gid) => galleryDownloadInfos[gid];

  /// Concurrency-safe lookup for use at await boundaries in multi-step
  /// operations (pauseAll / resumeAll / etc.). Returns the live info iff the
  /// gallery is still resident AND its `downloadStatus` still matches
  /// [expected]; otherwise null.
  ///
  /// A null return means a concurrent path (deleteGallery, completed
  /// download, _pauseOnSiteError, etc.) has mutated or removed the entry —
  /// the caller should bail out of its remaining in-memory mutations to
  /// avoid (a) null-bang crashes from `galleryDownloadInfos[gid]!` and
  /// (b) overwriting the winning path's state with stale values. DB writes
  /// that already landed in the transaction remain authoritative.
  GalleryDownloadInfo? _liveInfoOrSkip(int gid, DownloadStatus expected) {
    final GalleryDownloadInfo? info = galleryDownloadInfos[gid];
    if (info == null || info.downloadProgress.downloadStatus != expected) {
      return null;
    }
    return info;
  }

  Future<void> pauseDownloadGalleryByGid(int gid) async {
    GalleryDownloadInfo? gallery = _findGalleryByGid(gid);
    if (gallery != null) {
      return pauseDownloadGallery(gallery);
    }
  }

  Future<void> pauseDownloadGallery(GalleryDownloadInfo gallery) async {
    GalleryDownloadInfo galleryDownloadInfo = galleryDownloadInfos[gallery.gid]!;
    GalleryDownloadProgress downloadProgress = galleryDownloadInfo.downloadProgress;

    if (downloadProgress.downloadStatus != DownloadStatus.downloading) {
      return;
    }

    if (!await _updateGalleryInDatabase(
      GalleryDownloadedCompanion(gid: Value(gallery.gid), downloadStatusIndex: Value(DownloadStatus.paused.index)),
    )) {
      return;
    }

    downloadProgress.downloadStatus = DownloadStatus.paused;
    update(['$galleryDownloadProgressId::${gallery.gid}']);

    for (AsyncTask task in galleryDownloadInfo.tasks) {
      executor.cancelTask(task);
    }

    galleryDownloadInfo.tasks.clear();
    galleryDownloadInfo.cancelToken.cancel();
    galleryDownloadInfo.speedComputer.pause();

    /// Persist per-image paused status so a restart doesn't leave stale
    /// `downloading` rows on a paused gallery — the in-memory coercion below
    /// would otherwise be lost on `_instantiateFromDB`'s DB read.
    await GalleryImageDao.updateImageStatusByGallery(
      gallery.gid,
      DownloadStatus.downloading.index,
      DownloadStatus.paused.index,
    );

    for (GalleryImage? img in galleryDownloadInfo.images ?? <GalleryImage?>[]) {
      if (img?.downloadStatus == DownloadStatus.downloading) {
        img?.downloadStatus = DownloadStatus.paused;
        update(['$downloadImageId::${gallery.gid}']);
      }
    }

    await _flushMetadataSave(gallery);

    log.info('Pause download gallery: ${gallery.title}');
  }

  Future<void> resumeAllDownloadGallery() async {
    final List<GalleryDownloadInfo> paused = galleryDownloadInfos.values.where((g) => g.downloadProgress.downloadStatus == DownloadStatus.paused).toList();
    if (paused.isEmpty) return;

    /// Single transaction: bulk gallery status + bulk image status.
    /// CAS guard: pass `fromStatusIndex: paused` so a gallery flipped away
    /// from `paused` by a concurrent path (e.g. deleteGallery) is skipped.
    await appDb.transaction(() async {
      await GalleryDao.batchUpdateGallery(
        paused
            .map((g) => GalleryDownloadedCompanion(
                  gid: Value(g.gid),
                  downloadStatusIndex: Value(DownloadStatus.downloading.index),
                ))
            .toList(),
        fromStatusIndex: DownloadStatus.paused.index,
      );
      await GalleryImageDao.updateImageStatusByGids(
        paused.map((g) => g.gid),
        DownloadStatus.paused.index,
        DownloadStatus.downloading.index,
      );
    });

    for (final gallery in paused) {
      final GalleryDownloadInfo? info = _liveInfoOrSkip(gallery.gid, DownloadStatus.paused);
      if (info == null) {
        continue;
      }
      info.downloadProgress.downloadStatus = DownloadStatus.downloading;

      /// can't reuse cancelToken across pause/resume
      info.cancelToken = CancelToken();
      info.speedComputer.start();

      for (GalleryImage? img in info.images ?? <GalleryImage?>[]) {
        if (img?.downloadStatus == DownloadStatus.paused) {
          img?.downloadStatus = DownloadStatus.downloading;
          update(['$downloadImageId::${gallery.gid}']);
        }
      }

      _saveGalleryMetadataInDisk(gallery);
      update(['$galleryDownloadProgressId::${gallery.gid}']);

      /// Re-submit the gallery task — single-launch, no per-image await needed.
      _submitTask(
        gid: info.gid,
        priority: _computeGalleryTaskPriority(info),
        task: _GalleryDownloadTaskRunner(this, info).downloadGalleryTask(),
      );
    }
  }

  Future<void> resumeDownloadGalleryByGid(int gid) async {
    GalleryDownloadInfo? gallery = _findGalleryByGid(gid);
    if (gallery != null) {
      return resumeDownloadGallery(gallery);
    }
  }

  Future<void> resumeDownloadGallery(GalleryDownloadInfo gallery) async {
    GalleryDownloadInfo galleryDownloadInfo = galleryDownloadInfos[gallery.gid]!;
    GalleryDownloadProgress downloadProgress = galleryDownloadInfo.downloadProgress;

    if (downloadProgress.downloadStatus != DownloadStatus.paused) {
      return;
    }

    if (!await _updateGalleryInDatabase(
      GalleryDownloadedCompanion(gid: Value(gallery.gid), downloadStatusIndex: Value(DownloadStatus.downloading.index)),
    )) {
      return;
    }

    downloadProgress.downloadStatus = DownloadStatus.downloading;
    update(['$galleryDownloadProgressId::${gallery.gid}']);

    /// can't reuse
    galleryDownloadInfo.cancelToken = CancelToken();
    galleryDownloadInfo.speedComputer.start();

    /// Mirror the pause-time batch write: flip persisted `paused` rows back to
    /// `downloading` so the DB matches in-memory state.
    await GalleryImageDao.updateImageStatusByGallery(
      gallery.gid,
      DownloadStatus.paused.index,
      DownloadStatus.downloading.index,
    );

    for (GalleryImage? img in galleryDownloadInfo.images ?? <GalleryImage?>[]) {
      if (img?.downloadStatus == DownloadStatus.paused) {
        img?.downloadStatus = DownloadStatus.downloading;
        update(['$downloadImageId::${gallery.gid}']);
      }
    }

    log.info('Resume download gallery: ${gallery.title}');

    _saveGalleryMetadataInDisk(gallery);

    _resumeDownloadGallery(gallery.gid);
  }

  /// Resume a paused download. The [GalleryDownloadInfo] must already exist.
  Future<void> _resumeDownloadGallery(int gid) async {
    await _startDownloadTask(galleryDownloadInfos[gid]!);
  }

  Future<void> deleteGalleryByGid(int gid) async {
    GalleryDownloadInfo? gallery = _findGalleryByGid(gid);
    if (gallery != null) {
      return deleteGallery(gallery);
    }
  }

  Future<void> deleteGallery(GalleryDownloadInfo gallery, {bool deleteImages = true}) async {
    await pauseDownloadGallery(gallery);

    log.info('Delete download gallery: ${gallery.title}, deleteImages:$deleteImages');

    await superResolutionService.deleteSuperResolve(gallery.gid, SuperResolutionType.gallery);

    await _clearGalleryDownloadInfoInDatabase(gallery.gid);
    if (deleteImages) {
      _clearDownloadedImageInDisk(gallery);
    }
    _clearGalleryInfoInMemory(gallery);
  }

  /// Update local downloaded gallery if there's a new version.
  Future<void> updateGallery(GalleryDownloadInfo oldGallery, GalleryUrl newVersionGalleryUrl) async {
    log.info('update gallery: ${oldGallery.title}');

    GalleryDetail newGalleryDetail;
    try {
      ({GalleryDetail galleryDetails, String apikey}) detailPageInfo = await retry(
        () => ehRequest.requestDetailPage(galleryUrl: newVersionGalleryUrl.url, parser: EHSpiderParser.detailPage2GalleryAndDetailAndApikey),
        retryIf: (e) => e is DioException,
        maxAttempts: _maxRetryTimes,
      );
      newGalleryDetail = detailPageInfo.galleryDetails;
    } on DioException catch (e) {
      log.info('${'updateGalleryError'.tr}, reason: ${e.errorMsg}');
      snack('updateGalleryError'.tr, e.errorMsg ?? '', isShort: true);
      return;
    } on EHSiteException catch (e) {
      log.info('${'updateGalleryError'.tr}, reason: ${e.message}');
      snack('updateGalleryError'.tr, e.message, isShort: true);
      pauseAllDownloadGallery();
      return;
    }

    GalleryDownloadRequest newGalleryRequest = GalleryDownloadRequest(
      gid: newGalleryDetail.galleryUrl.gid,
      token: newGalleryDetail.galleryUrl.token,
      title: newGalleryDetail.japaneseTitle ?? newGalleryDetail.rawTitle,
      category: newGalleryDetail.category,
      pageCount: newGalleryDetail.pageCount,
      galleryUrl: newGalleryDetail.galleryUrl.url,
      uploader: newGalleryDetail.uploader,
      publishTime: newGalleryDetail.publishTime,
      downloadOriginalImage: oldGallery.downloadOriginalImage,
      group: oldGallery.group,
      tags: tagMap2TagString(newGalleryDetail.tags),
      tagRefreshTime: DateTime.now().toString(),
      oldVersionGalleryUrl: GalleryDownloadInfo.encodeVersionChain(
        <String>[oldGallery.galleryUrl, ...oldGallery.oldVersionChain],
      ),
    );

    downloadGallery(newGalleryRequest);
  }

  Future<void> reDownloadGalleryByGid(int gid) async {
    GalleryDownloadInfo? gallery = _findGalleryByGid(gid);
    if (gallery != null) {
      return reDownloadGallery(gallery);
    }
  }

  Future<void> reDownloadGallery(GalleryDownloadInfo gallery) async {
    log.info('Re-download gallery: ${gallery.gid}');

    GalleryDownloadRequest request = gallery.toGalleryDownloadRequest();
    await deleteGallery(gallery);

    downloadGallery(request);
  }

  Future<void> reDownloadImage(int gid, int serialNo) async {
    GalleryDownloadInfo? gallery = _findGalleryByGid(gid);
    if (gallery == null) {
      return;
    }

    await gallery.ensureImagesLoaded();
    final GalleryImage? image = gallery.imageAtSync(serialNo);
    if (image == null) {
      return;
    }

    log.info('Re-download image, gid: $gid, index: $serialNo');

    /// Snapshot the per-image downloaded flag and materialize the list BEFORE
    /// the status flip below. [GalleryDownloadProgress.hasDownloaded]
    /// synthesizes an all-true list for `downloaded` galleries (backing
    /// `_hasDownloaded` stays null); reading it after the CAS to `downloading`
    /// would lazily allocate an all-false list — this decrement would never
    /// fire, curCount would overshoot pageCount, and the gallery would stall
    /// in `downloading` (the `curCount == totalCount` completion check would
    /// never match again).
    final bool wasDownloaded = gallery.downloadProgress.hasDownloaded[serialNo];

    /// Copy the synthesized list into `_hasDownloaded` while still in the old
    /// status, so flipping this one image back to downloading below doesn't
    /// reset every other downloaded image's flag to false.
    gallery.downloadProgress.hasDownloaded = List<bool>.from(gallery.downloadProgress.hasDownloaded);

    /// If the gallery is not currently `downloading`, CAS-flip it to
    /// `downloading` first (gated on the current status). This covers both
    /// `downloaded` (re-download a completed gallery's image) and `paused`
    /// (re-download while paused — implicit resume). CAS-first ensures that
    /// if a concurrent path (deleteGallery, pauseAll, resumeAll) beat us to
    /// the status flip, we bail BEFORE touching memory, image rows, or disk
    /// files. A gallery already in `downloading` needs no flip — its task
    /// pipeline is in flight and will (re)process this image.
    final DownloadStatus currentStatus = gallery.downloadProgress.downloadStatus;
    if (currentStatus != DownloadStatus.downloading) {
      final bool flipped = await _updateGalleryDownloadStatus(
        gallery,
        DownloadStatus.downloading,
        fromStatus: currentStatus,
      );
      if (!flipped) {
        log.download('reDownloadImage: CAS failed (gid=$gid, expected=$currentStatus→downloading); concurrent path won, bailing.');
        return;
      }
    }

    await _updateImageStatus(gallery, image, serialNo, DownloadStatus.downloading);

    _deleteImageInDisk(image);

    if (wasDownloaded) {
      gallery.downloadProgress.curCount--;
    }
    gallery.downloadProgress.hasDownloaded[serialNo] = false;
    gallery.speedComputer.resetProgress(serialNo);
    gallery.speedComputer.start();

    update(['$galleryDownloadSuccessId::${gallery.gid}', '$galleryDownloadProgressId::${gallery.gid}']);

    _GalleryDownloadTaskRunner(this, gallery)._reParseImageUrlAndDownload(serialNo);
  }

  Future<void> assignPriority(GalleryDownloadInfo gallery, int priority) async {
    if (priority == galleryDownloadInfos[gallery.gid]?.priority) {
      return;
    }

    log.info('Assign priority, gid: ${gallery.gid}, priority: $priority');

    if (!await _updateGalleryInDatabase(
      GalleryDownloadedCompanion(gid: Value(gallery.gid), priority: Value(priority)),
    )) {
      return;
    }

    galleryDownloadInfos[gallery.gid]!.priority = priority;
    _invalidateGalleriesCache();

    if (galleryDownloadInfos[gallery.gid]?.downloadProgress.downloadStatus == DownloadStatus.downloading) {
      await pauseDownloadGallery(gallery);
      await resumeDownloadGallery(gallery);
    }
  }

  Future<bool> updateGroupByGid(int gid, String group) async {
    GalleryDownloadInfo? gallery = _findGalleryByGid(gid);
    if (gallery != null) {
      return updateGroup(gallery, group);
    }
    return false;
  }

  Future<bool> updateGroup(GalleryDownloadInfo gallery, String group) async {
    /// Atomically create the group (if new) and update the gallery's group column.
    /// Without a transaction, a failure in the gallery update would leave an orphan
    /// group row in [gallery_group] — and in-memory state would already be mutated.
    bool success = await appDb.transaction(() async {
      if (!allGroups.contains(group) && !await _addGroup(group)) {
        return false;
      }
      return _updateGalleryInDatabase(
        GalleryDownloadedCompanion(gid: Value(gallery.gid), groupName: Value(group)),
      );
    });

    if (!success) {
      return false;
    }

    galleryDownloadInfos[gallery.gid]?.group = group;
    _invalidateGalleriesCache();
    _saveGalleryMetadataInDisk(gallery);

    return true;
  }

  Future<void> renameGroup(String oldGroup, String newGroup) async {
    List<GalleryDownloadInfo> galleriesInGroup = galleriesWithGroup(oldGroup);

    await appDb.transaction(() async {
      if (!allGroups.contains(newGroup) && !await _addGroup(newGroup)) {
        return;
      }

      for (GalleryDownloadInfo g in galleriesInGroup) {
        g.group = newGroup;
        await _updateGalleryInDatabase(
          GalleryDownloadedCompanion(gid: Value(g.gid), groupName: Value(newGroup)),
        );
      }

      await _deleteGroup(oldGroup);
    });

    /// Mark dirty after the transaction commits — `_saveGalleryMetadataInDisk`
    /// schedules a throttled disk write via timer, which must not be armed
    /// inside a DB transaction (the write would race with rollback).
    for (GalleryDownloadInfo g in galleriesInGroup) {
      _saveGalleryMetadataInDisk(g);
    }

    _invalidateGalleriesCache();
  }

  Future<void> deleteGroup(String group) {
    return _deleteGroup(group);
  }

  Future<void> updateGalleryOrder(List<GalleryDownloadInfo> galleries) async {
    await appDb.transaction(() async {
      for (GalleryDownloadInfo gallery in galleries) {
        await _updateGalleryInDatabase(
          GalleryDownloadedCompanion(gid: Value(gallery.gid), sortOrder: Value(gallery.sortOrder)),
        );
      }
    });

    _invalidateGalleriesCache();

    for (GalleryDownloadInfo gallery in galleries) {
      _saveGalleryMetadataInDisk(gallery);
    }
  }

  Future<void> updateGroupOrder(int beforeIndex, int afterIndex) async {
    if (afterIndex == allGroups.length - 1) {
      allGroups.add(allGroups.removeAt(beforeIndex));
    } else {
      allGroups.insert(afterIndex, allGroups.removeAt(beforeIndex));
    }

    log.info('Update group order: $allGroups');

    await appDb.transaction(() async {
      for (int i = 0; i < allGroups.length; i++) {
        await GalleryGroupDao.updateGalleryGroupOrder(allGroups[i], i);
      }
    });
  }

  bool isUpdatingDependent(int gid) {
    GalleryDownloadInfo? gallery = galleries.firstWhereOrNull((g) => g.gid == gid);
    if (gallery == null) {
      return false;
    }

    /// Match by gid+token ignoring domain: directParentUrl may be stored as
    /// an exhentai.org URL while the parent's galleryUrl is e-hentai.org.
    final GalleryUrl? galleryParsed = GalleryUrl.tryParse(gallery.galleryUrl);
    GalleryDownloadInfo? oldGallery = galleryParsed == null
        ? null
        : galleries.firstWhereOrNull((g) {
            String? dp = g.directParentUrl;
            if (dp == null) return false;
            GalleryUrl? dpParsed = GalleryUrl.tryParse(dp);
            return dpParsed != null &&
                dpParsed.gid == galleryParsed.gid &&
                dpParsed.token == galleryParsed.token;
          });
    if (oldGallery == null) {
      return false;
    }

    return oldGallery.downloadProgress.downloadStatus != DownloadStatus.downloaded;
  }

  /// Use metadata in each gallery folder to restore download status, then sync to database.
  /// This is used after re-install app, or share download folder to another user.
  ///
  /// Metadata parsing runs in a background isolate to avoid UI jank when
  /// hundreds of galleries each parse a multi-KB JSON file. DB writes stay on
  /// the main isolate (Drift's connection isn't isolate-safe).
  ///
  /// Concurrent calls are coalesced — if a restore is already in flight, the
  /// caller awaits the same future instead of starting a second pass (which
  /// would race on DB inserts and double-count galleries).
  Future<int>? _restoreTasksFuture;

  /// Whether a [restoreTasks] pass is currently in flight.
  bool get isRestoring => _restoreTasksFuture != null;

  /// Restore progress for UI display. Updated during [_doRestoreTasks].
  int restoreTotalDirectories = 0;
  int restoreScannedDirectories = 0;
  int restoreParsedMetadata = 0;
  int restoreRestoredGalleries = 0;

  /// Current restore phase for UI display.
  /// 0 = idle/done, 1 = parsing metadata, 2 = restoring to DB/memory.
  int restorePhase = 0;

  /// When true, [_buildGalleryInfoInMemory] skips the per-gallery
  /// [update] call so batch restores don't trigger 3000+ UI rebuilds.
  /// The caller (e.g. [_doRestoreTasks]) is responsible for calling
  /// [update] at appropriate intervals and once at the end.
  bool _batchRestoreMode = false;

  /// Trigger restore when entering the download page, regardless of
  /// [downloadSetting.restoreTasksAutomatically]. Safe to call multiple
  /// times — [restoreTasks] coalesces concurrent triggers.
  ///
  /// After restore, runs [verifyDownloadedGalleriesMetadata] to catch
  /// galleries whose metadata exists on disk but were skipped or failed
  /// during the initial restore (e.g. a transient parse error), and to
  /// log sanitizedTitle mismatches that would cause wrong path lookups.
  /// Coalesces concurrent [verifyDownloadedGalleriesMetadata] calls so
  /// multiple [ensureRestored] invocations (e.g. from repeated
  /// [DownloadPage.initState]) don't run the scan in parallel and
  /// oscillate sanitizedTitle between duplicate directories.
  Future<int>? _verifyFuture;

  Future<void> ensureRestored() async {
    log.info('ensureRestored: called');
    await restoreTasks();
    await verifyDownloadedGalleriesMetadata();
  }

  /// Scan the download directory for gallery metadata files and verify that
  /// every gallery on disk has a corresponding in-memory
  /// [GalleryDownloadInfo]. This catches two classes of problems:
  ///
  /// 1. **Metadata exists but gallery not in memory** — the initial
  ///    [restoreTasks] parse failed (transient I/O error, corrupt JSON, …)
  ///    and the gallery was silently skipped. We re-read the metadata and
  ///    restore the gallery.
  ///
  /// 2. **sanitizedTitle mismatch** — the directory name doesn't match the
  ///    `sanitizedTitle` stored in memory/DB (e.g. the user renamed the
  ///    directory, or the sanitisation rules changed between versions).
  ///    We update the DB row so path lookups succeed on next launch.
  ///
  /// Runs after [restoreTasks] completes.  Cheap when everything is
  /// consistent: it only stats files and compares strings, re-reading
  /// metadata only for galleries that are missing from memory.
  Future<int> verifyDownloadedGalleriesMetadata() async {
    /// Coalesce concurrent calls — multiple ensureRestored() invocations
    /// (e.g. from repeated DownloadPage.initState) would otherwise run
    /// the scan in parallel and oscillate sanitizedTitle between
    /// duplicate directories on disk.
    if (_verifyFuture != null) {
      return _verifyFuture!;
    }
    _verifyFuture = _doVerifyDownloadedGalleriesMetadata();
    try {
      return await _verifyFuture!;
    } finally {
      _verifyFuture = null;
    }
  }

  Future<int> _doVerifyDownloadedGalleriesMetadata() async {
    await completed;

    final String downloadPath = downloadSetting.downloadPath.value;
    final String visibleDirPath = pathService.getVisibleDir().path;
    final io.Directory downloadDir = io.Directory(downloadPath);
    if (!await downloadDir.exists()) {
      return 0;
    }

    int repairedCount = 0;

    final List<io.Directory> galleryDirs = <io.Directory>[];
    await for (final entity in downloadDir.list()) {
      if (entity is io.Directory) {
        galleryDirs.add(entity);
      }
    }

    /// Group directories by gid and select the best one for each gid.
    /// When duplicate directories exist (e.g. truncated-title dir from an
    /// older sanitisation algorithm + full-title dir from the current one),
    /// processing both causes oscillation: the first dir switches
    /// sanitizedTitle and may reset the gallery to paused; the second dir
    /// switches it back but can't restore the downloaded status.  By picking
    /// only the directory with the most files per gid, we avoid this.
    final Map<int, io.Directory> bestDirByGid = <int, io.Directory>{};
    final Map<int, int> fileCountByGid = <int, int>{};
    for (final io.Directory dir in galleryDirs) {
      final io.File metadataFile =
          io.File(path.join(dir.path, _GalleryMetadataStore.metadataFileName));
      if (!await metadataFile.exists()) {
        continue;
      }
      final int? gid = _tryExtractGidFromDirName(dir.path);
      if (gid == null) {
        continue;
      }
      int fileCount = 0;
      try {
        await for (final _ in dir.list()) {
          fileCount++;
        }
      } catch (_) {}
      final int? prevCount = fileCountByGid[gid];
      if (prevCount == null || fileCount > prevCount) {
        bestDirByGid[gid] = dir;
        fileCountByGid[gid] = fileCount;
      }
    }

    final List<io.Directory> dirsToProcess = bestDirByGid.values.toList();
    final List<int> gidsToProcess = bestDirByGid.keys.toList();

    for (int i = 0; i < dirsToProcess.length; i++) {
      final io.Directory dir = dirsToProcess[i];
      final int gidFromName = gidsToProcess[i];

      final GalleryDownloadInfo? info = galleryDownloadInfos[gidFromName];

      /// Already loaded — verify path consistency.
      if (info != null) {
        final String expectedPath =
            DownloadPathResolver.computeGalleryDownloadAbsolutePath(info.toGalleryDownloadedData());
        final bool titleMismatch = !path.equals(expectedPath, dir.path);

        /// When there's a title mismatch, the disk may contain **two**
        /// directories for the same gid (e.g. a truncated-title dir from an
        /// older sanitisation algorithm and a full-title dir from the
        /// current one).  Before switching sanitizedTitle to this
        /// directory's name, check whether the **current** expected path
        /// already exists and has a valid cover file.  If it does, this
        /// directory is a stale duplicate and we skip the mismatch repair
        /// — otherwise we'd oscillate sanitizedTitle between the two
        /// directories across runs, and if the stale duplicate is processed
        /// last the gallery gets reset to paused because its cover file
        /// doesn't exist.  We still fall through to the restore check
        /// below so a previously-reset gallery can be recovered.
        bool skipMismatchRepair = false;
        if (titleMismatch) {
          final bool currentPathValid =
              await io.Directory(expectedPath).exists() &&
              info.coverImage?.path != null &&
              await io.File(
                DownloadPathResolver.computeImageDownloadAbsolutePathFromRelativePath(info.coverImage!.path!),
              ).exists();
          if (currentPathValid) {
            log.info('verifyMetadata: skipping stale duplicate directory for gallery $gidFromName: ${dir.path}');
            skipMismatchRepair = true;
          }
        }

        if (!skipMismatchRepair) {
        /// Detect stale image paths independently: sanitizedTitle may have
        /// been repaired in a prior run while image paths were not, so the
        /// gallery directory now matches but cover/thumbnail files still point
        /// at the old (full-title) directory. Probe the cover file directly.
        bool pathStale = false;
        if (info.coverImage?.path != null) {
          final String coverAbs =
              DownloadPathResolver.computeImageDownloadAbsolutePathFromRelativePath(info.coverImage!.path!);
          pathStale = !await io.File(coverAbs).exists();
        }

        if (titleMismatch || pathStale) {
          final String dirName = path.basename(dir.path);
          final String diskTitle = dirName.substring('$gidFromName - '.length);
          if (titleMismatch) {
            log.warning('verifyMetadata: sanitizedTitle mismatch for gallery $gidFromName: '
                'memory="${info.sanitizedTitle}" disk="$diskTitle"');
            await _updateGalleryInDatabase(
              GalleryDownloadedCompanion(gid: Value(gidFromName), sanitizedTitle: Value(diskTitle)),
            );
            info.sanitizedTitle = diskTitle;
          } else {
            log.warning('verifyMetadata: image paths stale for gallery $gidFromName, recomputing');
          }
          /// Recompute every image path so cover/thumbnail loading points at
          /// the real on-disk directory.
          await info.ensureImagesLoaded();
          for (int serialNo = 0; serialNo < info.pageCount; serialNo++) {
            final GalleryImage? img = info.imageAtSync(serialNo);
            if (img == null) {
              continue;
            }
            final String newPath = DownloadPathResolver.computeImageDownloadRelativePath(
              info.toGalleryDownloadedData(),
              _downloadUrlFor(info.toGalleryDownloadedData(), img),
              serialNo,
            );
            if (img.path == newPath) {
              continue;
            }
            await _updateImageInDatabase(
              ImageCompanion(gid: Value(info.gid), serialNo: Value(serialNo), path: Value(newPath)),
            );
            info.updateImagePath(serialNo, newPath);
            update(['$downloadImageId::${info.gid}::$serialNo', '$downloadImageUrlId::${info.gid}::$serialNo']);
          }
          /// After recompute, probe the cover file again. If it still doesn't
          /// exist, the gallery was marked downloaded but files are genuinely
          /// missing (only metadata on disk) — reset to paused so the user can
          /// re-download instead of the read page loading non-existent files.
          if (info.downloadProgress.downloadStatus == DownloadStatus.downloaded &&
              info.coverImage?.path != null) {
            final String coverAbsAfter =
                DownloadPathResolver.computeImageDownloadAbsolutePathFromRelativePath(info.coverImage!.path!);
            if (!await io.File(coverAbsAfter).exists()) {
              log.warning('verifyMetadata: files missing for downloaded gallery $gidFromName, resetting to paused');
              await _updateGalleryInDatabase(
                GalleryDownloadedCompanion(gid: Value(info.gid), downloadStatusIndex: Value(DownloadStatus.paused.index)),
              );
              info.downloadProgress.downloadStatus = DownloadStatus.paused;
              info.downloadProgress.curCount = 0;
              await GalleryImageDao.updateImageStatusByGallery(info.gid, DownloadStatus.downloaded.index, DownloadStatus.none.index);
              for (GalleryImage? img in info.images ?? <GalleryImage?>[]) {
                if (img?.downloadStatus == DownloadStatus.downloaded) {
                  img?.downloadStatus = DownloadStatus.none;
                }
              }
              update(['$galleryDownloadProgressId::${info.gid}', '$downloadImageId::${info.gid}']);
            }
          }


          repairedCount++;
        }
        } // end if (!skipMismatchRepair)

        /// Reverse check: if the gallery is paused with curCount=0 (the
        /// signature of a previous verify reset, not a user pause), and the
        /// cover file exists at the current path, restore to downloaded.
        /// This recovers galleries that were incorrectly reset by a prior
        /// verify run before the duplicate-directory grouping fix.  Runs
        /// outside the mismatch block so it also fires when sanitizedTitle
        /// and paths are already correct (the previous run fixed the path
        /// but left the status as paused).
        if (info.downloadProgress.downloadStatus == DownloadStatus.paused &&
            info.downloadProgress.curCount == 0 &&
            info.coverImage?.path != null) {
          final String coverAbs =
              DownloadPathResolver.computeImageDownloadAbsolutePathFromRelativePath(info.coverImage!.path!);
          if (await io.File(coverAbs).exists()) {
            log.info('verifyMetadata: restoring gallery $gidFromName to downloaded (was paused with curCount=0, cover exists)');
            await _updateGalleryInDatabase(
              GalleryDownloadedCompanion(gid: Value(info.gid), downloadStatusIndex: Value(DownloadStatus.downloaded.index)),
            );
            info.downloadProgress.downloadStatus = DownloadStatus.downloaded;
            info.downloadProgress.curCount = info.pageCount;
            await GalleryImageDao.updateImageStatusByGallery(info.gid, DownloadStatus.none.index, DownloadStatus.downloaded.index);
            for (GalleryImage? img in info.images ?? <GalleryImage?>[]) {
              if (img?.downloadStatus == DownloadStatus.none) {
                img?.downloadStatus = DownloadStatus.downloaded;
              }
            }
            update(['$galleryDownloadProgressId::${info.gid}', '$downloadImageId::${info.gid}']);
            repairedCount++;
          }
        }

        if (i % 20 == 0) {
          await Future.delayed(Duration.zero);
        }
        continue;
      }

      /// Not in memory — re-read metadata and restore.
      log.info('verifyMetadata: gallery $gidFromName has metadata on disk but not in memory, restoring: ${dir.path}');
      try {
        final ({GalleryDownloadedData gallery, List<GalleryImage?> images})? restored =
            await _GalleryMetadataStore.readForRestoreAsync(dir, downloadPath, visibleDirPath);
        if (restored == null) {
          log.warning('verifyMetadata: metadata parse returned null for gallery $gidFromName: ${dir.path}');
          continue;
        }

        GalleryDownloadedData gallery = restored.gallery;
        if (gallery.downloadStatusIndex == DownloadStatus.downloading.index) {
          gallery = gallery.copyWith(downloadStatusIndex: DownloadStatus.paused.index);
        }

        if (galleryDownloadInfos.containsKey(gallery.gid)) {
          continue;
        }

        if (!await _restoreInfoInDatabase(gallery, restored.images)) {
          log.error('verifyMetadata: restore failed for gallery $gidFromName: ${gallery.title}');
          _clearGalleryDownloadInfoInDatabase(gallery.gid);
          continue;
        }

        _initGalleryInfoInMemoryWithImages(gallery, restored.images);
        if (gallery.downloadStatusIndex == DownloadStatus.downloaded.index) {
          final GalleryDownloadInfo restoredInfo = galleryDownloadInfos[gallery.gid]!;
          /// If marked downloaded but the cover file is missing, files are
          /// gone — reset to paused so the user can re-download.
          bool filesMissing = false;
          if (restoredInfo.coverImage?.path != null) {
            final String coverAbs =
                DownloadPathResolver.computeImageDownloadAbsolutePathFromRelativePath(restoredInfo.coverImage!.path!);
            filesMissing = !await io.File(coverAbs).exists();
          }
          if (filesMissing) {
            log.warning('verifyMetadata: files missing for restored gallery $gidFromName, resetting to paused');
            await _updateGalleryInDatabase(
              GalleryDownloadedCompanion(gid: Value(gallery.gid), downloadStatusIndex: Value(DownloadStatus.paused.index)),
            );
            restoredInfo.downloadProgress.downloadStatus = DownloadStatus.paused;
            restoredInfo.downloadProgress.curCount = 0;
            await GalleryImageDao.updateImageStatusByGallery(gallery.gid, DownloadStatus.downloaded.index, DownloadStatus.none.index);
            for (GalleryImage? img in restoredInfo.images ?? <GalleryImage?>[]) {
              if (img?.downloadStatus == DownloadStatus.downloaded) {
                img?.downloadStatus = DownloadStatus.none;
              }
            }
            update(['$galleryDownloadProgressId::${gallery.gid}', '$downloadImageId::${gallery.gid}']);
          } else {
            restoredInfo.evictImages();
          }
        }
        repairedCount++;
        log.info('verifyMetadata: restored gallery $gidFromName: ${gallery.title}');
      } catch (e, st) {
        log.error('verifyMetadata: error restoring gallery $gidFromName: ${dir.path}', e, st);
      }
      await Future.delayed(Duration.zero);
    }

    if (repairedCount > 0) {
      update([galleryCountChangedId]);
      log.info('verifyMetadata: repaired $repairedCount galleries');
    }

    return repairedCount;
  }

  Future<int> restoreTasks() async {
    log.info('restoreTasks: awaiting completed...');
    await completed;
    log.info('restoreTasks: completed resolved');

    /// Coalesce concurrent triggers (e.g. user taps "restore" while the
    /// auto-restore on startup is still running). The second caller awaits
    /// the first's result.
    if (_restoreTasksFuture != null) {
      log.info('restoreTasks: coalescing with existing restore');
      return _restoreTasksFuture!;
    }
    _restoreTasksFuture = _doRestoreTasks();
    update([galleryCountChangedId]);
    try {
      int result = await _restoreTasksFuture!;
      log.info('restoreTasks: done, restored $result galleries');
      return result;
    } finally {
      _restoreTasksFuture = null;
      restoreTotalDirectories = 0;
      restoreScannedDirectories = 0;
      restoreParsedMetadata = 0;
      restoreRestoredGalleries = 0;
      restorePhase = 0;
      update([galleryCountChangedId]);
    }
  }

  Future<int> _doRestoreTasks() async {
    final String downloadPath = downloadSetting.downloadPath.value;
    final String visibleDirPath = pathService.getVisibleDir().path;
    log.info('_doRestoreTasks: downloadPath=$downloadPath, visibleDirPath=$visibleDirPath');

    io.Directory downloadDir = io.Directory(downloadPath);
    if (!downloadDir.existsSync()) {
      log.warning('_doRestoreTasks: download dir does not exist: $downloadPath');
      return 0;
    }

    /// Use async listing so the UI thread isn't blocked during enumeration
    /// of directories containing thousands of entries.
    final List<io.Directory> galleryDirs = <io.Directory>[];
    await for (final entity in downloadDir.list()) {
      if (entity is io.Directory) {
        galleryDirs.add(entity);
      }
    }
    restoreTotalDirectories = galleryDirs.length;
    restoreScannedDirectories = 0;
    restoreParsedMetadata = 0;
    restoreRestoredGalleries = 0;
    restorePhase = 1;
    log.info('_doRestoreTasks: found ${galleryDirs.length} gallery directories');
    update([galleryCountChangedId]);
    if (galleryDirs.isEmpty) {
      restorePhase = 0;
      return 0;
    }

    /// Skip metadata parsing for galleries already loaded from the DB.
    /// Directory name format is `'{gid} - {title}'` (see [DownloadPathResolver]),
    /// so we extract the leading numeric gid and check [galleryDownloadInfos].
    /// On a typical re-launch with 3000+ DB-loaded galleries, this avoids
    /// reading + parsing 3000+ metadata files only to discard every result.
    int skippedAlreadyLoaded = 0;
    final List<io.Directory> dirsToParse = [];
    for (final io.Directory dir in galleryDirs) {
      final int? gidFromName = _tryExtractGidFromDirName(dir.path);
      if (gidFromName != null && galleryDownloadInfos.containsKey(gidFromName)) {
        skippedAlreadyLoaded++;
        continue;
      }
      dirsToParse.add(dir);
    }
    log.info('_doRestoreTasks: skipped $skippedAlreadyLoaded already-loaded, parsing ${dirsToParse.length} metadata files');
    update([galleryCountChangedId]);

    /// Parse metadata files using async I/O so the UI thread stays free to
    /// rebuild and show progress. We avoided [Isolate.run] because the worker
    /// isolate would need to initialise every global top-level variable in
    /// the library (downloadSetting, pathService, galleryDownloadService,
    /// etc.), some of which depend on GetX / platform channels not available
    /// in a spawned isolate — this caused the isolate to hang silently.
    ///
    /// Each iteration yields to the event loop (the [await] on file I/O is
    /// sufficient), so progress updates render between reads. A dedicated
    /// [update] call every gallery keeps the UI fresh.
    final List<({GalleryDownloadedData gallery, List<GalleryImage?> images})?> restoredList = [];
    for (int i = 0; i < dirsToParse.length; i++) {
      try {
        restoredList.add(await _GalleryMetadataStore.readForRestoreAsync(dirsToParse[i], downloadPath, visibleDirPath));
      } catch (e) {
        log.warning('_doRestoreTasks: failed to parse metadata for ${dirsToParse[i].path}: $e');
        restoredList.add(null);
      }
      restoreScannedDirectories++;
      restoreParsedMetadata = restoredList.whereType<Object>().length;
      if (i % 10 == 0) {
        update([galleryCountChangedId]);
      }
      /// Yield to the event loop so UI rebuilds land.
      await Future.delayed(Duration.zero);
    }
    log.info('_doRestoreTasks: parsed ${restoredList.whereType<Object>().length}/${dirsToParse.length} metadata files');
    restorePhase = 2;
    update([galleryCountChangedId]);

    /// Batch mode: suppress per-gallery [update] calls inside
    /// [_buildGalleryInfoInMemory] so 3000+ restores don't trigger 3000+
    /// UI rebuilds. We call [update] at intervals and once at the end.
    _batchRestoreMode = true;
    int restoredCount = 0;
    for (final ({GalleryDownloadedData gallery, List<GalleryImage?> images})? restored in restoredList) {
      if (restored == null) {
        continue;
      }

      GalleryDownloadedData gallery = restored.gallery;
      List<GalleryImage?> images = restored.images;

      /// A gallery left in `downloading` state at shutdown cannot be safely
      /// resumed — its image tasks were killed mid-flight. Demote to `paused`
      /// so the user explicitly resumes, rather than silently re-launching
      /// downloads that may have half-written image files.
      if (gallery.downloadStatusIndex == DownloadStatus.downloading.index) {
        gallery = gallery.copyWith(downloadStatusIndex: DownloadStatus.paused.index);
      }

      /// skip if exists
      if (galleryDownloadInfos.containsKey(gallery.gid)) {
        continue;
      }

      if (!await _restoreInfoInDatabase(gallery, images)) {
        log.error('Restore download failed. Gallery: ${gallery.title}');
        _clearGalleryDownloadInfoInDatabase(gallery.gid);
        continue;
      }

      /// Restore images directly into the in-memory [GalleryDownloadInfo.images]
      /// list. The restored list is sized to pageCount; missing slots stay null.
      List<GalleryImage?> restoredImages = List.generate(gallery.pageCount, (_) => null);
      for (int serialNo = 0; serialNo < images.length && serialNo < gallery.pageCount; serialNo++) {
        final GalleryImage? img = images[serialNo];
        if (img != null) {
          restoredImages[serialNo] = img;
        }
      }

      _initGalleryInfoInMemoryWithImages(gallery, restoredImages);

      /// The metadata-restore path loads every gallery's full image list
      /// (to derive curCount/hasDownloaded and the metadata snapshot). No
      /// consumer retains at startup, so evict completed galleries' lists
      /// right away to match the DB path ([_instantiateFromDB] loads only
      /// coverImage). [GalleryDownloadInfo.evictImages] keeps coverImage
      /// (serialNo 0) resident for list/grid cover display; incomplete
      /// galleries keep their list for the download loop.
      if (gallery.downloadStatusIndex == DownloadStatus.downloaded.index) {
        galleryDownloadInfos[gallery.gid]!.evictImages();
      }

      restoredCount++;
      restoreRestoredGalleries = restoredCount;
      if (restoredCount % 50 == 0) {
        update([galleryCountChangedId]);
        await Future.delayed(Duration.zero);
      }
    }
    _batchRestoreMode = false;
    _invalidateGalleriesCache();
    restorePhase = 0;
    update([galleryCountChangedId]);

    return restoredCount;
  }

  /// Extract the leading numeric gid from a gallery directory name shaped
  /// `'{gid} - {title}'` (see [DownloadPathResolver.computeGalleryDownloadAbsolutePath]).
  /// Returns null if the name doesn't start with a parseable integer followed
  /// by ` - `. Used by [_doRestoreTasks] to skip metadata parsing for
  /// galleries already resident in [galleryDownloadInfos] from the DB load.
  static int? _tryExtractGidFromDirName(String dirPath) {
    final String name = path.basename(dirPath);
    final int sep = name.indexOf(' - ');
    if (sep <= 0) {
      return null;
    }
    return int.tryParse(name.substring(0, sep));
  }

  /// Re-compute every image's on-disk path after the user changes the download
  /// root directory. Processes galleries in batches of [_pathUpdateBatchSize]
  /// inside separate transactions: each batch loads images into memory, updates
  /// DB rows + in-memory paths, then evicts completed galleries to bound peak
  /// memory. Avoids holding all galleries' images resident simultaneously.
  static const int _pathUpdateBatchSize = 200;

  Future<void> updateImagePathAfterDownloadPathChanged() async {
    final List<GalleryDownloadInfo> allGalleries = galleries.toList();

    for (int i = 0; i < allGalleries.length; i += _pathUpdateBatchSize) {
      final List<GalleryDownloadInfo> batch = allGalleries.skip(i).take(_pathUpdateBatchSize).toList();

      await appDb.transaction(() async {
        for (final GalleryDownloadInfo info in batch) {
          await info.ensureImagesLoaded();

          for (int serialNo = 0; serialNo < info.pageCount; serialNo++) {
            final GalleryImage? img = info.imageAtSync(serialNo);
            if (img == null) {
              continue;
            }

            final String newPath = DownloadPathResolver.computeImageDownloadRelativePath(
              info.toGalleryDownloadedData(),
              _downloadUrlFor(info.toGalleryDownloadedData(), img),
              serialNo,
            );

            if (img.path == newPath) {
              continue;
            }

            if (!await _updateImageInDatabase(
              ImageCompanion(gid: Value(info.gid), serialNo: Value(serialNo), path: Value(newPath)),
            )) {
              log.error('Update image path after download path changed failed');
            }
            info.updateImagePath(serialNo, newPath);

            update(['$downloadImageId::${info.gid}::$serialNo', '$downloadImageUrlId::${info.gid}::$serialNo']);
          }
        }
      });

      /// Evict completed galleries after each batch to release memory. In-
      /// complete galleries keep their images resident for the download loop.
      for (final GalleryDownloadInfo info in batch) {
        if (info.downloadProgress.downloadStatus == DownloadStatus.downloaded) {
          info.evictImages();
        }
      }
    }
  }

  Future<void> _generateComicInfoInDisk(GalleryDownloadInfo gallery) async {
    GalleryDetail galleryDetail;
    try {
      ({GalleryDetail galleryDetails, String apikey}) detailPageInfo = await retry(
        () => ehRequest.requestDetailPage(galleryUrl: gallery.galleryUrl, parser: EHSpiderParser.detailPage2GalleryAndDetailAndApikey),
        retryIf: (e) => e is DioException,
        maxAttempts: _maxRetryTimes,
      );
      galleryDetail = detailPageInfo.galleryDetails;
    } catch (e) {
      log.error('Generate comic info failed due to network error, gallery: ${gallery.gid}', e);
      return;
    }

    if (_taskHasBeenRemoved(gallery)) {
      return;
    }

    EHGalleryComicInfo galleryComicInfo = EHGalleryComicInfo(
      rawTitle: galleryDetail.rawTitle,
      japaneseTitle: galleryDetail.japaneseTitle,
      category: galleryDetail.category,
      pageCount: galleryDetail.pageCount,
      galleryUrl: galleryDetail.galleryUrl.url,
      uploader: galleryDetail.uploader,
      publishTime: galleryDetail.publishTime,
      languageAbbreviation: LocaleConsts.language2Abbreviation[galleryDetail.language]?.toLowerCase(),
      tagDatas: galleryDetail.tags.values.flattened.map((galleryTag) => galleryTag.tagData).toList(),
      rating: galleryDetail.realRating,
    );

    try {
      io.File file = io.File(path.join(DownloadPathResolver.computeGalleryDownloadAbsolutePath(gallery.toGalleryDownloadedData()), 'ComicInfo.xml'));
      if (!await file.exists()) {
        await file.create(recursive: true);
      }
      await file.writeAsString(galleryComicInfo.toXmlDocument().toXmlString(pretty: true));
    } catch (e) {
      log.error('Write comic info failed, gallery: ${gallery.gid}', e);
    }
  }

  void updateExecutor() {
    executor.concurrency = downloadSetting.downloadTaskConcurrency.value;
    executor.rate = Rate(downloadSetting.maximum.value, downloadSetting.period.value);
  }

  /// start executor
  void _startExecutor() {
    log.debug('start download executor');

    executor = EHExecutor(
      concurrency: downloadSetting.downloadTaskConcurrency.value,
      rate: Rate(downloadSetting.maximum.value, downloadSetting.period.value),
    );

    /// Resume gallery whose status is [downloading], order by insertTime
    for (GalleryDownloadInfo g in galleries) {
      if (g.downloadProgress.downloadStatus == DownloadStatus.downloading) {
        // gid2SpeedComputer[g.gid]!.start();
        _resumeDownloadGallery(g.gid);
      }
    }
  }

  void _submitTask({required int gid, required int priority, required AsyncTask<void> task}) {
    galleryDownloadInfos[gid]?.tasks.add(task);

    executor.scheduleTask(priority, task).then((_) => galleryDownloadInfos[gid]?.tasks.remove(task)).onError((e, stackTrace) {
      galleryDownloadInfos[gid]?.tasks.remove(task);
      if (e is! CancelException) {
        log.error('Executor exception!', e, stackTrace);
        log.uploadError(e);
      }
      return null;
    });
  }

  /// Shortcut for the common pattern: compute image priority, build the task, submit.
  ///
  /// Status-gated: refuses to submit a new task if the gallery's downloadStatus
  /// is no longer [DownloadStatus.downloading] (paused / completed / deleted).
  /// Without this gate, a task could be added to [info.tasks] between
  /// pauseAll's `info.tasks.clear()` and the next iteration, becoming an
  /// orphan tracked by the executor but not by [info.tasks] — un-cancelable.
  void _submitImageTask(GalleryDownloadInfo gallery, int serialNo, AsyncTask<void> Function() taskBuilder) {
    final GalleryDownloadInfo? info = _liveInfoOrSkip(gallery.gid, DownloadStatus.downloading);
    if (info == null) {
      return;
    }
    return _submitTask(
      gid: gallery.gid,
      priority: _computeImageTaskPriority(gallery, serialNo),
      task: taskBuilder(),
    );
  }

  /// Rules:
  /// 1. If [downloadAllGalleriesOfSamePriority] is false
  ///   1.1 Galleries download order:
  ///     1.1.1 gallery with high priority
  ///     1.1.2 gallery with low priority
  ///     1.1.3 if priority is same, download only 1 gallery simultaneously in the order of insert time ASC
  ///   1.2 For each gallery, previous image should be downloaded earlier
  /// 2. If [downloadAllGalleriesOfSamePriority] is true
  ///   2.1 Galleries download order:
  ///     2.1.1 gallery with high priority
  ///     2.1.2 gallery with low priority
  ///     2.1.3 if priority is same, download all galleries simultaneously
  ///   2.2 For each gallery, previous image should be downloaded earlier and images with same [serialNo] has the same priority no matter which gallery they belong to
  ///
  /// Because a gallery has most 2000 images, we assign 2000 numbers to each gallery
  int _computeGalleryTaskPriority(GalleryDownloadInfo gallery) {
    if (_taskHasBeenPausedOrRemoved(gallery)) {
      return 0;
    }

    int groupPriority = galleryDownloadInfos[gallery.gid]!.priority * _priorityBase;

    if (downloadSetting.downloadAllGalleriesOfSamePriority.isTrue) {
      return groupPriority;
    }

    /// priority is same, order by insert time — uses the cached
    /// [GalleryDownloadInfo.insertTimePriority] to avoid DateFormat.parse
    /// on every image task submit.
    int timePriority = galleryDownloadInfos[gallery.gid]!.insertTimePriority * 2000;

    return groupPriority + timePriority;
  }

  int _computeImageTaskPriority(GalleryDownloadInfo gallery, int serialNo) {
    return _computeGalleryTaskPriority(gallery) + serialNo;
  }

  /// Pause one gallery or all galleries depending on [pauseAll].
  /// Centralizes the pause/pauseAll branch repeated across parse/download handlers.
  Future<void> _pauseOnSiteError({required GalleryDownloadInfo gallery, required bool pauseAll, String? message}) {
    if (message != null) {
      snack('error'.tr, message, isShort: true);
    }
    return pauseAll ? pauseAllDownloadGallery() : pauseDownloadGallery(gallery);
  }

  bool _taskHasBeenPausedOrRemoved(GalleryDownloadInfo gallery) {
    return galleryDownloadInfos[gallery.gid] == null || galleryDownloadInfos[gallery.gid]!.downloadProgress.downloadStatus == DownloadStatus.paused;
  }

  bool _taskHasBeenRemoved(GalleryDownloadInfo gallery) {
    return galleryDownloadInfos[gallery.gid] == null;
  }

  Future<void> _updateProgressAfterImageDownloaded(GalleryDownloadInfo gallery, int serialNo) async {
    /// Status-gate at entry: if a concurrent pause / pauseAll / delete has
    /// flipped status away from [DownloadStatus.downloading], this is a late
    /// completion racing with the pause path — bail out without mutating
    /// curCount / hasDownloaded / status / evicting images. The pause path
    /// is authoritative for paused state; a late increment here would either
    /// (a) overshoot curCount past the actual downloaded count, or (b) flip
    /// status back to `downloaded` after pauseAll just set it to `paused`,
    /// leaving DB (`paused`) and memory (`downloaded`) diverged.
    final GalleryDownloadInfo? info = _liveInfoOrSkip(gallery.gid, DownloadStatus.downloading);
    if (info == null) {
      return;
    }

    GalleryDownloadProgress downloadProgress = info.downloadProgress;
    downloadProgress.curCount++;
    downloadProgress.hasDownloaded[serialNo] = true;

    if (downloadProgress.curCount == downloadProgress.totalCount) {
      /// Don't pre-flip memory status before the await — the CAS may fail if
      /// a concurrent pauseAll beat us to it, in which case DB stays `paused`
      /// and we must NOT set memory to `downloaded` (would diverge). The
      /// `_updateGalleryDownloadStatus` call writes memory only on CAS success.
      final bool flipped = await _updateGalleryDownloadStatus(
        gallery,
        DownloadStatus.downloaded,
        fromStatus: DownloadStatus.downloading,
      );

      /// Re-check after the await: CAS failure means a concurrent pauseAll
      /// flipped status to `paused` (memory not written to `downloaded`);
      /// or deleteGallery may have removed the entry. Either way, bail
      /// without disposing speedComputer or evicting images — the gallery
      /// is not in the `downloaded` state we expected.
      if (!flipped) {
        log.download('Completion CAS failed: gid=${gallery.gid}, expected=downloading→downloaded; a concurrent path (likely pauseAll) changed status. Skipping evict/dispose.');
        return;
      }
      final GalleryDownloadInfo? live = _liveInfoOrSkip(gallery.gid, DownloadStatus.downloaded);
      if (live == null) {
        return;
      }
      live.speedComputer.dispose();

      /// All images downloaded — evict the full image list. Cover image is
      /// retained for list/grid cover display; full list re-loads on next
      /// read page / detail page open.
      live.evictImages();
      update(['$galleryDownloadSuccessId::${gallery.gid}']);
    }

    update(['$galleryDownloadProgressId::${gallery.gid}']);
  }

  Future<void> _instantiateFromDB() async {
    /// Parallelize the three startup DB queries — they have no data dependency
    /// on each other. Sequential awaits added ~3 round-trips to cold start.
    final List<Object> results = await Future.wait([
      GalleryGroupDao.selectGalleryGroups(),
      GalleryDao.selectGalleries(),
      GalleryImageDao.selectCoverImages(),
      GalleryImageDao.selectDownloadedCountsByGid(),
    ]);
    allGroups = (results[0] as List<GalleryGroupData>).map((e) => e.groupName).toList();
    log.debug('init Gallery groups: $allGroups');

    /// Get download info from database
    List<GalleryDownloadedData> dbGalleries = results[1] as List<GalleryDownloadedData>;

    /// Only load cover images (serialNo=0) at startup — full image lists
    /// lazy-load on first access to each gallery (detail/read/download).
    Map<int, GalleryImage> covers = results[2] as Map<int, GalleryImage>;
    Map<int, int> downloadedCounts = results[3] as Map<int, int>;

    for (GalleryDownloadedData gallery in dbGalleries) {
      _initGalleryInfoInMemory(gallery);

      GalleryDownloadInfo info = galleryDownloadInfos[gallery.gid]!;

      /// Populate cover image (slot 0) if a DB row exists.
      info.coverImage = covers[gallery.gid];

      /// Populate curCount: for fully-downloaded galleries, it equals pageCount;
      /// otherwise use the precise count from DB. hasDownloaded defers to the
      /// getter for completed galleries and syncs from [images] on first
      /// load for incomplete ones.
      int downloadedCount = downloadedCounts[gallery.gid] ?? 0;
      if (info.downloadProgress.downloadStatus == DownloadStatus.downloaded) {
        info.downloadProgress.curCount = gallery.pageCount;
      } else {
        info.downloadProgress.curCount = downloadedCount;
      }
    }
  }

  Future<bool> _initGalleryInfo(GalleryDownloadedData gallery) async {
    if (!await _saveGalleryInfoAndGroupInDB(gallery)) {
      return false;
    }

    _initGalleryInfoInMemory(gallery);

    _saveGalleryMetadataInDisk(galleryDownloadInfos[gallery.gid]!);

    return true;
  }

  Future<bool> _updateGalleryDownloadStatus(
    GalleryDownloadInfo gallery,
    DownloadStatus downloadStatus, {
    DownloadStatus? fromStatus,
  }) async {
    /// CAS: when [fromStatus] is provided, the DB UPDATE is gated on the
    /// current row's `downloadStatusIndex` matching it. This prevents lost
    /// updates when a concurrent `pauseAllDownloadGallery` / `resumeAllDownloadGallery`
    /// has already flipped the row. Without this, a late completion writing
    /// `downloaded` could overwrite a just-written `paused`, or vice versa.
    ///
    /// Memory mutation follows the DB result: if 0 rows updated, the CAS
    /// failed (someone else won) — skip the memory write so memory stays
    /// consistent with DB.
    final GalleryDownloadedCompanion companion = GalleryDownloadedCompanion(
      gid: Value(gallery.gid),
      downloadStatusIndex: Value(downloadStatus.index),
    );
    final bool success = fromStatus == null
        ? await _updateGalleryInDatabase(companion)
        : await _updateGalleryInDatabase(companion, fromStatusIndex: fromStatus.index);

    if (!success) {
      log.download('CAS skip on _updateGalleryDownloadStatus: gid=${gallery.gid}, expected=$fromStatus, target=$downloadStatus');
      return false;
    }

    galleryDownloadInfos[gallery.gid]?.downloadProgress.downloadStatus = downloadStatus;

    _saveGalleryMetadataInDisk(gallery);
    return true;
  }

  Future<bool> _updateImageStatus(GalleryDownloadInfo gallery, GalleryImage image, int serialNo, DownloadStatus downloadStatus) async {
    if (!await _updateImageInDatabase(
      ImageCompanion(gid: Value(gallery.gid), serialNo: Value(serialNo), downloadStatusIndex: Value(downloadStatus.index)),
    )) {
      return false;
    }

    image.downloadStatus = downloadStatus;

    update(['$downloadImageId::${gallery.gid}::$serialNo', '$downloadImageUrlId::${gallery.gid}::$serialNo']);

    _saveGalleryMetadataInDisk(gallery);

    return true;
  }

  Future<bool> _addGroup(String group) async {
    if (!allGroups.contains(group)) {
      allGroups.add(group);
    }

    return (await GalleryGroupDao.insertGalleryGroup(GalleryGroupData(groupName: group, sortOrder: 0)) > 0);
  }

  Future<bool> _deleteGroup(String group) async {
    allGroups.remove(group);

    try {
      return (await GalleryGroupDao.deleteGalleryGroup(group) > 0);
    } on SqliteException catch (e) {
      log.info(e);
      return false;
    }
  }

  // MEMORY

  /// Initialize in-memory state for a gallery that has **no image data
  /// resident** — e.g. just downloaded fresh, or loaded from DB at startup
  /// where [images] lazy-loads on first access. [coverImage] is populated
  /// separately by the caller (e.g. from [GalleryImageDao.selectCoverImages]);
  /// curCount and hasDownloaded default to zero / all-false.
  void _initGalleryInfoInMemory(GalleryDownloadedData gallery) {
    _buildGalleryInfoInMemory(gallery, images: null);
  }

  /// Initialize in-memory state for a gallery with **already-known images**
  /// — e.g. restored from disk metadata, or imported from a folder of
  /// existing image files. curCount and hasDownloaded are derived from the
  /// images list.
  void _initGalleryInfoInMemoryWithImages(GalleryDownloadedData gallery, List<GalleryImage?> images) {
    _buildGalleryInfoInMemory(gallery, images: images);
  }

  void _buildGalleryInfoInMemory(GalleryDownloadedData gallery, {required List<GalleryImage?>? images}) {
    if (!allGroups.contains(gallery.groupName)) {
      allGroups.add(gallery.groupName);
    }
    galleryDownloadInfos[gallery.gid] = GalleryDownloadInfo(
      gid: gallery.gid,
      token: gallery.token,
      galleryUrl: gallery.galleryUrl,
      title: gallery.title,
      category: gallery.category,
      pageCount: gallery.pageCount,
      uploader: gallery.uploader,
      publishTime: gallery.publishTime,
      insertTime: gallery.insertTime,
      oldVersionGalleryUrl: gallery.oldVersionGalleryUrl,
      sanitizedTitle: gallery.sanitizedTitle,
      priority: gallery.priority,
      sortOrder: gallery.sortOrder,
      group: gallery.groupName,
      downloadOriginalImage: gallery.downloadOriginalImage,
      tags: gallery.tags,
      tagRefreshTime: gallery.tagRefreshTime,
      thumbnailsCountPerPage: SiteSetting.thumbnailsCountPerPage.value,
      tasks: [],
      cancelToken: CancelToken(),
      downloadProgress: GalleryDownloadProgress(
        curCount: images?.fold<int>(0, (total, img) => total + (img?.downloadStatus == DownloadStatus.downloaded ? 1 : 0)) ?? 0,
        totalCount: gallery.pageCount,
        downloadStatus: DownloadStatus.values[gallery.downloadStatusIndex],
        hasDownloaded: images?.map((img) => img?.downloadStatus == DownloadStatus.downloaded).toList(),
      ),
      imageHrefs: List.generate(gallery.pageCount, (_) => null),
      images: images,
      onSpeedUpdate: () => update(['$galleryDownloadSpeedComputerId::${gallery.gid}']),
    );

    _invalidateGalleriesCache();
    if (!_batchRestoreMode) {
      update([galleryCountChangedId, '$galleryDownloadProgressId::${gallery.gid}']);
    }
  }

  void _clearGalleryInfoInMemory(GalleryDownloadInfo gallery) {
    _metadataStore.cancel(gallery.gid);
    GalleryDownloadInfo? galleryDownloadInfo = galleryDownloadInfos.remove(gallery.gid);
    galleryDownloadInfo?._speedComputer?.dispose();

    _invalidateGalleriesCache();
    update([galleryCountChangedId, '$galleryDownloadProgressId::${gallery.gid}']);
  }

  // DB

  Future<bool> _saveGalleryInfoAndGroupInDB(GalleryDownloadedData gallery) async {
    return appDb.transaction(() async {
      await GalleryGroupDao.insertGalleryGroup(GalleryGroupData(groupName: gallery.groupName, sortOrder: 0));

      return await GalleryDao.insertGallery(
            GalleryDownloadedCompanion.insert(
              gid: Value(gallery.gid),
              token: gallery.token,
              title: gallery.title,
              category: gallery.category,
              pageCount: gallery.pageCount,
              galleryUrl: gallery.galleryUrl,
              oldVersionGalleryUrl: Value(gallery.oldVersionGalleryUrl),
              uploader: Value(gallery.uploader),
              publishTime: gallery.publishTime,
              downloadStatusIndex: gallery.downloadStatusIndex,
              insertTime: gallery.insertTime,
              downloadOriginalImage: Value(gallery.downloadOriginalImage),
              priority: gallery.priority,
              sortOrder: Value(gallery.sortOrder),
              groupName: gallery.groupName,
              tags: Value(gallery.tags),
              tagRefreshTime: Value(gallery.tagRefreshTime),
              sanitizedTitle: Value(gallery.sanitizedTitle),
            ),
          ) >
          0;
    });
  }

  Future<bool> _saveNewImageInfoInDatabase(GalleryImage image, int serialNo, int gid) async {
    return await GalleryImageDao.insertImage(
          ImageData(
            gid: gid,
            serialNo: serialNo,
            url: image.url,
            originalImageUrl: image.originalImageUrl,
            path: image.path!,
            imageHash: image.imageHash ?? '',
            downloadStatusIndex: image.downloadStatus.index,
          ),
        ) >
        0;
  }

  Future<bool> _updateGalleryInDatabase(GalleryDownloadedCompanion gallery, {int? fromStatusIndex}) async {
    return await GalleryDao.updateGallery(gallery, fromStatusIndex: fromStatusIndex) > 0;
  }

  Future<bool> _updateImageInDatabase(ImageCompanion image) async {
    return await GalleryImageDao.updateImage(image) > 0;
  }

  Future<void> _clearGalleryDownloadInfoInDatabase(int gid) {
    return appDb.transaction(() async {
      await GalleryImageDao.deleteImagesWithGid(gid);
      await GalleryDao.deleteGallery(gid);
    });
  }

  /// Persist a restored gallery + its images to DB. Caller ([restoreTasks])
  /// is responsible for status fix-ups (e.g. demoting `downloading` →
  /// `paused`); this method only does DB writes.
  Future<bool> _restoreInfoInDatabase(GalleryDownloadedData gallery, List<GalleryImage?> images) async {
    if (!await _saveGalleryInfoAndGroupInDB(gallery)) {
      return false;
    }

    return await appDb.transaction(() async {
      final List<ImageData> imageRows = <ImageData>[];
      for (int serialNo = 0; serialNo < images.length && serialNo < gallery.pageCount; serialNo++) {
        final GalleryImage? image = images[serialNo];
        if (image == null) {
          continue;
        }
        imageRows.add(ImageData(
          gid: gallery.gid,
          serialNo: serialNo,
          url: image.url,
          originalImageUrl: image.originalImageUrl,
          path: image.path!,
          imageHash: image.imageHash ?? '',
          downloadStatusIndex: image.downloadStatus.index,
        ));
      }
      await GalleryImageDao.batchInsertImages(imageRows);
      return true;
    }).catchError((e) {
      log.error('Restore images into database error', e);
      log.uploadError(e);
      return false;
    });
  }

  // Disk

  /// Per-gallery metadata JSON persistence (debounced writes + disk reads for restore).
  late final _GalleryMetadataStore _metadataStore = _GalleryMetadataStore(this);

  /// Gallery upgrade migration: copy image bytes + metadata from an old gallery
  /// version to a new one by matching imageHash.
  late final _GalleryUpgradeMigrator _upgradeMigrator = _GalleryUpgradeMigrator(this);

  void _saveGalleryMetadataInDisk(GalleryDownloadInfo gallery) => _metadataStore.save(gallery);

  Future<void> _flushMetadataSave(GalleryDownloadInfo gallery) => _metadataStore.flush(gallery);

  void _clearDownloadedImageInDisk(GalleryDownloadInfo gallery) {
    io.Directory directory = io.Directory(DownloadPathResolver.computeGalleryDownloadAbsolutePath(gallery.toGalleryDownloadedData()));
    if (!directory.existsSync()) {
      /// sanitizedTitle may not match the on-disk directory name (e.g. after
      /// a sanitisation algorithm change).  Fall back to matching by gid
      /// prefix so the directory is still deleted instead of becoming an
      /// orphan that verify would later re-import.
      final String downloadPath = downloadSetting.downloadPath.value;
      try {
        for (final io.FileSystemEntity entity in io.Directory(downloadPath).listSync()) {
          if (entity is io.Directory && path.basename(entity.path).startsWith('${gallery.gid} - ')) {
            entity.deleteSync(recursive: true);
            return;
          }
        }
      } catch (e) {
        log.error('Delete image in disk fallback error', e);
      }
      return;
    }
    directory.deleteSync(recursive: true);
  }

  void _deleteImageInDisk(GalleryImage image) {
    try {
      io.File file = io.File(image.path!);
      if (!file.existsSync()) {
        return;
      }
      file.deleteSync();
    } on Exception catch (e) {
      log.error('Delete image in disk error', e);
      log.uploadError(e);
    }
  }

  void _ensureDownloadDirExists() {
    try {
      io.Directory(downloadSetting.downloadPath.value).createSync(recursive: true);
    } on Exception catch (e) {
      toast('brokenDownloadPathHint'.tr);
      log.error(e);
      log.uploadError(
        e,
        extraInfos: {
          'defaultDownloadPath': downloadSetting.defaultDownloadPath,
          'downloadPath': downloadSetting.downloadPath.value,
          'exists': pathService.getVisibleDir().existsSync(),
        },
      );
    }
  }
}

enum DownloadStatus {
  none,
  switching,
  paused,
  downloading,
  downloaded,
  downloadFailed,
}

/// Business Object for initiating a gallery download or import. Carries only
/// the input fields a caller has at request time — runtime state (tasks,
/// cancelToken, downloadProgress) and DB-derived fields (sanitizedTitle,
/// sortOrder, insertTime, priority) are populated by the service.
///
/// This is the only shape external callers should use to start a download or
/// import; [GalleryDownloadedData] is an internal DB-layer detail.
class GalleryDownloadRequest {
  final int gid;
  final String token;
  final String title;
  final String category;
  final int pageCount;
  final String galleryUrl;
  final String? uploader;
  final String publishTime;
  final bool downloadOriginalImage;
  final String group;
  final String tags;
  final String? tagRefreshTime;

  /// Ancestor version chain encoded as a JSON-array string (direct parent
  /// first, oldest root last), or a legacy single-URL string for records
  /// written before the chain format was introduced. Set when this request
  /// is a gallery update from an older version — [updateGallery] populates
  /// it by prepending the old gallery's URL to the old gallery's own chain.
  final String? oldVersionGalleryUrl;

  /// Optional overrides for service-owned fields. Null = service picks defaults
  /// (sortOrder=0, priority=[defaultDownloadGalleryPriority], insertTime=now).
  /// Used by [reDownloadGallery] to preserve user-assigned sort/priority across
  /// re-downloads, and by batch-favorite-download to stagger insertTime so the
  /// priority scheduler downloads galleries one-by-one (not all at once).
  final int? sortOrder;
  final int? priority;
  final String? insertTime;

  const GalleryDownloadRequest({
    required this.gid,
    required this.token,
    required this.title,
    required this.category,
    required this.pageCount,
    required this.galleryUrl,
    required this.publishTime,
    required this.downloadOriginalImage,
    required this.group,
    required this.tags,
    this.uploader,
    this.tagRefreshTime,
    this.oldVersionGalleryUrl,
    this.sortOrder,
    this.priority,
    this.insertTime,
  });
}

/// Pick the URL to actually download from, given the gallery's
/// `downloadOriginalImage` flag. Used by the download pipeline (parse url,
/// download bytes, upgrade migration, path recompute) and by metadata restore.
///
/// For download-original galleries, prefer [GalleryImage.originalImageUrl] and
/// fall back to [GalleryImage.url] if the original URL is missing (legacy rows
/// written before the `originalImageUrl` column existed, where `url` itself
/// stores the original URL). For regular galleries, always use `url`.
///
/// Free function (not a method on [GalleryImage]) so it can be called from
/// any context — including the metadata store's [Isolate.run] restore path,
/// which only has a [GalleryDownloadedData] (parsed from JSON) and no access
/// to the [GalleryDownloadInfo] singleton.
String _downloadUrlFor(GalleryDownloadedData gallery, GalleryImage image) {
  return gallery.downloadOriginalImage ? (image.originalImageUrl ?? image.url) : image.url;
}

class GalleryDownloadInfo implements Comparable<GalleryDownloadInfo> {
  // === Identity (immutable after creation) ===
  final int gid;
  final String token;
  final String galleryUrl;
  final String title;
  final String category;
  final int pageCount;
  final String? uploader;
  final String publishTime;
  final String insertTime;

  /// Mutable so [_fetchAndSetOldVersionGalleryUrl] can backfill it from the
  /// network after download start. Persisted to DB + metadata on update.
  ///
  /// Storage format (backwards-compatible):
  ///   - null                         → no known parent version
  ///   - "https://e-hentai.org/g/..."  → legacy single-URL record (direct parent only)
  ///   - "[\"url1\",\"url2\",...]"      → JSON array of ancestor URLs, ordered from
  ///                                     direct parent (index 0) to oldest root.
  /// The array form lets the "Delete history versions" feature detect version
  /// relationships across multiple hops even when intermediate versions have
  /// been deleted locally — any URL in the chain that still exists locally is
  /// enough to link two galleries into the same version group.
  String? oldVersionGalleryUrl;
  String? sanitizedTitle;

  /// Parse [oldVersionGalleryUrl] into an ordered ancestor chain.
  /// Returns `[]` when null, `[url]` for legacy single-URL records, and the
  /// decoded list for JSON-array records. Order: direct parent first, oldest root last.
  List<String> get oldVersionChain => decodeVersionChain(oldVersionGalleryUrl);

  /// The direct parent version URL (single hop). Used by the upgrade migrator
  /// to locate the immediate predecessor for image-byte reuse. Returns null
  /// when no parent is recorded.
  String? get directParentUrl {
    final List<String> chain = oldVersionChain;
    return chain.isEmpty ? null : chain.first;
  }

  /// Whether any version relationship is recorded for this gallery.
  bool get hasVersionChain => oldVersionGalleryUrl != null && oldVersionGalleryUrl!.isNotEmpty;

  /// Whether [oldVersionGalleryUrl] is a legacy single-URL record written
  /// before the ancestor-chain format was introduced. Such records only
  /// capture the direct parent and should be re-crawled by the "Fetch old
  /// version links" tool to build the full ancestor chain. Once re-crawled
  /// the value is stored as a JSON array and this returns false.
  bool get isLegacyVersionUrl {
    final String? v = oldVersionGalleryUrl;
    return v != null && v.isNotEmpty && !v.startsWith('[');
  }

  /// Decode a stored [oldVersionGalleryUrl] value into an ordered ancestor chain.
  /// Tolerates null, legacy single-URL strings, and JSON-array strings.
  static List<String> decodeVersionChain(String? stored) {
    if (stored == null || stored.isEmpty) {
      return const <String>[];
    }
    if (stored.startsWith('[')) {
      try {
        return (jsonDecode(stored) as List).cast<String>();
      } catch (e) {
        log.error('decodeVersionChain: failed to parse JSON array, falling back to single-URL', e);
        return [stored];
      }
    }
    return [stored];
  }

  /// Encode an ordered ancestor chain (direct parent first) into the storage
  /// format. Returns null for an empty chain, a JSON-array string otherwise.
  static String? encodeVersionChain(List<String> chain) {
    if (chain.isEmpty) {
      return null;
    }
    return jsonEncode(chain);
  }

  /// Pre-parsed `MMddHHmmss` of [insertTime]. Cached at construction so
  /// [_computeGalleryTaskPriority] avoids `DateFormat.parse` on every image
  /// task submit.
  late final int _insertTimePriority = _parseInsertTimePriority();

  int get insertTimePriority => _insertTimePriority;

  // === Mutable config (user-changeable) ===
  int priority;
  int sortOrder;
  String group;
  bool downloadOriginalImage;
  String tags;
  String? tagRefreshTime;

  // === Download runtime state ===
  GalleryDownloadProgress downloadProgress;

  /// 20, 40 and so on
  int thumbnailsCountPerPage;
  List<AsyncTask> tasks;
  CancelToken cancelToken;
  List<GalleryThumbnail?> imageHrefs;

  /// Cover image (serialNo == 0), always resident. Loaded at startup from
  /// DB; used by list/grid/search pages. Other serialNos go through
  /// [ensureImagesLoaded] / [imageAtSync].
  GalleryImage? coverImage;

  /// Full image list, `null` when not resident in memory.
  /// - Startup: `null` (only [coverImage] loaded)
  /// - Download start: [ensureImagesLoaded] pulls from DB (or new empty list)
  /// - Download complete: [evictImages] → `null`
  /// - Read page open: [ensureImagesLoaded] pulls from DB
  /// - Read page close: if gallery is downloaded → [evictImages] → `null`
  List<GalleryImage?>? images;

  Future<void>? _imagesLoadingFuture;

  /// Lazily allocated so completed/restored galleries don't pay the cost of
  /// per-image byte-tracking lists until a download actually (re)starts.
  GalleryDownloadSpeedComputer? _speedComputer;
  final VoidCallback _onSpeedUpdate;

  GalleryDownloadSpeedComputer get speedComputer => _speedComputer ??= GalleryDownloadSpeedComputer(pageCount, _onSpeedUpdate);

  GalleryDownloadInfo({
    required this.gid,
    required this.token,
    required this.galleryUrl,
    required this.title,
    required this.category,
    required this.pageCount,
    required this.thumbnailsCountPerPage,
    required this.tasks,
    required this.cancelToken,
    required this.downloadProgress,
    required this.imageHrefs,
    List<GalleryImage?>? images,
    GalleryImage? coverImage,
    required this.priority,
    required this.sortOrder,
    required this.group,
    required this.downloadOriginalImage,
    required this.tags,
    required this.tagRefreshTime,
    this.uploader,
    required this.publishTime,
    required this.insertTime,
    this.oldVersionGalleryUrl,
    this.sanitizedTitle,
    required VoidCallback onSpeedUpdate,
  })  : _onSpeedUpdate = onSpeedUpdate,
        images = images,
        coverImage = coverImage ?? (images == null || images.isEmpty ? null : images[0]);

  /// Lazy-load the full [images] list from DB. Idempotent + concurrent-safe:
  /// concurrent callers share the same [_imagesLoadingFuture]. After evict
  /// ([images] == null), re-calling reloads from DB.
  Future<void> ensureImagesLoaded() async {
    if (images != null) {
      return;
    }
    if (_imagesLoadingFuture != null) {
      return _imagesLoadingFuture!;
    }
    _imagesLoadingFuture = _loadImages().whenComplete(() => _imagesLoadingFuture = null);
    return _imagesLoadingFuture!;
  }

  Future<void> _loadImages() async {
    final List<ImageData> rows = await GalleryImageDao.selectImagesByGalleryId(gid);
    final List<GalleryImage?> loaded = List.generate(pageCount, (_) => null);
    for (final d in rows) {
      if (d.serialNo < pageCount) {
        loaded[d.serialNo] = GalleryImage(
          url: d.url,
          originalImageUrl: d.originalImageUrl,
          path: d.path,
          imageHash: d.imageHash.isEmpty ? null : d.imageHash,
          downloadStatus: DownloadStatus.values[d.downloadStatusIndex],
        );
      }
    }
    images = loaded;
    if (coverImage == null && loaded[0] != null) {
      coverImage = loaded[0];
    }

    /// Sync [GalleryDownloadProgress.hasDownloaded] for incomplete galleries.
    /// Completed galleries derive hasDownloaded on demand (see getter).
    if (downloadProgress.downloadStatus != DownloadStatus.downloaded) {
      downloadProgress._hasDownloaded ??= List.filled(pageCount, false);
      final List<bool> has = downloadProgress._hasDownloaded!;
      for (int i = 0; i < pageCount; i++) {
        has[i] = loaded[i]?.downloadStatus == DownloadStatus.downloaded;
      }
    }
  }

  /// Refcount of active consumers that need the full [images] list resident
  /// for synchronous access (read page, details page, thumbnails page,
  /// super-resolution, etc.). While non-empty, [evictImages] is a no-op —
  /// the list stays resident until the last consumer calls [releaseImages].
  ///
  /// Keyed by an owner label (caller-supplied, e.g. 'ReadPageLogic',
  /// 'SuperResolutionService') so that a blocked evict can log exactly which
  /// consumers are still holding a retain. A single owner may retain multiple
  /// times — its count is the map value.
  ///
  /// The download loop itself does NOT retain — eviction is gated by
  /// `downloadStatus == downloaded` separately, so an incomplete gallery
  /// never evicts regardless of refcount.
  final Map<String, int> _imageResidents = <String, int>{};

  /// Mark that a consumer (read page, detail page, etc.) needs the full
  /// [images] list to stay resident. Pairs with [releaseImages]. Safe to
  /// call multiple times — each call increments the owner's count, each
  /// release decrements. If [images] is currently evicted, triggers a lazy
  /// reload so the consumer can read synchronously after the returned future
  /// completes (or use [ensureImagesLoaded] explicitly for the async wait).
  ///
  /// [owner] should be a stable identifier for debugging — typically the
  /// consumer's runtimeType or a short literal. Identical owner strings
  /// aggregate into a single map entry.
  void retainImages({required String owner}) {
    _imageResidents[owner] = (_imageResidents[owner] ?? 0) + 1;
    if (images == null) {
      ensureImagesLoaded();
    }
  }

  /// Release a retain. When the count drops to 0 AND the gallery is fully
  /// downloaded, evicts the list to bound memory. Incomplete galleries
  /// keep the list — the download loop is still using it.
  ///
  /// [owner] must match the [retainImages] call. Pass `evictIfComplete: false`
  /// for consumers that close while another is expected to take over
  /// imminently (rare).
  void releaseImages({required String owner, bool evictIfComplete = true}) {
    final int? count = _imageResidents[owner];
    if (count == null || count == 0) {
      log.warning('releaseImages called with owner "$owner" but no matching retain on gallery $gid; current owners: ${_ownersSnapshot()}');
      return;
    }
    if (count == 1) {
      _imageResidents.remove(owner);
    } else {
      _imageResidents[owner] = count - 1;
    }
    if (_imageResidents.isEmpty && evictIfComplete && downloadProgress.downloadStatus == DownloadStatus.downloaded) {
      evictImages();
    }
  }

  /// Whether any consumer is currently retaining the [images] list.
  bool get imagesRetained => _imageResidents.isNotEmpty;

  /// Snapshot of current owners + their retain counts, formatted for logs.
  /// E.g. `ReadPageLogic(1), SuperResolutionService(2)`.
  String _ownersSnapshot() {
    return _imageResidents.entries.map((e) => '${e.key}(${e.value})').join(', ');
  }

  /// Release [images] from memory. [coverImage] is retained for list/grid
  /// cover display. No-op while [imagesRetained] is true — eviction is
  /// deferred to the last consumer's [releaseImages] call, and the blocking
  /// owners are logged for debugging.
  ///
  /// Called directly by the download-completion path and by [releaseImages]
  /// when the refcount drains to 0 on a completed gallery.
  void evictImages() {
    if (_imageResidents.isNotEmpty) {
      log.debug('evictImages skipped on gallery $gid: ${_imageResidents.length} owner(s) still retaining: ${_ownersSnapshot()}');
      return;
    }
    images = null;
  }

  /// Synchronous read — returns null if [images] is not currently resident.
  GalleryImage? imageAtSync(int serialNo) => images?[serialNo];

  /// Async read — triggers [ensureImagesLoaded] if needed.
  Future<GalleryImage?> imageAt(int serialNo) async {
    await ensureImagesLoaded();
    return images?[serialNo];
  }

  /// Write a freshly parsed/created [GalleryImage] at [serialNo]: updates
  /// [images] (if resident) and [coverImage] (if serialNo == 0).
  void upsertImage(int serialNo, GalleryImage image) {
    images ??= List.generate(pageCount, (_) => null);
    images![serialNo] = image;
    if (serialNo == 0) coverImage = image;
  }

  void updateImageStatus(int serialNo, DownloadStatus status) {
    images?[serialNo]?.downloadStatus = status;
    if (serialNo == 0) coverImage?.downloadStatus = status;
  }

  void updateImagePath(int serialNo, String? newPath) {
    images?[serialNo]?.path = newPath;
    if (serialNo == 0) coverImage?.path = newPath;
  }

  void clearImage(int serialNo) {
    images?[serialNo] = null;
    if (serialNo == 0) coverImage = null;
  }

  /// Synthesize a [GalleryDownloadedData] view from the absorbed fields.
  /// Used where external code / DB layer still expects the DataClass shape.
  GalleryDownloadedData toGalleryDownloadedData() => GalleryDownloadedData(
        gid: gid,
        token: token,
        title: title,
        category: category,
        pageCount: pageCount,
        galleryUrl: galleryUrl,
        oldVersionGalleryUrl: oldVersionGalleryUrl,
        uploader: uploader,
        publishTime: publishTime,
        downloadStatusIndex: downloadProgress.downloadStatus.index,
        insertTime: insertTime,
        downloadOriginalImage: downloadOriginalImage,
        priority: priority,
        sortOrder: sortOrder,
        groupName: group,
        tags: tags,
        tagRefreshTime: tagRefreshTime,
        sanitizedTitle: sanitizedTitle,
      );

  /// Build a [GalleryDownloadRequest] from this info's fields. Used when
  /// re-downloading or updating — the request is a pure-data snapshot that
  /// [downloadGallery] can consume to construct a fresh task.
  GalleryDownloadRequest toGalleryDownloadRequest() => GalleryDownloadRequest(
        gid: gid,
        token: token,
        title: title,
        category: category,
        pageCount: pageCount,
        galleryUrl: galleryUrl,
        uploader: uploader,
        publishTime: publishTime,
        downloadOriginalImage: downloadOriginalImage,
        group: group,
        tags: tags,
        tagRefreshTime: tagRefreshTime,
        oldVersionGalleryUrl: oldVersionGalleryUrl,
        sortOrder: sortOrder,
        priority: priority,
      );

  /// 'default' group always sorts last regardless of locale.
  static int groupSortRank(String group) => group == 'default'.tr ? 1 : 0;

  /// Canonical order: group rank → group name → sortOrder → insertTime desc.
  @override
  int compareTo(GalleryDownloadInfo other) {
    final int rankCmp = groupSortRank(group) - groupSortRank(other.group);
    if (rankCmp != 0) {
      return rankCmp;
    }

    final int groupCmp = group.compareTo(other.group);
    if (groupCmp != 0) {
      return groupCmp;
    }

    final int orderCmp = sortOrder - other.sortOrder;
    if (orderCmp != 0) {
      return orderCmp;
    }

    return other.insertTime.compareTo(insertTime);
  }

  int _parseInsertTimePriority() {
    try {
      final DateTime dt = DateFormat('yyyy-MM-dd HH:mm:ss').parse(insertTime);
      return int.parse(DateFormat('MMddHHmmss').format(dt));
    } catch (_) {
      return 0;
    }
  }
}

class GalleryDownloadProgress {
  /// downloaded images count
  int curCount;

  /// total images count
  int totalCount;

  DownloadStatus downloadStatus;

  /// Per-image downloaded flags. Only populated for incomplete galleries
  /// (downloadStatus != downloaded). For completed galleries, the getter
  /// returns a synthesized all-true list on demand — avoids holding a
  /// pageCount-sized List<bool> for every finished gallery in the library.
  List<bool>? _hasDownloaded;

  GalleryDownloadProgress({
    required this.curCount,
    required this.totalCount,
    required this.downloadStatus,
    List<bool>? hasDownloaded,
  }) : _hasDownloaded = hasDownloaded;

  List<bool> get hasDownloaded {
    if (downloadStatus == DownloadStatus.downloaded) {
      return List.filled(totalCount, true);
    }
    return _hasDownloaded ??= List.filled(totalCount, false);
  }

  set hasDownloaded(List<bool> value) => _hasDownloaded = value;

  Map<String, dynamic> toJson() {
    return {
      "curCount": curCount,
      "totalCount": totalCount,
      "downloadStatus": downloadStatus.index,
      "hasDownloaded": jsonEncode(hasDownloaded),
    };
  }

  factory GalleryDownloadProgress.fromJson(Map<String, dynamic> json) {
    return GalleryDownloadProgress(
      curCount: json["curCount"],
      totalCount: json["totalCount"],
      downloadStatus: DownloadStatus.values[json["downloadStatus"]],
      hasDownloaded: (jsonDecode(json["hasDownloaded"]) as List).cast<bool>(),
    );
  }
}

/// Compute gallery download speed during last period every second
class GalleryDownloadSpeedComputer extends SpeedComputer {
  List<int> imageDownloadedBytes;
  List<int> imageTotalBytes;

  GalleryDownloadSpeedComputer(int pageCount, VoidCallback updateCallback)
      : imageDownloadedBytes = List.generate(pageCount, (_) => 0),
        imageTotalBytes = List.generate(pageCount, (_) => 1),
        super(updateCallback: updateCallback);

  void updateProgress(int current, int total, int serialNo) {
    imageTotalBytes[serialNo] = total;

    downloadedBytes -= imageDownloadedBytes[serialNo];
    imageDownloadedBytes[serialNo] = current;
    downloadedBytes += imageDownloadedBytes[serialNo];
  }

  /// one image download failed
  void resetProgress(int serialNo) {
    downloadedBytes -= imageDownloadedBytes[serialNo];
    imageDownloadedBytes[serialNo] = 0;
  }

  int getImageDownloadedBytes(int serialNo) {
    return imageDownloadedBytes[serialNo];
  }
}
