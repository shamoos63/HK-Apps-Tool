import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;

import 'adb_paths.dart';
import 'zip_index.dart';

class ApkBadging {
  ApkBadging({
    required this.packageName,
    this.versionName,
    this.versionCode,
    this.label,
    this.iconZipPath,
  });

  final String packageName;
  final String? versionCode;
  final String? versionName;
  /// Best-effort resolved display name (`application-label*:` / `application: label=` from `aapt dump badging`).
  final String? label;
  final String? iconZipPath;
}

class AaptService {
  /// Picks one human-readable string from full `aapt dump badging` stdout (localized lines included).
  static String? extractBestApplicationLabel(String badgingStdout) {
    final byLocale = <String, String>{};
    final re = RegExp(
      r"application-label(-[a-zA-Z0-9-]+)?\s*:\s*'((?:[^'\\]|\\.)*)'",
    );
    for (final m in re.allMatches(badgingStdout)) {
      final locRaw = m.group(1);
      final loc = (locRaw == null) ? '' : locRaw.replaceFirst(RegExp(r'^-'), '');
      final raw = m.group(2);
      if (raw == null) continue;
      final v = raw.replaceAll(r"\'", "'").trim();
      if (v.isEmpty) continue;
      if (v.startsWith('@')) continue;
      byLocale.putIfAbsent(loc, () => v);
    }

    if (byLocale.isNotEmpty) {
      const priority = <String>['', 'en-US', 'en-rUS', 'en-GB', 'en'];
      for (final k in priority) {
        final found = byLocale[k];
        if (found != null && found.isNotEmpty) return found;
      }
      for (final e in byLocale.entries) {
        if (e.key.toLowerCase().startsWith('en')) return e.value;
      }
      return byLocale[''] ?? byLocale.values.first;
    }

    final appLine = RegExp(r"application:\s*label='((?:[^'\\]|\\.)*)'").firstMatch(badgingStdout) ??
        RegExp(r'application:\s*label="((?:[^"\\]|\\.)*)"').firstMatch(badgingStdout);
    if (appLine != null) {
      final v = appLine.group(1)!.replaceAll(r"\'", "'").trim();
      if (v.isNotEmpty && !v.startsWith('@')) return v;
    }
    return null;
  }

  /// Safe base name for `.apk` / `.xapk` under Windows and Unix (no path separators).
  static String sanitizeFileStem(String displayLabelOrTitle) {
    var s = displayLabelOrTitle.replaceAll(RegExp(r'[\x00-\x1f]'), ' ').trim();
    if (s.isEmpty) return '';
    s = s.replaceAll(RegExp(r'[<>:"/\\|?*]'), '_');
    s = s.replaceAll(RegExp(r'\s+'), ' ').trim();
    s = s.replaceAll(RegExp(r'\.+$'), '');
    const maxLen = 120;
    if (s.length > maxLen) {
      s = s.substring(0, maxLen).trimRight();
    }
    return s.trim().isEmpty ? '' : s;
  }

  Future<ApkBadging?> readBadging(String apkPath) async {
    final aapt = await AdbPaths.resolveAaptExecutable();
    if (aapt == null) return null;
    final r = await Process.run(aapt, ['dump', 'badging', apkPath]);
    if (r.exitCode != 0) return null;
    final out = r.stdout as String;
    final nameM = RegExp(r"package: name='([^']+)'").firstMatch(out);
    if (nameM == null) return null;
    final name = nameM.group(1)!;
    final vcode = RegExp(r"versionCode='([^']*)'").firstMatch(out)?.group(1);
    final vname = RegExp(r"versionName='([^']*)'").firstMatch(out)?.group(1);
    final label = extractBestApplicationLabel(out);
    final iconFromDpi = _bestApplicationIconDpi(out);
    final iconLegacy = RegExp(r"application: label='[^']*' icon='([^']+)'").firstMatch(out) ??
        RegExp(r"application: icon='([^']+)'").firstMatch(out);
    final iconZipPath = iconFromDpi ?? iconLegacy?.group(1);
    return ApkBadging(
      packageName: name,
      versionCode: vcode,
      versionName: vname,
      label: label,
      iconZipPath: iconZipPath,
    );
  }

