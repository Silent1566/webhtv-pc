/// 托管 Python 运行时：为 CatVod 站源准备一个带第三方依赖的解释器。
///
/// 背景（2026-10-25 实测）：真实配置里 82 个 csp_PyProxy 站点的 Atvp.py 壳在
/// **模块顶层**就 import requests / Crypto / lxml（C:/dev/Atvp.py:18-23）。本机 PATH
/// 上的解释器（py launcher 指向已删除的 3.15、WindowsApps 别名、LOCALAPPDATA/bin
/// 的 3.14）全都没有这些依赖，于是 sidecar 一启动就在 import 阶段失败，host.py 记
/// 一行 stderr 后以 code 3 退出，用户只看到「sidecar 意外退出（code=3）」。
///
/// 本模块只做一件事：把「缺依赖」这件事**程序化地修好**——用探测到的 base 解释器
/// 建一个托管 venv、把依赖装进去，再把 venv 内的解释器交给宿主使用。
///
/// 设计约束：
/// - 只用 dart:io + package:path：桌面发行版不捆绑 Python，也不能为此新增 Dart 依赖；
/// - 全部同步（Process.runSync），因为调用方必须用 Isolate.run 把它放到后台 isolate：
///   建 venv + pip 安装是分钟级操作，绝不能跑在 UI isolate 上（UI 卡死的既有教训）；
/// - 幂等：已就绪时只跑一次依赖探测，不重复建 venv、不重复安装；
/// - 永不抛异常：失败一律变成 ProvisionResult 里的可诊断结论（含原始输出末尾摘要），
///   由 UI 如实展示原因，而不是又塌缩成一句「运行时未支持」。
library;

import 'dart:io';

import 'package:path/path.dart' as p;

/// 依赖探测脚本：只在有缺失时输出 MISSING:a,b，否则输出 OK。
///
/// 用 importlib.util.find_spec 而不是 import：只查模块能否被解析，不执行模块顶层代码
/// （Atvp.py 的顶层代码本身就会解析配置并发网络请求）。
const String pythonDependencyProbeScript =
    "import importlib.util as u,sys;"
    "ms=[m for m in sys.argv[1:] if u.find_spec(m) is None];"
    "print('MISSING:'+','.join(ms) if ms else 'OK')";

/// CatVod 站源需要的探测模块（宿主侧探测与托管安装共用同一份清单）。
const List<String> catVodPythonProbeModules = <String>['requests', 'Crypto', 'lxml'];

/// 先看本机已有解释器是否已经带齐依赖；不带才建托管 venv。
///
/// 顺序很重要：直接可用的解释器不该触发 20–30 s 的 venv 创建与联网安装。
ProvisionResult prepareCatVodPythonRuntimeSync({
  required String runtimeRoot,
  required List<PythonBaseCandidate> baseCandidates,
  List<String> packages = catVodPythonPackages,
  List<String> probeModules = catVodPythonProbeModules,
  String? pipIndexUrl,
  ProvisionCommandRunner runner = defaultProvisionCommandRunner,
  ProvisionDependencyProbe? probe,
}) {
  final effectiveProbe = probe ??
      (String exe, List<String> args, List<String> modules) =>
          defaultProvisionDependencyProbe(exe, args, modules, runner: runner);

  for (final candidate in baseCandidates) {
    if (probeModules.isNotEmpty &&
        effectiveProbe(candidate.executable, candidate.arguments, probeModules)) {
      return ProvisionResult(
        status: ProvisionStatus.ready,
        executable: candidate.executable,
        arguments: candidate.arguments,
        message: '本机 Python 已具备 CatVod 依赖，无需托管运行时',
      );
    }
  }

  return provisionPythonRuntimeSync(
    runtimeRoot: runtimeRoot,
    baseCandidates: baseCandidates,
    packages: packages,
    probeModules: probeModules,
    pipIndexUrl: pipIndexUrl,
    runner: runner,
    probe: probe,
  );
}

