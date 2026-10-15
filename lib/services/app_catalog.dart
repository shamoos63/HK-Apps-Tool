import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'apkpure_service.dart';
import 'cancellation.dart';
import 'uptodown_service.dart';

/// Where a download comes from.
enum StoreSource {
  apkpure('APKPure'),
  aptoide('Aptoide'),
  fdroid('F-Droid');

  const StoreSource(this.label);
  final String label;
}

/// One app found by search (merged across sources by package name).
class AppListing {
  AppListing({required this.packageId, required this.title, this.iconUrl, this.developer});

  final String packageId;
  String title;
  String? iconUrl;
  String? developer;

  /// Which catalogue surfaced this result (Google Play / Aptoide / Uptodown).
  final Set<String> foundVia = {};

  /// Uptodown app page, when Uptodown returned this app.
  String? uptodownPage;
}

/// One downloadable file of an option. [zipEntry] is set when several files are packed into one XAPK.
class DownloadPart {
  DownloadPart({required this.url, this.size, this.md5, this.zipEntry, this.referer, this.userAgent});

  final String url;
  final int? size;
  final String? md5;
  final String? zipEntry;
  final String? referer;
  final String? userAgent;
}

/// A concrete build that can be downloaded: version, size, and the file(s) to fetch.
class DownloadOption {
  DownloadOption({
    required this.source,
    required this.packageId,
    required this.title,
    required this.versionName,
    this.versionCode,
    required this.parts,
    this.isBundle = false,
    this.signer,
    this.warning,
    this.iconUrl,
    this.updated,
  });

  final StoreSource source;
  final String packageId;
  final String title;
  final String versionName;
  final int? versionCode;

  /// First part is the APK / XAPK; extra parts (OBB) are packed into one `.xapk` with it.
  final List<DownloadPart> parts;

  /// XAPK / split bundle (or APK + OBB that will be saved as `.xapk`).
  final bool isBundle;
  final String? signer;
  String? warning;
  final String? iconUrl;
  final String? updated;

  int? get totalSize {
    var t = 0;
    for (final p in parts) {
      if (p.size == null) return null;
      t += p.size!;
    }
    return t;
  }

  bool get hasObb => parts.length > 1;
  String get extension => (isBundle || hasObb) ? 'xapk' : 'apk';
}

/// Searches several catalogues at once and lists every downloadable build for an app.
///
/// * Google Play search turns an app *name* into exact package names (what users type rarely
///   matches mirror-site slugs, which is why searches used to come back empty).
/// * APKPure's mobile API (the web site is behind a Cloudflare challenge) gives XAPK/APK links.
/// * Aptoide's public JSON API gives APKs, OBB files and MD5 checksums.
/// * Uptodown helps find apps by name; its downloads now sit behind a Cloudflare Turnstile
///   check, so they are only offered as "open in browser".
/// * F-Droid covers open-source apps.
class AppCatalog {
  AppCatalog({UptodownSearchService? uptodown}) : _uptodown = uptodown ?? UptodownSearchService();

  static final AppCatalog shared = AppCatalog();

  static const _webUa =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36';
  static const apkpureUa = 'okhttp/3.12.1';

  final UptodownSearchService _uptodown;
  final HttpClient _http = HttpClient()
    ..autoUncompress = true
    ..connectionTimeout = const Duration(seconds: 15)
    ..idleTimeout = const Duration(seconds: 20);

  static bool looksLikePackageId(String q) => ApkpureService.looksLikeAndroidPackageId(q);

  Future<({int status, String body})> _get(
    String url, {
    String ua = _webUa,
    Map<String, String> headers = const {},
    Duration timeout = const Duration(seconds: 20),
    CancellationToken? cancel,
  }) async {
    cancel?.throwIfCancelled();
    final req = await _http.getUrl(Uri.parse(url)).timeout(timeout);
    req.headers.set(HttpHeaders.userAgentHeader, ua);
    req.headers.set(HttpHeaders.acceptLanguageHeader, 'en-US,en;q=0.9');
    headers.forEach(req.headers.set);
    final res = await req.close().timeout(timeout);
    final bytes = await res.fold<BytesBuilder>(BytesBuilder(copy: false), (b, c) => b..add(c)).timeout(timeout);
    cancel?.throwIfCancelled();
    return (status: res.statusCode, body: latin1.decode(bytes.takeBytes()));
  }

