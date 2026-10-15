import 'dart:io';

import 'package:path/path.dart' as p;

/// Resolves the folder that contains [adb.exe] (Android platform-tools layout).
class AdbPaths {
  AdbPaths._();

  static String? _cachedAdbDir;
  static String? _cachedAdbExe;

  static void clearCache() {
    _cachedAdbDir = null;
    _cachedAdbExe = null;
  }

  static Future<String?> resolveAdbExecutable() async {
    if (_cachedAdbExe != null) return _cachedAdbExe;
    final dir = await resolveAdbDirectory();
    if (dir == null) return null;
    final exe = p.join(dir, 'adb.exe');
    if (File(exe).existsSync()) {
      _cachedAdbExe = exe;
      return exe;
    }
    return null;
  }

  static Future<String?> resolveAdbDirectory() async {
    if (_cachedAdbDir != null) return _cachedAdbDir;

    final candidates = <String>[
      p.join(p.dirname(Platform.resolvedExecutable), 'adb'),
      p.join(Directory.current.path, 'adb'),
      p.join(Directory.current.path, 'build', 'windows', 'x64', 'runner', 'Debug', 'adb'),
      p.join(Directory.current.path, 'build', 'windows', 'x64', 'runner', 'Release', 'adb'),
      p.join(Directory.current.path, 'build', 'windows', 'x64', 'runner', 'Profile', 'adb'),
    ];

    for (final c in candidates) {
      final adb = p.join(c, 'adb.exe');
      if (File(adb).existsSync()) {
        _cachedAdbDir = c;
        return c;
      }
    }

    // Fall back to PATH.
    final which = await Process.run('where', ['adb'], runInShell: true);
    if (which.exitCode == 0) {
      final line = (which.stdout as String).split('\n').firstWhere(
            (e) => e.trim().toLowerCase().endsWith('adb.exe'),
            orElse: () => '',
          );
      if (line.isNotEmpty) {
        final d = p.dirname(line.trim());
        _cachedAdbDir = d;
        return d;
      }
    }
    return null;
  }

  static Future<String?> resolveAaptExecutable() async {
    final dir = await resolveAdbDirectory();
    if (dir == null) return null;
    final aapt = p.join(dir, 'aapt.exe');
    if (File(aapt).existsSync()) return aapt;
    final aapt2 = p.join(dir, 'aapt2.exe');
    if (File(aapt2).existsSync()) return aapt2;
    return null;
  }
}