/// 该解释器路径是否就是托管 venv 内的解释器。
bool isManagedPythonExecutable(String executable, String runtimeRoot) {
  if (runtimeRoot.trim().isEmpty) return false;
  return p.equals(p.normalize(executable), p.normalize(venvPythonPath(runtimeRoot)));
}
/// CatVod 站源（Atvp 壳）实测需要的第三方包。
///
/// - requests：壳的顶层 import 与 _FallbackSpider 的 HTTP；
/// - pycryptodome（模块名 Crypto）：secspider 解密链（AES-GCM / HKDF / ECC / SHA256）
///   的硬依赖，缺它连插件源码都解不开。**必须钉 <4**：实测 pycryptodome 4.1.0 的
///   `Crypto.Cipher.PKCS1_OAEP` 没有 `MGF1`（真正的 MGF1 在
///   `Crypto.Signature.pss`），而部分内层插件会写
///   `mgfunc=lambda seed,size: PKCS1_OAEP.MGF1(seed,size,SHA256)` →
///   4.x 上必然 AttributeError；3.24.1 有该类属性。
/// - lxml：_FallbackSpider.html() 的兜底解析；
/// - beautifulsoup4：少数插件（实测 SeedHub[采][广]）把它当硬依赖。
///   只在**安装**清单里：本机解释器带齐前三个即视为可用，不为一个站付建 venv 的代价。
const List<String> catVodPythonPackages = <String>[
  'requests',
  'pycryptodome<4',
  'lxml',
  'beautifulsoup4',
];

/// 探测用模块名 → 安装用包名（Crypto 属于 pycryptodome，两者不同名，必须显式映射）。
const Map<String, String> pythonModuleToPackage = <String, String>{
  'Crypto': 'pycryptodome',
  'requests': 'requests',
  'lxml': 'lxml',
};

/// 一次外部命令的结果。
class ProvisionCommandResult {
  const ProvisionCommandResult({
    required this.exitCode,
    this.stdout = '',
    this.stderr = '',
  });

  final int exitCode;
  final String stdout;
  final String stderr;

  String get combined => '${stdout.trim()}\n${stderr.trim()}';
}

/// 执行外部命令的可注入抽象（单测不启动真实进程）。
typedef ProvisionCommandRunner = ProvisionCommandResult Function(
  String executable,
  List<String> arguments, {
  Duration timeout,
  Map<String, String>? environment,
});

/// 判断某解释器是否已具备 modules（可注入）。
typedef ProvisionDependencyProbe = bool Function(
  String executable,
  List<String> arguments,
  List<String> modules,
);

/// 一个候选 base 解释器（可执行文件 + 前置参数，例如 py.exe 的 -3）。
class PythonBaseCandidate {
  const PythonBaseCandidate({
    required this.executable,
    this.arguments = const <String>[],
  });

  final String executable;
  final List<String> arguments;

  @override
  String toString() => '${p.basename(executable)}'
      '${arguments.isEmpty ? '' : ' ${arguments.join(' ')}'}';
}

/// 默认命令执行器：同步执行，继承父进程环境（pip 需要网络与代理环境变量）。
ProvisionCommandResult defaultProvisionCommandRunner(
  String executable,
  List<String> arguments, {
  Duration timeout = const Duration(minutes: 10),
  Map<String, String>? environment,
}) {
  try {
    final result = Process.runSync(
      executable,
      arguments,
      stdoutEncoding: const SystemEncoding(),
      stderrEncoding: const SystemEncoding(),
      environment: environment,
      includeParentEnvironment: true,
    );
    return ProvisionCommandResult(
      exitCode: result.exitCode,
      stdout: '${result.stdout ?? ''}',
      stderr: '${result.stderr ?? ''}',
    );
  } on ProcessException catch (error) {
    return ProvisionCommandResult(
      exitCode: -1,
      stderr: 'ProcessException: ${error.message}',
    );
  } catch (error) {
    return ProvisionCommandResult(exitCode: -1, stderr: '$error');
  }
}