  Future<Map<String, dynamic>?> _json(String url, {CancellationToken? cancel}) async {
    final r = await _get(url, cancel: cancel);
    if (r.status >= 400) return null;
    final decoded = json.decode(utf8.decode(latin1.encode(r.body), allowMalformed: true));
    return decoded is Map<String, dynamic> ? decoded : null;
  }

  // ───────────────────────────── search ─────────────────────────────

  /// Merged search. Results that Google Play knows come first (best name matching), then
  /// anything only the mirrors have (region-locked, delisted, or modded builds).
  Future<List<AppListing>> search(String query, {CancellationToken? cancel}) async {
    var last = <AppListing>[];
    await for (final snapshot in searchStream(query, cancel: cancel)) {
      last = snapshot;
    }
    return last;
  }

  /// Like [search], but yields the merged list each time another catalogue answers,
  /// so the UI can show Google Play hits while slower mirrors are still loading.
  Stream<List<AppListing>> searchStream(String query, {CancellationToken? cancel}) async* {
    final q = query.trim();
    if (q.isEmpty) return;
    final byPkg = <String, AppListing>{};
    final order = <String>[];

    void add(Iterable<AppListing> list, String via) {
      for (final l in list) {
        final existing = byPkg[l.packageId];
        if (existing == null) {
          byPkg[l.packageId] = l..foundVia.add(via);
          order.add(l.packageId);
        } else {
          existing.foundVia.add(via);
          existing.iconUrl ??= l.iconUrl;
          existing.developer ??= l.developer;
          existing.uptodownPage ??= l.uptodownPage;
          if (existing.title == existing.packageId) existing.title = l.title;
        }
      }
    }

    Future<List<AppListing>> guard(Future<List<AppListing>> f) =>
        f.timeout(const Duration(seconds: 15)).catchError((Object e) {
          if (e is OperationCanceled) throw e;
          return <AppListing>[];
        });

    // Merge in a fixed priority order (exact package, Play, Aptoide, Uptodown) whatever order they finish in.
    final sources = <(String, Future<List<AppListing>>)>[
      if (looksLikePackageId(q)) ('Package', Future.value([AppListing(packageId: q, title: q)])),
      ('Google Play', guard(_playSearch(q, cancel: cancel))),
      ('Aptoide', guard(_aptoideSearch(q, cancel: cancel))),
      ('Uptodown', guard(_uptodownSearch(q, cancel: cancel))),
    ];
    final done = List<List<AppListing>?>.filled(sources.length, null);
    final ticks = StreamController<void>();
    var remaining = sources.length;
    for (var i = 0; i < sources.length; i++) {
      final idx = i;
      sources[i].$2.then((v) => done[idx] = v, onError: (_) => done[idx] = const []).whenComplete(() {
        remaining--;
        ticks.add(null);
        if (remaining == 0) ticks.close();
      });
    }
    await for (final _ in ticks.stream) {
      cancel?.throwIfCancelled();
      byPkg.clear();
      order.clear();
      for (var i = 0; i < sources.length; i++) {
        final list = done[i];
        if (list != null) add(list.map(_copy), sources[i].$1);
      }
      yield [for (final p in order) byPkg[p]!];
    }
  }

  static AppListing _copy(AppListing l) =>
      AppListing(packageId: l.packageId, title: l.title, iconUrl: l.iconUrl, developer: l.developer)
        ..uptodownPage = l.uptodownPage;

  Future<List<AppListing>> _playSearch(String q, {CancellationToken? cancel}) async {
    final r = await _get(
      'https://play.google.com/store/search?q=${Uri.encodeQueryComponent(q)}&c=apps&hl=en&gl=US',
      cancel: cancel,
    );
    if (r.status >= 400) return [];
    final html = utf8.decode(latin1.encode(r.body), allowMalformed: true);
    final out = <AppListing>[];
    final seen = <String>{};
    final re = RegExp(r'href="/store/apps/details\?id=([A-Za-z0-9_.]+)"([^>]*)>');
    for (final m in re.allMatches(html)) {
      final pkg = m.group(1)!;
      if (!seen.add(pkg)) continue;
      final label = RegExp(r'aria-label="([^"]+)"').firstMatch(m.group(2)!)?.group(1);
      final tail = html.substring(m.end, (m.end + 2500).clamp(0, html.length));
      final icon = RegExp(r'src="(https://play-lh\.googleusercontent\.com/[^"=]+)=s\d+[^"]*"').firstMatch(tail)?.group(1);
      // List cards: <span>Title</span> then <span>Developer</span> inside the link.
      final card = tail.substring(0, tail.contains('</a>') ? tail.indexOf('</a>') : tail.length);
      final spans = RegExp(r'<span class="[^"]*">([^<]{2,100})</span>').allMatches(card).map((x) => x.group(1)!).toList();
      final divs = RegExp(r'<div class="[^"]*">([^<]{2,100})</div>').allMatches(tail).map((x) => x.group(1)!).toList();
      final title = label ?? spans.firstOrNull ?? divs.firstOrNull;
      final developer = label != null ? divs.skip(1).firstOrNull : spans.skip(1).firstOrNull;
      out.add(AppListing(
        packageId: pkg,
        title: _unescape(title ?? pkg),
        iconUrl: icon == null ? null : '$icon=s128',
        developer: developer == null ? null : _unescape(developer),
      ));
      if (out.length >= 20) break;
    }
    return out;
  }

