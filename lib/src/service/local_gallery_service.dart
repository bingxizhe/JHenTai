import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:get/get.dart';
import 'package:jhentai/src/service/gallery_download_service.dart';
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

  List<LocalGallery> allGallerys = [];
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
  ReceivePort? _scanReceivePort;
  Isolate? _scanIsolate;

  bool get hasScanned => _hasScanned;

  @override
  Future<void> doInitBean() async {
    Get.put(this, permanent: true);
  }

  @override
  Future<void> doAfterBeanReady() async {}

  Future<void> ensureScanned() async {
    if (_hasScanned) {
      return;
    }
    log.info('ensureScanned: begin scanning local gallerys');
    await refreshLocalGallerys();
  }

  Future<void> refreshLocalGallerys() {
    if (loadingState == LoadingState.loading) {
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

    int preCount = allGallerys.length;

    allGallerys.clear();
    path2GalleryDir.clear();
    path2SubDir.clear();
    update([galleryCountChangedId]);

    _loadGalleriesFromDiskInIsolate(preCount, completer);
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

    allGallerys.removeWhere((g) => g.title == gallery.title);
    path2GalleryDir[parentPath]?.removeWhere((g) => g.title == gallery.title);

    update([galleryCountChangedId]);
  }

  Future<void> _loadGalleriesFromDiskInIsolate(
      int preCount, Completer<void> completer) async {
    DateTime start = DateTime.now();
    _scanReceivePort?.close();
    _scanIsolate?.kill(priority: Isolate.immediate);
    _scanReceivePort = ReceivePort();

    try {
      _scanReceivePort!.listen(
        (dynamic message) {
          if (message is! Map) {
            return;
          }

          switch (message['type']) {
            case _LocalGalleryScanMessageType.progress:
              _handleScanProgress(message);
              break;
            case _LocalGalleryScanMessageType.done:
              _handleScanDone(message, preCount, start, completer);
              break;
            case _LocalGalleryScanMessageType.error:
              _handleScanError(
                  message['error'], message['stackTrace'], completer);
              break;
          }
        },
      );

      _scanIsolate = await Isolate.spawn(
        _scanLocalGalleriesInIsolate,
        {
          'sendPort': _scanReceivePort!.sendPort,
          'scanPaths':
              downloadSetting.extraGalleryScanPath.toList(growable: false),
          'visibleDirPath': pathService.getVisibleDir().path,
        },
        debugName: 'local-gallery-scanner',
      );
    } catch (e, stackTrace) {
      _handleScanError(e, stackTrace, completer);
    }
  }

  void _handleScanProgress(Map message) {
    scannedDirectoryCount =
        message['scannedDirectoryCount'] ?? scannedDirectoryCount;
    scannedGalleryCount = message['scannedGalleryCount'] ?? scannedGalleryCount;
    totalDirectoryCount = message['totalDirectoryCount'] ?? totalDirectoryCount;
    scanningPath = message['scanningPath'];
    update([galleryCountChangedId]);
  }

  void _handleScanDone(
      Map message, int preCount, DateTime start, Completer<void> completer) {
    allGallerys = ((message['allGallerys'] as List?) ?? [])
        .whereType<Map>()
        .map((gallery) =>
            LocalGallery.fromScanMessage(gallery.cast<String, dynamic>()))
        .toList();

    path2GalleryDir = {};
    ((message['path2GalleryDir'] as Map?) ?? {})
        .forEach((dynamic key, dynamic value) {
      path2GalleryDir[key as String] = ((value as List?) ?? [])
          .whereType<Map>()
          .map((gallery) =>
              LocalGallery.fromScanMessage(gallery.cast<String, dynamic>()))
          .toList();
    });

    path2SubDir = {};
    ((message['path2SubDir'] as Map?) ?? {})
        .forEach((dynamic key, dynamic value) {
      path2SubDir[key as String] = ((value as List?) ?? []).cast<String>();
    });

    scannedDirectoryCount =
        message['scannedDirectoryCount'] ?? scannedDirectoryCount;
    totalDirectoryCount = message['totalDirectoryCount'] ?? totalDirectoryCount;
    scannedGalleryCount = allGallerys.length;
    scanningPath = null;
    loadingState = LoadingState.success;
    _hasScanned = true;
    _refreshTask = null;
    _disposeScanner();

    log.info(
      'Refresh local gallerys, preCount:$preCount, newCount: ${allGallerys.length}, timeCost: ${DateTime.now().difference(start).inMilliseconds}ms',
    );

    update([galleryCountChangedId]);

    if (totalDirectoryCount > 0) {
      toast('scanCompleted'.tr);
    }

    completer.complete();
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
    _disposeScanner();
    update([galleryCountChangedId]);

    if (!completer.isCompleted) {
      completer.complete();
    }
  }

  void _disposeScanner() {
    _scanReceivePort?.close();
    _scanReceivePort = null;
    _scanIsolate = null;
  }

  @override
  void onClose() {
    _scanReceivePort?.close();
    _scanIsolate?.kill(priority: Isolate.immediate);
    super.onClose();
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

class _LocalGalleryScanMessageType {
  static const String progress = 'progress';
  static const String done = 'done';
  static const String error = 'error';
}

class _LocalGalleryScanContext {
  final SendPort sendPort;
  final String visibleDirPath;
  final List<Map<String, String>> allGallerys = [];
  final Map<String, List<Map<String, String>>> path2GalleryDir = {};
  final Map<String, List<String>> path2SubDir = {};

  int scannedDirectoryCount = 0;
  int scannedGalleryCount = 0;
  int totalDirectoryCount = 0;
  DateTime lastProgressTime = DateTime.fromMillisecondsSinceEpoch(0);

  _LocalGalleryScanContext(
      {required this.sendPort, required this.visibleDirPath});

  void sendProgress(String scanningPath, {bool force = false}) {
    DateTime now = DateTime.now();
    if (!force && now.difference(lastProgressTime).inMilliseconds < 500) {
      return;
    }

    lastProgressTime = now;
    sendPort.send({
      'type': _LocalGalleryScanMessageType.progress,
      'scannedDirectoryCount': scannedDirectoryCount,
      'scannedGalleryCount': scannedGalleryCount,
      'totalDirectoryCount': totalDirectoryCount,
      'scanningPath': scanningPath,
    });
  }
}

class _LocalGalleryDirectoryScanResult {
  bool isLegalGalleryDir = false;
  bool isLegalNestedGalleryDir = false;
}

void _scanLocalGalleriesInIsolate(Map<String, dynamic> args) {
  SendPort sendPort = args['sendPort'];
  List<String> scanPaths = (args['scanPaths'] as List).cast<String>();
  String visibleDirPath = args['visibleDirPath'];
  _LocalGalleryScanContext context = _LocalGalleryScanContext(
      sendPort: sendPort, visibleDirPath: visibleDirPath);

  try {
    context.totalDirectoryCount = _countDirectoriesInIsolate(scanPaths);
    context.sendProgress('counting-done', force: true);

    for (String scanPath in scanPaths) {
      _parseLocalGalleryDirectoryInIsolate(context, Directory(scanPath), true);
    }

    _sortLocalGalleryScanResult(context);
    sendPort.send({
      'type': _LocalGalleryScanMessageType.done,
      'allGallerys': context.allGallerys,
      'path2GalleryDir': context.path2GalleryDir,
      'path2SubDir': context.path2SubDir,
      'scannedDirectoryCount': context.scannedDirectoryCount,
      'totalDirectoryCount': context.totalDirectoryCount,
    });
  } catch (e, stackTrace) {
    sendPort.send({
      'type': _LocalGalleryScanMessageType.error,
      'error': e.toString(),
      'stackTrace': stackTrace.toString(),
    });
  }
}

int _countDirectoriesInIsolate(List<String> scanPaths) {
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

_LocalGalleryDirectoryScanResult _parseLocalGalleryDirectoryInIsolate(
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
        _parseLocalGalleryDirectoryInIsolate(context, subDirectory, false);
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
    _initLocalGalleryInfoInIsolate(
        context, directory, images.first, parentPath);
  }

  return result;
}

void _initLocalGalleryInfoInIsolate(_LocalGalleryScanContext context,
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
