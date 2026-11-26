part of 'gallery_download_service.dart';

/// Handles copying image data (bytes + metadata + super-resolution info) from
/// an old gallery version to a new one during a gallery update. Locates
/// matching images by [imageHash] and reuses their downloaded bytes instead of
/// re-downloading.
///
/// Byte copying always happens inside the executor task that triggered it
/// (never in its own task), so the per-image rate limiter — which only gates
/// task starts — does not throttle copies.
///
/// Only real file copies are used: no hard links, no moves, so the old version
/// always keeps a complete, independent set of files.
class _GalleryUpgradeMigrator {
  final GalleryDownloadService _service;

  _GalleryUpgradeMigrator(this._service);

  /// Locate the locally downloaded parent version of [newGallery].
  ///
  /// Matches by gid+token ignoring the domain: `directParentUrl` is recorded
  /// from the EH detail page and may point at exhentai.org while the local
  /// gallery was downloaded from e-hentai.org (or vice versa). An exact URL
  /// match is tried first as a fast path; the fallback compares the two URLs
  /// with the host normalized, which is a plain string compare — this method
  /// runs once per thumbnails page and once per image-page fallback, so it
  /// must stay cheap.
  GalleryDownloadInfo? _findLocalParent(GalleryDownloadInfo newGallery) {
    final String? parentUrl = newGallery.directParentUrl;
    if (parentUrl == null) {
      return null;
    }

    final GalleryDownloadInfo? exact = _service.galleries.firstWhereOrNull((e) => e.galleryUrl == parentUrl);
    if (exact != null) {
      return exact;
    }

    final String normalizedParentUrl = _normalizeGalleryUrlDomain(parentUrl);
    final GalleryDownloadInfo? domainInsensitive = _service.galleries.firstWhereOrNull(
      (e) => _normalizeGalleryUrlDomain(e.galleryUrl) == normalizedParentUrl,
    );

    if (domainInsensitive == null) {
      log.info('Reuse: parent gallery not found locally, parent gid: ${GalleryUrl.tryParse(parentUrl)?.gid}, url: $parentUrl');
    } else {
      log.info('Reuse: parent gallery matched by gid+token ignoring domain, parent gid: ${domainInsensitive.gid}');
    }

    return domainInsensitive;
  }

  /// Drop the EX/EH host distinction so the same gallery URL compares equal
  /// regardless of which site recorded it.
  static String _normalizeGalleryUrlDomain(String url) => url.replaceFirst('exhentai.org', 'e-hentai.org');

  /// Build `imageHash -> serialNo` for an old version's images. Built once per
  /// bulk call instead of scanning the list per image.
  Map<String, int> _buildHashIndex(List<GalleryImage?>? images) {
    final Map<String, int> index = {};
    if (images == null) {
      return index;
    }
    for (int serialNo = 0; serialNo < images.length; serialNo++) {
      final String? hash = images[serialNo]?.imageHash;
      if (hash != null && hash.isNotEmpty) {
        index.putIfAbsent(hash, () => serialNo);
      }
    }
    return index;
  }

  int? _findOldSerialNoByHash(List<GalleryImage?>? images, String hash) {
    if (images == null) {
      return null;
    }
    for (int serialNo = 0; serialNo < images.length; serialNo++) {
      if (images[serialNo]?.imageHash == hash) {
        return serialNo;
      }
    }
    return null;
  }

  /// Copy one image's bytes from the old version into the new version's path.
  ///
  /// Returns false when the reusable bytes are unavailable (source file gone,
  /// permission/space error, ...) so the caller falls back to a normal
  /// download instead of failing the whole update.
  Future<bool> _copyImageBytes(GalleryImage oldImage, GalleryImage newImage, int serialNo) async {
    if (oldImage.path == null || newImage.path == null) {
      return false;
    }

    final io.File oldFile = io.File(path.join(pathService.getVisibleDir().path, oldImage.path!));
    if (!await oldFile.exists()) {
      log.download('Reuse: skip image $serialNo, old file missing: ${oldImage.path}');
      return false;
    }

    final io.File newFile = io.File(path.join(pathService.getVisibleDir().path, newImage.path!));
    try {
      await newFile.parent.create(recursive: true);
      await oldFile.copy(newFile.path);
      return true;
    } catch (e, st) {
      log.error('Reuse: copy image $serialNo failed, fall back to download', e, st);
      return false;
    }
  }

  /// Copy bytes + metadata for one matched pair, then mark it downloaded.
  ///
  /// When the new gallery already holds a resident [GalleryImage] (row parsed
  /// before this call), that instance is updated in place so in-memory status
  /// stays consistent with the DB — otherwise a later `processImage` would
  /// re-download an image that was just reused.
  Future<bool> _reuseImage(GalleryDownloadInfo oldGallery, int oldSerialNo, GalleryDownloadInfo newGallery, int newSerialNo) async {
    final GalleryImage? oldImage = oldGallery.imageAtSync(oldSerialNo);
    if (oldImage == null) {
      return false;
    }

    /// Path extension depends on the actual download URL. Old gallery may
    /// have `downloadOriginalImage=true` and stored `fullimg.php`→`jpg` on
    /// disk; we must use the same URL when recomputing the path for the new
    /// gallery so the extension matches.
    final String oldDownloadUrl = _downloadUrlFor(oldGallery.toGalleryDownloadedData(), oldImage);
    final GalleryImage newImage = oldImage.copyWith(
      path: DownloadPathResolver.computeImageDownloadRelativePath(newGallery.toGalleryDownloadedData(), oldDownloadUrl, newSerialNo),
      downloadStatus: DownloadStatus.downloaded,
    );

    if (!await _copyImageBytes(oldImage, newImage, newSerialNo)) {
      return false;
    }

    log.download('Copy old image, new serialNo: $newSerialNo');

    final GalleryImage? resident = newGallery.imageAtSync(newSerialNo);
    if (resident == null) {
      await _service._saveNewImageInfoInDatabase(newImage, newSerialNo, newGallery.gid);
      newGallery.upsertImage(newSerialNo, newImage);
    } else {
      await _service._updateImageStatus(newGallery, resident, newSerialNo, DownloadStatus.downloaded);
    }

    await _service._updateProgressAfterImageDownloaded(newGallery, newSerialNo);

    await superResolutionService.copyImageInfo(oldGallery.toGalleryDownloadedData(), newGallery.toGalleryDownloadedData(), oldSerialNo, newSerialNo);

    return true;
  }

