import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import 'app_shell_nav.dart';
import 'app_theme.dart';
import 'services/adb_service.dart';
import 'services/app_catalog.dart';
import 'services/app_paths.dart';
import 'services/cancellation.dart';
import 'services/combined_apk_store_service.dart';
import 'services/download_queue.dart';
import 'services/install_queue.dart';
import 'services/store_search_settings.dart';
import 'ui/install_queue_panel.dart' show formatBytes;
import 'widgets/branded_app_bar.dart';

/// Search by app name or package across Google Play, Aptoide and Uptodown, then pick a build
/// from APKPure / Aptoide / Uptodown / F-Droid and download (or download and install) it.
class ApkpureSearchPage extends StatefulWidget {
  const ApkpureSearchPage({super.key});

  @override
  State<ApkpureSearchPage> createState() => _ApkpureSearchPageState();
}

class _ApkpureSearchPageState extends State<ApkpureSearchPage> {
  static final CombinedApkStoreService _svc = CombinedApkStoreService.shared;
  AppCatalog get _catalog => _svc.catalog;
  final _controller = TextEditingController();

  List<AppListing> _hits = [];
  bool _searching = false;
  String? _searchError;
  CancellationToken? _searchCancel;
  StreamSubscription<List<AppListing>>? _searchSub;

  AppListing? _selected;
  List<DownloadOption>? _options;
  bool _loadingOptions = false;
  CancellationToken? _optionsCancel;

  /// Options already handed to the download queue (button shows progress instead).
  final Set<DownloadOption> _started = {};

