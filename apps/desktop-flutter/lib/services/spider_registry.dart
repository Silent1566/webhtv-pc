/// 本地 Spider manifest 注册表（设计文档 §9.7、§17.2、§18.2）。
///
/// Phase 2 的安全边界：只加载**本机已存在**的 manifest 与站源代码，不下载远程脚本，
/// 因此不存在「首次执行远程脚本前必须由用户确认来源和权限」的确认流程——该流程属于
/// Phase 3 远程分发，此时才需要。
///
/// manifest 与代码分离：宿主只信任 manifest 声明的 capability / permission / limits，
/// 站源自报的能力超出 manifest 时以 manifest 为准（§9.7）。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../core/ipc_protocol.dart';
import 'log_service.dart';
import 'spider_process.dart';

/// 一个已发现的本地 Spider。
class LocalSpider {
  const LocalSpider({
    required this.manifest,
    required this.manifestPath,
    required this.rootDir,
    required this.entryPath,
  });

  final SpiderManifest manifest;
  final String manifestPath;

  /// manifest 所在目录；`entry` 相对该目录解析。
  final String rootDir;
  final String entryPath;

  String get key => manifest.key;

  bool get entryExists => File(entryPath).existsSync();
}

/// 注册表：扫描 Spider 目录，加载并校验 manifest（§9.7）。
class SpiderManifestRegistry {
  SpiderManifestRegistry({required this.root, required this.log});

  /// Spider 根目录（`%APPDATA%/webhtv-pc/spiders`）。
  final String root;
  final LogService log;

  final Map<String, LocalSpider> _spiders = {};

  Map<String, LocalSpider> get spiders => Map.unmodifiable(_spiders);

  List<LocalSpider> get sortedSpiders {
    final list = _spiders.values.toList()
      ..sort((a, b) => a.key.compareTo(b.key));
    return list;
  }

  /// 扫描根目录。每次调用都会重读 manifest，使手工编辑后无需重启。
  Future<List<LocalSpider>> scan() async {
    _spiders.clear();
    final directory = Directory(root);
    if (!await directory.exists()) return const [];

    await for (final entity in directory.list(followLinks: false)) {
      final manifestFile = entity is Directory
          ? File(p.join(entity.path, 'manifest.json'))
          : (entity is File && p.basename(entity.path).endsWith('.json')
                ? entity
                : null);
      if (manifestFile == null || !await manifestFile.exists()) continue;
      final loaded = await _load(manifestFile);
      if (loaded == null) continue;
      if (_spiders.containsKey(loaded.key)) {
        log.warning(
          '忽略重复的 Spider key=${loaded.key}（已存在 ${_spiders[loaded.key]!.manifestPath}）',
          scope: 'spider',
        );
        continue;
      }
      _spiders[loaded.key] = loaded;
    }
    log.info(
      'Spider manifest 扫描完成 root=$root found=${_spiders.length}',
      scope: 'spider',
    );
    return sortedSpiders;
  }

  /// 注册单个 manifest 文件；供测试与「手动添加」路径使用。
  Future<LocalSpider?> register(String manifestPath) async {
    final loaded = await _load(File(manifestPath));
    if (loaded == null) return null;
    _spiders[loaded.key] = loaded;
    return loaded;
  }

  LocalSpider? byKey(String key) => _spiders[key];

