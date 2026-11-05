/// `csp_*` 站点「配置里声明的 jar」自动探测（方案 3）。
///
/// 背景（`docs/reference/win-box-borrowings.md` §12.9）：AT 这类配置把
/// `jar`/`spider` 写成远端地址（例 `http://192.168.50.50:4567/spring.jar`），
/// 而 PC 端的 `csp_*` 只认本机缓存。此前用户看到的是
/// 「请把无 Android Context 的 jar 放到 `C:\...\spiders\csp\<key>`」——
/// 让他自己去「迁移」，而这本可以是程序的事。
///
/// 本类只做三件安全的事：
/// 1. 按配置里已存在的 URL 取回 jar（用户配置本身就指向它，没有新增信任）；
/// 2. 用 [JarIntake] 做**纯静态**检测（只读 zip 目录项，绝不加载类）；
/// 3. 检测通过的入口才落盘（复用 [JarIntake.install] 的原子导入）：桌面入口直接装；
///    「可转译 dex」（含 `classes.dex`、**无**原生库）落盘并注入 [DexTranslate]
///    做导入期预转译；含原生库 / 不可转译 dex / 损坏的入口**仍然不落盘**，
///    只把结论写进 `probe.json`。
///
/// 因此「自动迁移」的真实边界是：能加载（或能转译成能加载）的自动装好；不能的
/// 自动说清原因，而不是让用户对着一句「缺少 jar」反复试。
library;

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import '../core/protocol.dart';
import 'dex_translate.dart';
import 'direct_spider_registrar.dart';
import 'jar_intake.dart';
import 'log_service.dart';
import 'spider_registry.dart';

/// 单个站点的自动探测结果。
enum CspProbeOutcome {
  /// 本地已导入，未触发下载。
  skippedInstalled,

  /// 取回并静态检测通过，已自动导入。
  installed,

  /// 取回但静态检测不通过（含**原生库** / 不可转译的 dex / 损坏），**未落盘**。
  rejected,

  /// 取回失败（网络 / 非 2xx / 超限）。
  failed,

  /// 配置没有声明 jar，或声明的是非 http(s) 地址。
  noSource,
}

/// 一个站点的探测明细。
class CspProbeEntry {
  const CspProbeEntry({
    required this.siteKey,
    required this.outcome,
    this.jarUrl,
    this.inspection,
    this.message = '',
  });

  final String siteKey;
  final CspProbeOutcome outcome;
  final String? jarUrl;
  final JarInspection? inspection;
  final String message;
}

/// 一轮探测的汇总。
class CspProbeReport {
  const CspProbeReport({this.entries = const []});

  final List<CspProbeEntry> entries;

  int get installed =>
      entries.where((e) => e.outcome == CspProbeOutcome.installed).length;

  int get rejected =>
      entries.where((e) => e.outcome == CspProbeOutcome.rejected).length;

  int get failed =>
      entries.where((e) => e.outcome == CspProbeOutcome.failed).length;

  bool get isEmpty => entries.isEmpty;
}

/// 从 `jar` / `spider` 字段解析出可下载地址。
///
/// TVBox 生态会在地址后追加 `;md5;<hash>`（校验用），部分配置还会有多个 `;`
/// 段（`;md5;hash;...`）。这里只取第一段作为 URL，其余忽略——不比上游更严格，
/// 也不额外信任：URL 本身来自用户配置。
class JarSourceSpec {
  const JarSourceSpec({required this.url, this.md5});

  final String url;

  /// 配置声明的 md5（小写十六进制）；缺省为 null（不校验）。
  final String? md5;

  static JarSourceSpec? parse(String? raw) {
    final text = (raw ?? '').trim();
    if (text.isEmpty) return null;
    final parts = text.split(';');
    final url = parts.first.trim();
    if (url.isEmpty) return null;
    final uri = Uri.tryParse(url);
    if (uri == null) return null;
    final scheme = uri.scheme.toLowerCase();
    if (scheme != 'http' && scheme != 'https') return null;
    String? md5;
    for (var i = 1; i + 1 < parts.length; i++) {
      if (parts[i].trim().toLowerCase() == 'md5') {
        final value = parts[i + 1].trim().toLowerCase();
        if (RegExp(r'^[0-9a-f]{32}$').hasMatch(value)) md5 = value;
        break;
      }
    }
    return JarSourceSpec(url: url, md5: md5);
  }
}

