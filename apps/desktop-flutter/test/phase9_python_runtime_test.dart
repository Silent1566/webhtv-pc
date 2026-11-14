/// Python 运行时解析（§9.7 `runtime` 字段）的回归测试。
///
/// 背景：Windows 上 `py.exe` launcher 可能指向**已被删除**的解释器，
/// 旧实现只看「文件是否存在」就采用它，于是 sidecar 一启动就以 101 退出，
/// 日志里只剩「sidecar 崩溃」——把「解释器坏了」伪装成「站源代码有问题」。
/// 这里锁住两条契约：
/// 1. 候选必须逐个用 `--version` 验证，坏的候选不能被采用；
/// 2. 全部候选都坏时必须返回 null（调用方据此显示「运行时未安装」）。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:webhtv_pc/services/spider_process.dart';

void main() {
  group('Python 候选解析', () {
    test('候选来自 PATH，Windows 上 py.exe 排在前面', () {
      final candidates = SidecarRuntimeResolver.pythonCandidates();
      expect(candidates, isNotEmpty, reason: '本机应能找到至少一个 Python 候选');

      if (Platform.isWindows) {
        final launcherIndex = candidates.indexWhere(
          (item) => p.basename(item.executable).toLowerCase() == 'py.exe',
        );
        if (launcherIndex >= 0) {
          expect(
            launcherIndex,
            0,
            reason: 'py.exe 是 Windows 上的首选入口，必须排在候选首位',
          );
          expect(candidates.first.arguments, contains('-3'));
        }
      }

      // 候选不得重复（同一可执行文件 + 同一参数只出现一次）。
      final keys = candidates
          .map((item) => '${item.executable}|${item.arguments.join(' ')}'
              .toLowerCase())
          .toList();
      expect(keys.toSet().length, keys.length);
    });

    test('第一个候选不可用时回退到下一个', () {
      const broken = SidecarCommand(executable: 'C:/nope/py.exe', arguments: ['-3']);
      const good = SidecarCommand(executable: 'C:/ok/python.exe', arguments: []);

      final resolved = SidecarRuntimeResolver.firstUsablePython(
        [broken, good],
        probe: (command) => command.executable == good.executable,
      );

      expect(resolved, isNotNull);
      expect(resolved!.executable, good.executable);
    });

    test('全部候选都不可用时返回 null，而不是硬选第一个', () {
      const broken = SidecarCommand(executable: 'C:/nope/py.exe', arguments: ['-3']);
      final resolved = SidecarRuntimeResolver.firstUsablePython(
        [broken],
        probe: (_) => false,
      );
      expect(resolved, isNull);
    });

    test('候选列表为空时返回 null', () {
      expect(
        SidecarRuntimeResolver.firstUsablePython([], probe: (_) => true),
        isNull,
      );
    });

    test('文件不存在的候选一律判为不可用（不启动进程）', () {
      expect(
        SidecarRuntimeResolver.pythonWorks(
          const SidecarCommand(executable: 'C:/definitely/missing/python.exe', arguments: []),
        ),
        isFalse,
      );
    });

    test('真实探测：可用候选必须能打印 Python 3.x', () {
      final candidates = SidecarRuntimeResolver.pythonCandidates();
      final usable = SidecarRuntimeResolver.firstUsablePython(candidates);
      if (usable == null) {
        // 没有可用 Python 的机器上不能静默通过：至少断言候选非空，
        // 证明「解析不到」是环境结论而不是解析器自己坏了。
        expect(candidates, isNotEmpty);
        return;
      }
      final version = Process.runSync(usable.executable, [
        ...usable.arguments,
        '--version',
      ]);
      final output = '${version.stdout}${version.stderr}';
      expect(version.exitCode, 0);
      expect(output, matches(RegExp(r'Python\s+3\.')));
    });
  });
}
