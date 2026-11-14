/// T3（csp_*）桌面 JAR 站源的**静态检测与导入**（ADR-0002、
/// docs/reference/win-box-borrowings.md §12.6）。
///
/// 约束：
/// - 只**静态读取** zip 目录项与文件树，绝不加载类、绝不执行站源代码
///   （PRODUCT.md：UI/服务层不得直接执行 Spider / 网络逻辑）；
/// - classes.dex 用 **zip 条目名精确匹配**判定，不再用裸字节子串搜索
///   （后者在普通桌面 jar 里恰好出现该字样即假阳，见 §12.6.2 缺陷①）；
/// - **目录入口**（含 .class 的目录）同样在检测范围内（旧实现直接返回 false，
///   属漏判，见 §12.6.2 缺陷②）；
/// - 判定结论只有一处来源：spider_router.dart 的可用性文案与设置页的检测结果
///   都读本文件，避免「设置页说 A、站点页说 B」（§12.6.2 缺陷③）；
/// - 解析失败与非 zip 一律给出**结构化**结论，不把异常抛给 UI。
///
/// 诚实边界（§12.6.5）：本文件只是**静态判定**。能通过 desktopReady 只说明
/// 「不含 dex、不含原生库、可被宿主按 zip 加载」，**不保证**站点可用——入口类仍须
/// 继承 webhtv.spider.Spider 或提供静态 createSpider(Map)
/// （sidecars/spider-host-jvm/.../EntryLoader.java:84-99）。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'log_service.dart';

/// 单次静态检测的结论分级。
enum JarVerdict {
  /// 桌面 JVM 可直接加载：无 *.dex、无 *.so，且含 class 条目。
  desktopReady,

  /// 源码入口（.java 或含 .java 的目录）：需宿主用 JDK 编译。
  ///
  /// 当前 csp_* 绑定只解析 index.jar 或类目录（CspJvmBinding.entryFor），
  /// 因此源码入口**不落盘**，如实提示改用 manifest（spider-local:）。
  sourceReady,

  /// 含 *.dex、且**不含**任何原生库（*.so）：可在导入期预转译为桌面 JVM 可加载的
  /// class jar（sidecar 的 `webhtv.spider.DexIntakeCli`）。
  ///
  /// 只在正常解析路径上给出——兜底字节扫描无法确认有没有 lib/*.so，见 [androidJar]。
  translatableDex,

  /// 含 *.dex、但**无法确认**是否也能转译的 Android 站源：JVM 无法加载（ADR-0002）。
  ///
  /// 当前只有一条产生路径：zip 中央目录解析失败后的字节扫描兜底——该路径只看到
  /// 「内容里出现过 classes.dex」，看不到完整条目名清单，因此无法排除 lib/*.so，
  /// 不能当作可转译入口。
  androidJar,

  /// 含 *.so：依赖 Android/ARM 原生库，桌面 JVM 无法加载。
  nativeLibrary,

  /// 无 dex / 无原生库，但没有任何 class 条目：宿主加载时以 ClassNotFound 收场。
  missingEntryClass,

  /// 无法按 zip 解析（不是 jar，或文件已损坏），或入口为空。
  malformed,

  /// 入口路径不存在。
  missingSource,
}

/// 静态检测报告（纯数据，可单测）。
class JarInspection {
  const JarInspection({
    required this.verdict,
    required this.sourcePath,
    this.entryCount = 0,
    this.dexEntries = const [],
    this.nativeEntries = const [],
    this.classEntries = const [],
    this.sourceEntries = const [],
    this.expectedClass,
    this.entryClassFound = false,
    this.note = '',
  });

  final JarVerdict verdict;
  final String sourcePath;
  final int entryCount;
  final List<String> dexEntries;
  final List<String> nativeEntries;
  final List<String> classEntries;
  final List<String> sourceEntries;

  /// 期望的入口类名（csp_Demo → Demo）。
  final String? expectedClass;

  /// 是否找到了与 [expectedClass] 同名的 class 条目（仅作**提示**，
  /// 不影响 spider_router 的可用性判定——入口类可能带包名或另有 createSpider）。
  final bool entryClassFound;

  /// 附加说明（例如「类目录入口」）。
  final String note;

