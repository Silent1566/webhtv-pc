import 'package:flutter/material.dart';

import '../services/csp_jar_probe.dart';
import '../services/unidbg_runtime.dart';
import '../state/app_state.dart';
import 'settings_layout.dart';
import 'tokens.dart';

/// 加固壳解包运行时（unidbg 0.9.9）的设置页。
///
/// 为什么需要独立入口：加固壳站源（jar 内 ARM 加密 payload）首次使用前必须先有解包
/// 运行时，而下载**必须由用户触发**（约 40.7 MB，四镜像回退 + 逐文件 SHA-256）。此前
/// 下载按钮只长在 Spider 管理页的探测卡片里，用户在站点列表看到「需先下载解包运行时」
/// 之后找不到它——这一页就是那个落点。
class ShellRuntimePage extends StatefulWidget {
  const ShellRuntimePage({super.key, required this.state});

  final AppState state;

  @override
  State<ShellRuntimePage> createState() => _ShellRuntimePageState();
}

class _ShellRuntimePageState extends State<ShellRuntimePage> {
  bool _busy = false;
  String _note = '';
  String? _message;

  AppState get _state => widget.state;

  Future<void> _install() async {
    setState(() {
      _busy = true;
      _note = '正在下载解包运行时（${CspJarProbe.shellRuntimeSizeLabel}）…';
      _message = null;
    });
    final result = await _state.installShellRuntime(
      onProgress: (UnidbgRuntimeProgress progress) {
        if (!mounted) return;
        setState(() {
          _note =
              '正在下载 ${progress.file}（${progress.fileIndex}/${progress.fileCount}，'
              '${(progress.bytesDone / (1024 * 1024)).toStringAsFixed(1)} MB）…';
        });
      },
    );
    if (!mounted) return;
    setState(() {
      _busy = false;
      _note = '';
      _message = result.installed
          ? '已安装到 ${result.dir}。回到站点列表点「自动探测配置里的 jar」即可解包。'
          : '下载失败：${result.error ?? '原因未知'}';
    });
  }

  Future<void> _remove() async {
    setState(() {
      _busy = true;
      _note = '正在删除…';
      _message = null;
    });
    await _state.removeShellRuntime();
    if (!mounted) return;
    setState(() {
      _busy = false;
      _note = '';
      _message = '已删除。已解包的站点不受影响，只是不能再解新的壳。';
    });
  }

  Future<void> _probe() async {
    setState(() {
      _busy = true;
      _note = '正在重新探测配置里的 jar…';
      _message = null;
    });
    final report = await _state.probeCspJars();
    if (!mounted) return;
    setState(() {
      _busy = false;
      _note = '';
      _message = report.isEmpty
          ? '没有需要探测的 csp_* 站点。'
          : '探测完成：解包装好 ${report.unpacked} 个、需运行时 ${report.needsShellRuntime} 个、'
                '解包失败 ${report.unpackFailed} 个、直接装入 ${report.installed} 个。';
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final installed = _state.shellRuntimeInstalled;
    return SettingsDetailScaffold(
      title: '加固壳解包运行时',
      description:
          '部分 TVBox / 猫源配置把站源 jar 做成「加固壳」：classes.dex 只是加载层，真实 '
          'Spider 被加密在 assets/*.guard 里，只能由壳内的 ARM 原生库解出。装上这里的运行时后，'
          '程序会在导入期用 unidbg 模拟 AArch64 解包一次，把结果按壳 jar 的 SHA-256 缓存成普通 '
          'jar，再走既有 dex 转译与侧车加载。',
      children: [
        SettingsSection(
          title: '状态',
          children: [
            SettingsRowList(
              children: [
                ListTile(
                  leading: Icon(
                    installed ? Icons.check_circle_outline : Icons.cloud_download_outlined,
                  ),
                  title: Text(installed ? '已安装' : '未安装'),
                  subtitle: Text(
                    installed
                        ? _state.shellRuntime.dir
                        : '需要时再下载：${CspJarProbe.shellRuntimeSizeLabel}。不下载不影响其它站源。',
                  ),
                ),
              ],
            ),
          ],
        ),
        const SizedBox(height: AppSpace.lg),
        Text(
          '边界：只支持已识别的壳配方（当前 wex/shinidie）；壳内 native 能力（如自带的'
          '加解密辅助）在桌面端仍缺失，调用时会如实报错，不会静默降级。',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: AppSpace.lg),
        Wrap(
          spacing: AppSpace.md,
          runSpacing: AppSpace.sm,
          children: [
            if (!installed)
              FilledButton.icon(
                key: const ValueKey('shell-runtime-install'),
                onPressed: _busy ? null : _install,
                icon: const Icon(Icons.download, size: 18),
                label: const Text('下载解包运行时'),
              )
            else
              OutlinedButton.icon(
                key: const ValueKey('shell-runtime-remove'),
                onPressed: _busy ? null : _remove,
                icon: const Icon(Icons.delete_outline, size: 18),
                label: const Text('删除运行时'),
              ),
            OutlinedButton.icon(
              key: const ValueKey('shell-runtime-probe'),
              onPressed: _busy ? null : _probe,
              icon: const Icon(Icons.travel_explore, size: 18),
              label: const Text('重新探测配置里的 jar'),
            ),
          ],
        ),
        if (_busy) ...[
          const SizedBox(height: AppSpace.md),
          Row(
            children: [
              const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              const SizedBox(width: AppSpace.sm),
              Expanded(child: Text(_note, style: theme.textTheme.bodySmall)),
            ],
          ),
        ],
        if (_message != null) ...[
          const SizedBox(height: AppSpace.md),
          Text(_message!),
        ],
      ],
    );
  }
}