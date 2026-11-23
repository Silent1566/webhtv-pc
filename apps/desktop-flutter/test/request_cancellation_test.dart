import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/app_error.dart';
import 'package:webhtv_pc/core/request_cancellation.dart';

void main() {
  test('cancel is idempotent and preserves the first reason', () async {
    final cancellation = RequestCancellation();
    final timeout = AppError(AppErrorKind.siteTimeout, 'timeout');
    cancellation.cancel(timeout);
    cancellation.cancel();
    await cancellation.whenCancelled;
    expect(cancellation.isCancelled, isTrue);
    expect(cancellation.reason, same(timeout));
    expect(cancellation.throwIfCancelled, throwsA(same(timeout)));
  });

  test(
    'bind returns a successful operation without cancelling the scope',
    () async {
      final cancellation = RequestCancellation();
      expect(await cancellation.bind(Future.value(42)), 42);
      expect(cancellation.isCancelled, isFalse);
    },
  );

  test('bind stops waiting and consumes late operation errors', () async {
    final cancellation = RequestCancellation();
    final operation = Completer<int>();
    final result = cancellation.bind(operation.future);
    final expectation = expectLater(
      result,
      throwsA(
        isA<AppError>().having(
          (error) => error.kind,
          'kind',
          AppErrorKind.siteCancelled,
        ),
      ),
    );
    cancellation.cancel();
    await expectation;
    operation.completeError(StateError('late failure'));
    await Future<void>.delayed(Duration.zero);
  });

  test(
    'pre-cancelled bind still observes an already-started operation',
    () async {
      final cancellation = RequestCancellation()..cancel();
      final operation = Completer<int>();
      final expectation = expectLater(
        cancellation.bind(operation.future),
        throwsA(isA<AppError>()),
      );
      operation.completeError(StateError('late failure'));
      await expectation;
      await Future<void>.delayed(Duration.zero);
    },
  );
}
