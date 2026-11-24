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
/// 4. 加固壳（`assets/*.guard` / DexNative 系）先解包再判定：payload 按 SHA-256
///    缓存在 `<root>/probe-cache/shell/<sha>/payload.jar`；解包运行时（unidbg）
///    未安装时**只报结论、不触发下载**（下载由 UI 的用户动作发起）。
///
/// 5. 加固壳站点按「**壳 jar 作入口 + payload.jar 同目录**」装配：`index.jar` 是壳 jar，
///    解包产物另存 `payload.jar`，`manifest.config.className` 写**壳入口类**。壳的
///    `Init → DexNative` 加载链在桌面 JVM 上由 host.jar 里的同名影子类接管，由它在
///    payload 里解析真实现——壳类名与 payload 类名未必有对应关系（实测
///    `WexHanXiaoQuan` 的真实现是 `WexAiHanXiaoQuan`），所以 App 侧不猜 payload 类名。
///
/// 因此「自动迁移」的真实边界是：能加载（或能转译成能加载）的自动装好；不能的
/// 自动说清原因（含**卡在哪个阶段**），而不是让用户对着一句「缺少 jar」反复试。
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
import 'shell_unpack.dart';
import 'spider_registry.dart';
import 'unidbg_runtime.dart';

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

  /// 加固壳入口已解包成 payload 并导入（含命中 payload 缓存的情形）。
  ///
  /// 与 [installed] 分开：用户要能区分「本来就是桌面 jar」和「先解了壳才装好」，
  /// 因为后者的 native 依赖在桌面上仍然缺失（调用会抛 UnsatisfiedLinkError）。
  unpacked,

  /// 加固壳入口需要先下载 ARM 解包运行时（unidbg，约 40 MB）。
  ///
  /// **不在这里触发下载**：运行时属于用户动作，由 UI 发起；探测只如实报
  /// 「缺什么、多大、下一步做什么」。
  needsShellRuntime,

  /// 解包失败（结论里带 `stage`：卡在哪一阶段）。
  unpackFailed,

  /// 壳族未支持：解出来的 payload 仍无法在桌面 JVM 加载（或仍带壳特征）。
  unsupportedShell,
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

  /// 壳入口已解包并导入（含命中 payload 缓存）。
  int get unpacked =>
      entries.where((e) => e.outcome == CspProbeOutcome.unpacked).length;

  /// 需要用户先下载解包运行时（**未触发下载**）。
  int get needsShellRuntime => entries
      .where((e) => e.outcome == CspProbeOutcome.needsShellRuntime)
      .length;

  /// 解包失败（带阶段）。
  int get unpackFailed =>
      entries.where((e) => e.outcome == CspProbeOutcome.unpackFailed).length;

  bool get isEmpty => entries.isEmpty;
}

/// 一个**按 jar URL 聚合**的加固壳目标在 UI 上的状态。
///
/// 与 [CspProbeOutcome] 分开：后者是**一次探测动作**的结论（含取回失败、跳过），
/// UI 的多选解包页只需回答「这份壳 jar 现在能不能直接开始解包、缺什么」。
enum ShellTargetState {
  /// 已解包并导入（`<csp>/<key>/` 已有入口）：无事可做。
  installed,

  /// 缺 ARM 解包运行时（unidbg，[CspJarProbe.shellRuntimeSizeLabel]）：
  /// **本机没有它就无法解包**，下一步是用户主动下载。
  needsRuntime,

  /// 运行时就位、也没有 payload 缓存：可以开始解包。
  needsUnpack,

  /// payload 已缓存（解包过），但至少一个站点还没装好：只差导入。
  unpacked,

  /// 上次解包失败（[ShellJarTarget.stage] / [ShellJarTarget.message] 说明卡在哪）。
  failed,
}

/// 一个**按 jar URL 聚合**的加固壳目标：同一份壳 jar 常被几十个站点共用
/// （AT 的 spring.jar 就有 90+ 个），逐站点列出来只会让多选失去意义。
class ShellJarTarget {
  const ShellJarTarget({
    required this.jarUrl,
    required this.state,
    this.md5,
    this.siteKeys = const [],
    this.jarSha256,
    this.payloadSha256,
    this.stage,
    this.message,
  });

  /// 配置里声明的 jar 地址（聚合键：**同一 URL = 同一个目标**）。
  final String jarUrl;

  /// 配置声明的 md5（`;md5;<hash>`），未声明为 null；仅展示用，不参与判定。
  final String? md5;

  /// 共享这份 jar 的站点 key：**已去重并排序**，UI 直接展示。
  final List<String> siteKeys;

  /// 壳 jar 的 SHA-256（payload 缓存目录就按它命名）；内容未知时为 null。
  final String? jarSha256;

  final ShellTargetState state;

  /// payload 的 SHA-256（已缓存/已解包时有值）。
  final String? payloadSha256;

  /// 上次解包失败的阶段（仅在 [ShellTargetState.failed] 时有值）。
  final String? stage;

  /// 面向用户的一句话结论/原因（与 probe.json 里的 summary 同源）。
  final String? message;
}

/// 解包进度的一次回调（`unpackSelected` 的 `onProgress`）。
class ShellUnpackTick {
  const ShellUnpackTick({
    required this.jarIndex,
    required this.jarCount,
    required this.jarUrl,
    required this.fraction,
    required this.stage,
    this.eta,
  });

  /// 当前 jar 在本次多选里的下标（**0 起**）。
  final int jarIndex;

  /// 本次多选涉及的 jar 总数。
  final int jarCount;

  final String jarUrl;

  /// **总体**进度（0..1，单调不减）：跨 jar 折算，不是在单个 jar 内循环。
  ///
  /// 单个 jar 的那一段与 [ShellUnpack.fractionAt] **同一口径**（**含**当前阶段的
  /// 权重）：`(jarIndex + fractionAt(stage)) / jarCount`。
  final double fraction;

  /// 当前阶段名，与 CLI 的 `STAGES` 一字不差（见 [ShellUnpack.stages]）。
  final String stage;

  /// 总体剩余时间；**数据太薄时（刚读完壳 / 刚认出配方）为 null**——
  /// 那时没有任何可信速率，编一个数字出来只会在下一阶段被自己推翻。
  final Duration? eta;
}

/// 解包阶段的下标：**名字与权重全部委托给 [ShellUnpack]**，不复制第二份表。
///
/// 为什么不自己排一套词：Dart 侧这里发 tick、sidecar 侧发 [ShellUnpackProgress]，
/// 两处文案一旦分叉，用户在「解包中」与「解包完成」两个界面看到的是两套说法。
///
/// 这里**不单独发** [register] 的 tick：native 注册发生在解包运行时内部（注入点
/// 只返回最终结论），凭空发一条「注册中」是在编造观察不到的事实；但
/// [ShellUnpack.fractionAt] 的口径把注册的权重算进 [invoke]（进入该阶段即 0.90），
/// 折算与 sidecar 完全一致。
class ShellUnpackStages {
  const ShellUnpackStages._();

  static const int read = 0;
  static const int identify = 1;
  static const int start = 2;
  static const int register = 3;
  static const int invoke = 4;
  static const int verify = 5;
  static const int store = 6;

  /// 阶段总数（与 CLI 契约一致）。
  static const int count = ShellUnpack.stageCount;

  /// 下标 → 阶段名（[ShellUnpack.stages] 是唯一的口径定义处）。
  static String nameOf(int index) =>
      index >= 0 && index < ShellUnpack.stages.length
      ? ShellUnpack.stages[index]
      : ShellUnpack.stages.last;

  /// 下标 → **含当前阶段权重**的累计进度（0..1）。
  static double fractionOf(int index) => ShellUnpack.fractionAt(index);

  /// 阶段名 → 下标；sidecar 的进度事件按名字上报，这里做**唯一**的对照转换。
  /// 未登记的名字返回 -1（调用方丢弃，避免把未知阶段当成收尾把进度推到 100%）。
  static int indexOf(String stage) {
    final name = stage.trim();
    for (var i = 0; i < ShellUnpack.stages.length; i++) {
      if (ShellUnpack.stages[i] == name) return i;
    }
    return -1;
  }
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
    this.shellUnpack,
    this.shellRuntimeInstalled,
    this.unidbgRuntime,
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

  /// 加固壳解包钩子（签名见 [ShellUnpack.run] 的核心参数）。
  ///
  /// 缺省用真实的 [ShellUnpack.run]（起一次 `java -cp <unidbg>/* ShellUnpack.java`）；
  /// 单测注入假实现，避免测试里真的起 java / 真的起 ARM 模拟器。
  final Future<Map<String, Object?>> Function({
    required String shellJar,
    required String outJar,
  })?
  shellUnpack;

  /// 解包运行时是否已安装（单测注入；缺省读 [unidbgRuntime] 的 `isInstalledSync`）。
  ///
  /// 探测只**读状态**、绝不触发下载：约 40 MB 的下载属于用户动作。
  final bool Function()? shellRuntimeInstalled;

  /// ARM 解包运行时（unidbg）。为空时按需新建（`dir`/`classpathWildcard` 是
  /// 实例 getter，依赖应用数据目录，因此这里注入实例而不是静态引用）。
  final UnidbgRuntime? unidbgRuntime;

  final http.Client _client;

  /// 单轮探测的下载缓存（URL → 字节或 null=失败）。
  final Map<String, List<int>?> _downloadCache = {};
  final Map<String, List<Map<String, Object?>>> _shellAttempts = {};

