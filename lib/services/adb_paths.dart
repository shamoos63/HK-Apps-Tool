import 'dart:io';

import 'package:path/path.dart' as p;

/// Resolves the folder that contains adb (Android platform-tools layout).
///
/// Windows builds ship `adb.exe` next to the app; macOS / Linux fall back to the Android SDK
/// (`ANDROID_HOME`, `~/Library/Android/sdk`, `~/Android/Sdk`) or whatever is on `PATH`.
class AdbPaths {
  AdbPaths._();

  static String? _cachedAdbDir;
  static String? _cachedAdbExe;

  static String _exe(String name) => Platform.isWindows ? '$name.exe' : name;

  static void clearCache() {
    _cachedAdbDir = null;
    _cachedAdbExe = null;
  }

  static Future<String?> resolveAdbExecutable() async {
    if (_cachedAdbExe != null) return _cachedAdbExe;
    final dir = await resolveAdbDirectory();
    if (dir == null) return null;
    final exe = p.join(dir, _exe('adb'));
    if (File(exe).existsSync()) {
      _cachedAdbExe = exe;
      return exe;
    }
    return null;
  }

  static List<String> _sdkRoots() {
    final env = Platform.environment;
    final home = env['HOME'] ?? env['USERPROFILE'];
    return [
      ?env['ANDROID_HOME'],
      ?env['ANDROID_SDK_ROOT'],
      if (home != null) ...[
        p.join(home, 'Library', 'Android', 'sdk'),
        p.join(home, 'Android', 'Sdk'),
      ],
      if (env['LOCALAPPDATA'] != null) p.join(env['LOCALAPPDATA']!, 'Android', 'Sdk'),
    ];
  }

  static Future<String?> resolveAdbDirectory() async {
    if (_cachedAdbDir != null) return _cachedAdbDir;

    final candidates = <String>[
      p.join(p.dirname(Platform.resolvedExecutable), 'adb'),
      p.join(Directory.current.path, 'adb'),
      p.join(Directory.current.path, 'build', 'windows', 'x64', 'runner', 'Debug', 'adb'),
      p.join(Directory.current.path, 'build', 'windows', 'x64', 'runner', 'Release', 'adb'),
      p.join(Directory.current.path, 'build', 'windows', 'x64', 'runner', 'Profile', 'adb'),
      for (final root in _sdkRoots()) p.join(root, 'platform-tools'),
    ];

    for (final c in candidates) {
      final adb = p.join(c, _exe('adb'));
      if (File(adb).existsSync()) {
        _cachedAdbDir = c;
        return c;
      }
    }

    // Fall back to PATH.
    try {
      final which = Platform.isWindows
          ? await Process.run('where', ['adb'], runInShell: true)
          : await Process.run('which', ['adb']);
      if (which.exitCode == 0) {
        final line = (which.stdout as String).split('\n').firstWhere(
              (e) => e.trim().toLowerCase().endsWith(_exe('adb')),
              orElse: () => '',
            );
        if (line.isNotEmpty) {
          final d = p.dirname(line.trim());
          _cachedAdbDir = d;
          return d;
        }
      }
    } catch (_) {}
    return null;
  }

  static Future<String?> resolveAaptExecutable() async {
    final dir = await resolveAdbDirectory();
    if (dir == null) return null;
    final dirs = <String>[dir];
    // SDK layout: aapt lives in build-tools/<version>/, next to platform-tools/.
    final buildTools = Directory(p.join(p.dirname(dir), 'build-tools'));
    if (buildTools.existsSync()) {
      final versions = buildTools.listSync().whereType<Directory>().map((d) => d.path).toList()
        ..sort((a, b) => b.compareTo(a));
      dirs.addAll(versions);
    }
    for (final d in dirs) {
      final aapt = p.join(d, _exe('aapt'));
      if (File(aapt).existsSync()) return aapt;
      final aapt2 = p.join(d, _exe('aapt2'));
      if (File(aapt2).existsSync()) return aapt2;
    }
    return null;
  }
}
