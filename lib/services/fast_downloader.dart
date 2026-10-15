import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:archive/archive.dart' show getCrc32;
import 'package:crypto/crypto.dart' as crypto;
import 'package:path/path.dart' as p;
import 'package:synchronized/synchronized.dart';

import 'app_catalog.dart';
import 'cancellation.dart';
import 'xapk_service.dart';
import 'zip_index.dart';

/// Multi-connection downloader.
///
/// * Splits large files into byte ranges fetched over several connections at once (CDNs usually
///   cap speed per connection, so this is often several times faster on a fast line).
/// * Resumes a dropped range where it stopped instead of restarting the whole file.
/// * Verifies MD5 when the store publishes one.
/// * APK + OBB builds (Aptoide) are downloaded straight into a single `.xapk` that the installer
///   understands — no second copy, and the game data gets pushed to the phone automatically.
class FastDownloader {
  FastDownloader._();

  static final FastDownloader instance = FastDownloader._();

  static const _defaultUa =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36';
  static const _minSegment = 6 * 1024 * 1024;
  static const _maxConnectionsPerFile = 6;

  final HttpClient _http = HttpClient()
    ..autoUncompress = false
    ..connectionTimeout = const Duration(seconds: 20)
    ..idleTimeout = const Duration(seconds: 15)
    ..maxConnectionsPerHost = 24;

  /// Downloads [option] into [directory] as `<stem>.<apk|xapk>` and returns the final file.
  /// The extension is decided by the file's real contents, not the URL.
  Future<File> download(
    DownloadOption option,
    Directory directory,
    String stem, {
    void Function(int received, int? total)? onProgress,
    CancellationToken? cancel,
  }) async {
    final partial = File(p.join(directory.path, '$stem.${option.extension}.partial'));
    final active = <HttpClientRequest>{};
    cancel?.abortHook = () {
      for (final r in active.toList()) {
        try {
          r.abort();
        } catch (_) {}
      }
    };
    try {
      if (option.parts.length == 1) {
        await _downloadSingle(option.parts.single, partial, active, onProgress, cancel);
      } else {
        await _downloadIntoXapk(option, partial, active, onProgress, cancel);
      }
      cancel?.throwIfCancelled();
      return await _finalize(partial, directory, stem);
    } catch (_) {
      try {
        if (partial.existsSync()) await partial.delete();
      } catch (_) {}
      rethrow;
    } finally {
      cancel?.abortHook = null;
    }
  }

  Future<File> _finalize(File partial, Directory directory, String stem) async {
    if (!await XapkService.fileLooksLikeOpenableZip(partial)) {
      final head = await partial.openRead(0, 256).fold<List<int>>([], (a, b) => a..addAll(b));
      final text = utf8.decode(head, allowMalformed: true).toLowerCase();
      if (text.contains('<html') || text.contains('<!doctype')) {
        throw const HttpException('The store returned a web page instead of the app (link expired or blocked).');
      }
      throw const HttpException('Downloaded file is not a valid APK / XAPK.');
    }
    final z = await ZipIndex.tryOpen(partial.path);
    final isPlainApk = z == null || z.entries.any((e) => e.name == 'AndroidManifest.xml');
    final ext = isPlainApk ? 'apk' : 'xapk';
    var dest = File(p.join(directory.path, '$stem.$ext'));
    if (dest.existsSync()) await dest.delete();
    await partial.rename(dest.path);
    return dest;
  }

  // ─────────────────────────── single file ───────────────────────────

  Future<void> _downloadSingle(
    DownloadPart part,
    File out,
    Set<HttpClientRequest> active,
    void Function(int, int?)? onProgress,
    CancellationToken? cancel,
  ) async {
    final probe = await _probe(part, active, cancel);
    if (part.size != null && probe.total != null && part.size != probe.total) {
      // Store metadata is stale; trust the server.
    }
    final total = probe.total ?? part.size;
    final raf = await out.open(mode: FileMode.write);
    try {
      if (total != null) await raf.truncate(total);
      var received = 0;
      void bump(int n) {
        received += n;
        onProgress?.call(received, total);
      }

      final writer = _RegionWriter(raf, 0);
      if (probe.ranged && total != null) {
        await _fetchRanges(probe.url, part, total, writer, bump, active, cancel);
      } else {
        await _fetchWhole(probe.url, part, writer, bump, active, cancel);
        await raf.truncate(writer.written);
      }
      await writer.flush();
    } finally {
      await raf.close();
    }
    if (part.md5 != null) {
      final digest = await _md5InIsolate(out.path);
      if (digest.toLowerCase() != part.md5!.toLowerCase()) {
        throw const HttpException('Checksum mismatch — the download was corrupted. Please try again.');
      }
    }
  }

