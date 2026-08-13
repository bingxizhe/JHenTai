import 'dart:async';
import 'dart:io';

import 'package:get/get.dart';
import 'package:jhentai/src/service/gallery_download/gallery_download_service.dart';
import 'package:jhentai/src/utils/file_util.dart';
import 'package:path/path.dart';

import '../model/gallery_image.dart';
import '../pages/download/grid/mixin/grid_download_page_service_mixin.dart';
import '../setting/download_setting.dart';
import '../utils/toast_util.dart';
import 'jh_service.dart';
import 'path_service.dart';
import 'log.dart';
import '../widget/loading_state_indicator.dart';
import 'archive_download_service.dart';

/// Load galleries in download directory but is not downloaded by JHenTai
LocalGalleryService localGalleryService = LocalGalleryService();

class LocalGalleryService extends GetxController
    with GridBasePageServiceMixin, JHLifeCircleBeanErrorCatch
    implements JHLifeCircleBean {
  static const String rootPath = '';

  LoadingState loadingState = LoadingState.idle;

  List<LocalGallery> allGalleries = [];
  Map<String, List<LocalGallery>> path2GalleryDir = {};
  Map<String, List<String>> path2SubDir = {};

  Map<int, LocalGallery> gid2EHViewerGallery = {};

  List<String> get rootDirectories => path2SubDir[rootPath] ?? [];

  int scannedDirectoryCount = 0;
  int scannedGalleryCount = 0;
  int totalDirectoryCount = 0;
  String? scanningPath;

  bool _hasScanned = false;
  Future<void>? _refreshTask;

  bool get hasScanned => _hasScanned;

  @override
  Future<void> doInitBean() async {
    Get.put(this, permanent: true);
  }

  @override
  Future<void> doAfterBeanReady() async {}

  Future<void> ensureScanned() async {
    if (_hasScanned) {
      log.info('ensureScanned: already scanned, skipping');
      return;
    }
    log.info('ensureScanned: begin scanning local galleries, scanPaths=${downloadSetting.extraGalleryScanPath}');
    await refreshLocalGalleries();
  }

  Future<void> refreshLocalGalleries() {
    if (loadingState == LoadingState.loading) {
      log.info('refreshLocalGalleries: already loading, returning existing future');
      return _refreshTask ?? Future.value();
    }

    Completer<void> completer = Completer<void>();
    _refreshTask = completer.future;
    loadingState = LoadingState.loading;
    _hasScanned = false;
    scannedDirectoryCount = 0;
    scannedGalleryCount = 0;
    totalDirectoryCount = 0;
    scanningPath = null;

    int preCount = allGalleries.length;

    allGalleries.clear();
    path2GalleryDir.clear();
    path2SubDir.clear();
    update([galleryCountChangedId]);

    log.info('refreshLocalGalleries: starting disk scan');
    _loadGalleriesFromDisk(preCount, completer);
    return _refreshTask!;
  }

  List<GalleryImage> getGalleryImages(LocalGallery gallery) {
    List<File> imageFiles = Directory(gallery.path)
        .listSync()
        .whereType<File>()
        .where((image) => FileUtil.isImageExtension(image.path))
        .toList()
      ..sort(FileUtil.naturalCompareFile);

    return imageFiles
        .map(
          (file) => GalleryImage(
            url: '',
            path: relative(file.path, from: pathService.getVisibleDir().path),
            downloadStatus: DownloadStatus.downloaded,
          ),
        )
        .toList();
  }

  void deleteGallery(LocalGallery gallery, String parentPath) {
    log.info('Delete local gallery: ${gallery.title}');

    Directory dir = Directory(gallery.path);

    List<File> allFiles = dir.listSync().whereType<File>().toList();
    List<File> imageFiles = dir
        .listSync()
        .whereType<File>()
        .where((image) => FileUtil.isImageExtension(image.path))
        .toList();
    if (allFiles.length == imageFiles.length) {
      dir.delete(recursive: true).catchError((e) {
        log.error('Delete local gallery error!', e);
        log.uploadError(e);
        return dir;
      });
    } else {
      for (File file in imageFiles) {
        file.delete().catchError((e) {
          log.error('Delete local gallery error!', e);
          log.uploadError(e);
          return file;
        });
      }
    }

    allGalleries.removeWhere((g) => g.title == gallery.title);
    path2GalleryDir[parentPath]?.removeWhere((g) => g.title == gallery.title);

    update([galleryCountChangedId]);
  }

  Future<void> _loadGalleriesFromDisk(
      int preCount, Completer<void> completer) async {
    DateTime start = DateTime.now();

    final List<String> scanPaths =
        downloadSetting.extraGalleryScanPath.toList(growable: false);
    final String visibleDirPath = pathService.getVisibleDir().path;
    log.info('_loadGalleriesFromDisk: scanPaths=$scanPaths, visibleDirPath=$visibleDirPath');

    try {
      _LocalGalleryScanContext context = _LocalGalleryScanContext(
        onProgress: (scanningPath, scannedDirs, galleryCount, totalDirs) {
          this.scanningPath = scanningPath;
          scannedDirectoryCount = scannedDirs;
          scannedGalleryCount = galleryCount;
          totalDirectoryCount = totalDirs;
          update([galleryCountChangedId]);
        },
        visibleDirPath: visibleDirPath,
      );

      context.totalDirectoryCount = _countDirectories(scanPaths);
      log.info('_loadGalleriesFromDisk: counted ${context.totalDirectoryCount} directories');
      context.sendProgress('counting-done', force: true);

      for (int i = 0; i < scanPaths.length; i++) {
        log.info('_loadGalleriesFromDisk: scanning ${scanPaths[i]}');
        _parseLocalGalleryDirectory(context, Directory(scanPaths[i]), true);
        /// Yield to the event loop between scan paths so the UI stays
        /// responsive. Individual [Directory.listSync] calls are fast enough
        /// that we don't need per-directory yields.
        await Future.delayed(Duration.zero);
      }

      _sortLocalGalleryScanResult(context);
      log.info('_loadGalleriesFromDisk: done, found ${context.allGallerys.length} galleries');

      _handleScanDone(context, preCount, start, completer);
    } catch (e, stackTrace) {
      log.error('_loadGalleriesFromDisk failed', e, stackTrace);
      _handleScanError(e, stackTrace, completer);
    }
  }

  void _handleScanDone(
      _LocalGalleryScanContext context, int preCount, DateTime start, Completer<void> completer) {
    allGalleries = context.allGallerys
        .map((gallery) => LocalGallery.fromScanMessage(gallery))
        .toList();

    path2GalleryDir = {};
    context.path2GalleryDir.forEach((key, value) {
      path2GalleryDir[key] = value
          .map((gallery) => LocalGallery.fromScanMessage(gallery))
          .toList();
    });

    path2SubDir = {};
    context.path2SubDir.forEach((key, value) {
      path2SubDir[key] = List<String>.from(value);
    });

    scannedDirectoryCount = context.scannedDirectoryCount;
    totalDirectoryCount = context.totalDirectoryCount;
    scannedGalleryCount = allGalleries.length;
    scanningPath = null;
    loadingState = LoadingState.success;
    _hasScanned = true;
    _refreshTask = null;

    log.info(
      'Refresh local galleries, preCount:$preCount, newCount: ${allGalleries.length}, timeCost: ${DateTime.now().difference(start).inMilliseconds}ms',
    );

    update([galleryCountChangedId]);

    if (totalDirectoryCount > 0) {
      toast('scanCompleted'.tr);
    }

    if (!completer.isCompleted) {
      completer.complete();
    }
  }

  void _handleScanError(
      Object? error, Object? stackTrace, Completer<void> completer) {
    log.error(
        '_loadGalleriesFromDisk failed, path: ${downloadSetting.extraGalleryScanPath}',
        error,
        stackTrace is StackTrace ? stackTrace : null);
    loadingState = LoadingState.error;
    scanningPath = null;
    _refreshTask = null;
    update([galleryCountChangedId]);

    if (!completer.isCompleted) {
      completer.complete();
    }
  }
}