  /// 懒建的运行时实例：只有真的碰到加固壳入口才会用到它。
  late final UnidbgRuntime _runtime = unidbgRuntime ?? UnidbgRuntime(log: log);

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
  /// 版本 3：判定顺序改为「加固壳 → 原生库 → dex」，并新增解包链路
  /// （`shellGuard` 不再直接报「含原生库/不可用」，payload 判定口径也变了）。
  /// 版本 2 及更早写下的结论必须立刻失效并重判。
  /// 3 → 4：**入口类名改按 `api` 推导**（此前按站点 key）。旧结论里的站点是用错误的
  /// 类名装出来的（侧车退出码 3、点开没有任何内容），不能继续复用。
  /// 4 → 5：**加固壳站点改为「壳 jar 作入口 + payload.jar 同目录」**（此前把解包产物
  /// 直接当入口）。旧结论装出来的是 payload 入口：壳类不在 payload 里，站点必然
  /// ClassNotFound（code=3），而且壳的加载链（Init → DexNative）根本没被走到。
  static const int probeSemanticsVersion = 5;

  /// 解包运行时的公告体积（18 个 jar，约 39 MB）。
  ///
  /// 只用于**文案**：探测绝不下载运行时，用户要在按下「下载」之前就看到代价。
  static const String shellRuntimeSizeLabel = '约 40.7 MB';

  /// payload 的 dex 转译产物目录（相对站点目录）。
  ///
  /// 必须与宿主 `com.github.catvod.spider.DexNative` 里的同名常量一致：它在 payload.jar
  /// 同级目录找这里预转译好的 classes.jar，找不到才会在加载期自己再转译一次（5-9 s
  /// 的 dex2jar 会挤在侧车握手窗口里）。
  ///
  /// 为什么不复用站点目录的 `dexBundles/`：那是**壳**的转译产物，两者都写
  /// `classes.jar`，共用会互相顶掉。
  static const String payloadDexDirName = 'payload-dex';

  /// 扫描配置里所有 `csp_*` 站点并逐个探测（幂等；不抛异常）。
  ///
  /// 同一轮内按 URL 去重下载：AT 这类配置有 90+ 个站点共用同一个 `spring.jar`，
  /// 若逐站点独立取回会产生上百次请求，也会放大上游压力。
  Future<CspProbeReport> materialize(
    AppConfig config, {
    void Function(ShellUnpackTick)? onProgress,
  }) async {
    final entries = <CspProbeEntry>[];
    final probeClock = Stopwatch()..start();
    _downloadCache.clear();
    _shellAttempts.clear();
    final sites = config.sites
        .where(
          (site) =>
              CspJvmBinding.matches(site.api) && directSpiderKind(site) == null,
        )
        .toList();
    final eta = _UnpackEtaEstimator(jarCount: sites.length);
    // 只有站点边界适合报整体速率估算；装配/翻译阶段如实报「计算中」。
    const estimatedStages = {'站点-探测', '站点-完成'};
    var lastFraction = -1.0;
    var siteIndex = 0;
    var siteStartMs = 0;
    void emit(double fraction, String stage, {double? inside, int? completed}) {
      if (fraction < lastFraction) return;
      lastFraction = fraction;
      // 只有站点边界才报估算：壳内阶段权重只在真解包时攒得够样本，缓存命中的站点
      // 永远走不到那里，只靠它预计时间会一直空着；而装配/翻译阶段的实际耗时由另一
      // 条路径按「不可估」上报，不能被这里的整体速率盖掉。
      final measured = estimatedStages.contains(stage)
          ? eta.measuredEta(
              completed: completed ?? siteIndex,
              total: sites.length,
              elapsedMs: probeClock.elapsedMilliseconds,
            )
          : null;
      try {
        onProgress?.call(
          ShellUnpackTick(
            jarIndex: sites.isEmpty ? 0 : siteIndex,
            jarCount: sites.length,
            jarUrl: sites.isEmpty
                ? ''
                : JarSourceSpec.parse(
                        sites[siteIndex].effectiveJar(config.spider),
                      )?.url ??
                      '',
            fraction: fraction,
            stage: stage,
            eta:
                (inside == null
                    ? null
                    : eta.eta(
                        jarIndex: siteIndex,
                        jarElapsedMs:
                            probeClock.elapsedMilliseconds - siteStartMs,
                        fractionInside: inside,
                      )) ??
                measured,
          ),
        );
      } catch (_) {}
    }

    emit(0, '探测-开始');
    // 入口类名按 `api` 推导并登记：这份配置的 key 是中文标签，按 key 推必然 ClassNotFound。
    _entryClassByKey
      ..clear()
      ..addEntries(
        config.sites.map((site) => MapEntry(site.key, entryClassNameOf(site))),
      );
    for (final site in sites) {
      // 已有自己运行时的站点（direct js/py、CatVod 壳）不参与 JVM 探测：
      // 它们的 api 只是壳名，**没有**声明 jar 的语义；若配置顶层有全局
      // `spider`，`effectiveJar` 会把那份 jar 也算到它们头上（AT 的顶层
      // spider 就是 spring.jar），探测结果对它们毫无意义，纯属白下白写。
      if (directSpiderKind(site) != null) continue;
      try {
        siteStartMs = probeClock.elapsedMilliseconds;
        emit(siteIndex / sites.length * 0.99, '站点-探测');
        final entry = await _probeSite(
          site,
          config.spider,
          onStage: (index) {
            final inside = ShellUnpack.fractionAt(index).clamp(0.0, 0.97);
            emit(
              (siteIndex + inside) / sites.length * 0.99,
              ShellUnpackStages.nameOf(index),
              inside: inside,
            );
          },
          // Assembly/translation has no trustworthy rate: report the phase with a
          // null ETA instead of letting the unpack curve extrapolate a fake countdown.
          onAssembly: (stage) =>
              emit(((siteIndex + 0.97) / sites.length) * 0.99, stage),
        );
        if (entry != null) entries.add(entry);
        // 命中缓存时 `_probeSite` 可能一路同步跑完，这里显式让出一次事件循环，
        // 否则一百来个站点会在首帧之后连成一段几百毫秒的卡顿。
        await Future<void>.delayed(Duration.zero);
      } catch (error) {
        // 单个站点失败不得影响其它站点与启动。
        log?.warning('CSP jar 自动探测失败 site=${site.key} $error', scope: 'spider');
        entries.add(
          CspProbeEntry(
            siteKey: site.key,
            outcome: CspProbeOutcome.failed,
            message: '$error',
          ),
        );
      }
      eta.markJarDone(probeClock.elapsedMilliseconds - siteStartMs);
      emit(
        (siteIndex + 1) / sites.length * 0.99,
        '站点-完成',
        completed: siteIndex + 1,
      );
      siteIndex++;
    }
    // A later success for identical shell content repairs the earlier site without another emulation.
    for (var i = 0; i < entries.length; i++) {
      final entry = entries[i];
      if (entry.outcome != CspProbeOutcome.unpackFailed) continue;
      final record = JarIntake.probeRecord(binding.directoryFor(entry.siteKey));
      final sha = record?['sha256'];
      if (sha is! String || !_nonEmpty(_payloadFileFor(sha))) continue;
      final site = sites.firstWhere((site) => site.key == entry.siteKey);
      try {
        final repaired = await _probeSite(site, config.spider);
        if (repaired != null) entries[i] = repaired;
      } catch (error) {
        log?.warning('CSP 缓存恢复失败 site=${site.key} $error', scope: 'spider');
      }
      await Future<void>.delayed(Duration.zero);
    }
    siteIndex = sites.isEmpty ? 0 : sites.length - 1;
    emit(1, '探测-完成');
    if (entries.isNotEmpty) {
      final report = CspProbeReport(entries: entries);
      log?.info(
        '探测耗时 elapsed=${probeClock.elapsedMilliseconds}ms '
        'sites=${entries.length}',
        scope: 'spider',
      );
      log?.info(
        'CSP jar 自动探测：已装 ${report.installed} 个、解包装好 ${report.unpacked} 个、'
        '拒绝 ${report.rejected} 个、失败 ${report.failed} 个、'
        '需解包运行时 ${report.needsShellRuntime} 个、解包失败 ${report.unpackFailed} 个',
        scope: 'spider',
      );
      return report;
    }
    // 一个都没处理 = 所有站点的结论按当前口径都还是最新的（跳过不算失败）。
    // 这句话必须打出来：否则日志里「已装 0 个、拒绝 0 个…」会被读成「探测什么都没做」
    // 或「站点全丢了」，而真实含义是「无需操作」。
    log?.info(
      'CSP jar 自动探测：全部站点结论已是最新，无需操作 '
      'elapsed=${probeClock.elapsedMilliseconds}ms',
      scope: 'spider',
    );
    return CspProbeReport(entries: entries);
  }

