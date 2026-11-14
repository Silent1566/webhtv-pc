/// Spider 管理页（设计文档 §9.7、§9.8、§17.2、§18.2.1、§18.3）。
///
/// 展示内容与约束：
/// - 每个运行时的 ABI 版本、capability、权限、资源限制与隔离等级；
/// - 每个站点的运行状态（运行中/已崩溃/退避重试/已禁用）与失败计数；
/// - 支持强制停止与重置（人工退出指数退避）；
/// - **如实**标记隔离等级：Job Object 只提供崩溃与资源隔离，不是文件系统或网络
///   沙箱，因此文案不得宣称「强隔离」（§18.2.1）；
/// - 本地 Spider 来源与权限在启用前必须可见（§18.1、§18.2）。
library;

import 'package:flutter/material.dart';

import '../services/csp_jar_probe.dart';
import '../services/jar_intake.dart';
import '../services/spider_process.dart';
import '../services/spider_registry.dart';
import '../state/app_state.dart';
import 'common.dart';
import 'local_sources_page.dart';

class SpiderPage extends StatefulWidget {
  const SpiderPage({super.key, required this.state});

  final AppState state;

  @override
  State<SpiderPage> createState() => _SpiderPageState();
}

class _SpiderPageState extends State<SpiderPage> {
  bool _scanning = false;

  @override
  void initState() {
    super.initState();
    widget.state.addListener(_onStateChanged);
    // 首次进入扫描一次，保证页面展示的是磁盘上的真实 manifest。
    WidgetsBinding.instance.addPostFrameCallback((_) => _rescan());
  }

  @override
  void dispose() {
    widget.state.removeListener(_onStateChanged);
    super.dispose();
  }

  void _onStateChanged() {
    if (mounted) setState(() {});
  }

  AppState get _state => widget.state;