/// 默认依赖探测：探测脚本退出码为 0 且输出含 OK。
bool defaultProvisionDependencyProbe(
  String executable,
  List<String> arguments,
  List<String> modules, {
  ProvisionCommandRunner runner = defaultProvisionCommandRunner,
}) {
  if (modules.isEmpty) return true;
  final result = runner(
    executable,
    <String>[
      ...arguments,
      '-c',
      pythonDependencyProbeScript,
      ...modules,
    ],
    timeout: const Duration(seconds: 30),
  );
  if (result.exitCode != 0) return false;
  return result.combined.trim().split(RegExp(r'\s+')).contains('OK');
}

/// 托管运行时根目录：`<cacheDir>/python`。
String managedPythonRoot(String cacheDir) => p.join(cacheDir, 'python');

/// 托管 venv 内的解释器路径。
String venvPythonPath(String runtimeRoot) {
  if (Platform.isWindows) return p.join(runtimeRoot, 'Scripts', 'python.exe');
  return p.join(runtimeRoot, 'bin', 'python');
}

/// 托管运行时的准备结论。
enum ProvisionStatus {
  /// 已存在且依赖齐全。
  ready,

  /// 本次新建并安装成功。
  created,

  /// 没有可用来建 venv 的 Python 3。
  noBasePython,

  /// python -m venv 失败。
  createFailed,

  /// pip 安装失败。
  installFailed,

  /// pip 退出码为 0，但重新探测仍缺模块。
  verifyFailed,
}

/// 托管运行时准备结果。
class ProvisionResult {
  const ProvisionResult({
    required this.status,
    this.executable = '',
    this.arguments = const <String>[],
    this.message = '',
    this.steps = const <String>[],
    this.missingModules = const <String>[],
  });

  final ProvisionStatus status;
  final String executable;
  final List<String> arguments;
  final String message;
  final List<String> steps;
  final List<String> missingModules;

  bool get ok =>
      status == ProvisionStatus.ready || status == ProvisionStatus.created;

  @override
  String toString() => '${status.name}: $message'
      '${missingModules.isEmpty ? '' : ' missing=${missingModules.join(',')}'}';
}

