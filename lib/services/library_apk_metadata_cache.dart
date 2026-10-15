import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:synchronized/synchronized.dart';

import 'aapt_service.dart';

class _LibraryCacheSnap {
  _LibraryCacheSnap({
    required this.isXapk,
    required this.badging,
    required this.title,
    required this.packageId,
    required this.localVersion,
    required this.iconName,
  });

  final bool isXapk;
  final ApkBadging? badging;
  final String title;
  final String? packageId;
  final String? localVersion;
  final String? iconName;
}

/// Disk cache for `aapt`/XAPK peek results so large library folders load quickly after the first scan.
class LibraryApkMetadataCache {
  LibraryApkMetadataCache._();

  static final LibraryApkMetadataCache instance = LibraryApkMetadataCache._();

  static const _indexName = 'index.json';
  static const _iconsDir = 'icons';

  final Lock _lock = Lock();

  Directory? _root;
  Map<String, Map<String, dynamic>>? _index;
  bool _dirty = false;
  Timer? _saveDebounce;

  String _normPath(File f) => p.normalize(f.absolute.path);

  Future<Directory> _rootDir() async {
    if (_root != null) return _root!;
    final base = await getApplicationSupportDirectory();
    _root = Directory(p.join(base.path, 'apk_library_metadata_cache'));
    if (!_root!.existsSync()) await _root!.create(recursive: true);
    final icons = Directory(p.join(_root!.path, _iconsDir));
    if (!icons.existsSync()) await icons.create(recursive: true);
    return _root!;
  }

  Future<void> _loadIndex() async {
    if (_index != null) return;
    final root = await _rootDir();
    final f = File(p.join(root.path, _indexName));
    if (!f.existsSync()) {
      _index = {};
      return;
    }
    try {
      final raw = json.decode(await f.readAsString()) as Map<String, dynamic>?;
      final items = <String, Map<String, dynamic>>{};
      if (raw != null && raw['items'] is List) {
        for (final e in raw['items'] as List) {
          if (e is! Map) continue;
          final m = Map<String, dynamic>.from(e);
          final k = (m['key'] as String?)?.toLowerCase();
          if (k != null && k.isNotEmpty) items[k] = m;
        }
      }
      _index = items;
    } catch (_) {
      _index = {};
    }
  }

  void _scheduleSave() {
    _saveDebounce?.cancel();
    _saveDebounce = Timer(const Duration(milliseconds: 500), () {
      Future<void>(() async => _flush());
    });
  }

  Future<void> _flush() async {
    await _lock.synchronized(() async {
      if (!_dirty || _index == null) return;
      _dirty = false;
      try {
        final root = await _rootDir();
        final f = File(p.join(root.path, _indexName));
        final body = json.encode({
          'v': 1,
          'items': _index!.values.toList(),
        });
        await f.writeAsString(body);
      } catch (_) {}
    });
  }

  String _iconFileName(String keyLower, int size, int modifiedMs) {
    final h = Object.hash(keyLower.hashCode, size, modifiedMs);
    return 'i_${h.toUnsigned(32).toRadixString(16)}.bin';
  }

  bool _pathsEqualIgnoringCase(String a, String b) =>
      p.normalize(a).toLowerCase() == p.normalize(b).toLowerCase();

