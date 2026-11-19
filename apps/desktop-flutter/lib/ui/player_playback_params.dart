// 播放参数（缓冲/硬解/自动连播/失败回退/LUT）的装配：开播注入、就地改写、落盘，
// 以及右键菜单「设置 → 播放参数」那一列子项。
//
// 为什么是 `part`：`_applyPlaybackEnhancements` 等直接读写页面字段 `_options`
// 并打到 `_controller` / `_optionWriteQueue` 上，抽成独立对象要先把这些状态搬
// 走；本轮只搬不改，行为与拆分前逐字一致。
part of 'player_page.dart';

extension _PlayerPagePlaybackParams on _PlayerPageState {
  /// 应用播放参数与 LUT（Phase 9）。
  ///
  /// 两者都走 mpv 属性注入；平台不是 NativePlayer 或属性被拒绝时只提示一次，
  /// 不把失败升级成播放失败（`docs/phase9/design/01` §5）。
  Future<void> _applyPlaybackEnhancements() async {
    _options = widget.state.playerOptions;
    final applied = await _queueOptionsApply(_options);
    if (!applied) {
      widget.state.log.warning('播放参数未生效（当前平台不是 NativePlayer）', scope: 'player');
    }
    // 内置预设按 id 重新落盘：cacheDir 随时可能被系统或清理功能删掉，
    // 只信 lutPath 会在缓存被清后静默失效。
    var lut = _options.lutPath.trim();
    final builtinLut = findBuiltinLut(_options.lutPresetId);
    if (builtinLut != null) {
      try {
        lut = await _lutStore.materialize(builtinLut);
        if (lut != _options.lutPath) {
          await _persistOptions(_options.copyWith(lutPath: lut));
        }
      } on LutStoreException catch (error) {
        widget.state.log.warning(
          'LUT 落盘失败 ${error.code} path=${builtinLut.path}',
          scope: 'player',
        );
        _showPlayerMessage('LUT 不可用：${error.message}', kind: ToastKind.error);
        return;
      }
    }
    if (lut.isEmpty) return;
    try {
      final text = await File(lut).readAsString();
      final parsed = parseCube(text, path: lut);
      if (!parsed.ok) {
        widget.state.log.warning(
          'LUT 解析失败 ${parsed.error} path=$lut',
          scope: 'player',
        );
        _showPlayerMessage('LUT 不可用：${parsed.error}', kind: ToastKind.error);
        return;
      }
      final ok = await _controller.applyLut(lut);
      if (!ok) {
        _showPlayerMessage('当前播放内核不支持 LUT', kind: ToastKind.error);
      }
    } catch (error) {
      widget.state.log.warning('LUT 加载失败 $error path=$lut', scope: 'player');
      _showPlayerMessage('LUT 加载失败：$error', kind: ToastKind.error);
    }
  }

  Future<void> _persistOptions(PlayerOptions options) async {
    _options = options.normalized();
    await widget.state.setPlayerOptions(_options);
  }

  /// 把一次 mpv 参数写入排进 [_optionWriteQueue]。返回该笔的真实结果。
  Future<bool> _queueOptionsApply(PlayerOptions options) =>
      _enqueueWrite(() => _controller.applyPlayerOptions(options));

