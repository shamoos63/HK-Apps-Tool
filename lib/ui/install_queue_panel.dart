import 'package:flutter/material.dart';

import '../app_theme.dart';
import '../services/install_queue.dart';

String formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  const units = ['KB', 'MB', 'GB', 'TB'];
  var v = bytes / 1024;
  var i = 0;
  while (v >= 1024 && i < units.length - 1) {
    v /= 1024;
    i++;
  }
  return '${v.toStringAsFixed(v >= 100 ? 0 : 1)} ${units[i]}';
}

String formatDuration(Duration d) {
  final s = d.inMilliseconds / 1000;
  if (s < 60) return '${s.toStringAsFixed(s < 10 ? 1 : 0)}s';
  return '${d.inMinutes}m ${(d.inSeconds % 60).toString().padLeft(2, '0')}s';
}

String stageLabel(InstallStage s) => switch (s) {
      InstallStage.queued => 'Waiting',
      InstallStage.preparing => 'Reading archive',
      InstallStage.installing => 'Installing',
      InstallStage.copyingObb => 'Copying game data',
      InstallStage.done => 'Installed',
      InstallStage.failed => 'Failed',
      InstallStage.canceled => 'Canceled',
    };

/// Side panel listing every install job with live progress, cancel, and retry.
class InstallQueuePanel extends StatelessWidget {
  const InstallQueuePanel({super.key, this.maxHeight});

  /// When set (narrow layouts), the panel shrinks to its content up to this height.
  final double? maxHeight;

  @override
  Widget build(BuildContext context) {
    final q = InstallQueue.instance;
    final scheme = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    return ListenableBuilder(
      listenable: q,
      builder: (context, _) {
        final jobs = q.jobs;
        final active = q.activeCount;
        final done = jobs.where((j) => j.succeeded).length;
        final failed = jobs.where((j) => j.stage == InstallStage.failed).length;
        final list = ListView.separated(
          shrinkWrap: maxHeight != null,
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
          itemCount: jobs.length,
          separatorBuilder: (_, _) => const SizedBox(height: 8),
          itemBuilder: (context, i) => _JobTile(job: jobs[i]),
        );
        return Card(
          child: Column(
            mainAxisSize: maxHeight != null ? MainAxisSize.min : MainAxisSize.max,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
                child: Row(
                  children: [
                    Icon(Icons.downloading_rounded, color: scheme.primary, size: 22),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('Install queue', style: t.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
                          Text(
                            [
                              if (active > 0) '$active active',
                              if (done > 0) '$done done',
                              if (failed > 0) '$failed failed',
                              if (jobs.isEmpty) 'Nothing queued',
                            ].join(' · '),
                            style: t.labelSmall?.copyWith(color: scheme.onSurfaceVariant),
                          ),
                        ],
                      ),
                    ),
                    TextButton(
                      onPressed: jobs.any((j) => j.finished) ? q.clearFinished : null,
                      child: const Text('Clear finished'),
                    ),
                  ],
                ),
              ),
              if (jobs.isEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 20),
                  child: Text(
                    'Press Install on any app, select several and install them together, '
                    'or drop APK / XAPK files anywhere on this page.',
                    style: t.bodySmall?.copyWith(color: scheme.onSurfaceVariant, height: 1.4),
                  ),
                )
              else if (maxHeight != null)
                ConstrainedBox(constraints: BoxConstraints(maxHeight: maxHeight!), child: list)
              else
                Expanded(child: list),
            ],
          ),
        );
      },
    );
  }
}

class _JobTile extends StatelessWidget {
  const _JobTile({required this.job});

  final InstallJob job;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    final q = InstallQueue.instance;
    final failed = job.stage == InstallStage.failed;
    final (Color bg, Color fg, IconData icon) = switch (job.stage) {
      InstallStage.done => (scheme.successContainer, scheme.success, Icons.check_circle_rounded),
      InstallStage.failed => (scheme.errorContainer, scheme.error, Icons.error_rounded),
      InstallStage.canceled => (scheme.surfaceContainerHighest, scheme.onSurfaceVariant, Icons.block_rounded),
      InstallStage.queued => (scheme.surfaceContainerHigh, scheme.onSurfaceVariant, Icons.schedule_rounded),
      _ => (scheme.primaryContainer.withValues(alpha: 0.45), scheme.primary, Icons.sync_rounded),
    };
    final progress = job.progress;
    final bits = <String>[
      stageLabel(job.stage),
      if (!job.finished && progress != null) '${(progress * 100).round()}%',
      if (job.apkBytes > 0) formatBytes(job.apkBytes + job.obbBytes),
      if (job.splitCount > 1) '${job.splitCount} splits',
      if (job.elapsed != null) formatDuration(job.elapsed!),
    ];
    return DecoratedBox(
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 6, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(icon, size: 18, color: fg),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    job.label,
                    style: t.labelLarge?.copyWith(fontWeight: FontWeight.w600),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (job.stage == InstallStage.queued)
                  IconButton(
                    tooltip: 'Cancel',
                    visualDensity: VisualDensity.compact,
                    onPressed: () => q.cancel(job),
                    icon: const Icon(Icons.close_rounded, size: 18),
                  ),
                if (failed)
                  IconButton(
                    tooltip: 'Retry',
                    visualDensity: VisualDensity.compact,
                    onPressed: () => q.retry(job),
                    icon: const Icon(Icons.replay_rounded, size: 18),
                  ),
                if (job.finished)
                  IconButton(
                    tooltip: 'Remove',
                    visualDensity: VisualDensity.compact,
                    onPressed: () => q.remove(job),
                    icon: const Icon(Icons.close_rounded, size: 18),
                  ),
              ],
            ),
            Padding(
              padding: const EdgeInsets.only(left: 26, right: 6, top: 2),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(bits.join(' · '), style: t.labelSmall?.copyWith(color: scheme.onSurfaceVariant)),
                  if (!job.finished) ...[
                    const SizedBox(height: 6),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      child: LinearProgressIndicator(
                        minHeight: 5,
                        value: job.stage == InstallStage.queued ? 0 : progress,
                      ),
                    ),
                  ],
                  if (job.targets.length > 1)
                    for (final target in job.targets)
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Text(
                          '${target.deviceLabel}: ${stageLabel(target.stage)}'
                          '${target.bytesTotal > 0 && !target.finished ? ' ${(100 * target.bytesDone / target.bytesTotal).clamp(0, 100).round()}%' : ''}',
                          style: t.labelSmall?.copyWith(color: scheme.onSurfaceVariant),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                  if (failed && job.error != null) ...[
                    const SizedBox(height: 6),
                    SelectableText(
                      job.error!,
                      maxLines: 6,
                      style: t.bodySmall?.copyWith(color: scheme.onErrorContainer, height: 1.3),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
