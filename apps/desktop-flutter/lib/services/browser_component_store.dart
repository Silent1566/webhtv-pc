/// 浏览器内核组件：把用户选定的便携 Chromium 装进应用数据目录，供 Web 嗅探使用。
///
/// # 为什么需要它
///
/// 解析器 `type=0/4` 依赖一个 Chromium 内核浏览器。Windows 上 Edge 天然存在，
/// 但精简 Linux、容器、未装 Chrome 的 macOS 上「用户得自己找浏览器装」是一道
/// 真实门槛——本机实测只有 snap 包装脚本时，用户看到的是 `snap-confine` 权限
/// 错误（见 `docs/phase3/evidence/linux-sniff-acceptance.txt`）。
///
/// # 边界（PRODUCT.md 硬约束）
///
/// - **不内置、不随包分发**浏览器：组件只能由用户显式选择来源（本地目录或 zip）；
/// - 不静默联网下载：来源永远是用户给的；
/// - 装进来只是「复制 + 校验 + 登记」，不修改系统、不写注册表、不申请权限；
/// - 校验用 `--version`（`probeChromiumBrowser`）与 `chromiumVersionOf`：
///   探测不过的包绝不登记，避免把坏包装写进配置后每次播放都失败。
///
/// # 目录布局
///
/// ```text
/// <dataDir>/components/browser/<label>-<version>/
///   ├── component.json      # id/label/version/executable(相对)/source/installedAt
///   └── ...                 # 原样复制的浏览器文件
/// ```
///
/// 解析优先级由 `DefaultSniffTransport` 组合：显式环境变量 → 已装组件 → 系统浏览器。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;

import '../core/sniff/browser_process.dart';
import '../core/sniff/sniff_transport.dart';
import '../core/sniff/sniff_types.dart';
import 'app_paths.dart';

/// 一个已安装的浏览器组件。
class BrowserComponent {
  const BrowserComponent({
    required this.id,
    required this.label,
    required this.version,
    required this.executablePath,
    required this.directory,
    this.source,
    this.installedAt,
  });

  final String id;
  final String label;

  /// 形如 `154.0.8037.0`；识别不到时为 `unknown`。
  final String version;

  /// 可执行文件绝对路径。
  final String executablePath;

  /// 组件根目录（卸载时整体删除）。
  final String directory;

  /// 安装来源（用户选的目录或 zip 路径，仅用于诊断）。
  final String? source;

  final DateTime? installedAt;

  String get displayName => '$label $version';

  Map<String, Object?> toJson(String relativeExecutable) => {
    'id': id,
    'label': label,
    'version': version,
    'executable': relativeExecutable,
    if (source != null) 'source': source,
    if (installedAt != null) 'installedAt': installedAt!.toIso8601String(),
  };

  /// 从 `component.json` 读回组件；缺字段视为损坏并返回 null。
  static BrowserComponent? fromManifest(
    File manifest, {
    required String directory,
  }) {
    try {
      final decoded = jsonDecode(manifest.readAsStringSync());
      if (decoded is! Map) return null;
      final relative = decoded['executable'];
      final id = decoded['id'];
      final label = decoded['label'];
      if (relative is! String || id is! String || label is! String) return null;
      final version = decoded['version'] is String
          ? decoded['version'] as String
          : 'unknown';
      final installedAt = decoded['installedAt'] is String
          ? DateTime.tryParse(decoded['installedAt'] as String)
          : null;
      return BrowserComponent(
        id: id,
        label: label,
        version: version,
        executablePath: p.join(directory, relative),
        directory: directory,
        source: decoded['source'] is String ? decoded['source'] as String : null,
        installedAt: installedAt,
      );
    } on Object {
      return null;
    }
  }
}

/// 组件库：安装、列出、校验、卸载。
///
/// 全部 IO；调用方负责放到后台 isolate（安装是复制几百 MB 的量级）。
class BrowserComponentStore {
  BrowserComponentStore({
    required this.rootDirectory,
    Future<String?> Function(String executablePath)? versionReader,
  }) : _versionReader = versionReader ?? chromiumVersionOf;

  /// 应用数据目录下的组件根目录。
  factory BrowserComponentStore.forApp(AppPaths paths) => BrowserComponentStore(
    rootDirectory: p.join(paths.dataDir, 'components', 'browser'),
  );

  final String rootDirectory;
  final Future<String?> Function(String executablePath) _versionReader;