/// 用 baseCandidates 中第一个可用解释器，在 runtimeRoot 建/复用托管 venv 并安装 packages。
///
/// 全程同步且**不抛异常**：任何失败都变成 ProvisionResult（含输出末尾摘要）。
/// 调用方必须通过 Isolate.run 把它放到后台 isolate。
ProvisionResult provisionPythonRuntimeSync({
  required String runtimeRoot,
  required List<PythonBaseCandidate> baseCandidates,
  List<String> packages = catVodPythonPackages,
  List<String> probeModules = const <String>['requests', 'Crypto', 'lxml'],
  String? pipIndexUrl,
  ProvisionCommandRunner runner = defaultProvisionCommandRunner,
  ProvisionDependencyProbe? probe,
  Duration createTimeout = const Duration(seconds: 180),
  Duration installTimeout = const Duration(minutes: 10),
}) {
  final steps = <String>[];
  final venvPython = venvPythonPath(runtimeRoot);
  final effectiveProbe = probe ??
      (String exe, List<String> args, List<String> modules) =>
          defaultProvisionDependencyProbe(exe, args, modules, runner: runner);

  // ① 幂等：venv 已存在且依赖齐全 → 直接复用，零网络开销。
  if (File(venvPython).existsSync() &&
      (probeModules.isEmpty ||
          effectiveProbe(venvPython, const <String>[], probeModules))) {
    return ProvisionResult(
      status: ProvisionStatus.ready,
      executable: venvPython,
      message: '托管 Python 运行时已就绪',
      steps: <String>['复用 $venvPython'],
    );
  }

  // ② 选 base：import venv 是标准库，缺它说明该解释器是裁剪版/坏掉的别名。
  PythonBaseCandidate? base;
  final rejected = <String>[];
  for (final candidate in baseCandidates) {
    final check = runner(
      candidate.executable,
      <String>[...candidate.arguments, '-c', 'import venv'],
      timeout: const Duration(seconds: 30),
    );
    if (check.exitCode == 0) {
      base = candidate;
      break;
    }
    rejected.add('$candidate → ${_tail(check.combined, maxLines: 2, maxChars: 160)}');
  }
  if (base == null) {
    return ProvisionResult(
      status: ProvisionStatus.noBasePython,
      message: baseCandidates.isEmpty
          ? '没有找到可用的 Python 3 解释器'
          : '所有 Python 候选都不可用：${rejected.join('；')}',
      steps: steps,
    );
  }
  steps.add('基础解释器 $base 可用');

  // ③ 建 venv（已存在但依赖不全时原地补装）。
  if (!File(venvPython).existsSync()) {
    final create = runner(
      base.executable,
      <String>[...base.arguments, '-m', 'venv', runtimeRoot],
      timeout: createTimeout,
    );
    if (create.exitCode != 0 || !File(venvPython).existsSync()) {
      return ProvisionResult(
        status: ProvisionStatus.createFailed,
        message: '创建 Python 虚拟环境失败：${_tail(create.combined)}',
        steps: steps,
      );
    }
    steps.add('已创建 venv $runtimeRoot');
  } else {
    steps.add('复用已有 venv $runtimeRoot（依赖不全，补装）');
  }

  // ④ 安装依赖。失败一律如实报出 pip 末尾输出，不静默降级。
  final installEnv = <String, String>{};
  if (pipIndexUrl != null && pipIndexUrl.trim().isNotEmpty) {
    installEnv['PIP_INDEX_URL'] = pipIndexUrl.trim();
  }
  final install = runner(
    venvPython,
    <String>[
      '-m',
      'pip',
      'install',
      '--disable-pip-version-check',
      '--no-input',
      // 显式短超时：pip 默认重试会让离网用户卡满 installTimeout（实测默认
      // 写不通的 index 要 21.8 s 才失败，黑洞 IP 6.7 s，DNS 失败 1.9 s）。
      '--retries',
      '1',
      '--timeout',
      '10',
      ...packages,
    ],
    timeout: installTimeout,
    environment: installEnv.isEmpty ? null : installEnv,
  );
  if (install.exitCode != 0) {
    return ProvisionResult(
      status: ProvisionStatus.installFailed,
      executable: venvPython,
      message: '安装 Python 依赖失败：${_tail(install.combined)}',
      steps: steps,
    );
  }
  steps.add('已安装 ${packages.join(', ')}');

  // ⑤ pip 退出码为 0 不等于模块可导入（镜像可能给了空包/错包）→ 必须复验。
  final missing = probeModules.isEmpty
      ? const <String>[]
      : probeModules
          .where((m) => !effectiveProbe(venvPython, const <String>[], <String>[m]))
          .toList(growable: false);
  if (missing.isNotEmpty) {
    return ProvisionResult(
      status: ProvisionStatus.verifyFailed,
      executable: venvPython,
      message: '依赖安装后复验失败，仍缺少：${missing.join(', ')}',
      steps: steps,
      missingModules: missing,
    );
  }

  return ProvisionResult(
    status: ProvisionStatus.created,
    executable: venvPython,
    message: '托管 Python 运行时已创建：$venvPython',
    steps: steps,
  );
}

/// 只保留输出末尾若干行：pip/venv 的关键报错总在最后。
String _tail(String text, {int maxLines = 8, int maxChars = 800}) {
  final lines = text
      .split(RegExp(r'\r?\n'))
      .map((line) => line.trimRight())
      .where((line) => line.isNotEmpty)
      .toList(growable: false);
  final kept = lines.length <= maxLines
      ? lines
      : lines.sublist(lines.length - maxLines);
  var joined = kept.join(' | ');
  if (joined.length > maxChars) {
    joined = joined.substring(joined.length - maxChars);
  }
  return joined;
}