  Future<LocalSpider?> _load(File file) async {
    final String text;
    try {
      text = await file.readAsString();
    } catch (error) {
      log.error('读取 manifest 失败 ${file.path}：$error', scope: 'spider');
      return null;
    }

    Object? decoded;
    try {
      decoded = jsonDecode(text);
    } catch (error) {
      log.error('manifest 不是合法 JSON ${file.path}：$error', scope: 'spider');
      return null;
    }

    final manifest = SpiderManifest.fromJson(decoded);
    final problems = manifest.problems;
    if (problems.isNotEmpty) {
      // §9.7：未声明权限的能力在进程层拒绝；manifest 非法则不得加载。
      log.error(
        'manifest 校验失败 ${file.path}：${problems.join("; ")}',
        scope: 'spider',
      );
      return null;
    }
    if (manifest.missingRequired.isNotEmpty) {
      log.error(
        'manifest 缺少必需方法 key=${manifest.key}：${manifest.missingRequired.join(",")}',
        scope: 'spider',
      );
      return null;
    }

    final rootDir = p.dirname(file.path);
    final entryPath = p.isAbsolute(manifest.entry)
        ? manifest.entry
        : p.normalize(p.join(rootDir, manifest.entry));
    // §9.8：远程脚本只在工作目录内运行；本地路径也必须落在 manifest 目录内。
    if (!p.isWithin(rootDir, entryPath) && entryPath != rootDir) {
      log.error(
        'manifest entry 越出 Spider 目录 key=${manifest.key} entry=$entryPath',
        scope: 'spider',
      );
      return null;
    }

    return LocalSpider(
      manifest: manifest,
      manifestPath: file.path,
      rootDir: rootDir,
      entryPath: entryPath,
    );
  }
}

/// 站点与本地 Spider 的绑定（`api` 形态 `spider-local:<key>` 或 manifest 相对路径）。
///
/// 使用独立的 `spider-local:` scheme 而不是猜测 `api` 内容，避免把普通 URL 误判为
/// 本地 Spider，也避免把本地路径误当作远端接口（§8.1、§9.9）。
class SpiderLocalBinding {
  const SpiderLocalBinding({required this.registry});

  static const String scheme = 'spider-local:';

  final SpiderManifestRegistry registry;

  /// 从站点 `api` 解析本地 Spider。
  ///
  /// 返回 null 表示该站点不是本地 Spider 形态。
  LocalSpider? resolve(String api) {
    final trimmed = api.trim();
    if (!trimmed.toLowerCase().startsWith(scheme)) return null;
    final target = trimmed.substring(scheme.length).trim();
    if (target.isEmpty) return null;
    // 允许 `spider-local:<key>` 与 `spider-local:<相对路径>/manifest.json` 两种写法。
    final key = p.basename(target).replaceAll(RegExp(r'\.json$'), '');
    return registry.byKey(target) ??
        registry.byKey(key) ??
        registry.byKey(target.replaceAll('/', '-'));
  }

  /// 该站点是否声明为本地 Spider。
  static bool matches(String api) =>
      api.trim().toLowerCase().startsWith(scheme);
}

/// `csp_*` 站点到桌面 JVM 站源的绑定（§9.3 `tvbox-java-v1`）。
///
/// `csp_<类名>` 是 TVBox 生态的 Java 站源形态：`api` 是**类名**，`jar`（或顶层 `spider`）
/// 是代码包。PC 端只在满足以下两个条件时才认为可用：
///
/// 1. 存在本地缓存的 jar/目录，且**不含 `classes.dex`**——含 dex 的是 Android 站源，
///    JVM 无法加载（ADR-0002 §1.1），必须如实报「不支持」而不是启动后崩溃；
/// 2. 本机有 Java 运行时且 `spider-host-jvm/host.jar` 存在。
///
/// 缓存位置：`<configDir>/spiders/csp/<key>/`，由用户在设置页导入桌面 jar。
class CspJvmBinding {
  const CspJvmBinding({required this.root});

  /// `<configDir>/spiders/csp`。
  final String root;

  /// `api` 是否为 `csp_*` 形态。
  static bool matches(String api) => api.trim().toLowerCase().startsWith('csp_');

  /// 从 `api` 提取类名（去掉 `csp_` 前缀）。
  static String classNameOf(String api) {
    final trimmed = api.trim();
    if (!matches(trimmed)) return trimmed;
    return trimmed.substring(4);
  }