  /// 是否可落盘到 `<config>/spiders/csp/<siteKey>/`。
  ///
  /// 两种情况可以通过：[JarVerdict.desktopReady]（桌面 jar 直接可加载）与
  /// [JarVerdict.translatableDex]（导入期预转译成桌面 class jar，见 [JarIntake.install]
  /// 的 translateDex）。含原生库、无类条目、损坏、不可转译的 dex 一律拒绝且不落盘
  /// （§12.6.4 ①②）。
  bool get installable =>
      verdict == JarVerdict.desktopReady ||
      verdict == JarVerdict.translatableDex;

  bool get isAndroid => verdict == JarVerdict.androidJar;

  /// 面向用户的一句话结论（与 spider_router.dart 的措辞保持一致）。
  String get summary {
    switch (verdict) {
      case JarVerdict.desktopReady:
        final missing = entryClassFound
            ? ''
            : '（未找到与「${expectedClass ?? '?'}」同名的 class，宿主加载时可能报 ClassNotFound）';
        return '可导入的桌面入口：$entryCount 个条目，无 classes.dex、无原生库。$missing';
      case JarVerdict.sourceReady:
        return '这是源码入口（${sourceEntries.length} 个 .java）：需要 JDK 编译，'
            '当前 csp_ 绑定只解析 index.jar / 类目录，请改用 manifest（spider-local:）。';
      case JarVerdict.translatableDex:
        return '这是 Android 站源入口（内含 classes.dex，共 ${dexEntries.length} 个 dex 条目）：'
            '无原生库，可在导入时转译为桌面可加载的 class jar。';
      case JarVerdict.androidJar:
        return '该入口看起来含 classes.dex（${dexEntries.take(3).join('、')}），'
            '但 zip 结构已损坏、无法确认是否还含原生库（lib/*.so），'
            '因此不做自动转译；JVM 无法加载（ADR-0002）。';
      case JarVerdict.nativeLibrary:
        return '该入口含原生库（${nativeEntries.take(3).join('、')}），'
            '依赖 Android/ARM 原生实现，桌面 JVM 无法加载（Win-box 用 unidbg 属另一条路线）。';
      case JarVerdict.missingEntryClass:
        return '可解析但没有任何 .class 条目（宿主会以 ClassNotFound 收场）：'
            '入口必须继承 webhtv.spider.Spider 或提供静态 createSpider(Map)。';
      case JarVerdict.malformed:
        return '无法按 zip 解析（可能不是 jar，或文件已损坏）。';
      case JarVerdict.missingSource:
        return '入口路径不存在：$sourcePath';
    }
  }
}

/// 导入结果。
class JarInstallResult {
  const JarInstallResult({
    required this.ok,
    required this.siteKey,
    this.targetPath,
    this.error,
    this.inspection,
    this.dexTranslation,
  });

  /// 是否**落盘成功**。与转译成败**无关**：转译结果单独看 [dexTranslation]，
  /// 文案由上层（spider_router）决定。落盘成功而转译失败时本字段仍为 true。
  final bool ok;
  final String siteKey;
  final String? targetPath;
  final String? error;
  final JarInspection? inspection;

  /// 导入期预转译（DexIntakeCli）的一行 JSON 结果，原样来自 CLI：
  /// 成功 `{'ok': true, 'bundle': …, 'classCount': …, 'cached': …, 'sourceSha256': …, 'archive': …}`，
  /// 失败 `{'ok': false, 'stage': …, 'message': …}`。
  ///
  /// 为 null 表示**没有转译**（调用方未注入 translateDex，或入口本来不是 dex）。
  /// 分工：本文件只负责记录，可用性/文案由上层按 `dexTranslation['ok']` 决定。
  final Map<String, Object?>? dexTranslation;
}

/// 已安装到缓存目录的一个 csp_* 条目（含当前磁盘内容的静态结论）。
class InstalledJar {
  const InstalledJar({
    required this.siteKey,
    required this.directory,
    required this.entryPath,
    required this.inspection,
  });

  final String siteKey;
  final String directory;
  final String entryPath;
  final JarInspection inspection;
}

/// T3 桌面 jar 的静态检测与导入。
class JarIntake {
  const JarIntake._();