  /// Picks the largest `application-icon-NNN` entry (usually highest DPI).
  String? _bestApplicationIconDpi(String badging) {
    var bestN = -1;
    String? bestPath;
    for (final m in RegExp(r"application-icon-(\d+):'([^']+)'").allMatches(badging)) {
      final n = int.tryParse(m.group(1)!) ?? 0;
      if (n >= bestN) {
        bestN = n;
        bestPath = m.group(2);
      }
    }
    return bestPath;
  }

  /// Launcher icon bytes. Pass [badging] when already known to skip a second `aapt` run.
  ///
  /// Reads only the ZIP directory plus the icon entry instead of loading the whole APK.
  Future<Uint8List?> readLauncherIconBytes(String apkPath, {ApkBadging? badging}) async {
    badging ??= await readBadging(apkPath);
    final rel = badging?.iconZipPath;
    final idx = await ZipIndex.tryOpen(apkPath);
    if (idx != null) {
      try {
        return await _iconFromIndex(idx, rel);
      } catch (_) {
        // fall back to the full decoder below
      }
    }

    final bytes = await File(apkPath).readAsBytes();
    final archive = ZipDecoder().decodeBytes(bytes);

    if (rel != null && rel.isNotEmpty && !rel.endsWith('.xml')) {
      final hit = _findZipEntry(archive, rel);
      if (hit != null) {
        return Uint8List.fromList(hit.content as List<int>);
      }
    }

    final fromAdaptive = _iconFromAdaptiveXml(archive);
    if (fromAdaptive != null) return fromAdaptive;

    final fb = _fallbackIconFile(archive);
    if (fb != null) return Uint8List.fromList(fb.content as List<int>);
    return null;
  }

  /// Same lookup order as the [Archive] path, but over a [ZipIndex] (entries read on demand).
  Future<Uint8List?> _iconFromIndex(ZipIndex idx, String? rel) async {
    ZipEntry? loose(String path) {
      final want = path.replaceAll('\\', '/').toLowerCase();
      return idx.find((e) => !e.isDirectory && (e.lowerName == want || e.lowerName.endsWith(want)));
    }

    if (rel != null && rel.isNotEmpty && !rel.endsWith('.xml')) {
      final norm = rel.replaceAll('\\', '/');
      final base = p.basename(norm);
      final hit = loose(norm) ?? idx.find((e) => !e.isDirectory && e.baseName == base);
      if (hit != null) return idx.readBytes(hit);
    }

    for (final f in idx.entries) {
      final n = f.lowerName;
      if (f.isDirectory || !n.endsWith('ic_launcher.xml') || !n.contains('mipmap-anydpi')) continue;
      final xml = String.fromCharCodes(await idx.readBytes(f));
      final fg = RegExp(r'android:foreground="@drawable/([^"]+)"').firstMatch(xml)?.group(1) ??
          RegExp(r'android:drawable="@drawable/([^"]+)"').firstMatch(xml)?.group(1);
      if (fg == null) continue;
      ZipEntry? hit;
      for (final ext in ['.png', '.webp']) {
        for (final dens in ['xxxhdpi', 'xxhdpi', 'xhdpi', 'hdpi', 'mdpi']) {
          hit ??= loose('res/drawable-$dens-v4/$fg$ext');
          hit ??= loose('res/drawable-$dens/$fg$ext');
        }
      }
      hit ??= idx.find((e) {
        final low = e.baseName.toLowerCase();
        return !e.isDirectory && (low == '$fg.png' || low == '$fg.webp') && e.lowerName.contains('drawable');
      });
      if (hit != null) return idx.readBytes(hit);
    }

    const densityRank = ['xxxhdpi', 'xxhdpi', 'xhdpi', 'hdpi', 'mdpi', 'ldpi', 'nodpi'];
    ZipEntry? best;
    var bestRank = -1;
    for (final f in idx.entries) {
      final n = f.lowerName;
      if (f.isDirectory || !(n.endsWith('.png') || n.endsWith('.webp'))) continue;
      if (!(n.contains('ic_launcher') && n.contains('mipmap')) || n.contains('mipmap-anydpi')) continue;
      var rank = 0;
      for (var i = 0; i < densityRank.length; i++) {
        if (n.contains('mipmap-${densityRank[i]}')) {
          rank = i + 1;
          break;
        }
      }
      if (rank > bestRank || (rank == bestRank && best != null && f.name.length > best.name.length)) {
        bestRank = rank;
        best = f;
      }
    }
    return best == null ? null : idx.readBytes(best);
  }

