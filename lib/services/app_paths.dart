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

  static Future<Directory> tempExtractDirectory() async {
    final base = await getApplicationSupportDirectory();
    final dir = Directory(p.join(base.path, 'temp_xapk'));
    if (dir.existsSync()) {
      await dir.delete(recursive: true);
    }
    await dir.create(recursive: true);
    return dir;
  }
}