  /// 检测时最多读取的条目数（防御超大 jar）。
  static const int maxEntries = 50000;

  /// csp_* → 类名（对齐 EntryLoader.resolveClassName：去 csp_ 前缀）。
  static String classNameFor(String siteKey) {
    final trimmed = siteKey.trim();
    if (trimmed.toLowerCase().startsWith('csp_')) return trimmed.substring(4);
    return trimmed;
  }

  /// 入口是否为**不可转译**的 Android jar（即判为 [JarVerdict.androidJar]）。
  ///
  /// 供 `CspJvmBinding.isAndroidJar`（services/spider_registry.dart）委托调用，
  /// 保证站点列表文案与设置页检测结论来自**同一处判定**（§12.6.2 缺陷③）。
  ///
  /// 边界：含 dex 且无原生库的入口现在是 [JarVerdict.translatableDex]（可转译），
  /// **不再**算「Android 站源」；只有兜底字节扫描出来的结论才算。
  static bool hasAndroidDex(String path) =>
      inspectPath(path).verdict == JarVerdict.androidJar;

  /// 静态检测一个入口（jar 文件 / 目录 / .java 文件）。
  ///
  /// 不加载类、不解压条目内容、不执行任何代码；不抛异常。
  static JarInspection inspectPath(String sourcePath, {String? expectedClass}) {
    final type = FileSystemEntity.typeSync(sourcePath);
    if (type == FileSystemEntityType.notFound) {
      return JarInspection(
        verdict: JarVerdict.missingSource,
        sourcePath: sourcePath,
      );
    }
    if (type == FileSystemEntityType.directory) {
      return _inspectDirectory(
        Directory(sourcePath),
        expectedClass: expectedClass,
      );
    }
    return _inspectFile(File(sourcePath), expectedClass: expectedClass);
  }

  // ---------------------------------------------------------------------------
  // 检测
  // ---------------------------------------------------------------------------

  static JarInspection _inspectFile(File file, {String? expectedClass}) {
    final path = file.path;

    if (path.toLowerCase().endsWith('.java')) {
      return JarInspection(
        verdict: JarVerdict.sourceReady,
        sourcePath: path,
        entryCount: 1,
        sourceEntries: [p.basename(path)],
        expectedClass: expectedClass,
        note: '单文件源码入口',
      );
    }

    final names = _readZipEntryNames(path);
    if (names == null) {
      // 兜底：只有**确实是 zip**（魔数 50 4B 03 04）却解析失败时才做字节扫描，
      // 避免「文件里恰好出现 classes.dex 字样」被误判（§12.6.4 ⑦）。
      //
      // 这条分支只能看到字节流，看不到条目名清单，因此**无法确认**有没有原生库
      // （lib/*.so）：不能当作可转译入口，仍判 androidJar（拒绝落盘）。
      if (_hasZipMagic(file) && _containsAscii(file, 'classes.dex')) {
        return JarInspection(
          verdict: JarVerdict.androidJar,
          sourcePath: path,
          dexEntries: const ['classes.dex'],
          expectedClass: expectedClass,
          note: 'zip 解析失败，按字节扫描兜底判定',
        );
      }
      return JarInspection(
        verdict: JarVerdict.malformed,
        sourcePath: path,
        expectedClass: expectedClass,
      );
    }
    return _classifyNames(path, names, expectedClass: expectedClass);
  }

  static JarInspection _inspectDirectory(
    Directory directory, {
    String? expectedClass,
  }) {
    final names = <String>[];
    try {
      for (final entity
          in directory.listSync(recursive: true, followLinks: false)) {
        if (entity is! File) continue;
        names.add(p.relative(entity.path, from: directory.path));
        if (names.length >= maxEntries) break;
      }
    } catch (_) {
      return JarInspection(
        verdict: JarVerdict.malformed,
        sourcePath: directory.path,
        expectedClass: expectedClass,
      );
    }
    if (names.isEmpty) {
      return JarInspection(
        verdict: JarVerdict.malformed,
        sourcePath: directory.path,
        expectedClass: expectedClass,
        note: '目录为空',
      );
    }
    return _classifyNames(
      directory.path,
      names,
      expectedClass: expectedClass,
      isDirectory: true,
    );
  }