  /// 列出配置里**加固壳相关**的目标，按 jar URL 聚合（同一份壳 jar 只出现一次）。
  ///
  /// 纯只读：**不下载、不解包、不写 probe.json**——下载与解包都是用户动作。
  /// 判定依据按可信度取：本地暂存 jar 的静态检测 → 该 jar 名下站点的 `probe.json`。
  /// 两者都没有证据的 jar 不会出现在结果里（「不认识的 jar 不猜成壳」）。
  ///
  /// [refresh] 为真时忽略 `probe.json` 里的壳结论、只认本地暂存文件（用户换了 jar
  /// 或怀疑旧结论时用）：此时没有本地暂存文件的 jar 一律不算壳——先探测再说。
  Future<List<ShellJarTarget>> discoverShellTargets(
    AppConfig config, {
    bool refresh = false,
  }) async {
    // 顺带做一次「只升不降」的限额迁移：老站点目录里还写着 256 MiB / 30 s，而加固壳
    // 首译峰值约 257 MiB，会被作业对象静默杀掉（2026-11-21 实测三站点 code=1）。
    // 放在这里是因为它**每次启动都会跑一次**，且不联网、只改 limits 两行。
    JarIntake.ensureMinimumLimits(root: root, log: log);
    final targets = <ShellJarTarget>[];
    for (final group in _jarGroups(config).values) {
      // 让出事件循环：`_describeTarget` 里是同步文件 I/O（读 probe.json、开壳 jar、
      // 算 SHA-256），几十上百个站点连着跑会把首帧之后的那一段直接占满。
      // 每个 group 之间让一次，UI 就不会整段卡住。
      await Future<void>.delayed(Duration.zero);
      final target = _describeTarget(group, refresh: refresh);
      if (target != null) targets.add(target);
    }
    return targets;
  }

  /// 解包**用户选中的** jar（多选语义），每个 jar 成功后导入它名下的**所有**站点。
  ///
  /// 三条纪律：
  /// 1. 只碰 [jarUrls] 里的 jar：没选中的站点不下载、不解包、不落盘；
  /// 2. 单个 jar 失败（取回/运行时/解包/导入）**只记进 report**，不影响后面的 jar；
  /// 3. 走的是与 [materialize] 同一段导入实现（[_installPayload]），失败分级不变。
  ///
  /// [onProgress] 在**每个 jar 开始**与**每个阶段变化**时回调；`fraction` 是跨 jar 折算的
  /// **总体**进度（单个 jar 的那一段与 [ShellUnpack.fractionAt] 同口径，**含**当前阶段
  /// 权重），`eta` 用平滑速率外推，并把**未开始的 jar** 各算一整份。
  Future<CspProbeReport> unpackSelected(
    AppConfig config, {
    required Set<String> jarUrls,
    void Function(ShellUnpackTick)? onProgress,
  }) async {
    _downloadCache.clear();
    _shellAttempts.clear();
    _entryClassByKey
      ..clear()
      ..addEntries(
        config.sites.map((site) => MapEntry(site.key, entryClassNameOf(site))),
      );
    final known = _jarGroups(config);
    final groups = <_JarGroup>[];
    for (final url in jarUrls) {
      if (!known.containsKey(url)) {
        log?.warning('跳过不在配置里的 jar：${redactUrl(url)}', scope: 'spider');
      }
    }
    for (final group in known.values) {
      if (!jarUrls.contains(group.spec.url)) continue;
      if (_describeTarget(group, refresh: false) == null) {
        log?.warning(
          '跳过非加固壳的选中 jar：${redactUrl(group.spec.url)}',
          scope: 'spider',
        );
        continue;
      }
      groups.add(group);
    }
    if (groups.isEmpty) return const CspProbeReport();

    final jarCount = groups.length;
    final clock = Stopwatch()..start();
    final eta = _UnpackEtaEstimator(jarCount: jarCount);
    var jarStartMs = 0;
    // 进度只许前进：解包器上报的阶段与该方法的收尾阶段可能重叠（例如 verify 在
    // 两条路径上都会出现），回退的事件直接被丢弃，避免进度条倒跳。
    var lastFraction = -1.0;
    void emitTick(int index, int stageIndex) {
      final fractionInside = ShellUnpackStages.fractionOf(stageIndex);
      final overall = (index + fractionInside) / jarCount;
      if (overall <= lastFraction) return;
      lastFraction = overall;
      try {
        onProgress?.call(
          ShellUnpackTick(
            jarIndex: index,
            jarCount: jarCount,
            jarUrl: groups[index].spec.url,
            fraction: (index + fractionInside) / jarCount,
            stage: ShellUnpackStages.nameOf(stageIndex),
            eta: eta.eta(
              jarIndex: index,
              jarElapsedMs: clock.elapsedMilliseconds - jarStartMs,
              fractionInside: fractionInside,
            ),
          ),
        );
      } catch (_) {}
    }

    final entries = <CspProbeEntry>[];
    for (var index = 0; index < jarCount; index++) {
      final group = groups[index];
      jarStartMs = clock.elapsedMilliseconds;
      emitTick(index, ShellUnpackStages.read);
      try {
        entries.addAll(
          await _unpackJar(group, (stageIndex) => emitTick(index, stageIndex)),
        );
      } catch (error) {
        // 单个 jar 的意外异常同样只落在自己的结论上：其它选中项照常继续。
        log?.warning(
          '加固壳解包异常 url=${redactUrl(group.spec.url)} $error',
          scope: 'spider',
        );
        entries.addAll(
          await _rejectGroup(
            group,
            outcome: CspProbeOutcome.unpackFailed,
            verdict: JarVerdict.shellGuard.name,
            summary: '加固壳解包异常：$error',
          ),
        );
      }
      eta.markJarDone(clock.elapsedMilliseconds - jarStartMs);
    }

    final report = CspProbeReport(entries: entries);
    log?.info(
      '加固壳多选解包：$jarCount 个 jar，已装 ${report.unpacked} 个、'
      '跳过 ${report.entries.where((e) => e.outcome == CspProbeOutcome.skippedInstalled).length} 个、'
      '失败 ${report.failed} 个、解包失败 ${report.unpackFailed} 个、'
      '需解包运行时 ${report.needsShellRuntime} 个',
      scope: 'spider',
    );
    return report;
  }

  /// 按 URL 把 `csp_*` 站点分组（**不下载、不落盘**）。插入顺序即配置顺序。
  Map<String, _JarGroup> _jarGroups(AppConfig config) {
    final groups = <String, _JarGroup>{};
    for (final site in config.sites) {
      if (!CspJvmBinding.matches(site.api)) continue;
      // 与 [materialize] 同一条排除规则：自带运行时的站点没有「声明 jar」的语义。
      if (directSpiderKind(site) != null) continue;
      final spec = JarSourceSpec.parse(site.effectiveJar(config.spider));
      if (spec == null) continue;
      groups.putIfAbsent(spec.url, () => _JarGroup(spec)).sites.add(site);
    }
    return groups;
  }

  /// 把一个 jar 分组翻译成 UI 要的 [ShellJarTarget]（不是加固壳返回 null）。
  ///
  /// 状态优先级（越靠前越「已经是事实」，不因本机现况而倒退）：
  /// 已装好 → payload 已缓存 → 缺运行时 → 上次失败 → 待解包。
  /// 缺运行时之所以排在「上次失败」之前：没有运行时，重试只会在同一步再失败一次，
  /// 用户真正该做的是先把运行时装上。
  ShellJarTarget? _describeTarget(_JarGroup group, {required bool refresh}) {
    final url = group.spec.url;
    final stagedFile = _stagedFileFor(url);
    final staged = _nonEmpty(stagedFile) ? stagedFile : null;
    JarInspection? fileInspection;
    if (staged != null) {
      fileInspection = JarIntake.inspectPath(
        staged.path,
        expectedClass: entryClassNameOf(group.sites.first),
      );
    }
    final fileIsShell = fileInspection == null
        ? null
        : fileInspection.verdict == JarVerdict.shellGuard;
    final recordIsShell = group.sites.any(
      (site) => _recordIsShell(
        JarIntake.probeRecord(binding.directoryFor(site.key)),
        url,
      ),
    );
    final shell = fileIsShell ?? (refresh ? false : recordIsShell);
    if (!shell) return null;

    final siteKeys = <String>{};
    var allInstalled = true;
    String? jarSha = staged == null ? null : _sha256Of(staged);
    String? payloadSha;
    String? stage;
    String? message;
    var failed = false;
    for (final site in group.sites) {
      siteKeys.add(site.key);
      if (binding.entryFor(site.key) == null) allInstalled = false;
      final record = JarIntake.probeRecord(binding.directoryFor(site.key));
      if (record == null ||
          record['sourceUrl'] != url ||
          !_isCurrentRecord(record)) {
        continue;
      }
      final recordedSha = '${record['sha256'] ?? ''}'.trim();
      if (jarSha == null && recordedSha.isNotEmpty) jarSha = recordedSha;
      final recordedPayload = record['shellPayload'];
      if (payloadSha == null &&
          recordedPayload is Map &&
          recordedPayload['sha256'] != null) {
        payloadSha = '${recordedPayload['sha256']}';
      }
      if ('${record['outcome'] ?? ''}'.trim() ==
          CspProbeOutcome.unpackFailed.name) {
        failed = true;
        final recordedStage = '${record['shellStage'] ?? ''}'.trim();
        if (stage == null && recordedStage.isNotEmpty) stage = recordedStage;
        final summary = '${record['summary'] ?? ''}'.trim();
        if (message == null && summary.isNotEmpty) message = summary;
      }
    }

    final payloadFile = jarSha == null ? null : _payloadFileFor(jarSha);
    final cached = payloadFile != null && _nonEmpty(payloadFile);
    if (cached) payloadSha ??= _sha256Of(payloadFile);
    final ShellTargetState state;
    if (allInstalled) {
      // 入口已在缓存目录里：用户能直接用，剩余缓存是否还在不该让状态倒退。
      state = ShellTargetState.installed;
    } else if (cached) {
      state = ShellTargetState.unpacked;
    } else if (!_shellRuntimeInstalled()) {
      state = ShellTargetState.needsRuntime;
    } else if (failed) {
      state = ShellTargetState.failed;
    } else {
      state = ShellTargetState.needsUnpack;
    }

    final keys = siteKeys.toList()..sort();
    return ShellJarTarget(
      jarUrl: url,
      md5: group.spec.md5,
      siteKeys: keys,
      jarSha256: jarSha,
      state: state,
      payloadSha256: payloadSha,
      stage: state == ShellTargetState.failed ? stage : null,
      message: state == ShellTargetState.failed ? message : null,
    );
  }