  /// 便携包里认的可执行文件名（Windows 带后缀，POSIX 不带）。
  static const Set<String> executableNames = {
    'chrome',
    'chrome.exe',
    'chromium',
    'chromium.exe',
    'msedge',
    'msedge.exe',
  };

  /// 在包里找可执行文件的最大深度：常见布局是 `chrome-win64/chrome.exe`、
  /// `chrome-linux64/chrome`，再深就是解压出错或根本不是浏览器包。
  static const int maxSearchDepth = 3;

  /// 已安装组件（按目录名排序，保证 UI 与解析顺序稳定）。
  Future<List<BrowserComponent>> installed() async {
    final root = Directory(rootDirectory);
    if (!root.existsSync()) return const [];
    final result = <BrowserComponent>[];
    final entities = root.listSync(followLinks: false)
      ..sort((a, b) => a.path.compareTo(b.path));
    for (final entity in entities) {
      if (entity is! Directory) continue;
      final name = p.basename(entity.path);
      if (name.startsWith('.')) continue;
      final manifest = File(p.join(entity.path, 'component.json'));
      if (!manifest.existsSync()) continue;
      final component = BrowserComponent.fromManifest(
        manifest,
        directory: entity.path,
      );
      if (component != null && File(component.executablePath).existsSync()) {
        result.add(component);
      }
    }
    return result;
  }

  /// 交给嗅探传输的候选路径（存在即返回；可用性仍由 transport 探测）。
  Future<List<String>> executablePaths() async => [
    for (final component in await installed()) component.executablePath,
  ];

  /// 校验一个组件：返回 null 表示可用，否则是不可用原因。
  Future<String?> validate(BrowserComponent component) async {
    if (!File(component.executablePath).existsSync()) {
      return '可执行文件已不存在：${component.executablePath}';
    }
    return probeChromiumBrowser(
      BrowserCommand(
        executablePath: component.executablePath,
        label: component.label,
      ),
      useCache: false,
    );
  }

  /// 从目录安装（会整棵复制，安装后与原目录无关）。
  Future<BrowserComponent> installFromDirectory(
    Directory source, {
    String? label,
  }) async {
    if (!source.existsSync()) {
      throw SniffException('安装来源不存在', detail: source.path);
    }
    final executable = _findExecutable(source);
    if (executable == null) {
      throw SniffException(
        '安装包里没有找到 Chromium 内核可执行文件',
        detail: '在 ${source.path} 下 $maxSearchDepth 层内未找到 '
            'chrome / chromium / msedge（不含 .exe 的等价名）',
      );
    }

    final staging = Directory(
      p.join(rootDirectory, '.install-${DateTime.now().microsecondsSinceEpoch}'),
    );
    await Directory(rootDirectory).create(recursive: true);
    await staging.create(recursive: true);
    try {
      await _copyTree(source, staging);
      final relative = p.relative(
        p.join(staging.path, p.relative(executable.path, from: source.path)),
        from: staging.path,
      );
      final stagedExecutable = p.join(staging.path, relative);
      // zip 解出来的文件在 POSIX 上没有执行位（zip 的 mode 常丢失），复制后也不
      // 保证保留。**必须在读版本之前补**：否则 `--version` 直接 Permission denied，
      // 组件就会被命名成 "webhtv-browser-XXXX" 这种无意义的临时目录名。
      _ensureExecutable(stagedExecutable);

      final versionLine = await _versionReader(stagedExecutable);
      final resolvedLabel = _labelOf(versionLine, label ?? p.basename(source.path));
      final version = _versionOf(versionLine);
      final id = '${_slug(resolvedLabel)}-$version';
      final target = Directory(p.join(rootDirectory, id));
      final draft = BrowserComponent(
        id: id,
        label: resolvedLabel,
        version: version,
        executablePath: stagedExecutable,
        directory: staging.path,
        source: source.path,
        installedAt: DateTime.now(),
      );
      await File(p.join(staging.path, 'component.json')).writeAsString(
        const JsonEncoder.withIndent('  ').convert(draft.toJson(relative)),
        flush: true,
      );

      // 探测必须在登记前完成：装进来却跑不起来的包，宁可当场报错。
      final issue = await probeChromiumBrowser(
        BrowserCommand(executablePath: draft.executablePath, label: draft.label),
        useCache: false,
      );
      if (issue != null) {
        throw SniffException('这个包里的浏览器跑不起来', detail: issue);
      }
      if (target.existsSync()) {
        await target.delete(recursive: true);
      }
      final moved = await staging.rename(target.path);
      return BrowserComponent(
        id: id,
        label: resolvedLabel,
        version: version,
        executablePath: p.join(moved.path, relative),
        directory: moved.path,
        source: source.path,
        installedAt: draft.installedAt,
      );
    } catch (_) {
      await _deleteQuietly(staging);
      rethrow;
    }
  }

