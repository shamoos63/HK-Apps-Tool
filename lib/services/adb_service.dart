import 'dart:async';
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

/// The device or adb build cannot do session streaming; use a classic `adb install` instead.
class AdbStreamingUnsupported implements Exception {
  AdbStreamingUnsupported(this.message);
  final String message;
  @override
  String toString() => 'Streaming install unsupported: $message';
}

class AdbService {
  Future<String?> _adb() => AdbPaths.resolveAdbExecutable();

  static const _timeout = Duration(seconds: 25);

  /// Installs and OBB copies of multi-GB games can take many minutes over USB 2.
  static const installTimeout = Duration(minutes: 45);

  static final _sdkBySerial = <String, int?>{};

  Future<String> _run(
    List<String> args, {
    String? serial,
    Map<String, String>? environment,
  }) async {
    final r = await _runResult(args, serial: serial, environment: environment);
    return r.combinedOutput;
  }

  Future<String> _requireAdb() async {
    final adb = await _adb();
    if (adb == null) {
      throw StateError(
        'adb not found. Copy Android platform-tools into the "adb" folder next to this app, then restart.',
      );
    }
    return adb;
  }

  Future<AdbCommandResult> _runResult(
    List<String> args, {
    String? serial,
    Map<String, String>? environment,
    Duration timeout = _timeout,
  }) async {
    final adb = await _requireAdb();
    final full = <String>[if (serial != null) ...['-s', serial], ...args];
    final r = await Process.run(adb, full, environment: environment, runInShell: false).timeout(timeout);
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
    return _runResult(args, serial: serial, timeout: installTimeout);
  }

  /// Installs split bundles together (required for XAPK / multiple APKs).
  Future<AdbCommandResult> installMultiple({
    required String serial,
    required List<String> apkPaths,
    bool replace = true,
  }) async {
    if (apkPaths.isEmpty) throw ArgumentError('apkPaths empty');
    final args = <String>['install-multiple', if (replace) '-r', ...apkPaths];
    return _runResult(args, serial: serial, timeout: installTimeout);
  }

  /// `ro.build.version.sdk`, cached per device for this run.
  Future<int?> deviceSdk(String serial) async {
    if (_sdkBySerial.containsKey(serial)) return _sdkBySerial[serial];
    int? sdk;
    try {
      sdk = int.tryParse((await _run(['shell', 'getprop', 'ro.build.version.sdk'], serial: serial)).trim());
    } catch (_) {}
    _sdkBySerial[serial] = sdk;
    return sdk;
  }

  static final _safeShellArg = RegExp(r'^[A-Za-z0-9._/+=@-]+$');

  /// Runs `adb exec-in <command>` feeding [data] to the device command's stdin.
  /// Returns combined stdout/stderr; [onBytes] reports bytes as they are handed to adb.
  Future<AdbCommandResult> _execIn(
    String serial,
    String command,
    Stream<List<int>> data, {
    void Function(int delta)? onBytes,
  }) async {
    final adb = await _requireAdb();
    final proc = await Process.start(adb, ['-s', serial, 'exec-in', command]);
    final out = proc.stdout.transform(const SystemEncoding().decoder).join();
    final err = proc.stderr.transform(const SystemEncoding().decoder).join();
    try {
      await proc.stdin.addStream(onBytes == null
          ? data
          : data.map((c) {
              onBytes(c.length);
              return c;
            }));
    } catch (_) {
      // adb exited early (e.g. device rejected the command); the exit code below explains why.
    }
    try {
      await proc.stdin.close();
    } catch (_) {}
    final code = await proc.exitCode.timeout(installTimeout, onTimeout: () {
      proc.kill();
      return -1;
    });
    return AdbCommandResult(exitCode: code, stdout: await out, stderr: await err);
  }

