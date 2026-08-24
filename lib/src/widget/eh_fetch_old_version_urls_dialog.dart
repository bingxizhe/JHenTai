
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

/// A dialog that scans every downloaded gallery, fetches its complete ancestor
/// chain (parent, grandparent, …) from the EH detail page, and persists it as
/// [oldVersionGalleryUrl] (a JSON-array string).
///
/// The recursive crawl walks `parentGalleryUrl` links up the version tree until
/// it reaches a gallery with no parent, hits the max-depth guard, or detects a
/// cycle. A partial chain (obtained before a mid-way network failure) is still
/// persisted — every discovered ancestor is valuable for the "Delete history
/// versions" grouping.
///
/// Legacy single-URL records (written before the chain format was introduced)
/// are automatically upgraded: the known parent seeds the chain and crawling
/// resumes from there, so cross-multi-hop relationships are discovered without
/// re-requesting the gallery's own detail page.
///
/// Retry strategy matches the "Delete history versions" deep-scan logic:
///   1. Try the site the gallery URL currently points to (5 retries)
///   2. On failure, try the opposite site (5 retries)
///   3. On still-failure, return what has been collected so far
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
    /// Skip galleries that already have a new-format (JSON-array) chain.
    /// Legacy single-URL records are re-crawled to upgrade them to a full
    /// ancestor chain — without this, cross-multi-hop version relationships
    /// captured before the chain format would never be discovered.
    if (gallery.hasVersionChain && !gallery.isLegacyVersionUrl) {
      return;
    }

    final GalleryUrl? galleryUrl = GalleryUrl.tryParse(gallery.galleryUrl);
    if (galleryUrl == null) {
      failedCount++;
      failedTitles.add(gallery.title);
      return;
    }

    /// For legacy single-URL records, seed the chain with the known parent
    /// and continue crawling from there instead of re-requesting the
    /// gallery's own detail page. This upgrades the record to the full
    /// ancestor-chain format while avoiding a redundant network request.
    final List<String> knownAncestors = gallery.oldVersionChain;

    /// Recursively crawl parent links to build the full ancestor chain.
    /// A partial chain (collected before a mid-way failure) is still persisted.
    final ({List<String> chain, bool anySuccess}) result =
        await _fetchFullAncestorChain(galleryUrl, gallery.gid, knownAncestors: knownAncestors);

    if (!result.anySuccess && knownAncestors.isEmpty) {
      /// No known ancestors and every network attempt failed — record as a
      /// failed gallery. When known ancestors exist we still persist them
      /// (upgrading the format) even if the deeper crawl failed.
      failedCount++;
      failedTitles.add(gallery.title);
      return;
    }

    if (result.chain.isEmpty) {
      /// At least one request succeeded but no parent was found — this is a
      /// leaf gallery with no ancestry, not a failure.
      return;
    }

    await galleryDownloadService.updateOldVersionChain(gallery.gid, result.chain);
    updatedCount++;
    log.info('fetchOldVersionUrls: set chain (length ${result.chain.length}) for gallery ${gallery.gid}');
  }

  /// Crawl `parentGalleryUrl` links starting from [startUrl] up the version
  /// tree, returning the ordered ancestor chain (direct parent first, oldest
  /// root last) and whether any network request succeeded. Stops when: no
  /// parent is found, max depth is reached, a cycle is detected, or a hop
  /// fails on both sites. Each hop uses the same 5-retry + site-fallback
  /// strategy as the deep scan.
  ///
  /// [knownAncestors] seeds the chain with previously-recorded ancestors
  /// (e.g. a legacy single-URL record's direct parent). Crawling then
  /// resumes from the last known ancestor instead of re-requesting the
  /// gallery's own detail page, so legacy records are upgraded to the full
  /// chain format without redundant network requests.
  Future<({List<String> chain, bool anySuccess})> _fetchFullAncestorChain(
    GalleryUrl startUrl, int gid, {
    List<String> knownAncestors = const <String>[],
  }) async {
    const int maxDepth = 20;
    final List<String> chain = <String>[...knownAncestors];
    final Set<String> visited = <String>{startUrl.url, ...knownAncestors};
    bool anySuccess = false;

    /// Once a hop succeeds only on the fallback site, all subsequent hops
    /// skip the original site and go straight to the site that worked.
    /// null = use the URL's own site first; true = force e-hentai; false = force exhentai.
    bool? forceIsEH;

    /// Start crawling from the last known ancestor (if any) so we don't
    /// re-request the gallery's own detail page when a parent is already
    /// recorded. For legacy single-URL records this means we begin at the
    /// known parent and look for the grandparent.
    GalleryUrl? current = knownAncestors.isEmpty
        ? startUrl
        : GalleryUrl.tryParse(knownAncestors.last);

    for (int depth = 0; depth < maxDepth; depth++) {
      if (current == null) {
        break;
      }

      final ({bool success, String? parentUrl, bool? usedIsEH}) hop =
          await _fetchParentUrl(current, gid, forceIsEH: forceIsEH);
      if (hop.success) {
        anySuccess = true;
        /// Lock to the fallback site if this hop only succeeded there,
        /// so later hops skip the dead site entirely.
        if (forceIsEH == null && hop.usedIsEH != null && hop.usedIsEH != current.isEH) {
          forceIsEH = hop.usedIsEH;
          log.info('fetchOldVersionUrls: locking subsequent hops to ${forceIsEH! ? "e-hentai" : "exhentai"} for gallery $gid');
        }
      }

      if (!hop.success) {
        /// Both sites failed for this hop — stop, keep the partial chain.
        break;
      }

      final String? parentUrl = hop.parentUrl;
      if (parentUrl == null || parentUrl.isEmpty) {
        /// Request succeeded but this gallery has no parent — reached the root.
        break;
      }

      /// Cycle guard — the site returned a parent we've already visited
      /// (shouldn't happen on well-formed data, but protects against loops).
      if (visited.contains(parentUrl)) {
        log.warning('fetchOldVersionUrls: cycle detected at $parentUrl for gallery $gid, stopping crawl');
        break;
      }

      chain.add(parentUrl);
      visited.add(parentUrl);

      /// If the parent is itself a locally-downloaded gallery that already has
      /// a recorded chain, we can short-circuit: append the known chain and
      /// stop the network crawl. This reuses previously fetched ancestry and
      /// avoids redundant requests.
      ///
      /// Match by gid+token ignoring domain: the parent URL may be an
      /// exhentai.org URL (when the fallback site was used) while the local
      /// gallery was downloaded from e-hentai.org, or vice versa.
      final GalleryUrl? parentParsed = GalleryUrl.tryParse(parentUrl);
      final GalleryDownloadInfo? parentLocal = parentParsed == null
          ? null
          : galleryDownloadService.galleries.firstWhereOrNull(
              (g) {
                GalleryUrl? gp = GalleryUrl.tryParse(g.galleryUrl);
                return gp != null &&
                    gp.gid == parentParsed.gid &&
                    gp.token == parentParsed.token;
              },
            );
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

    return (chain: chain, anySuccess: anySuccess);
  }

  /// Fetch a single gallery's detail page and return its parentGalleryUrl.
  /// Returns a record: [success] is true if at least one site responded;
  /// [parentUrl] is the parent URL (null/empty if the gallery has no parent);
  /// [usedIsEH] is the site that actually responded (null on total failure).
  ///
  /// [forceIsEH] skips the original-site attempt and goes straight to the
  /// specified site. Set by the caller after an earlier hop only succeeded
  /// on the fallback site, to avoid wasting a round-trip on the dead site.
  Future<({bool success, String? parentUrl, bool? usedIsEH})> _fetchParentUrl(
    GalleryUrl galleryUrl, int gid, {
    bool? forceIsEH,
  }) async {
    if (forceIsEH != null) {
      final GalleryUrl forcedUrl = galleryUrl.copyWith(isEH: forceIsEH);
      final ({bool success, String? parentUrl}) r = await _tryFetchParent(forcedUrl.url, gid);
      return (success: r.success, parentUrl: r.parentUrl, usedIsEH: r.success ? forceIsEH : null);
    }

    /// Phase 1: try original site (5 retries)
    final ({bool success, String? parentUrl}) r1 = await _tryFetchParent(galleryUrl.url, gid);
    if (r1.success) {
      return (success: true, parentUrl: r1.parentUrl, usedIsEH: galleryUrl.isEH);
    }

    /// Phase 2: fallback to opposite site (5 retries)
    final GalleryUrl altUrl = galleryUrl.copyWith(isEH: !galleryUrl.isEH);
    log.warning(
        'fetchOldVersionUrls: gallery $gid failed on ${galleryUrl.isEH ? "e-hentai" : "exhentai"}, trying ${altUrl.isEH ? "e-hentai" : "exhentai"}');
    final ({bool success, String? parentUrl}) r2 = await _tryFetchParent(altUrl.url, gid);
    return (success: r2.success, parentUrl: r2.parentUrl, usedIsEH: r2.success ? altUrl.isEH : null);
  }

  /// Request one detail page and extract parentGalleryUrl.
  /// Returns [success=true] with the parent URL (null if no parent) on a
  /// successful response, or [success=false] on network failure after retries.
  Future<({bool success, String? parentUrl})> _tryFetchParent(String url, int gid) async {
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
      return (success: true, parentUrl: result.galleryDetails.parentGalleryUrl?.url);
    } catch (e) {
      log.warning('fetchOldVersionUrls: failed to fetch detail for gallery $gid at $url', e);
      return (success: false, parentUrl: null);
    }
  }
}

enum _DialogPhase { idle, scanning, completed }