  /// 解包**一个** jar 并把 payload 导入它名下的所有站点。
  ///
  /// 每个失败出口都返回结论条目（不抛异常），[unpackSelected] 因此能逐个 jar 继续。
  Future<List<CspProbeEntry>> _unpackJar(
    _JarGroup group,
    void Function(int stageIndex) emit,
  ) async {
    final spec = group.spec;
    final url = spec.url;

    // 暂存命中就不重下：用户在探测里已经下过一次，多选解包没有理由再打一遍。
    final staged = _stagedFileFor(url);
    var jarFile = _nonEmpty(staged) ? staged : null;
    if (jarFile == null) {
      final bytes = await _download(url);
      if (bytes != null) {
        try {
          await Directory(p.join(root, 'probe-cache')).create(recursive: true);
          await staged.writeAsBytes(bytes, flush: true);
          jarFile = staged;
        } catch (error) {
          log?.warning(
            '写解包暂存 jar 失败 url=${redactUrl(url)} $error',
            scope: 'spider',
          );
        }
      }
    }
    if (jarFile == null) {
      // 与 materialize 同一条口径：取回失败写 `fetchFailed`，[retryAfter] 冷却后自动重试。
      return _rejectGroup(
        group,
        outcome: CspProbeOutcome.failed,
        verdict: 'fetchFailed',
        summary: '取回失败：${redactUrl(url)}',
      );
    }

    // 手上有壳 jar 了才开始「认配方」：没拿到字节的识别是假的。
    emit(ShellUnpackStages.identify);
    final inspection = JarIntake.inspectPath(
      jarFile.path,
      expectedClass: JarIntake.classNameFor(group.sites.first.key),
    );
    if (inspection.verdict != JarVerdict.shellGuard) {
      // 选中的 jar 内容已经变了：不再解包，如实说清（不猜、不硬套壳流程）。
      return _rejectGroup(
        group,
        outcome: CspProbeOutcome.unsupportedShell,
        verdict: inspection.verdict.name,
        summary:
            '本地暂存的 jar 已不是加固壳（${inspection.summary}）：'
            '跳过解包，请重新探测后再决定。',
        inspection: inspection,
      );
    }

    final shellSha = _sha256Of(jarFile) ?? '';
    final payload = _payloadFileFor(shellSha);
    Map<String, Object?>? unpack;
    if (_nonEmpty(payload)) {
      log?.info(
        '复用加固壳解包缓存 url=${redactUrl(url)} sha=${_shortSha(shellSha)}',
        scope: 'spider',
      );
    } else {
      if (!_shellRuntimeInstalled()) {
        final summary =
            '该入口是加固壳（${_shellLabel(inspection)}）：需要 ARM 解包桥（unidbg，'
            '$shellRuntimeSizeLabel）先解出 payload 才能转译；解包运行时未安装，'
            '因此不自动导入。下一步：设置 → 站点与内容 → 「运行时与外部依赖」→ 加固壳解包运行时 → 下载（约 40.7 MB），然后回来再探测一次。';
        return _rejectGroup(
          group,
          outcome: CspProbeOutcome.needsShellRuntime,
          verdict: inspection.verdict.name,
          summary: summary,
          sha256: shellSha,
          inspection: inspection,
        );
      }
      try {
        await payload.parent.create(recursive: true);
      } catch (error) {
        log?.warning(
          '创建解包缓存目录失败 url=${redactUrl(url)} $error',
          scope: 'spider',
        );
      }
      // 真实解包器会逐阶段上报，因此不预发 start/invoke（预发会把进度先顶到 0.90，
      // 后面的真实阶段会被单调性保护吞掉，用户看到 90% 卡住整个解包时长）。
      // 注入的假实现拿不到内部阶段，才用这两条把区间括起来。
      if (shellUnpack != null) {
        emit(ShellUnpackStages.start);
        emit(ShellUnpackStages.invoke);
      }
      unpack = await _runShellUnpack(
        shellJar: jarFile.path,
        outJar: payload.path,
        onProgress: (progress) {
          final index = ShellUnpackStages.indexOf(progress.stage);
          if (index >= 0)
            emit(
              index == ShellUnpackStages.store
                  ? ShellUnpackStages.verify
                  : index,
            );
        },
      );
      final stage = '${unpack['stage'] ?? ''}'.trim();
      final message = '${unpack['message'] ?? ''}'.trim();
      if (unpack['ok'] != true) {
        final failedStage = stage.isEmpty ? ShellUnpack.stageInvoke : stage;
        return _rejectGroup(
          group,
          outcome: CspProbeOutcome.unpackFailed,
          verdict: inspection.verdict.name,
          summary: _shellFailureSummary(failedStage, message),
          shellStage: failedStage,
          sha256: shellSha,
          inspection: inspection,
        );
      }
    }

    emit(ShellUnpackStages.verify);
    if (!_nonEmpty(payload)) {
      return _rejectGroup(
        group,
        outcome: CspProbeOutcome.unpackFailed,
        verdict: inspection.verdict.name,
        summary: _shellFailureSummary(
          'payload-校验',
          'CLI 报告成功但 payload 不存在或为空：${payload.path}',
        ),
        shellStage: 'payload-校验',
        sha256: shellSha,
        inspection: inspection,
      );
    }

    final payloadInfo = _payloadInfo(payload, unpack);
    final entries = <CspProbeEntry>[];
    for (final site in group.sites) {
      await Future<void>.delayed(Duration.zero);
      if (binding.entryFor(site.key) != null) {
        // 已导入（含用户手工导入）的站点不被覆盖：多选解包不是「重装」。
        entries.add(
          CspProbeEntry(
            siteKey: site.key,
            outcome: CspProbeOutcome.skippedInstalled,
            jarUrl: url,
          ),
        );
        continue;
      }
      entries.add(
        await _installPayload(
          siteKey: site.key,
          targetDir: binding.directoryFor(site.key),
          spec: spec,
          shell: jarFile,
          payload: payload,
          payloadInfo: payloadInfo,
          shellSha: shellSha,
        ),
      );
    }
    // 「落盘」是这一组的**收尾**：装完才发，装上失败的站点不会先被报成完成。
    emit(ShellUnpackStages.store);
    return entries;
  }

  /// 整组站点共用的失败出口：一条结论写盘 + 一条条目，逐个站点留痕。
  Future<List<CspProbeEntry>> _rejectGroup(
    _JarGroup group, {
    required CspProbeOutcome outcome,
    required String verdict,
    required String summary,
    String? shellStage,
    String? sha256,
    JarInspection? inspection,
  }) async {
    final entries = <CspProbeEntry>[];
    for (final site in group.sites) {
      final siteKey = site.key;
      await _writeRecord(
        binding.directoryFor(siteKey),
        siteKey,
        group.spec,
        verdict: verdict,
        outcome: outcome.name,
        summary: summary,
        shellStage: shellStage,
        sha256: sha256,
      );
      entries.add(
        CspProbeEntry(
          siteKey: siteKey,
          outcome: outcome,
          jarUrl: group.spec.url,
          inspection: inspection,
          message: summary,
        ),
      );
    }
    return entries;
  }

  /// `probe.json` 的结论是否按**当前判定口径**得出（否则一律当不存在）。
  static bool _isCurrentRecord(Map<String, Object?> record) {
    final version = record['semanticsVersion'];
    return version is int && version == probeSemanticsVersion;
  }

  /// 该站点上次的结论是否表明「它的 jar 是加固壳」（要求结论按**当前口径**得出）。
  static bool _recordIsShell(Map<String, Object?>? record, String url) {
    if (record == null || record['sourceUrl'] != url) return false;
    if (!_isCurrentRecord(record)) return false;
    return _shellFeatures(record);
  }

  /// 结论本身是否属于加固壳链路（**不看**版本号）。
  ///
  /// 与 [_recordIsShell] 的区别：那里问「按当前口径，它是不是壳」；这里问「这条结论当初
  /// 是不是壳链路得出的」——用来判断旧口径装出来的壳站点需不需要按新装配重装。
  static bool _shellFeatures(Map<String, Object?> record) {
    if ('${record['verdict'] ?? ''}' == JarVerdict.shellGuard.name) return true;
    if (record['shellPayload'] is Map) return true;
    return _shellOutcomes.contains('${record['outcome'] ?? ''}'.trim());
  }

  /// [CspProbeOutcome] 里属于加固壳链路的结论（这些站点的 jar 一定是壳）。
  static const List<String> _shellOutcomes = [
    'needsShellRuntime',
    'unpackFailed',
    'unpacked',
    'unsupportedShell',
  ];

  /// 单轮内按 URL 暂存 jar 的路径（`probe-cache/<url 哈希前 16 位>.jar`）。
  File _stagedFileFor(String url) {
    final key = sha256.convert(utf8.encode(url)).toString();
    return File(p.join(root, 'probe-cache', '${key.substring(0, 16)}.jar'));
  }