  /// Follows `mipmap-anydpi-v26/ic_launcher.xml` foreground drawable when it points to a bitmap.
  Uint8List? _iconFromAdaptiveXml(Archive archive) {
    for (final f in archive) {
      if (!f.isFile) continue;
      final n = f.name.toLowerCase();
      if (!n.endsWith('ic_launcher.xml') || !n.contains('mipmap-anydpi')) continue;
      try {
        final xml = String.fromCharCodes(f.content as List<int>);
        final fg = RegExp(r'android:foreground="@drawable/([^"]+)"').firstMatch(xml)?.group(1) ??
            RegExp(r'android:drawable="@drawable/([^"]+)"').firstMatch(xml)?.group(1);
        if (fg == null) continue;
        ArchiveFile? hit;
        for (final ext in ['.png', '.webp']) {
          for (final dens in ['xxxhdpi', 'xxhdpi', 'xhdpi', 'hdpi', 'mdpi']) {
            hit ??= _findZipEntryLoose(archive, 'res/drawable-$dens-v4/$fg$ext');
            hit ??= _findZipEntryLoose(archive, 'res/drawable-$dens/$fg$ext');
          }
        }
        if (hit == null) {
          for (final e in archive) {
            if (!e.isFile) continue;
            final low = p.basename(e.name).toLowerCase();
            if ((low == '$fg.png' || low == '$fg.webp') && e.name.toLowerCase().contains('drawable')) {
              hit = e;
              break;
            }
          }
        }
        if (hit != null) return Uint8List.fromList(hit.content as List<int>);
      } catch (_) {}
    }
    return null;
  }

  ArchiveFile? _findZipEntry(Archive archive, String rel) {
    final normalized = rel.replaceAll('\\', '/');
    final hit = _findZipEntryLoose(archive, normalized);
    if (hit != null) return hit;
    final base = p.basename(normalized);
    for (final f in archive) {
      if (!f.isFile) continue;
      if (p.basename(f.name) == base) return f;
    }
    return null;
  }

  ArchiveFile? _findZipEntryLoose(Archive archive, String path) {
    final want = path.replaceAll('\\', '/').toLowerCase();
    for (final f in archive) {
      if (!f.isFile) continue;
      final name = f.name.replaceAll('\\', '/').toLowerCase();
      if (name == want) return f;
      if (name.endsWith(want)) return f;
    }
    return null;
  }

  ArchiveFile? _fallbackIconFile(Archive archive) {
    const densityRank = ['xxxhdpi', 'xxhdpi', 'xhdpi', 'hdpi', 'mdpi', 'ldpi', 'nodpi'];
    ArchiveFile? best;
    var bestRank = -1;
    for (final f in archive) {
      if (!f.isFile) continue;
      final n = f.name.toLowerCase();
      if (!(n.endsWith('.png') || n.endsWith('.webp'))) continue;
      if (!(n.contains('ic_launcher') && n.contains('mipmap'))) continue;
      if (n.contains('mipmap-anydpi')) continue;
      var rank = 0;
      for (var i = 0; i < densityRank.length; i++) {
        if (n.contains('mipmap-${densityRank[i]}')) {
          rank = i + 1;
          break;
        }
      }
      if (rank > bestRank) {
        bestRank = rank;
        best = f;
      } else if (rank == bestRank && best != null && f.name.length > best.name.length) {
        best = f;
      }
    }
    return best;
  }

  Future<ApkBadging?> readBadgingForFile(String path) => readBadging(path);

  static bool looksLikeApk(String path) {
    final e = p.extension(path).toLowerCase();
    return e == '.apk';
  }
}
