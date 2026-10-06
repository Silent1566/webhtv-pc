/// Windows Job Object 隔离原语的回归测试（§9.8、§18.2.1）。
///
/// 背景（真实缺陷）：`JOB_OBJECT_LIMIT_JOB_TIME` 必须搭配**非零**的
/// `PerJobUserTimeLimit`。传入 0 时内核把参数判为非法，`SetInformationJobObject`
/// 整体失败（实测 Win10/11 返回 `ERROR_INVALID_PARAMETER`），于是 `create()`
/// 返回 null，调用方静默退化成「无作业」：子进程既不受内存/CPU 限制，也**不会**
/// 随宿主退出被内核回收。
///
/// 猫源运行时（`CatNodeRuntime`）用 `maxCpuSeconds = 0` 表示「长驻服务不限 CPU」，
/// 因此长期命中该路径，每次退出都留下孤儿 Node 进程——这正是「历史进程没杀干净」
/// 的根因。`test/phase2_ipc_test.dart` 只覆盖了 `cpuSeconds > 0` 的 sidecar 路径，
/// 所以缺陷一直没有被门禁拦住。
///
/// 本文件把两件事钉成回归门禁：
/// 1. `cpuSeconds == 0` 也必须拿到可用作业；
/// 2. 未实际设置的机制不得出现在隔离声明里（§18.2.1 禁止虚假隔离声明）。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/services/windows_job.dart';

/// 用 `tasklist` 判断 PID 是否仍存活。
///
/// 刻意用 CSV 格式并按 PID 字面量匹配，而不是匹配「没有运行」之类的人读文案：
/// 后者随系统语言变化，在非中文 Windows 上会给出错误结论。
Future<bool> _isAlive(int pid) async {
  final result = await Process.run('tasklist', <String>[
    '/FI',
    'PID eq $pid',
    '/NH',
    '/FO',
    'CSV',
  ]);
  return (result.stdout as String).contains('"$pid"');
}

/// 起一个能存活很久的子进程，供回收测试使用。
Future<Process> _spawnLongLived() => Process.start(
  r'C:\Windows\System32\cmd.exe',
  const <String>['/c', 'ping -n 600 127.0.0.1 > nul'],
);

void main() {
  group(
    'WindowsJobObject 创建（§9.8）',
    () {
      test('cpuSeconds=0（不限 CPU）时仍必须创建成功', () {
        // 猫源运行时的真实参数：长驻服务不能限 CPU。
        final job = WindowsJobObject.create(
          memoryBytes: 256 * 1024 * 1024,
          cpuSeconds: 0,
        );
        addTearDown(() => job?.dispose());
        expect(
          job,
          isNotNull,
          reason: 'cpuSeconds=0 不得导致作业创建失败，否则子进程完全失去隔离与回收能力',
        );
        expect(
          job!.report.canTerminateTree,
          isTrue,
          reason: '作业必须能终止整个进程树，否则退出后会残留孤儿进程',
        );
      });

      test('未设置 CPU 上限时不得宣称 cpu-time-limit 机制', () {
        final job = WindowsJobObject.create(
          memoryBytes: 256 * 1024 * 1024,
          cpuSeconds: 0,
        );
        addTearDown(() => job?.dispose());
        expect(job, isNotNull);
        expect(
          job!.report.mechanisms,
          isNot(contains('job-object:cpu-time-limit')),
          reason: '未实际设置的机制不得出现在隔离声明里（§18.2.1）',
        );
        // 内存上限确实设置了，必须如实声明。
        expect(job.report.mechanisms, contains('job-object:process-memory-limit'));
      });

      test('cpuSeconds>0 时如实声明 cpu-time-limit 机制', () {
        final job = WindowsJobObject.create(
          memoryBytes: 256 * 1024 * 1024,
          cpuSeconds: 60,
        );
        addTearDown(() => job?.dispose());
        expect(job, isNotNull);
        expect(job!.report.level, startsWith('job-object'));
        expect(job.report.mechanisms, contains('job-object:cpu-time-limit'));
      });
    },
    skip: Platform.isWindows ? null : 'Windows Job Object 仅在 Windows 生效',
  );

  group(
    'WindowsJobObject 进程树回收（§18.2.1）',
    () {
      test('kill-on-close：仅关闭作业句柄即终止子进程', () async {
        final job = WindowsJobObject.create(
          memoryBytes: 256 * 1024 * 1024,
          cpuSeconds: 0,
        );
        expect(job, isNotNull);
        final child = await _spawnLongLived();
        expect(job!.assign(child.pid), isTrue);
        await Future<void>.delayed(const Duration(seconds: 2));
        expect(await _isAlive(child.pid), isTrue, reason: '关闭作业前子进程应存活');

        // 只关句柄、不调用 terminate()：验证 KILL_ON_JOB_CLOSE 真的生效。
        job.dispose();
        await Future<void>.delayed(const Duration(seconds: 3));
        expect(
          await _isAlive(child.pid),
          isFalse,
          reason: '作业句柄关闭后子进程必须被内核终止，否则退出后残留孤儿进程',
        );
      }, timeout: const Timeout(Duration(seconds: 90)));

      test('terminate() 立即终止作业内进程', () async {
        final job = WindowsJobObject.create(
          memoryBytes: 256 * 1024 * 1024,
          cpuSeconds: 0,
        );
        expect(job, isNotNull);
        final child = await _spawnLongLived();
        expect(job!.assign(child.pid), isTrue);
        await Future<void>.delayed(const Duration(seconds: 1));
        expect(job.terminate(), isTrue);
        job.dispose();
        await Future<void>.delayed(const Duration(seconds: 3));
        expect(await _isAlive(child.pid), isFalse);
      }, timeout: const Timeout(Duration(seconds: 90)));
    },
    skip: Platform.isWindows ? null : 'Windows Job Object 仅在 Windows 生效',
  );
}
