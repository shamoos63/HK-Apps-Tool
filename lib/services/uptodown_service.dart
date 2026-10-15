import 'dart:convert';
import 'dart:io';

import 'package:html/parser.dart' as html_parser;

import 'apkpure_service.dart';
import 'cancellation.dart';
/// Search and release metadata from Uptodown (fallback when APKPure blocks with 403).
class UptodownSearchService {
  static const _ua =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36';

  final HttpClient _client = HttpClient()
    ..userAgent = _ua
    ..autoUncompress = true
    ..connectionTimeout = const Duration(seconds: 25);

  static String _secFetchSiteFor(Uri uri, String referer) {
    if (referer.isEmpty) return 'none';
    final r = Uri.tryParse(referer);
    if (r == null || !r.hasScheme || r.host.isEmpty) return 'cross-site';
    final a = uri.host.toLowerCase();
    final b = r.host.toLowerCase();
    if (a == b) return 'same-origin';
    // e.g. en.uptodown.com → app.en.uptodown.com is not same-origin; lying "same-origin" can get the socket dropped.
    if (a.endsWith('uptodown.com') && b.endsWith('uptodown.com')) return 'same-site';
    return 'cross-site';
  }

  static bool _isTransientGetFailure(Object e) {
    final msg = e.toString().toLowerCase();
    return e is SocketException ||
        e is HandshakeException ||
        msg.contains('connection closed') ||
        msg.contains('connection reset') ||
        msg.contains('broken pipe') ||
        msg.contains('timed out');
  }

  Future<String> _get(Uri uri, {required String referer, CancellationToken? cancel}) async {
    Object? lastErr;
    for (var attempt = 0; attempt < 3; attempt++) {
      if (attempt > 0) {
        await Future<void>.delayed(Duration(milliseconds: 250 * attempt));
      }
      try {
        return await _getOnce(uri, referer: referer, cancel: cancel);
      } catch (e) {
        lastErr = e;
        cancel?.throwIfCancelled();
        if (!_isTransientGetFailure(e) || attempt >= 2) rethrow;
      }
    }
    throw lastErr!;
  }

  Future<String> _getOnce(Uri uri, {required String referer, CancellationToken? cancel}) async {
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
    req.headers.set('Sec-Fetch-Site', _secFetchSiteFor(uri, referer));
    cancel?.throwIfCancelled();
    final res = await req.close();
    final body = await res.transform(utf8.decoder).join();
    if (res.statusCode >= 400) {
      throw HttpException('HTTP ${res.statusCode} for $uri');
    }
    return body;
  }

  static String? _packageIdFromAppUrl(String url) {
    final u = Uri.tryParse(url);
    if (u == null) return null;
    final host = u.host.toLowerCase();
    const suf = '.en.uptodown.com';
    if (!host.endsWith(suf)) return null;
    final sub = host.substring(0, host.length - suf.length);
    if (sub.isEmpty) return null;
    return sub.replaceAll('-', '.');
  }

  bool _warmed = false;

  Future<void> _warm({CancellationToken? cancel}) async {
    if (_warmed) return;
    try {
      await _get(Uri.parse('https://en.uptodown.com/'), referer: '', cancel: cancel);
    } catch (_) {}
    _warmed = true;
  }

  Future<List<ApkpureSearchHit>> search(String query, {CancellationToken? cancel}) async {
    final q = query.trim();
    if (q.isEmpty) return [];
    cancel?.throwIfCancelled();
    await _warm(cancel: cancel);
    final encoded = Uri.encodeQueryComponent(q);
    // Site form uses `query` (see #searchForm on /android); `q` returns 404/410.
    final urls = [
      Uri.parse('https://en.uptodown.com/android/search?query=$encoded'),
    ];
    HttpException? last;
    for (final uri in urls) {
      cancel?.throwIfCancelled();
      try {
        final body = await _get(uri, referer: 'https://en.uptodown.com/', cancel: cancel);
        final hits = _parseSearch(body);
        if (hits.isNotEmpty) return hits;
      } on OperationCanceled {
        rethrow;
      } on HttpException catch (e) {
        last = e;
      }
    }
    cancel?.throwIfCancelled();
    throw last ?? HttpException('Uptodown search failed');
  }

