import 'dart:io';

import 'package:flutter/material.dart';

import 'app_theme.dart';
import 'services/apk_library_folder_helper.dart';
import 'services/app_paths.dart';
import 'services/download_queue.dart';
import 'widgets/branded_app_bar.dart';

class DownloadsPage extends StatelessWidget {
  const DownloadsPage({super.key});

  static String _formatBytes(int n) {
    if (n < 1024) return '$n B';
    if (n < 1024 * 1024) return '${(n / 1024).toStringAsFixed(1)} KB';
    return '${(n / (1024 * 1024)).toStringAsFixed(2)} MB';
  }

  static String _formatSpeed(double bytesPerSecond) {
    if (bytesPerSecond < 1024) return '${bytesPerSecond.toStringAsFixed(0)} B/s';
    if (bytesPerSecond < 1024 * 1024) return '${(bytesPerSecond / 1024).toStringAsFixed(1)} KB/s';
    return '${(bytesPerSecond / (1024 * 1024)).toStringAsFixed(2)} MB/s';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: BrandedAppBar(
        title: const Text('Downloads'),
        actions: [
          TextButton(
            onPressed: () => DownloadQueue.instance.clearFinished(),
            child: const Text('Clear finished'),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
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
                      return Text(
                        'Files save to: …',
                        style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                      );
                    }
                    final pack = snap.data!;
                    final pth = pack.$1.path;
                    final custom = pack.$2;
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '${custom ? 'Custom library — ' : ''}files save to:',
                          style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                        ),
                        SelectableText(
                          pth,
                          style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurface),
                        ),
                        const SizedBox(height: 6),
                        TextButton.icon(
                          onPressed: () => ApkLibraryFolderHelper.pickAndSet(context),
                          icon: const Icon(Icons.folder_open_outlined, size: 18),
                          label: const Text('Choose library folder'),
                        ),
                        if (custom)
                          TextButton(
                            onPressed: () => ApkLibraryFolderHelper.confirmResetToDefault(context),
                            child: const Text('Use default folder'),
                          ),
                      ],
                    );
                  },
                );
              },
            ),
            const SizedBox(height: 12),
            Text(
              'When you start a download from Search or Install, this tab opens so you can follow progress and speed. '
              'The rail shows a badge with how many downloads are active. '
              'Failures usually mean the CDN returned a web page or a bad link — try again or pick another store result.',
              style: theme.textTheme.bodySmall?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
            ),
            const SizedBox(height: 16),
            Expanded(
              child: ListenableBuilder(
                listenable: DownloadQueue.instance,
                builder: (context, _) {
                  final tasks = DownloadQueue.instance.tasks;
                  if (tasks.isEmpty) {
                    return Center(
                      child: Text(
                        'No downloads yet.\nUse Search & download or "Download newer" on the Install tab.',
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodyLarge?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
                      ),
                    );
                  }
                  return ListView.separated(
                    itemCount: tasks.length,
                    separatorBuilder: (context, i) => const SizedBox(height: 10),
                    itemBuilder: (context, i) {
                      final t = tasks[i];
                      return _DownloadTaskCard(task: t, theme: theme);
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _DownloadTaskCard extends StatelessWidget {
  const _DownloadTaskCard({required this.task, required this.theme});

  final DownloadTask task;
  final ThemeData theme;

  @override
  Widget build(BuildContext context) {
    final running = task.status == DownloadTaskStatus.running;
    final ok = task.status == DownloadTaskStatus.succeeded;
    final failed = task.status == DownloadTaskStatus.failed;
    final cancelled = task.status == DownloadTaskStatus.cancelled;

    double? progress;
    if (running && task.totalBytes != null && task.totalBytes! > 0) {
      progress = task.received / task.totalBytes!;
      if (progress > 1) progress = 1;
    }

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(task.label, style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600)),
            if (task.sourceLabel != null)
              Text(task.sourceLabel!, style: theme.textTheme.labelMedium?.copyWith(color: theme.colorScheme.primary)),
            const SizedBox(height: 4),
            SelectableText(
              task.destinationPath,
              style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
            const SizedBox(height: 8),
            if (running) ...[
              LinearProgressIndicator(value: progress),
              const SizedBox(height: 6),
              Text(
                task.totalBytes != null && task.totalBytes! > 0
                    ? '${DownloadsPage._formatBytes(task.received)} / ${DownloadsPage._formatBytes(task.totalBytes!)}'
                    : '${DownloadsPage._formatBytes(task.received)} downloaded…',
                style: theme.textTheme.labelMedium,
              ),
              if (task.smoothedBytesPerSecond != null && task.smoothedBytesPerSecond! > 8) ...[
                const SizedBox(height: 4),
                Text(
                  DownloadsPage._formatSpeed(task.smoothedBytesPerSecond!),
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: theme.colorScheme.primary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
              const SizedBox(height: 10),
              Align(
                alignment: Alignment.centerLeft,
                child: OutlinedButton.icon(
                  onPressed: () => DownloadQueue.instance.cancelTask(task.id),
                  icon: const Icon(Icons.close_rounded, size: 18),
                  label: const Text('Cancel download'),
                ),
              ),
            ],
            if (ok) ...[
              Row(
                children: [
                  Icon(Icons.check_circle_rounded, color: Theme.of(context).colorScheme.success, size: 22),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Finished · ${DownloadsPage._formatBytes(task.received)}',
                      style: theme.textTheme.labelLarge?.copyWith(color: Theme.of(context).colorScheme.success),
                    ),
                  ),
                ],
              ),
            ],
            if (cancelled) ...[
              Row(
                children: [
                  Icon(Icons.cancel_outlined, color: theme.colorScheme.outline, size: 22),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Canceled',
                      style: theme.textTheme.labelLarge?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                    ),
                  ),
                ],
              ),
            ],
            if (failed) ...[
              DecoratedBox(
                decoration: BoxDecoration(
                  color: theme.colorScheme.errorContainer.withValues(alpha: 0.4),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: theme.colorScheme.error),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(10),
                  child: SelectableText(
                    task.errorMessage ?? 'Unknown error',
                    style: TextStyle(color: theme.colorScheme.error, height: 1.35),
                  ),
                ),
              ),
            ],
            if (task.status == DownloadTaskStatus.queued)
              Text('Queued…', style: theme.textTheme.labelMedium?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant)),
          ],
        ),
      ),
    );
  }
}