  /// payload 缓存路径：按**壳 jar 内容**命名，同一份壳 jar 只解包一次。
  File _payloadFileFor(String shellSha) => File(
    p.join(
      root,
      'probe-cache',
      'shell',
      shellSha.isEmpty ? 'unknown' : shellSha,
      'payload.jar',
    ),
  );

  Future<CspProbeEntry?> _probeSite(
    Site site,
    String? globalSpider, {
    void Function(int)? onStage,
    void Function(String)? onAssembly,
  }) async {
    final siteKey = site.key;
    final targetDir = binding.directoryFor(siteKey);

    final spec = JarSourceSpec.parse(site.effectiveJar(globalSpider));
    if (spec == null) return null;

    // 已导入（含用户手工导入）的站点不参与：不去覆盖用户的选择。
    // 例外：**我们自己写下的、按旧判定口径装的壳站点**。旧口径把解包产物直接当入口，
    // 新口径要求壳 jar 作入口 + payload.jar 同目录；不重装的话这些站点会永远停在
    // code=3，用户只能手动删站点目录——那是把内部实现变更的成本转嫁给用户
    // （与 semanticsVersion 同一条教训）。用户手工放的 jar 没有 probe.json，不受影响。
    final record = JarIntake.probeRecord(targetDir);
    final staleShellEntry =
        record != null &&
        record['sourceUrl'] == spec.url &&
        !_isCurrentRecord(record) &&
        _shellFeatures(record);
    final deferredAssembly =
        record != null &&
        record['sourceUrl'] == spec.url &&
        (record['pretranslationDeferred'] == true ||
            (_shellFeatures(record) &&
                (!_nonEmpty(File(p.join(targetDir, 'index.jar'))) ||
                    !_nonEmpty(File(p.join(targetDir, 'payload.jar'))) ||
                    (!record.containsKey('pretranslationDeferred') &&
                        (!_dexBundlePresent(targetDir) ||
                            !_dexBundlePresent(
                              p.join(targetDir, payloadDexDirName),
                            ))))));
    if (binding.entryFor(siteKey) != null &&
        !staleShellEntry &&
        !deferredAssembly) {
      return CspProbeEntry(
        siteKey: siteKey,
        outcome: CspProbeOutcome.skippedInstalled,
      );
    }

    var current = record;
    // 口径变了但入口已就位：就地改 manifest + 刷新版本，避免 99 个站点重装把界面卡死。
    if (current != null &&
        current['sourceUrl'] == spec.url &&
        !_shouldSkip(current, spec.url) &&
        await _upgradeInPlace(siteKey, targetDir, current)) {
      current = JarIntake.probeRecord(targetDir);
    }
    if (current != null &&
        current['sourceUrl'] == spec.url &&
        _shouldSkip(current, spec.url) &&
        !deferredAssembly &&
        current['installed'] != true) {
      return CspProbeEntry(
        siteKey: siteKey,
        outcome:
            outcomeFromName('${current['outcome'] ?? ''}') ??
            CspProbeOutcome.rejected,
        jarUrl: spec.url,
        message: '${current['summary'] ?? ''}',
      );
    }

    onStage?.call(ShellUnpackStages.read);
    final stagedCache = _stagedFileFor(spec.url);
    final recordedSha = current != null && current['sourceUrl'] == spec.url
        ? current['sha256']
        : null;
    final recoverCached =
        recordedSha is String &&
        recordedSha.isNotEmpty &&
        _nonEmpty(stagedCache) &&
        stagedCache.lengthSync() <= maxBytes &&
        _sha256Of(stagedCache) == recordedSha &&
        _nonEmpty(_payloadFileFor(recordedSha));
    final bytes = recoverCached
        ? await stagedCache.readAsBytes()
        : await _download(spec.url);
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
    await Directory(p.join(root, 'probe-cache')).create(recursive: true);
    final staged = _stagedFileFor(spec.url);
    if (!await staged.exists() || await staged.length() != bytes.length) {
      await staged.writeAsBytes(bytes, flush: true);
    }

    final inspection = JarIntake.inspectPath(
      staged.path,
      expectedClass: _entryClassOf(siteKey),
    );

    // 加固壳（`assets/*.guard` / DexNative 系）必须先解包：不解包它既不能转译也
    // 加载不出来，而「含原生库」这种结论对用户毫无可操作性（§12.6.4 ①）。
    if (inspection.verdict == JarVerdict.shellGuard) {
      return _probeShell(
        siteKey: siteKey,
        targetDir: targetDir,
        spec: spec,
        staged: staged,
        inspection: inspection,
        md5Note: md5Note,
        actualMd5: actualMd5,
        onStage: onStage,
        onAssembly: onAssembly,
      );
    }

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
    // 解决不了原生依赖；需要转译的 dex 已在上面那条分支落盘并预转译过，
    // 加固壳入口则由 [_probeShell] 先尝试解包。
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

  /// 加固壳入口：解包 → 校验 → 按 payload 判定 → 导入。**永不抛异常**。
  ///
  /// 分级如实：缺运行时（[CspProbeOutcome.needsShellRuntime]，**不在探测里下载**）、
  /// 解包失败（[CspProbeOutcome.unpackFailed]，带 `stage`）、壳族未支持
  /// （[CspProbeOutcome.unsupportedShell]）三者互不掩盖。
  Future<CspProbeEntry> _probeShell({
    required String siteKey,
    required String targetDir,
    required JarSourceSpec spec,
    required File staged,
    required JarInspection inspection,
    String? md5Note,
    String? actualMd5,
    void Function(int)? onStage,
    void Function(String)? onAssembly,
  }) async {
    onStage?.call(ShellUnpackStages.identify);
    // payload 按**壳 jar 的内容**缓存：同一份壳 jar 被 90+ 个 csp_ 站点共用时，
    // 解包只做一次（解包要起 ARM 模拟器，是整条链里最贵的一步）。
    final shellSha = _sha256Of(staged) ?? '';
    final payload = _payloadFileFor(shellSha);
    Map<String, Object?>? unpack;
    if (_nonEmpty(payload)) {
      log?.info(
        '复用加固壳解包缓存 site=$siteKey sha=${_shortSha(shellSha)}',
        scope: 'spider',
      );
    } else {
      if (!_shellRuntimeInstalled()) {
        final summary =
            '该入口是加固壳（${_shellLabel(inspection)}）：需要 ARM 解包桥（unidbg，'
            '$shellRuntimeSizeLabel）先解出 payload 才能转译；解包运行时未安装，'
            '因此不自动导入。下一步：设置 → 站点与内容 → 「运行时与外部依赖」→ 加固壳解包运行时 → 下载（约 40.7 MB），然后回来再探测一次。';
        await _writeRecord(
          targetDir,
          siteKey,
          spec,
          verdict: inspection.verdict.name,
          outcome: CspProbeOutcome.needsShellRuntime.name,
          summary: _withMd5Note(summary, md5Note),
          sha256: shellSha,
          entryCount: inspection.entryCount,
          actualMd5: actualMd5,
        );
        return CspProbeEntry(
          siteKey: siteKey,
          outcome: CspProbeOutcome.needsShellRuntime,
          jarUrl: spec.url,
          inspection: inspection,
          message: summary,
        );
      }
      try {
        await payload.parent.create(recursive: true);
      } catch (error) {
        log?.warning('创建解包缓存目录失败 site=$siteKey $error', scope: 'spider');
      }
      final attempts = _shellAttempts.putIfAbsent(shellSha, () => []);
      if (attempts.length >= 2) {
        unpack = attempts.last;
      } else {
        unpack = await _runShellUnpack(
          shellJar: staged.path,
          outJar: payload.path,
          onProgress: (progress) => onStage?.call(progress.stageIndex),
        );
        attempts.add(unpack);
      }
      final stage = '${unpack['stage'] ?? ''}'.trim();
      final message = '${unpack['message'] ?? ''}'.trim();
      // 失败一律带阶段：用户要看的是「卡在哪」，不是「解包失败」四个字。
      if (unpack['ok'] != true) {
        return _shellFailure(
          siteKey: siteKey,
          targetDir: targetDir,
          spec: spec,
          inspection: inspection,
          shellSha: shellSha,
          actualMd5: actualMd5,
          stage: stage.isEmpty ? ShellUnpack.stageInvoke : stage,
          message: message,
          md5Note: md5Note,
        );
      }
      if (!_nonEmpty(payload)) {
        return _shellFailure(
          siteKey: siteKey,
          targetDir: targetDir,
          spec: spec,
          inspection: inspection,
          shellSha: shellSha,
          actualMd5: actualMd5,
          stage: 'payload-校验',
          message: 'CLI 报告成功但 payload 不存在或为空：${payload.path}',
          md5Note: md5Note,
        );
      }
    }

    // The CLI's payload write is done; translation/import still runs, so the ETA
    // basis above no longer holds.
    onAssembly?.call('装配-翻译');
    onStage?.call(ShellUnpackStages.verify);
    return _installPayload(
      siteKey: siteKey,
      targetDir: targetDir,
      spec: spec,
      shell: staged,
      payload: payload,
      payloadInfo: _payloadInfo(payload, unpack),
      shellSha: shellSha,
      md5Note: md5Note,
      actualMd5: actualMd5,
    );
  }

  /// 把已解包的 payload 按「**壳 jar 作入口 + payload.jar 同目录**」导入一个站点。
  ///
  /// [materialize] 的单站点探测与 [unpackSelected] 的多选解包共用这一份实现：
  /// 两条入口若各写一遍，「探测装得好、多选装得不一样」只是时间问题。
  Future<CspProbeEntry> _installPayload({
    required String siteKey,
    required String targetDir,
    required JarSourceSpec spec,
    required File shell,
    required File payload,
    required Map<String, Object?> payloadInfo,
    required String shellSha,
    String? md5Note,
    String? actualMd5,
  }) async {
    // 入口类名 = **壳入口类**（api 去 csp_，保留 Guard，再补 com.github.catvod.spider 包名，
    // 省掉宿主对裸类名的那次回退）。payload 里的真实现由 host.jar 里的
    // com.github.catvod.spider.DexNative 自己在运行期解析——壳类名与 payload 类名不是
    // 简单对应（实测 WexHanXiaoQuan 的真实现是 WexAiHanXiaoQuan），App 侧不再猜：
    // 猜错只会变成 code=3（站点点开是空的），而错因在 App 侧看不出来。
    final shellEntryClass = qualifyClassName(_entryClassOf(siteKey));
    final payloadInspection = JarIntake.inspectUnpackedPayload(
      payload.path,
      expectedClass: shellEntryClass,
    );
    if (!payloadInspection.installable) {
      // 解包成功但产物仍不可加载（仍带壳特征 / 结构损坏 / 没有可转译的 dex）：
      // 这是**壳族未支持**，不是「再试一次就好」，因此不重试、不猜。
      final summary = '解包出的 payload 仍无法在桌面 JVM 加载：${payloadInspection.summary}';
      await _writeRecord(
        targetDir,
        siteKey,
        spec,
        verdict: payloadInspection.verdict.name,
        outcome: CspProbeOutcome.unsupportedShell.name,
        summary: _withMd5Note(summary, md5Note),
        shellPayload: payloadInfo,
        shellStage: '',
        sha256: shellSha,
        entryCount: payloadInspection.entryCount,
        actualMd5: actualMd5,
      );
      return CspProbeEntry(
        siteKey: siteKey,
        outcome: CspProbeOutcome.unsupportedShell,
        jarUrl: spec.url,
        inspection: payloadInspection,
        message: summary,
      );
    }

    // 先借 JarIntake.install 的落盘纪律（暂存名 → 原子 rename、intake.json、manifest.json）：
    // 它不接受壳 jar 作源（壳 jar 会被静态检测判成 shellGuard 而拒绝），而这两份写盘格式
    // 只该有一处定义，不在这里复制第二份。转译留到入口与 payload 都就位之后再做。
    final result = await JarIntake.install(
      sourcePath: payload.path,
      targetDir: targetDir,
      siteKey: siteKey,
      className: shellEntryClass,
      log: log,
      unpackedPayload: true,
      translateDex: null,
    );
    if (!result.ok) {
      final summary = result.error ?? '导入失败';
      await _writeRecord(
        targetDir,
        siteKey,
        spec,
        verdict: payloadInspection.verdict.name,
        outcome: CspProbeOutcome.failed.name,
        summary: _withMd5Note(summary, md5Note),
        shellPayload: payloadInfo,
        sha256: shellSha,
        entryCount: payloadInspection.entryCount,
        actualMd5: actualMd5,
      );
      return CspProbeEntry(
        siteKey: siteKey,
        outcome: CspProbeOutcome.failed,
        jarUrl: spec.url,
        inspection: payloadInspection,
        message: summary,
      );
    }

    final payloadSha = '${payloadInfo['sha256'] ?? ''}'.trim();
    final sitePayload = File(p.join(targetDir, 'payload.jar'));
    final deferred = <String>[];
    try {
      // 1) 站点入口换成**壳 jar**：install 刚把 payload 写成了 index.jar，那只是借用它的
      //    落盘纪律，必须被壳顶掉——payload 里没有壳类，拿它当入口必然 ClassNotFound。
      final entry = File(p.join(targetDir, 'index.jar'));
      final entryStaging = File(p.join(targetDir, 'index.jar.staging'));
      await shell.copy(entryStaging.path);
      if (await entry.exists()) await entry.delete();
      await entryStaging.rename(entry.path);

      // 2) payload 落到同目录的 payload.jar。同一份 payload（按 SHA-256）已经就位就不再
      //    复制：90+ 个站点共用同一份解包产物是常态，逐站点重写只是白占 IO。
      final payloadPresent =
          _nonEmpty(sitePayload) &&
          (payloadSha.isEmpty || _sha256Of(sitePayload) == payloadSha);
      if (!payloadPresent) {
        final staging = File(p.join(targetDir, 'payload.jar.staging'));
        await payload.copy(staging.path);
        if (await sitePayload.exists()) await sitePayload.delete();
        await staging.rename(sitePayload.path);
      }

      // 3) 壳与 payload **各转译各的**：两者都是 classes.dex，共用 dexBundles/ 会互相
      //    顶掉（壳的入口类就没了）。payload 的产物目录必须与 DexNative 的约定一致。
      final shellTranslation = await _translateStep(
        siteKey,
        siteDir: targetDir,
        archive: entry.path,
      );
      if (shellTranslation['ok'] != true)
        deferred.add(
          '壳：${shellTranslation['stage']} ${shellTranslation['message']}',
        );
      // payload 的预转译是**幂等**的：DexNative 在运行期就是「payload-dex/dexBundles/
      // classes.jar 在就直接用」，装配期重跑（probe.json 被删、口径重判）没必要再起一次
      // 5-9 s 的 dex2jar——99 个站点叠起来就是一次「界面未响应」。
      final payloadDexDir = p.join(targetDir, payloadDexDirName);
      if (!_dexBundlePresent(payloadDexDir)) {
        final payloadTranslation = await _translateStep(
          siteKey,
          siteDir: payloadDexDir,
          archive: sitePayload.path,
        );
        if (payloadTranslation['ok'] != true)
          deferred.add(
            'payload：${payloadTranslation['stage']} ${payloadTranslation['message']}',
          );
      }
      await _patchIntake(
        targetDir,
        shell: shell,
        shellSha: shellSha,
        payloadSha: payloadSha,
      );
    } catch (error) {
      // 装配半途失败是**真的失败**：入口可能已经不是可加载的形态，如实记下来，
      // 不要留一个「看着装好、点开是 code=3」的站点目录。
      final summary = '壳入口装配失败：$error';
      log?.warning('壳入口装配失败 site=$siteKey $error', scope: 'spider');
      await _writeRecord(
        targetDir,
        siteKey,
        spec,
        verdict: payloadInspection.verdict.name,
        outcome: CspProbeOutcome.failed.name,
        summary: _withMd5Note(summary, md5Note),
        shellPayload: payloadInfo,
        sha256: shellSha,
        entryCount: payloadInspection.entryCount,
        actualMd5: actualMd5,
      );
      return CspProbeEntry(
        siteKey: siteKey,
        outcome: CspProbeOutcome.failed,
        jarUrl: spec.url,
        inspection: payloadInspection,
        message: summary,
      );
    }

    final payloadBytes = payloadInfo['bytes'];
    final payloadSummary =
        '已解包并导入（壳入口 $shellEntryClass，payload $payloadBytes 字节）'
        '${deferred.isEmpty ? '' : '；预转译未完成，加载时重试：${deferred.join('；')}'}';
    await _writeRecord(
      targetDir,
      siteKey,
      spec,
      verdict: payloadInspection.verdict.name,
      outcome: CspProbeOutcome.unpacked.name,
      summary: _withMd5Note(payloadSummary, md5Note),
      pretranslationReasons: deferred,
      shellPayload: payloadInfo,
      installed: true,
      sha256: shellSha,
      entryCount: payloadInspection.entryCount,
      actualMd5: actualMd5,
    );
    JarIntake.ensureLaunchManifest(
      targetDir: targetDir,
      siteKey: siteKey,
      log: log,
    );
    return CspProbeEntry(
      siteKey: siteKey,
      outcome: CspProbeOutcome.unpacked,
      jarUrl: spec.url,
      inspection: payloadInspection,
      message: payloadSummary,
    );
  }

  /// 转译一条入口；失败只记 warning，**不回滚装配**。
  ///
  /// 为什么允许失败：宿主 DexNative 在加载期找不到产物时会自己再转译一次（只是把
  /// 5-9 s 的 dex2jar 挤进侧车握手窗口）；这里预转译只是把那段时间挪到导入期。
  Future<Map<String, Object?>> _translateStep(
    String siteKey, {
    required String siteDir,
    required String archive,
  }) async {
    try {
      await Directory(siteDir).create(recursive: true);
      final result = await _translateDex(siteDir: siteDir, archive: archive);
      if (result['ok'] != true) {
        log?.warning(
          '壳入口装配的预转译未完成 site=$siteKey archive=$archive '
          'stage=${result['stage']} message=${result['message']}',
          scope: 'spider',
        );
      }
      return result;
    } catch (error) {
      // 抛异常也算预转译失败：这一步是**加速**而不是装配前提（运行期 DexNative 还会
      // 自己再译一次），因此只记 warning——否则一次缓存目录不可写就会把整个站点装失败。
      log?.warning(
        '壳入口装配的预转译异常 site=$siteKey archive=$archive $error',
        scope: 'spider',
      );
      return {'ok': false, 'stage': 'dex-转译', 'message': '$error'};
    }
  }

  /// 把 `intake.json` 的字段对齐**真实装配**。
  ///
  /// 为什么必须改：`JarIntake.install` 记的是「源 = payload、入口 = index.jar」，而壳入口
  /// 装配之后 index.jar 是壳 jar——照旧不动会让诊断读到的来源与磁盘上真正在跑的入口不一致
  /// （用户按 intake.json 回滚/排查会找错文件）。
  Future<void> _patchIntake(
    String targetDir, {
    required File shell,
    required String shellSha,
    required String payloadSha,
  }) async {
    final file = File(p.join(targetDir, 'intake.json'));
    if (!await file.exists()) return;
    try {
      final raw = jsonDecode(await file.readAsString());
      if (raw is! Map) return;
      final map = Map<String, Object?>.from(raw);
      map['sourcePath'] = p.normalize(shell.path);
      map['sourceSha256'] = shellSha;
      map['shellEntry'] = true;
      if (payloadSha.isNotEmpty) map['payloadSha256'] = payloadSha;
      await file.writeAsString(jsonEncode(map), flush: true);
    } catch (error) {
      log?.warning(
        '更新 intake.json 失败 target=$targetDir $error',
        scope: 'spider',
      );
    }
  }

  /// 解包失败的统一出口：结论写盘 + 返回 [CspProbeOutcome.unpackFailed]。
  Future<CspProbeEntry> _shellFailure({
    required String siteKey,
    required String targetDir,
    required JarSourceSpec spec,
    required JarInspection inspection,
    required String shellSha,
    required String stage,
    required String message,
    String? actualMd5,
    String? md5Note,
  }) async {
    final summary = _shellFailureSummary(stage, message);
    log?.warning(
      '加固壳解包失败 site=$siteKey stage=$stage $message',
      scope: 'spider',
    );
    await _writeRecord(
      targetDir,
      siteKey,
      spec,
      verdict: inspection.verdict.name,
      outcome: CspProbeOutcome.unpackFailed.name,
      summary: _withMd5Note(summary, md5Note),
      shellStage: stage,
      sha256: shellSha,
      entryCount: inspection.entryCount,
      actualMd5: actualMd5,
    );
    return CspProbeEntry(
      siteKey: siteKey,
      outcome: CspProbeOutcome.unpackFailed,
      jarUrl: spec.url,
      inspection: inspection,
      message: summary,
    );
  }

  /// 解包钩子：缺省走真实 [ShellUnpack.run]，测试可注入假实现（不起 java/模拟器）。
  ///
  /// [onProgress] 只喂给真实的解包器：注入的假实现签名保持不变（单测不起 java），
  /// 因此注入路径的中间阶段由假实现自己决定要不要发。
  Future<Map<String, Object?>> _runShellUnpack({
    required String shellJar,
    required String outJar,
    void Function(ShellUnpackProgress)? onProgress,
  }) {
    final injected = shellUnpack;
    if (injected != null) return injected(shellJar: shellJar, outJar: outJar);
    return ShellUnpack.run(
      shellJar: shellJar,
      outJar: outJar,
      log: log,
      unidbgClasspath: _runtime.classpathWildcard,
      onProgress: onProgress,
    );
  }

  /// 解包运行时是否已安装（**只读状态，不下载**）。
  bool _shellRuntimeInstalled() {
    final injected = shellRuntimeInstalled;
    if (injected != null) return injected();
    return _runtime.isInstalledSync;
  }

  /// payload 的入口类名：先「去 Guard 后缀」，再原样；两个都不在 class 条目里时
  /// 返回 null（由 [JarIntake.install] 退回按 key 推导，宿主如实报 ClassNotFound）。
  /// 入口类名的真源是配置的 `api`（`csp_<类名>`），**不是站点 key**。
  ///
  /// 这份配置里 key 是中文标签（`玩偶`/`花卷`/`蜗牛`…），按 key 推导必然 ClassNotFound，
  /// 侧车会以退出码 3 收场、站点看着「可用」但点开没有任何内容。
  /// 站点 key → 入口类名（`api` 推导）。
  ///
  /// 为什么要一张表：真正拿到 [Site] 的地方（`materialize` / `unpackSelected`）与
  /// 真正要写 manifest 的地方（`_installPayload`）不在同一层，中间隔着只带 siteKey
  /// 的探测函数；把结论在入口处算一次、存下来，比把 [Site] 透传六层更不容易错。
  final Map<String, String> _entryClassByKey = {};

  String _entryClassOf(String siteKey) =>
      _entryClassByKey[siteKey] ?? JarIntake.classNameFor(siteKey);

  /// 站点的入口类名（裸名）：`api` 去 `csp_`。
  ///
  /// 对**加固壳站点**，这里得到的是壳入口类（`XxxGuard`）——真正写进 manifest 前再由
  /// [qualifyClassName] 补包名；非壳入口保持裸名不动（桌面 jar 的类可能在任意包里，
  /// 补 `com.github.catvod.spider` 反而会指向不存在的类）。
  static String entryClassNameOf(Site site) {
    final byApi = CspJvmBinding.classNameOf(site.api).trim();
    if (byApi.isNotEmpty) return byApi;
    return JarIntake.classNameFor(site.key);
  }

  /// 补全站源包名。宿主对裸类名有 `com.github.catvod.spider` 回退，但写全限定名能省掉
  /// 那一次回退，日志里也直接看得出装的是哪个类。
  static String qualifyClassName(String name) {
    final trimmed = name.trim();
    if (trimmed.isEmpty || trimmed.contains('.')) return trimmed;
    return 'com.github.catvod.spider.$trimmed';
  }

  /// 写进 `probe.json` 的 payload 指纹（命中缓存时缺 recipe/asset，如实留 null）。
  /// 解包失败的统一文案（单站点探测与多选解包共用，措辞不得漂移）。
  static String _shellFailureSummary(String stage, String message) =>
      '加固壳解包失败（$stage）${message.isEmpty ? '' : '：$message'}；'
      'payload 未生成，站点仍未导入。下一步：核对解包运行时是否完整、'
      'JDK 是否为 17+，或先通过「安卓设备接入」交给安卓端运行。';

  Map<String, Object?> _payloadInfo(
    File payload,
    Map<String, Object?>? unpack,
  ) {
    var bytes = 0;
    try {
      bytes = payload.lengthSync();
    } catch (_) {}
    return <String, Object?>{
      'sha256': unpack?['sha256'] ?? _sha256Of(payload),
      'bytes': unpack?['bytes'] ?? bytes,
      'recipe': unpack?['recipe'],
      'asset': unpack?['asset'],
    };
  }

  static String _shellLabel(JarInspection inspection) {
    final named = <String>[
      ...inspection.shellEntries,
      ...inspection.dexEntries,
    ];
    if (named.isEmpty) return 'Guard / DexNative';
    return named.take(3).join('、');
  }

  static bool _nonEmpty(File file) {
    try {
      return file.existsSync() && file.lengthSync() > 0;
    } catch (_) {
      return false;
    }
  }

  /// 某个产物目录里是否已经有可加载的 `dexBundles/classes.jar`。
  ///
  /// 约定：classes.jar 非空**且**产物记录是当前修复口径，才算已转译。
  ///
  /// 只判「文件在」会留下一个后门：旧口径的产物看起来完好，实际带着已修的误译（例如
  /// InterfaceMethodref 标记错），继续复用等于让用户永远撞同一个崩溃。判 false 只是「需要再转译」，
  /// 不会被当成永久失败。
  static bool _dexBundlePresent(String siteDir) =>
      _nonEmpty(File(p.join(siteDir, 'dexBundles', 'classes.jar'))) &&
      DexTranslate.recordUsable(
        p.join(siteDir, 'dexBundles', 'intake-dex.json'),
      );

  static String _shortSha(String value) =>
      value.length <= 12 ? value : value.substring(0, 12);

  static String _withMd5Note(String summary, String? md5Note) =>
      md5Note == null ? summary : '$summary；$md5Note';

  /// 导入期预转译：缺省走真实 [DexTranslate.run]，测试可注入假实现（不起 JVM）。
  Future<Map<String, Object?>> _translateDex({
    required String siteDir,
    required String archive,
  }) async {
    final injected = dexTranslate;
    if (injected != null) {
      final shared = p.join(root, 'probe-cache', 'dex');
      final sha = _sha256Of(File(archive));
      if (sha != null) {
        final cached = DexTranslate.copySharedBundle(
          sharedDir: shared,
          sha: sha,
          siteDir: siteDir,
        );
        if (cached != null) return cached;
      }
      final result = await injected(siteDir: siteDir, archive: archive);
      if (result['ok'] == true && sha != null)
        DexTranslate.storeSharedBundle(shared, sha, siteDir);
      return result;
    }
    return DexTranslate.run(
      siteDir: siteDir,
      archive: archive,
      log: log,
      // 共享产物：同一份 payload 被几十个站点共用时只跑一次 dex2jar。
      sharedDir: p.join(root, 'probe-cache', 'dex'),
    );
  }

  /// 判定口径变了、但**入口其实已经就位**时的就地升级。
  ///
  /// 为什么必须有它：语义版本一升，旧记录全部失效 → 99 个站点会重新下载、重装、
  /// 重跑一次 dex 转译（每站一次 JVM）。实测那一下会让窗口直接「未响应」。
  /// 而绝大多数情况下真正变的只有入口类名：改一行 manifest、刷新记录版本即可，
  /// 不需要碰 jar，也不需要起 JVM。
  ///
  /// 只处理「上次是装好了」的记录；其余（失败/未装/入口不存在）照旧走完整重探测。
  Future<bool> _upgradeInPlace(
    String siteKey,
    String targetDir,
    Map<String, Object?> record,
  ) async {
    final outcome = '${record['outcome'] ?? ''}'.trim();
    final installed =
        outcome == CspProbeOutcome.installed.name ||
        outcome == CspProbeOutcome.unpacked.name;
    if (!installed) return false;
    if (binding.entryFor(siteKey) == null) return false;
    // 只有「壳入口 + payload.jar」这套装配才谈得上就地升级入口类名；
    // 旧的 payload 直接作入口（没有 payload.jar）必须走完整重装——
    // 给它写壳类名会立刻 ClassNotFound，而记录版本已被刷新，站点就永久坏了。
    if (!File(p.join(targetDir, 'payload.jar')).existsSync()) return false;
    // 壳站点不能就地修：旧装配的 index.jar 是 payload，新装配要求 index.jar 是壳 jar 且
    // payload.jar 同目录。只改一行 manifest 会把站点指向 payload 里不存在的壳类（code=3），
    // 所以一律重装（重装走 payload 缓存，不重新解包）。
    if (_shellFeatures(record)) return false;
    final manifest = File(p.join(targetDir, 'manifest.json'));
    try {
      final resolved = _entryClassOf(siteKey);
      if (manifest.existsSync()) {
        final raw = jsonDecode(manifest.readAsStringSync());
        if (raw is Map) {
          final map = Map<String, Object?>.from(raw);
          final config = map['config'];
          final configMap = config is Map
              ? Map<String, Object?>.from(config)
              : <String, Object?>{};
          if ('${configMap['className'] ?? ''}' != resolved) {
            configMap['className'] = resolved;
            map['config'] = configMap;
            manifest.writeAsStringSync(jsonEncode(map), flush: true);
            log?.info('就地升级入口类名 site=$siteKey -> $resolved', scope: 'spider');
          }
        }
      }
      final probeFile = File(p.join(targetDir, 'probe.json'));
      if (probeFile.existsSync()) {
        final raw = jsonDecode(probeFile.readAsStringSync());
        if (raw is Map) {
          final map = Map<String, Object?>.from(raw);
          map['semanticsVersion'] = probeSemanticsVersion;
          probeFile.writeAsStringSync(jsonEncode(map), flush: true);
        }
      }
      return true;
    } catch (error) {
      log?.warning('就地升级失败 site=$siteKey $error', scope: 'spider');
      return false;
    }
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
    // 壳链路的两种结论**不是**终态：解包运行时装上之后应当立刻重试；解包失败
    // 可能是临时环境问题（JDK/目录/超时）。把它们当永久结论会让用户必须手动删
    // probe.json 才能恢复——那是内部实现变更的成本转嫁给用户。
    final outcome = '${record['outcome'] ?? ''}'.trim();
    if (outcome == CspProbeOutcome.needsShellRuntime.name ||
        outcome == CspProbeOutcome.unpackFailed.name) {
      return false;
    }
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
    String? outcome,
    bool installed = false,
    int? entryCount,
    String? sha256,
    String? actualMd5,
    // 加固壳链路的结论必须留痕：payload 指纹（sha256/bytes/recipe/asset）与
    // 失败阶段（`stage`）。缺省 null 表示「与壳无关」，不写空字段混淆诊断。
    Map<String, Object?>? shellPayload,
    String? shellStage,
    List<String>? pretranslationReasons,
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
        'outcome': ?outcome,
        'entryCount': entryCount,
        'summary': summary,
        'installed': installed,
        'shellPayload': ?shellPayload,
        'shellStage': ?shellStage,
        if (pretranslationReasons != null)
          'pretranslationDeferred': pretranslationReasons.isNotEmpty,
        'pretranslationReasons': ?pretranslationReasons,
      });
    } catch (error) {
      log?.warning('写入 CSP 探测结论失败 site=$siteKey $error', scope: 'spider');
    }
  }

  /// 把 `probe.json` 里记下的 `outcome` 复原成枚举（未知/缺省返回 null）。
  ///
  /// 用于「跳过重下」时保持分级不变：`needsShellRuntime` 的站点在下一轮仍应
  /// 显示「需要下载解包运行时」，而不是被压成笼统的 `rejected`。
  static CspProbeOutcome? outcomeFromName(String? name) {
    final trimmed = (name ?? '').trim();
    if (trimmed.isEmpty) return null;
    for (final outcome in CspProbeOutcome.values) {
      if (outcome.name == trimmed) return outcome;
    }
    return null;
  }

  /// 读取某个站点上次的探测结论（供路由判定与 UI 展示）。
  static Map<String, Object?>? recordFor(
    CspJvmBinding binding,
    String siteKey,
  ) => JarIntake.probeRecord(binding.directoryFor(siteKey));

  /// 同一份文件的 SHA-256 只算一次（按 path + size + mtime 失效）。
  ///
  /// 为什么需要：解包链路里同一份 payload / 壳 jar 会被反复问（探测、装每个站点、
  /// 写 records），每次都「读整份 + 哈希」会在 UI isolate 上连着烧几百毫秒——
  /// 实测 94 个 1 MB 级的 jar 全量哈希约 0.85 s。
  static final Map<String, ({int size, int mtimeMs, String sha})> _shaCache =
      {};

  static String? _sha256Of(File file) {
    try {
      final stat = file.statSync();
      final mtime = stat.modified.millisecondsSinceEpoch;
      final cached = _shaCache[file.path];
      if (cached != null &&
          cached.size == stat.size &&
          cached.mtimeMs == mtime) {
        return cached.sha;
      }
      final sha = sha256.convert(file.readAsBytesSync()).toString();
      if (_shaCache.length > 256) _shaCache.clear();
      _shaCache[file.path] = (size: stat.size, mtimeMs: mtime, sha: sha);
      return sha;
    } catch (_) {
      return null;
    }
  }
}