class LocalGallery {
  String title;
  String path;
  GalleryImage cover;

  LocalGallery({required this.title, required this.path, required this.cover});

  factory LocalGallery.fromScanMessage(Map<String, dynamic> message) {
    return LocalGallery(
      title: message['title'],
      path: message['path'],
      cover: GalleryImage(
        url: '',
        path: message['coverPath'],
        downloadStatus: DownloadStatus.downloaded,
      ),
    );
  }
}

class LocalGalleryParseResult {
  /// has images
  bool isLegalGalleryDir = false;

  /// has subDirectory that has images
  bool isLegalNestedGalleryDir = false;
}

class _LocalGalleryScanContext {
  final void Function(String scanningPath, int scannedDirectoryCount,
      int scannedGalleryCount, int totalDirectoryCount) onProgress;
  final String visibleDirPath;
  final List<Map<String, String>> allGallerys = [];
  final Map<String, List<Map<String, String>>> path2GalleryDir = {};
  final Map<String, List<String>> path2SubDir = {};

  int scannedDirectoryCount = 0;
  int scannedGalleryCount = 0;
  int totalDirectoryCount = 0;
  DateTime lastProgressTime = DateTime.fromMillisecondsSinceEpoch(0);

  _LocalGalleryScanContext(
      {required this.onProgress, required this.visibleDirPath});

