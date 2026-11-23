import 'dart:async';

import 'app_error.dart';

/// A request-local cancellation signal; cancelling never owns a shared host.
class RequestCancellation {
  final Completer<void> _cancelled = Completer<void>();
  AppError? _reason;

  bool get isCancelled => _reason != null;
  AppError? get reason => _reason;
  Future<void> get whenCancelled => _cancelled.future;

  void cancel([AppError? reason]) {
    if (isCancelled) return;
    _reason = reason ?? AppError(AppErrorKind.siteCancelled, '请求已取消');
    _cancelled.complete();
  }

  void throwIfCancelled() {
    final error = _reason;
    if (error != null) throw error;
  }

  /// Stop waiting without leaving late failures from [operation] unobserved.
  Future<T> bind<T>(Future<T> operation) {
    final result = Completer<T>();
    operation.then(
      (value) {
        if (result.isCompleted) return;
        if (isCancelled) {
          result.completeError(_reason!);
        } else {
          result.complete(value);
        }
      },
      onError: (Object error, StackTrace stackTrace) {
        if (!result.isCompleted) {
          result.completeError(_reason ?? error, stackTrace);
        }
      },
    );
    whenCancelled.then((_) {
      if (!result.isCompleted) result.completeError(_reason!);
    });
    return result.future;
  }
}