  // ─────────────────────────── APK + OBB → XAPK ───────────────────────────

  Future<void> _downloadIntoXapk(
    DownloadOption option,
    File out,
    Set<HttpClientRequest> active,
    void Function(int, int?)? onProgress,
    CancellationToken? cancel,
  ) async {
    // Sizes must be exact to lay the archive out up front; confirm them with the servers.
    final probes = await Future.wait(option.parts.map((x) => _probe(x, active, cancel)));
    final sizes = <int>[];
    for (var i = 0; i < probes.length; i++) {
      final s = probes[i].total ?? option.parts[i].size;
      if (s == null) throw const HttpException('Server did not report the file size; cannot build the XAPK.');
      sizes.add(s);
    }
    final pkg = option.packageId;
    final manifest = utf8.encode(json.encode({
      'xapk_version': 2,
      'package_name': pkg,
      'name': option.title,
      'version_name': option.versionName,
      if (option.versionCode != null) 'version_code': '${option.versionCode}',
      'split_apks': [
        {'file': option.parts.first.zipEntry ?? '$pkg.apk', 'id': 'base'},
      ],
      'expansions': [
        for (final x in option.parts.skip(1))
          {'file': x.zipEntry, 'install_location': 'EXTERNAL_STORAGE', 'install_path': x.zipEntry},
      ],
    }));

    final entries = <_ZipLayout>[
      _ZipLayout('manifest.json', manifest.length, bytes: manifest),
      for (var i = 0; i < option.parts.length; i++)
        _ZipLayout(option.parts[i].zipEntry ?? 'part_$i.bin', sizes[i], part: i),
    ];
    var offset = 0;
    for (final e in entries) {
      e.headerOffset = offset;
      offset += 30 + e.nameBytes.length + e.size;
    }
    final cdOffset = offset;
    if (cdOffset >= 0xFFFFFFFF) {
      throw const HttpException('This build is larger than 4 GB, which needs ZIP64 — not supported yet.');
    }
    final total = sizes.fold<int>(0, (a, b) => a + b);

    final raf = await out.open(mode: FileMode.write);
    try {
      await raf.truncate(cdOffset);
      for (final e in entries) {
        await raf.setPosition(e.headerOffset);
        await raf.writeFrom(e.localHeader(crc: 0));
        if (e.bytes != null) await raf.writeFrom(e.bytes!);
      }
      final lock = Lock();
      var received = 0;
      void bump(int n) {
        received += n;
        onProgress?.call(received, total);
      }

      await Future.wait([
        for (final e in entries.where((e) => e.part != null))
          () async {
            final part = option.parts[e.part!];
            final probe = probes[e.part!];
            final writer = _RegionWriter(raf, e.dataOffset, lock: lock);
            if (probe.ranged) {
              await _fetchRanges(probe.url, part, e.size, writer, bump, active, cancel);
            } else {
              await _fetchWhole(probe.url, part, writer, bump, active, cancel);
            }
            await writer.flush();
          }(),
      ]);
      cancel?.throwIfCancelled();
    } finally {
      await raf.close();
    }

    // CRCs (and MD5 checks) need one read pass over each entry — done off the UI thread.
    final path = out.path;
    for (final e in entries) {
      if (e.bytes != null) {
        e.crc = getCrc32(e.bytes!);
        continue;
      }
      final start = e.dataOffset, len = e.size;
      final md5Wanted = option.parts[e.part!].md5;
      final r = await _crcInIsolate(path, start, len, md5Wanted != null);
      e.crc = r.$1;
      if (md5Wanted != null && r.$2!.toLowerCase() != md5Wanted.toLowerCase()) {
        throw HttpException('Checksum mismatch in ${e.name} — the download was corrupted. Please try again.');
      }
    }

    final w = await out.open(mode: FileMode.append);
    try {
      for (final e in entries) {
        await w.setPosition(e.headerOffset);
        await w.writeFrom(e.localHeader(crc: e.crc));
      }
      await w.setPosition(cdOffset);
      final cd = BytesBuilder();
      for (final e in entries) {
        cd.add(e.centralHeader());
      }
      final cdBytes = cd.takeBytes();
      await w.writeFrom(cdBytes);
      final eocd = ByteData(22)
        ..setUint32(0, 0x06054b50, Endian.little)
        ..setUint16(8, entries.length, Endian.little)
        ..setUint16(10, entries.length, Endian.little)
        ..setUint32(12, cdBytes.length, Endian.little)
        ..setUint32(16, cdOffset, Endian.little);
      await w.writeFrom(eocd.buffer.asUint8List());
    } finally {
      await w.close();
    }
  }

