/// 弹幕设置明细页（Phase 9 · P1）。
///
/// 为什么把两件事收进一页：显示参数原先只挂在播放器底部弹层里（「点一下跳下一
/// 档」是弹层省竖向空间的妥协），弹幕库又另开一页「弹幕源」；同一件事散在两个
/// 入口，用户要么找不到地址，要么以为显示参数只属于播放器。现在
/// 「设置 → 弹幕 → 弹幕设置」是唯一落点，播放器内的入口由 P2 接入。
///
/// 为什么弹幕库排在显示参数**前面**：地址与自动搜索是「能不能搜到」的前置条件，
/// 顺序上先给前置条件；旧页只有这一块，排在顶部也让老用户回来时少滚一段。
///
/// 为什么「弹幕库地址」变成「弹幕源列表」：单个地址只能绑一个中转，多配一个就得
/// 覆盖旧的（S1 已把设置里的地址升级成 `sources` 列表）。页面因此按列表渲染，
/// 每条自带名称与启停；旧单地址已由 `DanmakuSettings.fromJson` 迁移成一条
/// 「默认」，所以这里不再保留单地址入口——留着就是两个改地址的地方。
library;

import 'package:flutter/material.dart';

import '../core/danmaku_settings.dart';
import '../core/danmaku_style.dart';
import '../state/app_state.dart';
import 'settings_detail_pages.dart';
import 'settings_layout.dart';
import 'tokens.dart';

/// 「自定义…」的哨兵值：合法时长最小 2s，-1 不会与任何档位撞值。
const int _customDurationOption = -1;

/// 自定义时长的合法区间（秒），与 core 的 2000..60000 ms 夹取区间同口径。
const int _customMinSeconds = 2;
const int _customMaxSeconds = 60;

/// 弹幕设置：显示参数 + 弹幕库，改动即时写盘。
class DanmakuSettingsPage extends StatefulWidget {
  const DanmakuSettingsPage({super.key, required this.state});

  final AppState state;

  /// 分类页副标题：只报「自动搜索是开还是关」与「几个源、从哪来」两个会变的事实。
  ///
  /// 必须读 [AppState.resolvedDanmakuSources]：手填 / 站点配置 / 本地猫源三档
  /// 只有一档是手填的，只看 `danmakuSettings.sources` 会把另外两档误报成未配置；
  /// 而只报「已配置地址」又说不清用户到底配了几条源。
  static String summary(AppState state) {
    final resolved = state.resolvedDanmakuSources;
    final search = state.danmakuSettings.autoSearch ? '自动搜索已开' : '自动搜索已关';
    final address = resolved.isConfigured
        ? '${resolved.sources.length} 个源（${_originLabel(resolved.origin)}）'
        : '未配置';
    return '$search · $address';
  }

  /// 副标题里的来源短名。
  ///
  /// 不复用 [ResolvedDanmakuSources.label]：那一档是「站点配置 danmaku 字段」这种
  /// 长名，塞进一行副标题会被省略号吃掉尾巴，用户看到的反而只剩「…」。
  static String _originLabel(DanmakuApiSource origin) => switch (origin) {
    DanmakuApiSource.user => '手填',
    DanmakuApiSource.config => '站点配置',
    DanmakuApiSource.bundle => '本地猫源',
    DanmakuApiSource.none => '未配置',
  };

  @override
  State<DanmakuSettingsPage> createState() => _DanmakuSettingsPageState();
}

class _DanmakuSettingsPageState extends State<DanmakuSettingsPage> {
  AppState get state => widget.state;

  /// 显示参数立即落盘，失败只记日志、不回滚：当前会话已经按新值渲染，
  /// 回滚只会让滑块自己弹回旧位置，用户看不出刚才那一下到底生没生效
  /// （与其它设置页同一口径）。
  Future<void> _applyStyle(DanmakuStyle next) async {
    final ok = await state.setDanmakuStyle(next);
    if (!ok) {
      state.log.warning('保存弹幕显示设置失败，本次修改只在当前会话生效', scope: 'danmaku');
    }
  }

