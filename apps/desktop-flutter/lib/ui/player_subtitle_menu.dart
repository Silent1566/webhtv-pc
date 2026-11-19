// 字幕菜单（轨选择弹层 / 搜索 / 本地文件 / 失败提示 / 样式弹层）与字幕样式档位表。
//
// 为什么是 `part`：这些入口全部依赖页面实时状态（`_controller` 的轨道与当前
// 选择、`_subtitleStyle`、`_mediaGeneration` 的换代闸门、`setState` / toast），
// 抽成独立 widget 得先把状态做成快照；本轮只搬不改，语义保持逐字一致。
// 档位表 `subtitleColorChoices` 留在同一 library 内，弹层与右键菜单仍共用一张表。
part of 'player_page.dart';

/// 偏移菜单的一步：0.1 秒（内部一律毫秒，见 `TrackOffset`）。
///
/// 只在这一层用：界面不换算成 mpv 的秒，换算的唯一出口是
/// `mpv_properties.dart` 的 `mpvSecondsFromMilliseconds`。
const int _trackOffsetStepMs = 100;

/// 字幕文字色的可选档位（底部弹层与右键菜单共用同一张表）。
///
/// 两处必须同源：菜单里的选中判定比对的是 `textColorValue`，各写一张表会
/// 出现「菜单里选了黄、弹层里不显示选中」这类割裂。
const List<({String label, int value})> subtitleColorChoices = [
  (label: '白', value: 0xFFFFFFFF),
  (label: '黄', value: 0xFFFFEB3B),
  (label: '青', value: 0xFF18FFFF),
  (label: '绿', value: 0xFFB2FF59),
  (label: '橙', value: 0xFFFFAB40),
  (label: '粉', value: 0xFFFF4081),
];

extension _PlayerPageSubtitleMenu on _PlayerPageState {
  /// 手动搜索字幕：打开搜索窗口 → 选中 → 下载/套用 → 记忆。
  ///
  /// 窗口只负责交互（可离屏测试）；搜索、下载、套用、记忆都在这一侧。
  Future<void> _showSubtitleSearch() async {
    final settings = widget.state.subtitleSettings;
    if (!settings.hasAnyProvider) {
      _showPlayerMessage(
        '未配置字幕源：请先在 设置 → 字幕源 填写 ASSRT / 迅雷 / 射手或本地目录',
        kind: ToastKind.error,
      );
      return;
    }
    final generation = _mediaGeneration;
    final service = _subtitleService(timeout: const Duration(seconds: 15));
    final selected = await showSubtitleSearchDialog(
      context: context,
      initialQuery: _subtitleQuery(),
      search: (query) => service.searchReport(query: query, settings: settings),
      preferredLanguages: settings.preferredLanguages,
      pickLocalFile: _pickLocalSubtitleFile,
    );
    if (selected == null || !mounted || generation != _mediaGeneration) return;
    final applied = await _applySubtitleCandidate(selected, remember: true);
    // 只有从字幕源搜到的候选才值得学标题：本地文件名不是影片名。
    if (applied && selected.providerId != 'local') {
      await widget.state.learnBusinessTitle(
        rawTitle: _request.vodName,
        confirmedTitle: selected.title,
        siteKey: _request.siteKey,
        vodId: _request.vodId,
      );
    }
  }

  /// 搜索窗口里的「选择本地文件…」：原生文件对话框，取消返回 null。
  Future<String?> _pickLocalSubtitleFile() async {
    try {
      final file = await FilePicker.pickFile(
        dialogTitle: '选择字幕文件',
        type: FileType.custom,
        allowedExtensions: const ['srt', 'ass', 'ssa', 'vtt', 'sub'],
      );
      return file?.path;
    } catch (error) {
      widget.state.log.warning('选择本地字幕文件失败 $error', scope: 'subtitle');
      return null;
    }
  }

