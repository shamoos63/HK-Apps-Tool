import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

class AppPaths {
  AppPaths._();

  static const _prefsKeyCustomApkLibrary = 'apk_library_directory_path';

  /// Bumped whenever the library folder preference changes; listen to rebuild path UI.
  static final ValueNotifier<int> apkLibraryDirectoryListenable = ValueNotifier(0);

  static Directory? _apkDirMemo;
  static String? _apkDirMemoKey;

  static void _invalidateApkDirCache() {
    _apkDirMemo = null;
    _apkDirMemoKey = null;
  }

  static void _notifyApkLibraryChanged() {
    apkLibraryDirectoryListenable.value++;
  }

  /// Returns the persisted custom folder path, or null when using the app default.
  static Future<String?> customApkLibraryDirectoryPathOrNull() async {
    final prefs = await SharedPreferences.getInstance();
    final s = prefs.getString(_prefsKeyCustomApkLibrary)?.trim();
    if (s == null || s.isEmpty) return null;
    return s;
  }

  static Future<bool> isUsingCustomApkLibraryDirectory() async =>
      (await customApkLibraryDirectoryPathOrNull()) != null;

  /// Creates the folder when missing. Persists normalized absolute path.
  static Future<void> setCustomApkLibraryDirectory(String absoluteOrUserPath) async {
    final dir = Directory(p.normalize(absoluteOrUserPath.trim()));
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    final storePath = dir.absolute.path;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefsKeyCustomApkLibrary, storePath);
    _invalidateApkDirCache();
    _notifyApkLibraryChanged();
  }

  static Future<void> clearCustomApkLibraryDirectory() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_prefsKeyCustomApkLibrary);
    _invalidateApkDirCache();
    _notifyApkLibraryChanged();
  }

  static Future<Directory> apkDownloadDirectory() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_prefsKeyCustomApkLibrary)?.trim();
    final cacheKey = (raw == null || raw.isEmpty) ? '__default__' : raw;

    if (_apkDirMemo != null &&
        _apkDirMemoKey == cacheKey &&
        _apkDirMemo!.existsSync()) {
      return _apkDirMemo!;
    }

    late final Directory dir;
    if (raw != null && raw.isNotEmpty) {
      dir = Directory(raw);
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }
    } else {
      final base = await getApplicationSupportDirectory();
      dir = Directory(p.join(base.path, 'APKs'));
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }
    }

    _apkDirMemo = dir;
    _apkDirMemoKey = cacheKey;
    return dir;
  }

  /// Test / benchmark hook: when set, temp extraction folders are created here instead of app support.
  static Directory? debugTempRootOverride;

  static var _jobCounter = 0;

  static Future<Directory> _tempRoot() async {
    final override = debugTempRootOverride;
    if (override != null) return Directory(p.join(override.path, 'temp_xapk_jobs'));
    final base = await getApplicationSupportDirectory();
    return Directory(p.join(base.path, 'temp_xapk_jobs'));
  }

  /// A fresh, private folder for one install job. Each job gets its own folder so several
  /// XAPKs can be unpacked at the same time; the caller deletes it when the install finishes.
  static Future<Directory> newJobExtractDirectory() async {
    final root = await _tempRoot();
    final dir = Directory(
      p.join(root.path, 'job_${DateTime.now().microsecondsSinceEpoch}_${_jobCounter++}'),
    );
    await dir.create(recursive: true);
    return dir;
  }

  /// Removes leftovers from a previous run (crash, force-quit) plus the old shared `temp_xapk` folder.
  static Future<void> purgeStaleExtractDirectories() async {
    try {
      final root = await _tempRoot();
      if (await root.exists()) await root.delete(recursive: true);
      if (debugTempRootOverride == null) {
        final legacy = Directory(p.join((await getApplicationSupportDirectory()).path, 'temp_xapk'));
        if (await legacy.exists()) await legacy.delete(recursive: true);
      }
    } catch (_) {}
  }
}