  /// Bulk-copy matching images by a full hash list for the new gallery, e.g.
  /// the list served by the JHenTai server. Called once per gallery update
  /// inside a single executor task, so the loop is not rate limited.
  Future<void> copyImageInfosFromImageHashes(GalleryDownloadInfo newGallery, List<String> imageHashes) async {
    GalleryDownloadInfo? oldGallery = _findLocalParent(newGallery);
    if (oldGallery == null) {
      return;
    }

    /// The old gallery's image list may have been evicted from memory
    /// (download complete / read page close), so sync reads below would find
    /// nothing. Reload from DB first so byte-copy can locate old images.
    await oldGallery.ensureImagesLoaded();

    final Map<String, int> hash2OldSerialNo = _buildHashIndex(oldGallery.images);
    if (hash2OldSerialNo.isEmpty) {
      log.info('Reuse: old gallery ${oldGallery.gid} has no image hash, skip bulk reuse');
      return;
    }

    int copied = 0;
    for (int serialNo = 0; serialNo < newGallery.pageCount && serialNo < imageHashes.length; serialNo++) {
      if (_service._taskHasBeenPausedOrRemoved(newGallery)) {
        break;
      }

      if (newGallery.imageAtSync(serialNo)?.downloadStatus == DownloadStatus.downloaded) {
        continue;
      }

      final int? oldImageSerialNo = hash2OldSerialNo[imageHashes[serialNo]];
      if (oldImageSerialNo == null) {
        continue;
      }

      if (await _reuseImage(oldGallery, oldImageSerialNo, newGallery, serialNo)) {
        copied++;
      }
    }

    log.info('Reuse: bulk copy finished, gid: ${newGallery.gid}, copied: $copied/${newGallery.pageCount}');
    _service._saveGalleryMetadataInDisk(newGallery);
  }

  /// Bulk-copy every reusable image of a thumbnails page.
  ///
  /// Uses the thumbnails' `data-orghash` (`originImageHash`) as the new
  /// version's page identity. Called right after a page's hrefs are parsed, so
  /// all copies of the page run inside that single executor task and the rate
  /// limiter only charges one slot for the whole page instead of one per image.
  Future<void> copyImageInfosFromImageHrefs(GalleryDownloadInfo newGallery, int fromSerialNo, int toSerialNo) async {
    final GalleryDownloadInfo? oldGallery = _findLocalParent(newGallery);
    if (oldGallery == null) {
      return;
    }

    await oldGallery.ensureImagesLoaded();

    final Map<String, int> hash2OldSerialNo = _buildHashIndex(oldGallery.images);
    if (hash2OldSerialNo.isEmpty) {
      log.info('Reuse: old gallery ${oldGallery.gid} has no image hash, skip page reuse');
      return;
    }

    int copied = 0;
    final int end = toSerialNo < newGallery.pageCount - 1 ? toSerialNo : newGallery.pageCount - 1;
    for (int serialNo = fromSerialNo; serialNo <= end; serialNo++) {
      if (_service._taskHasBeenPausedOrRemoved(newGallery)) {
        break;
      }

      if (newGallery.imageAtSync(serialNo)?.downloadStatus == DownloadStatus.downloaded) {
        continue;
      }

      final String? newImageHash = newGallery.imageHrefs[serialNo]?.originImageHash;
      if (newImageHash == null) {
        continue;
      }

      final int? oldImageSerialNo = hash2OldSerialNo[newImageHash];
      if (oldImageSerialNo == null) {
        continue;
      }

      if (await _reuseImage(oldGallery, oldImageSerialNo, newGallery, serialNo)) {
        copied++;
      }
    }

    if (copied > 0) {
      log.info('Reuse: page reuse finished, gid: ${newGallery.gid}, range: $fromSerialNo-$end, copied: $copied');
      _service._saveGalleryMetadataInDisk(newGallery);
    }
  }

  /// Fallback reuse for layouts whose thumbnails carry no `data-orghash`:
  /// match by the hash parsed from the image page itself. Called from
  /// [downloadImageTask] after the image page has been fetched, so it costs no
  /// extra rate-limiter slot.
  Future<void> tryCopyImageInfoFromImage(GalleryDownloadInfo newGallery, int newImageSerialNo) async {
    final String? hash = newGallery.imageAtSync(newImageSerialNo)?.imageHash;
    if (hash == null || hash.isEmpty) {
      return;
    }

    final GalleryDownloadInfo? oldGallery = _findLocalParent(newGallery);
    if (oldGallery == null) {
      return;
    }

    await oldGallery.ensureImagesLoaded();

    final int? oldImageSerialNo = _findOldSerialNoByHash(oldGallery.images, hash);
    if (oldImageSerialNo == null) {
      return;
    }

    await _reuseImage(oldGallery, oldImageSerialNo, newGallery, newImageSerialNo);
  }
}
