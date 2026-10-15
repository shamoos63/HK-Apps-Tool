import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;

import 'app_paths.dart';
import 'zip_index.dart';

class XapkPeek {
  XapkPeek({
    this.packageName,
    this.versionName,
    this.versionCode,
    this.sampleApkEntry,
    this.zip,
  });

  final String? packageName;
  final String? versionName;
  final String? versionCode;

  /// Base APK inside the XAPK (read it with [zip]) — used for badging and the launcher icon.
  final ZipEntry? sampleApkEntry;
  final ZipIndex? zip;
}

class XapkExtractResult {
  XapkExtractResult({required this.apkPaths, this.packageNameHint});

  final List<String> apkPaths;
  final String? packageNameHint;
}

/// One APK (base or split) to send to the device.
class InstallPart {
  InstallPart.localFile(String this.localPath, this.size)
      : zip = null,
        entry = null,
        name = p.basename(localPath);

  InstallPart.zipEntry(ZipIndex this.zip, ZipEntry this.entry)
      : localPath = null,
        size = entry.uncompressedSize,
        name = entry.baseName;

  final String name;
  final int size;
  final String? localPath;
  final ZipIndex? zip;
  final ZipEntry? entry;

  Future<Stream<List<int>>> open() async {
    if (localPath != null) return File(localPath!).openRead();
    return zip!.openEntry(entry!);
  }
}

/// OBB expansion file shipped inside an XAPK (copied to `/sdcard/Android/obb/...`).
class ObbPart {
  ObbPart(this.zip, this.entry, this.devicePath);

  final ZipIndex zip;
  final ZipEntry entry;
  final String devicePath;

  int get size => entry.uncompressedSize;
}

/// What to install for one library file: either entries streamed straight out of the archive,
/// or files on disk (plain APK, or the unpacked fallback for odd archives).
class InstallPlan {
  InstallPlan({
    required this.sourcePath,
    required this.parts,
    this.obbs = const [],
    this.packageName,
    this.workDir,
  });

  final String sourcePath;
  final List<InstallPart> parts;
  final List<ObbPart> obbs;
  final String? packageName;

  /// Temp folder owned by this plan (only when the archive had to be unpacked).
  final Directory? workDir;

  bool get isSplit => parts.length > 1;
  int get apkBytes => parts.fold(0, (a, b) => a + b.size);
  int get obbBytes => obbs.fold(0, (a, b) => a + b.size);

  /// Paths usable by plain `adb install` / `install-multiple`. Archive entries are copied into a
  /// private temp folder on first use (fallback path only — the fast path never touches disk).
  /// Shared by every device installing this plan, so it is unpacked at most once.
  Future<List<String>> materialize() => _materializing ??= _materialize();

  Future<List<String>>? _materializing;

  Future<List<String>> _materialize() async {
    if (parts.every((x) => x.localPath != null)) return [for (final x in parts) x.localPath!];
    final dir = _materializedDir = await AppPaths.newJobExtractDirectory();
    final out = <String>[];
    final used = <String>{};
    for (final part in parts) {
      if (part.localPath != null) {
        out.add(part.localPath!);
        continue;
      }
      var name = part.name.replaceAll(RegExp(r'[<>:"|?*\\/]'), '_');
      if (name.isEmpty || !used.add(name.toLowerCase())) {
        name = '${out.length}_${name.isEmpty ? 'part.apk' : name}';
        used.add(name.toLowerCase());
      }
      final dest = p.join(dir.path, name);
      await part.zip!.extractTo(part.entry!, dest);
      out.add(dest);
    }
    return out;
  }

  Directory? _materializedDir;

  Future<void> dispose() async {
    for (final d in [workDir, _materializedDir]) {
      if (d == null) continue;
      try {
        if (await d.exists()) await d.delete(recursive: true);
      } catch (_) {}
    }
  }
}

class _ExtractScan {
  _ExtractScan({this.pkgHint, this.orderedNames, required this.apkPaths});

  final String? pkgHint;
  final List<String>? orderedNames;
  final List<String> apkPaths;
}

class _Manifest {
  _Manifest({this.packageName, this.versionName, this.versionCode, this.splitOrder, this.expansions});

  final String? packageName;
  final String? versionName;
  final String? versionCode;
  final List<String>? splitOrder;

  /// archive entry name → device-relative install path.
  final Map<String, String>? expansions;