  /// 从 zip 安装（解到临时目录再走目录安装）。
  Future<BrowserComponent> installFromZip(File zip, {String? label}) async {
    if (!zip.existsSync()) {
      throw SniffException('安装包不存在', detail: zip.path);
    }
    final temp = await Directory.systemTemp.createTemp('webhtv-browser-');
    try {
      final archive = ZipDecoder().decodeBytes(await zip.readAsBytes());
      for (final entry in archive) {
        if (!entry.isFile) continue;
        final name = entry.name.replaceAll('\\', '/');
        if (name.contains('..')) continue;
        final output = File(p.join(temp.path, name));
        await output.parent.create(recursive: true);
        await output.writeAsBytes(entry.content as List<int>);
      }
      return await installFromDirectory(temp, label: label);
    } finally {
      await _deleteQuietly(temp);
    }
  }

  /// POSIX 上补执行位；Windows 无此语义。
  static void _ensureExecutable(String path) {
    if (Platform.isWindows) return;
    try {
      final stat = FileStat.statSync(path);
      if (stat.mode & 0x49 != 0) return;
      Process.runSync('chmod', ['755', path]);
    } on Object {
      // 补不上就交给下面的探测报出真实原因。
    }
  }

  /// 临时目录清理是 best-effort：失败不能盖掉真正的安装错误。
  static Future<void> _deleteQuietly(Directory directory) async {
    try {
      if (directory.existsSync()) await directory.delete(recursive: true);
    } on Object {
      // 忽略：下次安装会用新的临时目录。
    }
  }

  /// 卸载：只删组件根目录下的目录（防手滑删到别处）。
  Future<void> uninstall(BrowserComponent component) async {
    final root = p.normalize(p.absolute(rootDirectory));
    final target = p.normalize(p.absolute(component.directory));
    if (!p.isWithin(root, target)) {
      throw SniffException('拒绝卸载：目录不在组件库内', detail: component.directory);
    }
    final directory = Directory(target);
    if (directory.existsSync()) await directory.delete(recursive: true);
  }

  File? _findExecutable(Directory root) {
    final queue = <(Directory, int)>[(root, 0)];
    while (queue.isNotEmpty) {
      final (directory, depth) = queue.removeAt(0);
      final entities = directory.listSync(followLinks: false)
        ..sort((a, b) => a.path.compareTo(b.path));
      for (final entity in entities) {
        final name = p.basename(entity.path);
        if (entity is File && executableNames.contains(name.toLowerCase())) {
          if (Platform.isWindows ? name.toLowerCase().endsWith('.exe') : true) {
            return entity;
          }
        }
      }
      if (depth >= maxSearchDepth) continue;
      for (final entity in entities) {
        if (entity is Directory && !p.basename(entity.path).startsWith('.')) {
          queue.add((entity, depth + 1));
        }
      }
    }
    return null;
  }

  Future<void> _copyTree(Directory source, Directory target) async {
    await for (final entity in source.list(recursive: true, followLinks: false)) {
      final relative = p.relative(entity.path, from: source.path);
      final destination = p.join(target.path, relative);
      if (entity is Directory) {
        await Directory(destination).create(recursive: true);
      } else if (entity is File) {
        await Directory(p.dirname(destination)).create(recursive: true);
        await entity.copy(destination);
      }
    }
  }

  static String _labelOf(String? versionLine, String fallback) {
    final lower = (versionLine ?? '').toLowerCase();
    if (lower.contains('microsoft edge')) return 'Microsoft Edge';
    if (lower.contains('brave')) return 'Brave Browser';
    if (lower.contains('chromium')) return 'Chromium';
    if (lower.contains('chrome')) return 'Google Chrome';
    return fallback;
  }

  static String _versionOf(String? versionLine) {
    final match = RegExp(r'(\d+(?:\.\d+){1,3})').firstMatch(versionLine ?? '');
    return match?.group(1) ?? 'unknown';
  }

  static String _slug(String label) {
    final slug = label
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
        .replaceAll(RegExp(r'^-+|-+$'), '');
    return slug.isEmpty ? 'browser' : slug;
  }
}