  /// 站点 key 对应的缓存目录。
  String directoryFor(String siteKey) => p.join(root, _safe(siteKey));

  /// 在缓存目录内定位入口：优先 `index.jar`，其次唯一的一个 jar，最后类目录。
  String? entryFor(String siteKey) {
    final directory = Directory(directoryFor(siteKey));
    if (!directory.existsSync()) return null;

    final index = File(p.join(directory.path, 'index.jar'));
    if (index.existsSync()) return index.path;

    final jars = directory
        .listSync()
        .whereType<File>()
        .where((file) => file.path.toLowerCase().endsWith('.jar'))
        .toList()
      ..sort((a, b) => a.path.compareTo(b.path));
    if (jars.isNotEmpty) return jars.first.path;

    // 类目录：包含 `.class` 的目录。
    for (final entity in directory.listSync()) {
      if (entity is Directory && _containsClass(entity)) return entity.path;
    }
    return null;
  }

  static bool _containsClass(Directory directory) {
    try {
      for (final entity in directory.listSync(recursive: true, followLinks: false)) {
        if (entity is File && entity.path.toLowerCase().endsWith('.class')) return true;
      }
    } catch (_) {
      // 无法读取时按「不含 class」处理。
    }
    return false;
  }

  /// jar 是否为 Android 站源（内含 `classes.dex`）。
  ///
  /// 只做**目录项**检查，不加载任何类，因此对不可信 jar 也安全（§9.8）。
  static bool isAndroidJar(String path) {
    if (!path.toLowerCase().endsWith('.jar')) return false;
    final file = File(path);
    if (!file.existsSync()) return false;
    try {
      final bytes = file.readAsBytesSync();
      // zip 目录项里的文件名字节串是明文，直接搜索 `classes.dex` 即可，
      // 无需解压、不执行任何代码。
      return _containsAscii(bytes, 'classes.dex');
    } catch (_) {
      return false;
    }
  }

  static bool _containsAscii(List<int> haystack, String needle) {
    final target = needle.codeUnits;
    outer:
    for (var i = 0; i + target.length <= haystack.length; i++) {
      for (var j = 0; j < target.length; j++) {
        if (haystack[i + j] != target[j]) continue outer;
      }
      return true;
    }
    return false;
  }

  static String _safe(String value) =>
      value.replaceAll(RegExp(r'[^A-Za-z0-9_.-]'), '_');
}

/// Java 运行时探测结果（§9.3 `tvbox-java-v1`）。
///
/// [command] 为空时必须带 [issue]：UI 要能告诉用户「缺什么、为什么不能用」，
/// 而不是笼统的「Java 未安装」——实测本机 PATH 上的 Java 8 与 JDK 21 共存，
/// 只按 PATH 顺序取第一个会得到「Java 已安装但启动即崩」的假象。
class JavaRuntimeProbe {
  const JavaRuntimeProbe({
    required this.command,
    this.issue,
    this.major,
    this.hasCompiler = false,
  });

  /// 可直接启动 `host.jar` 的命令；不可用时为 null。
  final SidecarCommand? command;

  /// 不可用原因（已包含候选路径与版本信息）。
  final String? issue;

  /// 探测到的 Java 主版本。
  final int? major;

  /// 同目录是否存在 `javac`（即 JDK 而非 JRE）。`.java` 源码入口需要编译器。
  final bool hasCompiler;

  bool get available => command != null;
}

/// 本地 Spider 的运行命令解析（§9.7 `runtime` 字段）。
class LocalSpiderCommand {
  const LocalSpiderCommand({
    required this.executable,
    required this.arguments,
  });

  final String executable;
  final List<String> arguments;

  static const String _hostRelative = 'host.py';

