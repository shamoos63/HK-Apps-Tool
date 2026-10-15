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
  final String destinationPath;
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

  final List<DownloadTask> tasks = [];

  int get activeRunningCount =>
      tasks.where((t) => t.status == DownloadTaskStatus.running).length;

  /// Stops a running download (best-effort: aborts the HTTP request).
  void cancelTask(String id) {
    for (final t in tasks) {
      if (t.id != id) continue;
      if (t.status != DownloadTaskStatus.running) return;
      t.cancelToken.cancel();
      return;
    }
  }

  /// Starts a download (optionally switches to the Downloads tab first).
  Future<void> beginStoreDownload({
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
    tasks.insert(0, task);
    while (tasks.length > _maxHistory) {
      tasks.removeLast();
    }
    notifyListeners();

    task.status = DownloadTaskStatus.running;
    task.received = 0;
    task.totalBytes = null;
    task.errorMessage = null;
    task.resetSpeedMeter();
    notifyListeners();

    try {
      if (destination.existsSync()) await destination.delete();
      await store.downloadRelease(
        info,
        destination,
        cancel: cancel,
        onProgress: (received, total) {
          task.received = received;
          task.totalBytes = total;
          task.updateSpeedFromProgress(received);
          notifyListeners();
        },
      );
      task.received = await destination.length();
      task.totalBytes = task.received;
      task.status = DownloadTaskStatus.succeeded;
      notifyListeners();
    } on OperationCanceled {
      task.status = DownloadTaskStatus.cancelled;
      task.errorMessage = null;
      task.resetSpeedMeter();
      if (destination.existsSync()) {
        try {
          await destination.delete();
        } catch (_) {}
      }
      notifyListeners();
    } catch (e) {
      task.status = DownloadTaskStatus.failed;
      task.errorMessage = e.toString();
      task.resetSpeedMeter();
      if (destination.existsSync()) {
        try {
          await destination.delete();
        } catch (_) {}
      }
      notifyListeners();
      rethrow;
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
