import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:collection/collection.dart';
import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import 'app_theme.dart';
import 'services/aapt_service.dart';
import 'services/adb_paths.dart';
import 'services/adb_service.dart';
import 'services/apk_library_folder_helper.dart';
import 'services/app_paths.dart';
import 'services/cancellation.dart';
import 'services/combined_apk_store_service.dart';
import 'services/download_queue.dart';
import 'services/install_queue.dart';
import 'services/library_apk_metadata_cache.dart';
import 'services/xapk_service.dart';
import 'ui/install_queue_panel.dart';
import 'widgets/branded_app_bar.dart';

const _installableExtensions = {'.apk', '.xapk', '.apks'};

bool _isInstallable(String path) => _installableExtensions.contains(p.extension(path).toLowerCase());

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
  /// When the file landed in the library (file modified time) — drives the "Newest" tag.
  DateTime? addedAt;

  String get path => file.path;
  String get displayName => p.basename(path);
  String get label => badging?.label ?? title ?? displayName;
}

class _LocalInstallPageState extends State<LocalInstallPage> {
  final _adb = AdbService();
  final _aapt = AaptService();
  final _xapk = XapkService();
  final _store = CombinedApkStoreService.shared;
  final _queue = InstallQueue.instance;
  final TextEditingController _librarySearchCtl = TextEditingController();
  StreamSubscription<InstallJob>? _finishedSub;

  static const _metaConcurrency = 6;

  List<AdbDevice> _devices = [];
  String? _serial;
  /// Install to every connected device at once (only offered with 2+ devices).
  bool _allDevices = false;
  List<_LocalRow> _rows = [];
  final Set<String> _selected = {};
  bool _scanning = false;
  bool _dragging = false;
  String? _adbError;
  Map<String, String>? _deviceProps;

  /// Library order: false = A–Z (default), true = newest files first. Persisted.
  bool _newestFirst = false;
  static const _prefsNewestFirst = 'library_sort_newest_first';

  List<_LocalRow> get _sortedRows {
    if (!_newestFirst) return _rows;
    final epoch = DateTime.fromMillisecondsSinceEpoch(0);
    return [..._rows]..sort((a, b) => (b.addedAt ?? epoch).compareTo(a.addedAt ?? epoch));
  }

