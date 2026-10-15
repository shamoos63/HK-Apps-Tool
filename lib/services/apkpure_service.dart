import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:html/parser.dart' as html_parser;

import 'cancellation.dart';
import 'xapk_service.dart';

class ApkpureSearchHit {
  ApkpureSearchHit({
    required this.title,
    required this.pageUrl,
    required this.packageId,
    required this.slug,
    this.isUptodown = false,
    this.isApkcombo = false,
  });

  final String title;
  final String pageUrl;
  final String packageId;
  final String slug;
  /// When true, [pageUrl] is an Uptodown app page; use [CombinedApkStoreService] for release/download.
  final bool isUptodown;
  /// When true, results come from [apkcombo.com](https://apkcombo.com); signed CDN URLs are resolved from their download page.
  final bool isApkcombo;
}

class ApkpureReleaseInfo {
  ApkpureReleaseInfo({
    required this.title,
    required this.version,
    required this.updateDate,
    required this.downloadUrl,
    required this.pageUrl,
    this.downloadReferer,
  });

  final String title;
  final String version;
  final String updateDate;
  final String downloadUrl;
  final String pageUrl;
  /// Optional Referer header for CDN downloads (e.g. Uptodown, APKCombo).
  final String? downloadReferer;
}

/// Fetches APKPure data using [HttpClient] with browser-like headers where needed.
///
/// When possible, uses the same `api.pureapk.com` app-version endpoint and client
/// headers as [EFF apkeep](https://github.com/EFForg/apkeep) (`x-cv`, `x-sv`,
/// `x-abis`, `x-gp`) so metadata and CDN URLs work without scraping HTML that
/// often returns 403.
class ApkpureService {
  static const _ua =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36';

  static bool _looksLikeHtmlLead(List<int> raw) {
    if (raw.isEmpty || raw[0] != 0x3C) return false;
    final n = raw.length > 512 ? 512 : raw.length;
    final s = utf8.decode(raw.sublist(0, n), allowMalformed: true).trimLeft().toLowerCase();
    return s.startsWith('<!doctype') ||
        s.startsWith('<html') ||
        s.startsWith('<head') ||
        s.startsWith('<script') ||
        s.startsWith('<body') ||
        s.startsWith('<meta') ||
        s.startsWith('<title') ||
        s.startsWith('<link');
  }

  /// Same version-list URL shape as apkeep (`src/consts.rs`).
  static Uri _pureApiUri(String packageId) => Uri.parse(
        'https://api.pureapk.com/m/v3/cms/app_version?hl=en-US&package_name=${Uri.encodeQueryComponent(packageId)}',
      );

  /// Matches embedded CDN links in the pureapk response (see apkeep `APKPURE_DOWNLOAD_URL_REGEX`).
  static final _pureApiDownloadRe = RegExp(
    r'(X?APKJ)..(https?://(?:www\.)?[-a-zA-Z0-9@:%._+~#=]{1,256}\.[a-zA-Z0-9()]{1,6}\b(?:[-a-zA-Z0-9()@:%_+.~#?&/=]*))',
    caseSensitive: false,
  );

  static final _pureApiVersionHashRe = RegExp(
    r'([\w.+-]+):\([\da-f]{40,}',
    caseSensitive: false,
  );

  static bool looksLikeAndroidPackageId(String q) {
    final s = q.trim();
    if (s.length < 5 || !s.contains('.')) return false;
    return RegExp(r'^[a-zA-Z][a-zA-Z0-9_]*(?:\.[a-zA-Z0-9_]+)+$').hasMatch(s);
  }

  final HttpClient _client = HttpClient()
    ..userAgent = _ua
    ..autoUncompress = true
    ..connectionTimeout = const Duration(seconds: 25);

  /// Binary-only HTTP client: always persist the **exact** response body stream (no automatic
  /// gzip/decode). Transport compression is handled by system `curl` when possible, or by
  /// [_normalizeDownloadedArchive] for raw gzip-wrapped archives.
  late final HttpClient _httpBinaryDownloadClient = HttpClient()
    ..userAgent = _ua
    ..autoUncompress = false
    ..connectionTimeout = const Duration(seconds: 25);

  bool _warmed = false;

