/// 真实 Python 解释器的生命周期测试夹具。
///
/// 只按文件存在挑候选会把「解释器坏了」伪装成「取消没生效」：本机 `py.exe`
/// 指向已被删除的 3.15（`py -3` 以 101 退出），WindowsApps 的 App Execution
/// Alias 也可能启动成功却不执行任何代码。这里用真实子进程 + PYTHONPATH 模块
/// 标记验证候选，并拒绝无法保留参数的 launcher 候选。
library;

import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:webhtv_pc/services/spider_process.dart';

/// 只有 PYTHONPATH 上才找得到的标记模块名。
const String pythonFixtureModule = 'webhtv_fixture_marker';

/// 标记模块里的字面量：解释器真的 import 了它才会出现在 stdout。
const String pythonFixtureMarker = 'pythonpath-honored';

/// 挑第一个**真的**能执行 Python 3 且读取 PYTHONPATH 的候选解释器。
///
/// `PythonEnvironment.systemCandidates` 只接收可执行文件路径，参数会被丢弃
/// （`python_environment.dart` 中的 `SidecarCommand(executable: e, arguments: const [])`），
/// 所以 `py.exe -3` 这类带参数的候选不能改写成无参调用——那会改变它实际运行的
/// 版本。这里跳过它们，交给下一个无参可用的候选。
///
/// 全部不可用时返回 null；调用方必须 fail 而不是 skip，否则「本机没有真实
/// 解释器」会被静默当成通过。
Future<SidecarCommand?> firstRunnablePython({
  List<SidecarCommand>? candidates,
  Duration limit = const Duration(seconds: 20),
}) async {
  final probe = Directory.systemTemp.createTempSync('webhtv_python_fixture_');
  try {
    File(p.join(probe.path, '$pythonFixtureModule.py')).writeAsStringSync(
      "MARKER = '$pythonFixtureMarker'\n",
    );
    for (final candidate
        in candidates ??
            SidecarRuntimeResolver.pythonCandidates(queryLauncher: false)) {
      if (candidate.arguments.isNotEmpty) continue;
      if (await _runsPython(candidate, probe.path, limit)) return candidate;
    }
    return null;
  } finally {
    try {
      probe.deleteSync(recursive: true);
    } on FileSystemException {
      // 清理失败不改变结论，临时目录交给系统回收。
    }
  }
}

Future<bool> _runsPython(
  SidecarCommand command,
  String moduleDirectory,
  Duration limit,
) async {
  Process? process;
  try {
    process = await Process.start(
      command.executable,
      [
        ...command.arguments,
        '-B',
        '-c',
        'import $pythonFixtureModule as m, sys;'
            'print("$pythonFixtureModule:" + m.MARKER + ":Python " + str(sys.version_info[0]))',
      ],
      // 与 PythonEnvironment 一致：给了显式环境就不再继承父进程环境。
      environment: {...Platform.environment, 'PYTHONPATH': moduleDirectory},
      includeParentEnvironment: false,
    );
    final result = await Future.wait<Object>([
      process.exitCode,
      process.stdout.transform(systemEncoding.decoder).join(),
      process.stderr.transform(systemEncoding.decoder).join(),
    ]).timeout(limit);
    return result[0] == 0 &&
        '${result[1]}'
            .contains('$pythonFixtureModule:$pythonFixtureMarker:Python 3');
  } on Object {
    return false;
  } finally {
    final running = process;
    if (running != null) {
      try {
        running.kill();
      } on Object {
        // 已退出或句柄已释放。
      }
      await running.exitCode.timeout(
        const Duration(seconds: 2),
        onTimeout: () => -1,
      );
    }
  }
}
