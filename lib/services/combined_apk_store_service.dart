import 'dart:io';

export 'apkpure_service.dart' show ApkpureReleaseInfo, ApkpureSearchHit;

import 'apkcombo_service.dart';
import 'apkpure_service.dart';
import 'cancellation.dart';
import 'store_search_settings.dart';
import 'uptodown_service.dart';

/// Store search: merges enabled sources in order APKPure → APKCombo → Uptodown ([StoreSearchSettings]).
class CombinedApkStoreService {
  CombinedApkStoreService()
      : _apkpure = ApkpureService(),
        _apkcombo = ApkcomboSearchService(),
        _uptodown = UptodownSearchService();

  /// Shared HTTP stack for search and [DownloadQueue] transfers.
  ///
  /// Do not call [close] from a tab's [State.dispose] — switching tabs disposes
  /// hidden pages and would cancel in-flight downloads. [AppShell] calls [close]
  /// when the window closes.
  static final CombinedApkStoreService shared = CombinedApkStoreService();

  final ApkpureService _apkpure;
  final ApkcomboSearchService _apkcombo;
  final UptodownSearchService _uptodown;

  Future<List<ApkpureSearchHit>> search(String query, {CancellationToken? cancel}) async {
    final q = query.trim();
    if (q.isEmpty) return [];

    await StoreSearchSettings.instance.ensureLoaded();
    final prefs = StoreSearchSettings.instance;

    final merged = <ApkpureSearchHit>[];
    final seen = <String>{};

    void addHits(List<ApkpureSearchHit> list) {
      for (final h in list) {
        if (seen.add(h.packageId)) merged.add(h);
      }
    }

    Future<void> tryPure() async {
      try {
        cancel?.throwIfCancelled();
        addHits(await _apkpure.search(q, cancel: cancel));
      } on OperationCanceled {
        rethrow;
      } catch (_) {}
    }

    Future<void> tryCombo() async {
      try {
        cancel?.throwIfCancelled();
        addHits(await _apkcombo.search(q, cancel: cancel));
      } on OperationCanceled {
        rethrow;
      } catch (_) {}
    }

    Future<void> tryUd() async {
      try {
        cancel?.throwIfCancelled();
        addHits(await _uptodown.search(q, cancel: cancel));
      } on OperationCanceled {
        rethrow;
      } catch (_) {}
    }

    if (prefs.includesApkpure) await tryPure();
    if (prefs.includesApkcombo) await tryCombo();
    if (prefs.includesUptodown) await tryUd();

    return merged;
  }

  Future<ApkpureReleaseInfo> fetchRelease(ApkpureSearchHit hit) async {
    if (hit.isUptodown) {
      return _uptodown.fetchRelease(hit);
    }
    if (hit.isApkcombo) {
      return _apkcombo.fetchRelease(hit);
    }
    return _apkpure.fetchRelease(hit);
  }

  Future<File> downloadRelease(
    ApkpureReleaseInfo info,
    File destination, {
    void Function(int received, int? total)? onProgress,
    CancellationToken? cancel,
  }) {
    final ref = info.downloadReferer ??
        (info.downloadUrl.contains('apkcombo.com') ? 'https://apkcombo.com/' : 'https://apkpure.com/');
    return _apkpure.downloadToFile(
      info.downloadUrl,
      destination,
      referer: ref,
      onProgress: onProgress,
      cancel: cancel,
    );
  }

  bool looksNewer(String remoteVersion, String? localVersion) =>
      _apkpure.looksNewer(remoteVersion, localVersion);

  void close() {
    _apkpure.close();
    _apkcombo.close();
    _uptodown.close();
  }
}
