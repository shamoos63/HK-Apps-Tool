import 'dart:convert';
import 'dart:io';

import 'package:html/parser.dart' as html_parser;

import 'apkpure_service.dart';
import 'cancellation.dart';

/// Search and downloads via [apkcombo.com](https://apkcombo.com).
///
/// Direct APK/XAPK links are short-lived signed URLs on Cloudflare R2. The site
/// wraps them in `https://apkcombo.com/r2?u=<encoded-url>`. This service loads
/// the `/download/apk` HTML each time and extracts that wrapper link (same idea
/// as refreshing the page in a browser).
class ApkcomboSearchService {
  static const _ua =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36';

  static const _origin = 'https://apkcombo.com';
  static const _locale = 'en';

  final HttpClient _client = HttpClient()
    ..userAgent = _ua
    ..autoUncompress = true
    ..connectionTimeout = const Duration(seconds: 25);

  static final _r2HrefRe = RegExp(
    r'https://apkcombo\.com/r2\?[^"\s<>]+',
    caseSensitive: false,
  );

  bool _warmed = false;

  Future<void> _warm({CancellationToken? cancel}) async {
    if (_warmed) return;
    try {
      await _get(Uri.parse('$_origin/$_locale/'), referer: '', cancel: cancel);
    } catch (_) {}
    _warmed = true;
  }

  Future<String> _get(Uri uri, {required String referer, CancellationToken? cancel}) async {
    cancel?.throwIfCancelled();
    final req = await _client.getUrl(uri);
    req.headers.set(
      HttpHeaders.acceptHeader,
      'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
    );
    req.headers.set(HttpHeaders.acceptLanguageHeader, 'en-US,en;q=0.9');
    req.headers.set('Accept-Encoding', 'gzip, deflate');
    if (referer.isNotEmpty) {
      req.headers.set(HttpHeaders.refererHeader, referer);
    }
    req.headers.set('Upgrade-Insecure-Requests', '1');
    req.headers.set('Sec-Fetch-Dest', 'document');
    req.headers.set('Sec-Fetch-Mode', 'navigate');
    req.headers.set('Sec-Fetch-Site', referer.isEmpty ? 'none' : 'cross-site');
    cancel?.throwIfCancelled();
    final res = await req.close();
    final body = await res.transform(utf8.decoder).join();
    if (res.statusCode >= 400) {
      throw HttpException('HTTP ${res.statusCode} for $uri');
    }
    return body;
  }

  /// Parses `/{slug}/{package}/` or `/{locale}/{slug}/{package}/` listing paths.
  static (String slug, String packageId)? parseListing(Uri uri) {
    if (!uri.host.toLowerCase().endsWith('apkcombo.com')) return null;
    final segs = uri.pathSegments.where((s) => s.isNotEmpty).toList();
    if (segs.isEmpty) return null;
    var i = 0;
    if (segs.length >= 3 &&
        segs[i].length == 2 &&
        segs[i] == segs[i].toLowerCase() &&
        !segs[i + 1].contains('.')) {
      i++;
    }
    if (i + 1 >= segs.length) return null;
    final slug = segs[i];
    final pkg = segs[i + 1];
    if (!pkg.contains('.')) return null;
    const reserved = {'search', 'r2', 'download', 'apk', 'xapk', 'android-emulator', 'categories', 'policy'};
    if (reserved.contains(slug.toLowerCase())) return null;
    return (slug, pkg);
  }

  String _canonicalAppUrl(String slug, String packageId) => '$_origin/$_locale/$slug/$packageId/';

  List<ApkpureSearchHit> _hitsFromBody(String body) {
    final seen = <String>{};
    final hits = <ApkpureSearchHit>[];

    void add(String slug, String packageId, String title) {
      if (!seen.add(packageId)) return;
      hits.add(
        ApkpureSearchHit(
          title: title.trim().isEmpty ? slug.replaceAll('-', ' ') : title.trim(),
          pageUrl: _canonicalAppUrl(slug, packageId),
          packageId: packageId,
          slug: slug,
          isApkcombo: true,
        ),
      );
    }

    final doc = html_parser.parse(body);
    for (final a in doc.querySelectorAll('a[href]')) {
      final href = a.attributes['href'];
      if (href == null) continue;
      final abs = href.startsWith('http') ? href : '$_origin$href';
      final u = Uri.tryParse(abs);
      if (u == null) continue;
      final parsed = parseListing(u);
      if (parsed == null) continue;
      final t = a.text.replaceAll(RegExp(r'\s+'), ' ').trim();
      add(parsed.$1, parsed.$2, t);
    }

    for (final m in _hrefRegex.allMatches(body)) {
      final u = Uri.tryParse(m.group(1)!);
      if (u == null) continue;
      final parsed = parseListing(u);
      if (parsed == null) continue;
      add(parsed.$1, parsed.$2, parsed.$1.replaceAll('-', ' '));
    }

    return hits;
  }