  static JarInspection _classifyNames(
    String sourcePath,
    List<String> names, {
    String? expectedClass,
    bool isDirectory = false,
  }) {
    final dex = <String>[];
    final native = <String>[];
    final classes = <String>[];
    final sources = <String>[];
    for (final name in names) {
      final lower = name.toLowerCase();
      // 目录项判定只看**条目名**：不解压、不读内容。
      if (lower.endsWith('/') || lower.endsWith('\\')) continue;
      final base = p.basename(lower);
      if (base.endsWith('.dex')) {
        dex.add(name);
      } else if (base.endsWith('.so')) {
        native.add(name);
      } else if (base.endsWith('.class')) {
        classes.add(name);
      } else if (base.endsWith('.java')) {
        sources.add(name);
      }
    }

    final expected = expectedClass?.trim();
    final found =
        expected != null &&
        expected.isNotEmpty &&
        classes.any((c) => p.basename(c) == '$expected.class');

    // 判定顺序：**原生库的拒绝优先于 dex**。项目纪律要求含 lib/*.so 的 jar 一律
    // 拒绝落盘——dex 预转译只解决「JVM 不认 dalvik 字节码」，不解决原生实现只能
    // 在 Android/ARM 上跑的依赖（§12.6.4 ①、ADR-0002）。若先判 dex，「dex + 原生库」
    // 会被错报成可转译的 dex 入口，转译成功后依然加载不出原生实现。
    if (native.isNotEmpty) {
      return JarInspection(
        verdict: JarVerdict.nativeLibrary,
        sourcePath: sourcePath,
        entryCount: names.length,
        dexEntries: dex,
        nativeEntries: native,
        classEntries: classes,
        sourceEntries: sources,
        expectedClass: expectedClass,
        entryClassFound: found,
      );
    }
    if (dex.isNotEmpty) {
      // 走到这里说明已确认**没有任何原生库**，dex 可以在导入期转译。
      return JarInspection(
        verdict: JarVerdict.translatableDex,
        sourcePath: sourcePath,
        entryCount: names.length,
        dexEntries: dex,
        nativeEntries: native,
        classEntries: classes,
        sourceEntries: sources,
        expectedClass: expectedClass,
        entryClassFound: found,
      );
    }
    if (classes.isEmpty) {
      if (sources.isNotEmpty) {
        return JarInspection(
          verdict: JarVerdict.sourceReady,
          sourcePath: sourcePath,
          entryCount: names.length,
          sourceEntries: sources,
          expectedClass: expectedClass,
          note: isDirectory ? '源码目录' : '源码入口',
        );
      }
      return JarInspection(
        verdict: JarVerdict.missingEntryClass,
        sourcePath: sourcePath,
        entryCount: names.length,
        expectedClass: expectedClass,
      );
    }
    return JarInspection(
      verdict: JarVerdict.desktopReady,
      sourcePath: sourcePath,
      entryCount: names.length,
      classEntries: classes,
      sourceEntries: sources,
      expectedClass: expectedClass,
      entryClassFound: found,
      note: isDirectory ? '类目录入口' : 'jar 入口',
    );
  }

  /// 读取 zip 中央目录里的**条目名**。返回 null 表示无法按 zip 解析。
  static List<String>? _readZipEntryNames(String path) {
    InputFileStream? stream;
    try {
      stream = InputFileStream(path);
      final archive = ZipDecoder().decodeStream(stream);
      if (archive.files.isEmpty) return null;
      final names = <String>[];
      for (final file in archive.files) {
        names.add(file.name);
        if (names.length >= maxEntries) break;
      }
      return names;
    } catch (_) {
      return null;
    } finally {
      // Windows 上必须释放句柄，否则紧接着的移动/删除会失败。
      try {
        stream?.closeSync();
      } catch (_) {}
    }
  }

  static bool _hasZipMagic(File file) {
    try {
      final handle = file.openSync();
      try {
        final head = handle.readSync(4);
        return head.length == 4 &&
            head[0] == 0x50 &&
            head[1] == 0x4b &&
            head[2] == 0x03 &&
            head[3] == 0x04;
      } finally {
        handle.closeSync();
      }
    } catch (_) {
      return false;
    }
  }

