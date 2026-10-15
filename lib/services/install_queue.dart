import 'dart:async';
import 'dart:collection';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import 'adb_service.dart';
import 'apk_installer.dart';
import 'xapk_service.dart';

enum InstallStage { queued, preparing, installing, copyingObb, done, failed, canceled }

/// Progress of one job on one device.
class InstallTargetState {
  InstallTargetState(this.serial, this.deviceLabel);

  final String serial;
  final String deviceLabel;
  InstallStage stage = InstallStage.queued;
  int bytesDone = 0;
  int bytesTotal = 0;
  bool usedFallback = false;
  String detail = '';

  bool get finished =>
      stage == InstallStage.done || stage == InstallStage.failed || stage == InstallStage.canceled;
}

class InstallJob {
  InstallJob({
    required this.id,
    required this.label,
    required this.sourcePath,
    required this.targets,
    required this.includeObb,
  });

  final String id;
  final String label;
  final String sourcePath;
  final List<InstallTargetState> targets;
  final bool includeObb;
  final DateTime createdAt = DateTime.now();
  DateTime? startedAt;
  DateTime? finishedAt;
  InstallStage stage = InstallStage.queued;
  String? error;
  int apkBytes = 0;
  int obbBytes = 0;
  int splitCount = 0;
  String? packageName;

  String get fileName => p.basename(sourcePath);
  bool get finished =>
      stage == InstallStage.done || stage == InstallStage.failed || stage == InstallStage.canceled;
  bool get succeeded => stage == InstallStage.done;

  Duration? get elapsed {
    final s = startedAt;
    if (s == null) return null;
    return (finishedAt ?? DateTime.now()).difference(s);
  }

  /// 0..1 across all devices, or null while nothing measurable is happening yet.
  double? get progress {
    if (finished) return 1;
    final total = targets.fold<int>(0, (a, t) => a + t.bytesTotal);
    if (total <= 0) return null;
    final done = targets.fold<int>(0, (a, t) => a + t.bytesDone.clamp(0, t.bytesTotal));
    return done / total;
  }
}

class _Semaphore {
  _Semaphore(this.max);
  final int max;
  int _used = 0;
  final _waiters = Queue<Completer<void>>();

  Future<void> acquire() {
    if (_used < max) {
      _used++;
      return Future.value();
    }
    final c = Completer<void>();
    _waiters.add(c);
    return c.future;
  }

  void release() {
    if (_waiters.isNotEmpty) {
      _waiters.removeFirst().complete();
    } else if (_used > 0) {
      _used--;
    }
  }
}

/// App-wide install queue: runs several installs at once, keeps per-device load bounded,
/// and reports per-file progress.
///
/// Planning a job only reads the archive's directory (no unpacking), so jobs move straight to
/// streaming. Each device takes [perDeviceParallel] installs at a time — enough to overlap one
/// app's on-device verification/dexopt with the next app's transfer without saturating USB.
class InstallQueue extends ChangeNotifier {
  InstallQueue._();

  static final InstallQueue instance = InstallQueue._();

  static const perDeviceParallel = 2;
  static const maxActiveJobs = 4;
  static const _prefsCopyObb = 'install_copy_obb';

  final _installer = ApkInstaller();
  final _jobSlots = _Semaphore(maxActiveJobs);
  final _deviceSlots = <String, _Semaphore>{};
  final List<InstallJob> _jobs = [];
  var _seq = 0;

  final _finishedCtl = StreamController<InstallJob>.broadcast();

  /// Fires once per job when it reaches done / failed / canceled.
  Stream<InstallJob> get finished => _finishedCtl.stream;

  List<InstallJob> get jobs => List.unmodifiable(_jobs);
  int get activeCount => _jobs.where((j) => !j.finished).length;
  int get runningCount => _jobs.where((j) => !j.finished && j.stage != InstallStage.queued).length;

  bool copyObb = true;