  Future<void> _warmSession({CancellationToken? cancel}) async {
    if (_warmed) return;
    for (final u in ['https://apkpure.com/', 'https://apkpure.com/en']) {
      cancel?.throwIfCancelled();
      try {
        await _getBody(Uri.parse(u), referer: null, fetchSite: 'none', cancel: cancel);
      } catch (_) {}
    }
    _warmed = true;
  }

  void _applyHeaders(HttpClientRequest req, {required String? referer, required String fetchSite}) {
    req.headers.set(
      HttpHeaders.acceptHeader,
      'text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,image/apng,*/*;q=0.8',
    );
    req.headers.set(HttpHeaders.acceptLanguageHeader, 'en-US,en;q=0.9');
    req.headers.set('Accept-Encoding', 'gzip, deflate');
    req.headers.set('Upgrade-Insecure-Requests', '1');
    req.headers.set('Sec-Fetch-Dest', 'document');
    req.headers.set('Sec-Fetch-Mode', 'navigate');
    req.headers.set('Sec-Fetch-Site', fetchSite);
    req.headers.set('sec-ch-ua', '"Google Chrome";v="131", "Chromium";v="131", "Not_A Brand";v="24"');
    req.headers.set('sec-ch-ua-mobile', '?0');
    req.headers.set('sec-ch-ua-platform', '"Windows"');
    if (referer != null && referer.isNotEmpty) {
      req.headers.set(HttpHeaders.refererHeader, referer);
    }
  }

  Future<String> _getBody(
    Uri uri, {
    required String? referer,
    required String fetchSite,
    CancellationToken? cancel,
  }) async {
    cancel?.throwIfCancelled();
    final req = await _client.getUrl(uri);
    _applyHeaders(req, referer: referer, fetchSite: fetchSite);
    cancel?.throwIfCancelled();
    final res = await req.close();
    final body = await res.transform(utf8.decoder).join();
    if (res.statusCode >= 400) {
      throw HttpException('HTTP ${res.statusCode} for $uri');
    }
    return body;
  }

  void _applyPureApiHeaders(HttpClientRequest req) {
    req.headers.set(HttpHeaders.acceptHeader, '*/*');
    req.headers.set(HttpHeaders.acceptLanguageHeader, 'en-US,en;q=0.9');
    req.headers.set('Accept-Encoding', 'gzip, deflate');
    // Same keys as EFF apkeep `download_sources/apkpure.rs` `http_headers`.
    req.headers.set('x-cv', '3172501');
    req.headers.set('x-sv', '29');
    req.headers.set(
      'x-abis',
      'arm64-v8a,armeabi-v7a,armeabi,x86,x86_64',
    );
    req.headers.set('x-gp', '1');
  }

  /// True if api.pureapk.com looks aware of this package (JSON with link, or large protobuf payload).
  Future<bool> _probePureApiPackage(String packageId, {CancellationToken? cancel}) async {
    try {
      cancel?.throwIfCancelled();
      final uri = _pureApiUri(packageId);
      final req = await _client.getUrl(uri);
      _applyPureApiHeaders(req);
      cancel?.throwIfCancelled();
      final res = await req.close();
      if (res.statusCode >= 400) {
        await res.drain();
        return false;
      }
      final ct = res.headers.value(HttpHeaders.contentTypeHeader)?.toLowerCase() ?? '';
      if (ct.contains('octet-stream') || ct.contains('protobuf')) {
        final len = res.contentLength;
        await res.drain();
        if (len >= 0 && len < 500) return false;
        return true;
      }
      final body = await res.transform(utf8.decoder).join();
      return _parsePureApiDownloadUrl(body) != null;
    } catch (_) {
      return false;
    }
  }

  String? _parsePureApiDownloadUrl(String body) {
    final m = _pureApiDownloadRe.firstMatch(body);
    return m?.group(2)?.trim();
  }

  String? _parsePureApiDisplayName(String body) {
    for (final key in ['app_name', 'app_title', 'display_name', 'title', 'name']) {
      final m = RegExp(
        '"$key"\\s*:\\s*"([^"]{2,199})"',
        caseSensitive: false,
      ).firstMatch(body);
      if (m != null) {
        final s = m.group(1)!.trim();
        if (s.isNotEmpty) return s;
      }
    }
    return null;
  }

  String _bestVersionFromPureApiBody(String body) {
    String? best;
    for (final m in _pureApiVersionHashRe.allMatches(body)) {
      final v = m.group(1)!;
      if (best == null || looksNewer(v, best)) best = v;
    }
    return best ?? '—';
  }