  Future<List<AppListing>> _aptoideSearch(String q, {CancellationToken? cancel}) async {
    final j = await _json(
      'https://ws75.aptoide.com/api/7/apps/search?query=${Uri.encodeQueryComponent(q)}&limit=15',
      cancel: cancel,
    );
    final list = (j?['datalist']?['list'] as List?) ?? const [];
    return [
      for (final a in list.whereType<Map>())
        if (a['package'] is String)
          AppListing(
            packageId: a['package'] as String,
            title: (a['name'] as String?) ?? a['package'] as String,
            iconUrl: a['icon'] as String?,
            developer: (a['developer'] as Map?)?['name'] as String?,
          ),
    ];
  }

  Future<List<AppListing>> _uptodownSearch(String q, {CancellationToken? cancel}) async {
    final hits = await _uptodown.search(q, cancel: cancel);
    // Uptodown URLs use a slug, not the package name — read the real one from the top pages.
    final top = hits.take(4).toList();
    final resolved = await Future.wait(top.map((h) async {
      try {
        final pkg = await _uptodown.packageNameOf(h.pageUrl).timeout(const Duration(seconds: 10));
        if (pkg == null) return null;
        return AppListing(packageId: pkg, title: h.title)..uptodownPage = h.pageUrl;
      } catch (_) {
        return null;
      }
    }));
    return resolved.whereType<AppListing>().toList();
  }

  // ───────────────────────────── downloads ─────────────────────────────

  /// Every build the enabled sources offer for [listing], newest first, suspicious ones last.
  Future<List<DownloadOption>> options(
    AppListing listing, {
    Set<StoreSource> sources = const {...StoreSource.values},
    CancellationToken? cancel,
  }) async {
    Future<List<DownloadOption>> guard(Future<List<DownloadOption>> f) =>
        f.timeout(const Duration(seconds: 25)).catchError((Object e) {
          if (e is OperationCanceled) throw e;
          return <DownloadOption>[];
        });

    final all = (await Future.wait([
      if (sources.contains(StoreSource.apkpure)) guard(_apkpureOptions(listing, cancel: cancel)),
      if (sources.contains(StoreSource.aptoide)) guard(_aptoideOptions(listing, cancel: cancel)),
      if (sources.contains(StoreSource.fdroid)) guard(_fdroidOptions(listing, cancel: cancel)),
    ]))
        .expand((e) => e)
        .toList();
    cancel?.throwIfCancelled();
    _flagSuspicious(all);
    all.sort(compareOptions);
    return all;
  }

  /// Newest version first; warned builds after clean ones; then APKPure / F-Droid / Aptoide.
  static int compareOptions(DownloadOption a, DownloadOption b) {
    final wa = a.warning == null ? 0 : 1;
    final wb = b.warning == null ? 0 : 1;
    if (wa != wb) return wa - wb;
    // Stable releases before betas, so "Recommended" is never a pre-release.
    final pre = RegExp(r'beta|alpha|\brc\d*\b|preview|canary', caseSensitive: false);
    final ba = pre.hasMatch(a.versionName) ? 1 : 0;
    final bb = pre.hasMatch(b.versionName) ? 1 : 0;
    if (ba != bb) return ba - bb;
    // Version names first: some apps reset or re-scheme versionCode per ABI.
    final byName = _compareVersionNames(b.versionName, a.versionName);
    if (byName != 0) return byName;
    final av = a.versionCode, bv = b.versionCode;
    if (av != null && bv != null && av != bv) return bv.compareTo(av);
    const rank = {StoreSource.apkpure: 0, StoreSource.fdroid: 1, StoreSource.aptoide: 2};
    return rank[a.source]!.compareTo(rank[b.source]!);
  }

