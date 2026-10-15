import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Which third-party catalogues participate in [CombinedApkStoreService.search].
enum StoreSearchSource {
  apkpure,
  apkcombo,
  uptodown,
}

/// Persisted choice of search sources (application support directory JSON).
class StoreSearchSettings {
  StoreSearchSettings._();

  static final StoreSearchSettings instance = StoreSearchSettings._();

  static const _fileName = 'store_search_sources.json';

  /// User-enabled sources; order for merging is always APKPure → APKCombo → Uptodown.
  Set<StoreSearchSource> sources = {
    StoreSearchSource.apkpure,
    StoreSearchSource.apkcombo,
    StoreSearchSource.uptodown,
  };

  bool _loaded = false;

  Future<void> ensureLoaded() async {
    if (_loaded) return;
    try {
      final base = await getApplicationSupportDirectory();
      final file = File(p.join(base.path, _fileName));
      if (!file.existsSync()) {
        _loaded = true;
        return;
      }
      final list = json.decode(await file.readAsString());
      if (list is! List) {
        _loaded = true;
        return;
      }
      final parsed = <StoreSearchSource>{};
      for (final e in list) {
        if (e is String) {
          if (e == 'apkpure') parsed.add(StoreSearchSource.apkpure);
          if (e == 'apkcombo') parsed.add(StoreSearchSource.apkcombo);
          if (e == 'uptodown') parsed.add(StoreSearchSource.uptodown);
        }
      }
      if (parsed.isNotEmpty) sources = parsed;
    } catch (_) {
      // Keep defaults.
    }
    _loaded = true;
  }

  Future<void> save(Set<StoreSearchSource> next) async {
    sources = next.isEmpty
        ? {StoreSearchSource.apkpure}
        : Set<StoreSearchSource>.from(next);
    try {
      final base = await getApplicationSupportDirectory();
      final file = File(p.join(base.path, _fileName));
      final encoded = json.encode(sources.map((s) => s.name).toList());
      await file.writeAsString(encoded);
    } catch (_) {
      // Best-effort; in-memory choice still applies for this session.
    }
    _loaded = true;
  }

  bool get includesApkpure => sources.contains(StoreSearchSource.apkpure);
  bool get includesApkcombo => sources.contains(StoreSearchSource.apkcombo);
  bool get includesUptodown => sources.contains(StoreSearchSource.uptodown);
}