  Future<ApkpureReleaseInfo?> _tryFetchReleaseFromPureApi(ApkpureSearchHit hit) async {
    if (hit.isUptodown) return null;
    try {
      final uri = _pureApiUri(hit.packageId);
      final req = await _client.getUrl(uri);
      _applyPureApiHeaders(req);
      final res = await req.close();
      if (res.statusCode >= 400) {
        await res.drain();
        return null;
      }
      final ct = res.headers.value(HttpHeaders.contentTypeHeader)?.toLowerCase() ?? '';
      // api.pureapk.com often returns protobuf (application/octet-stream) now — our parser expects JSON text.
      if (ct.contains('octet-stream') || ct.contains('protobuf')) {
        await res.drain();
        return null;
      }
      final body = await res.transform(utf8.decoder).join();
      final dUrl = _parsePureApiDownloadUrl(body);
      if (dUrl == null || dUrl.isEmpty) return null;
      return ApkpureReleaseInfo(
        title: _parsePureApiDisplayName(body) ?? hit.title,
        version: _bestVersionFromPureApiBody(body),
        updateDate: '—',
        downloadUrl: dUrl,
        pageUrl: hit.pageUrl,
        downloadReferer: 'https://apkpure.com/',
      );
    } catch (_) {
      return null;
    }
  }

  Future<List<ApkpureSearchHit>> search(String query, {CancellationToken? cancel}) async {
    cancel?.throwIfCancelled();
    await _warmSession(cancel: cancel);
    final trimmed = query.trim();
    if (trimmed.isEmpty) return [];

    if (looksLikeAndroidPackageId(trimmed)) {
      try {
        cancel?.throwIfCancelled();
        if (await _probePureApiPackage(trimmed, cancel: cancel)) {
          final title = _humanizeSlug(trimmed.split('.').last);
          return [
            ApkpureSearchHit(
              title: title,
              pageUrl: 'https://apkpure.com/app/$trimmed/download',
              packageId: trimmed,
              slug: 'app',
            ),
          ];
        }
      } on OperationCanceled {
        rethrow;
      } catch (_) {}
    }

    cancel?.throwIfCancelled();
    final q = Uri.encodeQueryComponent(trimmed);
    HttpException? lastErr;
    final urls = [
      Uri.parse('https://apkpure.com/search?q=$q'),
      Uri.parse('https://apkpure.com/en/search?q=$q'),
      Uri.parse('https://www.apkpure.com/search?q=$q'),
    ];
    for (var i = 0; i < urls.length; i++) {
      cancel?.throwIfCancelled();
      try {
        final body = await _getBody(
          urls[i],
          referer: 'https://apkpure.com/',
          fetchSite: i == 0 ? 'same-origin' : 'same-origin',
          cancel: cancel,
        );
        return _parseSearchHits(body);
      } on OperationCanceled {
        rethrow;
      } on HttpException catch (e) {
        lastErr = e;
      }
    }
    cancel?.throwIfCancelled();
    throw lastErr ?? HttpException('Search failed');
  }

  List<ApkpureSearchHit> _parseSearchHits(String body) {
    final doc = html_parser.parse(body);
    final hits = <ApkpureSearchHit>[];
    final seen = <String>{};

    void tryAdd(String? href, String title) {
      if (href == null) return;
      if (!href.contains('apkpure.com')) return;
      if (href.contains('/howto/') || href.contains('/news/') || href.contains('/topic/')) return;
      final uri = Uri.parse(href.startsWith('http') ? href : 'https://apkpure.com$href');
      final segs = uri.pathSegments.where((s) => s.isNotEmpty).toList();
      if (segs.length < 3) return;
      if (segs.last != 'download') return;
      final pkg = segs[segs.length - 2];
      if (!pkg.contains('.')) return;
      final slug = segs[segs.length - 3];
      if (seen.add(pkg)) {
        hits.add(
          ApkpureSearchHit(
            title: title.trim().isEmpty ? _humanizeSlug(slug) : title.trim(),
            pageUrl: uri.replace(queryParameters: {}).toString().split('#').first,
            packageId: pkg,
            slug: slug,
          ),
        );
      }
    }

    for (final a in doc.querySelectorAll('a[href]')) {
      final href = a.attributes['href'];
      final t = a.text.replaceAll(RegExp(r'\s+'), ' ').trim();
      tryAdd(href, t);
    }

    final re = RegExp(
      r'https://(?:www\.)?apkpure\.com/([\w\-]+)/((?:[\w][\w]*\.)+[\w]+)/download[^"\s]*',
      caseSensitive: false,
    );
    for (final m in re.allMatches(body)) {
      tryAdd(m.group(0), _humanizeSlug(m.group(1)!));
    }

    return hits;
  }