  /// 解析成可执行命令（§9.7 `runtime` 字段）。
  ///
  /// - `python*` 用本机 Python 启动 `sidecars/spider-host-python/host.py`；
  /// - `node*` 用本机 Node 启动 `sidecars/spider-host-js/host.js`（§9.1
  ///   `tvbox-js-v1` 沙箱，与 Python 宿主同一份 `webhtv-ipc-v1` 帧契约）。
  ///
  /// [hostPath] 是 Python 宿主路径（`defaultSidecarHostPath()` 或测试覆盖）；
  /// [jsHostPath] 是 JS 宿主路径；[jvmHostPath] 是 JVM 宿主路径（`host.jar`）。
  /// 未显式给出时按发行包布局从 [hostPath] 推导（`sidecars/` 下两个兄弟运行时目录），
  /// 使单一路径参数在仓库与发行包两种布局下都成立。
  ///
  /// 运行时未安装/不受支持时返回 null，调用方必须显示「运行时未安装」
  /// 而不是静默失败。
  static LocalSpiderCommand? resolve({
    required LocalSpider spider,
    required String hostPath,
    String? jsHostPath,
    String? jvmHostPath,
    LogService? log,
  }) {
    final runtime = spider.manifest.runtime.toLowerCase();

    if (runtime.startsWith('python')) {
      if (!File(hostPath).existsSync()) {
        log?.error('sidecar 宿主不存在：$hostPath', scope: 'spider');
        return null;
      }
      // Python 命令统一由 host.py 决定具体解释器，避免宿主与 sidecar 猜测不一致；
      // 这里用宿主自身的解释器探测逻辑（`py -3` 优先，其次 `python3`/`python`）。
      final python = _pythonCommand();
      if (python == null) {
        log?.warning('未找到 Python 运行时，无法启动 sidecar', scope: 'spider');
        return null;
      }
      return LocalSpiderCommand(
        executable: python.executable,
        arguments: [
          ...python.arguments,
          hostPath,
          '--entry',
          spider.entryPath,
          '--manifest',
          spider.manifestPath,
        ],
      );
    }

    // JVM 运行时（`tvbox-java-v1`，§9.3）：桌面 Java 站源。
    //
    // 注意：这条路径**不**加载 Android jar——Android 站源是 `classes.dex` 且依赖
    // `android.content.Context`，JVM 无法加载（ADR-0002 §1.1）。此处只接受无
    // Android Context 的桌面 jar / 类目录 / 源码（§9.9）。
    if (runtime.startsWith('jvm') || runtime.startsWith('java')) {
      final resolvedJvmHost = (jvmHostPath != null && jvmHostPath.isNotEmpty)
          ? jvmHostPath
          : (hostPath.isNotEmpty ? jvmHostPathFor(hostPath) : '');
      if (resolvedJvmHost.isEmpty || !File(resolvedJvmHost).existsSync()) {
        log?.error('JVM sidecar 宿主不存在：$resolvedJvmHost', scope: 'spider');
        return null;
      }
      final java = _javaCommand();
      if (java == null) {
        final probe = probeJavaRuntime(log: log);
        log?.warning(
          '未找到可用 Java 运行时，无法启动 JVM sidecar：${probe.issue ?? "原因未知"}',
          scope: 'spider',
        );
        return null;
      }
      return LocalSpiderCommand(
        executable: java.executable,
        arguments: [
          ...java.arguments,
          // JVM 必须显式限堆：Windows 作业对象的内存上限是**硬限制**，而 JVM
          // 默认按物理内存的 1/4 预留堆（本机实测 640 MiB），在 256 MiB 作业内
          // 会直接 `os::commit_memory failed (DOS error 1455)` 退出，表现为
          // 「sidecar 启动即崩」而不是可诊断的错误（§18.2.1 资源限制）。
          ...jvmHeapFlags(spider.manifest.limits.memoryMiB),
          '-jar',
          resolvedJvmHost,
          '--entry',
          spider.entryPath,
          '--manifest',
          spider.manifestPath,
        ],
      );
    }

    if (runtime.startsWith('node')) {
      // 显式给出的 JS 宿主优先；否则由 Python 宿主路径推导（兄弟目录）。
      final resolvedJsHost = (jsHostPath != null && jsHostPath.isNotEmpty)
          ? jsHostPath
          : (hostPath.isNotEmpty ? jsHostPathFor(hostPath) : '');
      if (resolvedJsHost.isEmpty || !File(resolvedJsHost).existsSync()) {
        log?.error('JS sidecar 宿主不存在：$resolvedJsHost', scope: 'spider');
        return null;
      }
      final node = _nodeCommand();
      if (node == null) {
        log?.warning('未找到 Node 运行时，无法启动 JS sidecar', scope: 'spider');
        return null;
      }
      return LocalSpiderCommand(
        executable: node.executable,
        arguments: [
          ...node.arguments,
          resolvedJsHost,
          '--entry',
          spider.entryPath,
          '--manifest',
          spider.manifestPath,
        ],
      );
    }

    log?.warning(
      'runtime=${spider.manifest.runtime} 不受支持（已实现 python*/node*/jvm*）',
      scope: 'spider',
    );
    return null;
  }