  static bool _containsAscii(File file, String needle) {
    final target = needle.codeUnits;
    try {
      final bytes = file.readAsBytesSync();
      outer:
      for (var i = 0; i + target.length <= bytes.length; i++) {
        for (var j = 0; j < target.length; j++) {
          if (bytes[i + j] != target[j]) continue outer;
        }
        return true;
      }
    } catch (_) {}
    return false;
  }

  // ---------------------------------------------------------------------------
  // 导入 / 移除（落盘与回滚）
  // ---------------------------------------------------------------------------

  /// 已安装的 csp_* 站点 key（按目录名，已排序）。
  static List<String> installedSiteKeys(String cspRoot) {
    final installed = describeInstalled(cspRoot);
    return [for (final entry in installed) entry.siteKey];
  }

  /// 已安装的 csp_* 条目（含静态检测结论，供设置页回显）。
  ///
  /// 只读磁盘、不落盘；目录为空或不可读时返回空列表而不抛异常。
  static List<InstalledJar> describeInstalled(String cspRoot) {
    final dir = Directory(cspRoot);
    if (!dir.existsSync()) return const [];
    try {
      final installed = <InstalledJar>[];
      for (final entity in dir.listSync(followLinks: false)) {
        if (entity is! Directory) continue;
        final siteKey = p.basename(entity.path);
        final entry = _entryIn(entity);
        if (entry == null) continue;
        installed.add(
          InstalledJar(
            siteKey: siteKey,
            directory: entity.path,
            entryPath: entry,
            inspection: inspectPath(
              entry,
              expectedClass: classNameFor(siteKey),
            ),
          ),
        );
      }
      installed.sort((a, b) => a.siteKey.compareTo(b.siteKey));
      return installed;
    } catch (_) {
      return const [];
    }
  }

  /// 缓存目录内的入口：优先 `index.jar`，其次唯一的一个 jar，最后类目录。
  ///
  /// 顺序与 `CspJvmBinding.entryFor` 保持一致（两处必须给出同一个入口，
  /// 否则设置页检测的与站点页加载的不是同一个文件）。
  static String? _entryIn(Directory directory) {
    final index = File(p.join(directory.path, 'index.jar'));
    if (index.existsSync()) return index.path;
    final jars = directory
        .listSync(followLinks: false)
        .whereType<File>()
        .where((file) => file.path.toLowerCase().endsWith('.jar'))
        .toList()
      ..sort((a, b) => a.path.compareTo(b.path));
    if (jars.isNotEmpty) return jars.first.path;
    for (final entity in directory.listSync(followLinks: false)) {
      if (entity is Directory && _containsClass(entity)) return entity.path;
    }
    return null;
  }

  static bool _containsClass(Directory directory) {
    try {
      for (final entity
          in directory.listSync(recursive: true, followLinks: false)) {
        if (entity is File && entity.path.toLowerCase().endsWith('.class')) {
          return true;
        }
      }
    } catch (_) {}
    return false;
  }

