import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import 'services/adb_paths.dart';
import 'services/adb_service.dart';
import 'services/aapt_service.dart';
import 'services/apk_installer.dart';
import 'services/install_queue.dart';
import 'services/app_paths.dart';
import 'services/combined_apk_store_service.dart';
import 'services/download_queue.dart';
import 'services/device_installed_app_display_cache.dart';
import 'services/installed_app_metadata_service.dart';
import 'services/xapk_service.dart';
import 'ui/adb_feedback.dart';
import 'ui/blocking_progress.dart';
import 'widgets/branded_app_bar.dart';

class DeviceAppVm {
  DeviceAppVm(this.packageName) : displayName = packageName;

  final String packageName;
  String displayName;
  Uint8List? icon;
  bool metaDone = false;

  bool checkUpdateBusy = false;
  bool downloadInstallBusy = false;
  String? storeVersion;
  bool? updateAvailable;
  ApkpureReleaseInfo? pendingRelease;
}

ApkpureSearchHit? _pickStoreHit(List<ApkpureSearchHit> hits, String packageName) {
  final exact = hits.firstWhereOrNull((h) => h.packageId == packageName);
  if (exact != null) return exact;
  final nonUtd = hits.where((h) => !h.isUptodown).toList();
  if (nonUtd.length == 1) return nonUtd.first;
  return hits.firstOrNull;
}

class DeviceAppsPage extends StatefulWidget {
  const DeviceAppsPage({super.key});

  @override
  State<DeviceAppsPage> createState() => _DeviceAppsPageState();
}

class _DeviceAppsPageState extends State<DeviceAppsPage> {
  final _adb = AdbService();
  final _aapt = AaptService();
  final _xapk = XapkService();
  final _store = CombinedApkStoreService.shared;
  late final InstalledAppMetadataService _meta = InstalledAppMetadataService(_adb, _aapt);
  final TextEditingController _deviceSearchCtl = TextEditingController();

  List<AdbDevice> _devices = [];
  String? _serial;
  List<DeviceAppVm> _entries = [];
  bool _busy = false;
  String? _error;
  double _metaFraction = 1;