  Future<ApkpureReleaseInfo> fetchRelease(ApkpureSearchHit hit) async {
    final fromApi = await _tryFetchReleaseFromPureApi(hit);
    if (fromApi != null) return fromApi;

    await _warmSession();
    final downloadUrl = 'https://apkpure.com/${hit.slug}/${hit.packageId}/download';
    final body = await _getBody(
      Uri.parse(downloadUrl),
      referer: 'https://apkpure.com/',
      fetchSite: 'same-origin',
    );
    final title = _extractTitle(body) ?? hit.title;

    var version = _firstMatch(body, [
      RegExp(r'Latest Version\s+([\d.]+)', caseSensitive: false),
      RegExp(r'Download APK\s+([\d.]+)', caseSensitive: false),
      RegExp(r'versionName=[^\d]*([\d.]+)', caseSensitive: false),
      RegExp(r"What's New in the Latest Version\s+([\d.]+)", caseSensitive: false),
    ]) ??
        '';

    if (version.isEmpty) {
      version = _firstMatch(body, [RegExp(r'\b(\d+\.\d+\.\d+\.\d+)\b')]) ?? '—';
    }

    var date = _firstMatch(body, [
      RegExp(r'Update date\s*</[^>]+>\s*<[^>]+>([^<]+)', caseSensitive: false),
      RegExp(r'Update date[^0-9A-Za-z]+((?:Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)[^<\n]{0,32}\d{4})',
          caseSensitive: false),
    ]) ??
        '';

    if (date.isEmpty) {
      date = _firstMatch(body, [
        RegExp(r'((?:Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)\s+\d{1,2},\s+\d{4})'),
      ]) ??
          '—';
    }

    final dUrl = _firstMatch(body, [
      RegExp(r'(https://d\.apkpure\.com/b/(?:XAPK|APK)/[^"\s<>]+)'),
    ]) ??
        'https://d.apkpure.com/b/XAPK/${hit.packageId}?version=latest';

    return ApkpureReleaseInfo(
      title: title,
      version: version,
      updateDate: date.trim().isEmpty ? '—' : date.trim(),
      downloadUrl: dUrl,
      pageUrl: downloadUrl,
      downloadReferer: null,
    );
  }

  bool looksNewer(String remoteVersion, String? localVersion) {
    if (localVersion == null || localVersion.isEmpty) return true;
    final ra = _versionParts(remoteVersion);
    final la = _versionParts(localVersion);
    if (ra.isEmpty) return false;
    if (la.isEmpty) return true;
    final len = ra.length > la.length ? ra.length : la.length;
    for (var i = 0; i < len; i++) {
      final r = i < ra.length ? ra[i] : 0;
      final l = i < la.length ? la[i] : 0;
      if (r != l) return r > l;
    }
    return false;
  }

  List<int> _versionParts(String v) {
    return RegExp(r'\d+')
        .allMatches(v)
        .map((m) => int.tryParse(m.group(0)!) ?? 0)
        .toList();
  }

  /// When the CDN stores a gzip-wrapped APK/XAPK, bytes start with `1f 8b` instead of `PK`.
  /// Returns true if a gzip layer was removed.
  Future<bool> _gunzipFileInPlaceIfNeeded(File f) async {
    final head = await f.open(mode: FileMode.read);
    try {
      final b = await head.read(2);
      if (b.length < 2 || b[0] != 0x1f || b[1] != 0x8b) return false;
    } finally {
      await head.close();
    }

    final tmp = File('${f.path}.ungz');
    final sink = tmp.openWrite();
    try {
      await f.openRead().cast<List<int>>().transform(gzip.decoder).pipe(sink);
    } catch (e) {
      try {
        await sink.close();
      } catch (_) {}
      if (tmp.existsSync()) {
        try {
          await tmp.delete();
        } catch (_) {}
      }
      throw HttpException('Download looked gzip-compressed but failed to decompress: $e');
    }
    await sink.close();
    final outLen = await tmp.length();
    if (outLen < 4) {
      await tmp.delete();
      throw HttpException('Gzip decompression produced an empty file.');
    }
    await f.delete();
    try {
      await tmp.rename(f.path);
    } on FileSystemException {
      await tmp.copy(f.path);
      await tmp.delete();
    }
    return true;
  }