  static _Manifest? parse(List<int> bytes) {
    try {
      final map = json.decode(utf8.decode(bytes, allowMalformed: true)) as Map<String, dynamic>;
      final split = map['split_apks'];
      final exp = map['expansions'];
      final expansions = <String, String>{};
      if (exp is List) {
        for (final e in exp) {
          if (e is Map && e['file'] is String) {
            final file = (e['file'] as String).replaceAll('\\', '/');
            final dest = (e['install_path'] as String?)?.replaceAll('\\', '/') ?? file;
            expansions[file] = dest;
          }
        }
      }
      return _Manifest(
        packageName: map['package_name'] as String? ?? map['package'] as String?,
        versionName: map['version_name'] as String? ?? map['name'] as String?,
        versionCode: map['version_code']?.toString(),
        splitOrder: split is List
            ? split
                .map((e) {
                  if (e is String) return e;
                  if (e is Map && e['file'] is String) return e['file'] as String;
                  return null;
                })
                .whereType<String>()
                .toList()
            : null,
        expansions: expansions.isEmpty ? null : expansions,
      );
    } catch (_) {
      return null;
    }
  }
}

/// Reads APKPure-style XAPK archives and plans how to install them.
///
/// Fast path: list the ZIP central directory and stream each split APK straight out of the
/// archive to the device — nothing is unpacked to disk and OBB data is never touched unless asked.
/// Slow path (archives the streaming reader cannot parse): unpack with system `tar` like before,
/// but into a private per-job folder so several installs can run at the same time.
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
    final all = <String>[];
    for (final ent in dir.listSync(recursive: true)) {
      if (ent is! File) continue;
      final lower = ent.path.toLowerCase();
      if (lower.endsWith('.apk')) all.add(ent.path);
      if (p.basename(lower) == 'manifest.json') {
        final m = _Manifest.parse(await ent.readAsBytes());
        if (m != null) {
          pkgHint = m.packageName;
          orderedNames = m.splitOrder;
        }
      }
    }
    return _ExtractScan(pkgHint: pkgHint, orderedNames: orderedNames, apkPaths: all);
  }

  static List<T> _orderParts<T>(List<T> all, String Function(T) baseNameOf, List<String>? orderedNames) {
    if (orderedNames != null && orderedNames.isNotEmpty) {
      final byBase = {for (final x in all) baseNameOf(x): x};
      final ordered = <T>[];
      for (final n in orderedNames) {
        final hit = byBase[p.basename(n)];
        if (hit != null && !ordered.contains(hit)) ordered.add(hit);
      }
      for (final x in all) {
        if (!ordered.contains(x)) ordered.add(x);
      }
      return ordered;
    }
    return List<T>.from(all)..sort((a, b) => _apkSortCompareStatic(baseNameOf(a), baseNameOf(b)));
  }

  static XapkExtractResult _buildExtractResult(_ExtractScan scan) {
    return XapkExtractResult(
      apkPaths: _orderParts<String>(scan.apkPaths, p.basename, scan.orderedNames),
      packageNameHint: scan.pkgHint,
    );
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
    if (startsZipLocal && await ZipIndex.tryOpen(f.path) != null) {
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

  static bool _isSafeEntry(ZipEntry e) => !e.isDirectory && !e.name.split('/').contains('..');

  static ZipEntry? _manifestEntry(ZipIndex z) =>
      z.find((e) => !e.isDirectory && e.baseName.toLowerCase() == 'manifest.json');

  static Future<_Manifest?> _readManifest(ZipIndex z) async {
    final m = _manifestEntry(z);
    if (m == null || m.uncompressedSize > 4 * 1024 * 1024) return null;
    try {
      return _Manifest.parse(await z.readBytes(m));
    } catch (_) {
      return null;
    }
  }

  static ZipEntry? _pickBaseApk(Iterable<ZipEntry> apks, String? pkg) {
    ZipEntry? first;
    for (final e in apks) {
      final base = e.baseName.toLowerCase();
      if (pkg != null && base == '${pkg.toLowerCase()}.apk') return e;
      if (base == 'base.apk') return e;
      if (base.startsWith('com.') && !base.startsWith('config.') && !base.startsWith('split_')) return e;
      if (!base.startsWith('config.') && !base.startsWith('split_')) first ??= e;
    }
    return first ?? (apks.isEmpty ? null : apks.first);
  }

  /// Reads [manifest.json] (and locates the base APK) by listing the ZIP central directory only.
  Future<XapkPeek> peek(String xapkPath) async {
    final z = await ZipIndex.tryOpen(xapkPath);
    if (z != null) {
      final m = await _readManifest(z);
      final apks = z.entries.where((e) => _isSafeEntry(e) && e.lowerName.endsWith('.apk'));
      return XapkPeek(
        packageName: m?.packageName,
        versionName: m?.versionName,
        versionCode: m?.versionCode,
        sampleApkEntry: _pickBaseApk(apks, m?.packageName),
        zip: z,
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
        final m = _Manifest.parse(await ent.readAsBytes());
        pkg ??= m?.packageName;
        vname ??= m?.versionName;
        vcode ??= m?.versionCode;
      }
      return XapkPeek(packageName: pkg, versionName: vname, versionCode: vcode);
    } finally {
      try {
        if (peekDir.existsSync()) await peekDir.delete(recursive: true);
      } catch (_) {}
    }
  }

  /// True if this file is a ZIP that contains XAPK-style [manifest.json] (sometimes saved as `.apk`).
  static Future<bool> zipLooksLikeXapkBundle(String path) async {
    if (!path.toLowerCase().endsWith('.apk')) return false;
    final z = await ZipIndex.tryOpen(path);
    return z != null && _manifestEntry(z) != null;
  }

  /// Works out what to send to the device for [path] (APK, XAPK, or a split ZIP saved as `.apk`).
  ///
  /// [includeObb] also lists OBB expansion files so the caller can copy them to the device.
  Future<InstallPlan> planInstall(String path, {bool includeObb = false}) async {
    final z = await ZipIndex.tryOpen(path);
    if (z == null) {
      if (looksLikeXapk(path)) return _planByUnpacking(path);
      return InstallPlan(sourcePath: path, parts: [InstallPart.localFile(path, await File(path).length())]);
    }

    // A real APK has AndroidManifest.xml at its root — install it as-is, even if it embeds other APKs.
    final isPlainApk = z.entries.any((e) => e.name == 'AndroidManifest.xml');
    if (isPlainApk) {
      return InstallPlan(sourcePath: path, parts: [InstallPart.localFile(path, z.length)]);
    }

    final apkEntries =
        z.entries.where((e) => _isSafeEntry(e) && e.lowerName.endsWith('.apk')).toList();
    final hasNestedApks = z.entries.any((e) => _isSafeEntry(e) && e.lowerName.endsWith('.apks'));
    final streamable = apkEntries.every((e) => !e.isEncrypted && (e.method == 0 || e.method == 8));
    if (apkEntries.isEmpty || !streamable) {
      if (hasNestedApks || looksLikeXapk(path) || apkEntries.isNotEmpty) return _planByUnpacking(path);
      return InstallPlan(sourcePath: path, parts: [InstallPart.localFile(path, z.length)]);
    }

    final m = await _readManifest(z);
    final ordered = _orderParts<ZipEntry>(apkEntries, (e) => e.baseName, m?.splitOrder);
    final obbs = <ObbPart>[];
    if (includeObb) {
      for (final e in z.entries) {
        if (!_isSafeEntry(e)) continue;
        final mapped = m?.expansions?[e.name];
        final isObbPath = e.lowerName.startsWith('android/obb/') && e.lowerName.endsWith('.obb');
        if (mapped == null && !isObbPath) continue;
        final rel = (mapped ?? e.name).replaceFirst(RegExp(r'^/+'), '');
        if (rel.split('/').contains('..')) continue;
        obbs.add(ObbPart(z, e, '/sdcard/$rel'));
      }
    }
    return InstallPlan(
      sourcePath: path,
      parts: [for (final e in ordered) InstallPart.zipEntry(z, e)],
      obbs: obbs,
      packageName: m?.packageName,
    );
  }

  Future<InstallPlan> _planByUnpacking(String path) async {
    final dir = await AppPaths.newJobExtractDirectory();
    try {
      final r = await _extractInto(path, dir);
      final parts = <InstallPart>[
        for (final f in r.apkPaths) InstallPart.localFile(f, await File(f).length()),
      ];
      return InstallPlan(sourcePath: path, parts: parts, packageName: r.packageNameHint, workDir: dir);
    } catch (_) {
      try {
        await dir.delete(recursive: true);
      } catch (_) {}
      rethrow;
    }
  }

  /// Unpacks every APK from an XAPK into a new private temp folder (legacy / fallback path).
  Future<XapkExtractResult> extractApks(String xapkPath) async {
    return _extractInto(xapkPath, await AppPaths.newJobExtractDirectory());
  }

  Future<XapkExtractResult> _extractInto(String xapkPath, Directory dir) async {
    Future<void> reset() async {
      if (await dir.exists()) await dir.delete(recursive: true);
      await dir.create(recursive: true);
    }

    final tarFirst = await _runTarExtract(xapkPath, dir.path);
    if (tarFirst.exitCode == 0) {
      final scan = await _scanExtractedFolderWithNested(dir);
      if (scan.apkPaths.isNotEmpty) {
        return _buildExtractResult(scan);
      }
    }

    await reset();
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
      await reset();
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
