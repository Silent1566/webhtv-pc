/// 日志落盘性能与可见性（用户反馈 2026-10-12：「点击选择站点每次都会卡一会」）。
///
/// 根因：`LogService` 早期对**每条**日志做 `writeAsStringSync(mode: append)`。
/// 实测（本机 Windows，Dart 3.13.4）单条同步追加约 8.5ms —— 站点选择器打开时
/// 写 170 条站点明细要 **1.45 秒**，真实日志里 21 次点击全部落在 1.28~2.44s。
///
/// 修复后语义（本套件锁住）：
/// 1. **入队是纯内存操作**：170 条日志的入队耗时必须远低于旧实现（此处放宽到
///    200ms 仍与旧实现 1.45s 有数量级差距，同时不受 CI 机器抖动影响）；
/// 2. **落盘内容不丢、不乱序**：`flush()` 后文件里是全部行且顺序与写入一致；
/// 3. **时效性不退化**：首条日志由 0 延迟定时器立即刷出，不必等批次周期；
/// 4. **失败静默降级**：目录不可写时不得抛异常（诊断设施不能成为阻断项）。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/services/log_service.dart';

void main() {
  late Directory temp;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('webhtv-log');
  });

  tearDown(() async {
    try {
      await temp.delete(recursive: true);
    } catch (_) {}
  });

  Future<LogService> openService() async {
    final log = LogService();
    await log.open(temp.path);
    return log;
  }

  String readLog() => File('${temp.path}/webhtv-pc.log').readAsStringSync();

  group('落盘性能（170 条站点明细是真实触发场景）', () {
    test('170 条日志入队远快于逐条同步写（旧实现 1452ms）', () async {
      final log = await openService();
      final stopwatch = Stopwatch()..start();
      for (var i = 0; i < 170; i++) {
        log.debug('站点 name=测试$i key=csp_K$i type=4 available=true');
      }
      stopwatch.stop();
      // 纯内存入队：本机实测 < 1ms。阈值给足余量，仍能拦住「又改回逐条同步写」。
      expect(
        stopwatch.elapsedMilliseconds,
        lessThan(200),
        reason: '170 条日志入队耗时 ${stopwatch.elapsedMilliseconds}ms，疑似回退成逐条同步落盘',
      );

      log.flush();
      final lines = readLog().trim().split('\n');
      expect(lines.length, 170);
      expect(lines.first, contains('站点 name=测试0 '));
      expect(lines.last, contains('站点 name=测试169 '));
      await log.dispose();
    });

    test('flush 后全部日志按写入顺序落盘（不丢、不乱序）', () async {
      final log = await openService();
      for (var i = 0; i < 30; i++) {
        log.info('第 $i 行');
      }
      log.flush();
      final lines = readLog().trim().split('\n');
      expect(lines.length, 30);
      for (var i = 0; i < 30; i++) {
        expect(lines[i], contains('第 $i 行'));
      }
      await log.dispose();
    });

    test('多次 log 之间显式 flush 不重复写（批次只落盘一次）', () async {
      final log = await openService();
      log.info('A');
      log.info('B');
      log.flush();
      final first = readLog();
      expect(first.trim().split('\n').length, 2);
      // 再刷一次：队列已空，文件不得被追加空行或重复行。
      log.flush();
      expect(readLog(), first);
      await log.dispose();
    });
  });

  group('可见性（诊断与验收依赖文件里的时间线）', () {
    test('首条日志立即刷出，不必等批次周期', () async {
      final log = await openService();
      log.info('首条即时可见');
      // 批次间隔 200ms；首条走 0 延迟定时器，50ms 内必须可见。
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(readLog(), contains('首条即时可见'));
      await log.dispose();
    });

    test('dispose 会把未刷盘日志补齐（退出不丢日志）', () async {
      final log = await openService();
      log.info('退出前最后一条');
      // 不 flush，直接 dispose：dispose 必须自己收口。
      await log.dispose();
      expect(readLog(), contains('退出前最后一条'));
    });

    test('内存视图与文件内容一致（日志页读的是内存环形缓冲）', () async {
      final log = await openService();
      log.warning('内存视图');
      expect(log.entries.map((entry) => entry.message), contains('内存视图'));
      expect(log.export(), contains('内存视图'));
      await log.dispose();
    });
  });

  group('降级与轮转', () {
    test('目录不可写时静默降级，不影响调用方', () async {
      final log = LogService();
      // 用一个不存在的父目录下的路径：open 失败后必须仍可 log。
      final missing = File('${temp.path}/nope/deeper/x.log').parent.path;
      await log.open(missing);
      expect(() => log.info('降级后仍可记录'), returnsNormally);
      expect(log.entries.last.message, '降级后仍可记录');
      await log.dispose();
    });

    test('超过轮转阈值时旧文件被改名保留', () async {
      final log = LogService(maxFileBytes: 1);
      await log.open(temp.path);
      final file = File('${temp.path}/webhtv-pc.log');
      // 先写出内容，再触发一次轮转（open 时按大小判定）。
      log.info('轮转前的历史内容');
      log.flush();
      expect(file.existsSync(), isTrue);
      final rotated = File('${file.path}.1');
      await log.open(temp.path);
      expect(rotated.existsSync(), isTrue, reason: '超过 maxFileBytes 应轮转为 .1');
      await log.dispose();
    });
  });

  group('导出与清理（日志页「下载」「清理」按钮的文件层）', () {
    test('导出汇总轮转历史与主文件，旧内容在前', () async {
      final log = LogService(maxFileBytes: 1);
      await log.open(temp.path);
      log.info('第一代内容');
      log.flush();
      await log.open(temp.path); // 主文件超过 1 字节 → 轮转为 .1
      log.info('第二代内容');
      log.flush();
      final target = await log.exportToDirectory(temp.path, fileName: 'dump.log');
      expect(target.path, endsWith('dump.log'));
      final text = File('${temp.path}/dump.log').readAsStringSync();
      final first = text.indexOf('第一代内容');
      final second = text.indexOf('第二代内容');
      expect(first, greaterThanOrEqualTo(0));
      expect(second, greaterThan(first), reason: '导出顺序必须是旧 → 新');
      await log.dispose();
    });

    test('默认文件名带时间戳', () async {
      final log = await openService();
      log.info('给导出的内容');
      final target = await log.exportToDirectory('${temp.path}/exports');
      expect(
        RegExp(r'webhtv-pc-\d{8}-\d{6}\.log$').hasMatch(target.path),
        isTrue,
        reason: '实际文件名：${target.path}',
      );
      expect(target.readAsStringSync(), contains('给导出的内容'));
      await log.dispose();
    });

    test('清理删除落盘文件与轮转历史，并清空内存视图', () async {
      final log = LogService(maxFileBytes: 1);
      await log.open(temp.path);
      log.info('清理前的内存行');
      log.flush();
      await log.open(temp.path);
      log.info('轮转后的内存行');
      log.flush();
      final main = File('${temp.path}/webhtv-pc.log');
      final rotated = File('${main.path}.1');
      expect(rotated.existsSync(), isTrue);

      await log.clear();

      expect(log.entries, isEmpty);
      expect(log.export(), isEmpty);
      expect(main.existsSync(), isFalse);
      expect(rotated.existsSync(), isFalse);
      await log.dispose();
    });

    test('清理后继续记录仍会落盘（文件被重建）', () async {
      final log = await openService();
      log.info('清理之前');
      log.flush();
      await log.clear();
      log.info('清理之后');
      log.flush();
      final text = readLog();
      expect(text, contains('清理之后'));
      expect(text, isNot(contains('清理之前')));
      await log.dispose();
    });
  });
}
