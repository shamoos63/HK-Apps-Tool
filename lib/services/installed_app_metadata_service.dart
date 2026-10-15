import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import 'aapt_service.dart';
import 'adb_service.dart';
import 'device_installed_app_display_cache.dart';

/// Pulls the base APK from the device and reads label + launcher icon via aapt.
class InstalledAppMetadataService {
  InstalledAppMetadataService(this._adb, this._aapt);

  final AdbService _adb;
  final AaptService _aapt;

  Future<({String label, Uint8List? icon})> loadDisplayInfo(String serial, String packageName) async {
    try {
      final disk = await DeviceInstalledAppDisplayCache.instance.tryGet(serial, packageName);
      if (disk != null) return disk;

      final paths = await _adb.packageApkDevicePaths(serial, packageName);
      final devicePath = AdbService.pickBaseApkPath(paths);
      if (devicePath == null || devicePath.isEmpty) {
        return (label: packageName, icon: null);
      }
      final tmp = await Directory.systemTemp.createTemp('adb_mgr_appmeta_');
      try {
        final localApk = p.join(tmp.path, 'pulled.apk');
        await _adb.pullFile(serial: serial, devicePath: devicePath, localPath: localApk);
        if (!File(localApk).existsSync()) {
          return (label: packageName, icon: null);
        }
        final badging = await _aapt.readBadging(localApk);
        final rawLabel = badging?.label?.trim();
        final label = (rawLabel != null && rawLabel.isNotEmpty) ? rawLabel : packageName;
        final icon = await _aapt.readLauncherIconBytes(localApk);
        await DeviceInstalledAppDisplayCache.instance.put(serial, packageName, label, icon);
        return (label: label, icon: icon);
      } finally {
        try {
          await tmp.delete(recursive: true);
        } catch (_) {}
      }
    } catch (_) {
      return (label: packageName, icon: null);
    }
  }
}
