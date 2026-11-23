// 右键菜单的分组内容：由 `player_page.dart` 拆入的 `_PlayerPageState` 扩展。
//
// 为什么是 `part`（而不是独立 widget 或快照纯函数）：这段每次重建菜单都要读
// 页面的实时状态（`_options`、`_osdFlags`、`_subtitleStyle`、`_controller` 的
// 轨道列表……），改成快照纯函数要先把 30+ 个字段做成不可变对象——改动面大、回归
// 风险高，留给 Wave 2 评估（见 `player_page.dart` 里 `_contextMenuSections` 的
// 调用点）。用 `part` 的收益：零语义变化，方法仍是 `_PlayerPageState` 的成员。
part of 'player_page.dart';

extension _PlayerPageMenuSections on _PlayerPageState {
  /// 右键菜单的分组内容（`design/04` §4.1）。
  ///
  /// ## 为什么是 11 组、且大多数组能往下钻
  ///
  /// 上一版是 7 个**扁平**组、约 40 项：子菜单基本为空，本该分层的选项
  /// （字幕字号/描边/位置/底色、各画面比例、7 个屏显开关、定时关闭）全被摊在
  /// 主列里，主列要滚到底才看得见「屏显」。现在的形态对齐 PotPlayer 的分组
  /// 逻辑——**按功能域分组、组内下钻**：主列只回答「我要动哪一类」，
  /// 具体取值落在第 2、第 3 列。
  ///
  /// ## 带子列的父项**只有** children、没有 onSelect
  ///
  /// 引擎对「有 children 的项」不发动作（`design/04` §5.5：一次点击不能既
  /// 飞出又执行）。所以父项只承载「打开下一列」，真实动作全部落在叶子上。
  ///
  /// ## 当前值必须可见
  ///
  /// 倍速、音量档位、静音、画面模式、LUT、屏显开关、自动跳过、循环模式、
  /// 定时关闭、字幕样式各档都用 `selected` 标出来。不可用项用
  /// `enabled: false` 但**保留 selected**：引擎把「选中 + 禁用」画成压暗的
  /// 琥珀，仍读得出这是当前值（`DESIGN.md:373`「禁用只降低强调，不能抹掉
  /// 状态」）。
  ///
  /// ## 每组至少两项
  ///
  /// 只有一个子项的分组没有存在价值（分组的目的是缩短主列），宁可合并掉。
  /// 所以「画面」只有画面比例、LUT、HDR 色调映射、峰值亮度计算四项、全屏归
  /// 「显示」——全屏是显示模式，与屏显开关同一类。
  ///
  /// HDR 两项放在「画面」而不是「设置 → 播放参数」：它们改的是**画面**本身，
  /// 用户调它时眼睛正盯着画面；设置页那份仍是权威值，两处读同一份
  /// `PlayerOptions`，不会各记一套。
  List<PlayerMenuSection> _contextMenuSections() {
    const rates = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0];
    // 音量档位：与底部控制条滑杆同值域（0–100），20 一档。
    const volumeSteps = [0.0, 20.0, 40.0, 60.0, 80.0, 100.0];
    final osd = widget.state.osdFlags;
    final volume = _controller.volume;
    final subtitle = _controller.selectedSubtitle;
    final audioTracks = _controller.audioTrackOptions;
    // 设置组下钻树的数据源：每次建菜单都重读，菜单里显示的就是**真实值**，
    // 不走本地缓存（`_options` 只是播放参数的会话副本，字幕设置没有副本）。
    final subtitleSettings = widget.state.subtitleSettings;

    /// 叶子项的统一收尾：**先关菜单再执行**。
    ///
    /// 菜单层由本页持有；不关掉会盖在随后弹出的底部弹层/对话框上。
    VoidCallback act(VoidCallback action) => () {
      _closeContextMenu();
      action();
    };