  /// 返回是否写盘成功：源对话框要靠它决定「关掉还是留着让人再点一次」。
  Future<bool> _applySettings(DanmakuSettings next) async {
    final ok = await state.setDanmakuSettings(next);
    if (!ok) {
      state.log.warning('保存弹幕库设置失败，本次修改只在当前会话生效', scope: 'danmaku');
    }
    return ok;
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: state,
    builder: (context, _) {
      final style = state.danmakuStyle;
      return SettingsDetailScaffold(
        title: '弹幕设置',
        description: '显示参数与弹幕库搜索都在这里；改动即时保存。',
        children: [
          SettingsSection(title: '弹幕库', children: _librarySection(context)),
          SettingsSection(
            title: '显示',
            children: _displaySection(context, style),
          ),
        ],
      );
    },
  );

  /// 弹幕库：自动搜索开关 + 弹幕源列表 + 来源说明。
  ///
  /// 为什么列表排在开关**下方**：开关是「要不要搜」的前置，列表是「去哪儿搜」的
  /// 清单；清单放上面，每次进页都要先滚过一串地址才够得到开关。
  List<Widget> _librarySection(BuildContext context) {
    final settings = state.danmakuSettings;
    final resolved = state.resolvedDanmakuSources;
    final externalNote = _externalSourceNote(resolved);
    return [
      SwitchListTile(
        key: const ValueKey('settings-danmaku-auto-search'),
        dense: true,
        contentPadding: EdgeInsets.zero,
        title: const Text('没有弹幕时自动搜索弹幕库'),
        subtitle: Text(
          resolved.isConfigured
              ? '已配置 ${resolved.sources.length} 个源；搜索失败只提示，不影响播放'
              : '未配置地址：自动搜索不会发请求',
        ),
        // 开关始终可点：允许先打开再去下面添加源。置灰会让人以为顺序反了，
        // 「开关亮着但什么都没发生」也比「点不动」更容易看懂。
        value: settings.autoSearch,
        onChanged: (value) async {
          await _applySettings(settings.copyWith(autoSearch: value));
        },
      ),
      const SizedBox(height: AppSpace.md),
      _sourceListHeader(context, settings),
      if (settings.sources.isEmpty)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: AppSpace.sm),
          child: Text(
            '还没有弹幕源：点「添加」填一条地址',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        )
      else
        for (var index = 0; index < settings.sources.length; index++)
          _sourceTile(context, settings.sources, index),
      if (externalNote != null)
        Padding(
          key: const ValueKey('settings-danmaku-external-source'),
          padding: const EdgeInsets.only(top: AppSpace.sm),
          child: Text(
            externalNote,
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
      // 用户手上真正在用的是 danmu_api 一类中转，地址形态与早期的通用源不同，
      // 因此把「两种都能填」直接写在列表下方，只给示例 URL 会误导成搜索页。
      Padding(
        padding: const EdgeInsets.only(top: AppSpace.sm),
        child: Text(
          '可填 danmu_api / TVBox（FongMi）弹幕接口地址，如 '
          'http://192.168.1.10:9321/TOKEN，只有主机或一段路径时自动补 '
          '/danmaku；也兼容 ?title=&episode= 的通用源。',
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ),
    ];
  }

  /// 外部来源提示：用户没启用自己的源、但站点配置或猫源仍在生效时，必须说清
  /// 「现在真正在用的是它们」。
  ///
  /// 不说的话，空着的手填列表会让人以为自动搜索什么都不会发，于是去别处找问题。
  String? _externalSourceNote(ResolvedDanmakuSources resolved) {
    if (state.danmakuSettings.enabledSources.isNotEmpty) return null;
    return switch (resolved.origin) {
      DanmakuApiSource.config =>
        '当前生效：来自站点配置的 ${resolved.sources.length} 个地址；'
            '添加手动弹幕源会覆盖它们',
      DanmakuApiSource.bundle =>
        '当前生效：来自本地猫源 ${resolved.sources.isEmpty ? '' : resolved.sources.first.url}；'
            '添加手动弹幕源会覆盖它',
      _ => null,
    };
  }

  /// 「弹幕源（N 个启用）」+ 添加按钮。
  ///
  /// 计数说的是**启用**条数而不是总条数：用户关心的是「现在会去搜几个源」，
  /// 停用的那些留在列表里只是备查。
  Widget _sourceListHeader(BuildContext context, DanmakuSettings settings) {
    final theme = Theme.of(context);
    return Row(
      children: [
        Expanded(
          child: Text(
            '弹幕源（${settings.enabledSources.length} 个启用）',
            style: theme.textTheme.bodyLarge,
          ),
        ),
        TextButton.icon(
          key: const ValueKey('settings-danmaku-source-add'),
          onPressed: () => _editSource(context),
          icon: const Icon(Icons.add, size: 18),
          label: const Text('添加'),
        ),
      ],
    );
  }

  /// 一行弹幕源：启用开关 + 名称/地址 + 上移/下移/删除，点行本身进入编辑。
  ///
  /// 为什么把「编辑」放在整行而不是第四个图标：点一行改它是通用心智，而
  /// 名称/地址是这条源的主体信息，塞进一排无标签图标里没人认得出。
  Widget _sourceTile(
    BuildContext context,
    List<DanmakuSourceConfig> sources,
    int index,
  ) {
    final source = sources[index];
    return ListTile(
      key: ValueKey('settings-danmaku-source-${source.id}'),
      dense: true,
      contentPadding: EdgeInsets.zero,
      leading: Switch(
        key: ValueKey('settings-danmaku-source-enabled-${source.id}'),
        value: source.enabled,
        onChanged: (value) async {
          // 以 state 里的最新列表为基准：对话框/其它行可能刚改过它。
          final next = [...sources];
          if (index < next.length && next[index].id == source.id) {
            next[index] = next[index].copyWith(enabled: value);
          }
          await _applySettings(state.danmakuSettings.copyWith(sources: next));
        },
      ),
      title: Text(
        _sourceTitle(source, index),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(
        source.url,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _sourceAction(
            key: ValueKey('settings-danmaku-source-up-${source.id}'),
            icon: Icons.arrow_upward,
            tooltip: '上移',
            // 首/末项置灰：按钮位置不变，用户不用先数「这是第几条」。
            onPressed: index == 0
                ? null
                : () async {
                    await _moveSource(sources, index, -1);
                  },
          ),
          _sourceAction(
            key: ValueKey('settings-danmaku-source-down-${source.id}'),
            icon: Icons.arrow_downward,
            tooltip: '下移',
            onPressed: index == sources.length - 1
                ? null
                : () async {
                    await _moveSource(sources, index, 1);
                  },
          ),
          _sourceAction(
            key: ValueKey('settings-danmaku-source-remove-${source.id}'),
            icon: Icons.delete_outline,
            tooltip: '删除',
            onPressed: () async {
              await _removeSource(sources, index);
            },
          ),
        ],
      ),
      onTap: () => _editSource(context, editing: source),
    );
  }

  Widget _sourceAction({
    required Key key,
    required IconData icon,
    required String tooltip,
    required VoidCallback? onPressed,
  }) => IconButton(
    key: key,
    icon: Icon(icon, size: 18),
    tooltip: tooltip,
    visualDensity: VisualDensity.compact,
    padding: EdgeInsets.zero,
    constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
    onPressed: onPressed,
  );

  /// 标题：名称优先；名称为空（手改 settings.json 遗留）时退到 host。
  String _sourceTitle(DanmakuSourceConfig source, int index) {
    final name = source.name.trim();
    if (name.isNotEmpty) return name;
    return _defaultSourceName(source.url, index);
  }

  /// 名称留空时的兜底：host 比「弹幕源 3」更能让人认出这是哪台机器。
  String _defaultSourceName(String url, int index) {
    final host = (Uri.tryParse(url.trim())?.host ?? '').trim();
    return host.isEmpty ? '弹幕源 ${index + 1}' : host;
  }

  /// 新源的 id：只要在列表里唯一即可（它同时是控件 key 与结果归属标识）。
  ///
  /// 不用时间戳：连续添加两条可能落在同一微秒，撞 key 会让 Flutter 认错 widget。
  String _nextSourceId(List<DanmakuSourceConfig> sources) {
    final used = {for (final source in sources) source.id};
    for (var index = 1; ; index++) {
      final candidate = 'source-$index';
      if (!used.contains(candidate)) return candidate;
    }
  }

  /// 顺序即搜索顺序，也是结果合并顺序，所以上移/下移不是纯装饰。
  Future<void> _moveSource(
    List<DanmakuSourceConfig> sources,
    int index,
    int delta,
  ) async {
    final target = index + delta;
    if (target < 0 || target >= sources.length) return;
    final next = [...sources];
    next.insert(target, next.removeAt(index));
    await _applySettings(state.danmakuSettings.copyWith(sources: next));
  }

  Future<void> _removeSource(
    List<DanmakuSourceConfig> sources,
    int index,
  ) async {
    if (index < 0 || index >= sources.length) return;
    final next = [...sources]..removeAt(index);
    await _applySettings(state.danmakuSettings.copyWith(sources: next));
  }

  /// 添加 / 编辑一条源。
  ///
  /// 为什么这里不像地址那样「输入即保存」：这条对话框有两个字段，逐字写盘会让
  /// 「名称改好了、地址还没填完」的半成品进配置，自动搜索当场就会拿它发请求。
  Future<void> _editSource(
    BuildContext context, {
    DanmakuSourceConfig? editing,
  }) async {
    // id 在**打开对话框时**就定下来：写盘失败后用户点第二次「确定」必须还是同
    // 一条源，否则会凭空多出一条重复地址。编辑沿用原 id，新增取一个空位 id。
    final id = editing?.id ?? _nextSourceId(state.danmakuSettings.sources);
    await showDialog<void>(
      context: context,
      builder: (_) => _DanmakuSourceDialog(
        title: editing == null ? '添加弹幕源' : '编辑弹幕源',
        initialName: editing?.name ?? '',
        initialUrl: editing?.url ?? '',
        validateUrl: (text) =>
            isHttpAddress(text) ? null : '请输入完整的 http 或 https 地址',
        onSave: (name, url) => _saveSource(id, name, url),
      ),
    );
  }

  /// 按 id 写入一条源：已在列表里就改它，不在就追加。
  ///
  /// 按 id 而不是按「新增/编辑」两种模式：写盘失败后内存里已经留下这一条
  /// （页面口径是失败不回滚），重试时再追加就会变成两条。
  Future<bool> _saveSource(String id, String name, String url) {
    final settings = state.danmakuSettings;
    final sources = settings.sources;
    final index = sources.indexWhere((source) => source.id == id);
    final next = [...sources];
    if (index < 0) {
      next.add(
        DanmakuSourceConfig(
          id: id,
          name: name.isEmpty ? _defaultSourceName(url, sources.length) : name,
          url: url,
        ),
      );
    } else {
      next[index] = sources[index].copyWith(
        name: name.isEmpty ? _defaultSourceName(url, index) : name,
        url: url,
      );
    }
    return _applySettings(settings.copyWith(sources: next));
  }

  /// 显示参数：总开关、四个滑块、三个档位下拉、三类弹幕显隐。
  List<Widget> _displaySection(BuildContext context, DanmakuStyle style) {
    return [
      SwitchListTile(
        key: const ValueKey('settings-danmaku-enabled'),
        dense: true,
        contentPadding: EdgeInsets.zero,
        title: const Text('弹幕'),
        subtitle: const Text('总开关；关闭后播放器不再渲染任何弹幕'),
        value: style.enabled,
        onChanged: (value) async {
          await _applyStyle(style.copyWith(enabled: value));
        },
      ),
      _sliderTile(
        context,
        key: const ValueKey('settings-danmaku-opacity'),
        label: '透明度',
        valueText: '${(style.opacity * 100).round()}%',
        value: style.opacity,
        min: 0.1,
        max: 1.0,
        divisions: 9,
        onChanged: (value) async {
          await _applyStyle(style.copyWith(opacity: value));
        },
      ),
      _sliderTile(
        context,
        key: const ValueKey('settings-danmaku-scale'),
        label: '字号',
        valueText: '${(style.textScale * 100).round()}%',
        value: style.textScale,
        min: 0.5,
        max: 2.0,
        divisions: 15,
        onChanged: (value) async {
          await _applyStyle(style.copyWith(textScale: value));
        },
      ),
      _sliderTile(
        context,
        key: const ValueKey('settings-danmaku-stroke'),
        label: '描边',
        valueText: style.strokeWidth == 0
            ? '关闭'
            : style.strokeWidth.toStringAsFixed(1),
        value: style.strokeWidth,
        min: 0.0,
        max: 2.0,
        divisions: 20,
        onChanged: (value) async {
          await _applyStyle(style.copyWith(strokeWidth: value));
        },
      ),
      _sliderTile(
        context,
        key: const ValueKey('settings-danmaku-area'),
        label: '区域',
        valueText: '${(style.areaRatio * 100).round()}%',
        value: style.areaRatio,
        // 区间取 core 的夹取范围（DanmakuStyle.copyWith 夹到 0.2–0.9）：
        // 滑块若放宽到 0.1–1.0，拖到两端会被夹回去，松手时滑块自己弹开。
        min: 0.2,
        max: 0.9,
        divisions: 7,
        onChanged: (value) async {
          await _applyStyle(style.copyWith(areaRatio: value));
        },
      ),
      _durationTile(context, style),
      _dropdownTile(
        key: const ValueKey('settings-danmaku-tracks'),
        title: '行数',
        subtitle: '最多同时占用的弹幕轨道数；不限时只受「区域」限制',
        value: style.maxTracks,
        presets: const [0, 3, 5, 8],
        label: (tracks) => tracks == 0 ? '不限' : '$tracks 行',
        onChanged: (value) async {
          await _applyStyle(style.copyWith(maxTracks: value));
        },
      ),
      _dropdownTile(
        key: const ValueKey('settings-danmaku-offset'),
        title: '时间偏移',
        subtitle: '正数＝弹幕整体延后出现',
        value: style.timeOffsetMs,
        // 每 500ms 一档：±5s 覆盖常见的片头错位，更细的档位用户也感知不到。
        presets: [for (var ms = -5000; ms <= 5000; ms += 500) ms],
        label: _offsetLabel,
        onChanged: (value) async {
          await _applyStyle(style.copyWith(timeOffsetMs: value));
        },
      ),
      _typeSwitch(
        key: const ValueKey('settings-danmaku-show-scroll'),
        title: '滚动弹幕',
        subtitle: '从右向左飞过画面的普通弹幕',
        value: style.showScroll,
        onChanged: (value) async {
          await _applyStyle(style.copyWith(showScroll: value));
        },
      ),
      _typeSwitch(
        key: const ValueKey('settings-danmaku-show-top'),
        title: '顶部弹幕',
        subtitle: '固定在画面上方停留的弹幕',
        value: style.showTop,
        onChanged: (value) async {
          await _applyStyle(style.copyWith(showTop: value));
        },
      ),
      _typeSwitch(
        key: const ValueKey('settings-danmaku-show-bottom'),
        title: '底部弹幕',
        subtitle: '固定在画面下方停留的弹幕',
        value: style.showBottom,
        onChanged: (value) async {
          await _applyStyle(style.copyWith(showBottom: value));
        },
      ),
    ];
  }

  /// 时间偏移的档位文案：0 直接写「0s」，正数带 +，否则 +5s 与 -5s 读起来一样。
  String _offsetLabel(int ms) {
    if (ms == 0) return '0s';
    final seconds = (ms.abs() / 1000)
        .toStringAsFixed(1)
        .replaceFirst(RegExp(r'\.0$'), '');
    return '${ms > 0 ? '+' : '-'}${seconds}s';
  }

  /// 显示参数滑块：标题 + 当前值 + 滑轨。
  ///
  /// 不用播放器里「点一下循环到下一档」：那是弹层省竖向空间的妥协；有一整页
  /// 空间时，连续可调的参数给出滑轨比让人数「点了几下」清楚得多。
  Widget _sliderTile(
    BuildContext context, {
    required Key key,
    required String label,
    required String valueText,
    required double value,
    required double min,
    required double max,
    required int divisions,
    required ValueChanged<double> onChanged,
  }) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpace.xs),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(label, style: theme.textTheme.bodyLarge),
              ),
              Text(
                valueText,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
          Slider(
            key: key,
            // 夹到滑轨区间：手改 settings.json 的字号（core 允许到 2.5）落在
            // 本滑块的 0.5–2.0 之外时，Slider 会直接断言，整页白屏。
            value: value.clamp(min, max),
            min: min,
            max: max,
            divisions: divisions,
            onChanged: onChanged,
          ),
        ],
      ),
    );
  }

  /// 离散档位的行：标题 + 说明 + 右侧下拉。
  ///
  /// 为什么用下拉而不是重复点击：一页里有空间时，下拉能把全部档位一次列清，
  /// 也避免「当前到底在第几档」只能靠多次点击试出来。
  Widget _dropdownTile({
    required Key key,
    required String title,
    required String subtitle,
    required int value,
    required List<int> presets,
    required String Function(int) label,
    required ValueChanged<int> onChanged,
  }) {
    // 当前值必须进候选：手改 settings.json 到预设之外的值（如 7s 速度）时
    // DropdownButton 会直接断言，整页白屏——与播放参数的倍速下拉同一个理由。
    final options = <int>{...presets, value}.toList()..sort();
    return ListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      title: Text(title),
      subtitle: Text(subtitle),
      trailing: DropdownButton<int>(
        key: key,
        value: value,
        underline: const SizedBox.shrink(),
        items: [
          for (final option in options)
            DropdownMenuItem(value: option, child: Text(label(option))),
        ],
        onChanged: (next) {
          if (next == null) return;
          onChanged(next);
        },
      ),
    );
  }

  /// 「速度」行：固定档位 + 末尾「自定义…」。
  ///
  /// 不复用 [_dropdownTile]：那一行只有固定档位，自定义还得再接一个对话框，
  /// 把哨兵分支塞进共享实现，行数/偏移两行就都要背一个用不到的分支。
  Widget _durationTile(BuildContext context, DanmakuStyle style) {
    const presets = <int>[
      6000,
      8000,
      10000,
      12000,
      15000,
      20000,
      30000,
      45000,
      60000,
    ];
    // 当前值必须进候选（理由同 [_dropdownTile]），但哨兵不能被当成当前值：
    // 与「自定义…」项同值时，DropdownButton 会因为两个同值 item 直接断言。
    final current = style.scrollDurationMs;
    final options = <int>{...presets, current}
        .where((ms) => ms != _customDurationOption)
        .toList()
      ..sort();
    return ListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      title: const Text('速度'),
      subtitle: const Text('滚动弹幕穿过画面的时长（越大越慢）'),
      trailing: DropdownButton<int>(
        key: const ValueKey('settings-danmaku-duration'),
        value: options.contains(current) ? current : null,
        underline: const SizedBox.shrink(),
        items: [
          for (final option in options)
            DropdownMenuItem(value: option, child: Text('${option ~/ 1000}s')),
          const DropdownMenuItem(
            value: _customDurationOption,
            child: Text('自定义…'),
          ),
        ],
        onChanged: (next) async {
          if (next == null) return;
          if (next == _customDurationOption) {
            await _editCustomDuration(context, style);
            return;
          }
          await _applyStyle(style.copyWith(scrollDurationMs: next));
        },
      ),
    );
  }

  /// 自定义时长：对话框只校验并返回秒数，落盘仍走 [_applyStyle] 一条链路。
  Future<void> _editCustomDuration(
    BuildContext context,
    DanmakuStyle style,
  ) async {
    final seconds = await showDialog<int>(
      context: context,
      builder: (context) => _DanmakuDurationDialog(
        // 预填一个合法值：手改 settings.json 写到区间外时，一打开就报红更费解。
        initialSeconds: (style.scrollDurationMs / 1000)
            .round()
            .clamp(_customMinSeconds, _customMaxSeconds)
            .toInt(),
      ),
    );
    // 取消返回 null：连值都没有，自然不写盘。
    if (seconds == null) return;
    await _applyStyle(style.copyWith(scrollDurationMs: seconds * 1000));
  }

  Widget _typeSwitch({
    required Key key,
    required String title,
    required String subtitle,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) => SwitchListTile(
    key: key,
    dense: true,
    contentPadding: EdgeInsets.zero,
    title: Text(title),
    subtitle: Text(subtitle),
    value: value,
    onChanged: onChanged,
  );
}