  List<ApkpureSearchHit> _parseSearch(String body) {
    final seen = <String>{};
    final hits = <ApkpureSearchHit>[];
    final doc = html_parser.parse(body);
    for (final a in doc.querySelectorAll('a[href]')) {
      final href = a.attributes['href'];
      if (href == null) continue;
      final abs = href.startsWith('http') ? href : 'https://en.uptodown.com$href';
      if (!abs.contains('.en.uptodown.com/android')) continue;
      if (abs.contains('/download')) continue;
      final pkg = _packageIdFromAppUrl(abs);
      if (pkg == null || !pkg.contains('.')) continue;
      if (!seen.add(pkg)) continue;
      final title = a.text.replaceAll(RegExp(r'\s+'), ' ').trim();
      hits.add(
        ApkpureSearchHit(
          title: title.isEmpty ? pkg : title,
          pageUrl: abs.split('#').first,
          packageId: pkg,
          slug: 'uptodown',
          isUptodown: true,
        ),
      );
    }
    final re = RegExp(
      r'https://[a-z0-9\-]+\.en\.uptodown\.com/android(?!/download)[^"\s<>]*',
      caseSensitive: false,
    );
    for (final m in re.allMatches(body)) {
      final abs = m.group(0)!;
      final pkg = _packageIdFromAppUrl(abs);
      if (pkg == null || !seen.add(pkg)) continue;
      hits.add(
        ApkpureSearchHit(
          title: pkg,
          pageUrl: abs.split('#').first,
          packageId: pkg,
          slug: 'uptodown',
          isUptodown: true,
        ),
      );
    }
    return hits;
  }

  static final _dwUrlRes = <RegExp>[
    RegExp(r'(https://dw\.[^\s"<>]+\.apk[^\s"<>]*)', caseSensitive: false),
    RegExp(r'(https://dw\.[^\s"<>]+)', caseSensitive: false),
    RegExp(r'(https://[^"\s<>]*uptodown[^"\s<>]*\.apk[^"\s<>]*)', caseSensitive: false),
  ];

  /// Current Uptodown download pages put a signed path token on `#detail-download-button`
  /// and resolve it in-browser as `https://dw.uptodown.com/dwn/{token}` (see their download.js).
  String? _pickDownloadUrlFromDetailButton(String html) {
    final doc = html_parser.parse(html);
    final btn = doc.querySelector('#detail-download-button') ??
        doc.querySelector('button.button.download[data-url]');
    if (btn == null) return null;
    final ext = btn.attributes['data-url-ext']?.trim();
    if (ext != null && ext.startsWith('http')) {
      return ext.split('#').first;
    }
    final token = btn.attributes['data-url']?.trim();
    if (token == null || token.isEmpty || token == 'apps') return null;
    return 'https://dw.uptodown.com/dwn/$token';
  }

  String? _pickDownloadUrl(String html) {
    final fromBtn = _pickDownloadUrlFromDetailButton(html);
    if (fromBtn != null && fromBtn.isNotEmpty) return fromBtn;
    for (final re in _dwUrlRes) {
      final m = re.firstMatch(html);
      if (m != null && m.group(1)!.contains('dw.')) return m.group(1)!.trim();
    }
    return null;
  }

  Future<ApkpureReleaseInfo> fetchRelease(ApkpureSearchHit hit) async {
    final appUri = Uri.parse(hit.pageUrl);
    final body = await _get(appUri, referer: 'https://en.uptodown.com/');
    final doc = html_parser.parse(body);
    final title = doc.querySelector('h1')?.text.trim() ?? hit.title;

    var version = _pick(
      body,
      [
        RegExp(r'itemprop="softwareVersion"[^>]*>([^<]+)', caseSensitive: false),
        RegExp(r'"softwareVersion"\s*:\s*"([^"]+)"'),
        RegExp(r'Latest version[^0-9]*(\d[\d.]+\d)', caseSensitive: false),
        RegExp(r'\b(\d+\.\d+\.\d+\.\d+)\b'),
      ],
    ) ??
        '—';

    var date = _pick(
      body,
      [
        RegExp(r'Latest update[^0-9A-Za-z]+((?:Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)\s+\d{1,2},\s+\d{4})',
            caseSensitive: false),
        RegExp(r'(\d{4}-\d{2}-\d{2})'),
      ],
    ) ??
        '—';

    var dl = _pickDownloadUrl(body);
    final appBase = hit.pageUrl.split('?').first.replaceAll(RegExp(r'/+$'), '');
    final downloadLanding = '$appBase/download';

    // App page often has no token; the /android/download HTML has #detail-download-button.
    if (dl == null || !dl.toLowerCase().contains('dw.uptodown.com')) {
      try {
        final dlBody = await _get(Uri.parse(downloadLanding), referer: hit.pageUrl);
        dl = _pickDownloadUrl(dlBody) ?? dl;
      } catch (_) {}
    }

    if (dl == null || !dl.toLowerCase().contains('dw.uptodown.com')) {
      throw HttpException(
        'No Uptodown download link found for ${hit.title}. The site layout may have changed — try APKCombo from Search.',
      );
    }

    return ApkpureReleaseInfo(
      title: title,
      version: version,
      updateDate: date,
      downloadUrl: dl,
      pageUrl: hit.pageUrl,
      downloadReferer: downloadLanding,
    );
  }

  String? _pick(String body, List<RegExp> patterns) {
    for (final re in patterns) {
      final m = re.firstMatch(body);
      if (m != null && m.group(1)!.trim().isNotEmpty) return m.group(1)!.trim();
    }
    return null;
  }

  void close() => _client.close(force: true);
}