  // ─────────────────────────── HTTP plumbing ───────────────────────────

  Future<HttpClientResponse> _open(
    Uri url,
    DownloadPart part,
    Set<HttpClientRequest> active, {
    int? from,
    int? to,
  }) async {
    final req = await _http.getUrl(url);
    active.add(req);
    req.headers.set(HttpHeaders.userAgentHeader, part.userAgent ?? _defaultUa);
    req.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
    req.headers.set(HttpHeaders.acceptHeader, '*/*');
    if (part.referer != null) req.headers.set(HttpHeaders.refererHeader, part.referer!);
    if (from != null) req.headers.set(HttpHeaders.rangeHeader, 'bytes=$from-${to ?? ''}');
    try {
      return await req.close();
    } finally {
      active.remove(req);
    }
  }

  /// One-byte range request: learns the final (redirected) URL, the size, and range support.
  Future<({Uri url, int? total, bool ranged})> _probe(
    DownloadPart part,
    Set<HttpClientRequest> active,
    CancellationToken? cancel,
  ) async {
    cancel?.throwIfCancelled();
    var url = Uri.parse(part.url);
    final res = await _withRetry(() => _open(url, part, active, from: 0, to: 0), cancel);
    for (final r in res.redirects) {
      url = url.resolveUri(r.location);
    }
    await res.drain<void>();
    if (res.statusCode == 206) {
      final m = RegExp(r'/(\d+)').firstMatch(res.headers.value(HttpHeaders.contentRangeHeader) ?? '');
      return (url: url, total: m == null ? null : int.parse(m.group(1)!), ranged: m != null);
    }
    if (res.statusCode >= 400) throw HttpException('Download failed: HTTP ${res.statusCode}');
    return (url: url, total: res.contentLength >= 0 ? res.contentLength : null, ranged: false);
  }

  Future<T> _withRetry<T>(Future<T> Function() f, CancellationToken? cancel) async {
    for (var attempt = 0;; attempt++) {
      cancel?.throwIfCancelled();
      try {
        return await f();
      } catch (e) {
        cancel?.throwIfCancelled();
        if (attempt >= 4 || e is OperationCanceled) rethrow;
        await Future<void>.delayed(Duration(milliseconds: 400 * (1 << attempt)));
      }
    }
  }

  Future<void> _fetchWhole(
    Uri url,
    DownloadPart part,
    _RegionWriter writer,
    void Function(int) bump,
    Set<HttpClientRequest> active,
    CancellationToken? cancel,
  ) async {
    final res = await _withRetry(() => _open(url, part, active), cancel);
    if (res.statusCode >= 400) throw HttpException('Download failed: HTTP ${res.statusCode}');
    await for (final chunk in res) {
      cancel?.throwIfCancelled();
      await writer.add(chunk);
      bump(chunk.length);
    }
  }

  Future<void> _fetchRanges(
    Uri url,
    DownloadPart part,
    int total,
    _RegionWriter base,
    void Function(int) bump,
    Set<HttpClientRequest> active,
    CancellationToken? cancel,
  ) async {
    final n = math.max(1, math.min(_maxConnectionsPerFile, total ~/ _minSegment));
    final seg = (total / n).ceil();
    await Future.wait([
      for (var i = 0; i < n; i++)
        () async {
          final start = i * seg;
          final end = math.min(total, start + seg); // exclusive
          var pos = start;
          final w = base.at(start);
          var failures = 0;
          while (pos < end) {
            cancel?.throwIfCancelled();
            try {
              final res = await _open(url, part, active, from: pos, to: end - 1);
              if (res.statusCode != 206) {
                await res.drain<void>();
                throw HttpException('Range request failed: HTTP ${res.statusCode}');
              }
              await for (final chunk in res) {
                cancel?.throwIfCancelled();
                final take = math.min(chunk.length, end - pos);
                if (take <= 0) break;
                await w.add(take == chunk.length ? chunk : chunk.sublist(0, take));
                pos += take;
                bump(take);
              }
              failures = 0;
            } catch (e) {
              cancel?.throwIfCancelled();
              if (++failures > 6) rethrow;
              await w.flush();
              await Future<void>.delayed(Duration(milliseconds: 500 * failures));
            }
          }
          await w.flush();
        }(),
    ]);
  }
}