  /// 选择本地字幕文件：路径输入 → 加载并记忆。
  Future<void> _showLocalSubtitlePicker() async {
    var input = '';
    final path = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('本地字幕文件'),
        content: TextField(
          onChanged: (value) => input = value,
          autofocus: true,
          decoration: const InputDecoration(
            hintText: r'C:\subtitles\movie.srt',
          ),
          onSubmitted: (value) => Navigator.of(context).pop(value),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(input),
            child: const Text('加载'),
          ),
        ],
      ),
    );
    final trimmed = path?.trim() ?? '';
    if (trimmed.isEmpty || !mounted) return;
    final candidate = SubtitleCandidate(
      providerId: 'local',
      assetId: trimmed,
      title: trimmed.split(Platform.pathSeparator).last,
      language: '',
      format: '',
      url: trimmed,
    );
    await _applySubtitleCandidate(candidate, remember: true);
  }

  /// 字幕失败提示：不阻断播放，只用浮动提示告知（§10.4）。
  void _showSubtitleError(String message) {
    if (!mounted || _lastShownSubtitleError == message) return;
    _lastShownSubtitleError = message;
    // 不传 duration：走 error 默认的 15s，`字幕设置` 动作在这段时间内都可点。
    // 去重闸门 [_lastShownSubtitleError] 必须保留：同一条失败只提示一次。
    showToast(
      message,
      kind: ToastKind.error,
      action: AppToastAction(label: '字幕设置', onPressed: _showSubtitleMenu),
    );
  }

  Future<void> _showSubtitleMenu() async {
    final options = _controller.subtitleOptions;
    final selected = await showModalBottomSheet<Object>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            for (final option in options)
              ListTile(
                leading: Icon(
                  option.id == SubtitleOption.offId
                      ? Icons.subtitles_off_outlined
                      : (option.isExternal
                            ? Icons.description_outlined
                            : Icons.subtitles_outlined),
                ),
                title: Text(option.label),
                subtitle: option.isExternal
                    ? Text(
                        '外挂 · ${option.format.toUpperCase()}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      )
                    : const Text('内嵌'),
                trailing: _controller.selectedSubtitle == option
                    ? const Icon(Icons.check)
                    : null,
                onTap: () => Navigator.of(context).pop(option),
              ),
            if (options.isEmpty)
              const ListTile(
                title: Text('当前视频没有字幕轨'),
                subtitle: Text('可以搜索字幕或选择本地文件'),
              ),
            const Divider(height: 1),
            ListTile(
              leading: const Icon(Icons.search),
              title: const Text('搜索字幕…'),
              onTap: () => Navigator.of(context).pop('search'),
            ),
            ListTile(
              leading: const Icon(Icons.folder_open_outlined),
              title: const Text('选择本地字幕文件…'),
              onTap: () => Navigator.of(context).pop('local'),
            ),
            const Divider(height: 1),
            // 偏移这两组就地刷新：页面的 setState 到不了这个弹层，而当前值
            // 读的是页面字段 `_options`（`_livePatchOptions` 会同步更新它），
            // 所以这里只需要一个「只重建本块」的刷新入口。
            StatefulBuilder(
              builder: (context, setSheetState) => Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _trackOffsetTile(
                    TrackOffsetKind.subtitle,
                    onChanged: () => setSheetState(() {}),
                  ),
                  _trackOffsetTile(
                    TrackOffsetKind.audio,
                    onChanged: () => setSheetState(() {}),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
    if (selected == null || !mounted) return;
    if (selected == 'search') {
      await _showSubtitleSearch();
      return;
    }
    if (selected == 'local') {
      await _showLocalSubtitlePicker();
      return;
    }
    if (selected is! SubtitleOption) return;
    _controller.clearSubtitleError();
    final ok = await _controller.selectSubtitle(
      selected,
      headers: _request.subtitleHeaders,
    );
    final error = _controller.subtitleError;
    if (ok) {
      widget.state.log.info(
        '字幕已切换 sub=${selected.label} kind=${selected.kind.name}',
        scope: 'subtitle',
      );
      // 只记内嵌轨：外挂/本地/网络字幕随集变化，由 `SubtitleMatchRecord` 另管。
      if (!selected.isExternal && selected.id != SubtitleOption.offId) {
        _rememberTrackChoice(PlayerTrackSlot.subtitle, selected.id);
      }
      return;
    }
    widget.state.log.warning(
      '字幕切换失败 sub=${selected.label} ${error ?? "未知错误"}',
      scope: 'subtitle',
    );
    if (error != null) _showSubtitleError(error);
  }

  /// 「字幕延迟 / 音轨延迟」一行：当前值 + −0.1 秒 / 重置 / +0.1 秒。
  ///
  /// 为什么放在字幕菜单：偏移就是「字幕对不上/音画不同步」时的对轴动作，用户
  /// 来这儿找字幕源时顺手就能调；另开一个入口只会让对轴要跑两趟。
  Widget _trackOffsetTile(
    TrackOffsetKind kind, {
    required VoidCallback onChanged,
  }) {
    final current = _options.trackOffset(kind);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 8, 4),
      child: Row(
        children: [
          Icon(
            kind == TrackOffsetKind.subtitle
                ? Icons.subtitles_outlined
                : Icons.audiotrack,
            size: 20,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('${kind.label}延迟'),
                Text(
                  formatTrackOffsetSeconds(current.milliseconds),
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ),
          IconButton(
            icon: const Icon(Icons.remove_circle_outline),
            tooltip: '${kind.label}延迟 -0.1 秒',
            onPressed: () => _stepTrackOffset(
              kind,
              -_trackOffsetStepMs,
              onChanged: onChanged,
            ),
          ),
          TextButton(
            onPressed: current.isZero
                ? null
                : () => _setTrackOffset(kind, 0, onChanged: onChanged),
            child: const Text('重置'),
          ),
          IconButton(
            icon: const Icon(Icons.add_circle_outline),
            tooltip: '${kind.label}延迟 +0.1 秒',
            onPressed: () => _stepTrackOffset(
              kind,
              _trackOffsetStepMs,
              onChanged: onChanged,
            ),
          ),
        ],
      ),
    );
  }

  /// 走一步（±0.1 秒）。顶到 ±60 秒就只提示：不再写盘、不写内核。
  void _stepTrackOffset(
    TrackOffsetKind kind,
    int deltaMilliseconds, {
    required VoidCallback onChanged,
  }) {
    final current = _options.trackOffset(kind);
    final stepped = current.copyWith(
      milliseconds: current.milliseconds + deltaMilliseconds,
    );
    if (stepped == current) {
      _showPlayerMessage(
        '${kind.label}延迟已到 '
        '${formatTrackOffsetSeconds(TrackOffset.maxMilliseconds)} 上限',
      );
      return;
    }
    _setTrackOffset(kind, stepped.milliseconds, onChanged: onChanged);
  }

  /// 落盘 + 写内核 + 刷新弹层。
  ///
  /// extension 里不能调 `setState`，所以刷新走页面方法 [_livePatchOptions]：
  /// 它同步更新页面字段 `_options`、落盘，并把整表 mpv 属性（含两个偏移）
  /// 排进写入队列。
  void _setTrackOffset(
    TrackOffsetKind kind,
    int milliseconds, {
    required VoidCallback onChanged,
  }) {
    // 夹取在 TrackOffset 构造里做：界面永远拿不到越界值。
    final next = TrackOffset(kind: kind, milliseconds: milliseconds);
    _livePatchOptions(_options.withTrackOffset(next));
    unawaited(_applyTrackOffset(next));
    onChanged();
  }

  /// 写内核；失败只说原因，不阻断播放（与「音量归一」同一处理）。
  Future<void> _applyTrackOffset(TrackOffset offset) async {
    final applied = await _enqueueWrite(
      () => _controller.setTrackOffset(offset),
    );
    if (!mounted || applied) return;
    final rejected = _controller.rejectedMpvProperties;
    final reason = rejected.isNotEmpty
        ? rejected.map((entry) => entry.reason).join('；')
        : _controller.lastEngineError ?? '当前内核不支持';
    final message =
        '${offset.kind.label}延迟 '
        '${formatTrackOffsetSeconds(offset.milliseconds)} 未生效：$reason';
    widget.state.log.warning(message, scope: 'player');
    _showPlayerMessage(message, kind: ToastKind.error);
  }

  Future<void> _showSubtitleStyleSettings() async {
    var draft = _subtitleStyle;
    final result = await showModalBottomSheet<SubtitleStyle>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (context) => StatefulBuilder(
        builder: (context, setModalState) => SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('字幕样式', style: Theme.of(context).textTheme.titleLarge),
                const SizedBox(height: 4),
                Text(
                  '去除黑色字幕底框，并调整字幕位置、描边和时间偏移。',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: 18),
                Text('文字颜色', style: Theme.of(context).textTheme.titleSmall),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 10,
                  children: [
                    for (final choice in subtitleColorChoices)
                      InkWell(
                        onTap: () => setModalState(
                          () => draft = draft.copyWith(
                            textColorValue: choice.value,
                          ),
                        ),
                        borderRadius: BorderRadius.circular(20),
                        child: Container(
                          width: 30,
                          height: 30,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: Color(choice.value),
                            border: Border.all(
                              color: draft.textColorValue == choice.value
                                  ? Theme.of(context).colorScheme.primary
                                  : Colors.white54,
                              width: draft.textColorValue == choice.value
                                  ? 3
                                  : 1,
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 18),
                Text(
                  '字幕底色（默认透明）',
                  style: Theme.of(context).textTheme.titleSmall,
                ),
                Slider(
                  value: draft.backgroundOpacity,
                  min: 0,
                  max: 0.8,
                  divisions: 8,
                  label: '${(draft.backgroundOpacity * 100).round()}%',
                  onChanged: (value) => setModalState(
                    () => draft = draft.copyWith(backgroundOpacity: value),
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  '描边宽度 ${draft.outlineWidth.toStringAsFixed(1)}',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                Slider(
                  value: draft.outlineWidth,
                  min: 0,
                  max: 4,
                  divisions: 8,
                  label: draft.outlineWidth.toStringAsFixed(1),
                  onChanged: (value) => setModalState(
                    () => draft = draft.copyWith(outlineWidth: value),
                  ),
                ),
                Text(
                  '字号 ${((draft.textScale) * 100).round()}%',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                Slider(
                  value: draft.textScale,
                  min: 0.6,
                  max: 1.8,
                  divisions: 12,
                  label: '${(draft.textScale * 100).round()}%',
                  onChanged: (value) => setModalState(
                    () => draft = draft.copyWith(textScale: value),
                  ),
                ),
                Text(
                  '字幕位置 ${draft.bottomPadding.round()}dp',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                Slider(
                  value: draft.bottomPadding,
                  min: 0,
                  max: 120,
                  divisions: 12,
                  label: '${draft.bottomPadding.round()}dp',
                  onChanged: (value) => setModalState(
                    () => draft = draft.copyWith(bottomPadding: value),
                  ),
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    TextButton(
                      onPressed: () => setModalState(() {
                        draft = SubtitleStyle.defaults;
                      }),
                      child: const Text('恢复默认'),
                    ),
                    const Spacer(),
                    FilledButton(
                      onPressed: () => Navigator.of(context).pop(draft),
                      child: const Text('应用'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
    if (result == null || !mounted) return;
    _applySubtitleStyle(result);
  }
}