/// 解包 ETA 的估计器：阶段权重 → 平滑速率 → 再加上**未开始 jar** 的一整份估计。
///
/// 口径与 sidecar 的 [ShellUnpack.fractionAt] 一致：
/// - 已消耗 = `fraction`（**含**当前阶段权重），剩余 = `1 - fraction`；
/// - 单个 jar 剩余 ≈ 该 jar 已用墙钟 × `(1 - fraction) / fraction`，速率做指数滑动平均；
/// - 跨 jar **不能**只算当前 jar：未开始的 jar 按「已完成 jar 的平均耗时」各算一整份，
///   否则第一个 jar 快结束时进度条会报「还剩 3 秒」，而后面两个 jar 一动没动。
///
/// 数据太薄（刚读完壳 / 刚认出配方，`fraction <= 0.10`）时返回 null：那时没有
/// 可信速率，先给一个大数字再往下跳比不给更糟。
class _UnpackEtaEstimator {
  _UnpackEtaEstimator({required this.jarCount});

  final int jarCount;

  /// 已完成 jar 的实测耗时（毫秒）。
  final List<int> _completedMs = [];

  /// 平滑后的「一个 jar 走完」毫秒数（指数滑动平均）。
  double? _msPerJar;

  /// 新样本在 EMA 里的权重。
  static const double _smoothing = 0.4;

