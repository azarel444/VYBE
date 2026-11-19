import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

/// Android's filesDir is the same app-private directory returned by
/// path_provider's getApplicationSupportDirectory. Resolve it through VYBE's
/// already-used native channel so a path_provider Java class-loading failure
/// cannot block cached logos, fanart, album covers, lyrics or downloads.
/// No artwork file is moved or invalidated.
class VybeAppStorage {
  VybeAppStorage._();

  static const MethodChannel _channel = MethodChannel('vybe/local_art');
  static Directory? _cached;

  static Future<Directory> supportDirectory() async {
    final cached = _cached;
    if (cached != null) return cached;
    if (Platform.isAndroid) {
      try {
        final path = await _channel.invokeMethod<String>('appSupportPath');
        if (path != null && path.isNotEmpty) {
          return _cached = Directory(path);
        }
      } on MissingPluginException {
        // The optional Drive Flutter engine can lack MainActivity's channel.
        // Use the normal path provider when its Android integration works.
      } on PlatformException {
        // Fall back rather than turning an Android storage-path error into
        // a permanent artwork failure. Native support is preferred above.
      }
    }
    return _cached = await getApplicationSupportDirectory();
  }
}
