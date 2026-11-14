/// 托管 Python 运行时（CatVod 壳的依赖准备）回归测试。
///
/// 背景（2026-10-24 用户实测）：82 个 `csp_PyProxy` 站点走 Python sidecar，
/// 而宿主选中的解释器没有 requests/Crypto/lxml —— Atvp 壳在**模块顶层** import，
/// 于是 host.py 记一行 stderr 后 `return 3`，用户只看到「sidecar 意外退出 code=3」。
///
/// 这里锁住的契约：
/// 1. 本机解释器已带依赖 → 直接采用，**不建 venv、不联网**；
/// 2. 否则建托管 venv 并安装，且安装清单要钉住 pycryptodome<4（4.x 缺 PKCS1_OAEP.MGF1）；
/// 3. pip 退出码为 0 不等于可导入，必须逐模块复验；
/// 4. 任何失败都变成 ProvisionResult，绝不抛异常（调用方在后台 isolate 里跑）。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:webhtv_pc/services/python_runtime_provision.dart';

void main() {
  late Directory temp;
  late String runtimeRoot;
  late String venvPython;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('webhtv-provision-');
    runtimeRoot = '${temp.path}/python';
    venvPython = venvPythonPath(runtimeRoot);
  });

  tearDown(() {
    if (temp.existsSync()) temp.deleteSync(recursive: true);
  });

  group('托管 Python 运行时准备', () {
    test('本机解释器已带依赖时不建 venv、不联网', () {
      final calls = <String>[];
      final result = prepareCatVodPythonRuntimeSync(
        runtimeRoot: runtimeRoot,
        baseCandidates: const [
          PythonBaseCandidate(executable: 'C:/fake/python.exe'),
        ],
        runner: (exe, args, {timeout = const Duration(minutes: 10), environment}) {
          calls.add(args.join(' '));
          return const ProvisionCommandResult(exitCode: 0);
        },
        probe: (exe, args, modules) => true,
      );

      expect(result.status, ProvisionStatus.ready);
      expect(result.executable, 'C:/fake/python.exe');
      expect(
        calls.any((line) => line.contains('venv')),
        isFalse,
        reason: '已有带依赖的解释器不该付建 venv 的代价',
      );
      expect(calls.any((line) => line.contains('pip')), isFalse);
    });

    test('候选都缺依赖时建 venv 并安装，安装清单钉住 pycryptodome<4', () {
      final installArgs = <String>[];
      var installed = false;
      final result = prepareCatVodPythonRuntimeSync(
        runtimeRoot: runtimeRoot,
        baseCandidates: const [
          PythonBaseCandidate(executable: 'C:/fake/python.exe'),
        ],
        runner: (exe, args, {timeout = const Duration(minutes: 10), environment}) {
          if (args.contains('venv')) {
            File(venvPython).createSync(recursive: true);
            return const ProvisionCommandResult(exitCode: 0);
          }
          if (args.contains('pip')) {
            installArgs.addAll(args);
            installed = true;
            return const ProvisionCommandResult(
              exitCode: 0,
              stdout: 'Successfully installed',
            );
          }
          return const ProvisionCommandResult(exitCode: 0);
        },
        probe: (exe, args, modules) => installed,
      );

      expect(result.status, ProvisionStatus.created);
      expect(result.executable, venvPython);
      expect(installArgs, contains('pycryptodome<4'));
      expect(installArgs, contains('requests'));
      expect(installArgs, contains('lxml'));
      expect(installArgs, contains('beautifulsoup4'));
      expect(installArgs, contains('--no-input'));
      expect(installArgs, contains('1'));
      expect(
        installArgs.contains('--retries'),
        isTrue,
        reason: '离网时 pip 默认重试会卡满 installTimeout',
      );
    });

    test('pip 失败 → installFailed，并回显 pip 末尾输出', () {
      final result = prepareCatVodPythonRuntimeSync(
        runtimeRoot: runtimeRoot,
        baseCandidates: const [
          PythonBaseCandidate(executable: 'C:/fake/python.exe'),
        ],
        runner: (exe, args, {timeout = const Duration(minutes: 10), environment}) {
          if (args.contains('venv')) {
            File(venvPython).createSync(recursive: true);
            return const ProvisionCommandResult(exitCode: 0);
          }
          if (args.contains('pip')) {
            return const ProvisionCommandResult(
              exitCode: 1,
              stderr: 'ERROR: Could not find a version that satisfies requests',
            );
          }
          return const ProvisionCommandResult(exitCode: 0);
        },
        probe: (exe, args, modules) => false,
      );

      expect(result.status, ProvisionStatus.installFailed);
      expect(result.ok, isFalse);
      expect(result.message, contains('Could not find a version'));
    });

    test('pip 退出码 0 但复验仍缺模块 → verifyFailed 且列出缺失模块', () {
      final result = prepareCatVodPythonRuntimeSync(
        runtimeRoot: runtimeRoot,
        baseCandidates: const [
          PythonBaseCandidate(executable: 'C:/fake/python.exe'),
        ],
        runner: (exe, args, {timeout = const Duration(minutes: 10), environment}) {
          if (args.contains('venv')) {
            File(venvPython).createSync(recursive: true);
          }
          return const ProvisionCommandResult(exitCode: 0);
        },
        probe: (exe, args, modules) => modules.isEmpty,
      );

      expect(result.status, ProvisionStatus.verifyFailed);
      expect(result.missingModules, isNotEmpty);
      expect(result.ok, isFalse);
    });

    test('所有候选都建不了 venv → noBasePython（不抛异常）', () {
      final result = prepareCatVodPythonRuntimeSync(
        runtimeRoot: runtimeRoot,
        baseCandidates: const [
          PythonBaseCandidate(executable: 'C:/broken/py.exe', arguments: ['-3']),
          PythonBaseCandidate(executable: 'C:/broken/python.exe'),
        ],
        runner: (exe, args, {timeout = const Duration(minutes: 10), environment}) =>
            const ProvisionCommandResult(
              exitCode: 101,
              stderr: 'Unable to create process',
            ),
        probe: (exe, args, modules) => false,
      );

      expect(result.status, ProvisionStatus.noBasePython);
      expect(result.message, contains('所有 Python 候选都不可用'));
      expect(
        result.message,
        contains('py.exe -3'),
        reason: '必须逐个候选回显失败原因（含 py.exe 的 -3 参数），否则用户无从排查',
      );
      expect(result.message, contains('Unable to create process'));
    });
  });

  group('CatVod 解释器依赖探测', () {
    test('依赖探测脚本用 find_spec（不执行模块顶层代码）', () {
      expect(pythonDependencyProbeScript, contains('find_spec'));
      expect(pythonDependencyProbeScript, contains('MISSING'));
      expect(
        pythonDependencyProbeScript.contains('import requests'),
        isFalse,
        reason: '不能真的 import：Atvp 壳顶层会解析配置并发网络请求',
      );
    });

    test('宿主侧探测清单与安装清单模块名一致', () {
      expect(catVodPythonProbeModules, containsAll(<String>['requests', 'Crypto', 'lxml']));
      expect(pythonModuleToPackage['Crypto'], 'pycryptodome');
    });

    test('isManagedPythonExecutable 只认托管 venv 内的解释器', () {
      expect(isManagedPythonExecutable(venvPython, runtimeRoot), isTrue);
      expect(isManagedPythonExecutable('C:/other/python.exe', runtimeRoot), isFalse);
      expect(isManagedPythonExecutable(venvPython, ''), isFalse);
    });
  });
}