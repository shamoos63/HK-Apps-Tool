import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'app_catalog.dart';

/// Which download sources [AppCatalog.options] asks (persisted as JSON in app support).
class StoreSearchSettings {
  StoreSearchSettings._();

  static final StoreSearchSettings instance = StoreSearchSettings._();

  // v2: APKCombo and APKPure's web site sit behind Cloudflare challenges now; the source list changed.
  static const _fileName = 'store_sources_v2.json';

  Set<StoreSource> sources = StoreSource.values.toSet();

  bool _loaded = false;

  Future<void> ensureLoaded() async {
    if (_loaded) return;
    try {
      final base = await getApplicationSupportDirectory();
      final file = File(p.join(base.path, _fileName));
      if (file.existsSync()) {
        final list = json.decode(await file.readAsString());
        if (list is List) {
          final parsed = {
            for (final e in list)
              for (final s in StoreSource.values)
                if (s.name == e) s,
          };
          if (parsed.isNotEmpty) sources = parsed;
        }
      }
    } catch (_) {
      // Keep defaults.
    }
    _loaded = true;
  }

  Future<void> save(Set<StoreSource> next) async {
    sources = next.isEmpty ? StoreSource.values.toSet() : Set<StoreSource>.from(next);
    _loaded = true;
    try {
      final base = await getApplicationSupportDirectory();
      await File(p.join(base.path, _fileName)).writeAsString(json.encode(sources.map((s) => s.name).toList()));
    } catch (_) {
      // Best-effort; in-memory choice still applies for this session.
    }
  }
}
