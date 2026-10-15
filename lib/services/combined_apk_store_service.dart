import 'dart:io';

export 'apkpure_service.dart' show ApkpureReleaseInfo, ApkpureSearchHit;

import 'apkpure_service.dart';
import 'app_catalog.dart';
import 'cancellation.dart';
import 'fast_downloader.dart';
import 'store_search_settings.dart';

/// Facade over [AppCatalog] (search + builds) and [FastDownloader], kept for the
/// update-check and download call sites that speak in [ApkpureSearchHit] / [ApkpureReleaseInfo].
class CombinedApkStoreService {
  CombinedApkStoreService() : _apkpure = ApkpureService();

  /// Shared HTTP stack for search and [DownloadQueue] transfers.
  ///
  /// Do not call [close] from a tab's [State.dispose] — switching tabs disposes
  /// hidden pages and would cancel in-flight downloads. [AppShell] calls [close]
  /// when the window closes.
  static final CombinedApkStoreService shared = CombinedApkStoreService();

  final ApkpureService _apkpure;
  AppCatalog get catalog => AppCatalog.shared;

  Future<List<ApkpureSearchHit>> search(String query, {CancellationToken? cancel}) async {
    final list = await catalog.search(query, cancel: cancel);
    return [
      for (final l in list)
        ApkpureSearchHit(title: l.title, pageUrl: l.uptodownPage ?? '', packageId: l.packageId, slug: 'catalog'),
    ];
  }

  /// Best available build for [packageId] across the enabled sources (null when none has it).
  Future<ApkpureReleaseInfo?> latestFor(String packageId, {String? title, CancellationToken? cancel}) async {
    await StoreSearchSettings.instance.ensureLoaded();
    final opts = await catalog.options(
      AppListing(packageId: packageId, title: title ?? packageId),
      sources: StoreSearchSettings.instance.sources,
      cancel: cancel,
    );
    final best = opts.where((o) => o.warning == null).firstOrNull ?? opts.firstOrNull;
    return best == null ? null : releaseFor(best);
  }

  static ApkpureReleaseInfo releaseFor(DownloadOption o) => ApkpureReleaseInfo(
        title: o.title,
        version: o.versionName,
        updateDate: o.updated ?? '—',
        downloadUrl: o.parts.first.url,
        pageUrl: 'https://play.google.com/store/apps/details?id=${o.packageId}',
        downloadReferer: o.parts.first.referer,
        option: o,
      );

  Future<ApkpureReleaseInfo> fetchRelease(ApkpureSearchHit hit) async {
    final r = await latestFor(hit.packageId, title: hit.title);
    if (r == null) throw HttpException('No download source has ${hit.title} (${hit.packageId}).');
    return r;
  }

  /// Downloads [info] next to [destination] and returns the file actually written — its
  /// extension follows the real contents (`.apk` vs `.xapk`), which may differ from [destination].
  Future<File> downloadRelease(
    ApkpureReleaseInfo info,
    File destination, {
    void Function(int received, int? total)? onProgress,
    CancellationToken? cancel,
  }) async {
    final stem = destination.uri.pathSegments.last.replaceFirst(RegExp(r'\.(x?apk|apks)$', caseSensitive: false), '');
    final option = info.option;
    if (option != null) {
      try {
        return await FastDownloader.instance.download(
          option,
          destination.parent,
          stem,
          onProgress: onProgress,
          cancel: cancel,
        );
      } on OperationCanceled {
        rethrow;
      } catch (_) {
        if (option.parts.length > 1 || (cancel?.isCancelled ?? false)) rethrow;
        // Single file: one more try through the older curl-based path below.
      }
    }
    final ref = info.downloadReferer ?? 'https://apkpure.com/';
    return _apkpure.downloadToFile(info.downloadUrl, destination, referer: ref, onProgress: onProgress, cancel: cancel);
  }

  bool looksNewer(String remoteVersion, String? localVersion) => _apkpure.looksNewer(remoteVersion, localVersion);

  void close() {
    _apkpure.close();
    catalog.close();
  }
}