  @override
  void initState() {
    super.initState();
    StoreSearchSettings.instance.ensureLoaded().then((_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _searchSub?.cancel();
    _searchCancel?.cancel();
    _optionsCancel?.cancel();
    _controller.dispose();
    super.dispose();
  }

  Future<void> _toggleSource(StoreSource src, bool on) async {
    final prefs = StoreSearchSettings.instance;
    final next = Set<StoreSource>.from(prefs.sources);
    on ? next.add(src) : next.remove(src);
    if (next.isEmpty) {
      _toast('Keep at least one download source enabled.');
      return;
    }
    await prefs.save(next);
    if (!mounted) return;
    setState(() {});
    if (_selected != null) unawaited(_select(_selected!));
  }

  void _search() {
    final q = _controller.text.trim();
    if (q.isEmpty) return;
    _searchSub?.cancel();
    _searchCancel?.cancel();
    final cancel = _searchCancel = CancellationToken();
    setState(() {
      _searching = true;
      _searchError = null;
      _hits = [];
    });
    _searchSub = _catalog.searchStream(q, cancel: cancel).listen(
      (list) {
        if (!mounted || cancel.isCancelled) return;
        setState(() => _hits = list);
        if (_selected == null && list.isNotEmpty) unawaited(_select(list.first));
      },
      onError: (Object e) {
        if (mounted && e is! OperationCanceled) setState(() => _searchError = '$e');
      },
      onDone: () {
        if (!mounted || cancel.isCancelled) return;
        setState(() {
          _searching = false;
          if (_hits.isEmpty) _searchError = 'Nothing found for "$q". Try the exact app name or its package name.';
        });
      },
    );
    setState(() => _selected = null);
  }

  Future<void> _select(AppListing hit) async {
    _optionsCancel?.cancel();
    final cancel = _optionsCancel = CancellationToken();
    setState(() {
      _selected = hit;
      _options = null;
      _loadingOptions = true;
    });
    try {
      await StoreSearchSettings.instance.ensureLoaded();
      final opts = await _catalog.options(hit, sources: StoreSearchSettings.instance.sources, cancel: cancel);
      if (!mounted || cancel.isCancelled) return;
      setState(() => _options = opts);
    } on OperationCanceled {
      return;
    } catch (e) {
      if (mounted) _toast('Could not load builds: $e');
    } finally {
      if (mounted && !cancel.isCancelled) setState(() => _loadingOptions = false);
    }
  }

  Future<File?> _download(DownloadOption o, {bool switchTab = true}) async {
    setState(() => _started.add(o));
    try {
      final dir = await AppPaths.apkDownloadDirectory();
      final dest = File(p.join(dir.path, '${o.packageId}.${o.extension}'));
      final saved = await DownloadQueue.instance.beginStoreDownload(
        store: _svc,
        info: CombinedApkStoreService.releaseFor(o),
        label: '${o.title} ${o.versionName}',
        destination: dest,
        openDownloadsTab: switchTab,
      );
      if (mounted) _toast('Saved ${p.basename(saved.path)} to your library');
      return saved;
    } on OperationCanceled {
      return null;
    } catch (e) {
      if (mounted) _toast('Download failed: $e');
      return null;
    } finally {
      if (mounted) setState(() => _started.remove(o));
    }
  }

  Future<void> _downloadAndInstall(DownloadOption o) async {
    final devices = await AdbService().listDevices().catchError((_) => <AdbDevice>[]);
    if (!mounted) return;
    if (devices.isEmpty) {
      _toast('No phone connected — downloading only. Connect one and install from the Install tab.');
      await _download(o);
      return;
    }
    var targets = devices;
    if (devices.length > 1) {
      final picked = await showDialog<List<AdbDevice>>(
        context: context,
        builder: (c) => SimpleDialog(
          title: const Text('Install on'),
          children: [
            for (final d in devices)
              SimpleDialogOption(onPressed: () => Navigator.pop(c, [d]), child: Text(d.shortLabel)),
            SimpleDialogOption(
              onPressed: () => Navigator.pop(c, devices),
              child: Text('All ${devices.length} devices', style: const TextStyle(fontWeight: FontWeight.w600)),
            ),
          ],
        ),
      );
      if (picked == null) return;
      targets = picked;
    }
    final saved = await _download(o, switchTab: false);
    if (saved == null) return;
    InstallQueue.instance.enqueue(sourcePath: saved.path, label: o.title, devices: targets);
    AppShellNav.goTo(kShellTabInstall);
  }

  void _openInBrowser(String url) {
    if (Platform.isWindows) {
      Process.run('cmd', ['/c', 'start', '', url]);
    } else if (Platform.isMacOS) {
      Process.run('open', [url]);
    } else {
      Process.run('xdg-open', [url]);
    }
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    final prefs = StoreSearchSettings.instance;
    return Scaffold(
      appBar: BrandedAppBar(title: const Text('Search & download')),
      body: Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _controller,
                    autofocus: true,
                    textInputAction: TextInputAction.search,
                    decoration: InputDecoration(
                      hintText: 'App name or package (e.g. CapCut, PUBG Mobile, com.whatsapp)',
                      prefixIcon: const Icon(Icons.search_rounded),
                      suffixIcon: _searching
                          ? const Padding(
                              padding: EdgeInsets.all(14),
                              child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
                            )
                          : null,
                    ),
                    onSubmitted: (_) => _search(),
                  ),
                ),
                const SizedBox(width: 12),
                FilledButton.icon(
                  onPressed: _search,
                  icon: const Icon(Icons.travel_explore_rounded),
                  label: const Text('Search'),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 6,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Text('Download from', style: t.labelLarge?.copyWith(color: scheme.onSurfaceVariant)),
                for (final s in StoreSource.values)
                  FilterChip(
                    label: Text(s.label),
                    selected: prefs.sources.contains(s),
                    onSelected: (v) => _toggleSource(s, v),
                  ),
                const DensityToggleButton(),
              ],
            ),
            if (_searchError != null) ...[
              const SizedBox(height: 10),
              Text(_searchError!, style: TextStyle(color: scheme.error)),
            ],
            const SizedBox(height: 12),
            Expanded(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(flex: 4, child: _buildResults(context)),
                  const SizedBox(width: 16),
                  Expanded(flex: 5, child: Card(child: _buildDetail(context))),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _icon(String? url, {double size = 44}) {
    final scheme = Theme.of(context).colorScheme;
    final fallback = Container(
      width: size,
      height: size,
      color: scheme.surfaceContainerHighest,
      child: Icon(Icons.android_rounded, color: scheme.onSurfaceVariant, size: size * 0.55),
    );
    return ClipRRect(
      borderRadius: BorderRadius.circular(size * 0.24),
      child: url == null
          ? fallback
          : Image.network(url, width: size, height: size, fit: BoxFit.cover, errorBuilder: (_, _, _) => fallback),
    );
  }

  Widget _buildResults(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    if (_hits.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.manage_search_rounded, size: 56, color: scheme.primary.withValues(alpha: 0.7)),
            const SizedBox(height: 12),
            Text(_searching ? 'Searching Google Play, Aptoide and Uptodown…' : 'Find any Android app',
                style: t.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
            const SizedBox(height: 6),
            Text(
              'Names are matched through Google Play, so you get the real app\neven if the mirror sites name it differently.',
              textAlign: TextAlign.center,
              style: t.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ],
        ),
      );
    }
    final compact = DensityController.instance.value;
    return ListView.separated(
      itemCount: _hits.length,
      separatorBuilder: (_, _) => SizedBox(height: compact ? 3 : 6),
      itemBuilder: (context, i) {
        final h = _hits[i];
        final sel = _selected?.packageId == h.packageId;
        return Card(
          color: sel ? scheme.primaryContainer.withValues(alpha: 0.45) : null,
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: () => _select(h),
            child: Padding(
              padding: EdgeInsets.all(compact ? 6 : 10),
              child: Row(
                children: [
                  _icon(h.iconUrl, size: compact ? 30 : 44),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(h.title,
                            style: t.titleSmall?.copyWith(fontWeight: FontWeight.w700),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis),
                        Text(
                          [h.packageId, if (h.developer != null) h.developer!].join(' · '),
                          style: t.labelSmall?.copyWith(color: scheme.onSurfaceVariant),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        if (!compact) ...[
                          const SizedBox(height: 2),
                          Text(
                            'Found on ${h.foundVia.join(', ')}',
                            style: t.labelSmall?.copyWith(color: scheme.outline),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ],
                    ),
                  ),
                  const Icon(Icons.chevron_right_rounded),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildDetail(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    final sel = _selected;
    if (sel == null) {
      return Center(
        child: Text(
          'Pick an app to see every available build.',
          style: t.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
        ),
      );
    }
    final opts = _options;
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              _icon(sel.iconUrl ?? opts?.map((o) => o.iconUrl).whereType<String>().firstOrNull, size: 56),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(sel.title, style: t.titleLarge?.copyWith(fontWeight: FontWeight.w700)),
                    SelectableText(sel.packageId, style: t.labelMedium?.copyWith(color: scheme.onSurfaceVariant)),
                  ],
                ),
              ),
              if (sel.uptodownPage != null)
                IconButton(
                  tooltip: 'Open Uptodown download page (finish in your browser)',
                  onPressed: () => _openInBrowser('${sel.uptodownPage!}/download'),
                  icon: const Icon(Icons.public_rounded),
                ),
              IconButton(
                tooltip: 'Open on Google Play',
                onPressed: () => _openInBrowser('https://play.google.com/store/apps/details?id=${sel.packageId}'),
                icon: const Icon(Icons.open_in_new_rounded),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              Text('Available builds', style: t.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
              const SizedBox(width: 8),
              if (_loadingOptions)
                const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)),
            ],
          ),
          const SizedBox(height: 8),
          Expanded(
            child: opts == null
                ? Center(
                    child: Text('Asking ${StoreSearchSettings.instance.sources.map((s) => s.label).join(', ')}…',
                        style: t.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
                  )
                : opts.isEmpty
                    ? Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              'None of the enabled sources has a download for this app.\n'
                              'Try enabling more sources above.',
                              textAlign: TextAlign.center,
                              style: t.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
                            ),
                            if (sel.uptodownPage != null) ...[
                              const SizedBox(height: 12),
                              OutlinedButton.icon(
                                onPressed: () => _openInBrowser('${sel.uptodownPage!}/download'),
                                icon: const Icon(Icons.open_in_browser_rounded),
                                label: const Text('Open on Uptodown'),
                              ),
                            ],
                          ],
                        ),
                      )
                    : ListView.separated(
                        itemCount: opts.length,
                        separatorBuilder: (_, _) => const SizedBox(height: 8),
                        itemBuilder: (context, i) => _buildOption(context, opts[i], recommended: i == 0),
                      ),
          ),
        ],
      ),
    );
  }

  Widget _buildOption(BuildContext context, DownloadOption o, {required bool recommended}) {
    final scheme = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    final busy = _started.contains(o);
    final size = o.totalSize;
    final kind = o.hasObb ? 'APK + OBB → XAPK' : o.extension.toUpperCase();
    return DecoratedBox(
      decoration: BoxDecoration(
        color: recommended && o.warning == null
            ? scheme.primaryContainer.withValues(alpha: 0.35)
            : scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: o.warning != null ? scheme.tertiary : scheme.outlineVariant.withValues(alpha: 0.6),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 10, 10),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (recommended && o.warning == null)
                    Text('RECOMMENDED',
                        style: t.labelSmall?.copyWith(
                            color: scheme.primary, fontWeight: FontWeight.w800, letterSpacing: 0.6)),
                  Text('v${o.versionName}',
                      style: t.titleSmall?.copyWith(fontWeight: FontWeight.w700),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis),
                  const SizedBox(height: 2),
                  Text(
                    [
                      o.source.label,
                      kind,
                      if (size != null) formatBytes(size),
                      if (o.updated != null) o.updated!.split(' ').first,
                    ].join(' · '),
                    style: t.labelMedium?.copyWith(color: scheme.onSurfaceVariant),
                  ),
                  if (o.signer != null)
                    Text('Signed by ${o.signer}',
                        style: t.labelSmall?.copyWith(color: scheme.outline),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis),
                  if (o.warning != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Row(
                        children: [
                          Icon(Icons.warning_amber_rounded, size: 15, color: scheme.tertiary),
                          const SizedBox(width: 4),
                          Expanded(child: Text(o.warning!, style: t.labelSmall?.copyWith(color: scheme.tertiary))),
                        ],
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            if (busy)
              const Padding(
                padding: EdgeInsets.all(12),
                child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)),
              )
            else ...[
              IconButton(
                tooltip: 'Download to library',
                onPressed: () => _download(o),
                icon: const Icon(Icons.download_rounded),
              ),
              const SizedBox(width: 4),
              FilledButton.tonalIcon(
                onPressed: () => _downloadAndInstall(o),
                icon: const Icon(Icons.install_mobile_rounded, size: 18),
                label: const Text('Get & install'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
