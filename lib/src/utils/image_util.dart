import 'dart:typed_data';

import 'package:extended_image/extended_image.dart';
import 'package:jhentai/src/service/log.dart';

/// In-flight image requests keyed by URL, so duplicate loads share one future.
final Map<String, Future<Uint8List?>> _inflightNetworkImageData = {};

/// Best-effort wrapper around [getNetworkImageData].
///
/// The underlying implementation writes bytes straight into a shared temp
/// cache file (`<Temp>/cacheimage/<md5>`) without any error handling. When two
/// loads of the same URL run concurrently — or when another process holds that
/// file — the write throws `PathAccessException` (Windows reports errno 5), and
/// since callers fire it as a prefetch the failure surfaces as an unhandled
/// global error.
///
/// Image bytes are not a critical path, so:
/// - duplicate concurrent requests for the same URL share one future;
/// - any failure is logged and converted to `null` instead of being thrown.
Future<Uint8List?> getNetworkImageDataSafely(String url, {bool useCache = true}) {
  final Future<Uint8List?>? inflight = _inflightNetworkImageData[url];
  if (inflight != null) {
    return inflight;
  }

  final Future<Uint8List?> future = getNetworkImageData(url, useCache: useCache)
      .catchError((Object e) {
        log.warning('Load network image failed, url: $url', e);
        return null;
      })
      .whenComplete(() => _inflightNetworkImageData.remove(url));

  _inflightNetworkImageData[url] = future;
  return future;
}