  bool _looksLikeZlibLead(List<int> raw) {
    if (raw.length < 2) return false;
    if (raw[0] != 0x78) return false;
    // ZLib CMF/FLG: (cmf*256+flg) divisible by 31 (RFC 1950).
    return ((raw[0] << 8) + raw[1]) % 31 == 0;
  }

  /// Raw deflate in zlib wrapper (some CDNs use this instead of gzip).
  /// Returns true if a zlib layer was removed.
  Future<bool> _unzlibFileInPlaceIfNeeded(File f) async {
    final head = await f.open(mode: FileMode.read);
    List<int> b;
    try {
      b = await head.read(2);
    } finally {
      await head.close();
    }
    if (!_looksLikeZlibLead(b)) return false;

    final tmp = File('${f.path}.unzlib');
    final sink = tmp.openWrite();
    try {
      await f.openRead().cast<List<int>>().transform(ZLibDecoder()).pipe(sink);
    } catch (e) {
      try {
        await sink.close();
      } catch (_) {}
      if (tmp.existsSync()) {
        try {
          await tmp.delete();
        } catch (_) {}
      }
      throw HttpException('Download looked zlib-compressed but failed to decompress: $e');
    }
    await sink.close();
    final outLen = await tmp.length();
    if (outLen < 4) {
      await tmp.delete();
      throw HttpException('Zlib decompression produced an empty file.');
    }
    await f.delete();
    try {
      await tmp.rename(f.path);
    } on FileSystemException {
      await tmp.copy(f.path);
      await tmp.delete();
    }
    return true;
  }

  /// Some responses prepend a short binary header before the ZIP (APK/XAPK) payload.
  Future<void> _stripZipLocalHeaderPrefixIfNeeded(File f) async {
    final len = await f.length();
    if (len < 8) return;
    const maxScan = 2097152;
    final scan = len < maxScan ? len.toInt() : maxScan;
    final raf = await f.open(mode: FileMode.read);
    List<int> prefix;
    try {
      await raf.setPosition(0);
      prefix = await raf.read(scan);
    } finally {
      await raf.close();
    }
    var off = -1;
    for (var i = 0; i + 4 <= prefix.length; i++) {
      if (prefix[i] == 0x50 &&
          prefix[i + 1] == 0x4b &&
          prefix[i + 2] == 0x03 &&
          prefix[i + 3] == 0x04) {
        off = i;
        break;
      }
    }
    if (off <= 0) return;

    final tmp = File('${f.path}.ziptrim');
    final sink = tmp.openWrite();
    try {
      sink.add(prefix.sublist(off));
      await for (final chunk in f.openRead(scan)) {
        sink.add(chunk);
      }
    } catch (e) {
      try {
        await sink.close();
      } catch (_) {}
      if (tmp.existsSync()) {
        try {
          await tmp.delete();
        } catch (_) {}
      }
      throw HttpException('Failed trimming non-ZIP prefix before APK payload: $e');
    }
    await sink.close();
    await f.delete();
    try {
      await tmp.rename(f.path);
    } on FileSystemException {
      await tmp.copy(f.path);
      await tmp.delete();
    }
  }

  Future<void> _normalizeDownloadedArchive(File f) async {
    final head = await f.open(mode: FileMode.read);
    List<int> h4;
    try {
      await head.setPosition(0);
      h4 = await head.read(4);
    } finally {
      await head.close();
    }
    // Raw APK / XAPK is a ZIP starting with a local file header — never gzip/zlib/strip it.
    // Extra transforms have caused corrupt installs for otherwise-valid store downloads.
    if (h4.length >= 4 && h4[0] == 0x50 && h4[1] == 0x4b && h4[2] == 0x03 && h4[3] == 0x04) {
      return;
    }
    for (var i = 0; i < 8; i++) {
      if (await _gunzipFileInPlaceIfNeeded(f)) continue;
      if (await _unzlibFileInPlaceIfNeeded(f)) continue;
      break;
    }
    await _stripZipLocalHeaderPrefixIfNeeded(f);
  }

  bool _curlPathCached = false;
  String? _curlPathResolved;