  Future<void> loadSettings() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      copyObb = prefs.getBool(_prefsCopyObb) ?? true;
      notifyListeners();
    } catch (_) {}
  }

  Future<void> setCopyObb(bool v) async {
    copyObb = v;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_prefsCopyObb, v);
    } catch (_) {}
  }

  /// Latest job for [sourcePath] (used to show status on library cards).
  InstallJob? latestFor(String sourcePath) {
    for (final j in _jobs) {
      if (j.sourcePath == sourcePath) return j;
    }
    return null;
  }

  InstallJob enqueue({
    required String sourcePath,
    required String label,
    required List<AdbDevice> devices,
  }) {
    final job = InstallJob(
      id: 'install_${DateTime.now().microsecondsSinceEpoch}_${_seq++}',
      label: label,
      sourcePath: sourcePath,
      targets: [for (final d in devices) InstallTargetState(d.serial, d.shortLabel)],
      includeObb: copyObb,
    );
    _jobs.insert(0, job);
    notifyListeners();
    unawaited(_run(job));
    return job;
  }

  void cancel(InstallJob job) {
    if (job.stage != InstallStage.queued) return;
    job.stage = InstallStage.canceled;
    for (final t in job.targets) {
      t.stage = InstallStage.canceled;
    }
    job.finishedAt = DateTime.now();
    notifyListeners();
    _finishedCtl.add(job);
  }

  /// Re-queues the devices that failed.
  InstallJob? retry(InstallJob job) {
    if (!job.finished || job.succeeded) return null;
    final failed = job.targets.where((t) => t.stage != InstallStage.done).toList();
    if (failed.isEmpty) return null;
    return enqueue(
      sourcePath: job.sourcePath,
      label: job.label,
      devices: [for (final t in failed) AdbDevice(serial: t.serial, state: 'device', model: null)],
    );
  }

  void clearFinished() {
    _jobs.removeWhere((j) => j.finished);
    notifyListeners();
  }

  void remove(InstallJob job) {
    if (!job.finished) return;
    _jobs.remove(job);
    notifyListeners();
  }

  DateTime _lastNotify = DateTime.fromMillisecondsSinceEpoch(0);
  Timer? _pendingNotify;

  void _notifyThrottled() {
    final now = DateTime.now();
    if (now.difference(_lastNotify) > const Duration(milliseconds: 120)) {
      _lastNotify = now;
      notifyListeners();
      return;
    }
    _pendingNotify ??= Timer(const Duration(milliseconds: 120), () {
      _pendingNotify = null;
      _lastNotify = DateTime.now();
      notifyListeners();
    });
  }

  Future<void> _run(InstallJob job) async {
    await _jobSlots.acquire();
    InstallPlan? plan;
    try {
      if (job.stage == InstallStage.canceled) return;
      job.startedAt = DateTime.now();
      job.stage = InstallStage.preparing;
      notifyListeners();

      plan = await _installer.xapk.planInstall(job.sourcePath, includeObb: job.includeObb);
      job.apkBytes = plan.apkBytes;
      job.obbBytes = plan.obbBytes;
      job.splitCount = plan.parts.length;
      job.packageName = plan.packageName;
      for (final t in job.targets) {
        t.bytesTotal = plan.apkBytes + plan.obbBytes;
      }
      job.stage = InstallStage.installing;
      notifyListeners();

      final p = plan;
      await Future.wait([for (final t in job.targets) _runTarget(job, t, p)]);
      final allOk = job.targets.every((t) => t.stage == InstallStage.done);
      job.stage = allOk ? InstallStage.done : InstallStage.failed;
      if (!allOk) {
        job.error = job.targets
            .where((t) => t.stage != InstallStage.done)
            .map((t) => job.targets.length > 1 ? '${t.deviceLabel}: ${t.detail}' : t.detail)
            .join('\n');
      }
    } catch (e) {
      job.stage = InstallStage.failed;
      job.error = e.toString();
      for (final t in job.targets) {
        if (!t.finished) {
          t.stage = InstallStage.failed;
          t.detail = e.toString();
        }
      }
    } finally {
      await plan?.dispose();
      _jobSlots.release();
      job.finishedAt ??= DateTime.now();
      notifyListeners();
      if (job.stage != InstallStage.canceled) _finishedCtl.add(job);
    }
  }

  Future<void> _runTarget(InstallJob job, InstallTargetState t, InstallPlan plan) async {
    final slot = _deviceSlots.putIfAbsent(t.serial, () => _Semaphore(perDeviceParallel));
    await slot.acquire();
    try {
      t.stage = InstallStage.installing;
      notifyListeners();
      final r = await _installer.install(
        plan,
        t.serial,
        onBytes: (d) {
          t.bytesDone += d;
          _notifyThrottled();
        },
        onFallback: () {
          t.usedFallback = true;
          _notifyThrottled();
        },
      );
      if (!r.installSucceeded) {
        t.stage = InstallStage.failed;
        t.detail = r.combinedOutput.trim().isEmpty
            ? 'Install failed (exit code ${r.exitCode}).'
            : r.combinedOutput.trim();
        return;
      }
      t.bytesDone = plan.apkBytes;
      if (plan.obbs.isNotEmpty) {
        t.stage = InstallStage.copyingObb;
        notifyListeners();
        final o = await _installer.pushObbs(plan, t.serial, onBytes: (d) {
          t.bytesDone += d;
          _notifyThrottled();
        });
        if (o != null && o.exitCode != 0) {
          t.stage = InstallStage.failed;
          t.detail = 'App installed, but game data (OBB) copy failed: ${o.combinedOutput}';
          return;
        }
      }
      t.bytesDone = t.bytesTotal;
      t.stage = InstallStage.done;
      t.detail = plan.isSplit
          ? 'Installed ${plan.parts.length} splits${plan.obbs.isNotEmpty ? ' + OBB data' : ''}.'
          : 'Installed${plan.obbs.isNotEmpty ? ' + OBB data' : ''}.';
    } catch (e) {
      t.stage = InstallStage.failed;
      t.detail = e.toString();
    } finally {
      slot.release();
      notifyListeners();
    }
  }
}