  static int _compareVersionNames(String a, String b) {
    final pa = RegExp(r'\d+').allMatches(a).map((m) => int.parse(m.group(0)!)).toList();
    final pb = RegExp(r'\d+').allMatches(b).map((m) => int.parse(m.group(0)!)).toList();
    for (var i = 0; i < pa.length && i < pb.length; i++) {
      if (pa[i] != pb[i]) return pa[i].compareTo(pb[i]);
    }
    return pa.length.compareTo(pb.length);
  }

  /// Mirrors carry user uploads; flag tiny placeholder files and fake "999.x" versions.
  static void _flagSuspicious(List<DownloadOption> all) {
    final sizes = all.map((o) => o.totalSize).whereType<int>().toList()..sort();
    final median = sizes.isEmpty ? 0 : sizes[sizes.length ~/ 2];
    for (final o in all) {
      if (o.warning != null) continue;
      final s = o.totalSize;
      if (s != null && median > 8 * 1024 * 1024 && s < median * 0.2) {
        o.warning = 'Much smaller than other builds — may be a fake or a stub.';
      } else if (RegExp(r'^9{3,}').hasMatch(o.versionName)) {
        o.warning = 'Placeholder version number — likely not a real release.';
      }
    }
  }

  Future<List<DownloadOption>> _apkpureOptions(AppListing l, {CancellationToken? cancel}) async {
    final r = await _get(
      'https://api.pureapk.com/m/v3/cms/app_version?hl=en-US&package_name=${Uri.encodeQueryComponent(l.packageId)}',
      ua: apkpureUa,
      headers: const {
        'x-cv': '3172501',
        'x-sv': '29',
        'x-abis': 'arm64-v8a,armeabi-v7a,armeabi,x86,x86_64',
        'x-gp': '1',
        'Accept-Encoding': 'gzip',
      },
      cancel: cancel,
    );
    if (r.status >= 400) return [];
    final body = r.body;
    final iconAt = body.indexOf(RegExp(r'https://image\.winudf\.com/[^\x00-\x20]+/icon\.png'));
    final icon = iconAt < 0 ? null : _protoString(body, iconAt);
    final out = <DownloadOption>[];
    final seenVersions = <String>{};
    for (final m in RegExp(r'https://download\.pureapk\.com/b/(XAPK|APK)/').allMatches(body)) {
      final url = _protoString(body, m.start);
      if (url == null) continue;
      final q = Uri.tryParse(url)?.queryParameters ?? const {};
      final meta = _decodeApkpureMeta(q['c']);
      final vn = meta['vn'];
      if (vn == null || !seenVersions.add(vn)) continue; // first variant per version matches our ABI list
      final fileName = _b64(q['_fn']);
      final title = fileName == null ? l.title : fileName.split('_v').first;
      out.add(DownloadOption(
        source: StoreSource.apkpure,
        packageId: l.packageId,
        title: title,
        versionName: vn,
        versionCode: int.tryParse(meta['vc'] ?? ''),
        isBundle: m.group(1) == 'XAPK',
        iconUrl: icon,
        parts: [
          DownloadPart(
            url: url,
            size: int.tryParse(meta['s'] ?? ''),
            referer: 'https://apkpure.com/',
            userAgent: apkpureUa,
          ),
        ],
      ));
      if (out.length >= 4) break;
    }
    return out;
  }

  /// Reads the protobuf string that starts at [at] using the varint length just before it, so the
  /// next field's tag byte is never glued onto the URL.
  static String? _protoString(String body, int at) {
    for (final width in [2, 1, 3]) {
      if (at - width < 0) continue;
      var len = 0;
      var ok = true;
      for (var i = 0; i < width; i++) {
        final b = body.codeUnitAt(at - width + i);
        final last = i == width - 1;
        if (last == (b & 0x80 != 0)) {
          ok = false;
          break;
        }
        len |= (b & 0x7f) << (7 * i);
      }
      if (ok && len >= 20 && at + len <= body.length) {
        final s = body.substring(at, at + len);
        if (!s.contains(RegExp(r'[\x00-\x20]'))) return s;
      }
    }
    return null;
  }

