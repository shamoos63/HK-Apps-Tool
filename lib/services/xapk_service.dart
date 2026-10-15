import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;

import 'app_paths.dart';

class XapkPeek {
  XapkPeek({
    this.packageName,
    this.versionName,
    this.versionCode,
    this.sampleApkArchiveFile,
  });

  final String? packageName;
  final String? versionName;
  final String? versionCode;
  final ArchiveFile? sampleApkArchiveFile;
}

class XapkExtractResult {
  XapkExtractResult({required this.apkPaths, this.packageNameHint});

  final List<String> apkPaths;
  final String? packageNameHint;
}

class _ExtractScan {
  _ExtractScan({this.pkgHint, this.orderedNames, required this.apkPaths});

  final String? pkgHint;
  final List<String>? orderedNames;
  final List<String> apkPaths;
}

/// Expands APKPure-style XAPK archives to a temp directory and returns contained APK paths.
class XapkService {
  /// System `tar` (Windows ships bsdtar in System32 — reads ZIP/APK/XAPK reliably).
  /// The `archive` [ZipDecoder] throws [RangeError] on some legitimate store-downloaded XAPKs.
  static Future<ProcessResult> _runTarExtract(String archivePath, String destDir) async {
    if (Platform.isWindows) {
      final exe = p.join(
        Platform.environment['WINDIR'] ?? Platform.environment['SystemRoot'] ?? r'C:\Windows',
        'System32',
        'tar.exe',
      );
      if (!File(exe).existsSync()) {
        return ProcessResult(-1, 127, '', 'tar.exe not found at $exe');
      }
      return Process.run(exe, ['-xf', archivePath, '-C', destDir], runInShell: false);
    }
    return Process.run('tar', ['-xf', archivePath, '-C', destDir], runInShell: false);
  }