/// 自动探测并（在允许时）自动导入 `csp_*` 站点的配置声明 jar。
class CspJarProbe {
  CspJarProbe({
    required this.root,
    required this.binding,
    this.log,
    http.Client? client,
    this.maxBytes = 8 * 1024 * 1024,
    this.timeout = const Duration(seconds: 30),
    this.retryAfter = const Duration(minutes: 10),
    this.dexTranslate,
  }) : _client = client ?? http.Client();

  /// Spider 根目录（`<configDir>/spiders`）；下载缓存放 `<root>/probe-cache/`。
  final String root;

  /// `csp_*` 站点缓存绑定（`<root>/csp`）。
  final CspJvmBinding binding;

  final LogService? log;

  /// 单个 jar 的上限；真实配置里的 spring.jar 约 450 KiB。
  final int maxBytes;

  final Duration timeout;

  /// 取回失败后的冷却：期间不重复下载（避免每次装配都打一遍死链）。
  final Duration retryAfter;

  /// 导入期预转译钩子（签名与 `JarIntake.install` 的 `translateDex` 一致）。
  ///
  /// 缺省用真实的 [DexTranslate.run]（起一次 `java -cp host.jar;lib/* … DexIntakeCli`）；
  /// 单测注入假实现，避免测试里真的起 JVM。
  final Future<Map<String, Object?>> Function({
    required String siteDir,
    required String archive,
  })?
  dexTranslate;

  final http.Client _client;

  /// 单轮探测的下载缓存（URL → 字节或 null=失败）。
  final Map<String, List<int>?> _downloadCache = {};

  /// 探测结论的语义版本。**静态判定的口径一变就必须加一**。
  ///
  /// 为什么需要它：`probe.json` 里存的是「按当时的判定口径得出的结论」，而
  /// [_shouldSkip] 会把任何静态结论当作永久有效、不再重新下载。一旦判定口径
  /// 改变（P1-2 把「含 classes.dex」从 `androidJar` 拆出 `translatableDex`），
  /// 旧结论就是按已废弃的判据得出的，继续照用会把本该可用的站点永久卡在
  /// 「不可用」——用户只能手动删 probe.json 才能恢复。
  ///
  /// 这与 [checksumMismatch][_shouldSkip] 是同一个教训：判据变了，结论就失效。
  /// 用一个版本号统一处理，比每次新增一个「某 verdict 已失效」的特判更可靠。
  static const int probeSemanticsVersion = 2;

  /// 扫描配置里所有 `csp_*` 站点并逐个探测（幂等；不抛异常）。
  ///
  /// 同一轮内按 URL 去重下载：AT 这类配置有 90+ 个站点共用同一个 `spring.jar`，
  /// 若逐站点独立取回会产生上百次请求，也会放大上游压力。
  Future<CspProbeReport> materialize(AppConfig config) async {
    final entries = <CspProbeEntry>[];
    _downloadCache.clear();
    for (final site in config.sites) {
      if (!CspJvmBinding.matches(site.api)) continue;
      // 已有自己运行时的站点（direct js/py、CatVod 壳）不参与 JVM 探测：
      // 它们的 api 只是壳名，**没有**声明 jar 的语义；若配置顶层有全局
      // `spider`，`effectiveJar` 会把那份 jar 也算到它们头上（AT 的顶层
      // spider 就是 spring.jar），探测结果对它们毫无意义，纯属白下白写。
      if (directSpiderKind(site) != null) continue;
      try {
        final entry = await _probeSite(site, config.spider);
        if (entry != null) entries.add(entry);
      } catch (error) {
        // 单个站点失败不得影响其它站点与启动。
        log?.warning('CSP jar 自动探测失败 site=${site.key} $error', scope: 'spider');
      }
    }
    if (entries.isNotEmpty) {
      log?.info(
        'CSP jar 自动探测：已装 ${entries.where((e) => e.outcome == CspProbeOutcome.installed).length} 个、'
        '拒绝 ${entries.where((e) => e.outcome == CspProbeOutcome.rejected).length} 个、'
        '失败 ${entries.where((e) => e.outcome == CspProbeOutcome.failed).length} 个',
        scope: 'spider',
      );
    }
    return CspProbeReport(entries: entries);
  }

