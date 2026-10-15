import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../app_shell_nav.dart';
import 'cancellation.dart';
import 'combined_apk_store_service.dart';

enum DownloadTaskStatus { queued, running, succeeded, failed, cancelled }

class DownloadTask {
  DownloadTask({
    required this.id,
    required this.label,
    required this.destinationPath,
    required this.cancelToken,
  });

  final String id;
  final String label;
  /// Updated to the real file name when the download finishes (`.apk` vs `.xapk`).
  String destinationPath;
  /// e.g. "APKPure · 1.2.3 · XAPK + OBB".
  String? sourceLabel;
  final CancellationToken cancelToken;

  DownloadTaskStatus status = DownloadTaskStatus.queued;
  int received = 0;
  int? totalBytes;
  String? errorMessage;

  /// Smoothed speed (bytes/s), updated while [status] is [DownloadTaskStatus.running].
  double? smoothedBytesPerSecond;
  DateTime? _speedSampleTime;
  int? _speedSampleBytes;

  void resetSpeedMeter() {
    smoothedBytesPerSecond = null;
    _speedSampleTime = null;
    _speedSampleBytes = null;
  }

  void updateSpeedFromProgress(int receivedNow) {
    final now = DateTime.now();
    if (_speedSampleTime != null && _speedSampleBytes != null) {
      final elapsedUs = now.difference(_speedSampleTime!).inMicroseconds;
      if (elapsedUs >= 120000) {
        final delta = receivedNow - _speedSampleBytes!;
        if (delta >= 0 && elapsedUs > 0) {
          final inst = delta * 1e6 / elapsedUs;
          smoothedBytesPerSecond = smoothedBytesPerSecond == null
              ? inst
              : smoothedBytesPerSecond! * 0.72 + inst * 0.28;
        }
        _speedSampleTime = now;
        _speedSampleBytes = receivedNow;
      }
    } else {
      _speedSampleTime = now;
      _speedSampleBytes = receivedNow;
    }
  }
}

/// Central place for store downloads + progress UI on the Downloads tab.
class DownloadQueue extends ChangeNotifier {
  DownloadQueue._();

  static final DownloadQueue instance = DownloadQueue._();

  static const _maxHistory = 40;

  /// Each download already uses several connections; a few at once keeps the line saturated
  /// without starving the others.
  static const maxParallel = 3;
  int _running = 0;
  final _waiting = <Completer<void>>[];

  Future<void> _acquire() async {
    if (_running < maxParallel) {
      _running++;
      return;
    }
    final c = Completer<void>();
    _waiting.add(c);
    await c.future;
  }

  void _release() {
    if (_waiting.isNotEmpty) {
      _waiting.removeAt(0).complete();
    } else if (_running > 0) {
      _running--;
    }
  }

  final List<DownloadTask> tasks = [];

  int get activeRunningCount =>
      tasks.where((t) => t.status == DownloadTaskStatus.running).length;

  /// Stops a running download (best-effort: aborts the HTTP request).
  void cancelTask(String id) {
    for (final t in tasks) {
      if (t.id != id) continue;
      if (t.status != DownloadTaskStatus.running && t.status != DownloadTaskStatus.queued) return;
      t.cancelToken.cancel();
      if (t.status == DownloadTaskStatus.queued) {
        t.status = DownloadTaskStatus.cancelled;
        notifyListeners();
      }
      return;
    }
  }

  /// Starts a download (optionally switches to the Downloads tab first) and returns the saved file.
  Future<File> beginStoreDownload({
    required CombinedApkStoreService store,
    required ApkpureReleaseInfo info,
    required String label,
    required File destination,
    bool openDownloadsTab = true,
  }) async {
    if (openDownloadsTab) AppShellNav.goTo(kShellTabDownloads);

    final cancel = CancellationToken();
    final task = DownloadTask(
      id: '${DateTime.now().microsecondsSinceEpoch}',
      label: label,
      destinationPath: destination.path,
      cancelToken: cancel,
    );
    final o = info.option;
    if (o != null) {
      task.sourceLabel = [
        o.source.label,
        'v${o.versionName}',
        o.hasObb ? 'XAPK + OBB' : o.extension.toUpperCase(),
      ].join(' · ');
    }
    tasks.insert(0, task);
    while (tasks.length > _maxHistory) {
      tasks.removeLast();
    }
    notifyListeners();

    await _acquire();
    if (cancel.isCancelled) {
      _release();
      throw OperationCanceled();
    }
    task.status = DownloadTaskStatus.running;
    task.received = 0;
    task.totalBytes = null;
    task.errorMessage = null;
    task.resetSpeedMeter();
    notifyListeners();

    var lastPaint = DateTime.fromMillisecondsSinceEpoch(0);
    try {
      final saved = await store.downloadRelease(
        info,
        destination,
        cancel: cancel,
        onProgress: (received, total) {
          task.received = received;
          task.totalBytes = total;
          task.updateSpeedFromProgress(received);
          final now = DateTime.now();
          if (now.difference(lastPaint).inMilliseconds >= 100) {
            lastPaint = now;
            notifyListeners();
          }
        },
      );
      task.destinationPath = saved.path;
      task.received = await saved.length();
      task.totalBytes = task.received;
      task.status = DownloadTaskStatus.succeeded;
      notifyListeners();
      return saved;
    } on OperationCanceled {
      task.status = DownloadTaskStatus.cancelled;
      task.errorMessage = null;
      task.resetSpeedMeter();
      notifyListeners();
      rethrow;
    } catch (e) {
      task.status = DownloadTaskStatus.failed;
      task.errorMessage = e.toString();
      task.resetSpeedMeter();
      notifyListeners();
      rethrow;
    } finally {
      _release();
    }
  }

  void clearFinished() {
    tasks.removeWhere(
      (t) =>
          t.status == DownloadTaskStatus.succeeded ||
          t.status == DownloadTaskStatus.failed ||
          t.status == DownloadTaskStatus.cancelled,
    );
    notifyListeners();
  }
}
