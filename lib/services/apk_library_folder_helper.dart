import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import 'app_paths.dart';

/// UX helpers for choosing where APK / XAPK library files and store downloads live.
class ApkLibraryFolderHelper {
  ApkLibraryFolderHelper._();

  static Future<void> pickAndSet(BuildContext context) async {
    final initial = await AppPaths.apkDownloadDirectory();
    final chosen = await getDirectoryPath(
      initialDirectory: initial.path,
      confirmButtonText: 'Use this folder',
    );
    if (!context.mounted || chosen == null || chosen.trim().isEmpty) return;
    try {
      await AppPaths.setCustomApkLibraryDirectory(chosen);
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'APK library folder updated — Search downloads, Install picks, and “Download newer” use this path.',
            ),
          ),
        );
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not use that folder: $e')),
        );
      }
    }
  }

  static Future<void> confirmResetToDefault(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Use default library folder?'),
        content: const Text(
          'New downloads will save under this app’s data folder again. '
          'Files already in your custom folder are not moved.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Use default')),
        ],
      ),
    );
    if (ok != true || !context.mounted) return;
    await AppPaths.clearCustomApkLibraryDirectory();
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Library folder reset to default.')),
      );
    }
  }
}