  /// System `curl` is used first (Windows 10+ ships it) — it handles TLS, redirects, and
  /// `Content-Encoding` more reliably than ad-hoc Dart streaming for large APK/XAPK payloads.
  Future<String?> _findCurlExecutable() async {
    if (_curlPathCached) return _curlPathResolved;
    _curlPathCached = true;

    if (Platform.isWindows) {
      final root = Platform.environment['SystemRoot'] ??
          Platform.environment['SYSTEMROOT'] ??
          r'C:\Windows';
      final bundled = '$root${Platform.pathSeparator}System32${Platform.pathSeparator}curl.exe';
      if (File(bundled).existsSync()) {
        _curlPathResolved = bundled;
        return bundled;
      }
      try {
        final r = await Process.run(
          'where',
          ['curl'],
          runInShell: false,
        );
        if (r.exitCode == 0) {
          final out = (r.stdout as String).trim();
          final lines = out.split(RegExp(r'[\r\n]+')).where((s) => s.trim().isNotEmpty).toList();
          if (lines.isNotEmpty) {
            final pth = lines.first.trim();
            if (pth.isNotEmpty && File(pth).existsSync()) {
              _curlPathResolved = pth;
              return pth;
            }
          }
        }
      } catch (_) {}
      _curlPathResolved = null;
      return null;
    }
    try {
      final r = await Process.run('which', ['curl'], runInShell: false);
      if (r.exitCode != 0) {
        _curlPathResolved = null;
        return null;
      }
      final pth = (r.stdout as String).trim().split('\n').first.trim();
      if (pth.isEmpty) {
        _curlPathResolved = null;
        return null;
      }
      _curlPathResolved = pth;
      return pth;
    } catch (_) {
      _curlPathResolved = null;
      return null;
    }
  }

  Future<void> _assertPartialNotHtmlGate(File partial) async {
    final len = await partial.length();
    if (len < 32) return;
    final peek = len < 1024 ? len.toInt() : 1024;
    final raf = await partial.open(mode: FileMode.read);
    List<int> head;
    try {
      await raf.setPosition(0);
      head = await raf.read(peek);
    } finally {
      await raf.close();
    }
    if (_looksLikeHtmlLead(head)) {
      throw HttpException(
        'Server returned a web page instead of an APK '
        '(CDN blocked, expired link, or wrong URL).',
      );
    }
  }

  Future<File> _finalizeArchivePartialToDestination(
    File partial,
    File destination, {
    void Function(int received, int? total)? onProgress,
    int? declaredRawLengthHint,
    String? responseContentEncodingHeader,
    bool enforceDeclaredLengthAgainstRawBytes = true,
  }) async {
    final onDisk = await partial.length();
    if (onDisk == 0) {
      throw HttpException('Download empty (0 bytes written).');
    }
    if (enforceDeclaredLengthAgainstRawBytes &&
        declaredRawLengthHint != null &&
        declaredRawLengthHint > 0) {
      final enc = responseContentEncodingHeader?.toLowerCase().trim();
      if (enc != 'gzip' && enc != 'deflate' && enc != 'br') {
        if (onDisk + 4096 < declaredRawLengthHint) {
          throw HttpException(
            'Download truncated (got $onDisk bytes, server announced $declaredRawLengthHint). '
            'Try again or use another store.',
          );
        }
      }
    }
    onProgress?.call(onDisk, declaredRawLengthHint);

    await _assertPartialNotHtmlGate(partial);
    await _normalizeDownloadedArchive(partial);

    final size = await partial.length();
    if (size < 22) {
      throw HttpException('Download empty or too small to be a ZIP ($size bytes).');
    }
    if (!await XapkService.fileLooksLikeOpenableZip(partial)) {
      final raf = await partial.open(mode: FileMode.read);
      List<int> sig;
      try {
        await raf.setPosition(0);
        sig = await raf.read(8);
      } finally {
        await raf.close();
      }
      final hex = sig.map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ');
      throw HttpException(
        'Download is not a valid APK/XAPK (not a readable ZIP after transfer). '
        'Got $size bytes; first bytes: $hex. '
        'Try Search again for a fresh link, or use APKCombo / Uptodown for this app.',
      );
    }

    if (destination.existsSync()) {
      try {
        await destination.delete();
      } catch (_) {}
    }
    try {
      await partial.rename(destination.path);
    } on FileSystemException {
      await partial.copy(destination.path);
      await partial.delete();
    }
    return destination;
  }