  Future<void> _setNewestFirst(bool v) async {
    setState(() => _newestFirst = v);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_prefsNewestFirst, v);
    } catch (_) {}
  }

  List<_LocalRow> get _filteredLibraryRows {
    final q = _librarySearchCtl.text.trim().toLowerCase();
    final rows = _sortedRows;
    if (q.isEmpty) return rows;
    bool hit(_LocalRow r) {
      if (r.displayName.toLowerCase().contains(q)) return true;
      final title = (r.badging?.label ?? r.title ?? '').toLowerCase();
      if (title.contains(q)) return true;
      final pkg = (r.packageId ?? '').toLowerCase();
      if (pkg.contains(q)) return true;
      if (r.path.toLowerCase().contains(q)) return true;
      return false;
    }

    return rows.where(hit).toList();
  }

  /// The most recently added library file (only tagged when there is more than one file).
  String? get _newestPath {
    if (_rows.length < 2) return null;
    _LocalRow? best;
    for (final r in _rows) {
      if (r.addedAt == null) continue;
      if (best == null || r.addedAt!.isAfter(best.addedAt!)) best = r;
    }
    return best?.path;
  }

  List<AdbDevice> get _targets {
    if (_devices.isEmpty) return const [];
    if (_allDevices && _devices.length > 1) return _devices;
    final d = _devices.firstWhereOrNull((x) => x.serial == _serial) ?? _devices.first;
    return [d];
  }

  @override
  void initState() {
    super.initState();
    _librarySearchCtl.addListener(() {
      if (mounted) setState(() {});
    });
    _finishedSub = _queue.finished.listen(_onJobFinished);
    SharedPreferences.getInstance().then((prefs) {
      final v = prefs.getBool(_prefsNewestFirst) ?? false;
      if (mounted && v != _newestFirst) setState(() => _newestFirst = v);
    }).catchError((_) {});
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await _refreshPackages();
      if (mounted && _devices.isEmpty) unawaited(_scanDevices());
    });
  }

  @override
  void dispose() {
    _finishedSub?.cancel();
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
      setState(() => _selected.remove(row.path));
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
      setState(() => _adbError = e is StateError ? e.message : e.toString());
    } finally {
      if (mounted) setState(() => _scanning = false);
    }
  }

  Future<void> _renameRowToSanitizedApplicationLabel(_LocalRow row) async {
    if (!row.file.existsSync()) return;
    final stem = AaptService.sanitizeFileStem(row.badging?.label?.trim() ?? '');
    if (stem.isEmpty) return;

    final ext = p.extension(row.file.path).toLowerCase();
    if (!_installableExtensions.contains(ext)) return;

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
        .where((f) => _isInstallable(f.path))
        .toList()
      ..sort((a, b) => a.path.toLowerCase().compareTo(b.path.toLowerCase()));

    final rows = [
      for (final f in files)
        _LocalRow(f)..addedAt = (() {
          try {
            return f.statSync().modified;
          } catch (_) {
            return null;
          }
        })(),
    ];
    if (!mounted) return;
    setState(() {
      _rows = rows;
      final paths = rows.map((r) => r.path).toSet();
      _selected.removeWhere((x) => !paths.contains(x));
    });

    await _loadLibraryRowsMeta(rows);
    if (mounted) setState(() {});
    await _refreshDeviceVersions();
  }

  Future<void> _loadLibraryRowsMeta(List<_LocalRow> rows) async {
    // Worker pool: a slow XAPK no longer holds up the whole batch behind it.
    var next = 0;
    var sinceRepaint = 0;
    Future<void> worker() async {
      while (next < rows.length) {
        final row = rows[next++];
        await _loadLibraryRowMeta(row);
        if (++sinceRepaint >= _metaConcurrency && mounted) {
          sinceRepaint = 0;
          setState(() {});
        }
      }
    }

    await Future.wait([for (var i = 0; i < _metaConcurrency; i++) worker()]);
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
    final ext = p.extension(row.path).toLowerCase();
    row.isXapk = ext == '.xapk' || ext == '.apks';
    try {
      if (row.isXapk) {
        final peek = await _xapk.peek(row.path);
        row.packageId = peek.packageName;
        row.localVersion = peek.versionName;
        row.title = row.displayName;
        final sample = peek.sampleApkEntry;
        if (sample != null && peek.zip != null) {
          // Unpack only the base APK (not the whole XAPK) so aapt can read its label and icon.
          final tmpDir = await Directory.systemTemp.createTemp('hk_peek_');
          try {
            final tmp = p.join(tmpDir.path, 'base.apk');
            await peek.zip!.extractTo(sample, tmp);
            row.badging = await _aapt.readBadging(tmp);
            row.icon = await _aapt.readLauncherIconBytes(tmp, badging: row.badging);
          } finally {
            await tmpDir.delete(recursive: true);
          }
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
        row.icon = await _aapt.readLauncherIconBytes(row.file.path, badging: row.badging);
        await _renameRowToSanitizedApplicationLabel(row);
      }
    } catch (e) {
      row.title = row.displayName;
    } finally {
      row.metaBusy = false;
    }
  }

  /// One adb round-trip for the whole library (was two adb calls per row).
  Future<void> _refreshDeviceVersions({List<_LocalRow>? only}) async {
    final serial = _serial;
    if (serial == null) return;
    final rows = (only ?? _rows).where((r) => r.packageId != null).toList();
    if (rows.isEmpty) return;
    try {
      final versions = await _adb.installedVersionNames(serial, rows.map((r) => r.packageId!));
      for (final row in rows) {
        if (!versions.containsKey(row.packageId)) continue;
        final v = versions[row.packageId];
        row.installed = v != null;
        row.deviceVersion = v;
      }
    } catch (_) {}
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
      // Known package: ask every source for that exact app; otherwise resolve the name first.
      var pkg = row.packageId;
      if (pkg == null || !pkg.contains('.')) {
        final hits = await _store.search(query);
        pkg = hits.firstOrNull?.packageId;
      }
      final rel = pkg == null ? null : await _store.latestFor(pkg, title: row.label);
      if (rel == null) {
        row.remoteVersion = null;
        row.updateAvailable = null;
        row.updateRelease = null;
        if (mounted) _toast('No download source has "$query".');
        return;
      }
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
      final ext = '.${rel.option?.extension ?? (rel.downloadUrl.toUpperCase().contains('XAPK') ? 'xapk' : 'apk')}';
      final stem = AaptService.sanitizeFileStem(row.badging?.label?.trim() ?? '');
      final baseName = stem.isNotEmpty
          ? stem
          : (row.packageId != null && row.packageId!.contains('.'))
              ? row.packageId!
              : p.basenameWithoutExtension(row.path);
      final dest = File(p.join(dir.path, '$baseName$ext'));
      final saved = await DownloadQueue.instance.beginStoreDownload(
        store: _store,
        info: rel,
        label: row.title ?? row.displayName,
        destination: dest,
      );
      if (!mounted) return;
      _toast('Saved newer build to ${saved.path}');
      await _refreshPackages();
    } on OperationCanceled {
      // Canceled from the Downloads tab.
    } catch (e) {
      if (mounted) _toast('Download failed: $e');
    } finally {
      if (mounted) setState(() => row.downloadUpdateBusy = false);
    }
  }

  void _onJobFinished(InstallJob job) {
    if (!mounted || !job.targets.any((t) => t.stage == InstallStage.done)) return;
    final serial = _serial;
    if (serial == null || !job.targets.any((t) => t.serial == serial)) return;
    final rows = _rows.where((r) =>
        r.path == job.sourcePath || (job.packageName != null && r.packageId == job.packageName));
    unawaited(_refreshDeviceVersions(only: rows.toList()));
  }

  void _install(Iterable<_LocalRow> rows) {
    final targets = _targets;
    if (targets.isEmpty) {
      _toast('Connect a device with USB debugging, then press Scan.');
      return;
    }
    for (final row in rows) {
      _queue.enqueue(sourcePath: row.path, label: row.label, devices: targets);
    }
    setState(() => _selected.clear());
  }

  Future<void> _installExternalFiles(List<String> paths) async {
    final files = <String>[];
    for (final path in paths) {
      if (await FileSystemEntity.isDirectory(path)) {
        await for (final e in Directory(path).list(recursive: true, followLinks: false)) {
          if (e is File && _isInstallable(e.path)) files.add(e.path);
        }
      } else if (_isInstallable(path)) {
        files.add(path);
      }
    }
    if (files.isEmpty) {
      _toast('Drop .apk, .xapk or .apks files (or a folder containing them).');
      return;
    }
    final libDir = await AppPaths.apkDownloadDirectory();
    final outside = files.where((f) => !p.isWithin(libDir.path, f)).toList();

    if (_targets.isEmpty) {
      // Nothing to install to — keep them for later instead.
      await _copyIntoLibrary(outside);
      return;
    }
    final targets = _targets;
    for (final f in files) {
      final row = _rows.firstWhereOrNull((r) => r.path == f);
      _queue.enqueue(sourcePath: f, label: row?.label ?? p.basename(f), devices: targets);
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Installing ${files.length} ${files.length == 1 ? 'file' : 'files'} '
            'on ${targets.length == 1 ? targets.single.shortLabel : '${targets.length} devices'}'),
        action: outside.isEmpty
            ? null
            : SnackBarAction(label: 'Also add to library', onPressed: () => _copyIntoLibrary(outside)),
      ),
    );
  }

  Future<void> _copyIntoLibrary(List<String> files) async {
    if (files.isEmpty) return;
    final dir = await AppPaths.apkDownloadDirectory();
    var copied = 0;
    for (final f in files) {
      try {
        var dest = File(p.join(dir.path, p.basename(f)));
        for (var i = 2; dest.existsSync(); i++) {
          dest = File(p.join(dir.path, '${p.basenameWithoutExtension(f)} ($i)${p.extension(f)}'));
        }
        await File(f).copy(dest.path);
        copied++;
      } catch (e) {
        _toast('Could not copy ${p.basename(f)}: $e');
      }
    }
    if (copied > 0) {
      _toast('Added $copied ${copied == 1 ? 'file' : 'files'} to the library.');
      await _refreshPackages();
    }
  }

  Future<void> _pickFilesToInstall() async {
    final files = await openFiles(acceptedTypeGroups: const [
      XTypeGroup(label: 'Android packages', extensions: ['apk', 'xapk', 'apks']),
    ]);
    if (files.isEmpty) return;
    await _installExternalFiles([for (final f in files) f.path]);
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final visible = _filteredLibraryRows;
    final allVisibleSelected = visible.isNotEmpty && visible.every((r) => _selected.contains(r.path));
    return Scaffold(
      appBar: BrandedAppBar(
        title: const Text('Install'),
        actions: [
          TextButton.icon(
            onPressed: _pickFilesToInstall,
            icon: const Icon(Icons.add_rounded, size: 20),
            label: const Text('Install files…'),
          ),
          TextButton.icon(
            onPressed: _openApkFolder,
            icon: const Icon(Icons.folder_outlined, size: 20),
            label: const Text('Open folder'),
          ),
          IconButton(
            tooltip: 'Reload library',
            onPressed: _refreshPackages,
            icon: const Icon(Icons.sync_rounded, size: 20),
          ),
          const SizedBox(width: 8),
        ],
      ),
      bottomNavigationBar: _selected.isEmpty ? null : _buildSelectionBar(context),
      body: DropTarget(
        onDragEntered: (_) => setState(() => _dragging = true),
        onDragExited: (_) => setState(() => _dragging = false),
        onDragDone: (d) {
          setState(() => _dragging = false);
          _installExternalFiles([for (final f in d.files) f.path]);
        },
        child: Stack(
          children: [
            LayoutBuilder(
              builder: (context, box) {
                final wide = box.maxWidth >= 1080;
                final showQueue = _queue.jobs.isNotEmpty || wide;
                final main = Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _buildDeviceBar(context),
                    const SizedBox(height: 10),
                    _buildLibraryBar(context),
                    const SizedBox(height: 10),
                    if (_rows.isNotEmpty) ...[
                      Row(
                        children: [
                          Expanded(
                            child: TextField(
                              controller: _librarySearchCtl,
                              decoration: InputDecoration(
                                hintText: 'Search ${_rows.length} apps by name, package or file…',
                                prefixIcon: const Icon(Icons.search_rounded),
                                suffixIcon: _librarySearchCtl.text.isEmpty
                                    ? null
                                    : IconButton(
                                        tooltip: 'Clear',
                                        onPressed: () => _librarySearchCtl.clear(),
                                        icon: const Icon(Icons.clear_rounded),
                                      ),
                                isDense: true,
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          TextButton.icon(
                            onPressed: visible.isEmpty
                                ? null
                                : () => setState(() {
                                      if (allVisibleSelected) {
                                        _selected.removeAll(visible.map((r) => r.path));
                                      } else {
                                        _selected.addAll(visible.map((r) => r.path));
                                      }
                                    }),
                            icon: Icon(allVisibleSelected ? Icons.deselect_rounded : Icons.select_all_rounded),
                            label: Text(allVisibleSelected ? 'Deselect' : 'Select all'),
                          ),
                          PopupMenuButton<bool>(
                            tooltip: 'Sort library',
                            initialValue: _newestFirst,
                            onSelected: _setNewestFirst,
                            itemBuilder: (_) => const [
                              PopupMenuItem(value: false, child: Text('Name (A–Z)')),
                              PopupMenuItem(value: true, child: Text('Newest first')),
                            ],
                            child: Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  const Icon(Icons.sort_rounded, size: 20),
                                  const SizedBox(width: 4),
                                  Text(_newestFirst ? 'Newest' : 'A–Z'),
                                ],
                              ),
                            ),
                          ),
                          const DensityToggleButton(),
                        ],
                      ),
                      const SizedBox(height: 10),
                    ],
                    if (!wide && _queue.jobs.isNotEmpty) ...[
                      const InstallQueuePanel(maxHeight: 220),
                      const SizedBox(height: 10),
                    ],
                    Expanded(child: _buildLibraryList(context, visible)),
                  ],
                );
                return Padding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Expanded(child: main),
                      if (wide && showQueue) ...[
                        const SizedBox(width: 16),
                        const SizedBox(width: 360, child: InstallQueuePanel()),
                      ],
                    ],
                  ),
                );
              },
            ),
            if (_dragging)
              Positioned.fill(
                child: IgnorePointer(
                  child: Container(
                    margin: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: scheme.primaryContainer.withValues(alpha: 0.88),
                      borderRadius: BorderRadius.circular(24),
                      border: Border.all(color: scheme.primary, width: 2.5),
                    ),
                    child: Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.file_download_rounded, size: 56, color: scheme.onPrimaryContainer),
                          const SizedBox(height: 12),
                          Text(
                            _targets.isEmpty ? 'Drop to add to your library' : 'Drop to install',
                            style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                                  color: scheme.onPrimaryContainer,
                                  fontWeight: FontWeight.w700,
                                ),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            'APK, XAPK, APKS, or a folder of them',
                            style: TextStyle(color: scheme.onPrimaryContainer),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildSelectionBar(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final n = _selected.length;
    final targets = _targets;
    return Material(
      color: scheme.surfaceContainerHigh,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 10, 16, 10),
          child: Row(
            children: [
              Text('$n selected', style: Theme.of(context).textTheme.titleSmall),
              const SizedBox(width: 12),
              TextButton(onPressed: () => setState(_selected.clear), child: const Text('Clear')),
              const Spacer(),
              if (targets.length > 1)
                Padding(
                  padding: const EdgeInsets.only(right: 12),
                  child: Text('on ${targets.length} devices',
                      style: TextStyle(color: scheme.onSurfaceVariant)),
                ),
              FilledButton.icon(
                onPressed: targets.isEmpty
                    ? null
                    : () => _install(_rows.where((r) => _selected.contains(r.path) && !r.metaBusy)),
                icon: const Icon(Icons.install_mobile_rounded, size: 20),
                label: Text('Install $n'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildDeviceBar(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    final props = _deviceProps;
    final current = _devices.firstWhereOrNull((d) => d.serial == _serial);
    final subtitle = _devices.isEmpty
        ? 'Connect a phone with USB debugging enabled, then press Scan.'
        : [
            if (props != null)
              [props['manufacturer'], props['model']].where((e) => (e ?? '').isNotEmpty).join(' '),
            if (props != null && (props['android'] ?? '').isNotEmpty)
              'Android ${props['android']} · API ${props['sdk']}',
            if (props == null && current != null) current.shortLabel,
          ].join(' · ');
    final compact = DensityController.instance.value;
    return Card(
      child: Padding(
        padding: compact ? const EdgeInsets.fromLTRB(12, 6, 8, 6) : const EdgeInsets.fromLTRB(16, 12, 12, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Container(
                  width: compact ? 32 : 44,
                  height: compact ? 32 : 44,
                  decoration: BoxDecoration(
                    color: _devices.isEmpty ? scheme.surfaceContainerHighest : scheme.primaryContainer,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(
                    _devices.isEmpty ? Icons.phonelink_off_rounded : Icons.smartphone_rounded,
                    color: _devices.isEmpty ? scheme.onSurfaceVariant : scheme.onPrimaryContainer,
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _devices.isEmpty
                            ? 'No device connected'
                            : _devices.length == 1
                                ? 'Installing to ${_devices.single.shortLabel}'
                                : '${_devices.length} devices connected',
                        style: t.titleSmall?.copyWith(fontWeight: FontWeight.w700),
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 2),
                      Text(
                        subtitle,
                        style: t.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                Tooltip(
                  message: 'Also copy OBB game data from XAPKs to the device',
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text('OBB data', style: t.labelMedium?.copyWith(color: scheme.onSurfaceVariant)),
                      const SizedBox(width: 4),
                      ListenableBuilder(
                        listenable: _queue,
                        builder: (context, _) => Switch(
                          value: _queue.copyObb,
                          onChanged: (v) => _queue.setCopyObb(v),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton.tonalIcon(
                  onPressed: _scanning ? null : _scanDevices,
                  icon: _scanning
                      ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.usb_rounded, size: 20),
                  label: const Text('Scan'),
                ),
              ],
            ),
            if (_devices.length > 1) ...[
              const SizedBox(height: 10),
              Wrap(
                spacing: 8,
                runSpacing: 6,
                children: [
                  for (final d in _devices)
                    ChoiceChip(
                      label: Text(d.shortLabel),
                      selected: !_allDevices && d.serial == _serial,
                      onSelected: (_) async {
                        setState(() {
                          _allDevices = false;
                          _serial = d.serial;
                        });
                        await _loadDeviceDetails();
                        await _refreshDeviceVersions();
                      },
                    ),
                  ChoiceChip(
                    avatar: const Icon(Icons.devices_rounded, size: 18),
                    label: Text('All ${_devices.length} devices'),
                    selected: _allDevices,
                    onSelected: (_) => setState(() => _allDevices = true),
                  ),
                ],
              ),
            ],
            if (_adbError != null) ...[
              const SizedBox(height: 10),
              DecoratedBox(
                decoration: BoxDecoration(
                  color: scheme.errorContainer,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(10),
                  child: SelectableText(
                    _adbError!,
                    style: TextStyle(fontSize: 13, color: scheme.onErrorContainer),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildLibraryBar(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    return ListenableBuilder(
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
            final dir = snap.data?.$1;
            final isCustom = snap.data?.$2 ?? false;
            return Row(
              children: [
                Icon(Icons.folder_special_rounded, size: 20, color: scheme.primary),
                const SizedBox(width: 8),
                Text(
                  isCustom ? 'Library (custom)' : 'Library',
                  style: t.labelLarge?.copyWith(fontWeight: FontWeight.w700),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    dir?.path ?? '…',
                    style: t.labelSmall?.copyWith(color: scheme.onSurfaceVariant),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                TextButton(onPressed: _pickApkLibraryFolder, child: const Text('Change…')),
                if (isCustom) TextButton(onPressed: _resetApkLibraryFolder, child: const Text('Use default')),
              ],
            );
          },
        );
      },
    );
  }

  Widget _buildLibraryList(BuildContext context, List<_LocalRow> visible) {
    final scheme = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    if (_rows.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.inventory_2_outlined, size: 56, color: scheme.primary.withValues(alpha: 0.7)),
            const SizedBox(height: 14),
            Text('Your library is empty', style: t.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
            const SizedBox(height: 6),
            Text(
              'Drop APK or XAPK files here, use Install files…, or grab apps from Search.',
              textAlign: TextAlign.center,
              style: t.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ],
        ),
      );
    }
    if (visible.isEmpty) {
      return Center(
        child: Text(
          'No library entries match "${_librarySearchCtl.text.trim()}".',
          textAlign: TextAlign.center,
          style: t.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
        ),
      );
    }
    return ListenableBuilder(
      listenable: Listenable.merge([_queue, DensityController.instance]),
      builder: (context, _) => ListView.separated(
        itemCount: visible.length,
        separatorBuilder: (context, i) => SizedBox(height: DensityController.instance.value ? 4 : 8),
        itemBuilder: (context, i) => _buildCard(context, visible[i]),
      ),
    );
  }

  Widget _chip(BuildContext context, String text, {Color? bg, Color? fg, IconData? icon}) {
    final scheme = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: bg ?? scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null) ...[
              Icon(icon, size: 13, color: fg ?? scheme.onSurfaceVariant),
              const SizedBox(width: 4),
            ],
            Text(
              text,
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: fg ?? scheme.onSurfaceVariant,
                    fontWeight: FontWeight.w600,
                  ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCard(BuildContext context, _LocalRow row) {
    final scheme = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    final job = _queue.latestFor(row.path);
    final busy = job != null && !job.finished;
    final selected = _selected.contains(row.path);
    final sameAsDevice = row.installed == true &&
        row.deviceVersion != null &&
        row.localVersion != null &&
        row.deviceVersion == row.localVersion;
    final compact = DensityController.instance.value;
    final iconSize = compact ? 32.0 : 48.0;
    final isNewest = row.path == _newestPath;

    return Card(
      color: selected ? scheme.primaryContainer.withValues(alpha: 0.35) : null,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => setState(() => selected ? _selected.remove(row.path) : _selected.add(row.path)),
        child: Padding(
          padding: compact ? const EdgeInsets.fromLTRB(2, 3, 8, 3) : const EdgeInsets.fromLTRB(6, 10, 12, 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Checkbox(
                    value: selected,
                    onChanged: (v) => setState(() => v == true ? _selected.add(row.path) : _selected.remove(row.path)),
                  ),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(compact ? 8 : 12),
                    child: row.icon != null
                        ? Image.memory(row.icon!,
                            width: iconSize, height: iconSize, fit: BoxFit.cover, gaplessPlayback: true)
                        : Container(
                            width: iconSize,
                            height: iconSize,
                            color: scheme.surfaceContainerHighest,
                            child: row.metaBusy
                                ? Padding(
                                    padding: EdgeInsets.all(compact ? 8 : 14),
                                    child: const CircularProgressIndicator(strokeWidth: 2),
                                  )
                                : Icon(row.isXapk ? Icons.layers_outlined : Icons.android_rounded,
                                    color: scheme.onSurfaceVariant),
                          ),
                  ),
                  SizedBox(width: compact ? 10 : 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Flexible(
                              child: Text(
                                row.label,
                                style: (compact ? t.bodyMedium : t.titleSmall)?.copyWith(fontWeight: FontWeight.w700),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            if (isNewest) ...[
                              const SizedBox(width: 8),
                              _chip(context, 'Newest',
                                  icon: Icons.fiber_new_rounded,
                                  bg: scheme.secondaryContainer,
                                  fg: scheme.onSecondaryContainer),
                            ],
                            if (compact) ...[
                              const SizedBox(width: 8),
                              Flexible(
                                child: Text(
                                  [
                                    if (row.localVersion != null && row.localVersion!.trim().isNotEmpty)
                                      'v${row.localVersion}',
                                    if (row.isXapk) 'XAPK',
                                    if (row.installed == true)
                                      sameAsDevice ? 'Installed' : 'On device v${row.deviceVersion ?? '?'}',
                                    if (row.remoteVersion != null)
                                      'Store v${row.remoteVersion}${row.updateAvailable == true ? ' (newer)' : ''}',
                                  ].join(' · '),
                                  style: t.labelSmall?.copyWith(color: scheme.onSurfaceVariant),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ],
                          ],
                        ),
                        if (!compact) ...[
                        const SizedBox(height: 2),
                        Text(
                          [
                            if (row.packageId != null && row.packageId!.trim().isNotEmpty) row.packageId!,
                            row.displayName,
                          ].join(' · '),
                          style: t.labelSmall?.copyWith(color: scheme.onSurfaceVariant),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 6),
                        Wrap(
                          spacing: 6,
                          runSpacing: 4,
                          children: [
                            if (row.localVersion != null && row.localVersion!.trim().isNotEmpty)
                              _chip(context, 'v${row.localVersion}',
                                  bg: scheme.primaryContainer.withValues(alpha: 0.6), fg: scheme.onPrimaryContainer),
                            if (row.isXapk) _chip(context, 'XAPK', icon: Icons.layers_rounded),
                            if (row.installed == true)
                              sameAsDevice
                                  ? _chip(context, 'Installed', icon: Icons.check_rounded,
                                      bg: scheme.successContainer, fg: scheme.success)
                                  : _chip(context, 'On device v${row.deviceVersion ?? '?'}',
                                      icon: Icons.smartphone_rounded),
                            if (row.installed == false) _chip(context, 'Not on device'),
                            if (row.remoteVersion != null)
                              _chip(
                                context,
                                'Store v${row.remoteVersion}${row.updateAvailable == true ? ' · newer' : ''}',
                                icon: Icons.storefront_rounded,
                                bg: row.updateAvailable == true ? scheme.tertiaryContainer : null,
                                fg: row.updateAvailable == true ? scheme.onTertiaryContainer : null,
                              ),
                          ],
                        ),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(width: 12),
                  if (row.updateAvailable == true && row.updateRelease != null) ...[
                    FilledButton.tonal(
                      onPressed: row.downloadUpdateBusy ? null : () => _downloadNewerVersion(row),
                      child: row.downloadUpdateBusy
                          ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                          : const Text('Download newer'),
                    ),
                    const SizedBox(width: 8),
                  ],
                  FilledButton.icon(
                    onPressed: row.metaBusy || busy ? null : () => _install([row]),
                    icon: busy
                        ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.install_mobile_rounded, size: 18),
                    label: Text(busy ? stageLabel(job.stage) : 'Install'),
                    style: compact
                        ? FilledButton.styleFrom(
                            textStyle: t.labelMedium?.copyWith(fontWeight: FontWeight.w600),
                            minimumSize: const Size(0, 30),
                          )
                        : null,
                  ),
                  const SizedBox(width: 4),
                  IconButton(
                    tooltip: 'Check for update',
                    onPressed: row.checkBusy ? null : () => _checkOnline(row),
                    icon: row.checkBusy
                        ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.update_rounded),
                  ),
                  PopupMenuButton<String>(
                    tooltip: 'More',
                    enabled: !row.metaBusy,
                    onSelected: (v) {
                      if (v == 'delete') _deleteLocalFile(row);
                    },
                    itemBuilder: (c) => [
                      PopupMenuItem(
                        value: 'delete',
                        child: Row(
                          children: [
                            Icon(Icons.delete_outline_rounded, color: scheme.error),
                            const SizedBox(width: 10),
                            Text('Delete file', style: TextStyle(color: scheme.error)),
                          ],
                        ),
                      ),
                    ],
                  ),
                ],
              ),
              if (job != null) _buildJobLine(context, job),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildJobLine(BuildContext context, InstallJob job) {
    final scheme = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    final progress = job.progress;
    if (!job.finished) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(48, 10, 4, 0),
        child: Row(
          children: [
            Expanded(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: LinearProgressIndicator(
                  minHeight: 5,
                  value: job.stage == InstallStage.queued ? 0 : progress,
                ),
              ),
            ),
            const SizedBox(width: 10),
            Text(
              '${stageLabel(job.stage)}${progress != null ? ' ${(progress * 100).round()}%' : ''}',
              style: t.labelSmall?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ],
        ),
      );
    }
    if (job.stage == InstallStage.canceled) return const SizedBox.shrink();
    final ok = job.succeeded;
    final detail = ok
        ? '${job.targets.length > 1 ? 'Installed on ${job.targets.length} devices' : job.targets.single.detail}'
            '${job.elapsed != null ? ' in ${formatDuration(job.elapsed!)}' : ''}'
        : (job.error ?? 'Install failed');
    return Padding(
      padding: const EdgeInsets.fromLTRB(48, 10, 4, 0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(ok ? Icons.check_circle_rounded : Icons.error_rounded,
              size: 16, color: ok ? scheme.success : scheme.error),
          const SizedBox(width: 6),
          Expanded(
            child: SelectableText(
              detail,
              maxLines: ok ? 1 : 5,
              style: t.bodySmall?.copyWith(color: ok ? scheme.success : scheme.error, height: 1.3),
            ),
          ),
        ],
      ),
    );
  }
}