  /// JVM 堆参数：必须让 JVM 在作业对象的内存硬限制内完成启动。
  ///
  /// 实测（JDK 21 + Windows 作业对象 256 MiB）：不加参数时 JVM 会尝试预留
  /// 640 MiB 堆并直接失败退出。因此按 manifest 的 `limits.memoryMiB` 推导：
  /// 堆上限取约一半（留给 Metaspace、代码缓存、线程栈与直接内存），
  /// 并固定初始堆避免按物理内存自动推导。
  ///
  /// [memoryMiB] 过小时不返回任何参数——此时 JVM 无论如何都跑不起来，
  /// 让宿主按原有路径报错，而不是给出一组必然失败的参数。
  static List<String> jvmHeapFlags(int memoryMiB) {
    if (memoryMiB < 128) return const [];
    final heapMiB = (memoryMiB ~/ 2).clamp(64, 2048);
    final initialMiB = (heapMiB ~/ 8).clamp(16, 256);
    return [
      '-Xmx${heapMiB}m',
      '-Xms${initialMiB}m',
      // Metaspace 默认无上限（受作业对象总内存限制）；显式给出上限让失败
      // 发生在类加载阶段并带明确信息，而不是随机位置的 OOM。
      '-XX:MaxMetaspaceSize=${(memoryMiB ~/ 4).clamp(32, 256)}m',
      // 关闭 JVM 自己的容器/物理内存探测，避免它按宿主机内存推导堆。
      '-XX:MaxDirectMemorySize=${(memoryMiB ~/ 8).clamp(16, 256)}m',
    ];
  }

  /// 由 Python 宿主路径推导 JS 宿主路径：`sidecars/` 下两个兄弟运行时目录。
  ///
  /// `.../sidecars/spider-host-python/host.py` →
  /// `.../sidecars/spider-host-js/host.js`
  static String jsHostPathFor(String pythonHostPath) {
    final sidecarsDir = p.dirname(p.dirname(pythonHostPath));
    return p.join(sidecarsDir, 'spider-host-js', 'host.js');
  }

  /// 由 Python 宿主路径推导 JVM 宿主路径：`sidecars/spider-host-jvm/host.jar`。
  static String jvmHostPathFor(String pythonHostPath) {
    final sidecarsDir = p.dirname(p.dirname(pythonHostPath));
    return p.join(sidecarsDir, 'spider-host-jvm', 'host.jar');
  }

  /// 查找本机 Java。返回 null 表示未安装或不满足版本要求。
  ///
  /// 注意：**不能只按 PATH 顺序取第一个 `java.exe`**。实测本机 PATH 上
  /// `C:\Program Files\Java\jre1.8.0_501\bin\java.exe` 排在 JDK 21 之前，
  /// 而 `host.jar` 用 `--release 17` 构建，Java 8 会直接以
  /// `UnsupportedClassVersionError` 退出（表现为 sidecar 启动即崩）。
  /// 因此这里逐个探测候选并校验版本，详见 [probeJavaRuntime]。
  static SidecarCommand? _javaCommand() => probeJavaRuntime().command;