    return [
      // ------------------------------------------------------ 1. 播放
      PlayerMenuSection(
        title: '播放',
        items: [
          PlayerMenuItem(
            id: 'play',
            label: _controller.isPlaying ? '暂停' : '播放',
            icon: _controller.isPlaying ? Icons.pause : Icons.play_arrow,
            onSelect: act(_controller.playOrPause),
          ),
          // 本地文件没有「集」可换：这两个按钮落到 [_playPrevious] /
          // [_playNext] 的选集分支，而那一支读的是 `_episodes`
          // （= `request.playLines` 里当前线路的分集）——本地请求不带线路，
          // 队列也只属于站点目录连播，于是两条都退化成**静默 no-op**。
          // 死按钮比缺按钮更像「坏了」：置灰好歹表示「这里有个能力，此刻不可
          // 用」，而本地根本没有集这个概念，置灰还得多解释一句为什么。
          // 直播的「上一台/下一台」不受影响：那条路径走 liveSession。
          if (!_request.isLocal) ...[
            PlayerMenuItem(
              id: 'prev',
              label: _isLive ? '上一台' : '上一集',
              icon: Icons.skip_previous,
              onSelect: act(_playPrevious),
            ),
            PlayerMenuItem(
              id: 'next',
              label: _isLive ? '下一台' : '下一集',
              icon: Icons.skip_next,
              onSelect: act(_playNext),
            ),
          ],
          PlayerMenuItem(
            id: 'back10',
            label: '后退 10 秒',
            icon: Icons.replay_10,
            onSelect: act(
              () => _controller.seekBy(const Duration(seconds: -10)),
            ),
          ),
          PlayerMenuItem(
            id: 'forward10',
            label: '前进 10 秒',
            icon: Icons.forward_10,
            onSelect: act(
              () => _controller.seekBy(const Duration(seconds: 10)),
            ),
          ),
          PlayerMenuItem(
            id: 'previous_keyframe',
            label: '前一个关键帧  Ctrl+Shift+←',
            icon: Icons.skip_previous_outlined,
            enabled: _navigationAvailable,
            onSelect: act(() => unawaited(_seekToKeyframe(forward: false))),
          ),
          PlayerMenuItem(
            id: 'next_keyframe',
            label: '后一个关键帧  Ctrl+Shift+→',
            icon: Icons.skip_next_outlined,
            enabled: _navigationAvailable,
            onSelect: act(() => unawaited(_seekToKeyframe(forward: true))),
          ),
          _settingsToggle(
            id: 'thumbnail_preview',
            label: '导航栏缩略图',
            value: _options.showThumbnailPreview,
            onChanged: (value) => _livePatchOptions(
              _options.copyWith(showThumbnailPreview: value),
            ),
          ),
          _settingsToggle(
            id: 'drag_pause',
            label: '拖动进度条时暂停',
            value: _options.dragPause,
            onChanged: (value) =>
                _livePatchOptions(_options.copyWith(dragPause: value)),
          ),
          // 循环与定时是**会话级**状态，取值有 3 种循环 + 8 种定时，全部
          // 摊进主列会让「播放」组比别的组高出一倍，所以保留原来的底部弹层
          // 作为唯一入口。`selected` 让「已开启循环或定时」在主列直接可见——
          // 上一版这两个状态在菜单里完全不可见。
          PlayerMenuItem(
            id: 'playback_mode',
            label: '循环与定时…',
            icon: Icons.repeat,
            selected: _repeat != PlaybackRepeat.off || !_sleepTimer.idle,
            onSelect: act(_showPlaybackModeSheet),
          ),
          // 外调：外部播放器要的是已解析地址，所以这个家只能在这里。
          // 未配置播放器时也保留该项——点进去就是选择播放器，否则第一次
          // 使用的人找不到任何入口（控制栏按钮在未配置时不渲染）。
          PlayerMenuItem(
            id: 'external_player',
            label: '用外部播放器打开…',
            icon: Icons.open_in_new,
            selected: _externalPlayerRunning != null,
            onSelect: act(() => unawaited(_openInExternalPlayer())),
          ),
        ],
      ),

      // ------------------------------------------------------ 2. 速度
      PlayerMenuSection(
        title: '速度',
        items: [
          for (final rate in rates)
            PlayerMenuItem(
              id: 'rate_$rate',
              label: '${rate.toString()}×',
              selected: (_controller.rate - rate).abs() < 0.01,
              onSelect: act(() => _controller.setRate(rate)),
            ),
        ],
      ),

      // ------------------------------------------------------ 3. 字幕
      PlayerMenuSection(
        title: '字幕',
        items: [
          PlayerMenuItem(
            id: 'subtitle_track',
            label: '字幕轨…',
            icon: Icons.subtitles_outlined,
            selected: subtitle != null && subtitle.id != SubtitleOption.offId,
            onSelect: act(_showSubtitleMenu),
          ),
          PlayerMenuItem(
            id: 'subtitle_search',
            label: '在线搜索字幕…',
            icon: Icons.search,
            onSelect: act(_showSubtitleSearch),
          ),
          PlayerMenuItem(
            id: 'subtitle_local',
            label: '本地字幕文件…',
            icon: Icons.folder_open_outlined,
            onSelect: act(_showLocalSubtitlePicker),
          ),
          // 字幕样式在本轮**没有落盘能力**（`PlayerSubtitleStyle` 是页面字段），
          // 所以不能只给一个「打开设置页」的入口——四档取值每次都要点开底部
          // 弹层才看得见。这里做成二级 + 三级：字号 / 描边 / 位置 / 底色
          // 各自飞出一列具体档位。
          PlayerMenuItem(
            id: 'subtitle_style',
            label: '字幕样式',
            icon: Icons.format_color_text_outlined,
            children: [
              PlayerMenuItem(
                id: 'sub_size',
                label: '字号',
                icon: Icons.text_fields,
                children: [
                  for (final scale in const [0.8, 1.0, 1.25, 1.5])
                    PlayerMenuItem(
                      id: 'sub_size_${(scale * 100).round()}',
                      label: '${(scale * 100).round()}%',
                      selected:
                          (_subtitleStyle.textScale - scale).abs() < 0.001,
                      onSelect: () => _applySubtitleStyle(
                        _subtitleStyle.copyWith(textScale: scale),
                      ),
                    ),
                ],
              ),
              PlayerMenuItem(
                id: 'sub_outline',
                label: '描边',
                icon: Icons.border_color_outlined,
                children: [
                  for (final width in const [0.0, 1.0, 2.0, 3.0])
                    PlayerMenuItem(
                      id: 'sub_outline_${width.round()}',
                      label: width <= 0 ? '无描边' : '${width.round()}px',
                      selected:
                          (_subtitleStyle.outlineWidth - width).abs() < 0.001,
                      onSelect: () => _applySubtitleStyle(
                        _subtitleStyle.copyWith(outlineWidth: width),
                      ),
                    ),
                ],
              ),
              PlayerMenuItem(
                id: 'sub_pos',
                label: '位置',
                icon: Icons.vertical_align_bottom,
                children: [
                  for (final padding in const [0.0, 24.0, 48.0, 72.0])
                    PlayerMenuItem(
                      id: 'sub_pos_${padding.round()}',
                      label: '${padding.round()}dp',
                      selected:
                          (_subtitleStyle.bottomPadding - padding).abs() <
                          0.001,
                      onSelect: () => _applySubtitleStyle(
                        _subtitleStyle.copyWith(bottomPadding: padding),
                      ),
                    ),
                ],
              ),
              PlayerMenuItem(
                id: 'sub_bg',
                label: '底色',
                icon: Icons.format_color_fill,
                children: [
                  for (final alpha in const [0.0, 0.25, 0.5, 0.75])
                    PlayerMenuItem(
                      id: 'sub_bg_${(alpha * 100).round()}',
                      label: alpha <= 0 ? '透明' : '${(alpha * 100).round()}%',
                      selected:
                          (_subtitleStyle.backgroundOpacity - alpha).abs() <
                          0.001,
                      onSelect: () => _applySubtitleStyle(
                        _subtitleStyle.copyWith(backgroundOpacity: alpha),
                      ),
                    ),
                ],
              ),
              PlayerMenuItem(
                id: 'sub_color',
                label: '文字颜色',
                icon: Icons.format_color_text,
                children: [
                  for (final choice in subtitleColorChoices)
                    PlayerMenuItem(
                      id: 'sub_color_${choice.value.toRadixString(16)}',
                      label: choice.label,
                      selected: _subtitleStyle.textColorValue == choice.value,
                      onSelect: () => _applySubtitleStyle(
                        _subtitleStyle.copyWith(textColorValue: choice.value),
                      ),
                    ),
                ],
              ),
              PlayerMenuItem(
                id: 'sub_style_reset',
                label: '恢复默认样式',
                icon: Icons.restart_alt,
                onSelect: act(
                  () => _applySubtitleStyle(SubtitleStyle.defaults),
                ),
              ),
            ],
          ),
        ],
      ),

      // ------------------------------------------------------ 4. 弹幕
      //
      // 这三项原本寄生在「轨道」组里，但弹幕与轨道没有关系：轨道是**容器**，
      // 弹幕是**内容**——用户找「弹幕」时不会先想到「轨道」，而「轨道」组也
      // 因为混进 3 个非轨道项，从「切轨」变成了半张弹幕菜单。
      //
      // 三项都是**叶子**（与「设置」组的子树不同）：开关就地生效、不关菜单，
      // 搜索是一次弹层，设置是整页跳转，没有一个需要再飞出一列。
      PlayerMenuSection(
        title: '弹幕',
        items: [
          PlayerMenuItem(
            id: 'danmaku_toggle',
            label: _danmakuStyle.enabled ? '关闭弹幕' : '开启弹幕',
            icon: _danmakuStyle.enabled
                ? Icons.comment
                : Icons.comment_bank_outlined,
            selected: _danmakuStyle.enabled,
            // 就地生效、**不关菜单**：连续调整时会反复按。
            onSelect: _toggleDanmaku,
          ),
          PlayerMenuItem(
            id: 'danmaku_search',
            label: '搜索弹幕…',
            icon: Icons.travel_explore,
            onSelect: act(_showDanmakuSearch),
          ),
          PlayerMenuItem(
            id: 'danmaku_settings',
            label: '弹幕设置…',
            icon: Icons.comment_outlined,
            // 先给页签式弹层调显示参数；弹幕库仍在一屏放不下的整页里，
            // 由弹层底部的「完整设置页…」进入，两个入口共用同一实现。
            onSelect: act(() => unawaited(_openDanmakuQuickSettings())),
          ),
        ],
      ),

      // ------------------------------------------------------ 5. 画面
      PlayerMenuSection(
        title: '画面',
        items: [
          PlayerMenuItem(
            id: 'video_fit',
            label: '画面比例与缩放',
            icon: Icons.aspect_ratio_outlined,
            children: [
              for (final mode in PlayerVideoFitMode.values)
                PlayerMenuItem(
                  id: 'fit_${mode.name}',
                  label: mode.label,
                  selected: mode == _videoFitMode,
                  onSelect: act(() => _applyVideoFitMode(mode)),
                ),
            ],
          ),
          // LUT 是**即时生效**的切换，所以走飞出子列：选完仍在画面上。
          // 管理的长尾（导入/删除/在线搜索）塞不进 240 宽的子列，
          // 交给「更多 LUT…」打开的底部面板与设置里的三级明细页。
          PlayerMenuItem(
            id: 'lut',
            label: 'LUT 滤镜',
            icon: Icons.palette_outlined,
            children: buildLutMenuItems(
              options: _options,
              onOff: act(() => _applyLutPreset(null)),
              onPick: (preset) => act(() => _applyLutPreset(preset))(),
              onMore: act(_showLutSettings),
            ),
          ),
          // HDR 色调映射：**互斥单选**，和长按倍速/失败回退同一形态——摊成
          // 开关看不出「当前是哪一档」，飞出子列天然只有一项打勾。
          //
          // 为什么可以就地生效（而设置页仍写「下次播放生效」）：实测 mpv 0.40.0
          // 在播片过程中 set_property_string tone-mapping 六个取值全回 rc=0、
          // 画面不断流；非法值回 rc=-9 且继续播放。所以这里走
          // [_livePatchOptions]，与 applyPlayerOptions 共用同一条
          // 白名单 + 回读校验：回读不符会被判成没生效，不会假装成功。
          PlayerMenuItem(
            id: 'hdr_tone_mapping',
            label: 'HDR 色调映射',
            icon: Icons.hdr_auto_outlined,
            children: [
              for (final mode in HdrToneMapping.values)
                PlayerMenuItem(
                  id: 'hdr_tone_mapping_${mode.id}',
                  label: mode.label,
                  selected: _options.toneMapping == mode,
                  onSelect: () =>
                      _livePatchOptions(_options.copyWith(toneMapping: mode)),
                ),
            ],
          ),
          // 峰值亮度计算：同样三档互斥单选。
          PlayerMenuItem(
            id: 'hdr_peak_compute',
            label: '峰值亮度计算',
            icon: Icons.brightness_auto_outlined,
            children: [
              for (final mode in HdrPeakCompute.values)
                PlayerMenuItem(
                  id: 'hdr_peak_compute_${mode.id}',
                  label: mode.label,
                  selected: _options.hdrPeakCompute == mode,
                  onSelect: () => _livePatchOptions(
                    _options.copyWith(hdrPeakCompute: mode),
                  ),
                ),
            ],
          ),
        ],
      ),

      // ------------------------------------------------------ 6. 声音
      PlayerMenuSection(
        title: '声音',
        items: [
          PlayerMenuItem(
            id: 'volume',
            label: '音量',
            icon: _controller.muted ? Icons.volume_off : Icons.volume_up,
            children: [
              for (final step in volumeSteps)
                PlayerMenuItem(
                  id: 'volume_${step.round()}',
                  label: '${step.round()}%',
                  selected: (volume - step).abs() < 0.5,
                  onSelect: act(() => _controller.setVolume(step)),
                ),
              PlayerMenuItem(
                id: 'audio_normalization',
                label: '音量归一（Shift+N）',
                selected: widget.state.playerOptions.audioNormalization,
                onSelect: _toggleAudioNormalization,
              ),
            ],
          ),
          PlayerMenuItem(
            id: 'mute',
            label: _controller.muted ? '取消静音（M）' : '静音（M）',
            icon: _controller.muted ? Icons.volume_up : Icons.volume_off,
            selected: _controller.muted,
            onSelect: act(_controller.toggleMute),
          ),
          PlayerMenuItem(
            id: 'sound_audio_track',
            label: '音轨…',
            icon: Icons.graphic_eq,
            // 只有一条音轨时引擎没有可切的东西（`_showTrackMenu` 会弹说明），
            // 这里直接按「无多轨」灰掉，但仍保留在菜单里（隐藏更像功能没了）。
            enabled: audioTracks.length > 1,
            onSelect: act(() => _showTrackMenu(PlayerTrackKind.audio)),
          ),
        ],
      ),

      // ------------------------------------------------------ 7. 轨道
      PlayerMenuSection(
        title: '轨道',
        items: [
          PlayerMenuItem(
            id: 'track_video',
            label: '视频轨…',
            icon: Icons.video_settings_outlined,
            onSelect: act(() => _showTrackMenu(PlayerTrackKind.video)),
          ),
          PlayerMenuItem(
            id: 'track_subtitle',
            label: '字幕轨…',
            icon: Icons.subtitles_outlined,
            selected: subtitle != null && subtitle.id != SubtitleOption.offId,
            onSelect: act(_showSubtitleMenu),
          ),
        ],
      ),

      // ------------------------------------------------------ 8. 显示
      PlayerMenuSection(
        title: '显示',
        items: [
          PlayerMenuItem(
            id: 'osd',
            label: '屏显',
            icon: Icons.subtitles,
            children: [
              for (final id in OsdFlag.values)
                PlayerMenuItem(
                  id: 'osd_$id',
                  label: _osdLabelOf(id),
                  selected: osd[id] ?? false,
                  // 就地生效、不关菜单：7 个开关常要连着拨
                  // （`_toggleOsdFlag` 自己 setState，勾选当场刷新）。
                  onSelect: () => _toggleOsdFlag(id),
                ),
            ],
          ),
          // 屏显样式与「屏显」开关平级而不是嵌进它的 children：开关是「显示
          // 哪些项」，样式是「怎么画」；嵌进去会变成第 5 层，且与 7 个开关
          // 混排后「字号」看起来像第 8 个开关。
          PlayerMenuItem(
            id: 'osd_style',
            label: '屏显样式',
            icon: Icons.text_format,
            children: [
              PlayerMenuItem(
                id: 'osd_size',
                label: '字号',
                icon: Icons.text_fields,
                children: [
                  for (final scale in const [0.8, 1.0, 1.25, 1.5])
                    PlayerMenuItem(
                      id: 'osd_size_${(scale * 100).round()}',
                      label: '${(scale * 100).round()}%',
                      selected: (_osdStyle.textScale - scale).abs() < 0.001,
                      onSelect: () =>
                          _applyOsdStyle(_osdStyle.copyWith(textScale: scale)),
                    ),
                ],
              ),
              PlayerMenuItem(
                id: 'osd_opacity',
                label: '不透明度',
                icon: Icons.opacity,
                children: [
                  for (final opacity in const [0.5, 0.7, 0.85, 1.0])
                    PlayerMenuItem(
                      id: 'osd_opacity_${(opacity * 100).round()}',
                      label: '${(opacity * 100).round()}%',
                      selected: (_osdStyle.opacity - opacity).abs() < 0.001,
                      onSelect: () =>
                          _applyOsdStyle(_osdStyle.copyWith(opacity: opacity)),
                    ),
                ],
              ),
              PlayerMenuItem(
                id: 'osd_style_reset',
                label: '恢复默认样式',
                icon: Icons.restart_alt,
                onSelect: act(() => _applyOsdStyle(OsdStyle.defaults)),
              ),
            ],
          ),
          PlayerMenuItem(
            id: 'fullscreen',
            label: _fullscreen ? '退出全屏' : '全屏',
            icon: _fullscreen ? Icons.fullscreen_exit : Icons.fullscreen,
            onSelect: act(_toggleFullscreen),
          ),
        ],
      ),

      // ------------------------------------------------------ 9. 片头片尾
      PlayerMenuSection(
        title: '片头片尾',
        items: [
          PlayerMenuItem(
            id: 'auto_skip_intro',
            label: '自动跳过片头',
            icon: Icons.fast_forward_outlined,
            selected: (_options.skipKinds & SkipKindBits.intro) != 0,
            onSelect: () => _toggleAutoSkip(intro: true),
          ),
          PlayerMenuItem(
            id: 'auto_skip_outro',
            label: '自动跳过片尾',
            icon: Icons.fast_forward,
            selected: (_options.skipKinds & SkipKindBits.outro) != 0,
            onSelect: () => _toggleAutoSkip(intro: false),
          ),
          // 手动跳过依赖「本集有可用段」（手动标记或远端标定）：没有时
          // **灰掉但仍然列出**，隐藏会让用户以为功能没了（`DESIGN.md` 同类教训）。
          PlayerMenuItem(
            id: 'skip_intro',
            label: '跳过片头',
            icon: Icons.skip_next_outlined,
            enabled: _skipPlan.segments.any(
              (segment) => segment.kind == SkipKind.intro,
            ),
            onSelect: act(() => _manualSkip(SkipAction.intro)),
          ),
          PlayerMenuItem(
            id: 'skip_outro',
            label: '跳过片尾',
            icon: Icons.skip_next,
            enabled: _skipPlan.segments.any(
              (segment) => segment.kind == SkipKind.outro,
            ),
            onSelect: act(() => _manualSkip(SkipAction.outro)),
          ),
          PlayerMenuItem(
            id: 'mark_intro',
            label: '标记片头为当前位置',
            icon: Icons.flag_outlined,
            onSelect: act(() => _markSkipSegment(SkipAction.intro)),
          ),
          PlayerMenuItem(
            id: 'mark_outro',
            label: '标记片尾为当前位置',
            icon: Icons.flag,
            onSelect: act(() => _markSkipSegment(SkipAction.outro)),
          ),
          PlayerMenuItem(
            id: 'clear_skip',
            label: '清除本片标记',
            icon: Icons.clear,
            enabled: _skipSegments.active,
            onSelect: act(_clearSkipSegments),
          ),
        ],
      ),

      // ------------------------------------------------------ 10. 信息
      PlayerMenuSection(
        title: '信息',
        items: [
          PlayerMenuItem(
            id: 'media_info',
            label: '媒体信息',
            icon: Icons.info_outline,
            onSelect: act(_showMediaInfo),
          ),
          PlayerMenuItem(
            id: 'diagnostics',
            label: '播放诊断',
            icon: Icons.monitor_heart_outlined,
            enabled: _diagnostics != null,
            onSelect: act(_showDiagnostics),
          ),
          PlayerMenuItem(
            id: 'shortcuts',
            label: '快捷键说明',
            icon: Icons.keyboard,
            onSelect: act(_showShortcutHelp),
          ),
        ],
      ),

      // ------------------------------------------------------ 11. 设置
      //
      // 这一组是**下钻设置树**，不再只是三个跳转入口：硬解 / 缓存 / 自动连播
      // 这类开关本身就在这里改，用户不必离开画面（上一版三项全是
      // `Navigator.push`，点一下播放器就没了——用户反馈「还有些没有聚合」
      // 指的正是这件事）。
      //
      // 为什么仍保留跳转项（`完整设置页…` / `打开完整字幕源设置…`）：
      // 那几个页面里是**文本表单**——字幕源 URL、token
      // （**不得进日志**）、多个本地目录。菜单列宽固定 240
      // （`design/04` §5.2），放不下一个可读的输入框；硬塞进去也只会被
      // `maxLines: 1` 的省略号截断，用户看不到自己在改什么，比跳页更难用。
      // 所以切分标准是**「一步操作 vs 长文本录入」**，不是「开关 vs 页面」：
      // 开关就地改，表单仍交给专门页面，两边不重复实现同一份偏好。
      //
      // 弹幕库（自动搜索 / 打开弹幕库设置…）已从这里**删掉**：那两项的内容
      // 被「弹幕 → 弹幕设置…」整页吸收，留着就是同一份偏好的第二个入口。
      PlayerMenuSection(
        title: '设置',
        items: [
  // `_playbackParamsMenuItem` 已搬到 `player_playback_params.dart`（`part` 里的 `_PlayerPageState` 扩展）。
          _playbackParamsMenuItem(),
          PlayerMenuItem(
            id: 'settings_subtitle_source',
            label: '字幕源',
            icon: Icons.subtitles_outlined,
            children: [
              _settingsToggle(
                id: 'settings_subtitle_auto_match',
                label: '自动匹配字幕',
                value: subtitleSettings.autoMatch,
                // 一个源都没有时匹配必然落空：**灰掉但保留 selected**。
                // 引擎把「选中 + 禁用」画成压暗琥珀，状态仍可读
                // （`player_context_menu.dart:503-515`：「禁用只降低强调，
                // 不能抹掉状态」）。
                enabled: subtitleSettings.hasAnyProvider,
                onChanged: _toggleSubtitleAutoMatch,
              ),
              PlayerMenuItem(
                id: 'settings_subtitle_provider_status',
                label: subtitleSettings.hasAnyProvider ? '字幕源：已配置' : '字幕源：未配置',
                icon: subtitleSettings.hasAnyProvider
                    ? Icons.check_circle_outline
                    : Icons.new_releases_outlined,
                // 纯状态行：不给动作，也**不置灰**（灰色读起来像「坏了」）。
                // 「已配置」用 selected 表达，与开关列同一套视觉语言。
                selected: subtitleSettings.hasAnyProvider,
              ),
              PlayerMenuItem(
                id: 'settings_subtitle_source_form',
                label: '打开完整字幕源设置…',
                icon: Icons.folder_open_outlined,
                // 为什么仍是跳转：URL / token / 多个本地目录都是长文本、
                // 多值录入，见本组顶部注释。
                onSelect: act(
                  () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => SubtitleSettingsPage(state: widget.state),
                    ),
                  ),
                ),
              ),
            ],
          ),
          PlayerMenuItem(
            id: 'settings_buttons',
            label: '控制栏按钮',
            icon: Icons.view_week_outlined,
            children: [
              // 10 项（`kPlayerButtons`）：selected = **未隐藏**。
              // 用「显示中」而不是「已隐藏」做勾选态，是因为用户找的是
              // 「这个按钮还在不在控制栏上」。
              for (final spec in kPlayerButtons)
                _settingsToggle(
                  id: 'settings_button_${spec.id}',
                  label: spec.label,
                  value: !widget.state.playerButtonHidden.contains(spec.id),
                  onChanged: (value) =>
                      _togglePlayerButtonVisible(spec.id, value),
                ),
              PlayerMenuItem(
                id: 'settings_buttons_reset',
                label: '恢复默认顺序',
                icon: Icons.restart_alt,
                // 就地执行、不关菜单：结果在控制栏上立刻可见，不需要离开画面。
                // 这里**不弹二次确认**：误点一次的代价是「回到默认」，
                // 而默认本身就是绝大多数用户的状态（表单页要求确认是因为
                // 那里会连拖动顺序一起改）。
                onSelect: _resetPlayerButtonsFromMenu,
              ),
              PlayerMenuItem(
                id: 'settings_buttons_form',
                label: '拖动排序…',
                icon: Icons.drag_indicator,
                // 顺序调整是拖拽手势，菜单里没有可表达的载体——只能跳页。
                onSelect: act(
                  () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) =>
                          PlayerButtonConfigPage(state: widget.state),
                    ),
                  ),
                ),
              ),
            ],
          ),
          PlayerMenuItem(
            id: 'settings_overview_page',
            label: '完整设置页…',
            icon: Icons.settings_outlined,
            // 兜底入口：本树之外的一切设置（直播、广告规则、DoH、站点注入，
            // 以及需要数字输入的精调）都在那里。落点是**全部设置**页：
            // 它复用设置首页的分类中枢，五个分类都能从这里进。
            onSelect: act(
              () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => SettingsOverviewPage(state: widget.state),
                ),
              ),
            ),
          ),
        ],
      ),
    ];
  }

  /// 设置树里的一个开关行。
  ///
  /// 只做「布尔 → 菜单项」的形状转换，不含业务：每个开关的真实语义仍在
  /// 各自的 `onChanged` 里，读的是当前生效值（`selected` 即真相）。
  PlayerMenuItem _settingsToggle({
    required String id,
    required String label,
    required bool value,
    required ValueChanged<bool> onChanged,
    bool enabled = true,
  }) => PlayerMenuItem(
    id: id,
    label: label,
    selected: value,
    enabled: enabled,
    onSelect: () => onChanged(!value),
  );
}