  /// Installs [parts] by streaming each one straight into a PackageManager session
  /// (`install-create` → `install-write … -` → `install-commit`), the same protocol
  /// `adb install-multiple` uses, but fed from memory so nothing has to be unpacked to disk first.
  ///
  /// Throws [AdbStreamingUnsupported] when the device/adb refuses the streaming protocol before any
  /// data was committed, so the caller can fall back to a classic install.
  Future<AdbCommandResult> streamInstall({
    required String serial,
    required List<({String name, int size, Future<Stream<List<int>>> Function() open})> parts,
    bool replace = true,
    void Function(int delta)? onBytes,
  }) async {
    if (parts.isEmpty) throw ArgumentError('parts empty');
    final sdk = await deviceSdk(serial);
    if (sdk != null && sdk < 21) throw AdbStreamingUnsupported('Android API $sdk has no install sessions');
    final pm = (sdk ?? 0) >= 24 ? 'cmd package' : 'pm';
    final total = parts.fold<int>(0, (a, b) => a + b.size);

    final create = await _runResult(
      ['shell', '$pm install-create${replace ? ' -r' : ''} -S $total'],
      serial: serial,
    );
    final sessionM = RegExp(r'\[(\d+)\]').firstMatch(create.combinedOutput);
    if (sessionM == null) {
      throw AdbStreamingUnsupported('install-create: ${create.combinedOutput}');
    }
    final session = sessionM.group(1)!;
    var ok = false;
    try {
      for (var i = 0; i < parts.length; i++) {
        final part = parts[i];
        var name = '${i}_${part.name}'.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
        if (!_safeShellArg.hasMatch(name)) name = '$i.apk';
        final w = await _execIn(
          serial,
          '$pm install-write -S ${part.size} $session $name -',
          await part.open(),
          onBytes: onBytes,
        );
        if (!w.combinedOutput.toLowerCase().contains('success')) {
          if (i == 0 && w.combinedOutput.trim().isEmpty) {
            throw AdbStreamingUnsupported('install-write produced no output (exit ${w.exitCode})');
          }
          return AdbCommandResult(
            exitCode: w.exitCode == 0 ? 1 : w.exitCode,
            stdout: 'Failure [install-write ${part.name}] ${w.stdout}',
            stderr: w.stderr,
          );
        }
      }
      final commit = await _runResult(
        ['shell', '$pm install-commit $session'],
        serial: serial,
        timeout: installTimeout,
      );
      ok = commit.installSucceeded;
      return commit;
    } finally {
      if (!ok) {
        try {
          await _runResult(['shell', '$pm install-abandon $session'], serial: serial);
        } catch (_) {}
      }
    }
  }

  /// Streams [data] to [devicePath] (e.g. an OBB under `/sdcard/Android/obb/`) without a temp file.
  Future<AdbCommandResult> pushStream({
    required String serial,
    required String devicePath,
    required int size,
    required Stream<List<int>> data,
    void Function(int delta)? onBytes,
  }) async {
    if (!_safeShellArg.hasMatch(devicePath)) {
      throw ArgumentError('Unsafe device path: $devicePath');
    }
    final dir = devicePath.substring(0, devicePath.lastIndexOf('/'));
    final w = await _execIn(
      serial,
      "sh -c 'mkdir -p $dir && cat > $devicePath.part && mv $devicePath.part $devicePath && (stat -c %s $devicePath 2>/dev/null || wc -c < $devicePath)'",
      data,
      onBytes: onBytes,
    );
    final written = int.tryParse(w.stdout.trim().split(RegExp(r'\s+')).last);
    if (written != size) {
      return AdbCommandResult(
        exitCode: w.exitCode == 0 ? 1 : w.exitCode,
        stdout: 'Failure copying ${devicePath.split('/').last} (got ${written ?? '?'} of $size bytes)',
        stderr: w.stderr,
      );
    }
    return AdbCommandResult(exitCode: 0, stdout: 'Success', stderr: '');
  }

  /// `versionName` for each of [packages] in a single adb round-trip (null = not installed).
  ///
  /// Replaces one `pm path` + one `dumpsys` call per library row.
  Future<Map<String, String?>> installedVersionNames(String serial, Iterable<String> packages) async {
    final valid = packages.where((p) => RegExp(r'^[A-Za-z0-9_.]+$').hasMatch(p)).toSet().toList();
    final result = <String, String?>{for (final p in valid) p: null};
    const chunk = 60;
    for (var i = 0; i < valid.length; i += chunk) {
      final slice = valid.sublist(i, i + chunk > valid.length ? valid.length : i + chunk);
      final script = 'for p in ${slice.join(' ')}; do echo "@@\$p"; '
          'dumpsys package \$p | grep -m1 versionName=; done';
      final out = await _run(['shell', script], serial: serial);
      String? current;
      for (final line in const LineSplitter().convert(out)) {
        final t = line.trim();
        if (t.startsWith('@@')) {
          current = t.substring(2);
          continue;
        }
        if (current == null) continue;
        final m = RegExp(r'versionName=([^\s]+)').firstMatch(t);
        if (m != null && result[current] == null) result[current] = m.group(1);
      }
    }
    return result;
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