  /// 静态检测 + 落盘到 [targetDir]。
  ///
  /// 纪律：
  /// - 检测不通过（原生库 / 损坏 / 不可转译的 dex 等）**一律不落盘**，也不覆盖既有文件；
  /// - 落盘采用「暂存名 → 原子 rename」，与 backup_service.dart 同一范式；
  /// - 写入 intake.json 记录来源 / SHA-256 / 时间，供回滚与诊断（§12.6.2）。
  ///
  /// [translateDex]：导入期的预转译钩子（由调用方注入，通常是 sidecar 的
  /// `webhtv.spider.DexIntakeCli`），用依赖注入而非直接 import，避免引入 import 环。
  /// 只有 [JarVerdict.translatableDex] 且钩子非 null 时才调用；失败**不影响** `ok`
  /// （`ok` 表示落盘成功），结果放进 [JarInstallResult.dexTranslation] 与 intake.json
  /// 的 `dexTranslation` 字段。省略时完全跳过转译（既有调用方行为不变）。
  static Future<JarInstallResult> install({
    required String sourcePath,
    required String targetDir,
    required String siteKey,
    String? className,
    LogService? log,
    Future<Map<String, Object?>> Function({
      required String siteDir,
      required String archive,
    })? translateDex,
  }) async {
    final expected = className?.trim().isNotEmpty == true
        ? className!.trim()
        : classNameFor(siteKey);
    final inspection = inspectPath(sourcePath, expectedClass: expected);
    if (!inspection.installable) {
      log?.warning(
        '拒绝导入 T3 桌面站源 site=$siteKey verdict=${inspection.verdict.name} '
        'source=$sourcePath',
        scope: 'spider',
      );
      return JarInstallResult(
        ok: false,
        siteKey: siteKey,
        error: inspection.summary,
        inspection: inspection,
      );
    }

    try {
      final source = File(sourcePath);
      final targetRoot = Directory(targetDir);
      await targetRoot.create(recursive: true);

      final isJar = sourcePath.toLowerCase().endsWith('.jar');
      final entryName = isJar ? 'index.jar' : 'classes';
      final stagedPath = p.join(
        targetDir,
        isJar ? 'index.jar.staging' : 'classes.staging',
      );

      // 先写暂存名，再原子替换，避免中途失败留下半个入口。
      if (isJar) {
        await source.copy(stagedPath);
      } else {
        await _copyTree(
          Directory(sourcePath),
          await Directory(stagedPath).create(recursive: true),
        );
      }

      final legacyJar = File(p.join(targetDir, 'index.jar'));
      if (await legacyJar.exists()) await legacyJar.delete();
      final legacyDir = Directory(p.join(targetDir, 'classes'));
      if (await legacyDir.exists()) await legacyDir.delete(recursive: true);

      if (isJar) {
        await File(stagedPath).rename(p.join(targetDir, 'index.jar'));
      } else {
        await Directory(stagedPath).rename(p.join(targetDir, 'classes'));
      }

      final digest = isJar
          ? await _fileSha256(source)
          : await _directorySha256(Directory(sourcePath));

      // 落盘成功后才转译：转译读的就是刚就位的入口，且失败不回滚落盘结果。
      Map<String, Object?>? dexTranslation;
      if (inspection.verdict == JarVerdict.translatableDex &&
          translateDex != null) {
        dexTranslation = await _translateDex(
          translate: translateDex,
          siteKey: siteKey,
          // 目录入口没有 jar，按入口路径传入，由 CLI 自行判定并如实报失败。
          archive: p.join(targetDir, entryName),
          siteDir: targetDir,
          log: log,
        );
      }

      await File(p.join(targetDir, 'intake.json')).writeAsString(
        const JsonEncoder.withIndent('  ').convert({
          'siteKey': siteKey,
          'className': expected,
          'entry': entryName,
          'sourcePath': p.normalize(sourcePath),
          'sourceSha256': digest,
          'installedAt': DateTime.now().toIso8601String(),
          'verdict': inspection.verdict.name,
          'entryCount': inspection.entryCount,
          'note': inspection.note,
          'dexTranslation': ?dexTranslation,
        }),
        flush: true,
      );

      // `manifest.json` 是**启动 sidecar 的必需输入**（`Host.java` 在文件缺失时直接
      // 以退出码 2 结束，宿主侧只会看到「sidecar 意外退出（code=2）」）。此前这里
      // 只写 intake.json，`spider_router.cspLocalSpider` 却按约定指向
      // `<站点目录>/manifest.json`，两者对不上，dex 站点于是每次启动都崩在 2。
      await _writeLaunchManifest(
        targetDir: targetDir,
        siteKey: siteKey,
        entryName: entryName,
      );

      log?.info(
        'T3 桌面站源已导入 site=$siteKey entry=$entryName '
        'entries=${inspection.entryCount} sha256=${digest.substring(0, 12)}',
        scope: 'spider',
      );
      return JarInstallResult(
        ok: true,
        siteKey: siteKey,
        targetPath: targetDir,
        inspection: inspection,
        dexTranslation: dexTranslation,
      );
    } catch (error) {
      log?.error('导入 T3 桌面站源失败 site=$siteKey：$error', scope: 'spider');
      return JarInstallResult(
        ok: false,
        siteKey: siteKey,
        error: '写入失败：$error',
        inspection: inspection,
      );
    }
  }

