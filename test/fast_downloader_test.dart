import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:adbappmanager/services/app_catalog.dart';
import 'package:adbappmanager/services/fast_downloader.dart';
import 'package:adbappmanager/services/zip_index.dart';
import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter_test/flutter_test.dart';

Uint8List _bytes(int n, int seed) {
  final r = Random(seed);
  return Uint8List.fromList(List<int>.generate(n, (_) => r.nextInt(256)));
}

void main() {
  late HttpServer server;
  late Directory tmp;
  final files = <String, Uint8List>{};
  var rangeRequests = 0;
  var dropOnce = true;

  setUpAll(() async {
    final apkArchive = Archive()
      ..add(ArchiveFile.bytes('AndroidManifest.xml', _bytes(800, 1)))
      ..add(ArchiveFile.bytes('assets/blob.bin', _bytes(20 * 1024 * 1024, 2))..compression = CompressionType.none);
    files['/app.apk'] = Uint8List.fromList(ZipEncoder().encode(apkArchive));
    files['/game.apk'] = _bytes(7 * 1024 * 1024, 3);
    files['/main.obb'] = _bytes(13 * 1024 * 1024, 4);

    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) async {
      final res = req.response;
      if (req.uri.path == '/redirect') {
        await res.redirect(Uri.parse('/app.apk'));
        return;
      }
      final data = files[req.uri.path.replaceFirst('/norange', '')];
      if (data == null) {
        res.statusCode = 404;
        await res.close();
        return;
      }
      final range = req.headers.value(HttpHeaders.rangeHeader);
      if (range != null && !req.uri.path.startsWith('/norange')) {
        rangeRequests++;
        final m = RegExp(r'bytes=(\d+)-(\d*)').firstMatch(range)!;
        final from = int.parse(m.group(1)!);
        final to = m.group(2)!.isEmpty ? data.length - 1 : int.parse(m.group(2)!);
        res.statusCode = 206;
        res.headers.set(HttpHeaders.contentRangeHeader, 'bytes $from-$to/${data.length}');
        res.contentLength = to - from + 1;
        // Simulate a connection dropping mid-range once; the downloader must resume.
        if (dropOnce && from > 0 && to - from > 1024 * 1024) {
          dropOnce = false;
          final socket = await res.detachSocket(writeHeaders: true);
          socket.add(data.sublist(from, from + 1000));
          await socket.flush();
          socket.destroy();
          return;
        }
        res.add(data.sublist(from, to + 1));
      } else {
        res.contentLength = data.length;
        res.add(data);
      }
      await res.close();
    });
    tmp = Directory.systemTemp.createTempSync('hk_dl_test_');
  });

  tearDownAll(() async {
    await server.close(force: true);
    tmp.deleteSync(recursive: true);
  });

  String url(String path) => 'http://127.0.0.1:${server.port}$path';

  DownloadOption single(String path, {String? md5}) => DownloadOption(
        source: StoreSource.apkpure,
        packageId: 'com.test',
        title: 'Test',
        versionName: '1.0',
        parts: [DownloadPart(url: url(path), md5: md5)],
      );

  test('segmented download with redirect, resume and md5', () async {
    final want = files['/app.apk']!;
    rangeRequests = 0;
    final f = await FastDownloader.instance.download(
      single('/redirect', md5: crypto.md5.convert(want).toString()),
      tmp,
      'app',
    );
    expect(f.path.endsWith('app.apk'), isTrue);
    expect(f.readAsBytesSync(), want);
    expect(rangeRequests, greaterThan(3), reason: 'should use several connections');
  });

  test('server without range support falls back to one stream', () async {
    final f = await FastDownloader.instance.download(single('/norange/app.apk'), tmp, 'plain');
    expect(f.readAsBytesSync(), files['/app.apk']);
  });

  test('wrong md5 is rejected', () async {
    await expectLater(
      FastDownloader.instance.download(single('/app.apk', md5: '0' * 32), tmp, 'bad'),
      throwsA(isA<HttpException>()),
    );
    expect(File('${tmp.path}/bad.apk.partial').existsSync(), isFalse);
  });

  test('APK + OBB are assembled into a valid XAPK', () async {
    final option = DownloadOption(
      source: StoreSource.aptoide,
      packageId: 'com.test.game',
      title: 'Game',
      versionName: '2.0',
      versionCode: 20,
      parts: [
        DownloadPart(
          url: url('/game.apk'),
          size: files['/game.apk']!.length,
          md5: crypto.md5.convert(files['/game.apk']!).toString(),
          zipEntry: 'com.test.game.apk',
        ),
        DownloadPart(
          url: url('/main.obb'),
          size: files['/main.obb']!.length,
          zipEntry: 'Android/obb/com.test.game/main.20.com.test.game.obb',
        ),
      ],
    );
    final f = await FastDownloader.instance.download(option, tmp, 'game');
    expect(f.path.endsWith('game.xapk'), isTrue);
    final z = await ZipIndex.open(f.path);
    expect(z.entries.map((e) => e.name), [
      'manifest.json',
      'com.test.game.apk',
      'Android/obb/com.test.game/main.20.com.test.game.obb',
    ]);
    expect(await z.readBytes(z.entries[1]), files['/game.apk']);
    expect(await z.readBytes(z.entries[2]), files['/main.obb']);
    // CRCs must be right for other tools too.
    final decoded = ZipDecoder().decodeBytes(f.readAsBytesSync(), verify: true);
    expect(decoded.length, 3);
    final unzip = await Process.run('unzip', ['-tq', f.path]).catchError((_) => ProcessResult(0, 0, 'skip', ''));
    expect(unzip.exitCode, 0, reason: '${unzip.stdout}${unzip.stderr}');
  });
}