  /// 低于这个进度不给 ETA（只完成了「读壳」或「认配方」，样本太薄）。
  static const double _minFraction = 0.10;

  /// 记下一个 jar 的实测耗时，供「未开始 jar」折算。
  void markJarDone(int elapsedMs) => _completedMs.add(elapsedMs);

  /// 整轮剩余时间：按**本轮已用墙钟时间 ÷ 已完成站点数**外推。
  ///
  /// 与 [eta] 的分工：那个按壳内阶段权重算，只有真解包时才攒得够样本；而自动探测
  /// 绝大多数站点是缓存命中，阶段权重永远停在「读壳」附近，于是预计时间会一直显示
  /// 「计算中」——用户实测 95 站 16 秒跑完，全程没有过一个数字。
  ///
  /// 这里改用可观测的整体速率：第一个站点结束就有值，并且会**自我修正**——开头那个
  /// 需要真解包的站点把估计抬得很高，随后一批缓存命中的站点会在几十个之内把它压回
  /// 真值。剩余不足 1 秒时不报 0，而是报 1 秒（宁可略保守，也不假装已经结束）。
  Duration? measuredEta({
    required int completed,
    required int total,
    required int elapsedMs,
  }) {
    if (completed <= 0 || total <= completed) return null;
    final remaining = elapsedMs / completed * (total - completed);
    final millis = remaining.round();
    return Duration(milliseconds: millis < 1000 ? 1000 : millis);
  }

  /// [jarElapsedMs] 是**当前 jar** 已用的墙钟时间（不是整轮）。
  Duration? eta({
    required int jarIndex,
    required int jarElapsedMs,
    required double fractionInside,
  }) {
    if (fractionInside <= _minFraction) return null;
    final rawPerJar = jarElapsedMs / fractionInside;
    final smoothed = _msPerJar == null
        ? rawPerJar
        : _msPerJar! * (1 - _smoothing) + rawPerJar * _smoothing;
    _msPerJar = smoothed;
    final remainingJars = jarCount - jarIndex - 1;
    final perJarRef = _completedMs.isEmpty
        ? smoothed
        : _completedMs.reduce((a, b) => a + b) / _completedMs.length;
    final remainingMs =
        smoothed * (1 - fractionInside) + perJarRef * remainingJars;
    return Duration(milliseconds: remainingMs <= 0 ? 0 : remainingMs.round());
  }
}

/// 同一份 jar URL 下的一组 `csp_*` 站点（聚合单位：URL 而不是站点）。
class _JarGroup {
  _JarGroup(this.spec);

  final JarSourceSpec spec;

  /// **按配置顺序**保留的站点；对外聚合结果里的站点 key 另做去重排序。
  final List<Site> sites = [];
}