  /// 调用注入的预转译钩子，**绝不抛出**：异常兜底成 `ok:false` 结论。
  ///
  /// 日志只写 siteKey / cached / classCount / stage / message，不写站点凭据。
  static Future<Map<String, Object?>> _translateDex({
    required Future<Map<String, Object?>> Function({
      required String siteDir,
      required String archive,
    }) translate,
    required String siteKey,
    required String siteDir,
    required String archive,
    LogService? log,
  }) async {
    try {
      final result = await translate(siteDir: siteDir, archive: archive);
      if (result['ok'] == true) {
        log?.info(
          '导入期预转译完成 site=$siteKey cached=${result['cached']} '
          'classCount=${result['classCount']}',
          scope: 'spider',
        );
      } else {
        log?.warning(
          '导入期预转译失败 site=$siteKey stage=${result['stage']} '
          'message=${result['message']}',
          scope: 'spider',
        );
      }
      return result;
    } on Exception catch (error) {
      log?.warning('导入期预转译异常 site=$siteKey：$error', scope: 'spider');
      return {'ok': false, 'stage': '', 'message': '$error'};
    }
  }

  /// 同步确保 `<targetDir>/manifest.json` 存在（自愈旧导入）。
  ///
  /// 为什么需要自愈：`manifest.json` 的写入是 P1-2 后期才补上的，此前导入的站点
  /// 目录里只有 `index.jar` + `intake.json`，而 `Host.java` 对缺失的 manifest 直接
  /// 退出码 2。不补写的话，用户必须删掉站点目录重新导入才能恢复——那等于把内部
  /// 实现变更的成本转嫁给用户。
  ///
  /// 只在文件缺失时写一次，已有内容不覆盖（避免每次判定都产生磁盘写入）。
  static void ensureLaunchManifest({
    required String targetDir,
    required String siteKey,
  }) {
    final manifest = File(p.join(targetDir, 'manifest.json'));
    if (manifest.existsSync()) return;
    final entry = File(p.join(targetDir, 'index.jar')).existsSync()
        ? 'index.jar'
        : (Directory(p.join(targetDir, 'classes')).existsSync()
              ? 'classes'
              : null);
    if (entry == null) return;
    try {
      manifest.writeAsStringSync(
        const JsonEncoder.withIndent('  ').convert({
          'abi': 'webhtv-ipc-v1',
          'abiMinor': 0,
          'key': siteKey,
          'name': siteKey,
          'runtime': 'jvm',
          'entry': entry,
          'capabilities': const [
            'home',
            'category',
            'detail',
            'search',
            'play',
          ],
          'permissions': const {
            'network': true,
            'localProxy': false,
            'ui': false,
            'storage': 'cache-only',
            'process': false,
            'clipboard': false,
            'browser': false,
          },
          'limits': const {
            'memoryMiB': 256,
            'cpuSeconds': 30,
            'concurrency': 1,
            'responseMiB': 8,
          },
          'hashes': const {'entrySha256': ''},
          'signature': null,
        }),
        flush: true,
      );
    } catch (_) {
      // 写失败不阻断判定：让后续启动照旧报出可诊断的错误，而不是在这里静默改状态。
    }
  }

  /// 写启动 sidecar 用的 `manifest.json`（`webhtv-ipc-v1` 分发契约）。
  ///
  /// 字段对齐 `SpiderManifest.fromJson` 与 `SpiderManifest.problems` 的校验要求：
  /// `abi` 必须是 `webhtv-ipc-v1`、`key` 非空、`entry` 指向站点目录内的入口（必须是
  /// **相对路径**，`SpiderManifestRegistry._load` 会按 manifest 所在目录解析并校验
  /// 是否越界）。能力集按 dex 站源的实际可得范围声明；真实能力仍由 sidecar 在
  /// 握手时用反射自报，这里不夸大。
  static Future<void> _writeLaunchManifest({
    required String targetDir,
    required String siteKey,
    required String entryName,
  }) async {
    await File(p.join(targetDir, 'manifest.json')).writeAsString(
      const JsonEncoder.withIndent('  ').convert({
        'abi': 'webhtv-ipc-v1',
        'abiMinor': 0,
        'key': siteKey,
        'name': siteKey,
        'runtime': 'jvm',
        'entry': entryName,
        'capabilities': const [
          'home',
          'category',
          'detail',
          'search',
          'play',
        ],
        'permissions': const {
          'network': true,
          'localProxy': false,
          'ui': false,
          'storage': 'cache-only',
          'process': false,
          'clipboard': false,
          'browser': false,
        },
        'limits': const {
          'memoryMiB': 256,
          'cpuSeconds': 30,
          'concurrency': 1,
          'responseMiB': 8,
        },
        'hashes': const {'entrySha256': ''},
        'signature': null,
      }),
      flush: true,
    );
  }

