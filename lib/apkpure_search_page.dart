import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import 'services/app_paths.dart';
import 'services/cancellation.dart';
import 'services/combined_apk_store_service.dart';
import 'services/download_queue.dart';
import 'services/store_search_settings.dart';
import 'ui/blocking_progress.dart';
import 'widgets/branded_app_bar.dart';

class ApkpureSearchPage extends StatefulWidget {
  const ApkpureSearchPage({super.key});

  @override
  State<ApkpureSearchPage> createState() => _ApkpureSearchPageState();
}

class _ApkpureSearchPageState extends State<ApkpureSearchPage> {
  static final CombinedApkStoreService _svc = CombinedApkStoreService.shared;
  final _controller = TextEditingController();
  List<ApkpureSearchHit> _hits = [];
  String? _searchError;
  ApkpureSearchHit? _selected;
  ApkpureReleaseInfo? _detail;
  String? _detailError;

  @override
  void initState() {
    super.initState();
    StoreSearchSettings.instance.ensureLoaded().then((_) {
      if (mounted) setState(() {});
    });
  }

  Future<void> _setSourceSelected(StoreSearchSource src, bool selected) async {
    final prefs = StoreSearchSettings.instance;
    await prefs.ensureLoaded();
    final next = Set<StoreSearchSource>.from(prefs.sources);
    if (selected) {
      next.add(src);
    } else {
      next.remove(src);
    }
    if (next.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Keep at least one store enabled.')),
        );
      }
      return;
    }
    await prefs.save(next);
    if (mounted) setState(() {});
  }

  Widget _buildStoreSourceChips(BuildContext context) {
    final prefs = StoreSearchSettings.instance;
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Search in', style: theme.textTheme.labelLarge?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            FilterChip(
              label: const Text('APKPure'),
              selected: prefs.sources.contains(StoreSearchSource.apkpure),
              onSelected: (v) => _setSourceSelected(StoreSearchSource.apkpure, v),
            ),
            FilterChip(
              label: const Text('APKCombo'),
              selected: prefs.sources.contains(StoreSearchSource.apkcombo),
              onSelected: (v) => _setSourceSelected(StoreSearchSource.apkcombo, v),
            ),
            FilterChip(
              label: const Text('Uptodown'),
              selected: prefs.sources.contains(StoreSearchSource.uptodown),
              onSelected: (v) => _setSourceSelected(StoreSearchSource.uptodown, v),
            ),
          ],
        ),
        const SizedBox(height: 6),
        Text(
          'Enabled stores are queried in order and combined (first store wins duplicates). Preference is saved.',
          style: theme.textTheme.bodySmall?.copyWith(color: Colors.black54, height: 1.35),
        ),
      ],
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _search() async {
    final q = _controller.text.trim();
    if (q.isEmpty) return;
    setState(() {
      _searchError = null;
      _hits = [];
      _selected = null;
      _detail = null;
    });
    try {
      final cancel = CancellationToken();
      final list = await runWithBlockingProgress<List<ApkpureSearchHit>>(
        context,
        message: 'Searching app stores…',
        cancellable: cancel,
        work: () => _svc.search(q, cancel: cancel),
      );
      if (!mounted) return;
      setState(() => _hits = list);
      if (list.isEmpty) {
        setState(() => _searchError = 'No apps found. Try another name or check your network.');
      }
    } on OperationCanceled {
      if (mounted) {
        setState(() => _searchError = null);
      }
    } catch (e) {
      if (mounted) setState(() => _searchError = e.toString());
    }
  }

  Future<void> _select(ApkpureSearchHit hit) async {
    setState(() {
      _selected = hit;
      _detail = null;
      _detailError = null;
    });
    try {
      final d = await runWithBlockingProgress<ApkpureReleaseInfo>(
        context,
        message: 'Loading details…',
        work: () => _svc.fetchRelease(hit),
      );
      if (mounted) setState(() => _detail = d);
    } catch (e) {
      if (mounted) setState(() => _detailError = e.toString());
    }
  }

  Future<void> _download(ApkpureReleaseInfo info, ApkpureSearchHit hit) async {
    try {
      final dir = await AppPaths.apkDownloadDirectory();
      final isXapk = () {
        final u = info.downloadUrl.toLowerCase();
        return info.downloadUrl.toUpperCase().contains('XAPK') ||
            u.contains('.xapk') ||
            u.contains('.apks') ||
            u.contains('xapk-package');
      }();
      final ext = isXapk ? 'xapk' : 'apk';
      final dest = File(p.join(dir.path, '${hit.packageId}.$ext'));
      await DownloadQueue.instance.beginStoreDownload(
        store: _svc,
        info: info,
        label: hit.title,
        destination: dest,
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Saved to ${dest.path}')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: BrandedAppBar(title: const Text('Search & download')),
      body: Padding(
        padding: const EdgeInsets.all(20),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              flex: 5,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    'Downloads keep running if you switch tabs (e.g. to Downloads).',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Colors.black54, height: 1.4),
                  ),
                  const SizedBox(height: 12),
                  _buildStoreSourceChips(context),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _controller,
                          decoration: const InputDecoration(
                            hintText: 'App name (e.g. WhatsApp)',
                            prefixIcon: Icon(Icons.search_rounded),
                          ),
                          onSubmitted: (_) => _search(),
                        ),
                      ),
                      const SizedBox(width: 12),
                      FilledButton(
                        onPressed: _search,
                        child: const Text('Search'),
                      ),
                    ],
                  ),
                  if (_searchError != null) ...[
                    const SizedBox(height: 12),
                    Text(_searchError!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
                  ],
                  const SizedBox(height: 16),
                  Expanded(
                    child: _hits.isEmpty
                        ? Center(
                            child: Text(
                              'Results appear here.',
                              style: Theme.of(context).textTheme.bodyLarge?.copyWith(color: Colors.black45),
                            ),
                          )
                        : ListView.separated(
                            itemCount: _hits.length,
                            separatorBuilder: (context, i) => const SizedBox(height: 8),
                            itemBuilder: (context, i) {
                              final h = _hits[i];
                              final sel = _selected?.packageId == h.packageId &&
                                  _selected?.isUptodown == h.isUptodown &&
                                  _selected?.isApkcombo == h.isApkcombo;
                              return Card(
                                color: sel
                                    ? Theme.of(context).colorScheme.primaryContainer.withValues(alpha: 0.35)
                                    : null,
                                child: ListTile(
                                  title: Text(h.title, maxLines: 2, overflow: TextOverflow.ellipsis),
                                  subtitle: Text(
                                    '${h.packageId}'
                                    '${h.isUptodown ? ' · Uptodown' : ''}'
                                    '${h.isApkcombo ? ' · APKCombo' : ''}',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  trailing: const Icon(Icons.chevron_right_rounded),
                                  onTap: () => _select(h),
                                ),
                              );
                            },
                          ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 20),
            Expanded(
              flex: 4,
              child: Card(
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: _selected == null
                      ? Center(
                          child: Text(
                            'Select an app to see version, release date, and download.',
                            textAlign: TextAlign.center,
                            style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: Colors.black54),
                          ),
                        )
                      : _detailError != null
                          ? Text(_detailError!, style: TextStyle(color: Theme.of(context).colorScheme.error))
                          : _detail == null
                              ? const Center(child: Text('Loading…'))
                              : _buildDetail(_detail!, _selected!),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDetail(ApkpureReleaseInfo info, ApkpureSearchHit hit) {
    final t = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(info.title, style: t.titleLarge?.copyWith(fontWeight: FontWeight.w700)),
        const SizedBox(height: 12),
        _kv('Version', info.version, t),
        _kv('Update date', info.updateDate, t),
        const SizedBox(height: 16),
        Text('Download', style: t.titleSmall?.copyWith(fontWeight: FontWeight.w600)),
        const SizedBox(height: 6),
        SelectableText(info.downloadUrl, style: t.bodySmall),
        const SizedBox(height: 20),
        Row(
          children: [
            FilledButton.icon(
              onPressed: () => _download(info, hit),
              icon: const Icon(Icons.download_rounded),
              label: const Text('Download to APK folder'),
            ),
            const SizedBox(width: 12),
            OutlinedButton(
              onPressed: () async {
                await Process.run('cmd', ['/c', 'start', '', info.pageUrl], runInShell: false);
              },
              child: const Text('Open in browser'),
            ),
          ],
        ),
      ],
    );
  }

  Widget _kv(String k, String v, TextTheme t) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(width: 110, child: Text(k, style: t.labelLarge?.copyWith(color: Colors.black54))),
          Expanded(child: Text(v, style: t.bodyLarge)),
        ],
      ),
    );
  }
}