/// 自定义滚动时长的对话框（单位：秒）。
///
/// 与 [_DanmakuSourceDialog] 同一范式：校验不过只在输入框下方出 errorText、
/// 绝不写盘；确定才把秒数交回调用方，取消连值都不返回。
class _DanmakuDurationDialog extends StatefulWidget {
  const _DanmakuDurationDialog({required this.initialSeconds});

  final int initialSeconds;

  @override
  State<_DanmakuDurationDialog> createState() => _DanmakuDurationDialogState();
}

class _DanmakuDurationDialogState extends State<_DanmakuDurationDialog> {
  late final TextEditingController _seconds = TextEditingController(
    text: '${widget.initialSeconds}',
  );
  String? _error;

  @override
  void dispose() {
    _seconds.dispose();
    super.dispose();
  }

  /// 合法＝2..60 的整数；空串、小数、非数字一律不合法。
  int? _parse() {
    final value = int.tryParse(_seconds.text.trim());
    if (value == null) return null;
    if (value < _customMinSeconds || value > _customMaxSeconds) return null;
    return value;
  }

  void _submit() {
    final seconds = _parse();
    if (seconds == null) {
      setState(
        () => _error = '请输入 $_customMinSeconds–$_customMaxSeconds 的整数秒',
      );
      return;
    }
    Navigator.of(context).pop(seconds);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: const Text('自定义时长'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            key: const ValueKey('settings-danmaku-duration-input'),
            controller: _seconds,
            autofocus: true,
            keyboardType: TextInputType.number,
            decoration: InputDecoration(
              labelText: '时长（秒）',
              hintText: '例如 25',
              errorText: _error,
            ),
            // 只在**已经报过错**之后才随输入清错：边打字边报红是另一种噪音。
            onChanged: (text) {
              if (_error == null) return;
              if (_parse() != null) setState(() => _error = null);
            },
          ),
          const SizedBox(height: AppSpace.sm),
          Text(
            '$_customMinSeconds–$_customMaxSeconds 秒，越大越慢',
            style: theme.textTheme.bodySmall,
          ),
        ],
      ),
      actions: [
        TextButton(
          key: const ValueKey('settings-danmaku-duration-cancel'),
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          key: const ValueKey('settings-danmaku-duration-confirm'),
          onPressed: _submit,
          child: const Text('确定'),
        ),
      ],
    );
  }
}

