@Tags(['external'])
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/core/ipc_protocol.dart';

import 'support/search_cancel_harness.dart';

void main() {
  test('abandon only target, ignores late reply, survives original kill grace', () async {
    final fixture = SearchCancelHarness();
    await fixture.start();
    addTearDown(fixture.close);
    final host = await fixture.host();
    final target = host.call(
      'search',
      params: {'keyword': 'target'},
      requestId: 'target-17',
      deadline: const Duration(milliseconds: 500),
    );
    final survivor = host.call(
      'search',
      params: {'keyword': 'survivor'},
      requestId: 'survivor-18',
    );
    final targetFrame = await fixture.searchFrame('target');
    final survivorFrame = await fixture.searchFrame('survivor');
    final cancelled = expectLater(
      target.timeout(const Duration(milliseconds: 300)),
      throwsA(
        isA<SpiderError>().having(
          (e) => e.code,
          'code',
          SpiderErrorCode.cancelled,
        ),
      ),
    );
    expect(host.abandon('target-17'), isTrue);
    await cancelled;
    await fixture.until(
      () => fixture.frames.any((f) => f['method'] == r'$/cancelRequest'),
    );
    final cancels = fixture.frames
        .where((f) => f['method'] == r'$/cancelRequest')
        .toList();
    expect(cancels.map((f) => (f['params'] as Map)['id']), ['target-17']);
    await Future<void>.delayed(const Duration(milliseconds: 2200));
    expect(host.process.isRunning, isTrue);
    expect(host.process.killTreeCount, 0);
    expect(host.process.killGuardArmed, isFalse);
    await fixture.reply('target-17', title: 'obsolete');
    await fixture.until(() => fixture.sent.contains('target-17'));
    await fixture.reply('survivor-18');
    expect((await survivor as Map)['list'], isNotEmpty);
    final probe = host.call('home', requestId: 'probe-19');
    await fixture.reply('probe-19');
    expect(await probe, isA<Map>());
    expect(host.process.isRunning, isTrue);
    // ignore: avoid_print
    print(
      'IPC frames target=${targetFrame['id']} survivor=${survivorFrame['id']} cancel=${cancels.single['params']}; alive across 2200ms, late reply ignored',
    );
  }, skip: Platform.isWindows ? 'POSIX Python fixture' : false);
  test('actual Python host marks only target cancellation and keeps peer alive', () async {
    final fixture = SearchCancelHarness();
    await fixture.start();
    addTearDown(fixture.close);
    final host = await fixture.host(actualHost: true);
    final target = host.call(
      'search',
      params: {'keyword': 'actual-target'},
      requestId: 'actual-target-31',
    );
    final survivor = host.call(
      'search',
      params: {'keyword': 'actual-peer'},
      requestId: 'actual-peer-32',
    );
    await fixture.searchFrame('actual-target');
    await fixture.searchFrame('actual-peer');
    final stopped = expectLater(
      target,
      throwsA(
        isA<SpiderError>().having(
          (e) => e.code,
          'code',
          SpiderErrorCode.cancelled,
        ),
      ),
    );
    expect(host.abandon('actual-target-31'), isTrue);
    await stopped;
    await Future<void>.delayed(const Duration(milliseconds: 2200));
    expect(host.process.isRunning, isTrue);
    await fixture.reply('actual-target-31');
    await fixture.until(
      () => fixture.observations.any((o) => o['id'] == 'actual-target-31'),
    );
    await fixture.reply('actual-peer-32');
    expect((await survivor as Map)['list'], isNotEmpty);
    expect(
      fixture.observations,
      containsAll([
        {'id': 'actual-target-31', 'cancelled': true},
        {'id': 'actual-peer-32', 'cancelled': false},
      ]),
    );
    expect(host.process.isRunning, isTrue);
    expect(host.process.killTreeCount, 0);
    expect(host.process.killGuardArmed, isFalse);
    expect(host.process.killGuardArmed, isFalse);
    // ignore: avoid_print
    print(
      'actual Python host observations=${fixture.observations}; alive across 2200ms, no physical termination promised',
    );
  }, skip: Platform.isWindows ? 'POSIX Python fixture' : false);
}
