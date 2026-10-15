import 'dart:convert';
import 'dart:io';

import 'adb_paths.dart';

class AdbDevice {
  AdbDevice({required this.serial, required this.state, this.model});

  final String serial;
  final String state;
  /// From `adb devices -l` (`model:...`), if present.
  final String? model;

  String get shortLabel {
    final m = model?.replaceAll('_', ' ').trim();
    if (m != null && m.isNotEmpty) return '$serial · $m';
    return serial;
  }
}

/// Result of an adb invocation with separate stdout/stderr and exit code.
class AdbCommandResult {
  AdbCommandResult({
    required this.exitCode,
    required this.stdout,
    required this.stderr,
  });

  final int exitCode;
  final String stdout;
  final String stderr;

  String get combinedOutput {
    final b = StringBuffer();
    if (stdout.trim().isNotEmpty) b.writeln(stdout.trim());
    if (stderr.trim().isNotEmpty) b.writeln(stderr.trim());
    return b.toString().trim();
  }

  /// `adb install` / `install-multiple` reports Failure or Success in output.
  bool get installSucceeded {
    final t = combinedOutput.toLowerCase();
    if (t.contains('failure')) return false;
    return exitCode == 0 && t.contains('success');
  }

  /// `adb uninstall` prints Success on success.
  bool get uninstallSucceeded {
    final t = combinedOutput.toLowerCase();
    if (exitCode != 0) return false;
    return t.contains('success');
  }
}

class AdbService {
  Future<String?> _adb() => AdbPaths.resolveAdbExecutable();

  static const _timeout = Duration(seconds: 25);

  Future<String> _run(
    List<String> args, {
    String? serial,
    Map<String, String>? environment,
  }) async {
    final r = await _runResult(args, serial: serial, environment: environment);
    return r.combinedOutput;
  }

  Future<AdbCommandResult> _runResult(
    List<String> args, {
    String? serial,
    Map<String, String>? environment,
  }) async {
    final adb = await _adb();
    if (adb == null) {
      throw StateError(
        'adb.exe not found. Copy Android platform-tools into the "adb" folder next to this app, then restart.',
      );
    }
    final full = <String>[if (serial != null) ...['-s', serial], ...args];
    final r = await Process.run(adb, full, environment: environment, runInShell: false).timeout(_timeout);
    return AdbCommandResult(
      exitCode: r.exitCode,
      stdout: r.stdout is String ? r.stdout as String : '',
      stderr: r.stderr is String ? r.stderr as String : '',
    );
  }

  Future<List<AdbDevice>> listDevices() async {
    final out = await _run(['devices', '-l']);
    final lines = const LineSplitter().convert(out);
    final list = <AdbDevice>[];
    for (final line in lines.skip(1)) {
      if (line.trim().isEmpty) continue;
      final parts = line.trim().split(RegExp(r'\s+'));
      if (parts.length >= 2) {
        final modelM = RegExp(r'model:(\S+)').firstMatch(line);
        list.add(AdbDevice(
          serial: parts.first,
          state: parts[1],
          model: modelM?.group(1),
        ));
      }
    }
    return list.where((d) => d.state == 'device').toList();
  }

  Future<Map<String, String>> deviceProps(String serial) async {
    Future<String> prop(String key) async {
      final o = await _run(['shell', 'getprop', key], serial: serial);
      return o.trim();
    }

    return {
      'model': await prop('ro.product.model'),
      'manufacturer': await prop('ro.product.manufacturer'),
      'brand': await prop('ro.product.brand'),
      'device': await prop('ro.product.device'),
      'android': await prop('ro.build.version.release'),
      'sdk': await prop('ro.build.version.sdk'),
    };
  }

  Future<bool> isPackageInstalled(String serial, String packageName) async {
    final o = await _run(['shell', 'pm', 'path', packageName], serial: serial);
    return o.contains('package:');
  }

  Future<String?> installedVersionName(String serial, String packageName) async {
    final out = await _run(['shell', 'dumpsys', 'package', packageName], serial: serial);
    final m = RegExp(r'versionName=([^\s\n\r]+)').firstMatch(out);
    return m?.group(1);
  }

  Future<AdbCommandResult> installApk({
    required String serial,
    required String apkPath,
    bool replace = true,
  }) async {
    final args = <String>['install', if (replace) '-r', apkPath];
    return _runResult(args, serial: serial);
  }

  /// Installs split bundles together (required for XAPK / multiple APKs).
  Future<AdbCommandResult> installMultiple({
    required String serial,
    required List<String> apkPaths,
    bool replace = true,
  }) async {
    if (apkPaths.isEmpty) throw ArgumentError('apkPaths empty');
    final args = <String>['install-multiple', if (replace) '-r', ...apkPaths];
    return _runResult(args, serial: serial);
  }

  Future<AdbCommandResult> uninstallUserApp(String serial, String packageName) async {
    return _runResult(['uninstall', packageName], serial: serial);
  }

  Future<List<String>> listUserPackages(String serial) async {
    final out = await _run(['shell', 'pm', 'list', 'packages', '-3'], serial: serial);
    final re = RegExp(r'^package:([^\s\r]+)');
    final list = <String>[];
    for (final line in const LineSplitter().convert(out)) {
      final m = re.firstMatch(line.trim());
      if (m != null) list.add(m.group(1)!);
    }
    list.sort();
    return list;
  }

  /// Device paths from `pm path` (without `package:` prefix).
  Future<List<String>> packageApkDevicePaths(String serial, String packageName) async {
    final out = await _run(['shell', 'pm', 'path', packageName], serial: serial);
    final paths = <String>[];
    for (final line in const LineSplitter().convert(out)) {
      final t = line.trim();
      if (t.startsWith('package:')) {
        paths.add(t.substring('package:'.length).trim());
      }
    }
    return paths;
  }

  /// Prefer `base.apk`, else first non-split path, else first entry.
  static String? pickBaseApkPath(List<String> paths) {
    if (paths.isEmpty) return null;
    final lower = paths.map((e) => e.toLowerCase()).toList();
    for (var i = 0; i < paths.length; i++) {
      if (lower[i].endsWith('base.apk')) return paths[i];
    }
    for (var i = 0; i < paths.length; i++) {
      if (!lower[i].contains('split_')) return paths[i];
    }
    return paths.first;
  }

  Future<String> pullFile({
    required String serial,
    required String devicePath,
    required String localPath,
  }) async {
    return _run(['pull', devicePath, localPath], serial: serial);
  }
}
