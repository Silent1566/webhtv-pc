import 'package:flutter/material.dart';

import '../services/csp_jar_probe.dart';
import '../services/python_environment.dart';
import '../services/unidbg_runtime.dart';
import '../state/app_state.dart';
import 'python_environment_page.dart';
import 'settings_layout.dart';
import 'shell_runtime_page.dart';

/// 区块里的一行 = 一个**按需**获取的外部组件。
///
/// 用记录而不是新控件：行本身完全由 [SettingsNavRow] 画，这里只描述
/// 「图标 / 标题 / 一句话状态 / 点进哪一页」四件事。
typedef RuntimeDependencyRow = ({
  IconData icon,
  String title,
  String subtitle,
  VoidCallback onTap,
});

/// 「运行时与外部依赖」区块页。
///
/// 为什么收成一个区块：加固壳解包运行时、Python 运行时，以及将来的 Node / JRE
/// 都是**同一种东西**——本地程序运行时、按需获取、装不装只影响对应类型的站源。
/// 它们原先散在各分类里，用户看到「需要先下载运行时」之后还得猜去哪一组找。
///
/// 扩展方式见 [_rows]：**新增同类依赖只加一条记录**，页面骨架、说明与分组不动。
class RuntimeDependenciesPage extends StatefulWidget {
  const RuntimeDependenciesPage({
    super.key,
    required this.state,
    this.shellRuntimeInstalled,
    this.pythonEnvironmentStatus,
  });

  final AppState state;

  /// 状态来源的测试注入点；生产路径恒为 `null`（见下）。
  ///
  /// 为什么要注入：真实状态里「加固壳已装」要读 18 个 jar 的磁盘目录、
  /// 「Python 已就绪」要先探测解释器，widget 测试两件事都不该去碰。
  final bool Function()? shellRuntimeInstalled;
  final PythonEnvironmentStatus? Function()? pythonEnvironmentStatus;

  @override
  State<RuntimeDependenciesPage> createState() =>
      _RuntimeDependenciesPageState();
}

class _RuntimeDependenciesPageState extends State<RuntimeDependenciesPage> {
  AppState get _state => widget.state;

  @override
  void initState() {
    super.initState();
    _state.addListener(_onStateChanged);
  }

  @override
  void didUpdateWidget(RuntimeDependenciesPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.state != widget.state) {
      oldWidget.state.removeListener(_onStateChanged);
      widget.state.addListener(_onStateChanged);
    }
  }

  @override
  void dispose() {
    _state.removeListener(_onStateChanged);
    super.dispose();
  }

  /// 装/删运行时都会走 `AppState` 的通知：本页的「已安装/未安装」跟着刷新，
  /// 不要求用户退出去再进来一次。
  void _onStateChanged() {
    if (!mounted) return;
    setState(() {});
  }

  bool get _shellRuntimeInstalled =>
      (widget.shellRuntimeInstalled ?? () => _state.shellRuntimeInstalled)();

  PythonEnvironmentStatus? get _pythonStatus =>
      (widget.pythonEnvironmentStatus ?? () => _state.pythonEnvironmentStatus)();

  @override
  Widget build(BuildContext context) => SettingsDetailScaffold(
    title: '运行时与外部依赖',
    description:
        '这些是按需获取的外部组件：装不装只影响对应类型的站源，其余功能不受影响。'
        '状态与操作都在各自的下一级页面里，本页只做汇总入口。',
    children: [
      SettingsSection(
        title: '可选运行时',
        description: '未安装时这类站源用不了，其余站源照常工作；没有任何自动下载。',
        children: [
          SettingsRowList(
            children: [
              for (final row in _rows(context))
                SettingsNavRow(
                  icon: row.icon,
                  title: row.title,
                  subtitle: row.subtitle,
                  onTap: row.onTap,
                ),
            ],
          ),
        ],
      ),
    ],
  );

  /// 区块的**唯一**结构点。
  ///
  /// 新增同类依赖（Node / JRE / …）时只在这里加一条记录：图标、标题、
  /// 一句话状态与「点进哪一页」都写在同一条里，页面其余部分零改动。
  List<RuntimeDependencyRow> _rows(BuildContext context) {
    final state = widget.state;
    final shellInstalled = _shellRuntimeInstalled;
    final python = _pythonStatus;
    return <RuntimeDependencyRow>[
      (
        icon: Icons.lock_open_outlined,
        title: '加固壳解包运行时',
        // 状态放最前：窄窗单行会截断尾部，被截断的应该是版本号而不是「已安装」。
        subtitle: shellInstalled
            ? '已安装 · unidbg ${UnidbgRuntime.version} · '
                  '${CspJarProbe.shellRuntimeSizeLabel}'
            : '未安装 · unidbg ${UnidbgRuntime.version}'
                  '（${CspJarProbe.shellRuntimeSizeLabel}），加固壳 jar 源需要它',
        onTap: () => _push(context, ShellRuntimePage(state: state)),
      ),
      (
        icon: Icons.terminal_outlined,
        title: 'Python 运行时（CatVod 依赖）',
        subtitle: _pythonSubtitle(python),
        onTap: () => _push(context, PythonEnvironmentPage(state: state)),
      ),
    ];
  }

  /// Python 状态的一句话：本页只说「能不能用」。来源、解释器路径与缺哪个包
  /// 属于下一级的运行环境页，不在这里重复。
  String _pythonSubtitle(PythonEnvironmentStatus? status) {
    if (status == null) return '未检测 · 点进可检测或修复内置依赖';
    return status.ready ? '已就绪 · Python 站源可用' : '不可用 · Python 站源暂不可用，点进可修复';
  }

  void _push(BuildContext context, Widget page) {
    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => page));
  }
}
