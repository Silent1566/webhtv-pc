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

import '../services/spider_process.dart';
import '../services/spider_registry.dart';
import '../state/app_state.dart';

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
                child: CircularProgressIndicator(strokeWidth: 2),
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
          _SectionTitle('已安装的本地 Spider（${local.length}）'),
          if (local.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 8),
              child: Text(
                '未发现本地 Spider。把 manifest.json 放在配置目录的 spiders/ 下，'
                '并在站点 api 中使用 spider-local:<key> 引用。',
              ),
            ),
          for (final spider in local) _LocalSpiderCard(spider: spider),
          const SizedBox(height: 24),
          _SectionTitle('运行时状态（${runtimes.length}）'),
          if (runtimes.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 8),
              child: Text('本次会话还没有站点启动过 Spider 运行时。'),
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