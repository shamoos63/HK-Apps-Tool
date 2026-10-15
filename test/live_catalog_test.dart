// Hits real store APIs — run with: LIVE_STORES=1 flutter test test/live_catalog_test.dart
import 'dart:io';

import 'package:adbappmanager/services/app_catalog.dart';
import 'package:adbappmanager/services/fast_downloader.dart';
import 'package:adbappmanager/services/zip_index.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final live = Platform.environment['LIVE_STORES'] == '1';
  final catalog = AppCatalog();

  for (final q in ['capcut', 'free fire', 'pubg mobile', 'spotify', 'com.whatsapp', 'vlc']) {
    test('search + options: $q', () async {
      final sw = Stopwatch()..start();
      final hits = await catalog.search(q);
      final searchMs = sw.elapsedMilliseconds;
      expect(hits, isNotEmpty);
      final top = hits.first;
      sw.reset();
      final opts = await catalog.options(top);
      // ignore: avoid_print
      print('"$q" -> ${hits.length} apps in ${searchMs}ms; top ${top.packageId} "${top.title}" via ${top.foundVia}'
          '\n   ${opts.length} builds in ${sw.elapsedMilliseconds}ms: '
          '${opts.take(6).map((o) => '${o.source.label} ${o.versionName} ${o.extension} ${o.totalSize == null ? '?' : '${o.totalSize! ~/ 1048576}MB'}${o.hasObb ? ' +OBB' : ''}${o.warning != null ? ' [warn]' : ''}').join(' | ')}');
      expect(opts, isNotEmpty);
    }, skip: live ? false : 'set LIVE_STORES=1', timeout: const Timeout(Duration(minutes: 2)));
  }

  final dl = Platform.environment['LIVE_DOWNLOADS'] == '1';
  for (final (pkg, src) in [
    ('com.spotify.music', StoreSource.apkpure),
    ('org.videolan.vlc', StoreSource.aptoide),
    ('org.videolan.vlc', StoreSource.fdroid),
  ]) {
    test('download $pkg from ${src.label}', () async {
      final opts = await catalog.options(AppListing(packageId: pkg, title: pkg.split('.').last), sources: {src});
      final o = opts.firstWhere((o) => o.warning == null);
      final dir = Directory.systemTemp.createTempSync('hk_live_dl_');
      try {
        final sw = Stopwatch()..start();
        final f = await FastDownloader.instance.download(o, dir, 'x');
        final fastMs = sw.elapsedMilliseconds;
        final size = f.lengthSync();
        final z = await ZipIndex.open(f.path);
        sw.reset();
        final curl = await Process.run('curl', [
          '-sL', '-o', '${dir.path}/curl.bin', '-A', o.parts.first.userAgent ?? 'Mozilla/5.0',
          if (o.parts.first.referer != null) ...['-e', o.parts.first.referer!],
          o.parts.first.url,
        ]);
        final curlMs = sw.elapsedMilliseconds;
        final mb = size / 1048576;
        // ignore: avoid_print
        print('${src.label} $pkg v${o.versionName}: ${mb.toStringAsFixed(1)} MB -> ${p(f.path)} '
            '(${z.entries.length} entries${o.parts.first.md5 != null ? ', md5 ok' : ''})\n'
            '   multi-connection ${(fastMs / 1000).toStringAsFixed(1)}s = ${(mb / fastMs * 1000).toStringAsFixed(1)} MB/s | '
            'single curl ${(curlMs / 1000).toStringAsFixed(1)}s = ${(File('${dir.path}/curl.bin').lengthSync() / 1048576 / curlMs * 1000).toStringAsFixed(1)} MB/s (exit ${curl.exitCode})');
      } finally {
        dir.deleteSync(recursive: true);
      }
    }, skip: dl ? false : 'set LIVE_DOWNLOADS=1', timeout: const Timeout(Duration(minutes: 10)));
  }
}

String p(String path) => path.split('/').last;
