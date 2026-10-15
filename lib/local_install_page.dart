import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import 'services/aapt_service.dart';
import 'services/adb_paths.dart';
import 'services/adb_service.dart';
import 'services/apk_library_folder_helper.dart';
import 'services/app_paths.dart';
import 'services/combined_apk_store_service.dart';
import 'services/download_queue.dart';
import 'services/library_apk_metadata_cache.dart';
import 'services/xapk_service.dart';
import 'widgets/branded_app_bar.dart';

class LocalInstallPage extends StatefulWidget {
  const LocalInstallPage({super.key});

  @override
  State<LocalInstallPage> createState() => _LocalInstallPageState();
}

class _LocalRow {
  _LocalRow(this.file);

  File file;
  bool isXapk = false;
  ApkBadging? badging;
  String? packageId;
  String? title;
  String? localVersion;
  Uint8List? icon;
  bool metaBusy = true;
  String? remoteVersion;
  bool? updateAvailable;
  bool checkBusy = false;
  /// Last store [ApkpureReleaseInfo] from a successful check; used by [Download newer].
  ApkpureReleaseInfo? updateRelease;
  bool downloadUpdateBusy = false;
  String? deviceVersion;
  bool? installed;

  String get path => file.path;
  String get displayName => p.basename(path);
}

class _InstallActivity {
  _InstallActivity({
    required this.id,
    required this.label,
    required this.filePath,
  });

  final String id;
  final String label;
  /// Same as [_LocalRow.path] so progress appears under that card.
  final String filePath;
  bool running = true;
  bool? success;
  String detail = '';
}

class _LocalInstallPageState extends State<LocalInstallPage> {
  final _adb = AdbService();
  final _aapt = AaptService();
  final _xapk = XapkService();
  final _store = CombinedApkStoreService.shared;
  final TextEditingController _librarySearchCtl = TextEditingController();

  static const _metaConcurrency = 6;
  static const _maxConcurrentInstalls = 5;
  static const _maxActivityRows = 10;
  var _parallelInstallCount = 0;
  final List<_InstallActivity> _installActivities = [];

  List<AdbDevice> _devices = [];
  String? _serial;
  List<_LocalRow> _rows = [];
  bool _scanning = false;
  String? _adbError;
  Map<String, String>? _deviceProps;

  String _libraryHeaderSubtitle() {
    final installing = _installActivities.where((a) => a.running).length;
    late final String deviceLine;
    if (_devices.isEmpty) {
      deviceLine = 'No USB device — Scan device in app bar';
    } else {
      final serial = _serial;
      final d = serial != null
          ? _devices.firstWhere((x) => x.serial == serial, orElse: () => _devices.first)
          : _devices.first;
      deviceLine = d.shortLabel;
    }
    if (installing > 0) return '$installing installing · $deviceLine';
    return deviceLine;
  }

  List<_LocalRow> get _filteredLibraryRows {
    final q = _librarySearchCtl.text.trim().toLowerCase();
    if (q.isEmpty) return _rows;
    bool hit(_LocalRow r) {
      if (r.displayName.toLowerCase().contains(q)) return true;
      final title = (r.badging?.label ?? r.title ?? '').toLowerCase();
      if (title.contains(q)) return true;
      final pkg = (r.packageId ?? '').toLowerCase();
      if (pkg.contains(q)) return true;
      if (r.path.toLowerCase().contains(q)) return true;
      return false;
    }

    return _rows.where(hit).toList();
  }

  String _libraryFolderExpansionTitle() {
    if (_rows.isEmpty) return 'Device & APK folder';
    final total = _rows.length;
    final q = _librarySearchCtl.text.trim();
    if (q.isEmpty) {
      return 'Device & folder · $total ${total == 1 ? 'app' : 'apps'}';
    }
    final visible = _filteredLibraryRows.length;
    return 'Device & folder · $visible of $total matching';
  }