  /// 探测可用的 Java 运行时，并返回不可用时的**可定位原因**。
  ///
  /// 规则：
  /// 1. 候选顺序为 `JAVA_HOME/bin` → PATH 目录（去重）；
  /// 2. 每个候选执行 `java -version`，主版本必须 >= [minJavaMajor]（`host.jar`
  ///    以 `--release 17` 构建，见 `sidecars/spider-host-jvm/build.ps1`）；
  /// 3. **JDK 优先于 JRE**：`.java` 源码入口需要 `javax.tools` 编译器，
  ///    同目录有 `javac` 的候选排在前面；
  /// 4. 结果按可执行文件路径缓存，避免每次建站都起一次 `java -version`。
  static JavaRuntimeProbe probeJavaRuntime({LogService? log}) {
    final candidates = _javaCandidates();
    if (candidates.isEmpty) {
      return const JavaRuntimeProbe(
        command: null,
        issue: '未找到 java（已查 JAVA_HOME 与 PATH）；PC Java Spider 需要 JDK 17+',
      );
    }

    final rejected = <String>[];
    final accepted = <JavaRuntimeProbe>[];
    for (final candidate in candidates) {
      final probe = _probeJavaCandidate(candidate);
      if (probe.command != null) {
        accepted.add(probe);
      } else if (probe.issue != null) {
        rejected.add(probe.issue!);
      }
    }

    if (accepted.isEmpty) {
      return JavaRuntimeProbe(
        command: null,
        issue: '未找到可用的 Java 运行时（需要 $minJavaMajor+）：'
            '${rejected.isEmpty ? candidates.join(", ") : rejected.join("; ")}',
      );
    }
    // 有 javac 的（JDK）优先，否则保持原候选顺序。
    accepted.sort((a, b) => (b.hasCompiler ? 1 : 0) - (a.hasCompiler ? 1 : 0));
    final chosen = accepted.first;
    if (rejected.isNotEmpty) {
      log?.info(
        'Java 候选：选用 ${chosen.command!.executable}；跳过 ${rejected.join("; ")}',
        scope: 'spider',
      );
    }
    return chosen;
  }

  /// `host.jar` 以 `--release 17` 构建；运行时主版本必须不低于此值。
  static const int minJavaMajor = 17;

  static final Map<String, JavaRuntimeProbe> _javaProbeCache = {};

  static List<String> _javaCandidates() {
    final names = Platform.isWindows ? ['java.exe', 'java'] : ['java'];
    final found = <String>[];
    final seen = <String>{};
    void add(String path) {
      final key = path.toLowerCase();
      if (seen.add(key)) found.add(path);
    }

    final javaHome = Platform.environment['JAVA_HOME'];
    if (javaHome != null && javaHome.trim().isNotEmpty) {
      for (final name in names) {
        add(p.join(javaHome.trim(), 'bin', name));
      }
    }
    for (final dir in platformSearchDirs()) {
      for (final name in names) {
        add(p.join(dir, name));
      }
    }
    return found.where((path) => File(path).existsSync()).toList();
  }

  /// 探测单个候选：校验版本，并记录同目录是否有 `javac`（源码入口需要）。
  static JavaRuntimeProbe _probeJavaCandidate(String executable) {
    final cached = _javaProbeCache[executable.toLowerCase()];
    if (cached != null) return cached;

    final result = _runJavaProbe(executable);
    _javaProbeCache[executable.toLowerCase()] = result;
    return result;
  }

