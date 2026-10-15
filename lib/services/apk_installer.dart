import 'adb_service.dart';
import 'xapk_service.dart';

/// Installs an [InstallPlan] on one device: streams splits into a PackageManager session when the
/// device allows it, otherwise unpacks and falls back to `adb install` / `install-multiple`.
class ApkInstaller {
  ApkInstaller({AdbService? adb, XapkService? xapk})
      : adb = adb ?? AdbService(),
        xapk = xapk ?? XapkService();

  final AdbService adb;
  final XapkService xapk;

  Future<AdbCommandResult> install(
    InstallPlan plan,
    String serial, {
    void Function(int delta)? onBytes,
    void Function()? onFallback,
  }) async {
    var sent = 0;
    try {
      return await adb.streamInstall(
        serial: serial,
        parts: [for (final x in plan.parts) (name: x.name, size: x.size, open: x.open)],
        onBytes: (d) {
          sent += d;
          onBytes?.call(d);
        },
      );
    } on AdbStreamingUnsupported {
      // Older device / adb — classic path below.
    }
    onFallback?.call();
    if (sent > 0) onBytes?.call(-sent);
    final paths = await plan.materialize();
    if (paths.length > 1) {
      return adb.installMultiple(serial: serial, apkPaths: paths);
    }
    return adb.installApk(serial: serial, apkPath: paths.single);
  }

  /// Copies OBB expansion files from the archive straight to the device. Returns null when
  /// there are none, otherwise the first failure or a success result.
  Future<AdbCommandResult?> pushObbs(
    InstallPlan plan,
    String serial, {
    void Function(int delta)? onBytes,
  }) async {
    if (plan.obbs.isEmpty) return null;
    for (final obb in plan.obbs) {
      final r = await adb.pushStream(
        serial: serial,
        devicePath: obb.devicePath,
        size: obb.size,
        data: await obb.zip.openEntry(obb.entry),
        onBytes: onBytes,
      );
      if (r.exitCode != 0) return r;
    }
    return AdbCommandResult(exitCode: 0, stdout: 'Success', stderr: '');
  }

  /// One-shot helper: plan, install, clean up.
  Future<AdbCommandResult> installFile(String path, String serial, {bool includeObb = false}) async {
    final plan = await xapk.planInstall(path, includeObb: includeObb);
    try {
      final r = await install(plan, serial);
      if (r.installSucceeded && includeObb) {
        final o = await pushObbs(plan, serial);
        if (o != null && o.exitCode != 0) return o;
      }
      return r;
    } finally {
      await plan.dispose();
    }
  }
}