  static String? _b64(String? s) {
    if (s == null || s.isEmpty) return null;
    try {
      return utf8.decode(base64Url.decode(base64Url.normalize(s)), allowMalformed: true);
    } catch (_) {
      return null;
    }
  }

  /// `c=<n>|<CATEGORY>|<base64 of dev=..&t=xapk&s=SIZE&vn=VERSION&vc=CODE>`.
  static Map<String, String> _decodeApkpureMeta(String? c) {
    if (c == null) return const {};
    final parts = c.split('|');
    final decoded = _b64(parts.last);
    if (decoded == null) return const {};
    try {
      return Uri.splitQueryString(decoded);
    } catch (_) {
      return const {};
    }
  }

  Future<List<DownloadOption>> _aptoideOptions(AppListing l, {CancellationToken? cancel}) async {
    final j = await _json(
      'https://ws75.aptoide.com/api/7/listAppVersions?package_name=${Uri.encodeQueryComponent(l.packageId)}&limit=10',
      cancel: cancel,
    );
    final list = (j?['list'] as List?)?.whereType<Map>().toList() ?? const [];
    if (list.isEmpty) return [];
    // Keep the newest few distinct versions; fetch full metadata (signature + OBB) for each.
    final picks = <Map>[];
    final seen = <String>{};
    for (final a in list) {
      final vn = (a['file'] as Map?)?['vername'] as String?;
      if (vn == null || !seen.add(vn)) continue;
      picks.add(a);
      if (picks.length >= 4) break;
    }
    final metas = await Future.wait(picks.map((a) async {
      try {
        final m = await _json('https://ws75.aptoide.com/api/7/app/get?app_id=${a['id']}', cancel: cancel);
        return (m?['nodes']?['meta']?['data'] as Map?) ?? a;
      } catch (_) {
        return a;
      }
    }));
    final out = <DownloadOption>[];
    for (final d in metas) {
      final f = d['file'] as Map?;
      final path = (f?['path'] as String?) ?? (f?['path_alt'] as String?);
      if (f == null || path == null) continue;
      final pkg = d['package'] as String? ?? l.packageId;
      final parts = <DownloadPart>[
        DownloadPart(
          url: path,
          size: (f['filesize'] as num?)?.toInt(),
          md5: f['md5sum'] as String?,
          zipEntry: '$pkg.apk',
        ),
      ];
      final obb = d['obb'] as Map?;
      for (final kind in ['main', 'patch']) {
        final o = obb?[kind] as Map?;
        if (o == null || o['path'] == null) continue;
        parts.add(DownloadPart(
          url: o['path'] as String,
          size: (o['filesize'] as num?)?.toInt(),
          md5: o['md5sum'] as String?,
          zipEntry: 'Android/obb/$pkg/${o['filename']}',
        ));
      }
      final rank = (f['malware'] as Map?)?['rank'] as String?;
      out.add(DownloadOption(
        source: StoreSource.aptoide,
        packageId: pkg,
        title: d['name'] as String? ?? l.title,
        versionName: f['vername']?.toString() ?? '?',
        versionCode: (f['vercode'] as num?)?.toInt(),
        parts: parts,
        signer: (f['signature'] as Map?)?['owner'] as String?,
        iconUrl: d['icon'] as String?,
        updated: d['updated'] as String?,
        warning: rank != null && rank != 'TRUSTED' ? 'Aptoide marks this upload as $rank.' : null,
      ));
    }
    return out;
  }

  Future<List<DownloadOption>> _fdroidOptions(AppListing l, {CancellationToken? cancel}) async {
    final j = await _json('https://f-droid.org/api/v1/packages/${Uri.encodeComponent(l.packageId)}', cancel: cancel);
    final vc = (j?['suggestedVersionCode'] as num?)?.toInt();
    if (vc == null) return [];
    final packages = (j?['packages'] as List?)?.whereType<Map>() ?? const [];
    final match = packages.firstWhere((p) => p['versionCode'] == vc, orElse: () => const {});
    return [
      DownloadOption(
        source: StoreSource.fdroid,
        packageId: l.packageId,
        title: l.title,
        versionName: match['versionName']?.toString() ?? '$vc',
        versionCode: vc,
        parts: [DownloadPart(url: 'https://f-droid.org/repo/${l.packageId}_$vc.apk')],
      ),
    ];
  }

  static String _unescape(String s) => s
      .replaceAll('&amp;', '&')
      .replaceAll('&#39;', "'")
      .replaceAll('&quot;', '"')
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>');

  void close() => _http.close(force: true);
}