  /// Unpack Google Play-style `.apks` bundles that sometimes sit inside an XAPK.
  static Future<void> _unpackNestedApksBundles(Directory root) async {
    final bundles = root
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.toLowerCase().endsWith('.apks'))
        .toList();
    for (final b in bundles) {
      final outDir = Directory(p.join(b.parent.path, '${p.basename(b.path)}.extracted'));
      if (outDir.existsSync()) continue;
      await outDir.create(recursive: true);
      final pr = await _runTarExtract(b.path, outDir.path);
      if (pr.exitCode != 0) {
        try {
          if (outDir.existsSync()) await outDir.delete(recursive: true);
        } catch (_) {}
      }
    }
  }

  static Future<_ExtractScan> _scanExtractedFolderWithNested(Directory dir) async {
    await _unpackNestedApksBundles(dir);
    return _scanExtractedFolder(dir);
  }

  /// Walk [dir] after extraction; parse manifest for split order hint.
  static Future<_ExtractScan> _scanExtractedFolder(Directory dir) async {
    String? pkgHint;
    List<String>? orderedNames;
    for (final ent in dir.listSync(recursive: true)) {
      if (ent is! File) continue;
      if (p.basename(ent.path).toLowerCase() == 'manifest.json') {
        try {
          final map = json.decode(await ent.readAsString()) as Map<String, dynamic>;
          pkgHint = map['package_name'] as String? ?? map['package'] as String?;
          final split = map['split_apks'];
          if (split is List) {
            orderedNames = split.map((e) {
              if (e is String) return e;
              if (e is Map && e['file'] is String) return e['file'] as String;
              return null;
            }).whereType<String>().toList();
          }
        } catch (_) {}
      }
    }
    final all = Directory(dir.path)
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.toLowerCase().endsWith('.apk'))
        .map((f) => f.path)
        .toList();

    return _ExtractScan(pkgHint: pkgHint, orderedNames: orderedNames, apkPaths: all);
  }

  static XapkExtractResult _buildExtractResult(_ExtractScan scan) {
    final all = scan.apkPaths;
    final orderedNames = scan.orderedNames;
    final pkgHint = scan.pkgHint;
    if (orderedNames != null && orderedNames.isNotEmpty) {
      final byBase = {for (final fp in all) p.basename(fp): fp};
      final ordered = <String>[];
      for (final n in orderedNames) {
        final key = p.basename(n);
        final hit = byBase[key];
        if (hit != null) ordered.add(hit);
      }
      for (final fp in all) {
        if (!ordered.contains(fp)) ordered.add(fp);
      }
      return XapkExtractResult(apkPaths: ordered, packageNameHint: pkgHint);
    }
    final sorted = List<String>.from(all)..sort(_apkSortCompareStatic);
    return XapkExtractResult(apkPaths: sorted, packageNameHint: pkgHint);
  }

  static int _apkSortCompareStatic(String a, String b) {
    final ba = p.basename(a).toLowerCase();
    final bb = p.basename(b).toLowerCase();
    int score(String n) {
      if (n.startsWith('split_')) return 2;
      if (n.startsWith('config.')) return 1;
      return 0;
    }

    final sa = score(ba);
    final sb = score(bb);
    if (sa != sb) return sa.compareTo(sb);
    return ba.compareTo(bb);
  }

  static bool _bytesStartWithZipLocalHeader(List<int> head) =>
      head.length >= 4 && head[0] == 0x50 && head[1] == 0x4b && head[2] == 0x03 && head[3] == 0x04;

  static int _readU16le(List<int> b, int off) => b[off] | (b[off + 1] << 8);

  static int _readU32le(List<int> b, int off) =>
      (b[off] | (b[off + 1] << 8) | (b[off + 2] << 16) | (b[off + 3] << 24)) & 0xFFFFFFFF;

  /// True only for a real trailing EOCD: `PK\x05\x06`, comment length, and CD offset/size must fit the file.
  ///
  /// A bare `PK\x05\x06` match inside compressed bytes is a common false positive and makes the `archive`
  /// reader build a negative slice length (`RangeError`, e.g. value around -44k).
  static bool _tailHasPlausibleEocd(List<int> tail, int fileLen) {
    if (tail.length < 22 || fileLen < 22) return false;
    for (var i = tail.length - 22; i >= 0; i--) {
      if (tail[i] != 0x50 || tail[i + 1] != 0x4b || tail[i + 2] != 0x05 || tail[i + 3] != 0x06) {
        continue;
      }
      final commentLen = _readU16le(tail, i + 20);
      if (commentLen > 65535) continue;
      // EOCD + optional comment must consume the rest of this tail (which ends at file EOF).
      if (i + 22 + commentLen != tail.length) continue;

      final cdSize = _readU32le(tail, i + 12);
      final cdOffset = _readU32le(tail, i + 16);
      if (cdOffset == 0xFFFFFFFF || cdSize == 0xFFFFFFFF) {
        continue; // ZIP64 — let full [ZipDecoder] handle it
      }
      if (cdSize == 0) continue;
      if (cdOffset > fileLen) continue;
      if (cdSize > fileLen - cdOffset) continue;
      return true;
    }
    return false;
  }

  /// ZIP with no trailing comment: EOCD is exactly the last 22 bytes of the file.
  static Future<bool> _pkStartAndZeroCommentEocdAtEof(File f, int len) async {
    if (len < 22) return false;
    final raf = await f.open(mode: FileMode.read);
    try {
      await raf.setPosition(0);
      final h = await raf.read(4);
      if (!_bytesStartWithZipLocalHeader(h)) return false;
      await raf.setPosition(len - 22);
      final t = await raf.read(22);
      return t.length == 22 && t[0] == 0x50 && t[1] == 0x4b && t[2] == 0x05 && t[3] == 0x06;
    } finally {
      await raf.close();
    }
  }

  /// True if the file is a plausible APK / XAPK ZIP: local header at start and EOCD near the end.
  ///
  /// Some large store downloads parse poorly with [ZipDecoder] (empty list / exception) even though
  /// the payload is a valid ZIP; [adb install-multiple] and many tools accept them. We avoid loading
  /// the whole file into memory for this fast path.
  static Future<bool> fileLooksLikeOpenableZip(File f) async {
    final len = await f.length();
    if (len < 22) return false;

    var startsZipLocal = false;
    final raf = await f.open(mode: FileMode.read);
    try {
      await raf.setPosition(0);
      final head = await raf.read(4);
      startsZipLocal = _bytesStartWithZipLocalHeader(head);
      if (startsZipLocal && len > 4096) {
        const maxTail = 65557; // max ZIP comment (65535) + EOCD (22)
        final tailLen = len < maxTail ? len : maxTail;
        await raf.setPosition(len - tailLen);
        final tail = await raf.read(tailLen);
        if (_tailHasPlausibleEocd(tail, len)) {
          return true;
        }
      }
    } finally {
      await raf.close();
    }

    if (startsZipLocal && await _pkStartAndZeroCommentEocdAtEof(f, len)) {
      return true;
    }

    try {
      final bytes = await f.readAsBytes();
      final archive = ZipDecoder().decodeBytes(bytes);
      if (archive.isNotEmpty) return true;
    } on RangeError {
      // [archive] can mis-handle valid zips — fall through to structural checks.
    } catch (_) {
      // fall through
    }

    return startsZipLocal && await _pkStartAndZeroCommentEocdAtEof(f, len);
  }

  /// Reads [manifest.json] from an XAPK without extracting everything to disk.
  Future<XapkPeek> peek(String xapkPath) async {
    Archive? archive;
    try {
      final bytes = await File(xapkPath).readAsBytes();
      archive = ZipDecoder().decodeBytes(bytes);
      if (archive.isEmpty) archive = null;
    } on RangeError {
      archive = null;
    } catch (_) {
      archive = null;
    }
    if (archive != null) {
      String? pkg;
      String? vname;
      String? vcode;
      ArchiveFile? firstBaseApk;

      for (final f in archive) {
        if (!f.isFile) continue;
        if (p.basename(f.name).toLowerCase() == 'manifest.json') {
          try {
            final map = json.decode(utf8.decode(f.content as List<int>)) as Map<String, dynamic>;
            pkg ??= map['package_name'] as String? ?? map['package'] as String?;
            vname ??= map['version_name'] as String? ?? map['name'] as String?;
            vcode ??= map['version_code'] as String?;
          } catch (_) {}
        }
        if (f.name.toLowerCase().endsWith('.apk')) {
          final base = p.basename(f.name).toLowerCase();
          final isLikelyBase = base.startsWith('com.') && base.contains('.') && !base.startsWith('config.');
          if (firstBaseApk == null || isLikelyBase) {
            firstBaseApk = f;
            if (isLikelyBase) break;
          }
        }
      }

      return XapkPeek(
        packageName: pkg,
        versionName: vname,
        versionCode: vcode,
        sampleApkArchiveFile: firstBaseApk,
      );
    }

    return _peekViaSystemTar(xapkPath);
  }

  Future<XapkPeek> _peekViaSystemTar(String xapkPath) async {
    final peekDir = await Directory.systemTemp.createTemp('adb_xapk_peek_');
    try {
      final pr = await _runTarExtract(xapkPath, peekDir.path);
      if (pr.exitCode != 0) {
        throw FormatException(
          'Could not read this XAPK (built-in ZIP reader failed; '
          'system tar exited ${pr.exitCode}: ${pr.stderr}).',
        );
      }
      String? pkg;
      String? vname;
      String? vcode;
      for (final ent in peekDir.listSync(recursive: true)) {
        if (ent is! File) continue;
        if (p.basename(ent.path).toLowerCase() != 'manifest.json') continue;
        try {
          final map = json.decode(await ent.readAsString()) as Map<String, dynamic>;
          pkg ??= map['package_name'] as String? ?? map['package'] as String?;
          vname ??= map['version_name'] as String? ?? map['name'] as String?;
          vcode ??= map['version_code'] as String?;
        } catch (_) {}
      }
      return XapkPeek(
        packageName: pkg,
        versionName: vname,
        versionCode: vcode,
        sampleApkArchiveFile: null,
      );
    } finally {
      try {
        if (peekDir.existsSync()) await peekDir.delete(recursive: true);
      } catch (_) {}
    }
  }

  /// True if this file is a ZIP that contains XAPK-style [manifest.json] (sometimes saved as `.apk`).
  static Future<bool> zipLooksLikeXapkBundle(String path) async {
    if (!path.toLowerCase().endsWith('.apk')) return false;
    try {
      final bytes = await File(path).readAsBytes();
      if (bytes.length < 4 || bytes[0] != 0x50 || bytes[1] != 0x4b) return false;
      final z = ZipDecoder().decodeBytes(bytes);
      for (final f in z) {
        if (!f.isFile) continue;
        final bn = p.basename(f.name.replaceAll('\\', '/')).toLowerCase();
        if (bn == 'manifest.json') return true;
      }
      return false;
    } catch (_) {
      return false;
    }
  }

  /// Some stores ship a **multi-split ZIP** or **single wrapped APK** saved as `.apk`.
  /// Detect inner `*.apk` entries and extract to temp paths for `adb install-multiple`.
  Future<List<String>> apkPartsFromApkArchiveIfBundle(String apkPath) async {
    try {
      final bytes = await File(apkPath).readAsBytes();
      if (bytes.length < 4 || bytes[0] != 0x50 || bytes[1] != 0x4b) return [apkPath];
      final Archive archive;
      try {
        archive = ZipDecoder().decodeBytes(bytes);
      } catch (_) {
        return [apkPath];
      }
      final apkEntries = <ArchiveFile>[];
      for (final f in archive) {
        if (!f.isFile) continue;
        final norm = f.name.replaceAll('\\', '/');
        if (norm.contains('..')) continue;
        if (!p.basename(norm).toLowerCase().endsWith('.apk')) continue;
        apkEntries.add(f);
      }
      if (apkEntries.isEmpty) return [apkPath];

      final dir = await AppPaths.tempExtractDirectory();
      if (apkEntries.length == 1) {
        final inner = apkEntries.first;
        final innerBase = p.basename(inner.name.replaceAll('\\', '/'));
        final outerBase = p.basename(apkPath);
        if (innerBase.toLowerCase() == outerBase.toLowerCase()) return [apkPath];
        final safe = innerBase.replaceAll(RegExp(r'[<>:"|?*\\/]'), '_');
        final t = p.join(dir.path, safe.isEmpty ? 'base.apk' : safe);
        await File(t).writeAsBytes(inner.content as List<int>);
        return [t];
      }

      final paths = <String>[];
      for (final f in apkEntries) {
        final norm = f.name.replaceAll('\\', '/');
        final safe = p.basename(norm).replaceAll(RegExp(r'[<>:"|?*\\/]'), '_');
        final t = p.join(dir.path, safe.isEmpty ? 'part_${paths.length}.apk' : safe);
        await File(t).parent.create(recursive: true);
        await File(t).writeAsBytes(f.content as List<int>);
        paths.add(t);
      }
      paths.sort(_apkSortCompareStatic);
      return paths;
    } catch (_) {
      return [apkPath];
    }
  }

  /// Resolves adb install paths: XAPK / nested bundles / multi-apk ZIP saved as `.apk`.
  Future<List<String>> resolveAdbInstallParts(String path, {required bool useXapkPipeline}) async {
    final lower = path.toLowerCase();
    if (useXapkPipeline || lower.endsWith('.xapk')) {
      try {
        final r = await extractApks(path);
        if (r.apkPaths.isNotEmpty) return r.apkPaths;
      } catch (_) {
        /* try plain zip below */
      }
    }
    if (lower.endsWith('.apk')) {
      return apkPartsFromApkArchiveIfBundle(path);
    }
    return [path];
  }

  Future<XapkExtractResult> extractApks(String xapkPath) async {
    var dir = await AppPaths.tempExtractDirectory();
    final tarFirst = await _runTarExtract(xapkPath, dir.path);
    if (tarFirst.exitCode == 0) {
      final scan = await _scanExtractedFolderWithNested(dir);
      if (scan.apkPaths.isNotEmpty) {
        return _buildExtractResult(scan);
      }
    }

    dir = await AppPaths.tempExtractDirectory();
    try {
      final bytes = await File(xapkPath).readAsBytes();
      final archive = ZipDecoder().decodeBytes(bytes);
      for (final f in archive) {
        if (!f.isFile) continue;
        final normalized = f.name.replaceAll('\\', '/');
        if (normalized.contains('..')) continue;
        final target = p.join(dir.path, p.basename(normalized));
        await File(target).parent.create(recursive: true);
        await File(target).writeAsBytes(f.content as List<int>);
      }
      final scan = await _scanExtractedFolderWithNested(dir);
      if (scan.apkPaths.isEmpty) {
        throw StateError('No APK entries after ZIP decode.');
      }
      return _buildExtractResult(scan);
    } catch (_) {
      dir = await AppPaths.tempExtractDirectory();
      final retry = await _runTarExtract(xapkPath, dir.path);
      if (retry.exitCode != 0) {
        final err = '${retry.stderr}${retry.stdout}'.trim();
        throw FormatException(
          'Could not unpack this XAPK/APK. The built-in ZIP reader failed on this file '
          '(some store downloads use ZIP layouts it cannot parse). '
          'System tar also failed (exit ${retry.exitCode})${err.isEmpty ? '.' : ': $err'} '
          'Try downloading again or use APKCombo / Uptodown.',
        );
      }
      final scan2 = await _scanExtractedFolderWithNested(dir);
      if (scan2.apkPaths.isEmpty) {
        throw FormatException(
          'No .apk files found after unpacking (check for nested .apks bundles failed too). '
          'The download may be corrupt or use an unsupported layout — try downloading again or another store.',
        );
      }
      return _buildExtractResult(scan2);
    }
  }

  static bool looksLikeXapk(String path) => p.extension(path).toLowerCase() == '.xapk';
}