  static JavaRuntimeProbe _runJavaProbe(String executable) {
    String output;
    try {
      // `java -version` 把版本写到 stderr（历史行为，`-version` 与 `--version` 都如此）。
      final probe = Process.runSync(executable, const ['-version']);
      output = '${probe.stdout}${probe.stderr}'.trim();
      if (probe.exitCode != 0 && output.isEmpty) {
        return JavaRuntimeProbe(command: null, issue: '$executable 执行失败（exit=${probe.exitCode}）');
      }
    } catch (error) {
      return JavaRuntimeProbe(command: null, issue: '$executable 无法执行：$error');
    }

    final major = parseJavaMajor(output);
    if (major == null) {
      return JavaRuntimeProbe(
        command: null,
        issue: '$executable 版本无法识别（${output.split("\n").first.trim()}）',
      );
    }
    if (major < minJavaMajor) {
      return JavaRuntimeProbe(
        command: null,
        issue: '$executable 为 Java $major，低于所需的 $minJavaMajor',
      );
    }

    final binDir = p.dirname(executable);
    final hasCompiler = (Platform.isWindows ? ['javac.exe', 'javac'] : ['javac'])
        .any((name) => File(p.join(binDir, name)).existsSync());
    return JavaRuntimeProbe(
      command: SidecarCommand(executable: executable, arguments: const []),
      major: major,
      hasCompiler: hasCompiler,
    );
  }

  /// 从 `java -version` 输出解析主版本号；无法解析时返回 null。
  ///
  /// 兼容三种形态：`1.8.0_501`（Java 8）、`17.0.2`、`21.0.12+7-LTS`。
  /// 公开以便单测直接验证解析逻辑（本机 Java 8 / JDK 21 共存是真实场景）。
  static int? parseJavaMajor(String output) {
    final match = RegExp(r'version\s+"([^"]+)"').firstMatch(output);
    final raw = match?.group(1) ?? output.trim().split(RegExp(r'\s+')).first;
    if (raw.isEmpty) return null;
    final parts = raw.split('.');
    if (parts.isEmpty) return null;
    final first = int.tryParse(RegExp(r'^\d+').stringMatch(parts.first) ?? '');
    if (first == null) return null;
    // `1.x` 是 Java 8 及更早的旧编号，主版本在第二段。
    if (first == 1 && parts.length > 1) {
      return int.tryParse(RegExp(r'^\d+').stringMatch(parts[1]) ?? '');
    }
    return first;
  }

  /// 查找本机 Node。返回 null 表示未安装，UI 必须提示而不是静默跳过。
  static SidecarCommand? _nodeCommand() {
    final names = Platform.isWindows ? ['node.exe', 'node'] : ['node'];
    for (final name in names) {
      for (final dir in platformSearchDirs()) {
        final candidate = p.join(dir, name);
        if (File(candidate).existsSync()) {
          return SidecarCommand(executable: candidate, arguments: const []);
        }
      }
    }
    return null;
  }

  /// 查找本机 Python。返回 null 表示未安装，UI 必须提示而不是静默跳过。
  static SidecarCommand? _pythonCommand() {
    final pathDirs = (Platform.environment['PATH'] ?? '').split(';');
    final candidates = <String>[];
    // `py.exe` 位于 Windows 系统目录之外的 Launcher 目录，但也在 PATH 中；
    // 这里同时补充 SystemRoot，覆盖 PATH 被裁剪的情况。
    final systemRoot = Platform.environment['SystemRoot'];
    if (Platform.isWindows && systemRoot != null) {
      candidates.add(p.join(systemRoot, 'py.exe'));
    }
    candidates.addAll(pathDirs.where((dir) => dir.trim().isNotEmpty).map(
      (dir) => p.join(dir.trim(), 'py.exe'),
    ));
    for (final candidate in candidates) {
      if (File(candidate).existsSync()) {
        return SidecarCommand(executable: candidate, arguments: const ['-3']);
      }
    }
    final fallbacks = Platform.isWindows
        ? ['python3.exe', 'python.exe']
        : ['python3', 'python'];
    final dirs = platformSearchDirs();
    for (final name in fallbacks) {
      for (final dir in dirs) {
        final candidate = p.join(dir, name);
        if (File(candidate).existsSync()) {
          return SidecarCommand(executable: candidate, arguments: const []);
        }
      }
    }
    return null;
  }

