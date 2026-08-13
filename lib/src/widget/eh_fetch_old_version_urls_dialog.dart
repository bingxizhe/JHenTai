import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:jhentai/src/model/gallery_detail.dart';
import 'package:jhentai/src/model/gallery_url.dart';
import 'package:jhentai/src/network/eh_request.dart';
import 'package:jhentai/src/service/gallery_download/gallery_download_service.dart';
import 'package:jhentai/src/service/log.dart';
import 'package:jhentai/src/utils/eh_spider_parser.dart';
import 'package:retry/retry.dart';

/// A dialog that scans every downloaded gallery, fetches its parent gallery
/// URL from the EH detail page, and persists it as [oldVersionGalleryUrl].
///
/// Retry strategy matches the "Delete history versions" deep-scan logic:
///   1. Try the site the gallery URL currently points to (5 retries)
///   2. On failure, try the opposite site (5 retries)
///   3. On still-failure, record the gallery in the failed list
class EHFetchOldVersionUrlsDialog extends StatefulWidget {
  const EHFetchOldVersionUrlsDialog({Key? key}) : super(key: key);

  @override
  State<EHFetchOldVersionUrlsDialog> createState() => _EHFetchOldVersionUrlsDialogState();
}

class _EHFetchOldVersionUrlsDialogState extends State<EHFetchOldVersionUrlsDialog> {
  _DialogPhase phase = _DialogPhase.idle;
  int totalCount = 0;
  int scannedCount = 0;
  int updatedCount = 0;
  int failedCount = 0;
  final List<String> failedTitles = <String>[];

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('fetchOldVersionUrls'.tr),
      content: _buildBody(context),
      actions: _buildActions(context),
      contentPadding: const EdgeInsets.fromLTRB(24, 16, 24, 0),
      actionsPadding: const EdgeInsets.all(16),
    );
  }

  List<Widget>? _buildActions(BuildContext context) {
    switch (phase) {
      case _DialogPhase.idle:
        return [
          TextButton(onPressed: Get.back, child: Text('cancel'.tr)),
          ElevatedButton(onPressed: _start, child: Text('start'.tr)),
        ];
      case _DialogPhase.scanning:
        return null;
      case _DialogPhase.completed:
        return [
          TextButton(onPressed: Get.back, child: Text('close'.tr)),
        ];
    }
  }

  Widget _buildBody(BuildContext context) {
    switch (phase) {
      case _DialogPhase.idle:
        return _buildIdle(context);
      case _DialogPhase.scanning:
        return _buildScanning(context);
      case _DialogPhase.completed:
        return _buildCompleted(context);
    }
  }

  Widget _buildIdle(BuildContext context) {
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 400),
      child: Text('fetchOldVersionUrlsHint'.tr, style: const TextStyle(fontSize: 14)),
    );
  }

  Widget _buildScanning(BuildContext context) {
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 400),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'fetchOldVersionUrlsProgress'
                .tr
                .replaceAll('{count}', scannedCount.toString())
                .replaceAll('{total}', totalCount.toString()),
            style: const TextStyle(fontSize: 14),
          ),
          const SizedBox(height: 8),
          Text('${'updatedCount'.tr}: $updatedCount', style: const TextStyle(fontSize: 13)),
          Text('${'failedCount'.tr}: $failedCount', style: const TextStyle(fontSize: 13)),
          const SizedBox(height: 12),
          LinearProgressIndicator(
            value: totalCount == 0 ? null : scannedCount / totalCount,
          ),
        ],
      ),
    );
  }

  Widget _buildCompleted(BuildContext context) {
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 400, maxHeight: 400),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'fetchOldVersionUrlsDone'
                  .tr
                  .replaceAll('{updated}', updatedCount.toString())
                  .replaceAll('{failed}', failedCount.toString()),
              style: const TextStyle(fontSize: 14),
            ),
            if (failedTitles.isNotEmpty) ...[
              const SizedBox(height: 12),
              Text('${'failedItems'.tr}:', style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold)),
              const SizedBox(height: 4),
              ...failedTitles.map(
                (title) => Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(title, style: const TextStyle(fontSize: 12)),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Future<void> _start() async {
    final List<GalleryDownloadInfo> allGalleries =
        List.of(galleryDownloadService.galleries);
    totalCount = allGalleries.length;
    scannedCount = 0;
    updatedCount = 0;
    failedCount = 0;
    failedTitles.clear();
    setState(() => phase = _DialogPhase.scanning);

    for (final GalleryDownloadInfo gallery in allGalleries) {
      await _fetchForGallery(gallery);
      scannedCount++;
      if (scannedCount % 5 == 0) {
        setState(() {});
      }
      await Future.delayed(Duration.zero);
    }
    setState(() => phase = _DialogPhase.completed);
  }

  Future<void> _fetchForGallery(GalleryDownloadInfo gallery) async {
    /// Skip galleries that already have oldVersionGalleryUrl set.
    if (gallery.oldVersionGalleryUrl != null) {
      return;
    }

    final GalleryUrl? galleryUrl = GalleryUrl.tryParse(gallery.galleryUrl);
    if (galleryUrl == null) {
      failedCount++;
      failedTitles.add(gallery.title);
      return;
    }

    /// Phase 1: try original site (5 retries)
    bool success = await _fetchAndPersist(galleryUrl.url, gallery);
    if (success) {
      updatedCount++;
      return;
    }

    /// Phase 2: fallback to opposite site (5 retries)
    final GalleryUrl altUrl = galleryUrl.copyWith(isEH: !galleryUrl.isEH);
    log.warning(
        'fetchOldVersionUrls: gallery ${gallery.gid} failed on ${galleryUrl.isEH ? "e-hentai" : "exhentai"}, trying ${altUrl.isEH ? "e-hentai" : "exhentai"}');
    success = await _fetchAndPersist(altUrl.url, gallery);
    if (success) {
      updatedCount++;
      return;
    }

    /// Phase 3: record failure
    failedCount++;
    failedTitles.add(gallery.title);
  }

  /// Fetch detail page and persist parentGalleryUrl if found.
  /// Returns true on success (even if no parent URL found), false on failure.
  Future<bool> _fetchAndPersist(String url, GalleryDownloadInfo gallery) async {
    try {
      final ({GalleryDetail galleryDetails, String apikey}) result = await retry(
        () => ehRequest.requestDetailPage(
          galleryUrl: url,
          useCacheIfAvailable: true,
          parser: EHSpiderParser.detailPage2GalleryAndDetailAndApikey,
        ),
        retryIf: (e) => e is DioException,
        maxAttempts: 5,
      );
      final String? parentUrl = result.galleryDetails.parentGalleryUrl?.url;
      if (parentUrl != null && parentUrl.isNotEmpty) {
        await galleryDownloadService.updateOldVersionGalleryUrl(gallery.gid, parentUrl);
        log.info('fetchOldVersionUrls: set oldVersionGalleryUrl=$parentUrl for gallery ${gallery.gid}');
      }
      return true;
    } catch (e) {
      log.warning('fetchOldVersionUrls: failed to fetch detail for gallery ${gallery.gid}', e);
      return false;
    }
  }
}

enum _DialogPhase { idle, scanning, completed }
