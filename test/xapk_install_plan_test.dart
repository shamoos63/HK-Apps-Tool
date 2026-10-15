import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:adbappmanager/services/app_paths.dart';
import 'package:adbappmanager/services/xapk_service.dart';
import 'package:adbappmanager/services/zip_index.dart';
import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

Uint8List _bytes(int n, int seed) {
  final r = Random(seed);
  return Uint8List.fromList(List<int>.generate(n, (_) => r.nextInt(256)));
}

ArchiveFile _stored(String name, List<int> data) => ArchiveFile.bytes(name, data)..compression = CompressionType.none;

ArchiveFile _deflated(String name, List<int> data) => ArchiveFile.bytes(name, data);

String _writeZip(Directory dir, String name, List<ArchiveFile> files) {
  final a = Archive();
  files.forEach(a.add);
  final path = p.join(dir.path, name);
  File(path).writeAsBytesSync(ZipEncoder().encode(a));
  return path;
}

Future<Uint8List> _drain(Stream<List<int>> s) async {
  final b = BytesBuilder();
  await for (final c in s) {
    b.add(c);
  }
  return b.takeBytes();
}

void main() {
  late Directory tmp;
  final xapk = XapkService();

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('hk_xapk_test_');
    AppPaths.debugTempRootOverride = tmp;
  });

  tearDown(() {
    AppPaths.debugTempRootOverride = null;
    tmp.deleteSync(recursive: true);
  });

  test('ZipIndex reads stored and deflated entries without decoding the archive', () async {
    final base = _bytes(300000, 1);
    final text = utf8.encode('hello ' * 5000);
    final path = _writeZip(tmp, 'x.zip', [_stored('a/base.apk', base), _deflated('notes.txt', text)]);
    final z = await ZipIndex.open(path);
    expect(z.entries.map((e) => e.name), containsAll(['a/base.apk', 'notes.txt']));
    final b = z.find((e) => e.name == 'a/base.apk')!;
    expect(b.method, 0);
    expect(await z.readBytes(b), base);
    final n = z.find((e) => e.name == 'notes.txt')!;
    expect(n.method, 8);
    expect(await z.readBytes(n), text);

    final out = p.join(tmp.path, 'out.apk');
    var seen = 0;
    await z.extractTo(b, out, onBytes: (d) => seen += d);
    expect(File(out).readAsBytesSync(), base);
    expect(seen, b.compressedSize);
  });

  test('XAPK plan streams splits in manifest order and finds OBBs without unpacking', () async {
    final manifest = jsonEncode({
      'package_name': 'com.example.game',
      'version_name': '2.1',
      'split_apks': [
        {'file': 'com.example.game.apk', 'id': 'base'},
        {'file': 'config.arm64_v8a.apk', 'id': 'config.arm64_v8a'},
        {'file': 'config.en.apk', 'id': 'config.en'},
      ],
      'expansions': [
        {
          'file': 'Android/obb/com.example.game/main.7.com.example.game.obb',
          'install_location': 'EXTERNAL_STORAGE',
          'install_path': 'Android/obb/com.example.game/main.7.com.example.game.obb',
        }
      ],
    });
    final parts = {
      'config.en.apk': _bytes(1000, 2),
      'com.example.game.apk': _bytes(50000, 3),
      'config.arm64_v8a.apk': _bytes(20000, 4),
    };
    final obb = _bytes(80000, 5);
    final path = _writeZip(tmp, 'game.xapk', [
      _deflated('manifest.json', utf8.encode(manifest)),
      _deflated('icon.png', _bytes(100, 6)),
      for (final e in parts.entries) _stored(e.key, e.value),
      _stored('Android/obb/com.example.game/main.7.com.example.game.obb', obb),
    ]);

    final plan = await xapk.planInstall(path, includeObb: true);
    expect(plan.parts.map((x) => x.name),
        ['com.example.game.apk', 'config.arm64_v8a.apk', 'config.en.apk']);
    expect(plan.packageName, 'com.example.game');
    expect(plan.workDir, isNull, reason: 'fast path must not unpack to disk');
    for (final part in plan.parts) {
      expect(await _drain(await part.open()), parts[part.name]);
    }
    expect(plan.obbs.single.devicePath,
        '/sdcard/Android/obb/com.example.game/main.7.com.example.game.obb');
    expect(await _drain(await plan.obbs.single.zip.openEntry(plan.obbs.single.entry)), obb);

    final withoutObb = await xapk.planInstall(path);
    expect(withoutObb.obbs, isEmpty);

    // Fallback materialisation unpacks APKs only, once, and cleans up.
    final files = await plan.materialize();
    expect(files.map(p.basename), ['com.example.game.apk', 'config.arm64_v8a.apk', 'config.en.apk']);
    expect(identical(plan.materialize(), plan.materialize()), isTrue);
    await plan.dispose();
    expect(files.every((f) => !File(f).existsSync()), isTrue);
  });

  test('plain APK is installed as-is even if it embeds other APKs', () async {
    final path = _writeZip(tmp, 'app.apk', [
      _deflated('AndroidManifest.xml', _bytes(500, 7)),
      _deflated('classes.dex', _bytes(5000, 8)),
      _stored('assets/plugin.apk', _bytes(3000, 9)),
    ]);
    final plan = await xapk.planInstall(path);
    expect(plan.parts.single.localPath, path);
    expect(await XapkService.zipLooksLikeXapkBundle(path), isFalse);
  });

  test('split bundle saved as .apk is detected and split', () async {
    final path = _writeZip(tmp, 'bundle.apk', [
      _deflated('manifest.json', utf8.encode('{"package_name":"a.b"}')),
      _stored('base.apk', _bytes(4000, 10)),
      _stored('split_config.xxhdpi.apk', _bytes(2000, 11)),
    ]);
    expect(await XapkService.zipLooksLikeXapkBundle(path), isTrue);
    final plan = await xapk.planInstall(path);
    expect(plan.parts.map((x) => x.name), ['base.apk', 'split_config.xxhdpi.apk']);
  });

  test('peek reads manifest and locates the base APK', () async {
    final path = _writeZip(tmp, 'p.xapk', [
      _deflated('manifest.json',
          utf8.encode('{"package_name":"com.foo","version_name":"1.0","version_code":"5"}')),
      _stored('config.en.apk', _bytes(10, 12)),
      _stored('com.foo.apk', _bytes(10, 13)),
    ]);
    final peek = await xapk.peek(path);
    expect(peek.packageName, 'com.foo');
    expect(peek.versionName, '1.0');
    expect(peek.versionCode, '5');
    expect(peek.sampleApkEntry?.name, 'com.foo.apk');
  });

  test('ZIP64 archives are listed (when the zip tool is available)', () async {
    final src = Directory(p.join(tmp.path, 'src'))..createSync();
    File(p.join(src.path, 'base.apk')).writeAsBytesSync(_bytes(2048, 14));
    final out = p.join(tmp.path, 'z64.xapk');
    ProcessResult r;
    try {
      r = await Process.run('zip', ['-q', '-0', '-fz', out, 'base.apk'], workingDirectory: src.path);
    } on ProcessException {
      markTestSkipped('zip not installed');
      return;
    }
    if (r.exitCode != 0) {
      markTestSkipped('zip -fz unsupported');
      return;
    }
    final z = await ZipIndex.open(out);
    final e = z.entries.single;
    expect(e.name, 'base.apk');
    expect(await z.readBytes(e), File(p.join(src.path, 'base.apk')).readAsBytesSync());
  });
}