  void sendProgress(String scanningPath, {bool force = false}) {
    DateTime now = DateTime.now();
    if (!force && now.difference(lastProgressTime).inMilliseconds < 500) {
      return;
    }

    lastProgressTime = now;
    onProgress(
      scanningPath,
      scannedDirectoryCount,
      scannedGalleryCount,
      totalDirectoryCount,
    );
  }
}

class _LocalGalleryDirectoryScanResult {
  bool isLegalGalleryDir = false;
  bool isLegalNestedGalleryDir = false;
}

int _countDirectories(List<String> scanPaths) {
  int count = 0;
  for (String scanPath in scanPaths) {
    count += _countDirectoriesRecursive(Directory(scanPath));
  }
  return count;
}

int _countDirectoriesRecursive(Directory directory) {
  if (!directory.existsSync()) {
    return 0;
  }
  if (File(join(directory.path, GalleryDownloadService.metadataFileName))
      .existsSync()) {
    return 0;
  }
  if (File(join(directory.path, ArchiveDownloadService.metadataFileName))
      .existsSync()) {
    return 0;
  }

  int count = 1;
  try {
    for (FileSystemEntity entity in directory.listSync()) {
      if (entity is Directory) {
        count += _countDirectoriesRecursive(entity);
      }
    }
  } catch (_) {}
  return count;
}

_LocalGalleryDirectoryScanResult _parseLocalGalleryDirectory(
    _LocalGalleryScanContext context, Directory directory, bool isRootDir) {
  _LocalGalleryDirectoryScanResult result = _LocalGalleryDirectoryScanResult();
  context.scannedDirectoryCount++;
  context.sendProgress(directory.path);

  if (!directory.existsSync()) {
    return result;
  }

  if (File(join(directory.path, GalleryDownloadService.metadataFileName))
      .existsSync()) {
    return result;
  }

  if (File(join(directory.path, ArchiveDownloadService.metadataFileName))
      .existsSync()) {
    return result;
  }

  List<File> images = [];
  List<Directory> subDirectories = [];
  String parentPath =
      isRootDir ? LocalGalleryService.rootPath : directory.parent.path;

  for (FileSystemEntity entity in directory.listSync()) {
    if (entity is File && FileUtil.isImageExtension(entity.path)) {
      result.isLegalGalleryDir = true;
      images.add(entity);
    } else if (entity is Directory) {
      subDirectories.add(entity);
    }
  }

  for (Directory subDirectory in subDirectories) {
    _LocalGalleryDirectoryScanResult subResult =
        _parseLocalGalleryDirectory(context, subDirectory, false);
    if (subResult.isLegalGalleryDir || subResult.isLegalNestedGalleryDir) {
      result.isLegalNestedGalleryDir = true;
      List<String> subDirs = context.path2SubDir[parentPath] ??= [];
      if (!subDirs.contains(directory.path)) {
        subDirs.add(directory.path);
      }
    }
  }

  if (result.isLegalGalleryDir) {
    images.sort(FileUtil.naturalCompareFile);
    _initLocalGalleryInfo(
        context, directory, images.first, parentPath);
  }

  return result;
}

void _initLocalGalleryInfo(_LocalGalleryScanContext context,
    Directory galleryDir, File coverImage, String parentPath) {
  Map<String, String> gallery = {
    'title': basename(galleryDir.path),
    'path': galleryDir.path,
    'coverPath': relative(coverImage.path, from: context.visibleDirPath),
  };

  context.scannedGalleryCount++;
  context.allGallerys.add(gallery);
  (context.path2GalleryDir[parentPath] ??= []).add(gallery);
  context.sendProgress(galleryDir.path, force: true);
}

void _sortLocalGalleryScanResult(_LocalGalleryScanContext context) {
  context.allGallerys
      .sort((a, b) => FileUtil.naturalCompare(a['title']!, b['title']!));
  for (List<Map<String, String>> dirs in context.path2GalleryDir.values) {
    dirs.sort((a, b) => FileUtil.naturalCompare(a['title']!, b['title']!));
  }
  for (List<String> dirs in context.path2SubDir.values) {
    dirs.sort((a, b) => FileUtil.naturalCompare(
        basenameWithoutExtension(a), basenameWithoutExtension(b)));
  }
}
