import 'dart:io';

import 'package:get/get.dart';
import 'package:jhentai/src/utils/toast_util.dart';
import 'package:path/path.dart';

import '../setting/read_setting.dart';
import '../service/log.dart';

Future<void> openThirdPartyViewer(String dirPath) async {
  String viewerPath = readSetting.thirdPartyViewerPath.value!;

  ProcessResult result;
  try {
    result = await Process.run(
      basename(viewerPath),
      [dirPath],
      workingDirectory: dirname(viewerPath),
      runInShell: true,
    );
  } catch (e) {
    toast('internalError'.tr + e.toString());
    log.error(e);
    log.uploadError(
      e,
      extraInfos: {'viewerPath': viewerPath, 'dirPath': dirPath},
    );
    return;
  }

  // GUI readers (esp. Chromium/Electron-based ones) print non-fatal log
  // noise to stderr — e.g. GPU/disk-cache creation failures
  // (cache_util_win.cc, gpu_disk_cache.cc, ERROR_ACCESS_DENIED 0x5) —
  // while still launching and working correctly. A non-empty stderr is
  // therefore not a reliable error signal; only a non-zero exit code is.
  if (result.exitCode == 0) {
    return;
  }

  String stderr = result.stderr?.toString() ?? '';
  String display = stderr.isEmpty ? "exitCode: ${result.exitCode}" : stderr;
  toast('internalError'.tr + display);
  log.error(display);
  log.uploadError(
    Exception('Process Error'),
    extraInfos: {
      'viewerPath': viewerPath,
      'dirPath': dirPath,
      'exitCode': result.exitCode,
      'stderr': stderr,
    },
  );
}