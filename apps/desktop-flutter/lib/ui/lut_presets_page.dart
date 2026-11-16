/// LUT 滤镜三级明细页（设置 → 播放 → LUT 滤镜）。
///
/// 和 PlaybackOptionsPage 同一级、同一壳（SettingsDetailScaffold），只是内容换成
/// LutPresetBrowser。为什么要有这一页：DESIGN.md 的约定是「右键菜单里的每一项
/// 都要有等价入口」，而 LUT 此前只挂在右键菜单上。
///
/// 三处入口的分工：
/// - 右键「画面 → LUT 滤镜」的**飞出子列** = 播放中快速切换（不离开画面）；
/// - **底部面板** = 播放中搜索/导入（也不离开画面）；
/// - **本页** = 设置里的管理入口。
///
/// 依赖刻意收窄成 store + options + onChanged：本页对 AppState 的需要本来只有
/// 「读一份播放参数、写回一份」，收窄之后组件测试不必拉起整套 AppState
/// （数据库、日志、定时器），否则一条 UI 用例会跑十几秒还容易挂住。
library;

import 'package:flutter/material.dart';

import '../core/lut.dart';
import '../core/player_options.dart';
import '../services/lut_store.dart';
import 'lut_preset_browser.dart';
import 'settings_layout.dart';

/// 把一次选择落成新的播放参数（纯函数 + 一次落盘，便于直接单测）。
///
/// 内置项要先 materialize 成真实文件——mpv 的 lut3d 只吃路径；
/// 用户项本身就是磁盘文件，原样写入并清空 preset id。
/// 落盘失败会抛 [LutStoreException]，调用方据此提示，**不**产生半个设置。
Future<PlayerOptions> resolveLutSelection({
  required PlayerOptions current,
  required LutPreset preset,
  required LutStore store,
}) async {
  final path = await store.materialize(preset);
  return current.copyWith(
    lutPath: path,
    lutPresetId: preset.isBundled ? preset.id : '',
  );
}

class LutPresetsPage extends StatefulWidget {
  const LutPresetsPage({
    super.key,
    required this.store,
    required this.options,
    required this.onChanged,
  });

  final LutStore store;
  final PlayerOptions options;

  /// 选择变化时回写（设置页接线到 AppState.setPlayerOptions）。
  final ValueChanged<PlayerOptions> onChanged;

  /// 分类页那一行的副标题：当前是哪个预设 / 未启用。
  static String summary(PlayerOptions options) {
    if (!options.hasLut) return '未启用';
    final builtin = findBuiltinLut(options.lutPresetId);
    if (builtin != null) {
      return '当前：${builtin.name} · ${builtin.sizeLabel}';
    }
    return '当前：${lutIdFromPath(options.lutPath)}';
  }

  @override
  State<LutPresetsPage> createState() => _LutPresetsPageState();
}

class _LutPresetsPageState extends State<LutPresetsPage> {
  late PlayerOptions _options = widget.options;
  bool _applying = false;

  @override
  void didUpdateWidget(covariant LutPresetsPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 外部改了参数（用户在播放页切了滤镜）时跟上，避免页面显示旧档位。
    if (widget.options != oldWidget.options) _options = widget.options;
  }

  Future<void> _apply(LutPreset preset) async {
    if (_applying) return;
    setState(() => _applying = true);
    try {
      final next = await resolveLutSelection(
        current: _options,
        preset: preset,
        store: widget.store,
      );
      if (!mounted) return;
      setState(() => _options = next);
      widget.onChanged(next);
    } on LutStoreException catch (error) {
      _toast('LUT 不可用：${error.message}');
    } catch (error) {
      _toast('LUT 应用失败：$error');
    } finally {
      if (mounted) setState(() => _applying = false);
    }
  }

  void _clear() {
    final next = _options.copyWith(lutPath: '', lutPresetId: '');
    setState(() => _options = next);
    widget.onChanged(next);
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), behavior: SnackBarBehavior.floating),
    );
  }

  @override
  Widget build(BuildContext context) {
    return SettingsDetailScaffold(
      title: 'LUT 滤镜',
      description:
          '内置预设随安装包分发，选中后先写入缓存目录再交给 mpv 的 lut3d 滤镜；'
          '导入与在线下载的 .cube 保存在应用数据目录，可随时删除。',
      children: [
        // 不画进度条：内置落盘就是一次本地写（毫秒级），不定态进度条会一直转，
        // 视觉上比没有更吵；真正的耗时操作（下载）在浏览器内部有自己的指示器。
        // _applying 只留作「防连点」的重入闸。
        LutPresetBrowser(
          store: widget.store,
          currentPath: _options.lutPath.trim(),
          currentPresetId: _options.lutPresetId,
          showHeader: false,
          onSelect: _apply,
          onCleared: _clear,
        ),
        const SizedBox(height: 24),
      ],
    );
  }
}
