import 'dart:async';

import 'transfer_control.dart';

/// Retries recoverable connection operations with a bounded backoff.
class ConnectionRetry {
  ConnectionRetry({
    required this.resetConnection,
    this.maxAttempts = 3,
    this.delayForAttempt = _defaultDelay,
    this.isRecoverable = _defaultIsRecoverable,
    this.beforeRetry,
  });

  final Future<void> Function() resetConnection;
  final int maxAttempts;
  final Duration Function(int retryNumber) delayForAttempt;
  final bool Function(Object exception) isRecoverable;
  final void Function(int retryNumber)? beforeRetry;

  static Duration _defaultDelay(int retryNumber) =>
      Duration(milliseconds: 400 * retryNumber);

  static bool _defaultIsRecoverable(Object exception) {
    final message = exception.toString().toLowerCase();
    return message.contains('timed out') ||
        message.contains('connection reset') ||
        message.contains('connection closed') ||
        message.contains('connection refused') ||
        message.contains('broken pipe') ||
        message.contains('network is unreachable') ||
        message.contains('failed host lookup') ||
        message.contains('no address associated') ||
        message.contains('socket') ||
        message.contains('unexpected eof');
  }

  Future<T> run<T>(Future<T> Function() operation) async {
    Object? lastException;
    StackTrace? lastStackTrace;
    for (var attempt = 0; attempt < maxAttempts; attempt++) {
      try {
        if (attempt > 0) await resetConnection();
        return await operation();
      } catch (exception, stackTrace) {
        if (exception is TransferCancelled) {
          Error.throwWithStackTrace(exception, stackTrace);
        }
        if (!isRecoverable(exception)) {
          Error.throwWithStackTrace(exception, stackTrace);
        }
        lastException = exception;
        lastStackTrace = stackTrace;
        if (attempt + 1 < maxAttempts) {
          beforeRetry?.call(attempt + 1);
          await Future<void>.delayed(delayForAttempt(attempt + 1));
        }
      }
    }
    Error.throwWithStackTrace(lastException!, lastStackTrace!);
  }
}
