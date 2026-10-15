import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../services/cancellation.dart';

/// Runs [work] while showing a dialog with a linear progress bar.
///
/// When [cancellable] is set, a **Cancel** action calls [CancellationToken.cancel];
/// pass the same token into long-running work (e.g. [CombinedApkStoreService.search])
/// so it can stop between network steps.
Future<T> runWithBlockingProgress<T>(
  BuildContext context, {
  required String message,
  required Future<T> Function() work,
  CancellationToken? cancellable,
}) async {
  final nav = Navigator.of(context, rootNavigator: true);
  showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (dialogContext) {
      return PopScope(
        canPop: false,
        child: AlertDialog(
          content: ConstrainedBox(
            constraints: const BoxConstraints(minWidth: 280),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(message, style: Theme.of(dialogContext).textTheme.titleSmall),
                const SizedBox(height: 16),
                const LinearProgressIndicator(),
              ],
            ),
          ),
          actions: cancellable == null
              ? null
              : [
                  TextButton(
                    onPressed: () => cancellable.cancel(),
                    child: const Text('Cancel'),
                  ),
                ],
        ),
      );
    },
  );
  await SchedulerBinding.instance.endOfFrame;
  try {
    return await work();
  } finally {
    if (context.mounted) {
      nav.pop();
    }
  }
}
