/// Thrown when the user stops a cancellable operation (e.g. store search).
class OperationCanceled implements Exception {
  @override
  String toString() => 'Canceled';
}

/// Shared by UI + [CombinedApkStoreService] search; [cancel] is triggered from the progress dialog.
class CancellationToken {
  bool _cancelled = false;

  /// Optional hook (e.g. [HttpClientRequest.abort]) run when [cancel] is called.
  void Function()? abortHook;

  bool get isCancelled => _cancelled;

  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    try {
      abortHook?.call();
    } catch (_) {}
    abortHook = null;
  }

  void throwIfCancelled() {
    if (_cancelled) throw OperationCanceled();
  }
}