  /// Returns true if [apply] was called with cached metadata (skip `aapt` run).
  Future<bool> tryHydrate({
    required File file,
    required void Function({
      required bool isXapk,
      required ApkBadging? badging,
      required String title,
      required String? packageId,
      required String? localVersion,
      required Uint8List? icon,
    }) apply,
  }) async {
    _LibraryCacheSnap? snap;
    await _lock.synchronized(() async {
      await _loadIndex();
      if (!file.existsSync()) return;
      final st = file.statSync();
      final keyLower = _normPath(file).toLowerCase();
      final rec = _index![keyLower];
      if (rec == null) return;
      if (rec['size'] != st.size || rec['modifiedMs'] != st.modified.millisecondsSinceEpoch) return;
      final diskPath = rec['path'] as String?;
      if (diskPath == null || !_pathsEqualIgnoringCase(diskPath, file.path)) return;
      final isXapk = rec['isXapk'] == true;
      ApkBadging? badging;
      final pkg = rec['packageId'] as String?;
      if (pkg != null && pkg.isNotEmpty) {
        badging = ApkBadging(
          packageName: pkg,
          versionName: rec['versionName'] as String?,
          versionCode: rec['versionCode'] as String?,
          label: rec['label'] as String?,
          iconZipPath: null,
        );
      }
      final title = (rec['title'] as String?) ?? p.basename(file.path);
      final localVersion = rec['localVersion'] as String?;
      final iconName = rec['icon'] as String?;
      snap = _LibraryCacheSnap(
        isXapk: isXapk,
        badging: badging,
        title: title,
        packageId: pkg,
        localVersion: localVersion,
        iconName: iconName,
      );
    });

    if (snap == null) return false;
    final _LibraryCacheSnap cached = snap!;

    Uint8List? icon;
    final iname = cached.iconName;
    if (iname != null && iname.isNotEmpty) {
      try {
        final root = await _rootDir();
        final ip = File(p.join(root.path, _iconsDir, iname));
        if (ip.existsSync()) {
          icon = await ip.readAsBytes();
        }
      } catch (_) {}
    }

    apply(
      isXapk: cached.isXapk,
      badging: cached.badging,
      title: cached.title,
      packageId: cached.packageId,
      localVersion: cached.localVersion,
      icon: icon,
    );
    return true;
  }

  Future<void> record({
    required File file,
    required bool isXapk,
    required ApkBadging? badging,
    required String title,
    required String? packageId,
    required String? localVersion,
    required Uint8List? icon,
  }) async {
    await _lock.synchronized(() async {
      if (!file.existsSync()) return;
      await _loadIndex();
      final root = await _rootDir();
      final st = file.statSync();
      final pathNorm = _normPath(file);
      final keyLower = pathNorm.toLowerCase();

      String? iconName;
      if (icon != null && icon.isNotEmpty) {
        iconName = _iconFileName(keyLower, st.size, st.modified.millisecondsSinceEpoch);
        try {
          await File(p.join(root.path, _iconsDir, iconName)).writeAsBytes(icon, flush: true);
        } catch (_) {
          iconName = null;
        }
      }

      final rec = <String, dynamic>{
        'key': keyLower,
        'path': pathNorm,
        'size': st.size,
        'modifiedMs': st.modified.millisecondsSinceEpoch,
        'isXapk': isXapk,
        'packageId': packageId ?? badging?.packageName,
        'title': title,
        'localVersion': localVersion ?? badging?.versionName,
        'label': badging?.label,
        'versionName': badging?.versionName,
        'versionCode': badging?.versionCode,
      };
      if (iconName != null) {
        rec['icon'] = iconName;
      }
      _index![keyLower] = rec;
      _dirty = true;
      _pruneStale();
      _scheduleSave();
    });
  }

  void _pruneStale() {
    if (_index == null) return;
    final removeKeys = <String>[];
    for (final e in _index!.entries) {
      final rec = e.value;
      final pathStr = rec['path'] as String?;
      if (pathStr == null || pathStr.isEmpty) {
        removeKeys.add(e.key);
        continue;
      }
      try {
        final f = File(pathStr);
        if (!f.existsSync()) {
          removeKeys.add(e.key);
          continue;
        }
        final st = f.statSync();
        if (rec['size'] != st.size || rec['modifiedMs'] != st.modified.millisecondsSinceEpoch) {
          removeKeys.add(e.key);
        }
      } catch (_) {
        removeKeys.add(e.key);
      }
    }
    final rootPath = _root?.path;
    for (final k in removeKeys) {
      final iconName = _index![k]?['icon'] as String?;
      _index!.remove(k);
      if (iconName != null && rootPath != null) {
        try {
          final ip = File(p.join(rootPath, _iconsDir, iconName));
          if (ip.existsSync()) ip.deleteSync();
        } catch (_) {}
      }
    }
    if (removeKeys.isNotEmpty) _dirty = true;
  }
}