  static final _hrefRegex = RegExp(
    r'(https://apkcombo\.com/(?:[a-z]{2}/)?[\w-]+/(?:[\w]+\.)+[\w]+)/?(?:["\s<>#]|$)',
    caseSensitive: false,
  );

  Future<List<ApkpureSearchHit>> search(String query, {CancellationToken? cancel}) async {
    final q = query.trim();
    if (q.isEmpty) return [];
    cancel?.throwIfCancelled();
    await _warm(cancel: cancel);

    if (ApkpureService.looksLikeAndroidPackageId(q)) {
      try {
        cancel?.throwIfCancelled();
        final uri = Uri.parse('$_origin/$_locale/search?q=${Uri.encodeQueryComponent(q)}');
        final body = await _get(uri, referer: _origin, cancel: cancel);
        final hits = _hitsFromBody(body).where((h) => h.packageId == q).toList();
        if (hits.isNotEmpty) return hits;
      } on OperationCanceled {
        rethrow;
      } catch (_) {}
    }

    cancel?.throwIfCancelled();
    final uri = Uri.parse('$_origin/$_locale/search?q=${Uri.encodeQueryComponent(q)}');
    final body = await _get(uri, referer: _origin, cancel: cancel);
    return _hitsFromBody(body);
  }

  String? _firstR2Wrapper(String html) {
    final doc = html_parser.parse(html);
    for (final a in doc.querySelectorAll('a[href]')) {
      final href = a.attributes['href'];
      if (href == null || !href.contains('/r2?')) continue;
      final abs = href.startsWith('http') ? href : '$_origin$href';
      if (!abs.contains('u=')) continue;
      return abs.split('#').first;
    }
    final m = _r2HrefRe.firstMatch(html);
    return m?.group(0)?.split('#').first;
  }

  static String? _versionFromSignedStorageUrl(String storageUrl, String packageId) {
    try {
      final u = Uri.parse(storageUrl);
      final parts = u.pathSegments.where((s) => s.isNotEmpty).toList();
      if (parts.length >= 3 && parts[0] == packageId) {
        return parts[1];
      }
      if (parts.length >= 2 && parts[0].contains('.')) {
        return parts[1];
      }
    } catch (_) {}
    return null;
  }

  static String? _versionFromR2Wrapper(String wrapperUrl, String packageId) {
    try {
      final outer = Uri.parse(wrapperUrl);
      final innerStr = outer.queryParameters['u'];
      if (innerStr == null || innerStr.isEmpty) return null;
      return _versionFromSignedStorageUrl(innerStr, packageId);
    } catch (_) {}
    return null;
  }

  Future<ApkpureReleaseInfo> fetchRelease(ApkpureSearchHit hit) async {
    final dlPage = '$_origin/$_locale/${hit.slug}/${hit.packageId}/download/apk';
    final body = await _get(Uri.parse(dlPage), referer: hit.pageUrl);
    final wrap = _firstR2Wrapper(body);
    if (wrap == null || wrap.isEmpty) {
      throw HttpException(
        'APKCombo: no r2 download link found on the APK page (layout may have changed).',
      );
    }

    final doc = html_parser.parse(body);
    var title = doc.querySelector('h1')?.text.replaceAll(RegExp(r'\s+'), ' ').trim();
    title = (title == null || title.isEmpty) ? hit.title : title;
    title = title.split(' - ').first.trim();

    final version = _versionFromR2Wrapper(wrap, hit.packageId) ?? '—';

    return ApkpureReleaseInfo(
      title: title,
      version: version,
      updateDate: '—',
      downloadUrl: wrap,
      pageUrl: dlPage,
      downloadReferer: dlPage,
    );
  }

  void close() => _client.close(force: true);
}