  /// Writes [finalUrlString] bytes to [partial]; follows redirects (`-L`) and decodes
  /// `Content-Encoding` when present (`--compressed`).
  Future<void> _downloadUrlToPartialWithCurl({
    required String executable,
    required String finalUrlString,
    required File partial,
    required String referer,
    CancellationToken? cancel,
    void Function(Process started)? onProcessStarted,
    void Function()? onProcessEnded,
    void Function(int received, int? total)? onProgress,
  }) async {
    if (partial.existsSync()) {
      try {
        await partial.delete();
      } catch (_) {}
    }

    final args = <String>[
      '-fLsS',
      '--compressed',
      '--http1.1',
      '--connect-timeout', '60',
      '--max-redirs', '20',
      '-H',
      'User-Agent: $_ua',
      '-H',
      'Accept: application/vnd.android.package-archive,application/octet-stream;q=0.9,*/*;q=0.8',
      '-H',
      'Accept-Language: en-US,en;q=0.9',
      '-H',
      'Referer: $referer',
      '-o',
      partial.path,
      finalUrlString,
    ];

    final refUri = Uri.tryParse(referer);
    if (refUri != null && refUri.hasScheme && refUri.host.isNotEmpty) {
      args.insertAll(args.length - 2, ['-H', 'Origin: ${refUri.scheme}://${refUri.host}']);
    }

    final proc = await Process.start(executable, args, mode: ProcessStartMode.normal);
    onProcessStarted?.call(proc);

    Timer? tick;
    if (onProgress != null) {
      tick = Timer.periodic(const Duration(milliseconds: 450), (_) {
        if (!partial.existsSync()) return;
        try {
          final len = partial.lengthSync();
          onProgress(len, null);
        } catch (_) {}
      });
    }

    final stderrFuture = proc.stderr.transform(utf8.decoder).join();
    proc.stdout.listen((_) {});

    final code = await proc.exitCode;
    tick?.cancel();
    onProcessEnded?.call();

    final stderrText = await stderrFuture;

    cancel?.throwIfCancelled();
    if (code != 0) {
      if (cancel?.isCancelled ?? false) {
        throw OperationCanceled();
      }
      if (partial.existsSync()) {
        try {
          await partial.delete();
        } catch (_) {}
      }
      final msg = stderrText.trim().isEmpty ? '(no stderr)' : stderrText.trim();
      throw HttpException('curl exited with code $code: $msg');
    }
    if (!partial.existsSync() || await partial.length() == 0) {
      throw HttpException('Download produced empty file (curl OK but 0 bytes on disk).');
    }
    onProgress?.call(await partial.length(), await partial.length());
  }