  @override
  void initState() {
    super.initState();
    _deviceSearchCtl.addListener(() {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _deviceSearchCtl.dispose();
    super.dispose();
  }

  List<DeviceAppVm> get _filteredEntries {
    final q = _deviceSearchCtl.text.trim().toLowerCase();
    if (q.isEmpty) return _entries;
    return _entries
        .where(
          (e) =>
              e.displayName.toLowerCase().contains(q) || e.packageName.toLowerCase().contains(q),
        )
        .toList();
  }

  String _deviceListSummaryLine() {
    final serial = _serial;
    if (serial == null) {
      return 'Connect a device with USB debugging enabled, then refresh.';
    }
    final q = _deviceSearchCtl.text.trim();
    final total = _entries.length;
    final shown = _filteredEntries.length;
    if (total == 0) {
      return 'No user-installed apps on $serial';
    }
    if (q.isEmpty) {
      return '$total user-installed apps on $serial';
    }
    return '$shown of $total apps match "$q" · $serial';
  }

  Future<void> _reload() async {
    setState(() {
      _busy = true;
      _error = null;
      _metaFraction = 1;
    });
    try {
      AdbPaths.clearCache();
      final devs = await _adb.listDevices();
      setState(() {
        _devices = devs;
        if (devs.isEmpty) {
          _serial = null;
          _entries = [];
        } else if (_serial == null || !devs.any((d) => d.serial == _serial)) {
          _serial = devs.first.serial;
        }
      });
      final serial = _serial;
      if (serial != null) {
        final pkgs = await _adb.listUserPackages(serial);
        await DeviceInstalledAppDisplayCache.instance.pruneToPackageSet(serial, pkgs.toSet());
        setState(() {
          _entries = pkgs.map(DeviceAppVm.new).toList();
          _metaFraction = _entries.isEmpty ? 1 : 0;
        });
        if (_entries.isNotEmpty) {
          await _hydrateEntries(serial);
        }
      }
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _hydrateEntries(String serial) async {
    final total = _entries.length;
    const batchSize = 8;
    var done = 0;
    for (var i = 0; i < _entries.length; i += batchSize) {
      final end = math.min(i + batchSize, _entries.length);
      final slice = _entries.sublist(i, end);
      await Future.wait([
        for (final e in slice) _loadOne(serial, e),
      ]);
      done = end;
      if (mounted) setState(() => _metaFraction = done / total);
    }
    if (mounted) setState(() => _metaFraction = 1);
  }

  Future<void> _loadOne(String serial, DeviceAppVm e) async {
    final r = await _meta.loadDisplayInfo(serial, e.packageName);
    e.displayName = r.label;
    e.icon = r.icon;
    e.metaDone = true;
  }

  Future<void> _uninstall(DeviceAppVm app) async {
    final serial = _serial;
    if (serial == null) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Uninstall app?'),
        content: Text('${app.displayName}\n${app.packageName}'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Uninstall')),
        ],
      ),
    );
    if (ok != true) return;
    if (!mounted) return;
    try {
      final result = await runWithBlockingProgress<AdbCommandResult>(
        context,
        message: 'Uninstalling ${app.displayName}…',
        work: () => _adb.uninstallUserApp(serial, app.packageName),
      );
      if (!mounted) return;
      if (result.uninstallSucceeded) {
        showAdbSnack(
          context,
          success: true,
          successMessage: 'Uninstalled ${app.displayName} successfully.',
          failureTitle: 'Uninstall failed',
          result: result,
        );
      } else {
        showAdbSnack(
          context,
          success: false,
          successMessage: '',
          failureTitle: 'Uninstall failed',
          result: result,
        );
      }
      await _reload();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
      }
    }
  }

  Future<void> _checkUpdateOnDevice(DeviceAppVm app) async {
    final serial = _serial;
    if (serial == null) return;
    setState(() => app.checkUpdateBusy = true);
    try {
      final hits = await _store.search(app.packageName);
      final hit = _pickStoreHit(hits, app.packageName);
      if (hit == null) {
        app.storeVersion = null;
        app.updateAvailable = null;
        app.pendingRelease = null;
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('No store listing found for ${app.packageName}.')),
          );
        }
        return;
      }
      final rel = await _store.fetchRelease(hit);
      app.storeVersion = rel.version;
      final installed = await _adb.installedVersionName(serial, app.packageName);
      app.updateAvailable = _store.looksNewer(rel.version, installed);
      app.pendingRelease = app.updateAvailable == true ? rel : null;
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Update check failed: $e')));
      }
    } finally {
      app.checkUpdateBusy = false;
      if (mounted) setState(() {});
    }
  }

  Future<void> _downloadAndInstallUpdate(DeviceAppVm app) async {
    final serial = _serial;
    final rel = app.pendingRelease;
    if (serial == null || rel == null) return;
    setState(() => app.downloadInstallBusy = true);
    try {
      final dir = await AppPaths.apkDownloadDirectory();
      final isXapkUrl = rel.downloadUrl.toUpperCase().contains('XAPK') ||
          rel.downloadUrl.toLowerCase().contains('.xapk');
      final ext = isXapkUrl ? 'xapk' : 'apk';
      final dest = File(p.join(dir.path, '${app.packageName}.$ext'));

      await DownloadQueue.instance.beginStoreDownload(
        store: _store,
        info: rel,
        label: app.displayName,
        destination: dest,
      );

      if (!mounted) return;

      final result = await runWithBlockingProgress<AdbCommandResult>(
        context,
        message: 'Installing ${app.displayName}…',
        work: () => ApkInstaller(adb: _adb, xapk: _xapk)
            .installFile(dest.path, serial, includeObb: InstallQueue.instance.copyObb),
      );
      if (!mounted) return;
      showAdbSnack(
        context,
        success: result.installSucceeded,
        successMessage: 'Updated ${app.displayName} successfully.',
        failureTitle: 'Install failed',
        result: result,
      );
      if (result.installSucceeded) {
        setState(() {
          app.pendingRelease = null;
          app.updateAvailable = false;
          app.storeVersion = null;
        });
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
      }
    } finally {
      app.downloadInstallBusy = false;
      if (mounted) setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: BrandedAppBar(
        title: const Text('Apps on device'),
        actions: [
          if (_devices.length > 1)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: DropdownButtonHideUnderline(
                child: DropdownButton<String>(
                  value: _serial,
                  hint: const Text('Device'),
                  items: [
                    for (final d in _devices)
                      DropdownMenuItem(value: d.serial, child: Text(d.shortLabel, overflow: TextOverflow.ellipsis)),
                  ],
                  onChanged: (v) async {
                    setState(() => _serial = v);
                    if (v != null) {
                      setState(() {
                        _busy = true;
                        _metaFraction = 0;
                      });
                      try {
                        final pkgs = await _adb.listUserPackages(v);
                        await DeviceInstalledAppDisplayCache.instance.pruneToPackageSet(v, pkgs.toSet());
                        setState(() {
                          _entries = pkgs.map(DeviceAppVm.new).toList();
                          _metaFraction = _entries.isEmpty ? 1 : 0;
                        });
                        if (_entries.isNotEmpty) {
                          await _hydrateEntries(v);
                        }
                      } finally {
                        if (mounted) setState(() => _busy = false);
                      }
                    }
                  },
                ),
              ),
            ),
          TextButton.icon(
            onPressed: _busy ? null : _reload,
            icon: _busy
                ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.refresh_rounded),
            label: const Text('Refresh'),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: Column(
        children: [
          if (_metaFraction < 1 && _entries.isNotEmpty)
            LinearProgressIndicator(
              value: _metaFraction <= 0 ? null : _metaFraction,
              minHeight: 3,
            ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (_error != null)
                    Card(
                      color: Theme.of(context).colorScheme.errorContainer,
                      child: Padding(
                        padding: const EdgeInsets.all(14),
                        child: Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.onErrorContainer)),
                      ),
                    ),
                  if (_error != null) const SizedBox(height: 12),
                  Text(
                    _deviceListSummaryLine(),
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                  if (_serial != null && _entries.isNotEmpty) ...[
                    const SizedBox(height: 10),
                    TextField(
                      controller: _deviceSearchCtl,
                      decoration: InputDecoration(
                        hintText: 'Search by name or package…',
                        prefixIcon: const Icon(Icons.search_rounded),
                        suffixIcon: _deviceSearchCtl.text.isEmpty
                            ? null
                            : IconButton(
                                tooltip: 'Clear',
                                onPressed: () => _deviceSearchCtl.clear(),
                                icon: const Icon(Icons.clear_rounded),
                              ),
                        border: const OutlineInputBorder(),
                        isDense: true,
                      ),
                    ),
                  ],
                  if (_serial != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Text(
                        'Check update uses the same stores as Search & download. When a newer store version exists, you can download and install it in one step.',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
                      ),
                    ),
                  const SizedBox(height: 12),
                  Expanded(
                    child: _entries.isEmpty
                        ? const Center(child: Text('No packages to show.'))
                        : _filteredEntries.isEmpty
                            ? const Center(child: Text('No apps match your search.'))
                            : ListView.separated(
                            itemCount: _filteredEntries.length,
                            separatorBuilder: (context, i) => const SizedBox(height: 6),
                            itemBuilder: (context, i) {
                              final app = _filteredEntries[i];
                              final t = Theme.of(context).textTheme;
                              return Card(
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                                  child: Row(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      _buildLeading(app),
                                      const SizedBox(width: 12),
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment: CrossAxisAlignment.start,
                                          children: [
                                            Text(
                                              app.displayName,
                                              style: t.titleSmall?.copyWith(fontWeight: FontWeight.w600),
                                              maxLines: 2,
                                              overflow: TextOverflow.ellipsis,
                                            ),
                                            const SizedBox(height: 2),
                                            Text(
                                              app.packageName,
                                              style: t.bodySmall?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                            ),
                                            if (app.storeVersion != null) ...[
                                              const SizedBox(height: 6),
                                              Text(
                                                'Store: v${app.storeVersion}'
                                                '${app.updateAvailable == true ? ' (newer)' : app.updateAvailable == false ? ' (same or older)' : ''}',
                                                style: t.labelMedium?.copyWith(
                                                  color: Theme.of(context).colorScheme.primary,
                                                ),
                                              ),
                                            ],
                                            const SizedBox(height: 8),
                                            Wrap(
                                              spacing: 8,
                                              runSpacing: 8,
                                              children: [
                                                OutlinedButton(
                                                  onPressed: (app.checkUpdateBusy || app.downloadInstallBusy)
                                                      ? null
                                                      : () => _checkUpdateOnDevice(app),
                                                  child: app.checkUpdateBusy
                                                      ? const SizedBox(
                                                          width: 18,
                                                          height: 18,
                                                          child: CircularProgressIndicator(strokeWidth: 2),
                                                        )
                                                      : const Text('Check update'),
                                                ),
                                                if (app.updateAvailable == true && app.pendingRelease != null)
                                                  FilledButton.tonal(
                                                    onPressed: (app.checkUpdateBusy || app.downloadInstallBusy)
                                                        ? null
                                                        : () => _downloadAndInstallUpdate(app),
                                                    child: app.downloadInstallBusy
                                                        ? const SizedBox(
                                                            width: 18,
                                                            height: 18,
                                                            child: CircularProgressIndicator(strokeWidth: 2),
                                                          )
                                                        : const Text('Download & install'),
                                                  ),
                                                OutlinedButton(
                                                  onPressed: app.downloadInstallBusy ? null : () => _uninstall(app),
                                                  child: const Text('Uninstall'),
                                                ),
                                              ],
                                            ),
                                          ],
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              );
                            },
                          ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLeading(DeviceAppVm app) {
    if (app.icon != null) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: Image.memory(app.icon!, width: 48, height: 48, fit: BoxFit.cover),
      );
    }
    if (!app.metaDone) {
      return SizedBox(
        width: 48,
        height: 48,
        child: Center(
          child: SizedBox(
            width: 22,
            height: 22,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      );
    }
    return const CircleAvatar(
      radius: 24,
      child: Icon(Icons.android_rounded),
    );
  }
}