/// 添加 / 编辑一条弹幕源的对话框（名称 + 地址）。
///
/// 与 [ImmediateAddressDialog] 刻意不同：这里用「确定 / 取消」，因为两个字段是
/// 一起改的，逐字即时落盘会让半成品进配置（[DanmakuSettingsPage] 里有同样的
/// 理由）。校验失败只在地址框下方出 errorText，绝不写盘。
class _DanmakuSourceDialog extends StatefulWidget {
  const _DanmakuSourceDialog({
    required this.title,
    required this.initialName,
    required this.initialUrl,
    required this.validateUrl,
    required this.onSave,
  });

  final String title;
  final String initialName;
  final String initialUrl;
  final String? Function(String url) validateUrl;
  final Future<bool> Function(String name, String url) onSave;

  @override
  State<_DanmakuSourceDialog> createState() => _DanmakuSourceDialogState();
}

class _DanmakuSourceDialogState extends State<_DanmakuSourceDialog> {
  late final TextEditingController _name = TextEditingController(
    text: widget.initialName,
  );
  late final TextEditingController _url = TextEditingController(
    text: widget.initialUrl,
  );
  String? _urlError;
  bool _saving = false;
  bool _saveFailed = false;

  @override
  void dispose() {
    _name.dispose();
    _url.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final url = _url.text.trim();
    final error = widget.validateUrl(url);
    if (error != null) {
      setState(() => _urlError = error);
      return;
    }
    setState(() {
      _urlError = null;
      _saveFailed = false;
      _saving = true;
    });
    final saved = await widget.onSave(_name.text.trim(), url);
    if (!mounted) return;
    setState(() {
      _saving = false;
      _saveFailed = !saved;
    });
    // 失败时留着对话框：关掉等于把刚填的内容一起丢掉，用户还得重填一遍。
    if (!saved) return;
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: Text(widget.title),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            key: const ValueKey('settings-danmaku-source-name'),
            controller: _name,
            autofocus: true,
            decoration: const InputDecoration(
              labelText: '名称（可留空）',
              hintText: '客厅 NAS / 备用源',
            ),
          ),
          const SizedBox(height: AppSpace.sm),
          TextField(
            key: const ValueKey('settings-danmaku-source-url'),
            controller: _url,
            decoration: InputDecoration(
              labelText: '地址',
              hintText: 'http://192.168.1.10:9321/TOKEN',
              errorText: _urlError,
            ),
            // 只在**已经报过错**之后才随输入清错：边打字边报红是另一种噪音，
            // 但改对了还留着红字会让人以为仍不合法。
            onChanged: (text) {
              if (_urlError == null) return;
              if (widget.validateUrl(text.trim()) == null) {
                setState(() => _urlError = null);
              }
            },
          ),
          const SizedBox(height: AppSpace.sm),
          Text(
            '支持 danmu_api / TVBox（FongMi）接口与 ?title=&episode= 通用源',
            style: theme.textTheme.bodySmall,
          ),
          if (_saveFailed)
            Padding(
              padding: const EdgeInsets.only(top: AppSpace.sm),
              child: Text(
                '自动保存失败，请重新确认后重试',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.error,
                ),
              ),
            ),
        ],
      ),
      actions: [
        TextButton(
          key: const ValueKey('settings-danmaku-source-cancel'),
          onPressed: _saving ? null : () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          key: const ValueKey('settings-danmaku-source-save'),
          onPressed: _saving ? null : _submit,
          child: const Text('确定'),
        ),
      ],
    );
  }
}