  @override
  void initState() {
    super.initState();
    _librarySearchCtl.addListener(() {
      if (mounted) setState(() {});
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => _refreshPackages());
  }

  @override
  void dispose() {
    _librarySearchCtl.dispose();
    super.dispose();
  }

  Future<void> _pickApkLibraryFolder() async {
    await ApkLibraryFolderHelper.pickAndSet(context);
    if (mounted) await _refreshPackages();
  }

  Future<void> _resetApkLibraryFolder() async {
    await ApkLibraryFolderHelper.confirmResetToDefault(context);
    if (mounted) await _refreshPackages();
  }

  Future<void> _openApkFolder() async {
    try {
      final dir = await AppPaths.apkDownloadDirectory();
      if (!dir.existsSync()) await dir.create(recursive: true);
      final path = dir.path;
      if (Platform.isWindows) {
        await Process.run('explorer', [path]);
      } else if (Platform.isMacOS) {
        await Process.run('open', [path]);
      } else if (Platform.isLinux) {
        await Process.run('xdg-open', [path]);
      } else {
        _toast('Open folder is not configured for this OS.');
      }
    } catch (e) {
      if (mounted) _toast('Could not open folder: $e');
    }
  }

  Future<void> _deleteLocalFile(_LocalRow row) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Delete file?'),
        content: Text(
          'Remove "${row.displayName}" from the app library?\nThis cannot be undone.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
          FilledButton(
            onPressed: () => Navigator.pop(c, true),
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(c).colorScheme.error,
              foregroundColor: Theme.of(c).colorScheme.onError,
            ),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    try {
      if (row.file.existsSync()) {
        await row.file.delete();
      }
      setState(() {
        _installActivities.removeWhere((a) => a.filePath == row.path);
      });
      await _refreshPackages();
      _toast('Deleted ${row.displayName}');
    } catch (e) {
      if (mounted) _toast('Could not delete: $e');
    }
  }

  Future<void> _scanDevices() async {
    setState(() {
      _scanning = true;
      _adbError = null;
    });
    try {
      AdbPaths.clearCache();
      final list = await _adb.listDevices();
      setState(() {
        _devices = list;
        if (list.isEmpty) {
          _serial = null;
          _deviceProps = null;
        } else if (_serial == null || !list.any((d) => d.serial == _serial)) {
          _serial = list.first.serial;
        }
      });
      await _loadDeviceDetails();
      await _refreshPackages();
    } catch (e) {
      setState(() => _adbError = e.toString());
    } finally {
      if (mounted) setState(() => _scanning = false);
    }
  }

  Future<void> _renameRowToSanitizedApplicationLabel(_LocalRow row) async {
    if (!row.file.existsSync()) return;
    final stem = AaptService.sanitizeFileStem(row.badging?.label?.trim() ?? '');
    if (stem.isEmpty) return;

    final ext = p.extension(row.file.path).toLowerCase();
    if (ext != '.apk' && ext != '.xapk') return;

    File targetForStem(String baseStem) {
      final dir = row.file.parent;
      final primary = File(p.join(dir.path, '$baseStem$ext'));
      if (!primary.existsSync()) return primary;
      if (_sameFileRef(primary, row.file)) return primary;
      for (var i = 2; i < 10000; i++) {
        final f = File(p.join(dir.path, '$baseStem ($i)$ext'));
        if (!f.existsSync() || _sameFileRef(f, row.file)) return f;
      }
      return primary;
    }

    final target = targetForStem(stem);
    final wantName = p.basename(target.path);

    if (_pathsEqualIgnoringCase(p.basename(row.file.path), wantName) &&
        p.basename(row.file.path) != wantName) {
      await _renameFileWindowsCaseInsensitive(row.file, target);
      row.file = target;
      return;
    }

    if (_sameFileRef(target, row.file)) return;

    await row.file.rename(target.path);
    row.file = target;
  }

  static bool _pathsEqualIgnoringCase(String a, String b) => a.toLowerCase() == b.toLowerCase();

  bool _sameFileRef(File a, File b) => _pathsEqualIgnoringCase(a.absolute.path, b.absolute.path);

  /// Rename when only capitalization differs (`source` vs `dest`, same logical path).
  Future<void> _renameFileWindowsCaseInsensitive(File source, File dest) async {
    final parent = dest.parent.path;
    final base =
        '${p.basenameWithoutExtension(dest.path)}.__ren${DateTime.now().microsecondsSinceEpoch}${p.extension(dest.path)}';
    final tmp = File(p.join(parent, base));
    await source.rename(tmp.path);
    await tmp.rename(dest.path);
  }

  Future<void> _refreshPackages() async {
    final dir = await AppPaths.apkDownloadDirectory();
    final files = dir
        .listSync()
        .whereType<File>()
        .where((f) {
          final e = p.extension(f.path).toLowerCase();
          return e == '.apk' || e == '.xapk';
        })
        .toList()
      ..sort((a, b) => a.path.toLowerCase().compareTo(b.path.toLowerCase()));

    final rows = files.map(_LocalRow.new).toList();
    setState(() {
      _rows = rows;
    });

    await _loadLibraryRowsMeta(rows);
    if (mounted) setState(() {});
    await _refreshDeviceVersions();
  }

  Future<void> _loadLibraryRowsMeta(List<_LocalRow> rows) async {
    final n = rows.length;
    for (var i = 0; i < n; i += _metaConcurrency) {
      final end = math.min(i + _metaConcurrency, n);
      final slice = rows.sublist(i, end);
      await Future.wait([
        for (final row in slice) _loadLibraryRowMeta(row),
      ]);
      if (mounted) setState(() {});
    }
  }

  Future<void> _loadLibraryRowMeta(_LocalRow row) async {
    row.metaBusy = true;
    final hydrated = await LibraryApkMetadataCache.instance.tryHydrate(
      file: row.file,
      apply: ({
        required bool isXapk,
        required ApkBadging? badging,
        required String title,
        required String? packageId,
        required String? localVersion,
        required Uint8List? icon,
      }) {
        row.isXapk = isXapk;
        row.badging = badging;
        row.packageId = packageId ?? badging?.packageName;
        row.localVersion = localVersion ?? badging?.versionName;
        row.title = title;
        row.icon = icon;
      },
    );
    if (hydrated) {
      row.metaBusy = false;
      return;
    }
    await _loadMeta(row);
    await LibraryApkMetadataCache.instance.record(
      file: row.file,
      isXapk: row.isXapk,
      badging: row.badging,
      title: row.title ?? row.displayName,
      packageId: row.packageId,
      localVersion: row.localVersion,
      icon: row.icon,
    );
  }

  Future<void> _loadMeta(_LocalRow row) async {
    row.metaBusy = true;
    row.isXapk = XapkService.looksLikeXapk(row.path);
    try {
      if (row.isXapk) {
        final peek = await _xapk.peek(row.path);
        row.packageId = peek.packageName;
        row.localVersion = peek.versionName;
        row.title = row.displayName;
        if (peek.sampleApkArchiveFile != null) {
          final tmp = File(p.join(Directory.systemTemp.path, 'adb_mgr_icon_${row.packageId ?? 'x'}.apk'));
          await tmp.writeAsBytes(peek.sampleApkArchiveFile!.content as List<int>);
          row.badging = await _aapt.readBadging(tmp.path);
          row.icon = await _aapt.readLauncherIconBytes(tmp.path);
          await tmp.delete();
          if (row.badging != null) {
            row.packageId = row.badging!.packageName;
            row.localVersion = row.badging!.versionName ?? row.localVersion;
            row.title = row.badging!.label ?? row.title;
          }
        }
        await _renameRowToSanitizedApplicationLabel(row);
      } else {
        row.badging = await _aapt.readBadging(row.file.path);
        row.packageId = row.badging?.packageName;
        row.localVersion = row.badging?.versionName;
        row.title = row.badging?.label ?? row.badging?.packageName ?? row.displayName;
        row.icon = await _aapt.readLauncherIconBytes(row.file.path);
        await _renameRowToSanitizedApplicationLabel(row);
      }
    } catch (e) {
      row.title = row.displayName;
    } finally {
      row.metaBusy = false;
    }
  }

  Future<void> _refreshDeviceVersions() async {
    final serial = _serial;
    if (serial == null) return;
    for (final row in _rows) {
      final pkg = row.packageId;
      if (pkg == null) continue;
      final ins = await _adb.isPackageInstalled(serial, pkg);
      row.installed = ins;
      if (ins) {
        row.deviceVersion = await _adb.installedVersionName(serial, pkg);
      } else {
        row.deviceVersion = null;
      }
    }
    if (mounted) setState(() {});
  }

  Future<void> _loadDeviceDetails() async {
    final serial = _serial;
    if (serial == null) {
      if (mounted) setState(() => _deviceProps = null);
      return;
    }
    try {
      final props = await _adb.deviceProps(serial);
      if (mounted) setState(() => _deviceProps = props);
    } catch (_) {
      if (mounted) setState(() => _deviceProps = null);
    }
  }

  /// Badging sometimes appends `.xapk` / `.apk` to [application-label]; remove for store search only.
  String _stripFileExtensionFromApplicationLabelForSearch(String rawLabel) {
    var s = rawLabel.trim();
    if (s.isEmpty) return '';
    final ext = RegExp(r'\.(xapk|apks|apk)$', caseSensitive: false);
    while (true) {
      final next = s.replaceFirst(ext, '').trim();
      if (next == s || next.isEmpty) break;
      s = next;
    }
    return s.trim();
  }

  Future<void> _checkOnline(_LocalRow row) async {
    setState(() => row.checkBusy = true);
    try {
      final rawLabel = row.badging?.label?.trim();
      final labelQ = (rawLabel != null && rawLabel.isNotEmpty)
          ? _stripFileExtensionFromApplicationLabelForSearch(rawLabel)
          : null;
      final query = (labelQ != null && labelQ.isNotEmpty)
          ? labelQ
          : (row.packageId != null && row.packageId!.contains('.'))
              ? row.packageId!
              : (row.title ?? p.basenameWithoutExtension(row.path)).trim();
      if (query.isEmpty) {
        if (mounted) _toast('Nothing to search — Application label missing and no package id.');
        return;
      }
      final hits = await _store.search(query);
      final pkg = row.packageId;
      final hit = pkg != null
          ? (hits.firstWhereOrNull((h) => h.packageId == pkg) ?? hits.firstOrNull)
          : hits.firstOrNull;
      if (hit == null) {
        row.remoteVersion = null;
        row.updateAvailable = null;
        row.updateRelease = null;
        if (mounted) _toast('No store listing found for "$query".');
        return;
      }
      final rel = await _store.fetchRelease(hit);
      row.remoteVersion = rel.version;
      row.updateRelease = rel;
      final dv = row.deviceVersion ?? row.localVersion;
      row.updateAvailable = _store.looksNewer(rel.version, dv);
    } catch (e) {
      row.updateRelease = null;
      if (mounted) _toast('Update check failed: $e');
    } finally {
      if (mounted) {
        setState(() => row.checkBusy = false);
      }
    }
  }

  Future<void> _downloadNewerVersion(_LocalRow row) async {
    final rel = row.updateRelease;
    if (rel == null || row.updateAvailable != true) return;
    setState(() => row.downloadUpdateBusy = true);
    try {
      final dir = await AppPaths.apkDownloadDirectory();
      final isXapk = rel.downloadUrl.toUpperCase().contains('XAPK') ||
          rel.downloadUrl.toLowerCase().contains('.xapk');
      final ext = isXapk ? '.xapk' : '.apk';
      final stem = AaptService.sanitizeFileStem(row.badging?.label?.trim() ?? '');
      final baseName = stem.isNotEmpty
          ? stem
          : (row.packageId != null && row.packageId!.contains('.'))
              ? row.packageId!
              : p.basenameWithoutExtension(row.path);
      final dest = File(p.join(dir.path, '$baseName$ext'));
      await DownloadQueue.instance.beginStoreDownload(
        store: _store,
        info: rel,
        label: row.title ?? row.displayName,
        destination: dest,
      );
      if (!mounted) return;
      _toast('Saved newer build to ${dest.path}');
      await _refreshPackages();
    } catch (e) {
      if (mounted) _toast('Download failed: $e');
    } finally {
      if (mounted) setState(() => row.downloadUpdateBusy = false);
    }
  }

  Future<void> _acquireInstallSlot() async {
    while (_parallelInstallCount >= _maxConcurrentInstalls && mounted) {
      await Future<void>.delayed(const Duration(milliseconds: 120));
    }
    _parallelInstallCount++;
  }

  void _releaseInstallSlot() {
    if (_parallelInstallCount > 0) _parallelInstallCount--;
  }

  Future<void> _runInstallActivity(_InstallActivity act, _LocalRow row, String serial) async {
    await _acquireInstallSlot();
    try {
      if (!mounted) return;
      late AdbCommandResult result;
      final parts = await _xapk.resolveAdbInstallParts(
        row.path,
        useXapkPipeline: row.isXapk || await XapkService.zipLooksLikeXapkBundle(row.path),
      );
      if (parts.length > 1) {
        result = await _adb.installMultiple(serial: serial, apkPaths: parts);
      } else if (parts.isEmpty) {
        throw StateError('Could not resolve APK files to install.');
      } else {
        result = await _adb.installApk(serial: serial, apkPath: parts.single);
      }
      act.running = false;
      final multi = parts.length > 1;
      act.success = result.installSucceeded;
      act.detail = act.success == true
          ? (multi ? 'Installed successfully (split / bundle).' : 'Installed successfully.')
          : (result.combinedOutput.trim().isEmpty
              ? 'Install failed (exit code ${result.exitCode}).'
              : result.combinedOutput.trim());
    } catch (e) {
      act.running = false;
      act.success = false;
      act.detail = e.toString();
    } finally {
      _releaseInstallSlot();
    }
    if (mounted) setState(() {});
    await _refreshDeviceVersions();
  }

  void _install(_LocalRow row) {
    final serial = _serial;
    if (serial == null) {
      _toast('Connect a device and scan first.');
      return;
    }
    final act = _InstallActivity(
      id: '${DateTime.now().millisecondsSinceEpoch}_${row.path.hashCode}',
      label: row.title ?? row.displayName,
      filePath: row.path,
    );
    setState(() {
      _installActivities.insert(0, act);
      while (_installActivities.length > _maxActivityRows) {
        _installActivities.removeLast();
      }
    });
    unawaited(_runInstallActivity(act, row, serial));
  }

  void _clearInstallActivities() {
    setState(() => _installActivities.removeWhere((e) => !e.running));
  }

  Widget _buildInstallSummaryBar(BuildContext context) {
    if (_installActivities.isEmpty) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final running = _installActivities.where((a) => a.running).length;
    return Padding(
      padding: const EdgeInsets.only(top: 6, bottom: 4),
      child: Align(
        alignment: Alignment.centerLeft,
        child: Text(
          running > 0
              ? '$running installing · up to $_maxConcurrentInstalls at once'
              : '${_installActivities.length} recent install(s)',
          style: theme.textTheme.labelMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
      ),
    );
  }

  Widget _buildActivitiesUnderRow(BuildContext context, _LocalRow row) {
    final forPath = _installActivities.where((a) => a.filePath == row.path).toList();
    if (forPath.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var i = 0; i < forPath.length; i++) ...[
            if (i > 0) const SizedBox(height: 10),
            _buildSingleInstallActivity(context, forPath[i]),
          ],
        ],
      ),
    );
  }

  Widget _buildSingleInstallActivity(BuildContext context, _InstallActivity a) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (a.running) ...[
          Text('Installing…', style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
          const SizedBox(height: 6),
          const LinearProgressIndicator(minHeight: 4),
        ],
        if (!a.running && a.success != null) ...[
          DecoratedBox(
            decoration: BoxDecoration(
              color: a.success!
                  ? Colors.green.shade50
                  : theme.colorScheme.errorContainer.withValues(alpha: 0.35),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                color: a.success! ? Colors.green.shade700 : theme.colorScheme.error,
                width: 1.2,
              ),
            ),
            child: Padding(
              padding: const EdgeInsets.all(10),
              child: SelectableText(
                a.detail,
                style: TextStyle(
                  color: a.success! ? Colors.green.shade900 : theme.colorScheme.error,
                  fontWeight: FontWeight.w500,
                  height: 1.35,
                ),
              ),
            ),
          ),
        ],
      ],
    );
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: BrandedAppBar(
        title: const Text('HK Apps Tool'),
        actions: [
          TextButton.icon(
            onPressed: _scanning ? null : _scanDevices,
            icon: _scanning
                ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.refresh_rounded, size: 20),
            label: const Text('Scan device'),
          ),
          TextButton.icon(
            onPressed: _openApkFolder,
            icon: const Icon(Icons.folder_outlined, size: 20),
            label: const Text('Open folder'),
          ),
          TextButton.icon(
            onPressed: _refreshPackages,
            icon: const Icon(Icons.sync_rounded, size: 20),
            label: const Text('Reload'),
          ),
          TextButton.icon(
            onPressed: _installActivities.any((a) => !a.running) ? _clearInstallActivities : null,
            icon: const Icon(Icons.clear_all_rounded, size: 20),
            label: const Text('Clear finished'),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Material(
                    color: Theme.of(context).colorScheme.surfaceContainerHighest.withValues(alpha: 0.42),
                    borderRadius: BorderRadius.circular(10),
                    clipBehavior: Clip.antiAlias,
                    child: ExpansionTile(
                      initiallyExpanded: false,
                      tilePadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                      childrenPadding: const EdgeInsets.fromLTRB(10, 0, 10, 8),
                      title: Row(
                        children: [
                          Icon(Icons.folder_special_outlined,
                              size: 20, color: Theme.of(context).colorScheme.primary),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              _libraryFolderExpansionTitle(),
                              style: Theme.of(context)
                                  .textTheme
                                  .titleSmall
                                  ?.copyWith(fontWeight: FontWeight.w700),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                      subtitle: Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Text(
                          _libraryHeaderSubtitle(),
                          style:
                              Theme.of(context).textTheme.bodySmall?.copyWith(color: Colors.black54),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      children: [
                        if (_adbError != null) ...[
                          Card(
                            margin: EdgeInsets.zero,
                            color: Theme.of(context).colorScheme.errorContainer,
                            child: Padding(
                              padding: const EdgeInsets.all(10),
                              child: Text(
                                _adbError!,
                                style: TextStyle(
                                  fontSize: 13,
                                  color: Theme.of(context).colorScheme.onErrorContainer,
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(height: 8),
                        ],
                        if (_devices.isNotEmpty) ...[
                          Card(
                            margin: EdgeInsets.zero,
                            child: Padding(
                              padding: const EdgeInsets.all(10),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  Text(
                                    'Install target',
                                    style: Theme.of(context).textTheme.labelLarge?.copyWith(
                                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                                        ),
                                  ),
                                  const SizedBox(height: 8),
                                  if (_devices.length > 1)
                                    InputDecorator(
                                      decoration: const InputDecoration(
                                        border: OutlineInputBorder(),
                                        isDense: true,
                                        contentPadding:
                                            EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                                      ),
                                      child: DropdownButtonHideUnderline(
                                        child: DropdownButton<String>(
                                          isDense: true,
                                          isExpanded: true,
                                          value: _serial,
                                          hint: const Text('Select device'),
                                          items: [
                                            for (final d in _devices)
                                              DropdownMenuItem(
                                                value: d.serial,
                                                child: Text(d.shortLabel,
                                                    overflow: TextOverflow.ellipsis),
                                              ),
                                          ],
                                          onChanged: (v) async {
                                            if (v == null) return;
                                            setState(() => _serial = v);
                                            await _loadDeviceDetails();
                                            await _refreshDeviceVersions();
                                          },
                                        ),
                                      ),
                                    )
                                  else
                                    Text(
                                      _devices.first.shortLabel,
                                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                                            fontWeight: FontWeight.w600,
                                          ),
                                    ),
                                ],
                              ),
                            ),
                          ),
                          const SizedBox(height: 8),
                        ],
                        Text(
                          _devices.isEmpty
                              ? 'Enable USB debugging, then Scan device in the app bar.'
                              : 'Installation uses the selected device above.',
                          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                color: Colors.black54,
                                height: 1.35,
                              ),
                        ),
                        const SizedBox(height: 6),
                        ListenableBuilder(
                          listenable: AppPaths.apkLibraryDirectoryListenable,
                          builder: (context, _) {
                            return FutureBuilder<(Directory, bool)>(
                              key: ValueKey(AppPaths.apkLibraryDirectoryListenable.value),
                              future: () async {
                                final d = await AppPaths.apkDownloadDirectory();
                                final custom = await AppPaths.isUsingCustomApkLibraryDirectory();
                                return (d, custom);
                              }(),
                              builder: (context, snap) {
                                if (!snap.hasData) {
                                  return const Padding(
                                    padding: EdgeInsets.symmetric(vertical: 4),
                                    child: LinearProgressIndicator(minHeight: 2),
                                  );
                                }
                                final pack = snap.data!;
                                final dir = pack.$1;
                                final isCustom = pack.$2;
                                return Column(
                                  crossAxisAlignment: CrossAxisAlignment.stretch,
                                  children: [
                                    if (isCustom)
                                      Padding(
                                        padding: const EdgeInsets.only(bottom: 6),
                                        child: Text(
                                          'Custom APK / XAPK library folder',
                                          style: Theme.of(context).textTheme.labelMedium?.copyWith(
                                                color: Theme.of(context).colorScheme.primary,
                                                fontWeight: FontWeight.w600,
                                              ),
                                        ),
                                      ),
                                    Text(
                                      dir.path,
                                      style: Theme.of(context).textTheme.labelSmall?.copyWith(
                                            color: Theme.of(context).colorScheme.onSurfaceVariant,
                                            fontSize: 11,
                                          ),
                                      maxLines: 3,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                    const SizedBox(height: 8),
                                    Wrap(
                                      spacing: 8,
                                      runSpacing: 4,
                                      children: [
                                        TextButton.icon(
                                          onPressed: _pickApkLibraryFolder,
                                          icon: const Icon(Icons.folder_open_outlined, size: 18),
                                          label: const Text('Choose library folder'),
                                        ),
                                        if (isCustom)
                                          TextButton(
                                            onPressed: _resetApkLibraryFolder,
                                            child: const Text('Use default folder'),
                                          ),
                                      ],
                                    ),
                                  ],
                                );
                              },
                            );
                          },
                        ),
                        _buildInstallSummaryBar(context),
                        if (_deviceProps != null) ...[
                          const SizedBox(height: 8),
                          Card(
                            margin: EdgeInsets.zero,
                            child: Padding(
                              padding: const EdgeInsets.all(10),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    'Device info',
                                    style: Theme.of(context).textTheme.labelLarge?.copyWith(
                                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                                        ),
                                  ),
                                  const SizedBox(height: 6),
                                  Text(
                                    [
                                      if ((_deviceProps!['manufacturer'] ?? '').isNotEmpty)
                                        _deviceProps!['manufacturer']!,
                                      if ((_deviceProps!['model'] ?? '').isNotEmpty)
                                        _deviceProps!['model']!,
                                    ].join(' '),
                                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                                          fontWeight: FontWeight.w600,
                                        ),
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    'Android ${_deviceProps!['android'] ?? '?'} · API ${_deviceProps!['sdk'] ?? '?'}',
                                    style: Theme.of(context)
                                        .textTheme
                                        .bodySmall
                                        ?.copyWith(color: Colors.black54),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                  if (_rows.isNotEmpty) ...[
                    TextField(
                      controller: _librarySearchCtl,
                      decoration: InputDecoration(
                        hintText: 'Search APK / XAPK library…',
                        prefixIcon: const Icon(Icons.search_rounded),
                        suffixIcon: _librarySearchCtl.text.isEmpty
                            ? null
                            : IconButton(
                                tooltip: 'Clear',
                                onPressed: () => _librarySearchCtl.clear(),
                                icon: const Icon(Icons.clear_rounded),
                              ),
                        border: const OutlineInputBorder(),
                        isDense: true,
                      ),
                    ),
                    const SizedBox(height: 10),
                  ],
                  Expanded(
                    child: _rows.isEmpty
                        ? Center(
                            child: Text(
                              'No APK or XAPK yet.\nUse Search & download to add files.',
                              textAlign: TextAlign.center,
                              style: Theme.of(context)
                                  .textTheme
                                  .bodyMedium
                                  ?.copyWith(color: Colors.black54),
                            ),
                          )
                        : _filteredLibraryRows.isEmpty
                            ? Center(
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(horizontal: 24),
                                  child: Text(
                                    'No library entries match "${_librarySearchCtl.text.trim()}".',
                                    textAlign: TextAlign.center,
                                    style: Theme.of(context)
                                        .textTheme
                                        .bodyMedium
                                        ?.copyWith(color: Colors.black54),
                                  ),
                                ),
                              )
                            : ListView.separated(
                                itemCount: _filteredLibraryRows.length,
                                separatorBuilder: (context, i) => const SizedBox(height: 10),
                                itemBuilder: (context, i) =>
                                    _buildCard(context, _filteredLibraryRows[i]),
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

  Widget _buildCard(BuildContext context, _LocalRow row) {
    final t = Theme.of(context).textTheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: row.icon != null
                      ? Image.memory(row.icon!, width: 56, height: 56, fit: BoxFit.cover)
                      : Container(
                          width: 56,
                          height: 56,
                          color: Theme.of(context).colorScheme.surfaceContainerHighest,
                          child: Icon(row.isXapk ? Icons.layers_outlined : Icons.android_rounded),
                        ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        row.badging?.label ?? row.title ?? row.displayName,
                        style: t.titleMedium?.copyWith(fontWeight: FontWeight.w600),
                      ),
                      if (row.localVersion != null && row.localVersion!.trim().isNotEmpty) ...[
                        const SizedBox(height: 2),
                        Text(
                          'v${row.localVersion}',
                          style: t.bodyMedium?.copyWith(fontWeight: FontWeight.w500, color: Theme.of(context).colorScheme.primary),
                        ),
                      ],
                      if (row.packageId != null && row.packageId!.trim().isNotEmpty) ...[
                        const SizedBox(height: 4),
                        Text(
                          row.packageId!,
                          style: t.labelSmall?.copyWith(
                            color: Theme.of(context).colorScheme.onSurfaceVariant,
                            fontFamily: 'monospace',
                          ),
                        ),
                      ],
                      const SizedBox(height: 4),
                      Text(
                        [
                          row.displayName,
                          if (row.isXapk) 'XAPK',
                        ].join(' · '),
                        style: t.labelSmall?.copyWith(color: Theme.of(context).colorScheme.outline),
                      ),
                      if (row.installed != null) ...[
                        const SizedBox(height: 6),
                        Text(
                          row.installed!
                              ? 'On device: v${row.deviceVersion ?? '?'}'
                              : 'Not installed on device',
                          style: t.labelMedium,
                        ),
                      ],
                      if (row.remoteVersion != null) ...[
                        const SizedBox(height: 4),
                        Text(
                          'Online: v${row.remoteVersion}'
                          '${row.updateAvailable == true ? ' (newer)' : row.updateAvailable == false ? ' (same or older)' : ''}',
                          style: t.labelMedium?.copyWith(color: Theme.of(context).colorScheme.primary),
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  alignment: WrapAlignment.end,
                  children: [
                    FilledButton(
                      onPressed: row.metaBusy ? null : () => _install(row),
                      child: const Text('Install'),
                    ),
                    OutlinedButton(
                      onPressed: row.checkBusy ? null : () => _checkOnline(row),
                      child: row.checkBusy
                          ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                          : const Text('Check update'),
                    ),
                    if (row.updateAvailable == true && row.updateRelease != null)
                      FilledButton.tonal(
                        onPressed: row.downloadUpdateBusy ? null : () => _downloadNewerVersion(row),
                        child: row.downloadUpdateBusy
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(strokeWidth: 2),
                              )
                            : const Text('Download newer'),
                      ),
                    
                    OutlinedButton(
                      onPressed: row.metaBusy ? null : () => _deleteLocalFile(row),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: Theme.of(context).colorScheme.error,
                      ),
                      child: const Text('Delete file'),
                    ),
                  ],
                ),
              ],
            ),
            _buildActivitiesUnderRow(context, row),
          ],
        ),
      ),
    );
  }
}