  Future<CspProbeEntry?> _probeSite(Site site, String? globalSpider) async {
    final siteKey = site.key;
    final targetDir = binding.directoryFor(siteKey);

    // 已导入（含用户手工导入）的站点不参与：不去覆盖用户的选择。
    if (binding.entryFor(siteKey) != null) {
      return CspProbeEntry(
        siteKey: siteKey,
        outcome: CspProbeOutcome.skippedInstalled,
      );
    }

    final spec = JarSourceSpec.parse(site.effectiveJar(globalSpider));
    if (spec == null) return null;

    final record = JarIntake.probeRecord(targetDir);
    if (record != null &&
        record['sourceUrl'] == spec.url &&
        _shouldSkip(record, spec.url)) {
      return CspProbeEntry(
        siteKey: siteKey,
        outcome: CspProbeOutcome.rejected,
        jarUrl: spec.url,
        message: '${record['summary'] ?? ''}',
      );
    }

    final bytes = spec.url.isEmpty ? null : await _download(spec.url);
    if (bytes == null) {
      await _writeRecord(
        targetDir,
        siteKey,
        spec,
        verdict: 'fetchFailed',
        summary: '取回失败：${redactUrl(spec.url)}',
      );
      return CspProbeEntry(
        siteKey: siteKey,
        outcome: CspProbeOutcome.failed,
        jarUrl: spec.url,
        message: '配置声明的 jar 取回失败：${redactUrl(spec.url)}',
      );
    }

    // md5 **不参与判定**：TVBox 生态里配置声明的 md5 与实际内容不一致非常普遍
    // （服务端重新打包后没更新配置），按它拒绝会白白丢掉本来能用的入口——
    // 游标 2026-10-25 用户原话：「能下载但 md5 不符，这个不校验」。
    // 只把两份值记进 probe.json 供诊断，真正的判据仍然是 [JarIntake] 的静态检测。
    final declaredMd5 = spec.md5;
    final actualMd5 = declaredMd5 == null
        ? null
        : md5.convert(bytes).toString();
    final md5Note = (declaredMd5 != null && declaredMd5 != actualMd5)
        ? '配置声明的 md5 与实际内容不一致（期望 $declaredMd5，实际 $actualMd5），已忽略'
        : null;
    if (md5Note != null) {
      log?.info(
        'CSP jar 的 md5 与配置不一致，按内容继续检测 site=$siteKey url=${redactUrl(spec.url)}',
        scope: 'spider',
      );
    }

    // 暂存文件按 **URL** 命名：同一份 spring.jar 被 90+ 个站点共享，
    // 按站点各写一份只会白占磁盘（install 自己会复制到各自缓存目录）。
    final cacheDir = Directory(p.join(root, 'probe-cache'));
    await cacheDir.create(recursive: true);
    final urlKey = sha256.convert(utf8.encode(spec.url)).toString();
    final staged = File(
      p.join(cacheDir.path, '${urlKey.substring(0, 16)}.jar'),
    );
    if (!await staged.exists() || await staged.length() != bytes.length) {
      await staged.writeAsBytes(bytes, flush: true);
    }

    final inspection = JarIntake.inspectPath(
      staged.path,
      expectedClass: JarIntake.classNameFor(siteKey),
    );

    // 可落盘：桌面入口（无 dex / 无原生库）直接装；**可转译 dex**（含 classes.dex、
    // 无原生库）落盘后立刻做导入期预转译，CLI 结论随 intake.json 一起留下。
    // 含原生库的入口走下面的拒绝分支——dex 预转译解决不了原生实现只能在
    // Android/ARM 上跑这件事（§12.6.4 ①）。
    if (inspection.installable) {
      final result = await JarIntake.install(
        sourcePath: staged.path,
        targetDir: targetDir,
        siteKey: siteKey,
        log: log,
        translateDex: inspection.verdict == JarVerdict.translatableDex
            ? _translateDex
            : null,
      );
      // 分工：落盘成功与转译成败互不影响（`ok` 只表示落盘）。转译失败在这里
      // 记一条 warning 供诊断，落盘结果不回滚；面向用户的文案由 spider_router 决定。
      final translation = result.dexTranslation;
      if (translation != null && translation['ok'] != true) {
        log?.warning(
          'CSP jar 已落盘但预转译失败 site=$siteKey '
          'stage=${translation['stage']} message=${translation['message']}',
          scope: 'spider',
        );
      }
      await _writeRecord(
        targetDir,
        siteKey,
        spec,
        verdict: inspection.verdict.name,
        summary: md5Note == null
            ? inspection.summary
            : '${inspection.summary}；$md5Note',
        installed: result.ok,
        entryCount: inspection.entryCount,
        sha256: _sha256Of(staged),
        actualMd5: actualMd5,
      );
      return CspProbeEntry(
        siteKey: siteKey,
        outcome: result.ok ? CspProbeOutcome.installed : CspProbeOutcome.failed,
        jarUrl: spec.url,
        inspection: inspection,
        message: result.ok ? '已自动导入桌面入口' : (result.error ?? '导入失败'),
      );
    }

    // 不可加载：**不落盘到 csp 目录**，只记结论。含原生库（dex + lib/*.so）与
    // zip 结构损坏、无法确认无原生库的入口都在这里——dex 预转译只解决字节码形态，
    // 解决不了原生依赖；需要转译的 dex 已在上面那条分支落盘并预转译过。
    await _writeRecord(
      targetDir,
      siteKey,
      spec,
      verdict: inspection.verdict.name,
      summary: md5Note == null
          ? inspection.summary
          : '${inspection.summary}；$md5Note',
      entryCount: inspection.entryCount,
      sha256: _sha256Of(staged),
      actualMd5: actualMd5,
    );
    return CspProbeEntry(
      siteKey: siteKey,
      outcome: CspProbeOutcome.rejected,
      jarUrl: spec.url,
      inspection: inspection,
      message: inspection.summary,
    );
  }

