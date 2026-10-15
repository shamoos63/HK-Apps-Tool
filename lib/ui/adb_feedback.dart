import 'package:flutter/material.dart';

import '../services/adb_service.dart';

void showAdbSnack(
  BuildContext context, {
  required bool success,
  required String successMessage,
  required String failureTitle,
  required AdbCommandResult result,
}) {
  if (!context.mounted) return;
  final messenger = ScaffoldMessenger.of(context);
  final detail = result.combinedOutput.trim();
  final failureBody = detail.isNotEmpty
      ? detail
      : 'Exit code ${result.exitCode}. No output from adb.';

  messenger.showSnackBar(
    SnackBar(
      behavior: SnackBarBehavior.floating,
      duration: Duration(seconds: success ? 5 : 20),
      backgroundColor: success ? Colors.green.shade800 : Theme.of(context).colorScheme.errorContainer,
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            success ? successMessage : failureTitle,
            style: TextStyle(
              fontWeight: FontWeight.w700,
              color: success ? Colors.white : Theme.of(context).colorScheme.onErrorContainer,
            ),
          ),
          if (!success) ...[
            const SizedBox(height: 8),
            Text(
              failureBody,
              style: TextStyle(
                fontSize: 13,
                height: 1.35,
                color: Theme.of(context).colorScheme.onErrorContainer,
              ),
            ),
          ],
        ],
      ),
      action: !success && failureBody.length > 120
          ? SnackBarAction(
              label: 'Full log',
              textColor: Theme.of(context).colorScheme.onErrorContainer,
              onPressed: () {
                showDialog<void>(
                  context: context,
                  builder: (c) => AlertDialog(
                    title: Text(failureTitle),
                    content: SizedBox(
                      width: 480,
                      child: SingleChildScrollView(
                        child: SelectableText(failureBody),
                      ),
                    ),
                    actions: [
                      TextButton(onPressed: () => Navigator.pop(c), child: const Text('Close')),
                    ],
                  ),
                );
              },
            )
          : null,
    ),
  );
}