  Future<void> _rescan() async {
    if (_scanning) return;
    setState(() => _scanning = true);
    try {
      await _state.rescanSpiders();
    } finally {
      if (mounted) setState(() => _scanning = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final local = _state.localSpiders;
    final runtimes = _state.spiderRuntimeStatuses();
    return Padding(
      padding: const EdgeInsets.all(16),
      child: ListView(
        children: [
          Row(
            children: [
              Text(
                'Spider 运行时',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const Spacer(),
              if (_scanning) const SizedBox(
                width: 16,
                height: 16,
                child: LoadingBlock(center: false, size: 16),
              ),
              const SizedBox(width: 8),
              OutlinedButton.icon(
                key: const ValueKey('spider-local-sources-open'),
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => LocalSourcesPage(state: _state),
                  ),
                ),
                icon: const Icon(Icons.folder_copy_outlined, size: 18),
                label: const Text('本地源'),
              ),
              const SizedBox(width: 8),
              OutlinedButton.icon(
                onPressed: _scanning ? null : _rescan,
                icon: const Icon(Icons.refresh, size: 18),
                label: const Text('重新扫描'),
              ),
            ],
          ),
          const SizedBox(height: 8),
          _IsolationNotice(),
          const SizedBox(height: 16),
          _SectionTitle('T3 桌面 JAR 站源（csp_*）'),
          _CspJarIntakeCard(state: _state),
          const SizedBox(height: 24),
          _SectionTitle('已安装的本地 Spider（${local.length}）'),
          if (local.isEmpty)
            const SectionEmpty(
              icon: Icons.extension_outlined,
              title:
                  '未发现本地 Spider。把 manifest.json 放在配置目录的 spiders/ 下，'
                  '并在站点 api 中使用 spider-local:<key> 引用。',
            ),
          for (final spider in local) _LocalSpiderCard(spider: spider),
          const SizedBox(height: 24),
          _SectionTitle('运行时状态（${runtimes.length}）'),
          if (runtimes.isEmpty)
            const SectionEmpty(
              icon: Icons.memory_outlined,
              title: '本次会话还没有站点启动过 Spider 运行时。',
            ),
          for (final runtime in runtimes)
            _RuntimeCard(
              status: runtime,
              onStop: () => _state.stopSpider(runtime.siteKey),
              onReset: () => _state.resetSpider(runtime.siteKey),
            ),
          const SizedBox(height: 24),
          _SectionTitle('本地代理（§11）'),
          _ProxyCard(state: _state),
          const SizedBox(height: 16),
        ],
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Text(text, style: Theme.of(context).textTheme.titleMedium),
  );
}

/// 隔离等级声明（§18.2.1 要求如实标记，不得宣称强隔离）。
class _IsolationNotice extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      color: scheme.surfaceContainerHighest,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.shield_outlined, color: scheme.primary, size: 20),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    '隔离等级:进程隔离 + 尽力隔离(不是沙箱)',
                    style: TextStyle(fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Spider 在独立子进程中运行,主进程只通过 stdio 帧通信,不加载任何'
                    '不可信代码;Windows 下用 Job Object 限制内存与 CPU 时间,并保证'
                    '崩溃时连同子进程树一并终止。\n'
                    '但 Job Object 不提供文件系统与网络沙箱:sidecar 仍能读取当前用户'
                    '可访问的文件并发起出站连接。因此本产品默认只运行本机已存在的'
                    'Spider 代码,不自动下载远程脚本;启用第三方 Spider 前请自行确认来源。',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _LocalSpiderCard extends StatelessWidget {
  const _LocalSpiderCard({required this.spider});

  final LocalSpider spider;

  @override
  Widget build(BuildContext context) {
    final manifest = spider.manifest;
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    '${manifest.name}（key=${manifest.key}）',
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                ),
                Chip(
                  label: Text(manifest.runtime),
                  visualDensity: VisualDensity.compact,
                ),
                if (!spider.entryExists)
                  Padding(
                    padding: const EdgeInsets.only(left: 8),
                    child: Chip(
                      label: const Text('入口缺失'),
                      visualDensity: VisualDensity.compact,
                      backgroundColor: Theme.of(context).colorScheme.errorContainer,
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 6),
            Text('ABI:${manifest.abi} minor=${manifest.abiMinor}'),
            Text('能力:${manifest.capabilities.sorted.join(", ")}'),
            Text(
              '权限:network=${manifest.permissions.network} '
              'localProxy=${manifest.permissions.localProxy} '
              'storage=${manifest.permissions.storage} '
              'ui=${manifest.permissions.ui} '
              'process=${manifest.permissions.process} '
              'browser=${manifest.permissions.browser}',
            ),
            Text(
              '限制:memory=${manifest.limits.memoryMiB}MiB '
              'cpu=${manifest.limits.cpuSeconds}s '
              '并发=${manifest.limits.concurrency} '
              '响应=${manifest.limits.responseMiB}MiB '
              '单帧=${manifest.limits.maxFrameMiB}MiB',
            ),
            if (manifest.permissions.violations.isNotEmpty)
              Text(
                '权限越界:${manifest.permissions.violations.join(", ")}（该 manifest 会被拒绝加载）',
                style: TextStyle(
                  color: Theme.of(context).colorScheme.error,
                ),
              ),
            const SizedBox(height: 4),
            Text(
              spider.entryPath,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}

class _RuntimeCard extends StatelessWidget {
  const _RuntimeCard({
    required this.status,
    required this.onStop,
    required this.onReset,
  });

  final SpiderRuntimeStatus status;
  final VoidCallback onStop;
  final VoidCallback onReset;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final running = status.state == SpiderRuntimeState.running;
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    status.siteKey,
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                ),
                Chip(
                  label: Text(status.stateLabel),
                  visualDensity: VisualDensity.compact,
                  backgroundColor: switch (status.state) {
                    SpiderRuntimeState.running => scheme.primaryContainer,
                    SpiderRuntimeState.crashed ||
                    SpiderRuntimeState.failed => scheme.errorContainer,
                    SpiderRuntimeState.backoff => scheme.tertiaryContainer,
                    _ => null,
                  },
                ),
                const SizedBox(width: 8),
                TextButton(
                  onPressed: running ? onStop : null,
                  child: const Text('强制停止'),
                ),
                TextButton(
                  onPressed: status.failureCount > 0 ? onReset : null,
                  child: const Text('重置'),
                ),
              ],
            ),
            if (status.manifest != null)
              Text(
                'ABI:${status.manifest!.abi} minor=${status.manifest!.abiMinor} '
                'runtime=${status.manifest!.runtime}',
              ),
            if (status.initResult != null)
              Text(
                '已协商能力:${(status.initResult!.capabilities.toList()..sort()).join(", ")}',
              ),
            if (status.isolation != null)
              Text('隔离:${status.isolation!.level} '
                  '机制=${status.isolation!.mechanisms.join("+")}'),
            if (status.isolation != null)
              for (final limitation in status.isolation!.limitations)
                Text(
                  '边界:$limitation',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
            if (status.failureCount > 0)
              Text('失败次数:${status.failureCount} '
                  '退避=${status.restartDelay.inMilliseconds}ms'),
            if (status.lastError != null)
              Text(
                '最近错误:${status.lastError}',
                style: TextStyle(color: scheme.error),
              ),
            if (status.stderrLines.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  'stderr(已脱敏,末 3 行):\n'
                  '${status.stderrLines.reversed.take(3).toList().reversed.join("\n")}',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _ProxyCard extends StatelessWidget {
  const _ProxyCard({required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              state.proxyRunning
                  ? '运行中:${state.proxyBaseUrl}（仅监听 127.0.0.1）'
                  : '未启动（首次需要 Header 注入的播放会自动启动）',
            ),
            Text('活跃会话:${state.proxySessions.activeSessions.length}'),
            if (state.proxySessionFingerprint != null)
              Text('当前播放 token 指纹:${state.proxySessionFingerprint}'),
            const SizedBox(height: 8),
            Row(
              children: [
                FilledButton(
                  onPressed: state.proxyRunning ? null : () => state.startProxy(),
                  child: const Text('启动代理'),
                ),
                const SizedBox(width: 8),
                OutlinedButton(
                  onPressed: state.proxyRunning ? () => state.stopProxy() : null,
                  child: const Text('停止并释放端口'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// T3（`csp_*`）桌面 JAR 站源入口（ADR-0002、docs/reference/win-box-borrowings.md §12.6/§12.9）。
///
/// 两条路径：
/// - **自动探测**：配置里已经把 jar 写成远端地址时，程序自己取回、静态检测、
///   通过就装好；不通过只写结论（`probe.json`），站点列表直接显示真实原因。
///   用户不需要手工「迁移」任何文件（2026-10-24 用户诉求）。
/// - **手工导入**：用户本机已有 jar / 类目录时，填路径拷进
///   `<config>/spiders/csp/<siteKey>/`。
///
/// 两条路径共用的纪律：
/// - 导入前先静态检测（zip 目录项 + 文件树，不加载类、不执行代码）；
/// - 含**原生库**（`lib/*.so`）或无法解析的入口**一律拒绝且不落盘**；
///   含 `classes.dex` 且**无**原生库的入口**可以导入**，导入时先做预转译
///   （首次可能数秒，之后命中缓存）；两类结论的文案都指向 ADR-0002；
/// - 已导入条目可一键移除（回滚到「缺少桌面 JVM 站源」）。
///
/// 诚实预期（§12.6.5）：社区 T3 jar 里绝大多数含 dex 或继承 Android/CatVod 基类，
/// 自动探测不会让它们变得可用；它只保证「该能跑的那批自己跑起来」与
/// 「不能跑的那批原因写在用户看得到的地方」。
class _CspJarIntakeCard extends StatefulWidget {
  const _CspJarIntakeCard({required this.state});

  final AppState state;

  @override
  State<_CspJarIntakeCard> createState() => _CspJarIntakeCardState();
}

class _CspJarIntakeCardState extends State<_CspJarIntakeCard> {
  final TextEditingController _path = TextEditingController();
  final TextEditingController _siteKey = TextEditingController();
  JarInspection? _preview;
  CspProbeReport? _report;
  String? _message;
  bool _busy = false;

  /// `_busy` 期间的可见提示：让用户知道在做什么（导入含 dex 的入口会预转译数秒）。
  String _busyNote = '';

  @override
  void dispose() {
    _path.dispose();
    _siteKey.dispose();
    super.dispose();
  }

  AppState get _state => widget.state;

  void _onInspect() {
    final path = _path.text.trim();
    if (path.isEmpty) {
      setState(() => _message = '请先填写 jar 或类目录的绝对路径');
      return;
    }
    final key = _siteKey.text.trim();
    setState(() {
      _preview = _state.inspectCspSource(
        path,
        siteKey: key.isEmpty ? null : key,
      );
      _message = null;
    });
  }

  Future<void> _onImport() async {
    final path = _path.text.trim();
    final key = _siteKey.text.trim();
    if (path.isEmpty || key.isEmpty) {
      setState(() => _message = '导入需要同时填写站点 key（例 csp_Demo）与入口路径');
      return;
    }
    setState(() {
      _busy = true;
      _busyNote = '正在导入并预转译 dex（可能数秒）…';
      _message = null;
    });
    final result = await _state.importCspJar(siteKey: key, sourcePath: path);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _preview = result.inspection ?? _preview;
      if (!result.ok) {
        _message = '未导入：${result.error}';
        return;
      }
      final dex = result.dexTranslation;
      if (dex == null) {
        // 非 dex 入口（桌面 jar / 类目录）：没有转译这一步，文案不变。
        _message = '已导入到 ${result.targetPath}';
      } else if (dex['ok'] == true) {
        final classes = dex['classCount']?.toString() ?? '?';
        final cached = dex['cached'] == true ? '（命中缓存）' : '';
        _message = '已导入到 ${result.targetPath}；dex 已转译 $classes 个类$cached';
      } else {
        // 落盘成功但预转译失败：如实报告，不谎称可用。
        final stage = dex['stage']?.toString().trim() ?? '';
        final detail = dex['message']?.toString().trim() ?? '';
        _message =
            '已导入到 ${result.targetPath}，但 dex 预转译失败'
            '${stage.isEmpty ? '' : '（$stage）'}：'
            '${detail.isEmpty ? '未给出原因' : detail}；'
            '站点可能不可用，详见 ${result.targetPath} 下的 intake.json。';
      }
    });
  }

  /// 自动探测：配置里声明的 csp_* jar 由程序取回 + 静态检测（§12.9）。
  Future<void> _onProbe() async {
    setState(() {
      _busy = true;
      _busyNote = '正在取回并静态检测配置里的 jar…';
      _message = null;
    });
    final report = await _state.probeCspJars();
    if (!mounted) return;
    setState(() {
      _busy = false;
      _report = report;
      _message = report.isEmpty
          ? '没有需要自动探测的 csp_* 站点（配置里未声明 jar，或已全部导入）。'
          : '自动探测完成：已装 ${report.installed} 个、拒绝 ${report.rejected} 个、失败 ${report.failed} 个。';
    });
  }

  Future<void> _onRemove(String siteKey) async {
    setState(() {
      _busy = true;
      _busyNote = '正在移除站源…';
      _message = null;
    });
    final removed = await _state.removeCspJar(siteKey);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _message = removed ? '已移除 $siteKey' : '移除失败：$siteKey';
    });
  }

  static String _outcomeLabel(CspProbeOutcome outcome) => switch (outcome) {
    CspProbeOutcome.skippedInstalled => '已装过，跳过',
    CspProbeOutcome.installed => '已自动装入',
    CspProbeOutcome.rejected => '已拒绝（见原因）',
    CspProbeOutcome.failed => '取回/写入失败',
    CspProbeOutcome.noSource => '配置未声明 jar',
  };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final installed = _state.installedCspJars;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '配置里把 jar 写成远端地址时（如 spring.jar），点「自动探测」由程序取回并静态检测：'
              '能加载的自动装到 ${_state.cspRoot}，不能加载的原因直接显示在站点列表。'
              '也可手工导入本机已有的 jar / 类目录。含 classes.dex 的 Android 站源可以导入，'
              '导入时会预转译（首次约数秒）；只支持不依赖 Android UI 的站源，'
              '依赖 UI 的会被拒绝并指出缺失的类（ADR-0002）。',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                FilledButton.tonalIcon(
                  key: const ValueKey('csp-jar-probe'),
                  onPressed: _busy ? null : _onProbe,
                  icon: const Icon(Icons.travel_explore, size: 18),
                  label: const Text('自动探测配置里的 jar'),
                ),
              ],
            ),
            const SizedBox(height: 8),
            TextField(
              key: const ValueKey('csp-jar-path'),
              controller: _path,
              decoration: const InputDecoration(
                labelText: '入口路径（jar 文件或含 .class 的目录）',
                border: OutlineInputBorder(),
                isDense: true,
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              key: const ValueKey('csp-jar-site-key'),
              controller: _siteKey,
              decoration: const InputDecoration(
                labelText: '站点 key（例 csp_Demo，须与配置里的 api 一致）',
                border: OutlineInputBorder(),
                isDense: true,
              ),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                OutlinedButton.icon(
                  key: const ValueKey('csp-jar-inspect'),
                  onPressed: _busy ? null : _onInspect,
                  icon: const Icon(Icons.search, size: 18),
                  label: const Text('仅检测'),
                ),
                const SizedBox(width: 8),
                FilledButton.icon(
                  key: const ValueKey('csp-jar-install'),
                  onPressed: _busy ? null : _onImport,
                  icon: const Icon(Icons.add_circle_outline, size: 18),
                  label: const Text('检测并导入'),
                ),
                if (_busy) ...[
                  const SizedBox(width: 12),
                  const SizedBox(
                    width: 16,
                    height: 16,
                    child: LoadingBlock(center: false, size: 16),
                  ),
                  if (_busyNote.isNotEmpty) ...[
                    const SizedBox(width: 8),
                    Flexible(
                      child: Text(
                        _busyNote,
                        style: theme.textTheme.bodySmall,
                      ),
                    ),
                  ],
                ],
              ],
            ),
            if (_message != null) ...[
              const SizedBox(height: 8),
              Text(_message!, style: theme.textTheme.bodySmall),
            ],
            if (_preview != null) ...[
              const SizedBox(height: 8),
              Text(
                '检测结论（${_preview!.verdict.name}）',
                style: theme.textTheme.titleSmall,
              ),
              const SizedBox(height: 4),
              Text(_preview!.summary, style: theme.textTheme.bodySmall),
              Text(
                '入口：${_preview!.sourcePath}',
                style: theme.textTheme.bodySmall,
              ),
            ],
            if (_report != null && !_report!.isEmpty) ...[
              const SizedBox(height: 12),
              Text('自动探测结论', style: theme.textTheme.titleSmall),
              for (final entry in _report!.entries)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              '${entry.siteKey} · ${_outcomeLabel(entry.outcome)}',
                              style: theme.textTheme.bodyMedium,
                            ),
                          ),
                          if (entry.inspection != null)
                            Chip(
                              label: Text(
                                entry.inspection!.installable ? '可加载' : '不可加载',
                              ),
                              visualDensity: VisualDensity.compact,
                              backgroundColor: entry.inspection!.installable
                                  ? null
                                  : scheme.errorContainer,
                            ),
                        ],
                      ),
                      if (entry.message.isNotEmpty)
                        Text(
                          entry.message,
                          style: theme.textTheme.bodySmall,
                        ),
                    ],
                  ),
                ),
            ],
            const SizedBox(height: 12),
            Text(
              '已导入（${installed.length}）',
              style: theme.textTheme.titleSmall,
            ),
            if (installed.isEmpty)
              Text(
                '还没有导入任何 T3 桌面站源。',
                style: theme.textTheme.bodySmall,
              ),
            for (final jar in installed)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            '${jar.siteKey} · ${jar.inspection.verdict.name}',
                            style: theme.textTheme.bodyMedium,
                          ),
                        ),
                        Chip(
                          label: Text(
                            jar.inspection.installable ? '可加载' : '不可加载',
                          ),
                          visualDensity: VisualDensity.compact,
                          backgroundColor: jar.inspection.installable
                              ? null
                              : scheme.errorContainer,
                        ),
                        const SizedBox(width: 8),
                        TextButton(
                          key: ValueKey('csp-jar-remove-${jar.siteKey}'),
                          onPressed: _busy ? null : () => _onRemove(jar.siteKey),
                          child: const Text('移除'),
                        ),
                      ],
                    ),
                    Text(jar.entryPath, style: theme.textTheme.bodySmall),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}