  /// 导入期预转译：缺省走真实 [DexTranslate.run]，测试可注入假实现（不起 JVM）。
  Future<Map<String, Object?>> _translateDex({
    required String siteDir,
    required String archive,
  }) {
    final injected = dexTranslate;
    if (injected != null) return injected(siteDir: siteDir, archive: archive);
    return DexTranslate.run(siteDir: siteDir, archive: archive, log: log);
  }

  /// 有结论且无需重试时跳过下载。
  bool _shouldSkip(Map<String, Object?> record, String url) {
    if (record['sourceUrl'] != url) return false;
    // 结论是按旧判定口径得出的（或早于版本号引入）→ 立刻重下重判。
    final recordedVersion = record['semanticsVersion'];
    if (recordedVersion is! int || recordedVersion != probeSemanticsVersion) {
      return false;
    }
    final verdict = '${record['verdict'] ?? ''}';
    // 旧版本曾按 md5 拒绝（verdict=checksumMismatch）。去掉该判据后这些结论
    // 已经失效，必须立刻重下重判，否则用户还得手动删 probe.json 才能恢复。
    if (verdict == 'checksumMismatch') return false;
    if (verdict == 'fetchFailed') {
      final at = DateTime.tryParse('${record['fetchedAt'] ?? ''}');
      if (at == null) return false;
      return DateTime.now().difference(at) < retryAfter;
    }
    // 静态结论（含 dex / 原生库 / 损坏）与内容无关，重下也是同一结论。
    return verdict.isNotEmpty;
  }

  Future<List<int>?> _download(String url) async {
    if (_downloadCache.containsKey(url)) return _downloadCache[url];
    final result = await _downloadUncached(url);
    _downloadCache[url] = result;
    return result;
  }

  Future<List<int>?> _downloadUncached(String url) async {
    try {
      final response = await _client.get(Uri.parse(url)).timeout(timeout);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        log?.warning(
          'CSP jar 下载失败 HTTP ${response.statusCode} url=${redactUrl(url)}',
          scope: 'spider',
        );
        return null;
      }
      if (response.bodyBytes.length > maxBytes) {
        log?.warning(
          'CSP jar 超过上限 ${response.bodyBytes.length}>$maxBytes url=${redactUrl(url)}',
          scope: 'spider',
        );
        return null;
      }
      return response.bodyBytes;
    } catch (error) {
      log?.warning(
        'CSP jar 下载异常 url=${redactUrl(url)} $error',
        scope: 'spider',
      );
      return null;
    }
  }

  Future<void> _writeRecord(
    String targetDir,
    String siteKey,
    JarSourceSpec spec, {
    required String verdict,
    required String summary,
    bool installed = false,
    int? entryCount,
    String? sha256,
    String? actualMd5,
  }) async {
    try {
      await JarIntake.writeProbe(targetDir, {
        'siteKey': siteKey,
        'sourceUrl': spec.url,
        'semanticsVersion': probeSemanticsVersion,
        'declaredMd5': spec.md5,
        'actualMd5': actualMd5,
        'fetchedAt': DateTime.now().toIso8601String(),
        'sha256': sha256,
        'verdict': verdict,
        'entryCount': entryCount,
        'summary': summary,
        'installed': installed,
      });
    } catch (error) {
      log?.warning('写入 CSP 探测结论失败 site=$siteKey $error', scope: 'spider');
    }
  }

  /// 读取某个站点上次的探测结论（供路由判定与 UI 展示）。
  static Map<String, Object?>? recordFor(
    CspJvmBinding binding,
    String siteKey,
  ) => JarIntake.probeRecord(binding.directoryFor(siteKey));

  static String? _sha256Of(File file) {
    try {
      return sha256.convert(file.readAsBytesSync()).toString();
    } catch (_) {
      return null;
    }
  }
}