  /// 「设置 → 播放参数」那一列子项（原 `_contextMenuSections` 里的一段）。
  ///
  /// 拆出来只为给 Wave 2 一个可改的面：内容是逐字搬运的同一棵菜单树，
  /// 层级与「为什么是这一档」的理由都保持原样。
  PlayerMenuItem _playbackParamsMenuItem() {
    return PlayerMenuItem(
      id: 'settings_player_options',
      label: '播放参数',
      icon: Icons.tune,
      children: [
        _settingsToggle(
          id: 'settings_hwdec',
          label: '硬件解码',
          value: _options.hardwareDecoding,
          onChanged: (value) => _livePatchOptions(
            _options.copyWith(hardwareDecoding: value),
          ),
        ),
        _settingsToggle(
          id: 'settings_cache',
          label: '缓存',
          value: _options.cache,
          onChanged: (value) =>
              _livePatchOptions(_options.copyWith(cache: value)),
        ),
        _settingsToggle(
          id: 'settings_preload_next',
          label: '预加载下一集',
          value: _options.preloadNext,
          onChanged: (value) =>
              _livePatchOptions(_options.copyWith(preloadNext: value)),
        ),
        _settingsToggle(
          id: 'settings_audio_passthrough',
          label: '音频直通',
          value: _options.audioPassthrough,
          onChanged: (value) => _livePatchOptions(
            _options.copyWith(audioPassthrough: value),
          ),
        ),
        _settingsToggle(
          id: 'settings_auto_next',
          label: '自动连播',
          value: _options.autoNext,
          onChanged: (value) =>
              _livePatchOptions(_options.copyWith(autoNext: value)),
        ),
        // 长按画面快进：同样是**互斥单选**，飞出子列天然只有一项打勾。
        // 默认 3×；只影响长按手势，不改正常播放速率。
        PlayerMenuItem(
          id: 'settings_long_press_speed',
          label: '长按画面倍速',
          icon: Icons.fast_forward,
          children: [
            for (final speed in PlayerOptions.longPressSpeedChoices)
              PlayerMenuItem(
                id: 'settings_long_press_speed_${speed.toString().replaceAll('.', '_')}',
                label: _PlayerPageState._speedText(speed),
                selected: (_options.longPressSpeed - speed).abs() < 0.01,
                onSelect: () => _livePatchOptions(
                  _options.copyWith(longPressSpeed: speed),
                ),
              ),
          ],
        ),
        for (final rightSide in [false, true])
          PlayerMenuItem(
            id: 'settings_double_click_${rightSide ? 'right' : 'left'}',
            label: rightSide ? '右半屏双击' : '左半屏双击',
            icon: Icons.touch_app_outlined,
            children: [
              for (final action in PlayerDoubleClickAction.values)
                PlayerMenuItem(
                  id: 'settings_double_click_${rightSide ? 'right' : 'left'}_${action.id}',
                  label: action.label,
                  selected:
                      (rightSide
                          ? _options.doubleClickRight
                          : _options.doubleClickLeft) ==
                      action,
                  enabled: !((_isLive || _isCatchup) && action.isSeek),
                  onSelect: (_isLive || _isCatchup) && action.isSeek
                      ? null
                      : () => _livePatchOptions(
                          rightSide
                              ? _options.copyWith(
                                  doubleClickRight: action,
                                )
                              : _options.copyWith(
                                  doubleClickLeft: action,
                                ),
                        ),
                ),
            ],
          ),
        // 第 3 层：失败回退阶梯。四档是**互斥单选**，摊成四条开关会让
        // 「当前是哪一档」看不出来；飞出子列则天然单选（只有一项打勾）。
        PlayerMenuItem(
          id: 'settings_failure_fallback',
          label: '失败回退',
          icon: Icons.alt_route,
          children: [
            for (final mode in PlayerFailureFallback.values)
              PlayerMenuItem(
                id: 'settings_fallback_${mode.id}',
                label: mode.label,
                selected: _options.failureFallback == mode,
                // 就地生效、不关菜单：改完回退策略常常还要接着调缓存上限。
                onSelect: () => _livePatchOptions(
                  _options.copyWith(failureFallback: mode),
                ),
              ),
          ],
        ),
        // 第 3 层：缓存上限。真值是 int（16–2048 MiB，见
        // `PlayerOptions.minDemuxerMaxMiB`），菜单里没有数字输入，所以
        // 给四档常用值；要精调仍走「完整设置页…」的滑杆——**不假装**
        // 四档就是全部取值。
        PlayerMenuItem(
          id: 'settings_cache_cap',
          label: '缓存上限',
          icon: Icons.sd_storage_outlined,
          children: [
            for (final mib in const [64, 128, 256, 512])
              PlayerMenuItem(
                id: 'settings_cache_cap_$mib',
                label: '$mib MiB',
                selected: _options.demuxerMaxBytesMiB == mib,
                onSelect: () => _livePatchOptions(
                  _options.copyWith(demuxerMaxBytesMiB: mib),
                ),
              ),
          ],
        ),
      ],
    );
  }
}