  /// 移除已导入的站源（回滚）。不存在时返回 false。
  static Future<bool> remove({
    required String targetDir,
    LogService? log,
  }) async {
    final directory = Directory(targetDir);
    if (!directory.existsSync()) return false;
    try {
      await directory.delete(recursive: true);
      log?.info('T3 桌面站源已移除 $targetDir', scope: 'spider');
      return true;
    } catch (error) {
      log?.error('移除 T3 桌面站源失败 $targetDir：$error', scope: 'spider');
      return false;
    }
  }

  /// 读取自动探测结论 probe.json（不存在或损坏时返回 null）。
  ///
  /// 与 intake.json 分工：intake.json 记录**已导入**的入口；probe.json 记录
  /// 「配置声明的 jar 被静态检测后是什么、为什么没导入」（方案 3，见
  /// `docs/reference/win-box-borrowings.md` §12.9）。后者只描述结论，不落任何
  /// 可执行内容——含 dex 的 Android jar 依然拒绝落盘（§12.6.4）。
  static Map<String, Object?>? probeRecord(String targetDir) {
    final file = File(p.join(targetDir, 'probe.json'));
    if (!file.existsSync()) return null;
    try {
      final decoded = jsonDecode(file.readAsStringSync());
      return decoded is Map<String, Object?> ? decoded : null;
    } catch (_) {
      // 结论文件损坏时按「未探测」处理，下次启动重试。
      return null;
    }
  }

  /// 写入自动探测结论（建目录 + flush 落盘）。
  static Future<void> writeProbe(
    String targetDir,
    Map<String, Object?> record,
  ) async {
    final directory = Directory(targetDir);
    await directory.create(recursive: true);
    await File(p.join(directory.path, 'probe.json')).writeAsString(
      const JsonEncoder.withIndent('  ').convert(record),
      flush: true,
    );
  }

  /// 读取 intake.json（不存在或损坏时返回 null）。
  static Map<String, Object?>? intakeRecord(String targetDir) {
    final file = File(p.join(targetDir, 'intake.json'));
    if (!file.existsSync()) return null;
    try {
      final decoded = jsonDecode(file.readAsStringSync());
      return decoded is Map<String, Object?> ? decoded : null;
    } catch (_) {
      return null;
    }
  }

  static Future<void> _copyTree(Directory from, Directory to) async {
    await for (final entity in from.list(recursive: true, followLinks: false)) {
      final relative = p.relative(entity.path, from: from.path);
      final destination = p.join(to.path, relative);
      if (entity is Directory) {
        await Directory(destination).create(recursive: true);
      } else if (entity is File) {
        await Directory(p.dirname(destination)).create(recursive: true);
        await entity.copy(destination);
      }
    }
  }

  static Future<String> _fileSha256(File file) async {
    final digest = await sha256.bind(file.openRead()).first;
    return digest.toString();
  }

  /// 目录内容哈希：按相对路径排序后累积「相对路径 + 内容」（不依赖 mtime，可复现）。
  static Future<String> _directorySha256(Directory directory) async {
    final files = <File>[];
    await for (final entity
        in directory.list(recursive: true, followLinks: false)) {
      if (entity is File) files.add(entity);
    }
    files.sort((a, b) => a.path.compareTo(b.path));
    final buffer = BytesBuilder(copy: false);
    for (final file in files) {
      buffer.add(utf8.encode(p.relative(file.path, from: directory.path)));
      buffer.add(await file.readAsBytes());
    }
    return sha256.convert(buffer.takeBytes()).toString();
  }
}
