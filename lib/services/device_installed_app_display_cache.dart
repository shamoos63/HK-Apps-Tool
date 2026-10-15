import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:synchronized/synchronized.dart';

/// Cached label + icon per [serial, packageId] under app support (skips slow `adb pull` on repeat visits).
class DeviceInstalledAppDisplayCache {
  DeviceInstalledAppDisplayCache._();

  static final DeviceInstalledAppDisplayCache instance = DeviceInstalledAppDisplayCache._();

  final Lock _lock = Lock();
  Directory? _root;

  String _safeSegment(String raw) {
    var s = raw.replaceAll(RegExp(r'[^\w\-.]'), '_');
    if (s.length > 96) s = s.substring(0, 96);
    return s.isEmpty ? '_' : s;
  }

  Future<Directory> _ensureRoot() async {
    if (_root != null) return _root!;
    final base = await getApplicationSupportDirectory();
    _root = Directory(p.join(base.path, 'device_installed_app_cache'));
    if (!_root!.existsSync()) await _root!.create(recursive: true);
    return _root!;
  }

  Future<Directory> _serialDir(String serial) async {
    final root = await _ensureRoot();
    final d = Directory(p.join(root.path, _safeSegment(serial)));
    if (!d.existsSync()) await d.create(recursive: true);
    return d;
  }

  Future<({String label, Uint8List? icon})?> tryGet(String serial, String packageName) async {
    return _lock.synchronized(() async {
      try {
        final dir = await _serialDir(serial);
        final key = _safeSegment(packageName);
        final metaFile = File(p.join(dir.path, '$key.json'));
        if (!metaFile.existsSync()) return null;
        final map = json.decode(await metaFile.readAsString()) as Map<String, dynamic>?;
        if (map == null) return null;
        final label = map['label'] as String?;
        if (label == null || label.isEmpty) return null;
        Uint8List? icon;
        final iconName = map['icon'] as String?;
        if (iconName != null && iconName.isNotEmpty) {
          final ip = File(p.join(dir.path, iconName));
          if (ip.existsSync()) {
            icon = await ip.readAsBytes();
          }
        }
        return (label: label, icon: icon);
      } catch (_) {
        return null;
      }
    });
  }

  Future<void> put(String serial, String packageName, String label, Uint8List? icon) async {
    await _lock.synchronized(() async {
      try {
        final dir = await _serialDir(serial);
        final key = _safeSegment(packageName);
        var iconRel = '';
        if (icon != null && icon.isNotEmpty) {
          iconRel = '${key}_icon.bin';
          await File(p.join(dir.path, iconRel)).writeAsBytes(icon, flush: true);
        }
        await File(p.join(dir.path, '$key.json')).writeAsString(
          json.encode({
            'package': packageName,
            'label': label,
            if (iconRel.isNotEmpty) 'icon': iconRel,
          }),
        );
      } catch (_) {}
    });
  }

  /// Deletes cache entries for this device that are not in [wantedPackages].
  Future<void> pruneToPackageSet(String serial, Set<String> wantedPackages) async {
    await _lock.synchronized(() async {
      try {
        final dir = await _serialDir(serial);
        final wantedSafe = wantedPackages.map(_safeSegment).toSet();
        for (final ent in dir.listSync()) {
          if (ent is! File) continue;
          final base = p.basename(ent.path);
          if (base.endsWith('_icon.bin')) continue;
          if (!base.endsWith('.json')) continue;
          final id = base.substring(0, base.length - 5);
          if (wantedSafe.contains(id)) continue;
          try {
            final raw = json.decode(await ent.readAsString()) as Map<String, dynamic>?;
            final iconRel = raw?['icon'] as String?;
            if (iconRel != null && iconRel.isNotEmpty) {
              final ib = File(p.join(dir.path, iconRel));
              if (ib.existsSync()) ib.deleteSync();
            }
          } catch (_) {}
          try {
            await ent.delete();
          } catch (_) {}
        }
      } catch (_) {}
    });
  }
}
