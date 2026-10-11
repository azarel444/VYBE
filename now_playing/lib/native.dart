import 'dart:ui' show Rect;

import 'package:flutter/services.dart';

/// Calls into the Kotlin side that do not need the now-playing stream:
/// permission checks, the list of players, and launching navigation.
class Native {
  static const _c = MethodChannel('nowplaying/control');

  static Future<Map<String, bool>> permissionStatus() async {
    try {
      final r = await _c.invokeMethod<Map<dynamic, dynamic>>('permissionStatus');
      return {
        'notification': r?['notification'] == true,
        'audio': r?['audio'] == true,
        'overlay': r?['overlay'] == true,
      };
    } catch (_) {
      return {'notification': false, 'audio': false, 'overlay': false};
    }
  }

  /// Starts the Drive overlay. Returns 'ok', 'permission' (draw-over-apps is
  /// off) or 'nolistener' (notification access is off).
  static Future<String> startDrive({
    required String pkg,
    required bool swap,
    required double centerFrac,
    required bool controls,
    required bool autoClose,
  }) async {
    try {
      return (await _c.invokeMethod<String>('startDrive', {
            'navPkg': pkg,
            'swap': swap,
            'center': centerFrac,
            'controls': controls,
            'autoClose': autoClose,
          })) ??
          'nolistener';
    } catch (_) {
      return 'nolistener';
    }
  }

  /// Opens the map app, then puts VYBE's see-through Drive window in front of
  /// it. Returns 'ok', 'permission', 'nopkg' or 'none'.
  static Future<String> startDriveScreen({required String pkg}) async {
    try {
      return (await _c.invokeMethod<String>('startDriveScreen', {'navPkg': pkg})) ??
          'none';
    } catch (_) {
      return 'none';
    }
  }

  /// Closes the Drive window and goes back to normal VYBE.
  static Future<void> exitDrive() => _fire('exitDrive');

  /// Sends the Drive window to the back so the map app can be touched.
  static Future<void> hideDrive() => _fire('hideDrive');

  static Future<void> stopDrive() => _fire('stopDrive');

  static Future<bool> driveRunning() async {
    try {
      return (await _c.invokeMethod<bool>('driveRunning')) == true;
    } catch (_) {
      return false;
    }
  }

  static Future<void> openAccessSettings() => _fire('openAccessSettings');
  static Future<void> openOverlaySettings() => _fire('openOverlaySettings');

  /// Shows Android's audio permission prompt; true if it was granted.
  static Future<bool> requestAudio() async {
    try {
      return (await _c.invokeMethod<bool>('requestAudio')) == true;
    } catch (_) {
      return false;
    }
  }

  /// Players VYBE has seen, each with its kind and whether it may open VYBE.
  static Future<List<PlayerInfo>> getPlayers() async {
    try {
      final r = await _c.invokeMethod<List<dynamic>>('getPlayers');
      return (r ?? const [])
          .map((e) => PlayerInfo.from(Map<String, dynamic>.from(e as Map)))
          .toList();
    } catch (_) {
      return [];
    }
  }

  /// [mode] is 'auto', 'allow' or 'block'.
  static Future<void> setPlayerOverride(String pkg, String mode) async {
    try {
      await _c.invokeMethod('setPlayerOverride', {'pkg': pkg, 'mode': mode});
    } catch (_) {}
  }

  /// Apps with a launcher icon, for choosing the navigation app.
  static Future<List<AppInfo>> getInstalledApps() async {
    try {
      final r = await _c.invokeMethod<List<dynamic>>('getInstalledApps');
      return (r ?? const []).map((e) {
        final m = Map<String, dynamic>.from(e as Map);
        return AppInfo(m['pkg'] as String? ?? '', m['label'] as String? ?? '');
      }).toList();
    } catch (_) {
      return [];
    }
  }

  /// Opens the navigation app. With [bounds] (in screen pixels) it asks
  /// Android for a window of that size. Returns 'ok' (window requested),
  /// 'full' (opened normally), 'nopkg' or 'none' (could not open).
  static Future<String> launchNavigation(String pkg, Rect? bounds) async {
    try {
      final args = <String, dynamic>{'pkg': pkg};
      if (bounds != null) {
        args['left'] = bounds.left.round();
        args['top'] = bounds.top.round();
        args['right'] = bounds.right.round();
        args['bottom'] = bounds.bottom.round();
      }
      return (await _c.invokeMethod<String>('launchNavigation', args)) ?? 'none';
    } catch (_) {
      return 'none';
    }
  }

  static Future<void> _fire(String m) async {
    try {
      await _c.invokeMethod(m);
    } catch (_) {}
  }
}

class PlayerInfo {
  final String pkg;
  final String label;
  final String kind; // MUSIC, VIDEO, NAV, OTHER
  final String override; // auto, allow, block
  final bool allowed;

  const PlayerInfo(this.pkg, this.label, this.kind, this.override, this.allowed);

  factory PlayerInfo.from(Map<String, dynamic> m) => PlayerInfo(
        m['pkg'] as String? ?? '',
        m['label'] as String? ?? '',
        m['kind'] as String? ?? 'OTHER',
        m['override'] as String? ?? 'auto',
        m['allowed'] == true,
      );

  String get kindLabel {
    switch (kind) {
      case 'MUSIC':
        return 'Music player';
      case 'VIDEO':
        return 'Video app';
      case 'NAV':
        return 'Navigation';
      default:
        return 'Unknown type';
    }
  }
}

class AppInfo {
  final String pkg;
  final String label;
  const AppInfo(this.pkg, this.label);
}