  Future<File> downloadToFile(
    String url,
    File destination, {
    String? referer,
    void Function(int received, int? total)? onProgress,
    CancellationToken? cancel,
  }) async {
    // Downloads use `curl` or [_httpBinaryDownloadClient], not [_client]. [_warmSession] only hits
    // APKPure HTML via [_client], so awaiting it here only delayed transfer start without helping CDN fetches.
    final partial = File('${destination.path}.partial');
    if (partial.existsSync()) {
      try {
        await partial.delete();
      } catch (_) {}
    }

    IOSink? sink;
    HttpClientRequest? liveReq;
    Process? curlProc;

    try {
      cancel?.abortHook = () {
        try {
          liveReq?.abort();
        } catch (_) {}
        try {
          curlProc?.kill();
        } catch (_) {}
      };

      final ref = referer ?? 'https://apkpure.com/';
      final curlExe = await _findCurlExecutable();

      if (curlExe != null) {
        try {
          await _downloadUrlToPartialWithCurl(
            executable: curlExe,
            finalUrlString: url,
            partial: partial,
            referer: ref,
            cancel: cancel,
            onProcessStarted: (p) => curlProc = p,
            onProcessEnded: () => curlProc = null,
            onProgress: onProgress,
          );
          return await _finalizeArchivePartialToDestination(
            partial,
            destination,
            onProgress: onProgress,
            enforceDeclaredLengthAgainstRawBytes: false,
          );
        } on OperationCanceled {
          rethrow;
        } on HttpException {
          if (partial.existsSync()) {
            try {
              await partial.delete();
            } catch (_) {}
          }
          // Curl can fail on TLS/proxy quirks; retry with raw Dart HTTP below.
        }
      }

      var uri = Uri.parse(url);
      const maxHops = 20;
      for (var hop = 0; hop < maxHops; hop++) {
        cancel?.throwIfCancelled();
        liveReq = await _httpBinaryDownloadClient.getUrl(uri);
        liveReq.followRedirects = false;
        liveReq.headers.set(HttpHeaders.userAgentHeader, _ua);
        liveReq.headers.set(
          HttpHeaders.acceptHeader,
          'application/vnd.android.package-archive,application/octet-stream;q=0.9,*/*;q=0.8',
        );
        liveReq.headers.set(HttpHeaders.acceptLanguageHeader, 'en-US,en;q=0.9');
        liveReq.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
        liveReq.headers.set(HttpHeaders.refererHeader, ref);
        final refUri = Uri.tryParse(ref);
        if (refUri != null && refUri.hasScheme && refUri.host.isNotEmpty) {
          liveReq.headers.set('Origin', '${refUri.scheme}://${refUri.host}');
        }
        liveReq.headers.set('Sec-Fetch-Dest', 'empty');
        liveReq.headers.set('Sec-Fetch-Mode', 'cors');
        liveReq.headers.set('Sec-Fetch-Site', 'cross-site');
        liveReq.headers.set('sec-ch-ua', '"Google Chrome";v="131", "Chromium";v="131", "Not_A Brand";v="24"');
        liveReq.headers.set('sec-ch-ua-mobile', '?0');
        liveReq.headers.set('sec-ch-ua-platform', '"Windows"');

        final res = await liveReq.close();
        liveReq = null;

        if (res.statusCode >= 300 && res.statusCode < 400) {
          final loc = res.headers.value(HttpHeaders.locationHeader);
          if (loc == null || loc.isEmpty) {
            throw HttpException('HTTP ${res.statusCode} redirect without Location for $uri');
          }
          uri = uri.resolve(loc);
          await res.drain();
          continue;
        }

        if (res.statusCode >= 400) {
          throw HttpException('Download failed HTTP ${res.statusCode} for $uri');
        }

        final totalHint = res.contentLength >= 0 ? res.contentLength : null;
        final encodingHeader =
            res.headers.value(HttpHeaders.contentEncodingHeader)?.toLowerCase().trim();

        final out = partial.openWrite();
        sink = out;
        var received = 0;
        try {
          await for (final chunk in res) {
            cancel?.throwIfCancelled();
            out.add(chunk);
            received += chunk.length;
            onProgress?.call(received, totalHint);
          }
        } finally {
          await out.close();
          sink = null;
        }

        return await _finalizeArchivePartialToDestination(
          partial,
          destination,
          onProgress: onProgress,
          declaredRawLengthHint: totalHint,
          responseContentEncodingHeader: encodingHeader,
          enforceDeclaredLengthAgainstRawBytes: true,
        );
      }
      throw HttpException('Too many HTTP redirects while downloading.');
    } on OperationCanceled {
      try {
        await sink?.close();
      } catch (_) {}
      if (partial.existsSync()) {
        try {
          await partial.delete();
        } catch (_) {}
      }
      rethrow;
    } catch (e) {
      try {
        await sink?.close();
      } catch (_) {}
      if (partial.existsSync()) {
        try {
          await partial.delete();
        } catch (_) {}
      }
      rethrow;
    } finally {
      cancel?.abortHook = null;
    }
  }

  String? _extractTitle(String body) {
    final doc = html_parser.parse(body);
    final h1 = doc.querySelector('h1');
    if (h1 != null) {
      final t = h1.text.replaceAll(RegExp(r'\s+'), ' ').trim();
      if (t.isNotEmpty) return t;
    }
    final m = RegExp(r'<title>([^<]{3,120})</title>', caseSensitive: false).firstMatch(body);
    return m?.group(1)?.split('-').first.trim();
  }

  String? _firstMatch(String body, List<RegExp> patterns) {
    for (final re in patterns) {
      final m = re.firstMatch(body);
      if (m != null && m.group(1)!.trim().isNotEmpty) return m.group(1)!.trim();
    }
    return null;
  }

  String _humanizeSlug(String slug) {
    return slug
        .split('-')
        .where((s) => s.isNotEmpty)
        .map((s) => '${s[0].toUpperCase()}${s.substring(1)}')
        .join(' ');
  }

  void close() {
    _client.close(force: true);
    _httpBinaryDownloadClient.close(force: true);
  }
}