  static List<String> platformSearchDirs() {
    // sidecar 的 PATH 被裁剪为系统目录（§9.8），但宿主解析运行时时仍需要用户 PATH。
    final source = Platform.environment;
    final path = source['PATH'] ?? source['Path'] ?? '';
    final dirs = path
        .split(Platform.isWindows ? ';' : ':')
        .where((item) => item.trim().isNotEmpty)
        .map((item) => item.trim())
        .toList();
    return dirs;
  }

  static String get hostRelative => _hostRelative;
}

/// 定位仓库/发行包内的 Python sidecar 宿主脚本。
///
/// 查找顺序（§20.5「不依赖开发机上的 PATH、HOME 或预装 libmpv 才能启动」）：
/// 1. `WEBHTV_SIDECAR_HOST` 显式覆盖（测试与调试）；
/// 2. 与可执行文件同级的 `sidecars/`（发行包布局）；
/// 3. 从当前目录向上查找的仓库布局。
///
/// 找不到时返回空串；调用方必须显示「sidecar 宿主缺失」而不是静默跳过站点。
String defaultSidecarHostPath() {
  return _locateSidecarHost(
    const ['sidecars', 'spider-host-python', 'host.py'],
    'WEBHTV_SIDECAR_HOST',
  );
}

/// 定位仓库/发行包内的 JS（Node）sidecar 宿主脚本（§9.1 `tvbox-js-v1`）。
///
/// 与 [defaultSidecarHostPath] 同语义：`node*` 运行时需要 `spider-host-js/host.js`。
/// 发行包可能只带其中一种运行时，因此三个入口各自独立解析。
String defaultJsSidecarHostPath() {
  return _locateSidecarHost(
    const ['sidecars', 'spider-host-js', 'host.js'],
    'WEBHTV_SIDECAR_JS_HOST',
  );
}

/// 定位仓库/发行包内的 JVM（Java）sidecar 宿主（§9.3 `tvbox-java-v1`）。
///
/// 与 [defaultSidecarHostPath] 同语义：`jvm*`/`java*` 运行时需要
/// `sidecars/spider-host-jvm/host.jar`。该 jar 由
/// `sidecars/spider-host-jvm/build.ps1` 用 JDK 自带 javac/jar 产出（无第三方依赖）。
String defaultJvmSidecarHostPath() {
  return _locateSidecarHost(
    const ['sidecars', 'spider-host-jvm', 'host.jar'],
    'WEBHTV_SIDECAR_JVM_HOST',
  );
}

/// 共享的宿主脚本定位逻辑（环境变量覆盖 → 可执行文件同级 → 向上查找仓库）。
String _locateSidecarHost(List<String> relative, String envVar) {
  final override = Platform.environment[envVar];
  if (override != null && override.trim().isNotEmpty) {
    final candidate = p.normalize(override.trim());
    if (File(candidate).existsSync()) return candidate;
  }

  try {
    final executableDir = p.dirname(Platform.resolvedExecutable);
    final candidate = p.joinAll([executableDir, ...relative]);
    if (File(candidate).existsSync()) return candidate;
  } catch (_) {
    // Platform.resolvedExecutable 在极端环境下可能不可用。
  }

  var current = Directory.current;
  for (var hop = 0; hop < 6; hop++) {
    final candidate = p.joinAll([current.path, ...relative]);
    if (File(candidate).existsSync()) return candidate;
    final parent = current.parent;
    if (parent.path == current.path) break;
    current = parent;
  }
  return '';
}