/// Buffers chunks and writes them at increasing offsets of a shared file.
class _RegionWriter {
  _RegionWriter(this.raf, this.offset, {Lock? lock}) : lock = lock ?? Lock();

  final RandomAccessFile raf;
  final Lock lock;
  int offset;
  int written = 0;
  final _buf = BytesBuilder(copy: false);

  _RegionWriter at(int relative) => _RegionWriter(raf, offset + relative, lock: lock);

  Future<void> add(List<int> chunk) async {
    _buf.add(chunk);
    if (_buf.length >= 1 << 20) await flush();
  }

  Future<void> flush() async {
    if (_buf.isEmpty) return;
    final data = _buf.takeBytes();
    final at = offset + written;
    written += data.length;
    await lock.synchronized(() async {
      await raf.setPosition(at);
      await raf.writeFrom(data);
    });
  }
}

class _ZipLayout {
  _ZipLayout(this.name, this.size, {this.bytes, this.part}) : nameBytes = utf8.encode(name);

  final String name;
  final List<int> nameBytes;
  final int size;
  final List<int>? bytes;
  final int? part;
  int headerOffset = 0;
  int crc = 0;

  int get dataOffset => headerOffset + 30 + nameBytes.length;

  Uint8List localHeader({required int crc}) {
    final b = ByteData(30)
      ..setUint32(0, 0x04034b50, Endian.little)
      ..setUint16(4, 20, Endian.little)
      ..setUint16(6, 0x0800, Endian.little) // UTF-8 names
      ..setUint16(8, 0, Endian.little) // stored
      ..setUint32(14, crc, Endian.little)
      ..setUint32(18, size, Endian.little)
      ..setUint32(22, size, Endian.little)
      ..setUint16(26, nameBytes.length, Endian.little);
    return Uint8List.fromList([...b.buffer.asUint8List(), ...nameBytes]);
  }

  Uint8List centralHeader() {
    final b = ByteData(46)
      ..setUint32(0, 0x02014b50, Endian.little)
      ..setUint16(4, 20, Endian.little)
      ..setUint16(6, 20, Endian.little)
      ..setUint16(8, 0x0800, Endian.little)
      ..setUint32(16, crc, Endian.little)
      ..setUint32(20, size, Endian.little)
      ..setUint32(24, size, Endian.little)
      ..setUint16(28, nameBytes.length, Endian.little)
      ..setUint32(42, headerOffset, Endian.little);
    return Uint8List.fromList([...b.buffer.asUint8List(), ...nameBytes]);
  }
}

// Spawned from top-level functions so the closures sent to the isolate capture nothing else.
Future<String> _md5InIsolate(String path) => Isolate.run(() => _md5Of(path, 0, null));

Future<(int, String?)> _crcInIsolate(String path, int start, int length, bool withMd5) =>
    Isolate.run(() => _crcAndMd5(path, start, length, withMd5));

Future<String> _md5Of(String path, int start, int? length) async {
  final sink = _DigestSink();
  final input = crypto.md5.startChunkedConversion(sink);
  await for (final c in File(path).openRead(start, length == null ? null : start + length)) {
    input.add(c);
  }
  input.close();
  return sink.value.toString();
}

Future<(int, String?)> _crcAndMd5(String path, int start, int length, bool withMd5) async {
  var crc = 0;
  final sink = _DigestSink();
  final md5 = withMd5 ? crypto.md5.startChunkedConversion(sink) : null;
  await for (final c in File(path).openRead(start, start + length)) {
    crc = getCrc32(c, crc);
    md5?.add(c);
  }
  md5?.close();
  return (crc, withMd5 ? sink.value.toString() : null);
}

class _DigestSink implements Sink<crypto.Digest> {
  late crypto.Digest value;
  @override
  void add(crypto.Digest data) => value = data;
  @override
  void close() {}
}
